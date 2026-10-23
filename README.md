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

Working today:
- **Vertical sidebar** with a Space switcher, plus Favorites, Pinned and Today sections in each Space
- **Spaces with separate logins.** Each Space has its own browser profile, so work and personal accounts stay apart.
- **Folders, drag and drop, and pin/unpin** (Cmd+D)
- **Command bar.** Cmd+T opens a new tab, Cmd+L goes to an address or search, Cmd+W closes a tab.
- **Auto-archive.** Today tabs you haven't used in 12 hours are tidied away into a searchable Archive (Cmd+Y);
  Cmd+Shift+T brings the last one back.
- **Split view** (up to 4 panes), **Little Window** for links from other apps, and **Peek** for links clicked on
  pinned sites
- **Move over from Arc.** On first launch NotArc reads your Arc data on your own Mac and imports your Spaces, tabs,
  archive and logins. It only reads Arc's files and never changes them.

Planned: Boosts, Easel, Notes, extensions, settings and more. See [the parity checklist](docs/feature-parity.md).

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

Developer flags: `--selftest` runs an automated smoke test, `--dump-arc` prints what would be imported from Arc, and
`--dump-store` prints NotArc's saved sidebar.

## Project layout

- `app/`: the browser (window, sidebar, command bar, archive, Arc import)
- `docs/feature-parity.md`: checklist of every Arc feature and its status in NotArc
- `docs/arc-data-format.md`: how Arc stores your sidebar and archive on disk, so they can be imported
- `CONTRIBUTING.md`: how to build, test and contribute

## Help wanted

NotArc is built by volunteers, and there's a lot of Arc left to rebuild: Boosts, Easel, Notes, Settings, extensions,
context menus and more. If you know C++, Objective-C++ or macOS development, or just use Arc every day and can test,
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
