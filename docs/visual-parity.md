# Visual parity with Arc 1.169

34 done of 66 items.

Feature parity ([feature-parity.md](feature-parity.md)) says NotArc does everything Arc does. This list says it
**looks and feels** like Arc while doing it: every screen, panel, menu, state and animation. One box per screen or
state. A box is ticked only when a hidden render of NotArc sits beside the Arc reference and they match; the captioned
pairs are kept with the release notes. Items are ordered by how often you see them.

Each line says what Arc does and the reference used:
- **shot**: Omar's own screenshots of Arc on this Mac (Oct 24 and Oct 26, 2026, dark Space, docked sidebar).
- **colours**: the colour values Arc 1.169 ships for that part of the app, light and dark.
- **app**: Arc 1.169's own labels, menus and layout settings on this Mac.
- **help**: Arc's public Help Center and Arc's own tour pages (start.arc.net, resources.arc.net).
- **video**: public screenshots and videos of Arc 1.x.

NotArc never copies Arc's code, logo, pictures, sounds or wording. Where Arc used a picture (browser logos, welcome
videos, textures), NotArc draws its own. Calls made along the way are in [decisions.md](decisions.md).

## Reported by Omar (Nov 10)

- [x] **V1 Sidebar scrollbar.** Arc shows no scrollbar track in the sidebar, ever; an overlay scroller appears only
  while scrolling a long list, and the empty area below the tabs is just the Space colour. Ref: shot (no track),
  Omar's NotArc screenshot (track visible).
