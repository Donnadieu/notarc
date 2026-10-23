#!/bin/bash
# Build a distributable NotArc disk image from build/Release/NotArc.app.
# Usage: scripts/package.sh [output-dir]   (default: dist/)
# The app is ad-hoc signed (no Apple Developer ID), so first launch needs right-click > Open.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/Release/NotArc.app"
OUT="${1:-$ROOT/dist}"
[ -d "$SRC" ] || { echo "Build first: $SRC not found" >&2; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$SRC/Contents/Info.plist")"
ARCH="$(lipo -archs "$SRC/Contents/MacOS/NotArc" | tr ' ' '-')"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$SRC" "$STAGE/NotArc.app"
APP="$STAGE/NotArc.app"
FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"

# Incremental builds re-run the framework copy, leaving self-referencing links
# (Versions/A/A, Resources/Resources, Libraries/Libraries) that break code signing.
find "$FW" -type l ! -exec test -e {} \; -print -delete

# Sign inside-out: nested code first, the app bundle last.
for lib in "$FW/Libraries/"*.dylib; do codesign --force --sign - "$lib"; done
codesign --force --sign - "$FW"
for helper in "$APP/Contents/Frameworks/"*.app; do codesign --force --sign - "$helper"; done
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p "$OUT" "$STAGE/dmg"
mv "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
DMG="$OUT/NotArc-$VERSION-$ARCH.dmg"
hdiutil create -volname "NotArc $VERSION" -srcfolder "$STAGE/dmg" -format ULMO -ov "$DMG" >/dev/null
(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
