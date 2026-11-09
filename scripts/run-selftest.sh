#!/bin/bash
# Runs `--selftest` against a throwaway home (scripts/make-test-home.py) and
# gates on the self-test actually having run to completion -- the gap the
# project's own CONTRIBUTING.md flags: today a broken build or a hung/crashed
# self-test can merge unnoticed because nothing runs it automatically.
#
# WHY exit code isn't the pass signal: CEF's own teardown occasionally trips
# a "Teardown watchdog expired" kill after every check has already printed
# (observed locally even on a run where all 90 checks reported success), so a
# bare exit-code check would be flaky. Instead this looks for the last check
# in the self-test's fixed sequence (SELFTEST-WINDOWS, from the "multiple
# windows" test that intentionally runs last) in the captured output: seeing
# it proves the whole chain executed, regardless of how CEF's process exits.
#
# This does not grade every individual check (see CONTRIBUTING.md: pasting
# the relevant SELFTEST-... lines into a pull request remains how a reviewer
# verifies a specific feature's checks). It only proves the run didn't hang,
# crash or regress before completing.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

APP="${1:-build/Release/NotArc.app}/Contents/MacOS/NotArc"
TIMEOUT_SECS="${2:-600}"

if [ ! -x "$APP" ]; then
  echo "FIX: $APP not found. Build first: scripts/fetch-cef.sh && cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -S . -B build && ninja -C build" >&2
  exit 1
fi

HOME_DIR=$(mktemp -d)
python3 -I scripts/make-test-home.py "$HOME_DIR" > /dev/null
LOG=$(mktemp)

CFFIXED_USER_HOME="$HOME_DIR" perl -e "alarm $TIMEOUT_SECS; exec @ARGV" "$APP" --selftest > "$LOG" 2>&1
exit_code=$?

if grep -q '^SELFTEST-WINDOWS ' "$LOG"; then
  echo "run-selftest: ok (full self-test sequence ran; log: $LOG)"
  exit 0
fi

echo "SELFTEST-WINDOWS line never appeared -- the self-test did not finish (exit code was $exit_code)." >&2
echo "WHY: SELFTEST-WINDOWS is the last check the self-test runs; seeing it is the only way to know every earlier check ran too." >&2
echo "FIX: run it locally (CFFIXED_USER_HOME=<tmp dir> $APP --selftest) and look for a crash, hang or newly-broken check before this line in the log." >&2
echo "--- last 40 lines of $LOG ---" >&2
tail -40 "$LOG" >&2
exit 1
