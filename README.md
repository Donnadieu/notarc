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
- **Move over from Arc.** On first launch NotArc reads your Arc data on your own Mac and imports your Spaces, tabs,
  archive and logins. It only reads Arc's files and never changes them.

Planned: split view, Peek, Little Arc, Boosts, Easel and Notes and more. See [the parity checklist](docs/feature-parity.md).

## Built on Chromium, upgraded with Chromium

NotArc is a native macOS app written in Objective-C++. It embeds Chromium through the
[Chromium Embedded Framework](https://bitbucket.org/chromiumembedded/cef) (CEF), so websites behave exactly as they do
in Chrome. Upgrading to a newer Chromium means downloading a newer CEF build and rebuilding.

Current pin: CEF 156.0.7 (Chromium 156.0.8078.17), Apple Silicon.

## Build

Requirements: an Apple Silicon Mac, Apple's Command Line Tools (Xcode isn't needed), `cmake` and `ninja`
(`brew install cmake ninja`).

1. Download the CEF "Standard Distribution" for macOS ARM64 from https://cef-builds.spotifycdn.com/index.html,
   unpack it under `third_party/std/`, and link it: `ln -sfn std/<cef_binary_folder> third_party/cef`
2. `mkdir -p build && cd build && cmake -G Ninja -DCMAKE_BUILD_TYPE=Release .. && ninja`
3. Open `build/Release/NotArc.app`

The first time NotArc imports your Arc logins, macOS asks for permission to read the "Arc Safe Storage" Keychain item.
That key decrypts Arc's saved cookies on your own Mac. Nothing leaves your computer.

Developer flags: `--selftest` runs an automated smoke test, `--dump-arc` prints what would be imported from Arc, and
`--dump-store` prints NotArc's saved sidebar.

## Project layout

- `app/`: the browser (window, sidebar, command bar, archive, Arc import)
- `docs/feature-parity.md`: checklist of every Arc feature and its status in NotArc
- `docs/arc-data-format.md`: how Arc stores your sidebar and archive on disk, so they can be imported

## Contributing

Issues and pull requests are welcome. Please don't contribute anything copied from Arc (code, icons, images or text).
NotArc has to stay an independent implementation.

## License

MIT. See [LICENSE](LICENSE). "Arc" is a trademark of The Browser Company of New York; it's mentioned here only to
describe compatibility.
