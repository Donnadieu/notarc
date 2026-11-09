# NotArc

NotArc is a volunteer, MIT-licensed macOS browser (Objective-C++ on AppKit, embedding Chromium via CEF)
that rebuilds Arc's sidebar, Spaces, command bar and auto-archiving. README.md covers user-facing feature
status; CONTRIBUTING.md covers the human contribution process. This file is the map for a coding agent.

## Stack

Objective-C++ (AppKit) on top of the Chromium Embedded Framework (CEF). Build system is CMake + Ninja; no
package manager. Dependencies: Apple's Command Line Tools, `cmake`, `ninja`, and the pinned CEF binary
distribution (fetched by `scripts/fetch-cef.sh`, not a manual download).

## Quick commands

    scripts/check.sh                                   # format + file-length ratchet + Keychain-scope check (fast, no build)
    make check                                         # same, via Makefile
    make prove-canaries                                # run every custom rule's canary; proves it actually blocks
    scripts/setup-hooks.sh                              # one-time: point git at .githooks/ (pre-commit runs scripts/check.sh)
    scripts/fetch-cef.sh                                # download + checksum + link the pinned CEF build (third_party/cef)
    cmake -G Ninja -DCMAKE_BUILD_TYPE=Release -S . -B build && ninja -C build   # build
    scripts/run-selftest.sh build/Release/NotArc.app 600                        # run --selftest, gated on completion
    scripts/test-update.sh build/Release/NotArc.app                # updater end-to-end (touching app/updater.mm)
    scripts/test-session-restore.sh build/Release/NotArc.app       # crash/session-restore end-to-end

## Directory structure

    app/                  # the browser; see the table below
    scripts/              # build, test and lint scripts
    scripts/lint/         # the custom guardrail checks (file-length ratchet, Keychain scope)
    .github/workflows/    # CI: lint (fast), build-and-selftest (macOS), updater-canary (path-filtered)
    .hardening/           # ratchet baseline(s); counts may only shrink
    docs/                 # feature-parity.md (Arc parity checklist), arc-data-format.md (Arc's on-disk format)
    third_party/cef       # gitignored symlink to the downloaded CEF build; created by scripts/fetch-cef.sh

## Code layout (app/)

| File | What it does |
|---|---|
| `main.mm` | App startup, menus, keyboard shortcuts, the self-test driver |
| `main_window.mm` | Main window: sidebar, Spaces, tabs, command bar, split view, Peek, toolbar, themes, hover cards, media bar, crash/site prompts, Site Settings. File-length ratcheted (see Guardrails). |
| `browser_client.mm` | CEF callbacks: titles, loading, find, focus, links/popups, downloads, media, renderer crashes, permissions |
| `little_window.mm` | Little Window (also used for Peek) |
| `sidebar_store.mm`, `archive_store.mm` | Sidebar/archive JSON persistence; the crash marker for session restore |
| `history_store.mm`, `archive_window.mm` | History and the History/Archive windows |
| `downloads.mm` | Downloads list and window |
| `settings.mm` | Settings and the Settings window |
| `updater.mm` | Update check, download, SHA-256 verification, install. Gated by `.github/workflows/updater-canary.yml`. |
| `arc_import.mm`, `arc_cookies.mm` | One-time import of a user's Arc sidebar, archive and logins. The only files allowed to call Keychain/Security.framework APIs (enforced by `scripts/lint/check-keychain-scope.py`). |

## Guardrails

Every guardrail below runs in three places: `.githooks/pre-commit` (staged files only), `scripts/check.sh` /
`make check` (whole tree), and `.github/workflows/ci.yml` on every pull request.

| Guardrail | Enforced by | Why |
|---|---|---|
| Formatting | `.clang-format`; checked in `scripts/check.sh` | No formatting standard meant diffs mixed style with logic |
| File-length ratchet | `scripts/lint/file-length-ratchet.sh`, baseline in `.hardening/file-length-baseline.txt` | `main_window.mm`/`main.mm` are de facto god-objects; this stops them growing further while a split is planned |
| Keychain scope | `scripts/lint/check-keychain-scope.py` | Only `arc_import.mm`/`arc_cookies.mm` are reviewed to touch the user's Keychain |
| Build + `--selftest` | `.github/workflows/ci.yml` (`build-and-selftest`), `scripts/run-selftest.sh` | Nothing ran the build or the self-test automatically before |
| Updater / session-restore canary | `.github/workflows/updater-canary.yml` running `scripts/test-update.sh` and `scripts/test-session-restore.sh` | High-impact, low-visibility code paths; path-filtered so it only runs when they're touched |

The Keychain-scope and file-length checks are dependency-free scripts rather than a compiled clang-tidy plugin:
a real out-of-tree clang-tidy check needs LLVM's dev headers and its own build target, which is a lot of CI
surface for invariants this specific (a banned-API allowlist, a line count). Each has a `--prove` mode that runs
a self-contained canary proving it actually blocks (`make prove-canaries`, also run in CI).

`scripts/run-selftest.sh` does not grade every individual one of the self-test's ~90 checks (see
CONTRIBUTING.md's "paste the relevant SELFTEST-... lines into your pull request" convention for that). It gates
on the self-test having run to completion: it looks for `SELFTEST-WINDOWS`, the last check in the fixed
sequence, rather than trusting the process exit code, because CEF's own teardown can trip a watchdog kill after
every check has already succeeded.

## Conventions

- Branch from `main`; pull requests are squash-merged (see CONTRIBUTING.md).
- Run `scripts/lint/file-length-ratchet.sh --update` only after shrinking a tracked file, never to raise its cap.
- Keychain/Security.framework calls stay inside `app/arc_import.mm` / `app/arc_cookies.mm`. A new file that
  genuinely needs its own gets added to `ALLOWED_FILES` in `scripts/lint/check-keychain-scope.py`, with a
  comment explaining why.
- All commits must be signed.
