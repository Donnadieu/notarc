# Visual parity with Arc 1.169

79 done of 79 items.

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
  for the tab playing sound: the site's icon (never the artwork, V78), then back, play/pause, forward and the speaker spread evenly,
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

## Reported by Omar (Nov 12)

Two more of Omar's Arc 1.169 / NotArc 0.30 screenshots. These were misses in V7, V12 and V69.

- [x] **V73 Window buttons in colour.** Close, minimize and zoom are macOS's own buttons in their red, yellow and green,
  with the system's shading and coloured rims, in an active window and an inactive one alike, at Arc's spots (centres
  x 20/43/66, y 24; measured within 1 pt of Omar's Arc screenshot), and they stay there when AppKit lays the title bar
  out again (a light/dark switch). NotArc's turned into flat grey circles whenever its
  window lacked key focus: another app in front, or (with Chrome-style pages) a page's own window holding focus while
  you use it. Ref: shot (Omar's Arc, Nov 11), Omar's NotArc shot (grey circles next to skool.com), app (Arc places the
  system's own buttons).
- [x] **V74 No Boost brush in the address pill.** Arc shows no icon after the domain, on a plain site or a site with a
  Boost on; Boosts live in the site control center (its Boosts section with an on/off switch). NotArc showed a blue
  paintbrush (its Boost button) after the domain whenever the site had a Boost on. Ref: Omar (Arc never shows it), help
  (Arc's 2023 release notes: "Boosts now live within the Site Control Center"; the Boosts article edits them from the
  Site Control Panel), app (Arc's Boost icons ship only in its site control center).

## Reported by Omar (Nov 12): floating video and mini player

Omar's five Arc 1.169 screenshots of a YouTube video (the float over the sidebar, its hover controls, the slim mini
player and its hover row) and his notes. Before this, NotArc left Chromium's own picture-in-picture window as it was
(373x210 at the screen's bottom-right corner, Chromium's controls), its X paused the video, and the mini player showed
the track's artwork and only the current Space's tabs. This replaces the "Arc's own picture-in-picture windows" line
that was under Out of scope.

- [x] **V75 Floating video.** Leaving a tab whose video is playing floats it in a small window over the sidebar's
  bottom-left: 222 pt wide at the video's shape (125 pt for 16:9), 6 pt corners, a dark hairline, 20 pt from the
  window's left edge and 98 pt above its bottom (20 pt above the mini player's spot); it moves with the window and can
  be dragged. The mini player stays hidden while the video floats. Ref: shot (measured at 1x), app (Arc's PiP window,
  LastVideoPIPPosition).
- [x] **V76 Float hover controls.** Under the pointer the video dims and shows a back-to-tab arrow top-left, the site
  (www.youtube.com) in the middle of the top, minimize and close top-right on 28 pt rounded tiles, a big pause/play in
  the middle, and a white progress bar 10 pt above the bottom (click or drag to seek). The back arrow shows the
  video's tab (in its own Space) and puts the video back in the page. Ref: shot, app (tooltips "returns to the original
  tab", "minimizes the pip window", "closes the pip window").
- [x] **V77 Close and minimize keep the sound.** Both take the video away and the sound keeps playing; the mini player
  takes over. Chromium's own close paused the video. Ref: shot, Omar's notes, app (userRequestedMinimize,
  userRequestedClose).
- [x] **V78 Mini player.** The slim 32 pt bar above the Space dots shows the site's icon (YouTube's, not the video's
  artwork), then previous, play/pause, next and the speaker; they drive the page's media session (previous / next
  track, else 10 s skips). The speaker is Arc's Adjust Tab Volume: a small slider for that tab's sound. Play plays
  the sound without bringing the video back. Ref: shot, app (Adjust Tab Volume, speaker.wave.1/3).
- [x] **V79 Mini player hover row.** Under the pointer the card grows to 64 pt: what's playing (the media session's
  title, else the page title) ending in "...", then Open Picture in Picture (videos only) and Close Mini Player.
  Open Picture in Picture floats the video again; the X stops the sound and removes the player until that tab plays
  again. Ref: shot, app (Close Mini Player, Open Picture in Picture, Back to Tab tooltips).
- [x] **V80 Playing across Spaces and profiles.** Switching to another Space (also one on another profile, such as
  Andela) keeps the sound playing and the mini player in the sidebar; its icon still goes back to the tab, switching
  Space. Ref: Omar's notes.

