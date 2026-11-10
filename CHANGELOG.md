# Changelog

All NotArc releases are on [GitHub Releases](https://github.com/Donnadieu/notarc/releases). Apple Silicon, macOS 13
or later. From 0.5.0 on, NotArc updates itself.

## 0.26.1
- The Dock shows NotArc's own icon (the gold "¬" on indigo, the same one Finder shows) instead of a colourway from
  the icon picker. It's now the first choice in Settings > Appearance and the default; a colourway saved by an older
  version is cleared once, and anything you pick after that is kept.
- Import Everything from Arc now brings your logins over every time you run it: it copies each Space profile's Arc
  cookies again (Arc's newest sessions win), with their expiry, domain, path, Secure, HttpOnly and SameSite kept,
  and tells you how many came over. Before, logins were copied only once, the first time each Space opened, so
  sessions Arc renewed later never reached NotArc. It also reads Arc's key once for passwords and cookies, and when
  something can't come over (macOS said no to Arc's key, NotArc's own vault is locked, a profile has no Arc files)
  it says so in plain words instead of showing 0.
- The "Bring everything over from Arc?" offer shows at launch whenever Arc's data is there and you haven't imported
  or chosen Not Now yet. Older test and development launches could mark it as offered without it ever showing.
  The button is also in Settings > Profiles.

## 0.26.0
- NotArc is now signed with an Apple Developer ID and notarized by Apple, so macOS opens the download without asking
  you to allow it in System Settings. The first launch after updating, macOS may ask once more for the Keychain item
  NotArc keeps your cookies and passwords locked with, and for permissions you gave before (Calendar,
  notifications): click **Always Allow** / **Allow**.
- Chrome extensions: an extension's popup opens in a bubble under the puzzle-piece button in the address pill,
  sized to the popup, instead of in a tab; Esc or a click outside closes it. After installing, updating, removing or
  turning an extension on or off, a toast offers Relaunch Now (extensions load when NotArc starts, and your tabs come
  back). Installing or importing extensions turns on Chrome-style pages, which extensions need.
- NotArc has its own app icon: a marigold ¬ on indigo night (source files in assets/brand).

## 0.25.0
- Tab thumbnails: sidebar hover cards show a small picture of the page as it last looked, and holding Ctrl+Tab
  opens a switcher of your recent tabs with their pictures (Tab or Shift+Tab to move, let go of Ctrl to switch, Esc
  to cancel). Pictures stay in memory only and need macOS 14.4 or later.
- Notes look like Arc's: the first line is a large title, text sits in a centred reading column, and a format bar
  offers paragraph styles (Body, Heading 1-3), bold, italic, underline, strikethrough, bulleted and numbered lists,
  checklists and links (also in the Format menu). It follows the Space's light or dark look.
- Notes in split view: Split View > New Note in Split View opens a note beside the page, and Add Split from a note
  opens a page beside it. Open in Split View on a note moves that note into the split.
- File > Export Note as Markdown... saves the note as a .md file; Copy Note as Markdown copies it.
- Live Folders: + menu > New Live Folder > GitHub: My Pull Requests shows your open pull requests and the ones waiting
  for your review, using the Space's own github.com sign-in (no token). YouTube Channel... follows a channel by its
  address or @handle. New entries come in unread (a dot on the tab, a count on the folder) until you open them.
- Boost editor redesigned after Arc's: a compact card with a colour wheel (drag for hue and how colourful, with an
  Intensity slider), font tiles, text size, text case (now also Title Case), Zap and Code. Dragging the wheel
  previews on the page as you go and saves when you let go.
- Settings has panes like Arc's: General, Profiles (every profile with its Spaces; new and rename), Appearance (Light,
  Dark or Automatic for Spaces, and the app icon), Links and Advanced (Chrome-style pages, Developer Mode, Clear
  Browsing Data, Reset All Settings).
- App icon: pick one of six NotArc icons in Settings > Appearance. It shows in the Dock while NotArc is open.
- Developer Mode, per site as in Arc: on by itself for localhost, 127.0.0.1 and .local sites, and for any site from
  View > Turn On Developer Mode for This Site or Site Settings. The sidebar shows the full address with its port, the
  tab is never auto-archived, and Developer Tools is one click away in the address pill. View > Reset Developer Mode
  Sites forgets the sites you turned on.
- Max, NotArc's take on Arc Max, runs on your Mac with Apple's built-in model (macOS 26 with Apple Intelligence on):
  View > Ask on Page... (Cmd+Shift+A) answers questions from the page, View > Summarize Page, Shift + point at a link
  for a short preview of it, Tabs > Tidy Today Tabs sorts Today's tabs into topic folders (Undo puts them back), and
  tidy tab titles come from the model. Without Apple Intelligence each falls back to a non-AI version (best-matching
  sentences, key sentences, folders by site, the built-in title rules). The command bar offers "Ask ChatGPT" for questions (opens chatgpt.com
  with your own sign-in), and Edit > Copy Page as Markdown copies any page as Markdown. Settings > Max has the
  switches. Nothing goes to a NotArc server.
- Passwords and autofill: NotArc offers to save a password when you sign in (Save, Never for This Site, or Update
  when it changed), and clicking into a login, address or card field shows your saved entries to fill in. Edit >
  AutoFill > Fill Password (Cmd+\\) fills the page's login. NotArc > Passwords... lists them, with Add, and Show and
  Copy behind Touch ID or your Mac's password. Everything is stored encrypted on your Mac.
