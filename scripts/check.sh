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
scripts/lint/check-format.sh $(git ls-files 'app/*.mm' 'app/*.h' 'app/*.cc') || fail=1

echo "== file-length ratchet =="
scripts/lint/file-length-ratchet.sh || fail=1

echo "== keychain scope =="
python3 -I scripts/lint/check-keychain-scope.py || fail=1

exit $fail