## Reported by Omar (Nov 11)

Omar compared his NotArc 0.29.0 with Arc 1.169 side by side: six screenshots (three of each). These were misses in
V12, V29, V49 and V50 above.

- [x] **V67 Address-pill dropdown.** Clicking the sidebar's address pill (or Cmd+L) opens Arc's small dropdown, not
  the big bar: its top-left on the pill's, 348 pt wide (the pill plus 92), a 50 pt input row with the site's icon and
  the address in 13 pt, then at most five 50 pt rows (icon and title only, 13 pt semibold, the selected one a Space
  coloured pill 8 pt in), no dimming. The big centred bar stays for Cmd+T. Ref: shot (Omar's Arc, Nov 11, measured
  at 1x), Omar's NotArc shot (640 pt bar reaching over the page).
- [x] **V68 Closing the dropdown.** A click anywhere outside it, Esc, or another window or app taking focus closes it
  and nothing is opened; a click on the pill itself just closes it. Ref: Omar (NotArc could only be closed by picking
  a row).
- [x] **V69 Pill hover row.** Hovering the pill shows this profile's pinned extensions with their own icons (up to
  two; clicking one opens its popup under it, right-click for Options / Unpin), the puzzle (More) with every
  extension and Pin / Unpin, then Copy URL and the site control center. No Boost button, even on a site with a Boost
  on (V74). Ref: shot (Omar's Arc: two extension icons, link, controls), Omar's NotArc shot (Boost, link, controls, no
  extensions).
- [x] **V70 Arc's extensions show up.** Import Everything from Arc copied Omar's five extensions but left Chrome-style
  pages off, so none loaded and the pill showed none. Copying any now turns them on (they start at the next launch,
  and the summary says so), and Arc's toolbar pins come along. Ref: Omar's NotArc folder and settings (read only).
- [x] **V71 Command bar card.** The card is see-through like Arc's: a blur of what's behind under a neutral tint (dark
  ~#1A181B at 80 %, light near-white at 92 %), so the Space's colour shows through, with 10 pt corners (was opaque
  grey with 14 pt corners). Ref: shot (Omar's Arc, measured), video (Arc's new-tab bar, measured at 2x).
- [x] **V72 Site control center.** It hangs from the pill's site button (it hung from the page's corner), adds Arc's
  Extensions section (each extension with its icon and a pin button, + to add one), and the footer is Clear Cookies,
  Clear Cache and a ... menu with Arc's footer items (Clear Cache, Clear Cookies, Manage Extensions, Add Extension,
  All Site Settings, Manage Boosts, New Boost) plus Reset Permissions. Ref: app (Arc's site control center views,
  footer menu items and pin tooltips), Omar's NotArc shot.

## Window

- [x] **V6 Window frame.** No title bar; the page is a rounded card (8 pt corners) inset 10/9/9 pt on the Space colour,
  hairline edge, soft shadow only in light mode. Ref: shot, app (content inset, corner radius).
- [x] **V7 Traffic lights.** Window buttons sit inside the sidebar at x 20/43/66, centre y 24, and hide in focus mode.
  They are macOS's own buttons in their red, yellow and green in every window, active or not (V73). Ref: shot, Omar.
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
  the site buttons appear at its right only while the pointer is over it, in Arc's order since Nov 11 (V69): pinned
  extensions, More, Copy URL, site controls; never a Boost brush (V74); hover lightens it; click opens the dropdown
  (V67). Ref: shot, app.
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
- [x] **V21 Drag and drop.** A dragged row lifts with a shadow, other rows slide apart to make a gap, a drop into a
  folder highlights it, and a drop on the page card offers split. Ref: app (drag hint), video.
- [x] **V22 Empty Space.** A Space with no tabs shows only the title, divider and "+ New Tab"; no placeholder text.
  Ref: shot, video.
- [x] **V23 Hidden sidebar.** With the sidebar hidden the card fills the window; moving the pointer to the left edge
  slides the sidebar in as a floating rounded panel (10 pt corners, Space colour, deep shadow) over the page, and
  moving away hides it again. Ref: app (gesture-hidden sidebar), video.
- [x] **V24 Bottom bar.** Library button at left, one filled dot (or emoji) per Space in the middle, 34 pt apart
  (current white ~50%, others ~17%), "+" at right; icons white ~60%, centred 20.5 pt above the window bottom. Ref: shot.