- File > Import Everything from Arc now brings your saved passwords, addresses and cards too, and File > Import
  Passwords... brings them from Chrome, Brave, Edge, Vivaldi, Chromium or a passwords CSV file (Safari: export from
  Apple's Passwords app first).
- Chrome extensions (with Chrome-style pages on): a puzzle-piece button in the sidebar's address pill lists your
  extensions, with Open (its popup page, in a tab), Options, Turn Off/On, Update and Remove, plus Install
  Extension..., Chrome Web Store and Manage Extensions (chrome://extensions). File > Install Extension... takes a
  Chrome Web Store link or extension ID, downloads it from the Web Store and checks its signature before installing.
  Changes take effect when NotArc relaunches (one click; your tabs come back). Settings has a new "Use Chrome-style
  pages" switch, still off by default. Installing asks the Chrome Web Store (Google) for the extension's package.
- Ad blocking: Manage Ad Blockers... (Settings and Site Settings) lets you subscribe to filter lists such as
  EasyList and EasyPrivacy (downloaded only when you turn them on, refreshed daily or with Update Now) or any list by
  address. Lists block ad and tracker requests and hide ad elements on pages. The built-in list can be turned off, and
  the sites where blocking is off are listed with a Remove button.
- Easels: draw arrows, rectangles, ellipses and freehand pen strokes in eight colours (tool bar over the canvas, or
  V/T/A/R/O/P; Esc goes back to Select); drag the corner handles to resize anything (captures keep their shape).
  File > Capture Area to Easel and Capture Full Page to Easel. File > Add Live Clip to Easel: drag over part of a page
  and the clip keeps the address and that area; it refreshes when you open the easel (if older than a minute) and from
  File > Refresh Live Clips.

## 0.24.0
- Favorites: Move to > Favorites for any tab, and Remove from Favorites / Move to Pinned on a Favorite (also from the
  File menu and the command bar).
- Tidy tab titles: pinning a tab gives it a short, clean name ("Pull requests" instead of "Pull requests · GitHub"),
  on your Mac, with Undo. Tab menu: Tidy Title / Use Page Title. Settings checkbox to turn it off.
- Fixed: a renamed tab went back to the page's title when the page changed it or after a restart.
- Light mode: the page card has a hairline edge and a soft shadow, as in Arc.
- Space themes: a Grain slider in Edit Theme Color.
- Two-finger swipe over the sidebar switches Spaces.
- Next meeting: turn on View > Show Next Meeting from Calendar (or the Settings checkbox) and the sidebar shows your
  next meeting from the Mac's Calendar 10 minutes before it starts, with Join for Zoom, Meet, Teams and Webex links.
- Favorite previews: hover a Gmail Favorite for your newest unread email, or a calendar Favorite for today's events.
- Web notifications from sites you allowed now show in Notification Center; clicking one opens its tab.
- Split view: drag a tab from the sidebar onto the page to split on that side; Maximize Pane (Cmd+Shift+Return).
- Little Windows: Cmd+Option+N opens one from any app; Cmd+Option+click a link or a sidebar tab opens it in one;
  File > Show / Close Little Windows. Both keys can be turned off in Settings.
- A page in another language offers a one-tap Translate (Settings to turn it off).
- Right-click menus: images (open, save, copy, copy address), selected text (search) and the page itself (copy URL,
  Markdown, Capture, Translate, Boost).
- File > Peek Email from This Site: finds the newest email the site just sent you in Gmail (in this Space's Gmail
  sign-in), copies the sign-in code or opens the email in a Peek.
- The parity checklist is up to date with 0.23.0, with an Out of scope section and docs/decisions.md for every
  scope call.

## 0.23.0
- File > Import History...: brings your browsing history from Chrome, Brave, Edge, Vivaldi, Chromium, Firefox or Safari
  (Safari needs Full Disk Access for NotArc) into History
  and the command bar. The other browser isn't changed; importing twice adds nothing twice.

## 0.22.0
- Sound effects: Capture plays a shutter sound (Settings > Play sound effects). Reordering tabs in the sidebar gives a
  trackpad tick (Settings > Haptic feedback when reordering tabs). Both on by default.
- Block ads & trackers (Settings, off by default): stops pages loading ads and trackers from well-known ad and tracking
  services. Site Settings has a per-site switch to turn it off for one site.

## 0.21.0
- Translate Page (View menu): opens the page through Google's web translator into your macOS language; Show Original
  goes back. Nothing is sent to Google unless you choose it.
- Split view: Focus Previous Pane (Ctrl+Shift+[) next to Focus Next Pane, both wrapping around. Share Split View copies
  every pane's address; pasting two to four addresses into the command bar opens them as one split.
- Multiple windows: Chrome-style pages (Settings, off by default) also move between windows without reloading.

## 0.20.0
- Multiple windows: File > New Window (Cmd+N) opens a window on your current Space. Every window shares the same sidebar
  (Spaces, pinned, Today) and stays signed in; each has its own Space and tab. Move to New Window and Move to Main Window
  (tab menu, and a button in other windows' Today header) move the page without reloading it. Windows open when you
  quit come back next launch; a window you close keeps its tabs in the sidebar.

## 0.19.0
- Default browser: Settings shows which app opens your links and has a Make NotArc Default Browser button (macOS confirms). On first launch NotArc asks once, after the Arc import question.
- Search suggestions: the command bar lists up to three suggestions from your search engine under Go (Google, DuckDuckGo, Bing, Ecosia or Kagi). Not sent for typed addresses or from Incognito, no cookies sent; Settings checkbox, on by default.

## 0.18.0
- Automatic picture-in-picture: a video playing in the tab you leave pops out into a floating window and goes back when you return (Settings > Links checkbox, on by default). The sidebar media bar stays the mini player.
- Self-tests: the end-of-run snapshot waits for the last page checks to finish.
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
