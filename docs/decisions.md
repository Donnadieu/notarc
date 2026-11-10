# Decisions

Scope and design calls made while finishing NotArc, newest last. Each one says what was decided and why, so nobody has
to ask again. Items marked "Needs Omar's eyes" can only be confirmed by looking at a real screen or using a real
trackpad; everything else is checked by the hidden self-test.

## 2026-11-09: bringing the parity checklist up to date (0.23.0)

1. **Checklist status moved from 0.11.0 to 0.23.0.** Every line was checked against the code, CHANGELOG.md and its
   issue. The count line is now computed (done, partial, not started) and only counts in-scope work.
2. **#124 Sidebar rows is done.** The Arc sidebar look (tile grid, Space title, "+ New Tab", 41 pt rows, Arc's
   colours) shipped in 0.15.0 (PR #152); the line was already ticked but the issue stayed open for a side-by-side
   review. Closed; the side-by-side look goes under "Needs Omar's eyes".
3. **#19 and #65 reopened.** The 0.19.0 release PR closed them by mistake after the thumbnail change (#176) was
   reverted. Thumbnails are still missing, so both stay open.
4. **#26 Space themes:** per-Space light/dark shipped in 0.13.0 (#128), so only grain is left on that line.
5. **#150 gets its own line** under Library & data. It was tracked only as an issue; the one-button Arc import is
   the main promise to people leaving Arc, so it should count.
6. **Out of scope: sidebar sync across Macs.** Arc synced through its own servers and Arc accounts. NotArc keeps
   everything on the Mac and runs no server, and running one would mean accounts and hosting costs.
7. **Out of scope: share links** for folders, Spaces, Easels, Notes, Boosts and split views. Arc's links were pages
   on arc.net. NotArc has no server; Share Split View already copies the addresses instead (#38). The "sharing is out
   of scope" notes were taken out of the Easel, Notes and Boosts lines so those lines only list real work.
8. **Translate (#52):** in-place translation with Chromium's translate engine is out of scope, because CEF doesn't
   include that component and Google's Cloud Translation API needs a paid key. The in-scope part is the free web
   translator NotArc already uses, plus Arc's offer to translate when a page is in another language.
9. **AI features (#58, #59) run on the Mac, never through a NotArc server or a paid key.** NotArc uses Apple's
   built-in on-device model (macOS 26 with Apple Intelligence turned on). Where that model isn't available the AI
   commands are hidden or fall back to the non-AI version (tidy titles without AI is #18). "ChatGPT in the command
   bar" opens chatgpt.com with the question, in the Space's own ChatGPT sign-in. Arc's account, membership and its
   cloud AI service are out of scope.
10. **Favorite previews (#57) use the Space's own sign-in**, the way Arc read Notion and Slack through their web
    apps, rather than registering NotArc as an OAuth app with Google, Notion or Slack (that would need accounts and
    app reviews). The line is reworded to "Gmail, Notion and Slack previews for Favorites".
11. **Calendar (#56) reads the Mac's Calendar app (EventKit)** instead of signing in to Google Calendar. Any calendar
    the person already added to macOS (Google, iCloud, Exchange) works, with no OAuth app.
12. **Live Folders (#55):** "your own GitHub pull requests" uses the Space's existing github.com sign-in instead of a
    GitHub OAuth app. YouTube channels come from YouTube's public channel feeds.
13. **Visual matching without opening Arc.** No browser window (Arc or NotArc) may open on Omar's screen while this
    work runs, so Arc can't be measured live. The window frame (#122), animations (#126) and command bar (#127) are
    finished against the measurements already taken from Omar's screenshots of Arc (`~/Repos/arc-re/specs`) and Arc's
    on-disk resources, checked by the hidden self-test and offscreen captures, then ticked. A side-by-side look is
    listed under "Needs Omar's eyes". The same goes for real-trackpad gestures (#27, #77).
14. **Self-tests run with a scratch home** (`CFFIXED_USER_HOME`), so a run can never touch Omar's own NotArc data,
    Downloads or Arc folder, and it works from inside One's folder lock.

## 2026-11-09: look and feel, Favorites, tidy titles

15. **#122, #126 and #127 are ticked** under decision 13. The light-mode card edge (the last open part of #122) is
    built: a 1 pt border at Arc's TabListOverlapBorder colour (5%) in both modes and, in light mode only, two soft
    shadows (10% at 4 pt blur and 6% at 1 pt). Arc stores those shadows as runtime values, so the numbers are
    estimates. The slide/pop animations and the command bar styling were already built; what was left was a
    side-by-side look at a real Arc window, which goes under "Needs Omar's eyes".
16. **Favorites, not Top Apps.** Arc's menus still say "Move to Top Apps" internally, but its sidebar calls them
    Favorites, and so does NotArc everywhere. Folders and splits can't become Favorites (same rule as dragging).
17. **Tidy titles (#18) are on by default.** Arc Max's version was opt-in because it sent titles to an AI service;
    NotArc's runs on the Mac, is instant and has an Undo toast and "Use Page Title", so it starts on. Settings has
    "Tidy tab titles when pinning" to turn it off. The tidying is one function (`TidyTabTitle`) so the on-device model
    (#58) can replace it.
18. **Renames now stick (fix to #14).** A renamed tab used to show the page's title again as soon as the page changed
    its title or NotArc restarted. Items now remember that they were renamed (Arc's `title` vs `savedTitle`), and
    the Arc import keeps renames made in Arc.
19. **Grain (#26)** is NotArc's own noise tile (generated in code, seeded so it looks the same every time), shown at
    up to 35% over the theme colours. Arc's grain texture isn't copied.
20. **Swiping between Spaces (#27)** works over the sidebar only (over the page, the same swipe goes back/forward,
    #77), stops at the first and last Space (no wraparound), and follows the macOS "Swipe between pages" setting.
    Real-trackpad feel goes under "Needs Omar's eyes".
21. **Little Window keys (#42):** Cmd+Option+N works from any app through Carbon's hot key API, which needs no
    Accessibility permission; a self-test never registers it. The link modifier is Cmd+Option-click (Cmd-click is a
    background tab, Shift-click a Peek, Option-click a download), the same keys Arc uses on sidebar tabs. Both have
    settings. Arc lets you pick other keys; NotArc doesn't yet (not needed for parity of behaviour).
22. **Email peeking (#44)** reads Gmail's own unread-mail feed (`mail.google.com/mail/u/0/feed/atom`) with the
    current Space's Gmail sign-in, through a new read-only `SpaceFetch` helper. Only unread mail from the last 30
    minutes counts, the sender's domain (or name) has to match the site, a code is copied to the clipboard, and
    otherwise the email opens in a Peek. Gmail only, as in Arc. Nothing is sent anywhere but Gmail.
23. **Translate offer (#52)** uses the language the page declares (`<html lang>`), read once the shown tab has
    loaded, compared with the Mac's preferred languages by primary subtag. It's a toast with a Translate button,
    once per site per launch, with a setting to turn it off. NotArc doesn't guess undeclared languages.
24. **Context menu actions (#70)** are NotArc's own list on top of Chromium's: images get Open in New Tab, Save
    Image to Downloads, Copy Image (fetched with the tab's own sign-in) and Copy Image Address; selected text gets a
    search with your search engine; a plain right-click on the page gets Copy Page URL, as Markdown, Capture,
    Translate and Boost. Chromium's own items stay below.
25. **Drag to split (#37):** dropping a sidebar tab on the page moves that tab into a split with the shown page, on
    the side nearest the pointer (a tinted half shows where). A Favorite stays a Favorite and opens its page in the
    new pane. Notes and Easels don't take drops yet (their own split support is #50/#49).
26. **Maximize Pane (#37)** is Arc's split "Maximize": the focused pane fills the card while the split stays saved;
    toggling again, focusing another pane or leaving the split restores it. Shortcut Cmd+Shift+Return is NotArc's
    guess (Arc's isn't in its data).
27. **#77 is ticked** under decision 13: the swipe code and its self-test were already in place; only a real
    trackpad can confirm the feel, which goes under "Needs Omar's eyes".
28. **Web notifications (#78):** CEF's Alloy pages have no notification service, so NotArc injects a small shim as
    each http(s) document starts. It keeps the page's own permission flow (NotArc's site prompt) and reports each
    `new Notification()` / `showNotification()` to NotArc, which posts it to Notification Center only for sites
    allowed in Site Settings. Clicking it shows the tab. Push notifications that arrive while the site's tab is closed
    (service-worker push) aren't covered; Arc needed the tab open too for most sites. macOS asks once for
    permission the first time; that prompt, and the banner itself, go under "Needs Omar's eyes".
29. **Calendar (#56):** off by default (it needs macOS Calendar access, which macOS asks for once when it's turned
    on). The meeting bar shows from 10 minutes before a meeting until it ends, skips all-day, declined and cancelled
    events, and offers Join when the event's URL, location or notes hold a Zoom, Meet, Teams, Webex, Whereby, Jitsi,
    Around, Slack huddle or FaceTime link. Arc's own lead time isn't in its data; 10 minutes is NotArc's call.
30. **#57 is narrowed to Gmail and calendar Favorites.** Notion and Slack previews moved to Out of scope: Arc read them
    through those companies' private internal web endpoints, which NotArc can't build and test without accounts on
    both, and their unread counts already show as badges (#20). Gmail uses Gmail's own unread feed with the Space's
    sign-in (same as email peeking, #44); calendar Favorites (Google Calendar, Outlook calendar, iCloud, Proton,
    Cal.com) show today's events from the Mac's Calendar.

## 2026-11-09: tab thumbnails (#65, #19)

31. **Thumbnails are copied asynchronously with ScreenCaptureKit, from NotArc's own window.** The 0.19.0 attempt
    (#176, reverted) copied the window synchronously with `CGWindowListCreateImage`: 10-110 ms of main-thread time per
    copy made timing-sensitive self-tests fail at random. DevTools `Page.captureScreenshot` stops Chromium reporting
    frozen pages, and in-process reads (`cacheDisplayInRect`, layer IOSurfaces) are blank because the page is drawn
    in the GPU process. `SCScreenshotManager` with `SCShareableContent.getCurrentProcessShareableContent` copies the
    window in the window server and hands the picture back on a background queue: the main thread only starts the
    request (well under 1 ms) and stores the result. It needs no Screen Recording permission because the app only
    copies its own window, which needs macOS 14.4; on macOS 13 to 14.3 there are simply no thumbnails. CEF's
    off-screen rendering was not used: it would load each page a second time.
32. **When a copy is made:** 1 s after a tab comes on screen or finishes loading (every switch or load restarts the
    wait, so flipping quickly through tabs copies nothing), when the pointer moves over the sidebar, and when the
    Ctrl+Tab switcher opens; at most once every 2 s per tab, one at a time. A copy started before a tab switch is
    thrown away so a picture never shows the wrong page. Pictures are 480 px wide JPEGs of the top of the page (4:3),
    kept in memory only, never saved, and never shown for the tab already on screen. At most 40 pictures are kept
    across all windows (oldest dropped first), so memory stays under about 30 MB however many tabs are open. A tab
    switch itself only bumps a counter and re-arms the 1 s timer; the self-test flips tabs every 0.15 s and checks
    that no copy starts and that the thumbnail code adds under 1 ms to a switch.
33. **Ctrl+Tab held opens a recent-tab switcher**, as Arc's "tab switcher, like Command+Tab": the shown tab first,
    then the most recently used tabs of the Space (up to 8, fewer if the window is narrow), with the previous tab
    selected. Tab / Shift+Tab or the arrow keys move, releasing Ctrl switches, Esc cancels, a click picks a tile. The
    panel only appears after 0.12 s, so a quick Ctrl+Tab still flips straight to the previous tab. Choosing the menu
    item with the mouse switches directly. Ctrl+Shift+Tab to open it backwards wasn't added (no free shortcut was
    asked for); Shift+Tab works once it is open.

## 2026-11-09: Notes look, split panes and Markdown export (#50)
15. **Note lists are text markers, not AppKit text lists.** Bulleted, numbered and checklist items start with "•",
    "1." or "☐"/"☑" and a tab, with a hanging indent. AppKit's own lists (NSTextList) store their markers differently
    from macOS 26 on, so plain markers are the only form that reads the same in RTF, plain-text copies and every
    TextKit version. Clicking a box ticks it; Return continues a list and Return on an empty item ends it. Format >
    Lists... (AppKit's list panel) was replaced by the note's own list commands.
16. **Title and headings in Markdown:** the note's first line exports as `# Title`; Heading 1-3 export one level
    down (`##` to `####`) so a note has one top-level heading. Underline has no Markdown form and exports as
    `<u>...</u>`; strikethrough as `~~...~~`; checklists as `- [ ]` / `- [x]`. Images are left out.
17. **Arc's format bar wording isn't copied.** NotArc's bar uses plain names (Body, Heading 1-3, Bold, ...) and SF
    Symbols. No keyboard shortcuts were added for the new commands (Arc's aren't known); Cmd+B/I/U still work.
18. **A note is one document:** Open in Split View on a note moves it into the split rather than opening a copy, and
    pasting or typing a `notarc://note/...` address into a split does the same.

## 2026-11-09: Live Folders, finished (#55)

15. **My Pull Requests reads GitHub's own search pages** (`is:pr is:open archived:false author:@me`, then
    `review-requested:@me`, newest updated first) with the Space's cookies through a CEF request in that Space's
    request context, and parses the page: the pull request links in the server-rendered results, or the page data
    GitHub embeds as JSON when a page is client-rendered. Signed in or not comes from GitHub's `user-login` meta tag.
    Not signed in shows one "Sign in to GitHub to see your pull requests" entry that opens GitHub's sign-in page in that
    Space; when that tab lands back on github.com the folder refreshes. Signed in with nothing open shows "No open
    pull requests". One such folder per Space (asking again shows the existing one). Arc's GitHub SSO prompt, review
    status subtitles and team pull requests are not copied.
16. **YouTube channels:** an address with `/channel/UC...` is used as is; `@handle`, `/c/`, `/user/` and video
    addresses are read once to find the channel id (the page's canonical link, else its channel id fields), and the
    folder is named after the channel. Videos come from `youtube.com/feeds/videos.xml?channel_id=...` (newest 15, as
    YouTube serves them).
17. **Unread:** entries added by a refresh after the folder's first fill come in unread (Arc: showNewItemsAsUnread);
    the first fill and the sign-in / "No open pull requests" entries never do. The tab shows a small accent-colour dot,
    the folder row a count; opening the tab clears it. Unread is saved with the sidebar.

## 2026-11-09: Boost editor and colour wheel (#51)
1. **The Boost tint is a "color" blend now, not a "hue" blend.** The new wheel has saturation toward its centre, and
   a hue blend ignores the overlay's saturation, so the wheel's radius would do nothing. With a colour blend the page
   keeps its lightness, the rim gives full colour and the centre greys the page; the Intensity slider sets how much
   of it shows. Older Boosts (no saturation saved) start at 85% saturation, the old fixed value.
2. **The editor's slider is Intensity (the overlay's strength),** standing in for Arc's brightness control. Arc's
   advanced colour controls (secondary hue, invert lightness) are not built.
3. **The editor is a floating card, not Arc's shelf docked to the window.** It follows the Space's light/dark look and
   uses NotArc's Arc colours (tile fills from the sidebar rows, Arc blue for the chosen tile). The wheel, tiles and
   icons are drawn in code or are SF Symbols; nothing comes from Arc's app.
4. **Font tiles:** Page, System, Georgia, Helvetica, Avenir, Menlo, Times, Futura, Gill Sans and Rounded (Arial
   Rounded MT Bold, which ships with macOS). Baskerville left the list; a Boost that already uses it keeps it.
5. **Text case cycles Original, UPPER, lower, Title** (Arc's Boosts had capitalize as well).

## 2026-11-09: Settings panes, app icon choice, Developer Mode (#72, #74, #68)

1. **Settings panes follow Arc's names** (General, Profiles, Links, Max, Advanced), with Arc's separate App Icon pane
   folded into a new **Appearance** pane next to the default Space appearance. Panes are listed in one place
   (`-buildPanes` in `app/settings.mm`); the Max pane goes between Links and Advanced and is added by its own PR.
2. **Default Space appearance:** Settings > Appearance sets Light, Dark or Automatic for every Space that hasn't chosen
   its own. The Space menu's "Automatic" entry is renamed "Default (Settings)", because it now means "use the
   Settings choice", which is still "follow macOS" until changed.
3. **App icons are NotArc's own**, drawn in code (`app/app_icons.mm`): six colourways of one mark, a window with a
   sidebar. Nothing comes from Arc. The choice is applied with `NSApp.applicationIconImage` at launch and at once
   when picked. The signed app bundle is never changed, so Finder, and the Dock while NotArc is closed, keep the
   bundle's icon. Arc kept its icon in the Dock after quitting with a Dock tile plug-in; that is left out because it
   means shipping a second signed bundle.
4. **Developer Mode is per site and stored by host** (without "www.", ports ignored), as in Arc's
   `developerModeEnabledForHosts`. It is on by itself for localhost, *.localhost, 127.x.x.x, ::1 and *.local; a
   setting in Settings > Advanced turns that off, and each site can still be switched either way. In Developer Mode
   the sidebar pill shows the address without its scheme (host:port/path?query), so the port stays visible in the
   narrow pill; the full address is in the pill's tooltip.
5. **Developer Tools from the pill is a click away, never automatic.** The pitfalls rule (no DevTools sessions on tabs
   in the background) still holds; the self-test only checks that the button is shown, it never opens DevTools.
6. **Reset All Settings** resets every preference shown in Settings (including the app icon, Space appearance and
   Developer Mode sites). Spaces, tabs, profiles, history, site permissions, ad-blocking exceptions and keyboard
   shortcuts are kept: those are data or have their own reset.
