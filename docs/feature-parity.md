# Feature parity with Arc 1.169

85 done, 1 partial, 0 not started, of 86 items.

Arc behaviour NotArc needs to match. Each item is implemented from scratch. Each line links its GitHub issue (#N); a
checked line's issue is closed. Lines without a number were done before issues were opened. Status as of NotArc 0.24.0;
see [CHANGELOG.md](../CHANGELOG.md) for what each release added. Things NotArc deliberately won't copy are listed under
[Out of scope](#out-of-scope) at the end, with the reason, and aren't counted. Every scope call is recorded in
[decisions.md](decisions.md).

## Look and feel
- [x] Window frame: no title bar, page as a rounded card (10/9/9 pt inset, 8 pt corners) on the Space colour with a hairline edge and a soft shadow in light mode, 273 pt sidebar (#122)
- [x] Sidebar top: window buttons, sidebar toggle, back/forward/reload, address pill with site buttons (#123)
- [x] Sidebar rows: Arc-style tab, folder and section rows with Arc's hover, selected and pressed colours; Favorites tile grid, Space title and "+ New Tab" row, 41 pt rows (#124)
- [x] Space switcher icons at the bottom of the sidebar, archive button and "+" menu (#125)
- [x] Space-switch slide and page card pop animations: the sidebar slides left/right when switching Spaces, the page card pops when the tab changes, both off with Reduce Motion (#126)
- [x] Command bar styling: rounded translucent card, Arc's text colours, selected row as an Arc-blue pill, an icon per row, hairline under the field (#127)
- [x] Light and dark appearance: Arc's light and dark colours everywhere, following macOS or set per Space (#128)

## Sidebar & tabs

- [x] Vertical sidebar with Favorites (Top Apps), Pinned, Today
- [x] Folders, nested folders, drag and drop (New Folder, New Nested Folder, New Folder with selected items, drag into and between folders) (#12)
- [x] Pin/unpin (Cmd+D), Move to Pinned/Today/Top Apps: Move to > Favorites or another Space's Pinned/Today, Remove from Favorites, Move to Pinned, File > Add to / Remove from Favorites (also in the command bar) (#13)
- [x] Rename tab / item (#14)
- [x] Duplicate tab / duplicate folder (#15)
- [x] Archive tab, Archive Other Tabs / Above / Below, Clear Today tabs (#16)
- [x] Close and Keep Pinned; reset pinned tab to its saved URL (also Replace Pinned URL with Current, Reset All Pinned Tabs) (#17)
- [x] Tidy tab titles, on the Mac without AI: pinning gives a tab a short name (no unread counts, site name or e-mail address), with an Undo toast, Tidy Title / Use Page Title in the tab menu and a setting (#18)
- [x] Hover previews / hover cards on sidebar items (title, site, state, last used, address and a picture of the page) (#19)
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
- [x] Space themes: colours, gradients, icons/emoji (Space style editor): per-Space colour or two-colour gradient with intensity and grain, preset palettes, emoji icon, per-Space light/dark (#26)
- [x] Swipe / Ctrl+number to switch Spaces: Ctrl+1-9, Cmd+Opt+arrows, and a two-finger swipe over the sidebar (follows the macOS "Swipe between pages" setting) (#27)
- [x] Create/rename Profiles, assign Space to Profile (#28)
- [x] Show/hide Space header, search Spaces (View > Hide/Show Space Header; Spaces appear in command bar results) (#29)

## Command bar & navigation

- [x] Command bar: new tab, go to URL, search (Cmd+T new tab, Cmd+L current tab)
- [x] Suggestions: open tabs, history, bookmarks, actions, top domains (open and pinned tabs in every Space, Spaces, history, menu actions, top sites when empty; arrow keys + Enter) (#30)
- [x] Search engine choice, search suggestions (#31)
- [x] Switch to a recent tab (Ctrl+Tab; held, it shows a switcher with page pictures) (#32)
- [x] Back/forward, reload, find in page, zoom, print (#33)
- [x] Link routing rules (which Space opens which links): Air Traffic Control, Arc rules imported, rule editor (#34)
- [x] Command bar ranking that learns from what you pick (#35)
- [x] Paste and Go (Edit menu) (#36)

## Split view & windows

- [x] Split view: vertical/horizontal, up to 4 panes, add/close/move panes: add in all four directions, flip layout, close and focus panes, split as one sidebar item, draggable dividers, saved splits, drag a sidebar tab onto the page to split on that side, Maximize Pane (Cmd+Shift+Return) (#37)
- [x] Switch between split views; share split view: Focus Next/Previous Pane with wraparound; Share Split View copies every pane's address, and pasting 2-4 addresses opens them as one split (#38)
- [x] Multiple windows, move tab to window, Move to main window: File > New Window, one shared sidebar, Move to New Window / Move to Main Window without reloading (Chrome-style pages too), Today-header button, windows reopen after restart (#39)
- [x] Incognito window (#40)
- [x] Full screen, focus mode (Ctrl+Cmd+F full screen; Cmd+Opt+Shift+F focus mode hides sidebar and window buttons) (#41)

## Little Arc & Peek

- [x] Little Arc (mini browser for external links, global hotkey): Little Window for links from other apps (can be turned off), Cmd+Opt+N in NotArc and from any app, Cmd+Opt+click on a link or a sidebar tab, Show/Close Little Windows, archived on close or when idle (default 6 hours) (#42)
- [x] Open in main window / move to Space from Little Arc (Open in NotArc, or the Move to Space menu next to it) (#43)
- [x] Peek: preview links from pinned/favourite sites, email peeking: links leaving a Pinned tab or Favorite's site and Shift-clicked links open in Peek; Open as Tab; Undo after closing a Peek; File > Peek Email from This Site copies a sign-in code from your newest Gmail email from the site (or opens the email in a Peek) (#44)

## Media

- [x] Media controls in sidebar (play/pause, mute): speaker icon on playing tabs, media bar for the playing tab, Mute Tab (Cmd+Shift+M), sidebar menu Pause/Play Media (#45)
- [x] Automatic picture-in-picture, mini player (#46)
- [x] Toggle microphone/camera for calls (#47)

## Content tools

- [x] Capture: area, full page, portrait mode; save/copy screenshot (#48)
- [x] Easel (canvas of captures, text, live web clips) (#49)
- [x] Notes (rich-text documents in the sidebar): Arc-style title, reading column and format bar following the Space's light/dark look; notes as split view panes; Export/Copy Note as Markdown (#50)
- [x] Boosts: custom CSS/JS per site, zap elements, boost editor (per-site Boosts saved locally and applied on every page load, including subdomains; Arc-style editor card with a colour wheel and Intensity slider, font tiles, text size, case, Zap and Code; Shuffle; Boost indicator in the address pill; on/off) (#51)
- [x] Translate page: View > Translate Page opens the page through Google's web translator into your macOS language, Show Original goes back, and a page in another language offers a one-tap Translate (#52)
- [x] Ad blocking / content blocking (Settings > Block ads & trackers (off by default) with NotArc's own host list; filter list subscriptions in Manage Ad Blockers... (Settings and Site Settings): EasyList and EasyPrivacy offered, downloaded only when turned on, any list URL can be added, refreshed daily and with Update Now; Adblock Plus "||host^" rules with $third-party, $domain= and type options, "@@" exceptions and "##" cosmetic rules that hide page elements; per-site exceptions listed in the dialog) (#53)
- [x] Site control center (per-site permissions, clear cookies and refresh) (View > Site Settings, Cmd+Shift+I: connection security, Ask/Allow/Block for camera, mic, location, notifications, clipboard; Clear Cookies and Refresh; Reset Permissions) (#54)

## Live content

- [x] Live Folders (GitHub PRs/issues, RSS etc. as auto-updating folders) (+ menu > New Live Folder: GitHub: My Pull Requests (yours and ones waiting for your review, read with the Space's own github.com sign-in; a sign-in entry when the Space isn't signed in), YouTube Channel... (a channel address or @handle, from its public feed), or Feed or GitHub Repository... (RSS/Atom, a public repository's open pull requests or issues); refreshes every 15 minutes and on demand, keeps open tabs, adds new entries and drops old ones; new entries come in unread with a dot, the folder row counts them, opening the tab clears it; Remove from Live Folder; saved with the sidebar) (#55)
- [x] Calendar integration: next meeting, meeting link: from the Mac's Calendar (any calendar added to macOS), a sidebar bar from 10 minutes before a meeting with Join for Zoom/Meet/Teams/Webex links; View > Show Next Meeting from Calendar (#56)
- [x] Gmail and calendar previews for Favorites: hovering a Gmail Favorite lists your newest unread email (the Space's own Gmail sign-in, click to Peek); hovering a calendar Favorite lists today's events (#57)

## AI (Arc Max)

- [x] Ask on page, ChatGPT in command bar, tidy titles, 5-second previews (on-device with Apple's built-in model, non-AI fallbacks without it, tidy titles fall back to #18's rules; ChatGPT through your own chatgpt.com sign-in) (#58)
- [x] On-device tab categorisation and page summaries / page-to-Markdown (Tidy Tabs with Undo, by site without AI; summaries; Copy Page as Markdown works without AI) (#59)

## Library & data

- [x] Archive with search
- [x] Auto-archive (6h/12h/24h/7d/30d/never, in Settings) (#60)
- [x] Downloads list (Cmd+Shift+J: progress, filter, Open, Show in Finder, Copy, Cancel; download folder setting; quit warning) (#61)
- [x] History view (Cmd+Y, searchable, per-Space column, Clear History) (#62)
- [x] Import from Arc (Spaces, tabs, archive, logins)
- [x] Import everything from Arc with one button: Spaces, tabs, Favorites, logins, history, extensions, saved passwords, autofill (#150)
- [x] Import from Chrome/Safari/other browsers, password import (File > Import Bookmarks (#80), Import History and Import Passwords; Safari passwords come in as a CSV export from Apple Passwords, which other apps can't read) (#63)
- [x] Clear browsing data (time range; history, cookies, cache across all Spaces; Clear Cookies and Refresh for the current site) (#64)
- [x] Tab thumbnails for switchers and previews (sidebar hover cards, Ctrl+Tab switcher; in memory only) (#65)

## Browser basics

- [ ] Chrome extensions (Web Store), extension picker (partial: with Chrome-style pages on (Settings, off by default): Install Extension... from a Web Store link or ID (signature checked), a puzzle-piece picker in the address pill (Open, Options, Turn Off/On, Update, Remove, Manage Extensions), File > Import Extensions from Arc. Missing: extensions in the default page mode (CEF's Alloy pages can't run them), popups as bubbles (they open in a tab), and changes without a relaunch) (#66)
- [x] Password saving/autofill, address/card autofill (#67)
- [x] DevTools (show/hide), developer mode (per-site Developer Mode: on by itself for localhost, 127.0.0.1 and .local; full address with port in the sidebar pill, never auto-archived, Developer Tools in the pill; View menu, Site Settings and Settings > Advanced, with a reset) (#68)
- [x] Set as default browser, open links from other apps (#69)
- [x] Context menus (page, link, image, sidebar): sidebar menu; links (new tab, background, split, Peek, Little Window, Markdown); images (open, save to Downloads, copy image, copy address); selected text (search); page (copy URL, Markdown, Capture, Translate, Boost) (#70)
- [x] Sad tab / crash recovery, session restore (crashed-tab Reload view; each Space reopens on its last tab; after an app crash or force-quit the open tabs are reloaded) (#71)
- [x] Settings window (all preferences): General, Profiles, Appearance, Links, Max and Advanced panes, as in Arc (#72)
- [x] Keyboard shortcuts with user overrides (#73)
- [x] App icon choice, sound effects, toasts (six NotArc icons in Settings > Appearance, shown in the Dock; toasts; Capture shutter sound and reorder haptics with their settings) (#74)
- [x] PDF viewer (Chromium's built-in viewer: PDFs open in the tab with zoom, search, print and download) (#75)
- [x] AppleScript support for windows and tabs (#76)
- [x] Two-finger swipe back/forward and overscroll: swipe tracking with an edge arrow over the page, follows the macOS "Swipe between pages" setting (#77)
- [x] Web notifications, permission prompts, external app (protocol) dialogs: sheets for camera, mic, location, notifications and other permissions, "Open <App>?" for links to other apps, "Remember for this site", View > Reset Site Permissions; notifications from allowed sites show in macOS Notification Center and open their tab when clicked (#78)
- [x] Hung page / unresponsive renderer dialog (Page Unresponsive sheet: Wait or Exit Page) (#79)
- [x] Import bookmarks: Chrome, Brave, Edge, Vivaldi, Chromium directly; Safari and Firefox via their bookmarks HTML export (#80)

## Install & updates

- [x] Downloadable app from GitHub Releases
- [x] Automatic update check and install (daily check of GitHub Releases, SHA-256 verified, Install and Relaunch; Check for Updates... in the app menu; works from 0.5.0 on) (#81)

## Out of scope

Not built on purpose. These aren't counted above; the reasons are in [decisions.md](decisions.md).

- Sidebar sync across Macs: Arc synced through its own servers and Arc accounts; NotArc keeps everything on your Mac and runs no server.
- Sharing folders, Spaces, Easels, Notes, Boosts and split views by link: Arc's share links lived on arc.net; NotArc has no server to host them (Share Split View copies the addresses instead, #38).
- Translating pages in place with Chromium's translate engine: CEF doesn't ship it, and Google's translation API needs a paid key; NotArc uses Google's free web translator instead (#52).
- Notion and Slack previews on Favorites: Arc read them through Notion's and Slack's private internal web APIs; NotArc can't build and test against those without accounts on both, and their unread counts already show as badges (#20).
- An Arc account, Arc membership and Arc's own cloud AI service: NotArc's AI features run on your Mac (#58, #59).
