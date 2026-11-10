# Visual parity with Arc 1.169

0 done of 66 items.

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

- [ ] **V1 Sidebar scrollbar.** Arc shows no scrollbar track in the sidebar, ever; an overlay scroller appears only
  while scrolling a long list, and the empty area below the tabs is just the Space colour. Ref: shot (no track),
  Omar's NotArc screenshot (track visible).
- [ ] **V2 Tab rows.** 36 pt rows on a 41 pt pitch, 16 pt favicon at x 18, title at x 45 in 13-14 pt medium
  lavender-white; a long title fades out at the right edge (no "..."), and the fade makes room for a round close
  button that shows on hover and on the selected row. Ref: shot, colours.
- [ ] **V3 Mini player and media controls.** A card above the bottom bar for the tab playing sound: artwork or favicon,
  the track title and the site on two lines (no "(2:52)" in the title), and back, play/pause and forward buttons;
  mute on hover. A playing video you leave keeps playing in a small player there. Ref: help (Mini Player), shot
  (media bar black ~45%, radius 8), colours (playback control colour).
- [ ] **V4 Archive in the sidebar.** The archive button opens Archive inside the sidebar (Library), not a window: a
  search field, archived tabs grouped by when they were archived (Today, Yesterday, earlier days and months), each a
  normal favicon + title row; clicking one brings it back as a tab. Long archives load as you scroll. Ref: app
  (Archive page, search, empty state, auto-archive vs manual), help (Auto Archive).
- [ ] **V5 Command bar (new tab).** Cmd+T opens a large floating bar centred over the page, about a fifth of the way
  down: big 20 pt input, a solid material card with a deep soft shadow and ~12 pt corners, then rows with an icon,
  title and a dim second part (address, "Switch to Tab", action name); the selected row is a filled Arc-blue pill with a
  key hint on the right. Ref: app (centred, top-left, floating and full-window placements), colours, help (Command Bar
  Actions), video.

## Window

- [ ] **V6 Window frame.** No title bar; the page is a rounded card (8 pt corners) inset 10/9/9 pt on the Space colour,
  hairline edge, soft shadow only in light mode. Ref: shot, app (content inset, corner radius).
- [ ] **V7 Traffic lights.** Window buttons sit inside the sidebar at x 20/43/66, centre y 24; they dim when the window
  is inactive and hide in focus mode. Ref: shot, app (dimmed window controls).
- [ ] **V8 Inactive window.** An inactive window keeps the Space colour but its sidebar text and icons dim. Ref: app.
- [ ] **V9 Loading.** A loading tab shows a spinner in place of its favicon, and a soft glow runs along the page card
  while the page loads. Ref: app (glow progress indicator), video.
- [ ] **V10 Sad tab.** A crashed page shows a centred illustration, a short line and a Reload button on the page
  card. Ref: app (sad tab), video.

## Sidebar

- [ ] **V11 Top bar.** Sidebar toggle right of the traffic lights; back, forward and reload at the right, in the
  toolbar icon colour, disabled ones dimmed. Ref: shot, colours.
- [ ] **V12 Address pill.** x 8-264, 36 pt tall, ~10 pt corners, white ~9% (dark); shows the domain only in 13 pt; site
  buttons (copy link, site controls, extensions) at its right; hover lightens it; click opens the command bar on top of
  it. Ref: shot, app.
- [ ] **V13 Favorites grid.** Tiles 3 to a row (79 x 47 pt, 9 pt gaps, ~10 pt corners, white ~8%), 16 pt icon centred;
  selected tile is brighter; unread badge at the corner; tiles widen when there are fewer per row. Ref: shot.
- [ ] **V14 Space title.** Space name (and its emoji icon) at x 18 in 12-13 pt semibold, white ~45%; "..." menu on hover.
  Ref: shot, app (Space header).
- [ ] **V15 Pinned section and divider.** Pinned tabs sit between Favorites and the divider; the divider is 1 pt,
  white ~15%, x 18-255; no "Pinned" label. Ref: shot, colours.
- [ ] **V16 New Tab row.** "+ New Tab" under the divider in white ~45% with a hover fill; clicking it opens the
  command bar. Ref: shot, app.
- [ ] **V17 Today and Clear.** Today's tabs under New Tab; hovering the divider shows a small "Clear" action that
  archives them. Ref: app (Clear), video.
