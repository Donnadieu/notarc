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
| `app/main_window.mm` | Main window: sidebar, Spaces, tabs, command bar, split view, Peek, archive |
| `app/browser_client.mm` | CEF callbacks (titles, loading, find, focus, links and popups) |
| `app/little_window.mm` | Little Window (also used for Peek) |
| `app/sidebar_store.mm`, `app/archive_store.mm` | Saving the sidebar and archive as JSON |
| `app/arc_import.mm`, `app/arc_cookies.mm` | One-time import of a user's Arc sidebar, archive and logins |
| `docs/arc-data-format.md` | The files in a user's Arc data folder that the importer reads |

## Testing

Run `build/Release/NotArc.app/Contents/MacOS/NotArc --selftest`. It drives the app (new tabs, split view, Peek,
Spaces, shortcuts and more) using separate test data, prints `SELFTEST-...` lines and quits. Add a check there for
the feature you build, and paste the relevant lines into your pull request. Also try the feature by hand.

Changing the updater? Also run `scripts/test-update.sh`: it updates a throwaway copy of the app from the latest
GitHub release and checks the copy was replaced. It never touches /Applications.

## Pull requests

- Branch from `main`; pull requests are squash-merged.
- Describe what changed, how it matches Arc, and how you tested it.
- Update `docs/feature-parity.md` if your change completes or advances an item.

If you change saving, launching or quitting, also run `./scripts/test-session-restore.sh`. It crashes a self-test copy on purpose (SIGKILL) and checks that the next launch reopens the open tabs. It only uses the self-test files.
