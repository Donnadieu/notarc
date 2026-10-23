#!/bin/bash
# End-to-end updater test: copies the built app to a temp folder, marks the copy as 0.0.1, runs
# `--self-update-test` from it (downloads the latest GitHub release, checks its SHA-256, swaps it in
# after exiting), then checks the copy now has the release's version. Touches nothing in /Applications.
set -euo pipefail
APP="${1:-build/Release/NotArc.app}"
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
ditto "$APP" "$D/NotArc.app"
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString 0.0.1" "$D/NotArc.app/Contents/Info.plist"
touch "$D/NotArc.app/Contents/OLD_MARKER"
OUT=$("$D/NotArc.app/Contents/MacOS/NotArc" --self-update-test)
echo "$OUT"
LATEST=$(echo "$OUT" | sed -n 's/^UPDATETEST latest=\([^ ]*\).*/\1/p')
for _ in $(seq 1 30); do [ ! -e "$D/NotArc.app/Contents/OLD_MARKER" ] && break; sleep 1; done
GOT=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$D/NotArc.app/Contents/Info.plist")
codesign --verify --deep "$D/NotArc.app"
if [ "$GOT" = "$LATEST" ] && [ ! -e "$D/NotArc.app/Contents/OLD_MARKER" ] && [ ! -e "$D/NotArc.app.old" ]; then
  echo "UPDATE-E2E OK: 0.0.1 -> $GOT"
else
  echo "UPDATE-E2E FAILED: expected $LATEST, got $GOT"; exit 1
fi
