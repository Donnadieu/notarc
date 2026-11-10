#!/bin/bash
# Build a distributable NotArc disk image from build/Release/NotArc.app.
# Usage: scripts/package.sh [output-dir]   (default: dist/)
#
# Releases are signed with a Developer ID Application certificate (hardened runtime), notarized by Apple and stapled,
# so macOS opens them without asking. Signing happens inside-out: CEF's dylibs, the framework, every
# "NotArc Helper*.app", then the app. The app is notarized and stapled first (the updater copies it out of the dmg),
# then the dmg is signed, notarized and stapled too.
#
# Settings (environment, nothing secret lives in this repo):
#   NOTARC_SIGN_ID         codesign identity; default: the first "Developer ID Application" identity in the keychain
#   NOTARC_NOTARY_PROFILE  `xcrun notarytool store-credentials` profile name (required)
#   NOTARC_ADHOC=1         local test builds only: ad-hoc signature, no notarization (never publish these)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/build/Release/NotArc.app"
OUT="${1:-$ROOT/dist}"
[ -d "$SRC" ] || { echo "Build first: $SRC not found" >&2; exit 1; }

ADHOC="${NOTARC_ADHOC:-0}"
if [ "$ADHOC" = 1 ]; then
  ID="-"
else
  ID="${NOTARC_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"$/\1/p' | head -1)}"
  [ -n "$ID" ] || { echo "No Developer ID Application identity found (set NOTARC_SIGN_ID, or NOTARC_ADHOC=1 for a local build)" >&2; exit 1; }
  PROFILE="${NOTARC_NOTARY_PROFILE:-}"
  [ -n "$PROFILE" ] || { echo "Set NOTARC_NOTARY_PROFILE to a notarytool keychain profile" >&2; exit 1; }
fi

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

sign() {  # sign <entitlements or ""> <path>
  local ent="$1"; shift
  if [ "$ADHOC" = 1 ]; then
    codesign --force --sign - "$@"
  elif [ -n "$ent" ]; then
    codesign --force --options runtime --timestamp --entitlements "$ent" --sign "$ID" "$@"
  else
    codesign --force --options runtime --timestamp --sign "$ID" "$@"
  fi
}

# Sign inside-out: nested code first, the app bundle last.
for lib in "$FW/Libraries/"*.dylib; do sign "" "$lib"; done
sign "" "$FW"
for helper in "$APP/Contents/Frameworks/"*.app; do sign "$ROOT/app/helper.entitlements" "$helper"; done
sign "$ROOT/app/NotArc.entitlements" "$APP"
codesign --verify --deep --strict "$APP"

notarize() {  # notarize <file to submit> <label>
  local log="$STAGE/notary-$2.log"
  xcrun notarytool submit "$1" --keychain-profile "$PROFILE" --wait 2>&1 | tee "$log"
  if ! grep -q "status: Accepted" "$log"; then
    local sub; sub=$(sed -n 's/^ *id: \([0-9a-f-]*\).*/\1/p' "$log" | head -1)
    [ -n "$sub" ] && xcrun notarytool log "$sub" --keychain-profile "$PROFILE" >&2 || true
    echo "Notarization of $2 failed" >&2; exit 1
  fi
}

if [ "$ADHOC" != 1 ]; then
  ditto -c -k --keepParent "$APP" "$STAGE/NotArc-notarize.zip"
  notarize "$STAGE/NotArc-notarize.zip" app
  rm -f "$STAGE/NotArc-notarize.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

mkdir -p "$OUT" "$STAGE/dmg"
mv "$APP" "$STAGE/dmg/"
ln -s /Applications "$STAGE/dmg/Applications"
DMG="$OUT/NotArc-$VERSION-$ARCH.dmg"
hdiutil create -volname "NotArc $VERSION" -srcfolder "$STAGE/dmg" -format ULMO -ov "$DMG" >/dev/null

if [ "$ADHOC" != 1 ]; then
  codesign --force --timestamp --sign "$ID" "$DMG"
  notarize "$DMG" dmg
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "$DMG"
