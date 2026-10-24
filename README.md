# NotArc

**Arc is shutting down on December 22, 2026.** NotArc is an open-source effort to keep the way Arc works alive:
the vertical sidebar, Spaces, pinned tabs, folders, the command bar and auto-archiving, in a browser that anyone can
build, use and improve.

NotArc is not Arc. It isn't affiliated with or endorsed by The Browser Company, it contains none of Arc's code,
artwork or branding, and it's written from scratch. It aims for the same everyday features so you can keep working the
way you're used to.

## Why

Arc changed how many of us use the web. When it shuts down, those workflows go with it. NotArc keeps them going in the
open, so no single company can turn them off again.

## Features

NotArc is at version 0.11.0. 36 of the 80 Arc features on the [parity checklist](docs/feature-parity.md) are done
and 13 more are partly done. What works today:

**Sidebar and tabs**
- Vertical sidebar with a Space switcher, plus Favorites, Pinned and Today sections in each Space
- Folders and nested folders, drag and drop, pin/unpin (Cmd+D), rename, duplicate tabs and folders
- Pinned tabs remember their address: Reset to Pinned URL, Replace Pinned URL with Current, Close and Keep Pinned
- Multi-select (Cmd/Shift-click): copy links (plain or Markdown), New Folder with the selected tabs, pin, move to
  another Space, archive them all at once
- Hover cards with a tab's site, state, last use and full address
- Undo Close Tab (Cmd+Z), reopen the last archived tab (Cmd+Shift+T), Copy URL, Copy URL as Markdown, Copy Clean Link
- Arc's keyboard shortcuts: Cmd+1-9 for tabs, Cmd+Opt+Up/Down, Ctrl+Tab for the most recent tab, Cmd+S to hide
  the sidebar

**Spaces**
- Each Space has its own browser profile, so work and personal logins stay apart
- Create, rename, delete and reorder Spaces; Ctrl+1-9 and Cmd+Opt+Left/Right to switch
- Space colours and gradients (Spaces > Edit Theme Color...) and an emoji icon per Space
- Each Space reopens on the tab you were last on

**Command bar**
- Cmd+T and Cmd+L to go to an address or search, with suggestions from open and pinned tabs in every Space, Spaces,
  history and menu commands, plus your top sites when the field is empty
- Suggestions you pick rank higher next time
- Search engine choice: Google, DuckDuckGo, Bing, Ecosia or Kagi

**Split view, Little Window and Peek**
- Split view with up to 4 panes in any direction, draggable dividers, Flip Split Layout; a split is one sidebar item
  and comes back after a restart
- Little Window for links opened from other apps, with Open in NotArc and Move to Space
- Peek: links that leave a pinned site open in an overlay; Open as Tab, or Undo after closing one
- Toolbar mode (Cmd+Shift+S) with back, forward, reload and the full address; Focus Mode and full screen

**Library**
- Auto-archive: Today tabs you haven't used for 12 hours (6 hours to 30 days, or never) move to a searchable Archive
- History (Cmd+Y), Downloads (Cmd+Shift+J), Clear Browsing Data (Cmd+Shift+Delete)

**Browsing**
- Media controls: a speaker on tabs playing sound, a play/pause/mute bar in the sidebar, Mute Tab (Cmd+Shift+M)
- NotArc asks before sites use your camera, microphone, location or notifications, and before links open other apps
- Site Settings (Cmd+Shift+I): Ask/Allow/Block per permission, Clear Cookies and Refresh
- Crashed pages show a Reload button; frozen pages offer Wait or Exit Page; after a crash, your open tabs come back
- Built-in PDF viewer, find in page, zoom, print, DevTools

**Moving over from Arc.** On first launch NotArc reads your Arc data on your own Mac and imports your Spaces, tabs,
archive and logins. It only reads Arc's files and never changes them.

Not built yet: Boosts, Easel, Notes, extensions, password autofill, multiple windows, Incognito and more. The
[parity checklist](docs/feature-parity.md) tracks every item, and [CHANGELOG.md](CHANGELOG.md) lists what each
release added.

