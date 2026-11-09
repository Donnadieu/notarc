#!/bin/bash
# One local command for every fast guardrail: formatting, the file-length
# ratchet and the Keychain-scope check. Run before every commit (the
# pre-commit hook in .githooks/pre-commit runs this on staged files only;
# this runs it over the whole tree). Does not build the app or run
# --selftest -- those need CEF and a full build; run `scripts/run-selftest.sh`
# for that, or let CI do it.
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1

fail=0

echo "== clang-format =="
if command -v clang-format > /dev/null 2>&1; then
  files=$(git ls-files 'app/*.mm' 'app/*.h' 'app/*.cc')
  bad=0
  for f in $files; do
    diff -q <(clang-format --style=file "$f") "$f" > /dev/null || { echo "NEEDS FORMAT: $f" >&2; bad=1; }
  done
  if [ "$bad" -ne 0 ]; then
    echo "FIX: run 'git ls-files \"app/*.mm\" \"app/*.h\" \"app/*.cc\" | xargs clang-format --style=file -i'" >&2
    fail=1
  else
    echo "clang-format: ok"
  fi
else
  echo "clang-format not installed -- skipping (CI installs it; see .github/workflows/ci.yml)" >&2
fi

echo "== file-length ratchet =="
scripts/lint/file-length-ratchet.sh || fail=1

echo "== keychain scope =="
python3 -I scripts/lint/check-keychain-scope.py || fail=1

exit $fail
