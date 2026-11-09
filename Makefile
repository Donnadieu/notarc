# Convenience targets for the fast guardrails (formatting, the file-length
# ratchet, the Keychain-scope check). The actual app is built with CMake +
# Ninja; see README.md / CONTRIBUTING.md.

.PHONY: check prove-canaries setup-hooks

check:
	scripts/check.sh

prove-canaries:
	scripts/lint/file-length-ratchet.sh --prove
	python3 scripts/lint/check-keychain-scope.py --prove

setup-hooks:
	scripts/setup-hooks.sh
