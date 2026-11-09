#!/usr/bin/env python3
"""WHY: app/arc_import.mm and app/arc_cookies.mm are the only files meant to touch
the user's Keychain (importing Arc's saved logins). A Keychain/Security.framework
call anywhere else is either a duplicate, unreviewed import path or an accidental
widening of what reads the user's credentials, so it's banned outside those files.

FIX: move the call into app/arc_import.mm or app/arc_cookies.mm (or extend one of
those files' existing helpers), or if a new file genuinely needs its own scoped
Keychain access, add it to ALLOWED_FILES below with a comment saying why.
"""
import re
import sys
from pathlib import Path

BANNED_PATTERN = re.compile(r"\b(SecKeychain\w*|SecItem\w*|SecTrust\w*|SecCertificate\w*|SecAccessControl\w*)\s*\(")

ALLOWED_FILES = {
    "app/arc_cookies.mm",
    "app/arc_cookies.h",
    "app/arc_import.mm",
    "app/arc_import.h",
}


def scan(repo_root: Path, allowed_files=ALLOWED_FILES):
    violations = []
    for path in sorted((repo_root / "app").glob("*")):
        if path.suffix not in (".mm", ".h", ".cc"):
            continue
        rel = f"app/{path.name}"
        if rel in allowed_files:
            continue
        for lineno, line in enumerate(path.read_text(errors="replace").splitlines(), start=1):
            m = BANNED_PATTERN.search(line)
            if m:
                violations.append((rel, lineno, m.group(1)))
    return violations


def check(repo_root: Path, allowed_files=ALLOWED_FILES) -> int:
    violations = scan(repo_root, allowed_files)
    if not violations:
        print("keychain-scope: ok (no Keychain/Security.framework calls outside app/arc_import.mm, app/arc_cookies.mm)")
        return 0
    for rel, lineno, api in violations:
        print(f"KEYCHAIN-SCOPE: {rel}:{lineno} calls {api} outside the allowed Keychain-access files.", file=sys.stderr)
    print("WHY: only app/arc_import.mm and app/arc_cookies.mm are reviewed to touch the user's Keychain.", file=sys.stderr)
    print(
        "FIX: move the call into app/arc_import.mm or app/arc_cookies.mm, or add the file to ALLOWED_FILES in "
        "scripts/lint/check-keychain-scope.py with a comment explaining why it needs its own Keychain access.",
        file=sys.stderr,
    )
    return 1


def prove() -> int:
    import tempfile

    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "app").mkdir()
        (root / "app" / "arc_cookies.mm").write_text("SecItemCopyMatching(query, &result);\n")
        (root / "app" / "settings.mm").write_text("int x = 1;\n")
        if check(root) != 0:
            print("PROVE FAILED: no violation should be reported when the banned call is only in an allowed file", file=sys.stderr)
            return 1

        (root / "app" / "settings.mm").write_text("SecItemCopyMatching(query, &result);\n")
        if check(root) == 0:
            print("PROVE FAILED: a banned call outside the allowed files did not block", file=sys.stderr)
            return 1

    print("keychain-scope --prove: ok (canary blocked a call outside the allowed files)")
    return 0


def main(argv):
    if "--prove" in argv:
        return prove()
    repo_root = Path(__file__).resolve().parents[2]
    return check(repo_root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
