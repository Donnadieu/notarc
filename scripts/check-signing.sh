#!/bin/bash
# Release check: the app and every NotArc Helper*.app carry the camera and microphone usage strings, and (signed
# builds) the hardened runtime with the camera / audio-input entitlements. A hardened-runtime app without these is
# killed by macOS the moment a site starts the camera or mic, so a release must never ship without them.
# Usage: scripts/check-signing.sh <NotArc.app> [--adhoc]   (--adhoc: only the usage strings)
set -uo pipefail
APP="${1:?usage: check-signing.sh <NotArc.app> [--adhoc]}"
ADHOC="${2:-}"
FAIL=0
fail() { echo "SIGNING-CHECK FAIL: $*"; FAIL=1; }

BUNDLES=("$APP")
while IFS= read -r h; do BUNDLES+=("$h"); done < <(find "$APP/Contents/Frameworks" -maxdepth 1 -name 'NotArc Helper*.app' | sort)
[ "${#BUNDLES[@]}" -ge 6 ] || fail "expected the app and 5 helpers, found ${#BUNDLES[@]} bundles"

# Every bundle must be signed by the same team as the app (NOTARC_TEAM_ID, if set, names it).
TEAM="${NOTARC_TEAM_ID:-$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')}"
if [ "$ADHOC" != "--adhoc" ] && { [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; }; then fail "NotArc.app: no Developer ID team"; fi
for b in "${BUNDLES[@]}"; do
  name="$(basename "$b")"
  for key in NSCameraUsageDescription NSMicrophoneUsageDescription; do
    v="$(/usr/libexec/PlistBuddy -c "Print :$key" "$b/Contents/Info.plist" 2>/dev/null)"
    [ -n "$v" ] || fail "$name: no $key in Info.plist"
  done
  [ "$ADHOC" = "--adhoc" ] && continue
  info="$(codesign -dv "$b" 2>&1)"
  grep -q 'flags=.*runtime' <<<"$info" || fail "$name: not signed with the hardened runtime"
  grep -qx "TeamIdentifier=$TEAM" <<<"$info" || fail "$name: not signed by team $TEAM"
  ent="$(codesign -d --entitlements - --xml "$b" 2>/dev/null)"
  for e in com.apple.security.device.camera com.apple.security.device.audio-input com.apple.security.cs.allow-jit; do
    python3 - "$e" "$ent" <<'EOF' || fail "$name: entitlement $e missing or not true"
import plistlib, sys
key, xml = sys.argv[1], sys.argv[2].encode()
try:
    d = plistlib.loads(xml[xml.index(b"<?xml"):]) if b"<?xml" in xml else {}
except Exception:
    d = {}
sys.exit(0 if d.get(key) is True else 1)
EOF
  done
done
if [ "$FAIL" = 0 ]; then echo "SIGNING-CHECK OK ${#BUNDLES[@]} bundles"; fi
exit "$FAIL"
