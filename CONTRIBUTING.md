# Contributing to NotArc

Thanks for helping keep Arc's way of browsing alive. NotArc is a volunteer, non-commercial, MIT-licensed project.

## Ground rules

- **Build it from scratch.** Don't copy Arc's code, icons, images, sounds or wording. Describe what a feature does
  and implement it your own way. NotArc has to stay an independent browser.
- One feature or fix per pull request. Keep changes small enough to review.
- Every feature should match how it works in Arc 1.169 (the last Arc release). If you're unsure, say so in the issue.

## What to work on

- [docs/feature-parity.md](docs/feature-parity.md) lists every Arc feature and its status.
- Each missing or partial item has a GitHub issue labelled `parity`. Small, self-contained ones are labelled
  `good first issue`.
- Comment on the issue before starting, so two people don't build the same thing.

## Build

You need an Apple Silicon Mac, Apple's Command Line Tools (full Xcode isn't required), and `brew install cmake ninja`.

1. Download the CEF "Standard Distribution" for macOS ARM64 (the version in the README) from
   https://cef-builds.spotifycdn.com/index.html, unpack it under `third_party/std/`, then
   `ln -sfn std/<cef_binary_folder> third_party/cef`.
2. `mkdir -p build && cd build && cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .. && ninja`
3. Run `build/Release/NotArc.app`.

## Code layout

NotArc is Objective-C++ (AppKit for the window and sidebar) on top of CEF (Chromium).

| File | What it does |
|---|---|
| `app/main.mm` | App startup, menus and keyboard shortcuts, the self-test |
| `app/main_window.mm` | Main window: sidebar, Spaces, tabs, command bar and suggestions, split view, Peek, toolbar, themes, hover cards, media bar, crash and site prompts, Site Settings |
| `app/browser_client.mm` | CEF callbacks (titles, loading, find, focus, links and popups, downloads, media, renderer crashes, permissions, links to other apps) |
| `app/little_window.mm` | Little Window (also used for Peek) |
| `app/sidebar_store.mm`, `app/archive_store.mm` | Saving the sidebar and archive as JSON; the crash marker for session restore |
| `app/history_store.mm`, `app/archive_window.mm` | History and the History/Archive windows |
| `app/downloads.mm` | Downloads list and window |
| `app/settings.mm` | Settings and the Settings window |
| `app/updater.mm` | Update check, download, SHA-256 check and install |
| `app/arc_import.mm`, `app/arc_cookies.mm` | One-time import of a user's Arc sidebar, archive and logins |
| `docs/arc-data-format.md` | The files in a user's Arc data folder that the importer reads |

## Testing

Run `build/Release/NotArc.app/Contents/MacOS/NotArc --selftest`. It takes about three minutes, drives the app
(tabs, split view, Peek, Spaces, shortcuts, command bar, downloads, permissions and more), prints `SELFTEST-...` lines
and quits. Every value should be 1 (or the expected count); a `0` means a check failed.

The self-test is isolated from your own browsing: it uses separate "SelfTest" profiles and sidebar files, keeps
setting changes in memory only, uses a throwaway key instead of the Keychain (so no Keychain prompts), and a fake
camera and microphone. Keep it that way when you add checks.

Add a check for the feature you build. Timed checks run side by side, so show your own tab with `showItem:` before
asserting. Paste the relevant lines into your pull request, and try the feature by hand too.

Changing the updater? Also run `scripts/test-update.sh`: it updates a throwaway copy of the app from the latest
GitHub release and checks the copy was replaced. It never touches /Applications.

Changing saving, launching or quitting? Also run `scripts/test-session-restore.sh`. It crashes a self-test copy on
purpose (SIGKILL) and checks that the next launch reopens the open tabs. It only uses the self-test files.

## Issues

Every missing or partial Arc feature has an issue labelled `parity`, linked to its line in
`docs/feature-parity.md`.

- Before starting, comment on the issue (or ask to be assigned) so two people don't build the same thing. Check the
  comments first: someone may already be on it.
- Put `Closes #N` in your pull request when it finishes the item, so the issue closes on merge. If it only finishes
  part of it, use `Part of #N` and say in the issue what is still missing.
- The checklist and the issues must agree: a `[x]` line has a closed issue, an unchecked line has an open one.

## Pull requests

- Branch from `main`; pull requests are squash-merged.
- Describe what changed, how it matches Arc, and how you tested it.
- Update `docs/feature-parity.md` if your change completes or advances an item, and add a line to `CHANGELOG.md`
  for user-visible changes.
