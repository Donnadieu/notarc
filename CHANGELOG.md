# Changelog

All NotArc releases are on [GitHub Releases](https://github.com/Donnadieu/notarc/releases). Apple Silicon, macOS 13
or later. From 0.5.0 on, NotArc updates itself.

## Unreleased
- Light and dark: each Space can follow macOS or be set to Light or Dark (Space menu > Appearance), and the
  sidebar, rows, pills and command bar switch to Arc's light or dark colours with it.
- Arc motion: the sidebar slides sideways when you switch Spaces (from the right for the next Space, from the left
  for the previous one), and the page card pops in when you change tabs. Both turn off with Reduce Motion.
- Arc-style command bar: a rounded translucent card, Arc's text colours, the selected suggestion as an Arc-blue
  pill, an icon for each kind of suggestion, and a hairline under the field.

## 0.12.0
- Arc's window look: no title bar, the page sits in a rounded card inset on the Space colour, and the Space theme
  colours the whole window frame. The sidebar is 273 pt wide, as in Arc. Hiding the sidebar or Focus Mode shows
  the page edge to edge.
- Arc's sidebar top: sidebar toggle, back, forward and reload beside the window buttons, and a 36 pt address pill
  showing the site, with Copy URL and Site Settings buttons. Click the pill to open the command bar.
- Arc-style sidebar rows: 36 pt rounded pills with Arc's selected, hover and multi-select colours (and a soft
  shadow on the selected tab in light mode); Pinned and Today headers are plain labels and tabs under them aren't
  indented.
- Arc's bottom bar: Archive at the left, one icon per Space (its emoji, or a dot) to switch Spaces, and a "+"
  menu for New Tab, New Folder and New Space. Hidden with only one Space, as in Arc.
- Arc's Space title row replaces the Space drop-down: the Space's icon and name (double-click to rename) and a
  "..." menu with Rename, Edit Theme Color, Change Space Icon, New Space and Delete Space.
- Folders open and close with a single click and show a chevron instead of the macOS triangle; rows darken while
  pressed; a hairline separates Pinned from Today, as in Arc.
- New "Look and feel" section on the parity checklist.
- The self-test runs hidden and never takes focus.

## 0.11.0
- Site prompts: NotArc asks before a site uses your camera, microphone, location, notifications, clipboard and more,
  with "Remember for this site". Links that open other apps (email, Zoom, ...) ask "Open <App>?" first.
- Site Settings (View > Site Settings..., Cmd+Shift+I): connection security, Ask/Allow/Block per permission, Clear
  Cookies and Refresh, Reset Permissions.
- PDFs open in the built-in viewer, now covered by the self-test.

## 0.10.0
- Command bar suggestions: open and pinned tabs in any Space, Spaces, history, menu commands and top sites; picks rank
  higher next time.
- Toolbar mode (View > Show Toolbar, Cmd+Shift+S) with the full editable address; View > Hide Space Header.
- Undo after closing a Peek (toast, Cmd+Z, File > Reopen Closed Peek).
- Little Window: Move to Space menu.

## 0.9.0
- Crashed tabs show a Reload view; frozen pages get a Page Unresponsive sheet (Wait or Exit Page).
- Session restore: each Space reopens on its last tab; after a crash or force-quit, open tabs are reloaded.
- Sidebar multi-select with bulk actions; New Nested Folder.

## 0.8.0
- Space themes (colour or gradient, presets, intensity) and Space emoji icons.
- Hover cards on sidebar tabs.
- Media controls: speaker icon, sidebar media bar, Mute Tab (Cmd+Shift+M).

## 0.7.0
- Clear Browsing Data (Cmd+Shift+Delete) and Clear Cookies and Refresh.
- Copy Clean Link; duplicate folders; Undo Close Tab (Cmd+Z).

## 0.6.0
- Downloads window (Cmd+Shift+J) and download folder setting.
- Pinned tabs remember their address (reset, replace, Close and Keep Pinned).
- Paste and Go, Print, Ctrl+Tab, Cmd+9; full screen and Focus Mode.

## 0.5.0
- Automatic updates from GitHub Releases, SHA-256 verified, with Install and Relaunch.

## 0.4.0
- Settings window (auto-archive, search engine, Peek and Little Window options).
- Right-click menus for sidebar items and links; History (Cmd+Y).

## 0.3.0
- Split view as one sidebar item, panes on any side, draggable dividers, saved across restarts.
- Arc's keyboard shortcuts; Shift-click Peek; create, rename, delete and reorder Spaces.

## 0.2.0
- Split view (up to 4 panes), Little Window, Peek.
- Back/forward, reload, zoom, find in page, DevTools, Copy URL.

## 0.1.0
- First preview: sidebar with Spaces, Favorites, Pinned and Today; separate logins per Space; folders, drag and drop,
  pin/unpin; command bar; auto-archive and Archive; import from Arc.