- [x] **V2 Tab rows.** 36 pt rows on a 41 pt pitch, 16 pt favicon at x 18, title at x 45 in 13-14 pt medium
  lavender-white; a long title ends in "..." (Omar's Arc 1.169 screenshot), and a close button shows on the row under
  the pointer (not on the selected row by itself). Ref: shot, colours, app, video.
- [x] **V3 Mini player and media controls.** A 32 pt bar above the bottom bar (x 8-264, black ~60%, 8 pt corners)
  for the tab playing sound: the site's icon or artwork, then back, play/pause, forward and the speaker spread evenly,
  no text (what's playing is the icon's tooltip, without any running "(2:52)" clock). Back and forward use the
  page's own previous / next track, else skip 10 s. Ref: shot (measured to the pixel), help (Mini Player).
- [x] **V4 Archive in the sidebar.** The archive button opens Archive inside the sidebar (Library), not a window: a
  search field, archived tabs grouped by when they were archived (Today, Yesterday, earlier days and months), each a
  normal favicon + title row; clicking one brings it back as a tab. Long archives load as you scroll. Ref: app
  (Archive page, search, empty state, auto-archive vs manual), help (Auto Archive).
- [x] **V5 Command bar (new tab).** Cmd+T opens a large card centred on the window, about two thirds of its width and
  a quarter of the way down, while the whole window dims in the Space's colour: 20 pt input, opaque card with a deep
  shadow, 50 pt rows with the site's icon, title and a dim second part; "Switch to Tab" with a small arrow box on open
  tabs; the selected row is filled with the Space's colour, a shade deeper (Arc blue on the default theme). Ref: app
  (centred, top-left, floating and full-window placements), colours, help (Command Bar Actions), video.

## Window

- [x] **V6 Window frame.** No title bar; the page is a rounded card (8 pt corners) inset 10/9/9 pt on the Space colour,
  hairline edge, soft shadow only in light mode. Ref: shot, app (content inset, corner radius).
- [x] **V7 Traffic lights.** Window buttons sit inside the sidebar at x 20/43/66, centre y 24; they dim when the window
  is inactive and hide in focus mode. Ref: shot, app (dimmed window controls).
- [x] **V8 Inactive window.** An inactive window keeps the Space colour but its sidebar text and icons dim. Ref: app.
- [x] **V9 Loading.** A loading tab shows a small spinner in place of its icon (in its row, or in its pane of a split
  row), and a soft glow in the Space's colour sweeps along the top of the page card while the shown page loads. Ref:
  app (glow progress indicator), video.
- [x] **V10 Sad tab.** A crashed page turns plain (light or dark) with one centred drawing (NotArc's own torn page,
  not Arc's picture), a single line and "Reload" as a link in it. Ref: app (sad tab), video.

## Sidebar

- [x] **V11 Top bar.** Sidebar toggle right of the traffic lights; back, forward and reload at the right, in the
  toolbar icon colour (white ~60%); back / forward dim to ~22% when there's nowhere to go. Ref: shot, colours.
- [x] **V12 Address pill.** x 8-264, 36 pt tall, ~10 pt corners, white ~9% (dark); shows the domain only in 13 pt;
  the site buttons (Boost, copy link, site controls, extensions) appear at its right only while the pointer is over
  it (a site with a Boost on keeps that one); hover lightens it; click opens the command bar. Ref: shot, app.
- [x] **V13 Favorites grid.** Tiles 3 to a row (79 x 47 pt, 9 pt gaps, ~10 pt corners, white ~8%), 16 pt icon centred;
  selected tile is brighter; unread badge at the corner; tiles widen when there are fewer per row. Ref: shot.
- [x] **V14 Space title.** Space name (and its emoji icon) at x 18 in 12-13 pt semibold, white ~45%; "..." menu on hover.
  Ref: shot, app (Space header).
- [x] **V15 Pinned section and divider.** Pinned tabs sit between Favorites and the divider; the divider is 1 pt,
  white ~15%, x 18-255; no "Pinned" label. Ref: shot, colours.
- [x] **V16 New Tab row.** "+ New Tab" under the divider in white ~45% with a hover fill; clicking it opens the
  command bar. Ref: shot, app.
- [x] **V17 Today and Clear.** Today's tabs under New Tab; hovering the divider shows a small "↓ Clear" at its right
  that archives them. Ref: app (Clear), video.
- [x] **V18 Folders.** A drawn folder icon that opens (front flap tilted, in the Space's colour) and closes, bold
  name, no chevron; child rows 16 pt in, nested folders indent again. Arc's video shows no tab count on folders, so
  there is none. Ref: app, video.
- [x] **V19 Split view rows.** A split is one row: each pane's icon and title side by side, separated by a thin
  slanted slash (white 30%); the pane on screen is full brightness, the others dimmed. Ref: colours (slash), video.
- [x] **V20 Hover, selected and pressed states.** Selected white ~20%, hovered previous ~12%, pressed ~6.5%,
  multi-selected ~10% (dark); light mode uses white 85/50/... with a small shadow on the selected row. Ref: colours.
- [ ] **V21 Drag and drop.** A dragged row lifts with a shadow, other rows slide apart to make a gap, a drop into a
  folder highlights it, and a drop on the page card offers split. Ref: app (drag hint), video.
- [x] **V22 Empty Space.** A Space with no tabs shows only the title, divider and "+ New Tab"; no placeholder text.
  Ref: shot, video.
- [x] **V23 Hidden sidebar.** With the sidebar hidden the card fills the window; moving the pointer to the left edge
  slides the sidebar in as a floating rounded panel (10 pt corners, Space colour, deep shadow) over the page, and
  moving away hides it again. Ref: app (gesture-hidden sidebar), video.
- [x] **V24 Bottom bar.** Library button at left, one filled dot (or emoji) per Space in the middle, 34 pt apart
  (current white ~50%, others ~17%), "+" at right; icons white ~60%, centred 20.5 pt above the window bottom. Ref: shot.
- [ ] **V25 Plus menu.** "+" opens Arc's own menu style (dark rounded panel, icon per row): New Tab, Split View,
  Folder, Easel, Note, Boost, Space, Profile. Ref: app (plus button icons, menu colours).
- [x] **V26 Unread badge and sound icon.** Unread count/dot on a Favorite's tile; a tab with sound keeps its site
  icon and gets a speaker button at the row's right (left of the cross on hover) that mutes and unmutes it. Ref:
  app (mute button in the tab cell), video.
- [x] **V27 Update banner.** A background check downloads the update quietly, then a small card at the bottom of
  the sidebar says the version is ready with a Restart capsule (white on light, black on dark, Arc's updater-button
  colours). Ref: app (updater button colours).
- [x] **V28 Next meeting bar.** The same compact card at the sidebar bottom before a meeting: calendar icon, title
  and time, a Join capsule. Ref: app, video.

## Command bar and navigation

- [x] **V29 Command bar on the address pill (Cmd+L).** Opens in place: its top-left on the address pill, reaching out
  over the page (up to 640 pt), the current address selected, no dimming; with the sidebar hidden it opens centred.
  Ref: app (top-left placement).
- [ ] **V30 Command bar rows.** Open tabs ("Switch to Tab"), history, search suggestions, Spaces and actions, each with
  its icon; the empty state shows recent tabs and actions rather than a plain "Top Site" list. Ref: app, help.
- [ ] **V31 Command bar keyboard.** Up/Down move the pill, Tab completes, Enter opens, Shift+Enter opens a Little
  Window, Cmd+Enter keeps it in the background, Esc closes; typing a site's name then Tab starts Site Search with a
  capsule. Ref: help (Site Search, Actions), app.
- [x] **V32 Command bar text and colours.** Text white 80% / 33%, row hover 5%, hairline 10%, placeholder 60%,
  accessory chips 5%; light mode mirrored in black. Ref: colours.
- [ ] **V33 Ctrl+Tab switcher.** A centred panel of up to 5 recent tabs as page pictures with titles, the chosen one
  outlined; release to switch. Ref: video (tab switcher), help.
- [ ] **V34 Hover cards.** Hovering a sidebar row shows a card to its right with a page picture, title and address.
  Ref: app (hover card), video.
- [x] **V35 Find in page.** A small rounded floating bar 10 pt in from the page card's top-right: glass, field, match
  count, up / down arrows and a close button. Ref: video.
- [x] **V36 Toolbar mode.** View > Show Toolbar puts a thin bar with back/forward/reload and the full address above
  the page. Ref: app.

## Split view, Little Arc, Peek

- [x] **V37 Split panes on the page.** Each pane is its own rounded card with a small gap; the focused pane has a
  subtle outline. Ref: video, app.
- [x] **V38 Little Arc window.** A small window framed in the Space's colour, the page as a rounded card, a thin top
  bar with the site's domain and an "Open in" capsule; no sidebar. Ref: help (Little Arc), app, video.
- [x] **V39 Peek.** Links open in a large rounded card (10 pt corners, deep shadow, no title bar) floating over the
  dimmed page card, with round Open as Tab and close buttons above its top-right corner. Ref: help (Peek), video.
- [ ] **V40 Picture in picture.** Video PiP and the document PiP for calls with a thin top bar. Ref: app (PiP top bar).

## Library and content

- [ ] **V41 Library panel.** The Library button turns the sidebar into the Library: Spaces, Archive, Downloads,
  Media/Captures, Easels, Notes and Boosts, each a section you open in place. Ref: app (Library sections), help.
- [ ] **V42 Downloads.** Downloads live in the Library and in a small panel by the Library button; each item a card
  with an icon, name, progress and a hover fill; a new download flies into the Library button. Ref: app (download
  item colours), video.
- [ ] **V43 Easels.** Canvas on a dotted background, floating tool bar with pointer, pen, shapes, text and image
  tools, capture button. Ref: app (Easel tools), video.
- [ ] **V44 Notes.** Note page with a large title, reading column and a floating format bar. Ref: app, video.
- [ ] **V45 Boosts editor.** Card with a colour wheel, Intensity, font tiles, Zap and Code. Ref: app (Boost editor),
  video.
- [ ] **V46 Capture.** Area selection overlay and the capture result card with Copy/Save. Ref: app, video.

## Menus and panels

- [ ] **V47 Sidebar right-click menu.** Native menu with Arc's labels and order, section dividers, split icons. Ref:
  app (context menus).
- [ ] **V48 Page right-click menu.** Links, images and selected text with Arc's extra items (Open in Split View, Peek,
  Little Window, Copy as Markdown). Ref: app.
- [ ] **V49 Site controls.** The site button in the address pill opens a popover: address with copy, Boost, Capture,
  permissions with Ask/Allow/Block, Clear Cookies. Ref: app (site control center).
- [ ] **V50 Extensions menu.** Puzzle button in the pill; popups appear as bubbles under it. Ref: app, video.
- [ ] **V51 Permission prompts.** Requests drop down from the address pill, not as window sheets. Ref: app
  (permission request state on the top bar), video.

## Spaces and themes

- [ ] **V52 Space theme picker.** A popover with a big colour pad (drag dots for a one, two or three-colour
  gradient), rows of preset colours (pastel, muted, greys), sun/moon/automatic toggle, intensity and grain. Ref: app
  (Space style editor), video.
- [ ] **V53 Space gradients and grain.** The sidebar and window background paint the gradient with a fine grain.
  Ref: app (window theme), shot.
- [ ] **V54 New Space flow.** Name, emoji icon, profile and theme in one card. Ref: app (Space creation), video.
- [ ] **V55 Space switching animation.** The sidebar slides left/right with a spring as you change Space; the window
  colour cross-fades. Ref: app, video.

## Onboarding, settings, toasts

- [ ] **V56 Onboarding.** Full-window welcome with a soft glow, then a few short steps (pinning, Spaces, split view,
  new tab). Ref: app (welcome screens), video.
- [ ] **V57 Import screen.** Pick a browser from a grid of cards, then a progress step and a done step. Ref: app
  (import screens), video.
- [ ] **V58 Settings window.** Toolbar tabs with icons (General, Profiles, Links, Shortcuts, Icon, Max, Advanced),
  grouped sections, Arc's button styles. Ref: app (settings panes).
- [x] **V59 Toasts.** A dark capsule with an icon and short text ("Copied URL") near the bottom of the page card, a
  thin divider, then plain-text actions (Undo) in blue; fades out. Ref: app (toasts), video.
- [ ] **V60 Alerts and dialogs.** Rounded card dialogs with Arc's contrasting and red destructive buttons. Ref: app
  (button styles).

## Look everywhere

- [ ] **V61 Dark mode.** Every screen above in dark. Ref: colours.
- [ ] **V62 Light mode.** Every screen above in light, including the light selected-row shadow. Ref: colours.
- [ ] **V63 Typography.** SF Pro sizes and weights: tab title 13-14 medium, Space title 12-13 semibold, command bar
  input 20, rows 13-14. Ref: shot, video.
- [ ] **V64 Sizes, spacing and corner radii.** 273 pt sidebar, 8 pt side insets, 36 pt pill and rows, 10 pt pill and
  tile corners, 8 pt row and card corners. Ref: shot, app.
- [ ] **V65 Animations: opening and closing tabs.** A new tab row grows in from zero height; a closed one shrinks
  and the rows below slide up; archive slides it toward the Library button. Ref: video.
- [ ] **V66 Animations: sidebar show and hide.** Cmd+S slides the sidebar out and the page card expands, both with
  a spring; off with Reduce Motion. Ref: app, video.

## Out of scope

Not built on purpose; not counted.

- Arc's logo, app icon, browser logos, welcome videos and textures: they are Arc's (and others') artwork; NotArc
  draws its own.
- Arc account, membership card, referral and sync screens: NotArc has no accounts or server.
- Arc Max banners and Ask Arc's cloud chat screens: NotArc's AI runs on the Mac and has its own simpler screens.
- Sharing screens (share links for Spaces, folders, Easels): there is no server to host links.
- Arc's mobile sidebar icons and Windows-only screens: NotArc is a Mac app.
