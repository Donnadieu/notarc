# Feature parity with Arc 1.169

54 done, 19 partial, 14 not started or out of scope, of 87 items.

Arc behaviour NotArc needs to match. Each item is implemented from scratch. Each line links its GitHub issue (#N); a checked line's issue is closed. Lines without a number were done before
issues were opened, or are out of scope. Status as of NotArc 0.11.0; see
[CHANGELOG.md](../CHANGELOG.md) for what each release added.

## Look and feel
- [ ] Window frame: no title bar, page as a rounded card inset on the Space colour, 273 pt sidebar (partial: inset and radius measured from screenshots; confirm with on-screen measurement) (#122)
- [x] Sidebar top: window buttons, sidebar toggle, back/forward/reload, address pill with site buttons (#123)
- [x] Sidebar rows: Arc-style tab, folder and section rows with Arc's hover, selected and pressed colours (#124)
- [x] Space switcher icons at the bottom of the sidebar, archive button and "+" menu (#125)
- [ ] Space-switch slide and page card pop animations (partial: sidebar slides left/right when switching Spaces, page card pops when the tab changes, both off with Reduce Motion; durations and curves estimated, to match against a recording of Arc) (#126)
- [ ] Command bar styling (Arc's colours, row layout, selected row) (partial: rounded translucent card, Arc's text colours, selected row as an Arc-blue pill, icon per row, hairline under the field; exact row layout to confirm against a screenshot of Arc's command bar) (#127)
- [x] Light and dark appearance: Arc's light and dark colours everywhere, following macOS or set per Space (#128)

## Sidebar & tabs

- [x] Vertical sidebar with Favorites (Top Apps), Pinned, Today
- [x] Folders, nested folders, drag and drop (New Folder, New Nested Folder, New Folder with selected items, drag into and between folders) (#12)
- [ ] Pin/unpin (Cmd+D), Move to Pinned/Today/Top Apps (partial: pin/unpin and Move to Pinned/Today of another Space done; Top Apps moves missing) (#13)
- [x] Rename tab / item (#14)
- [x] Duplicate tab / duplicate folder (#15)
- [x] Archive tab, Archive Other Tabs / Above / Below, Clear Today tabs (#16)
- [x] Close and Keep Pinned; reset pinned tab to its saved URL (also Replace Pinned URL with Current, Reset All Pinned Tabs) (#17)
- [ ] Tidy tab titles (missing) (#18)
- [ ] Hover previews / hover cards on sidebar items (partial: hover card with title, site, state, last used and address; page thumbnail missing) (#19)
- [x] Unread badge on tabs (#20)
- [x] Go to Sidebar Item 1-9, last item, next/previous item (Cmd+1-8, Cmd+9 last, Cmd+Opt+Up/Down) (#21)
- [x] Hide/show sidebar, toolbar mode with full URL (Cmd+S sidebar; View > Show Toolbar (Cmd+Shift+S) with back/forward/reload and the full editable URL) (#22)
- [x] Multi-select sidebar items and bulk actions (Cmd/Shift-click; Copy Links, Copy Links as Markdown, New Folder with N Items, Pin/Unpin Selected, Move to Space, Archive N Tabs) (#23)
- [x] Copy URL, Copy URL as Markdown, copy links as Markdown, clean URL (#24)
- [x] Undo close (Cmd+Z in sidebar, Edit/File > Undo Close Tab), reopen closed tab (Cmd+Shift+T) (#25)

## Spaces & profiles

- [x] Multiple Spaces with switcher
- [x] Separate profile per Space (cookies, logins)
- [x] Create / delete / reorder Spaces
- [ ] Space themes: colours, gradients, icons/emoji (Space style editor) (partial: per-Space colour or two-colour gradient with intensity, preset palettes, emoji icon; grain and per-Space light/dark missing) (#26)
- [ ] Swipe / Ctrl+number to switch Spaces (partial: Ctrl+1-9 and Cmd+Opt+arrows done; trackpad swipe missing) (#27)
- [x] Create/rename Profiles, assign Space to Profile (#28)
- [x] Show/hide Space header, search Spaces (View > Hide/Show Space Header; Spaces appear in command bar results) (#29)

## Command bar & navigation

- [x] Command bar: new tab, go to URL, search (Cmd+T new tab, Cmd+L current tab)
- [x] Suggestions: open tabs, history, bookmarks, actions, top domains (open and pinned tabs in every Space, Spaces, history, menu actions, top sites when empty; arrow keys + Enter) (#30)
- [x] Search engine choice, search suggestions (#31)
- [x] Switch to a recent tab (Ctrl+Tab) (#32)
- [x] Back/forward, reload, find in page, zoom, print (#33)
- [x] Link routing rules (which Space opens which links): Air Traffic Control, Arc rules imported, rule editor (#34)
- [x] Command bar ranking that learns from what you pick (#35)
- [x] Paste and Go (Edit menu) (#36)

## Split view & windows

- [ ] Split view: vertical/horizontal, up to 4 panes, add/close/move panes (partial: add in all four directions, flip layout, close and focus panes, split as one sidebar item, draggable dividers and saving splits done; dragging a tab into the page to split and maximize pane missing) (#37)
- [x] Switch between split views; share split view: Focus Next/Previous Pane with wraparound; Share Split View copies every pane's address (Arc's arc.net links are gone), and pasting 2-4 addresses opens them as one split (#38)
- [x] Multiple windows, move tab to window, Move to main window: File > New Window, one shared sidebar, Move to New Window / Move to Main Window without reloading (Chrome-style pages too), Today-header button, windows reopen after restart (#39)
- [x] Incognito window (#40)
- [x] Full screen, focus mode (Ctrl+Cmd+F full screen; Cmd+Opt+Shift+F focus mode hides sidebar and window buttons) (#41)

## Little Arc & Peek

- [ ] Little Arc (mini browser for external links, global hotkey) (partial: Little Window for links from other apps (can be turned off), Cmd+Opt+N, archived on close or when idle (default 6 hours); global hotkey and modifier-click missing) (#42)
- [x] Open in main window / move to Space from Little Arc (Open in NotArc, or the Move to Space menu next to it) (#43)
- [ ] Peek: preview links from pinned/favourite sites, email peeking (partial: links leaving a Pinned tab or Favorite's site and Shift-clicked links open in Peek; Open as Tab; Undo after closing a Peek (toast, Cmd+Z, File > Reopen Closed Peek); email peeking missing) (#44)

## Media

- [x] Media controls in sidebar (play/pause, mute): speaker icon on playing tabs, media bar for the playing tab, Mute Tab (Cmd+Shift+M), sidebar menu Pause/Play Media (#45)
- [x] Automatic picture-in-picture, mini player (#46)
- [x] Toggle microphone/camera for calls (#47)

## Content tools

- [x] Capture: area, full page, portrait mode; save/copy screenshot (#48)
- [ ] Easel (canvas of captures, text, live web clips) (partial: File > New Easel and the + menu add an easel to Today; File > Capture to Easel (Cmd+Shift+2) adds a capture of the visible page, linked to its source, to the most recent easel; text boxes (double-click the canvas); drag to move, Delete to remove; saved locally, archived and reopened like tabs. Missing: live web clips, region and full-page capture, drawing (arrows, shapes, freehand), resizing; sharing is out of scope) (#49)
- [ ] Notes (rich-text documents in the sidebar) (partial: File > New Note (Cmd+Ctrl+N) and the + menu create a note at the top of Today; rich-text editor in the page card (bold, italic, underline, fonts, lists via Format menu), titled from its first line, autosaved locally, archived on close and reopened from the archive. Missing: Arc's note styling and toolbar, notes in split view, Markdown export; sharing is out of scope) (#50)
- [ ] Boosts: custom CSS/JS per site, zap elements, boost editor (partial: per-site Boosts saved locally and applied on every page load, including subdomains: colour tint, font, text size, upper/lower case, zaps (Option-click zaps all related elements), custom CSS and JavaScript; editor panel with Shuffle; Boost indicator in the address pill; on/off. Missing: Arc's editor look and colour wheel; sharing is out of scope) (#51)
- [ ] Translate page (missing) (#52)
- [ ] Ad blocking / content blocking (missing) (#53)
- [x] Site control center (per-site permissions, clear cookies and refresh) (View > Site Settings, Cmd+Shift+I: connection security, Ask/Allow/Block for camera, mic, location, notifications, clipboard; Clear Cookies and Refresh; Reset Permissions) (#54)

## Live content

- [ ] Live Folders (GitHub PRs/issues, RSS etc. as auto-updating folders) (partial: + menu > New Live Folder... from an RSS/Atom feed or a public GitHub repository's open pull requests or issues; refreshes every 15 minutes and on demand, keeps open tabs, adds new entries and drops old ones; Remove from Live Folder keeps an entry from coming back; saved with the sidebar. Missing: Arc's automatic GitHub folder for your own PRs (needs a GitHub sign-in), YouTube and other sources, unread badges) (#55)
- [ ] Calendar integration: next meeting, meeting link (missing) (#56)
- [ ] Notion / Slack / Gmail integrations in Favorites (missing) (#57)

## AI (Arc Max)

- [ ] Ask on page, ChatGPT in command bar, tidy titles, 5-second previews (missing (needs an LLM provider)) (#58)
- [ ] On-device tab categorisation and page summaries / page-to-Markdown (missing) (#59)

## Library & data

- [x] Archive with search
- [x] Auto-archive (6h/12h/24h/7d/30d/never, in Settings) (#60)
- [x] Downloads list (Cmd+Shift+J: progress, filter, Open, Show in Finder, Copy, Cancel; download folder setting; quit warning) (#61)
- [x] History view (Cmd+Y, searchable, per-Space column, Clear History) (#62)
- [x] Import from Arc (Spaces, tabs, archive, logins)
- [ ] Import from Chrome/Safari/other browsers, password import (missing) (#63)
- [x] Clear browsing data (time range; history, cookies, cache across all Spaces; Clear Cookies and Refresh for the current site) (#64)
- [ ] Tab thumbnails for switchers and previews (missing) (#65)

## Browser basics

- [ ] Chrome extensions (Web Store), extension picker (missing) (#66)
- [ ] Password saving/autofill, address/card autofill (missing) (#67)
- [ ] DevTools (show/hide), developer mode (partial: DevTools done) (#68)
- [x] Set as default browser, open links from other apps (#69)
- [ ] Context menus (page, link, image, sidebar) (partial: sidebar menu and NotArc link actions done; image actions are Chromium defaults) (#70)
- [x] Sad tab / crash recovery, session restore (crashed-tab Reload view; each Space reopens on its last tab; after an app crash or force-quit the open tabs are reloaded) (#71)
- [ ] Settings window (all preferences) (partial: search engine, auto-archive, Peek and Little Window link options; profiles, appearance, Max and advanced panes missing) (#72)
- [x] Keyboard shortcuts with user overrides (#73)
- [ ] App icon choice, sound effects, toasts (missing) (#74)
- [x] PDF viewer (Chromium's built-in viewer: PDFs open in the tab with zoom, search, print and download) (#75)
- [x] AppleScript support for windows and tabs (#76)
- [ ] Two-finger swipe back/forward and overscroll (partial: swipe tracking with an edge arrow, follows the macOS "Swipe between pages" setting; to confirm with a real trackpad) (#77)
- [ ] Web notifications, permission prompts, external app (protocol) dialogs (partial: sheets for camera, mic, location, notifications and other permissions, plus "Open <App>?" for links to other apps; "Remember for this site"; View > Reset Site Permissions; showing web notifications in macOS Notification Center not verified) (#78)
- [x] Hung page / unresponsive renderer dialog (Page Unresponsive sheet: Wait or Exit Page) (#79)
- [x] Import bookmarks: Chrome, Brave, Edge, Vivaldi, Chromium directly; Safari and Firefox via their bookmarks HTML export (#80)

## Sync & sharing (Arc account)

- [ ] Sidebar sync across Macs (out of scope for v1 (Arc used its own servers))
- [ ] Share folders/Spaces/Easels via link (out of scope for v1)

## Install & updates

- [x] Downloadable app from GitHub Releases
- [x] Automatic update check and install (daily check of GitHub Releases, SHA-256 verified, Install and Relaunch; Check for Updates... in the app menu; works from 0.5.0 on) (#81)
