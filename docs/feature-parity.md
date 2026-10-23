# Feature parity with Arc 1.169

20 done, 17 partial, 43 not started or out of scope, of 80 items.

Arc behaviour NotArc needs to match. Each item is implemented from scratch.

## Sidebar & tabs

- [x] Vertical sidebar with Favorites (Top Apps), Pinned, Today
- [ ] Folders, nested folders, drag and drop (partial: nested folders and New Folder from Selection missing)
- [ ] Pin/unpin (Cmd+D), Move to Pinned/Today/Top Apps (partial: pin/unpin and Move to Pinned/Today of another Space done; Top Apps moves missing)
- [x] Rename tab / item
- [ ] Duplicate tab / duplicate folder (partial: duplicate tab done; duplicate folder missing)
- [x] Archive tab, Archive Other Tabs / Above / Below, Clear Today tabs
- [x] Close and Keep Pinned; reset pinned tab to its saved URL (also Replace Pinned URL with Current, Reset All Pinned Tabs)
- [ ] Tidy tab titles (missing)
- [ ] Hover previews / hover cards on sidebar items (missing)
- [ ] Unread badge on tabs (missing)
- [x] Go to Sidebar Item 1-9, last item, next/previous item (Cmd+1-8, Cmd+9 last, Cmd+Opt+Up/Down)
- [ ] Hide/show sidebar, toolbar mode with full URL (partial: Cmd+S hides the sidebar; toolbar mode missing)
- [ ] Multi-select sidebar items and bulk actions (missing)
- [ ] Copy URL, Copy URL as Markdown, copy links as Markdown, clean URL (partial: copy URL and Markdown done)
- [ ] Undo close (Cmd+Z in sidebar), reopen closed tab (partial: Cmd+Shift+T only)

## Spaces & profiles

- [x] Multiple Spaces with switcher
- [x] Separate profile per Space (cookies, logins)
- [x] Create / delete / reorder Spaces
- [ ] Space themes: colours, gradients, icons/emoji (Space style editor) (missing)
- [ ] Swipe / Ctrl+number to switch Spaces (partial: Ctrl+1-9 and Cmd+Opt+arrows done; trackpad swipe missing)
- [ ] Create/rename Profiles, assign Space to Profile (missing)
- [ ] Show/hide Space header, search Spaces (missing)

## Command bar & navigation

- [x] Command bar: new tab, go to URL, search (done (basic))
- [ ] Suggestions: open tabs, history, bookmarks, actions, top domains (missing)
- [ ] Search engine choice, search suggestions (partial: engine choice done; suggestions missing)
- [x] Switch to a recent tab (Ctrl+Tab)
- [x] Back/forward, reload, find in page, zoom, print
- [ ] Link routing rules (which Space opens which links) (missing)
- [ ] Command bar ranking that learns from what you pick (missing)
- [x] Paste and Go (Edit menu)

## Split view & windows

- [ ] Split view: vertical/horizontal, up to 4 panes, add/close/move panes (partial: add in all four directions, flip layout, close and focus panes, split as one sidebar item, draggable dividers and saving splits done; dragging a tab into the page to split and maximize pane missing)
- [ ] Switch between split views; share split view (missing)
- [ ] Multiple windows, move tab to window, Move to main window (missing)
- [ ] Incognito window (missing)
- [x] Full screen, focus mode (Ctrl+Cmd+F full screen; Cmd+Opt+Shift+F focus mode hides sidebar and window buttons)

## Little Arc & Peek

- [ ] Little Arc (mini browser for external links, global hotkey) (partial: Little Window for links from other apps (can be turned off), Cmd+Opt+N, archived on close or when idle (default 6 hours); global hotkey and modifier-click missing)
- [ ] Open in main window / move to Space from Little Arc (partial: Open in NotArc moves to the current Space; choosing another Space missing)
- [ ] Peek: preview links from pinned/favourite sites, email peeking (partial: links leaving a Pinned tab or Favorite's site and Shift-clicked links open in Peek; Open as Tab; email peeking and undo missing)

## Media

- [ ] Media controls in sidebar (play/pause, mute) (missing)
- [ ] Automatic picture-in-picture, mini player (missing)
- [ ] Toggle microphone/camera for calls (missing)

## Content tools

- [ ] Capture: area, full page, portrait mode; save/copy screenshot (missing)
- [ ] Easel (canvas of captures, text, live web clips) (missing)
- [ ] Notes (rich-text documents in the sidebar) (missing)
- [ ] Boosts: custom CSS/JS per site, zap elements, boost editor (missing)
- [ ] Translate page (missing)
- [ ] Ad blocking / content blocking (missing)
- [ ] Site control center (per-site permissions, clear cookies and refresh) (missing)

## Live content

- [ ] Live Folders (GitHub PRs/issues, RSS etc. as auto-updating folders) (missing)
- [ ] Calendar integration: next meeting, meeting link (missing)
- [ ] Notion / Slack / Gmail integrations in Favorites (missing)

## AI (Arc Max)

- [ ] Ask on page, ChatGPT in command bar, tidy titles, 5-second previews (missing (needs an LLM provider))
- [ ] On-device tab categorisation and page summaries / page-to-Markdown (missing)

## Library & data

- [x] Archive with search
- [x] Auto-archive (6h/12h/24h/7d/30d/never, in Settings)
- [x] Downloads list (Cmd+Shift+J: progress, filter, Open, Show in Finder, Copy, Cancel; download folder setting; quit warning)
- [x] History view (Cmd+Y, searchable, per-Space column, Clear History)
- [x] Import from Arc (Spaces, tabs, archive, logins)
- [ ] Import from Chrome/Safari/other browsers, password import (missing)
- [ ] Clear browsing data (missing)
- [ ] Tab thumbnails for switchers and previews (missing)

## Browser basics

- [ ] Chrome extensions (Web Store), extension picker (missing)
- [ ] Password saving/autofill, address/card autofill (missing)
- [ ] DevTools (show/hide), developer mode (partial: DevTools done)
- [ ] Set as default browser, open links from other apps (partial: registers as a browser and opens links from other apps; no in-app "make default" prompt)
- [ ] Context menus (page, link, image, sidebar) (partial: sidebar menu and NotArc link actions done; image actions are Chromium defaults)
- [ ] Sad tab / crash recovery, session restore (partial: sidebar restore only)
- [ ] Settings window (all preferences) (partial: search engine, auto-archive, Peek and Little Window link options; profiles, appearance, Max and advanced panes missing)
- [ ] Keyboard shortcuts with user overrides (missing)
- [ ] App icon choice, sound effects, toasts (missing)
- [ ] PDF viewer (missing)
- [ ] AppleScript support for windows and tabs (missing)
- [ ] Two-finger swipe back/forward and overscroll (missing)
- [ ] Web notifications, permission prompts, external app (protocol) dialogs (missing)
- [ ] Hung page / unresponsive renderer dialog (missing)
- [ ] Import bookmarks (missing)

## Sync & sharing (Arc account)

- [ ] Sidebar sync across Macs (out of scope for v1 (Arc used its own servers))
- [ ] Share folders/Spaces/Easels via link (out of scope for v1)

## Install & updates

- [x] Downloadable app from GitHub Releases
- [x] Automatic update check and install (daily check of GitHub Releases, SHA-256 verified, Install and Relaunch; Check for Updates... in the app menu; works from 0.5.0 on)