- [ ] **V18 Folders.** Folder icon that opens and closes, child rows indented, folder count; nested folders indent
  again. Ref: app, video.
- [ ] **V19 Split view rows.** A split is one row: each pane's favicon and title side by side, separated by a thin
  slash; the shown pane is brighter. Ref: colours (slash, content-visible fill), video.
- [ ] **V20 Hover, selected and pressed states.** Selected white ~20%, hovered previous ~12%, pressed ~6.5%,
  multi-selected ~10% (dark); light mode uses white 85/50/... with a small shadow on the selected row. Ref: colours.
- [ ] **V21 Drag and drop.** A dragged row lifts with a shadow, other rows slide apart to make a gap, a drop into a
  folder highlights it, and a drop on the page card offers split. Ref: app (drag hint), video.
- [ ] **V22 Empty Space.** A Space with no tabs shows only the title, divider and "+ New Tab"; no placeholder text.
  Ref: shot, video.
- [ ] **V23 Hidden sidebar.** With the sidebar hidden the card fills the window; hovering the left edge slides the
  sidebar in as a floating rounded panel with a shadow over the page. Ref: app (gesture-hidden sidebar), video.
- [ ] **V24 Bottom bar.** Library button at left, one dot (or emoji) per Space in the middle (current one light, others
  ~25%), "+" at right. Ref: shot.
- [ ] **V25 Plus menu.** "+" opens Arc's own menu style (dark rounded panel, icon per row): New Tab, Split View,
  Folder, Easel, Note, Boost, Space, Profile. Ref: app (plus button icons, menu colours).
- [ ] **V26 Unread badge and sound icon.** Unread count/dot on a row or tile; a speaker icon on a playing tab that
  mutes on click. Ref: app, video.
- [ ] **V27 Update banner.** When an update is ready, a small banner at the bottom of the sidebar offers to restart.
  Ref: app (sidebar banner), video.
- [ ] **V28 Next meeting bar.** A compact card at the sidebar bottom before a meeting, with Join. Ref: app, video.

## Command bar and navigation

- [ ] **V29 Command bar on the address pill (Cmd+L).** Opens in place over the address pill at the top of the sidebar,
  widening to the right over the page, with the current address selected. Ref: app (top-left placement).
- [ ] **V30 Command bar rows.** Open tabs ("Switch to Tab"), history, search suggestions, Spaces and actions, each with
  its icon; the empty state shows recent tabs and actions rather than a plain "Top Site" list. Ref: app, help.
- [ ] **V31 Command bar keyboard.** Up/Down move the pill, Tab completes, Enter opens, Shift+Enter opens a Little
  Window, Cmd+Enter keeps it in the background, Esc closes; typing a site's name then Tab starts Site Search with a
  capsule. Ref: help (Site Search, Actions), app.
- [ ] **V32 Command bar text and colours.** Text white 80% / 33%, row hover 5%, hairline 10%, placeholder 60%,
  accessory chips 5%; light mode mirrored in black. Ref: colours.
- [ ] **V33 Ctrl+Tab switcher.** A centred panel of up to 5 recent tabs as page pictures with titles, the chosen one
  outlined; release to switch. Ref: video (tab switcher), help.
- [ ] **V34 Hover cards.** Hovering a sidebar row shows a card to its right with a page picture, title and address.
  Ref: app (hover card), video.
- [ ] **V35 Find in page.** A small floating bar at the top-right of the page card with the match count and arrows.
  Ref: video.
- [ ] **V36 Toolbar mode.** View > Show Toolbar puts a thin bar with back/forward/reload and the full address above
  the page. Ref: app.

## Split view, Little Arc, Peek

- [ ] **V37 Split panes on the page.** Each pane is its own rounded card with a small gap; the focused pane has a
  subtle outline. Ref: video, app.
- [ ] **V38 Little Arc window.** A small window with a thin top bar (domain, Space colour) and an "Open in" button;
  no sidebar. Ref: help (Little Arc), app.
- [ ] **V39 Peek.** Links open in a large rounded card floating over the dimmed page, with close and "Open as Tab"
  buttons at its top. Ref: help (Peek), video.
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
- [ ] **V59 Toasts.** Small dark rounded capsule with an icon and short text ("Copied URL") near the bottom of the
  page card, with Undo where it applies; fades out. Ref: app (toasts), video.
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
