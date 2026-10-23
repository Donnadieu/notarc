#!/bin/bash
# Session restore after a crash: run the self-test once (leaves SelfTestSidebar.json with a marker tab
# open and shown), then start the reload phase, kill it with SIGKILL (a crash), start it again and
# check that it noticed the crash, reloaded the open tabs and reopened the marker tab.
# Uses only the self-test files; never touches your real sidebar or profiles.
set -u
APP="${1:-build/Release/NotArc.app}/Contents/MacOS/NotArc"
LOG=$(mktemp -d)
perl -e 'alarm 280; exec @ARGV' "$APP" --selftest > "$LOG/phase1.log" 2>&1
"$APP" --selftest-reload > "$LOG/crash.log" 2>&1 &
PID=$!
sleep 6
kill -9 $PID 2>/dev/null; wait $PID 2>/dev/null
pkill -9 -f "NotArc Helper.*SelfTest" 2>/dev/null
sleep 2
perl -e 'alarm 90; exec @ARGV' "$APP" --selftest-reload > "$LOG/restore.log" 2>&1
LINE=$(grep SELFTEST-RESTORE "$LOG/restore.log")
echo "$LINE"
if echo "$LINE" | grep -q "crashedLastTime=1" && echo "$LINE" | grep -q "shown=https://example.org/session-restore-marker" &&
   ! echo "$LINE" | grep -q "restored=0 "; then
  echo "SESSION-RESTORE OK"
else
  echo "SESSION-RESTORE FAILED (logs in $LOG)"; exit 1
fi