- [x] **V25 Plus menu.** "+" opens a native menu (as Arc's is) with an icon on every row, in Arc's order: New Tab,
  New Split View (right / below), New Folder, New Easel, New Note, New Boost, New Live Folder, then New Space and New
  Profile; it opens upward from the button. Ref: app (plus button icons and menu item types).
- [x] **V26 Unread badge and sound icon.** Unread count/dot on a Favorite's tile; a tab with sound keeps its site
  icon and gets a speaker button at the row's right (left of the cross on hover) that mutes and unmutes it. Ref:
  app (mute button in the tab cell), video.
- [x] **V27 Update banner.** A background check downloads the update quietly, then a small card at the bottom of
  the sidebar says the version is ready with a Restart capsule (white on light, black on dark, Arc's updater-button
  colours). Ref: app (updater button colours).
- [x] **V28 Next meeting bar.** The same compact card at the sidebar bottom before a meeting: calendar icon, title
  and time, a Join capsule. Ref: app, video.

## Command bar and navigation

- [x] **V29 Command bar on the address pill (Cmd+L).** Opens in place: its top-left on the address pill, the current
  address selected, no dimming; with the sidebar hidden it opens centred. Since Nov 11 it's Arc's compact dropdown
  (V67), not a 640 pt bar. Ref: app (top-left placement), shot.
- [x] **V30 Command bar rows.** Open tabs ("Switch to Tab"), history, search suggestions, Spaces and actions, each with
  its icon; the empty bar shows recent tabs, a few actions (New Split View, New Little Window, Capture Area) and then
  top sites. Ref: app, help.
- [x] **V31 Command bar keyboard.** Up/Down move the pill, Tab completes, Enter opens, Shift+Enter opens a Little
  Window, Cmd+Enter opens a background tab, Esc closes; a site's name then Tab starts Site Search with a "Search
  <site>" capsule in the Space colour (Backspace on an empty field removes it). Ref: help (Site Search, Actions), app.
- [x] **V32 Command bar text and colours.** Text white 80% / 33%, row hover 5%, hairline 10%, placeholder 60%,
  accessory chips 5%; light mode mirrored in black. Ref: colours.
- [x] **V33 Ctrl+Tab switcher.** A centred dark HUD of recent tabs as page pictures with a soft shadow, the site's
  icon and title under each, the chosen one on a light rounded plate (no accent colour). Ref: app (item switcher:
  snapshots, shadow, visual-effect material).
- [x] **V34 Hover cards.** Hovering a sidebar row shows a card to its right: the page's picture edge to edge on top,
  the title, a link row (site icon + domain), then when it was last used. Ref: app (hover card: banner image, title,
  link views).
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

## Library and content

- [x] **V41 Library panel.** The Library button turns the sidebar into the Library: a Spaces list, then Archive,
  Downloads, Media (image and video downloads plus captures), Easels, Notes and Boosts with counts; each opens in
  place with Back and its own search. Ref: app (Library data: files, links, captures), help.
- [x] **V42 Downloads.** Downloads live in the Library as cards (file icon, name, status, a thin progress bar while
  downloading, a hover fill); a new download's icon flies from the page into the Library button and a small tray of
  recent download cards opens beside it in Arc's download-item colours. Ref: app (download item colours), video.
- [x] **V43 Easels.** Canvas on a dotted background, a floating rounded tool bar at the top with pointer, text,
  arrow, shapes and pen, then Add Image and Capture, then the colours; no scrollbar track. Ref: app (Easel tools),
  video.
- [x] **V44 Notes.** Note page with a large title ("Untitled" in grey while empty), a centred reading column and a
  floating rounded format bar over the top. Ref: app, video.
- [x] **V45 Boosts editor.** Card with a colour wheel, the Intensity slider, font tiles, size, Case, Zap and Code
  (already matched; checked against a render). Ref: app (Boost editor), video.
- [x] **V46 Capture.** The page dims with a dark hint capsule at the top; the selection gets a white rounded outline
  and a size tag; the result card at the page's bottom-right shows the picture with Copy, Show and Easel. Ref: app,
  video.

## Menus and panels

- [x] **V47 Sidebar right-click menu.** Native menu with Arc's labels, section dividers and an icon on every row
  (split rows with split icons); pinned-URL actions sit under "Edit Pinned Page", and a split row offers flipping the
  layout and "Separate All Tabs". Ref: app (context menus, split icons).
- [x] **V48 Page right-click menu.** Links, images and selected text get Arc's extra items on top of Chromium's
  menu (Open Link in Split View, Peek, Little Window, Copy Link as Markdown; image and page actions). Ref: app.
- [x] **V49 Site controls.** The site button opens Arc's site control center: the domain, a row of round actions
  (Copy URL, Share, Capture a portion, Capture the full page, New Boost), the connection, a Boosts section and Site
  Settings rows (icon tile, title, Ask / Allowed / Blocked, switches), then Clear Cookies and Reset Permissions.
  Ref: app (site control center).
- [x] **V50 Extensions menu.** Puzzle button in the pill (shown when any extension is installed or Chrome-style pages
  are on); each extension's popup appears as a bubble under it, or under its own pinned icon (V69). Ref: app, video.
- [x] **V51 Permission prompts.** Requests drop down from the address pill as a small card (title, Remember for this
  site, Don't Allow / Allow), never a window sheet; with the sidebar hidden they drop from the page's top-left. Ref:
  app (permission request state on the top bar), video.

## Spaces and themes

- [x] **V52 Space theme picker.** A popover with a big colour pad (drag dots for a one, two or three-colour
  gradient), rows of preset colours (pastel, muted, greys), sun/moon/automatic toggle, intensity and grain. Ref: app
  (Space style editor), video.
- [x] **V53 Space gradients and grain.** The sidebar and window background paint the gradient with a fine grain.
  Ref: app (window theme), shot.
- [x] **V54 New Space flow.** Name, emoji icon, profile and theme in one card. Ref: app (Space creation), video.
- [x] **V55 Space switching animation.** The sidebar slides left/right with a spring as you change Space; the window
  colour cross-fades. Ref: app, video.

## Onboarding, settings, toasts

- [x] **V56 Onboarding.** Full-window welcome with a soft glow, then a few short steps (pinning, Spaces, split view,
  new tab). Ref: app (welcome screens), video.
- [x] **V57 Import screen.** Pick a browser from a grid of cards, then a progress step and a done step. Ref: app
  (import screens), video.
- [x] **V58 Settings window.** Toolbar tabs with icons (General, Profiles, Links, Shortcuts, Icon, Max, Advanced),
  grouped sections, Arc's button styles. Ref: app (settings panes).
- [x] **V59 Toasts.** A dark capsule with an icon and short text ("Copied URL") near the bottom of the page card, a
  thin divider, then plain-text actions (Undo) in blue; fades out. Ref: app (toasts), video.
- [x] **V60 Alerts and dialogs.** Rounded card dialogs with Arc's contrasting and red destructive buttons. Ref: app
  (button styles).

## Look everywhere

- [x] **V61 Dark mode.** Every screen above in dark. Ref: colours.
- [x] **V62 Light mode.** Every screen above in light, including the light selected-row shadow. Ref: colours.
- [x] **V63 Typography.** SF Pro sizes and weights: tab title 13-14 medium, Space title 12-13 semibold, command bar
  input 20, rows 13-14. Ref: shot, video.
- [x] **V64 Sizes, spacing and corner radii.** 273 pt sidebar, 8 pt side insets, 36 pt pill and rows, 10 pt pill and
  tile corners, 8 pt row and card corners. Ref: shot, app.
- [x] **V65 Animations: opening and closing tabs.** A new tab row grows in from zero height; a closed one shrinks
  and the rows below slide up; archive slides it toward the Library button. Ref: video.
- [x] **V66 Animations: sidebar show and hide.** Cmd+S slides the sidebar out and the page card expands, both with
  a spring; off with Reduce Motion. Ref: app, video.

## Out of scope

Not built on purpose; not counted.

- Arc's logo, app icon, browser logos, welcome videos and textures: they are Arc's (and others') artwork; NotArc
  draws its own.
- Arc account, membership card, referral and sync screens: NotArc has no accounts or server.
- Arc Max banners and Ask Arc's cloud chat screens: NotArc's AI runs on the Mac and has its own simpler screens.
- Sharing screens (share links for Spaces, folders, Easels): there is no server to host links.
- Arc's mobile sidebar icons and Windows-only screens: NotArc is a Mac app.
- Arc's call window (document picture-in-picture for Meet): Chromium draws document PiP windows itself. The video
  float is Arc's since V75.
