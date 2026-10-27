# Changelog

All NotArc releases are on [GitHub Releases](https://github.com/Donnadieu/notarc/releases). Apple Silicon, macOS 13
or later. From 0.5.0 on, NotArc updates itself.

## Unreleased
- Capture (File > Capture): Capture Area (Shift+Cmd+3, drag a box), Capture Visible Page, Capture Full Page and Capture in Portrait Mode (on a padded background in the Space's colour). Each capture is copied and saved to Downloads, with Add to Easel offered.
- Call controls: when a page uses your camera or microphone, the sidebar bar shows mute and camera-off buttons (red when off) that work from any Space; the bar returns to normal when the call ends.

## 0.17.0
- AppleScript: scripts can list windows, Spaces and tabs, read a tab's title, URL and loading state, open, select, close, reload and navigate tabs, run JavaScript in a tab, and switch Spaces. The terms match Arc's, so most Arc scripts work after changing the app name.
- Fixed: the app's Info.plist had an empty executable name and bundle name.
- Keyboard Shortcuts (NotArc menu > Keyboard Shortcuts...): change, remove or reset the shortcut of any menu command. A combination already in use moves to the new command. Saved and applied at launch.

## 0.16.0
- File > Import Bookmarks...: bookmarks from Chrome, Brave, Edge, Vivaldi or Chromium (each profile listed), or a bookmarks HTML file exported from Safari or Firefox, land as a folder in the current Space's Pinned tabs.
- Incognito windows (File > New Incognito Window, Cmd+Shift+N): dark, with their own in-memory profile shared by open Incognito windows and wiped when the last one closes. Nothing goes to History, the Archive or disk, and you stay signed out of your Spaces' accounts.
- Air Traffic Control editor (Settings > Links > Air Traffic Control...): add, change and remove link rules, pick the Space or Little Window, and set where everything else goes. It replaces the "Links from other apps open in a Little Window" checkbox.
- Air Traffic Control: links opened from other apps follow your Arc link rules (by URL or by the app they came from) into the right Space or a Little Window. Your rules come over from Arc on first launch.
- Two-finger swipe on the trackpad goes back or forward, with an arrow at the page edge, following the macOS "Swipe between pages" setting.
- Unread badges on Favorites: a red count on the tile when the site puts one in its title (Gmail, Slack, LinkedIn, X, Outlook). Right-click a Favorite > Show Unread Badge turns it off for that tab.

## 0.15.0
- One button for Arc: the first time NotArc opens it offers "Bring everything over from Arc?" (also File > Import Everything from Arc...), adding history and extensions on top of the Spaces, tabs and logins that already come over.
- File > Import Extensions from Arc copies your Spaces' Arc extensions into NotArc (newest version, same IDs); they load with Chrome-style pages. Old Manifest V2 extensions such as uBlock Origin are skipped, with uBlock Origin Lite suggested.
- Groundwork for Chrome extensions, password filling and autofill: pages can run in Chromium's full Chrome mode (off by default; `defaults write io.github.donnadieu.notarc chromePages -bool YES` to try it).
- File > Import History from Arc brings each Space's Arc history (newest 20,000 visits) into History (Cmd+Y), tagged with its Space. Running it again adds nothing twice.
- The sidebar now looks like Arc's: the default indigo background, Favorites as icon tiles, real site icons on every tab, the Space name above a "+ New Tab" row, Arc's row spacing and text colours, and window buttons lined up with the sidebar icons.
- Profiles: the Space menu (right-click the Space name, or "...") > Profile moves a Space to another profile, with its own logins and Favorites, or makes and renames profiles. Your Arc profile names come over on first launch.
- Logins now survive quitting and reopening NotArc, including sites that sign you in only for the session.
- Live Folders: the + menu > New Live Folder... makes a folder that fills itself from an RSS or Atom feed, or from a
  GitHub repository's open pull requests (or issues, with /issues). It refreshes every 15 minutes (or Refresh Live
  Folder); tabs you've opened stay put, and Remove from Live Folder keeps an entry from coming back.
- Easels: File > New Easel or the + menu adds a canvas to Today. File > Capture to Easel (Cmd+Shift+2) drops a
  picture of the page you're on into your latest easel, linked back to the page (double-click it to open). Double-click
  the canvas to add text; drag things around; Delete removes them. Easels are saved on your Mac and archive like tabs.

## 0.14.0
- Notes: File > New Note (Cmd+Ctrl+N) or the + menu adds a rich-text note to the top of Today. It is named from
  its first line, saved on your Mac as you type, and archived when closed like a tab. Format menu: bold, italic,
  underline, size, fonts and lists.
- Boosts: a Boost button in the address pill (filled and tinted when the site has a Boost on); Option-click while
  zapping hides every element like it; Shuffle picks a random colour and font.

## 0.13.0
- Boosts: customise any site (View > Boost This Site..., Cmd+Opt+B): tint its colours, change the font, text size
  and case, zap elements you don't want (View > Zap Element), and add your own CSS and JavaScript. Boosts are saved
  on your Mac and apply to the site and its subdomains every time a page loads; turn one off from the View menu.
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
