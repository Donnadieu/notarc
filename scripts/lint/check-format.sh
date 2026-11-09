#!/bin/bash
# Checks the given files against .clang-format. Shared by scripts/check.sh,
# .githooks/pre-commit and .github/workflows/ci.yml so there's one copy of
# this loop instead of three. Usage: check-format.sh <file>...
set -u

if [ "$#" -eq 0 ]; then
  exit 0
fi

if ! command -v clang-format > /dev/null 2>&1; then
  echo "clang-format not installed -- skipping (CI installs it; see .github/workflows/ci.yml)" >&2
  exit 0
fi

bad=0
for f in "$@"; do
  diff -q <(clang-format --style=file "$f") "$f" > /dev/null || { echo "NEEDS FORMAT: $f" >&2; bad=1; }
done
if [ "$bad" -ne 0 ]; then
  echo "FIX: run 'git ls-files \"app/*.mm\" \"app/*.h\" \"app/*.cc\" | xargs clang-format --style=file -i' and re-add." >&2
  exit 1
fi
echo "clang-format: ok ($# file(s) checked)"
