#!/bin/bash
# Release check on the FINAL app (signed, notarized, stapled): camera and microphone must work the way Meet uses them,
# in both page modes (default and Chrome-style pages, which Omar uses). Omar, Nov 19 2026: Meet showed "Camera is off"
# with "!" on mic and camera; the dev-build tests had only covered the default mode.
#  1. scripts/check-signing.sh: usage strings on the app and every helper, hardened runtime, camera/audio-input
#     entitlements.
#  2. The app itself, hidden, in a throwaway home with fake camera/mic: getUserMedia({audio, video}) after Allow, the
#     device list has ids and names, the permission reads "granted", a remembered Allow needs no card
#     (SELFTEST-MEETREADY), and a page reaching an app on 127.0.0.1 asks and gets through (SELFTEST-LOOPBACK,
#     Beyond Identity's sign-in).
# Usage: scripts/test-signed-media.sh <NotArc.app> [--adhoc]
set -uo pipefail
APP="${1:?usage: test-signed-media.sh <NotArc.app> [--adhoc]}"
ADHOC="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
"$ROOT/scripts/check-signing.sh" "$APP" $ADHOC || FAIL=1
run() {  # run <label> <env...>
  local label="$1"; shift
  local home log
  home="$(mktemp -d "${TMPDIR:-/tmp}/notarc-media-XXXXXX")"
  log="$home.log"
  python3 "$ROOT/scripts/make-test-home.py" "$home" >/dev/null
  env CFFIXED_USER_HOME="$home" "$@" perl -e 'alarm 150; exec @ARGV' "$APP/Contents/MacOS/NotArc" --selftest >"$log" 2>&1
  local lines
  lines="$(grep -E '^SELFTEST-(MEETREADY|LOOPBACK|APPSCHEME|CLIENTCERT|REALPROFILE) ' "$log")"
  echo "$lines" | sed "s/^/[$label] /"
  if ! grep -q '^SELFTEST-REALPROFILE .*prefsUntouched=1 dataUntouched=1' <<<"$lines"; then
    echo "MEDIA-CHECK FAIL [$label]: the run didn't finish cleanly (log: $log)"; FAIL=1
  fi
  if grep -qE '=0( |$)' <<<"$lines"; then
    echo "MEDIA-CHECK FAIL [$label]: a check failed (log: $log)"; FAIL=1
  fi
  local need=MEETREADY
  [ "$label" = sign-in ] && need=LOOPBACK
  grep -q "^SELFTEST-$need " <<<"$lines" || { echo "MEDIA-CHECK FAIL [$label]: no SELFTEST-$need line"; FAIL=1; }
  [ "$FAIL" = 0 ] && rm -rf "$home" "$log"
}
run default NOTARC_SELFTEST_ONLY=meetready
run chrome-pages NOTARC_SELFTEST_ONLY=meetready NOTARC_CHROME_PAGES=1
run sign-in NOTARC_SELFTEST_ONLY=signin NOTARC_CHROME_PAGES=1
if [ "$FAIL" = 0 ]; then echo "MEDIA-CHECK OK"; fi
exit "$FAIL"
