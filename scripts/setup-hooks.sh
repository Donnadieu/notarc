#!/bin/bash
# Run once after cloning: points git at the repo's tracked hooks (.githooks/)
# instead of the unused .git/hooks/ samples.
set -eu
cd "$(git rev-parse --show-toplevel)"
git config core.hooksPath .githooks
echo "core.hooksPath set to .githooks"
