# Feature parity with Arc 1.169

6 done, 9 partial, 55 not started or out of scope, of 70 items.

Arc behaviour NotArc needs to match. Each item is implemented from scratch.

## Sidebar & tabs

- [x] Vertical sidebar with Favorites (Top Apps), Pinned, Today
- [ ] Folders, nested folders, drag and drop (partial: nested folders and New Folder from Selection missing)
- [ ] Pin/unpin (Cmd+D), Move to Pinned/Today/Top Apps (partial: Top Apps moves missing)
- [ ] Rename tab / item (missing)
- [ ] Duplicate tab / duplicate folder (missing)
- [ ] Archive tab, Archive Other Tabs / Above / Below, Clear Today tabs (partial: only close-to-archive)
- [ ] Close and Keep Pinned; reset pinned tab to its saved URL (missing)
- [ ] Tidy tab titles (missing)
- [ ] Hover previews / hover cards on sidebar items (missing)
- [ ] Unread badge on tabs (missing)
- [ ] Go to Sidebar Item 1-9, last item, next/previous item (missing)
- [ ] Hide/show sidebar, toolbar mode with full URL (missing)
- [ ] Multi-select sidebar items and bulk actions (missing)
- [ ] Copy URL, Copy URL as Markdown, copy links as Markdown, clean URL (partial: copy URL and Markdown done)
- [ ] Undo close (Cmd+Z in sidebar), reopen closed tab (partial: Cmd+Shift+T only)

## Spaces & profiles

- [x] Multiple Spaces with switcher
- [x] Separate profile per Space (cookies, logins)
- [ ] Create / delete / reorder Spaces (missing)
- [ ] Space themes: colours, gradients, icons/emoji (Space style editor) (missing)
- [ ] Swipe / Ctrl+number to switch Spaces (missing)
- [ ] Create/rename Profiles, assign Space to Profile (missing)
- [ ] Show/hide Space header, search Spaces (missing)

## Command bar & navigation

- [x] Command bar: new tab, go to URL, search (done (basic))
- [ ] Suggestions: open tabs, history, bookmarks, actions, top domains (missing)
- [ ] Search engine choice, search suggestions (missing)
- [ ] Switch to a recent tab (Ctrl+Tab) (missing)
- [ ] Back/forward, reload, find in page, zoom, print (partial: print missing)
- [ ] Link routing rules (which Space opens which links) (missing)

## Split view & windows

- [ ] Split view: vertical/horizontal, up to 4 panes, add/close/move panes (missing)
- [ ] Switch between split views; share split view (missing)
- [ ] Multiple windows, move tab to window, Move to main window (missing)
- [ ] Incognito window (missing)
- [ ] Full screen, focus mode (missing)

## Little Arc & Peek

- [ ] Little Arc (mini browser for external links, global hotkey) (missing)
- [ ] Open in main window / move to Space from Little Arc (missing)
- [ ] Peek: preview links from pinned/favourite sites, email peeking (missing)

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

## Library & data

- [x] Archive with search
- [ ] Auto-archive (6h/12h/24h/7d/30d/never) (partial: fixed 12h, no settings UI)
- [ ] Downloads list (missing)
- [ ] History view (missing)
- [x] Import from Arc (Spaces, tabs, archive, logins)
- [ ] Import from Chrome/Safari/other browsers, password import (missing)
- [ ] Clear browsing data (missing)

## Browser basics

- [ ] Chrome extensions (Web Store), extension picker (missing)
- [ ] Password saving/autofill, address/card autofill (missing)
- [ ] DevTools (show/hide), developer mode (partial: DevTools done)
- [ ] Set as default browser, open links from other apps (missing)
- [ ] Context menus (page, link, image, sidebar) (missing)
- [ ] Sad tab / crash recovery, session restore (partial: sidebar restore only)
- [ ] Settings window (all preferences) (missing)
- [ ] Keyboard shortcuts with user overrides (missing)
- [ ] App icon choice, sound effects, toasts (missing)

## Sync & sharing (Arc account)

- [ ] Sidebar sync across Macs (out of scope for v1 (Arc used its own servers))
- [ ] Share folders/Spaces/Easels via link (out of scope for v1)

## Install & updates

- [ ] Downloadable app from GitHub Releases (missing)
- [ ] Automatic update check and install (missing)