## Install

1. Download the latest `NotArc-<version>-arm64.dmg` from [Releases](https://github.com/Donnadieu/notarc/releases).
   NotArc currently needs an Apple Silicon Mac (M1 or newer) running macOS 13 or later.
2. Open the disk image and drag NotArc into Applications.
3. The first time only, right-click NotArc in Applications and choose **Open**, then **Open** again. NotArc isn't
   signed with a paid Apple developer certificate yet, so macOS asks you to confirm. If macOS still refuses, go to
   System Settings > Privacy & Security and click **Open Anyway**.

On first launch NotArc imports your Arc Spaces, tabs and archive. To bring your logins over too, macOS asks once for
access to the "Arc Safe Storage" Keychain item; click **Allow**. NotArc only reads Arc's data and never changes it.

From 0.5.0 on, NotArc checks GitHub Releases once a day and offers **Install and Relaunch** when a new
version is out (or use NotArc > Check for Updates...). Each download is checked against its published
SHA-256 before it's installed. On 0.4.0 or earlier, download the newer release once and replace the app in
Applications. Your data stays in `~/Library/Application Support/NotArc`.

## Built on Chromium, upgraded with Chromium

NotArc is a native macOS app written in Objective-C++. It embeds Chromium through the
[Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef) (CEF), so websites behave exactly as they do
in Chrome. Upgrading to a newer Chromium means downloading a newer CEF build and rebuilding.

Current pin: CEF 156.0.7 (Chromium 156.0.8078.17), Apple Silicon.

## Build from source

Requirements: an Apple Silicon Mac, Apple's Command Line Tools (Xcode isn't needed), `cmake` and `ninja`
(`brew install cmake ninja`).

1. Download the CEF "Standard Distribution" for macOS ARM64 from https://cef-builds.spotifycdn.com/index.html,
   unpack it under `third_party/std/`, and link it: `ln -sfn std/<cef_binary_folder> third_party/cef`
2. `mkdir -p build && cd build && cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .. && ninja`
3. Open `build/Release/NotArc.app`
4. Optional: `scripts/package.sh` makes the release disk image in `dist/`

The first time NotArc imports your Arc logins, macOS asks for permission to read the "Arc Safe Storage" Keychain item.
That key decrypts Arc's saved cookies on your own Mac. Nothing leaves your computer.

Developer flags: `--selftest` runs the automated self-test (separate test data; it never touches your own profiles,
settings or Keychain), `--dump-arc` prints what would be imported from Arc, and `--dump-store` prints NotArc's saved
sidebar.

## Project layout

- `app/`: the browser (window, sidebar, command bar, archive, downloads, history, updater, Arc import)
- `scripts/`: packaging (`package.sh`) and end-to-end tests for updates and crash recovery
- `docs/feature-parity.md`: checklist of every Arc feature and its status in NotArc
- `CHANGELOG.md`: what each release added
- `docs/arc-data-format.md`: how Arc stores your sidebar and archive on disk, so they can be imported
- `CONTRIBUTING.md`: how to build, test and contribute

## Help wanted

NotArc is built by volunteers, and there's a lot of Arc left to rebuild: Boosts, Easel, Notes, extensions, password
autofill, multiple windows and more. If you know C++, Objective-C++ or macOS development, or just use Arc every day and can test,
we'd love your help.

- See what's missing in the [parity checklist](docs/feature-parity.md).
- Pick an issue labelled [good first issue](https://github.com/Donnadieu/notarc/labels/good%20first%20issue) or
  [parity](https://github.com/Donnadieu/notarc/labels/parity).
- Read [CONTRIBUTING.md](CONTRIBUTING.md) for how to build, test and send a pull request.
- Questions and ideas go in [Discussions](https://github.com/Donnadieu/notarc/discussions).

Please don't contribute anything copied from Arc (code, icons, images or text). NotArc has to stay an independent
implementation.

## License

MIT. See [LICENSE](LICENSE). "Arc" is a trademark of The Browser Company of New York; it's mentioned here only to
describe compatibility.
