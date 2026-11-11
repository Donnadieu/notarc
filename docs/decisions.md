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
34. **Note lists are text markers, not AppKit text lists.** Bulleted, numbered and checklist items start with "•",
    "1." or "☐"/"☑" and a tab, with a hanging indent. AppKit's own lists (NSTextList) store their markers differently
    from macOS 26 on, so plain markers are the only form that reads the same in RTF, plain-text copies and every
    TextKit version. Clicking a box ticks it; Return continues a list and Return on an empty item ends it. Format >
    Lists... (AppKit's list panel) was replaced by the note's own list commands.
35. **Title and headings in Markdown:** the note's first line exports as `# Title`; Heading 1-3 export one level
    down (`##` to `####`) so a note has one top-level heading. Underline has no Markdown form and exports as
    `<u>...</u>`; strikethrough as `~~...~~`; checklists as `- [ ]` / `- [x]`. Images are left out.
36. **Arc's format bar wording isn't copied.** NotArc's bar uses plain names (Body, Heading 1-3, Bold, ...) and SF
    Symbols. No keyboard shortcuts were added for the new commands (Arc's aren't known); Cmd+B/I/U still work.
37. **A note is one document:** Open in Split View on a note moves it into the split rather than opening a copy, and
    pasting or typing a `notarc://note/...` address into a split does the same.

## 2026-11-09: Live Folders, finished (#55)

38. **My Pull Requests reads GitHub's own search pages** (`is:pr is:open archived:false author:@me`, then
    `review-requested:@me`, newest updated first) with the Space's cookies through a CEF request in that Space's
    request context, and parses the page: the pull request links in the server-rendered results, or the page data
    GitHub embeds as JSON when a page is client-rendered. Signed in or not comes from GitHub's `user-login` meta tag.
    Not signed in shows one "Sign in to GitHub to see your pull requests" entry that opens GitHub's sign-in page in that
    Space; when that tab lands back on github.com the folder refreshes. Signed in with nothing open shows "No open
    pull requests". One such folder per Space (asking again shows the existing one). Arc's GitHub SSO prompt, review
    status subtitles and team pull requests are not copied.
39. **YouTube channels:** an address with `/channel/UC...` is used as is; `@handle`, `/c/`, `/user/` and video
    addresses are read once to find the channel id (the page's canonical link, else its channel id fields), and the
    folder is named after the channel. Videos come from `youtube.com/feeds/videos.xml?channel_id=...` (newest 15, as
    YouTube serves them).
40. **Unread:** entries added by a refresh after the folder's first fill come in unread (Arc: showNewItemsAsUnread);
    the first fill and the sign-in / "No open pull requests" entries never do. The tab shows a small accent-colour dot,
    the folder row a count; opening the tab clears it. Unread is saved with the sidebar.

## 2026-11-09: Boost editor and colour wheel (#51)
41. **The Boost tint is a "color" blend now, not a "hue" blend.** The new wheel has saturation toward its centre, and
   a hue blend ignores the overlay's saturation, so the wheel's radius would do nothing. With a colour blend the page
   keeps its lightness, the rim gives full colour and the centre greys the page; the Intensity slider sets how much
   of it shows. Older Boosts (no saturation saved) start at 85% saturation, the old fixed value.
42. **The editor's slider is Intensity (the overlay's strength),** standing in for Arc's brightness control. Arc's
   advanced colour controls (secondary hue, invert lightness) are not built.
43. **The editor is a floating card, not Arc's shelf docked to the window.** It follows the Space's light/dark look and
   uses NotArc's Arc colours (tile fills from the sidebar rows, Arc blue for the chosen tile). The wheel, tiles and
   icons are drawn in code or are SF Symbols; nothing comes from Arc's app.
44. **Font tiles:** Page, System, Georgia, Helvetica, Avenir, Menlo, Times, Futura, Gill Sans and Rounded (Arial
   Rounded MT Bold, which ships with macOS). Baskerville left the list; a Boost that already uses it keeps it.
45. **Text case cycles Original, UPPER, lower, Title** (Arc's Boosts had capitalize as well).

## 2026-11-09: Settings panes, app icon choice, Developer Mode (#72, #74, #68)

46. **Settings panes follow Arc's names** (General, Profiles, Links, Max, Advanced), with Arc's separate App Icon pane
   folded into a new **Appearance** pane next to the default Space appearance. Panes are listed in one place
   (`-buildPanes` in `app/settings.mm`); the Max pane goes between Links and Advanced and is added by its own PR.
47. **Default Space appearance:** Settings > Appearance sets Light, Dark or Automatic for every Space that hasn't chosen
   its own. The Space menu's "Automatic" entry is renamed "Default (Settings)", because it now means "use the
   Settings choice", which is still "follow macOS" until changed.
48. **App icons are NotArc's own**, drawn in code (`app/app_icons.mm`): six colourways of one mark, a window with a
   sidebar. Nothing comes from Arc. The choice is applied with `NSApp.applicationIconImage` at launch and at once
   when picked. The signed app bundle is never changed, so Finder, and the Dock while NotArc is closed, keep the
   bundle's icon. Arc kept its icon in the Dock after quitting with a Dock tile plug-in; that is left out because it
   means shipping a second signed bundle.
49. **Developer Mode is per site and stored by host** (without "www.", ports ignored), as in Arc's
   `developerModeEnabledForHosts`. It is on by itself for localhost, *.localhost, 127.x.x.x, ::1 and *.local; a
   setting in Settings > Advanced turns that off, and each site can still be switched either way. In Developer Mode
   the sidebar pill shows the address without its scheme (host:port/path?query), so the port stays visible in the
   narrow pill; the full address is in the pill's tooltip.
50. **Developer Tools from the pill is a click away, never automatic.** The pitfalls rule (no DevTools sessions on tabs
   in the background) still holds; the self-test only checks that the button is shown, it never opens DevTools.
51. **Reset All Settings** resets every preference shown in Settings (including the app icon, Space appearance and
   Developer Mode sites). Spaces, tabs, profiles, history, site permissions, ad-blocking exceptions and keyboard
   shortcuts are kept: those are data or have their own reset.

## 2026-11-09: Arc Max on the Mac (#58, #59)

52. **Swift in the build.** Apple's on-device model (FoundationModels) is Swift-only. `app/on_device_ai.swift` is one
    `@objc` class compiled by a custom `swiftc` step in CMake into an object file and a generated header
    (`NotArcAI-Swift.h`); FoundationModels is weak-linked and checked with `#available(macOS 26, *)` and
    `SystemLanguageModel.default.availability`, so NotArc still runs on macOS 13. Command Line Tools have no macro
    plugins, so `@Generable` is out; replies are plain text, parsed in Objective-C++ with greedy sampling.
53. **Fallbacks keep every command visible.** Without the model: Ask on Page shows the page's sentences that best match
    the question (plus "Ask ChatGPT"), summaries pick the page's key sentences, link previews show the page's own
    description and Tidy Tabs groups by site. Settings > Max turns each feature, or all of Max, off.
54. **Tidy Tabs asks for one topic per tab, not for folders.** The small on-device model gave muddled folders when asked
    for "Folder: 1, 4" groups, but clean ones when it labels each tab ("3: Cooking") and NotArc groups equal labels.
    Only top-level Today tabs are tidied (folders, splits, notes and easels stay put); topics with 2+ tabs become
    folders at the top of Today; Undo (Edit menu and the toast) dissolves them back into the original order.
55. **Ask on Page is Cmd+Shift+A** (Arc folded it into Cmd+F; NotArc keeps Find as Find) and answers in a small panel
    over the page. "Ask ChatGPT" opens `https://chatgpt.com/?q=<question>` (with the page address for page questions)
    in a new tab of the current Space, so it uses that Space's own ChatGPT sign-in.
56. **5-second previews:** hold Shift while pointing at a link (or press Shift while on it); Chromium's link-target
    message tells NotArc which link. The page is fetched with an ephemeral, cookie-less `NSURLSession` (no sign-in,
    nothing stored), only http(s), and summarised on the Mac; results are cached per window for 50 links.
57. **Copy Page as Markdown is NotArc's own DOM walker** (no library): headings, paragraphs, emphasis, inline and block
    code, links and images made absolute, nested lists, quotes and tables; scripts, forms, navigation and hidden
    elements are skipped. It starts from the page's `<article>`/`<main>` when there is one, and adds the title and a
    Source line. Page scripts send results back through tagged console lines with a random nonce, in chunks.
58. **Settings > Max is its own pane** (General, Profiles, Appearance, Links, Max, Advanced), built from one
    self-contained view (`MaxSettingsSection()`). It was a section of the old single Settings window until the
    panes (#72) and Max branches were merged together.
59. **One tidy-title path, model first (#18 + #58).** #18 (merged first) tidies titles with rules on pin and from the
    tab menu. Max doesn't add a second tidy: when Max and its "Tidy tab titles with Apple's model" switch are on and
    the model is available, the same entry points (pin, tab menu's Tidy Title, View > Tidy Tab Title) ask the model,
    and use `TidyTabTitle` when it's off, unavailable or its reply is unusable. Whether pinning tidies at all stays
    #18's "Tidy tab titles when pinning" setting. A model reply that arrives after the tab was renamed is dropped.
    Every tidy (rules or model) is undoable from Edit > Undo as "Tidy Tab Title", besides #18's toast and "Use Page
    Title".
60. **Self-tests never call the real model.** A self-test run installs an "unavailable" model stub at launch, so every
    check (including #18's synchronous SELFTEST-TIDY) sees the same state on any Mac; the Max checks swap in an
    "available" stub with canned replies. The real model's state is only reported (`model=` in SELFTEST-MAX), so the
    live FoundationModels path is untested by the self-test.

## 2026-11-09: passwords and autofill (#67, #63, #150)

61. **NotArc has its own password manager and autofill.** NotArc pages run in CEF's Alloy style by default, which has
    no Chromium password manager or autofill (Chrome-style pages, #66, stay off by default). So NotArc keeps its own
    store and works in the default pages instead of waiting for Chrome-style pages.
62. **Store: one encrypted file, Chromium's scheme, NotArc's own Keychain item.** Logins, addresses and cards live in
    `Application Support/NotArc/Passwords.dat`. The whole file, and inside it each password and card number again, is
    encrypted the way Chromium does it ("v10", AES-128-CBC, key from PBKDF2 over a Keychain password), generalising
    the Arc cookie reader. The password is a random one in a "NotArc Safe Storage" Keychain item that NotArc makes on
    first use (so macOS doesn't ask). NotArc doesn't reuse CEF's "Chromium Safe Storage" item: the Chromium browser
    uses that same name, so the two would share a key and importing from Chromium would mix them up. Self-tests use a
    throwaway in-memory key and `SelfTestPasswords.dat`, and never touch the Keychain. If the file can't be decrypted
    it is never overwritten.
63. **Saving: a small page script reports login submissions; NotArc asks in a toast.** "Save password for <site>?"
    (Save, Never for This Site) or "Update the saved password for <user> on <site>?" (Update). Nothing is saved without
    a click. The script reports through a console line tagged with a per-frame secret made by NotArc, so a message
    only counts for the frame and site it was given to; fills go back only to that frame, and only while it still
    shows that site. "Offer to save passwords" can be turned off in the Passwords window.
64. **Filling only on a user action, never on page load.** A click (or Tab) into an empty login, address or card field
    opens a native menu of the saved entries at the field; Edit > AutoFill > Fill Password (Cmd+\\, chosen by us; Arc
    had no own shortcut) does the same for the page's login field. Logins saved for a site are offered on its other
    subdomains too (shown with the site name); an https login is never offered on an http page. Values are set the
    way typing would (input and change events), so sign-in pages built with React or Vue see them.
65. **Device authentication** (Touch ID or the Mac's password) before Show Password, Copy Password and filling a card;
    the Passwords window then trusts itself for 5 minutes. Copied passwords are marked concealed for clipboard
    managers. Self-tests skip the prompt and count it. Export from the Passwords window is out of scope.
66. **Import from Arc** is part of File > Import Everything from Arc and the first-launch offer: each Space's Chromium
    profile `Login Data` (and `Login Data For Account`) and `Web Data` (addresses and cards), read from a private copy
    with the "Arc Safe Storage" key cookie import already uses. Sites the person told Arc to never save come over as
    "Never" sites. NotArc's own copy of a login wins over an imported one; importing twice adds nothing twice.
67. **Import from Chrome, Brave, Edge, Vivaldi and Chromium** with File > Import Passwords..., same reader, each
    browser's own "<Name> Safe Storage" Keychain item. macOS asks once per browser; that is expected and can't be
    avoided because the item belongs to the other browser.
68. **Safari's passwords can't be read**: they live in Apple's Passwords app, which other apps can't read. The import
    sheet says so and points to Passwords > File > Export All Passwords, and NotArc imports that CSV file (Chrome,
    Firefox and Apple Passwords CSV formats), with a reminder to delete it. This also covers Firefox passwords.
69. **Address and card fields are matched** by their autocomplete attribute first, then by common field names
    (name, email, street, city, state, zip, country, phone, card number, name on card, expiry). The security code is
    never filled or stored. Addresses, cards and passwords come from imports or Add... in the Passwords window (a card
    number must pass the Luhn check). NotArc doesn't offer to save an address or card when a form is submitted, as
    Chromium does; to change one, delete it and add it again.
70. **Needs Omar's eyes:** the fill menu's position next to the field (it opens at the pointer inside cross-site
    frames), the save toast, the Add... form, Touch ID before Show/Copy, and an import from a real Chrome profile (macOS's "allow
    access" prompt). The self-test covers the rest with fixture databases and a local login page.

## 2026-11-09: Chrome extensions, Web Store installs and the picker (#66)

71. **Extensions need Chrome-style pages.** CEF 156's default (Alloy) pages have no extension system; it was removed
    in Chromium 128. The picker button and Manage Extensions only show with Chrome-style pages on (Settings, still
    off by default until typing, focus and full screen are checked on screen). Install Extension... works either
    way: the extension is saved and loads once Chrome-style pages are on. The line stays partial until they're the
    default.
72. **NotArc installs from the Web Store itself.** CEF has no API to install, load or turn off an extension while
    running, and Chromium's own "Add to Chrome" flow isn't wired up in CEF. NotArc downloads the extension's signed
    package from the Web Store's public download address (clients2.google.com, one request per install or update,
    no sign-in), checks every signature in it and that it belongs to the ID asked for, refuses Manifest V2, and
    unpacks it into NotArc's own extensions folder with the manifest "key" set, so it keeps its Web Store ID (and
    its saved settings). Extensions load at startup with `--load-extension`, like the Arc copies.
73. **Changes apply on relaunch.** Install, Remove and Turn Off/On take effect the next time NotArc starts, so each
    one offers "Relaunch Now" (tabs come back). Turned-off extensions are a NotArc list (`disabledExtensions`) that
    is left out of `--load-extension`.
74. **An extension's popup opens in a tab.** CEF has no extension toolbar to anchor Chromium's popup bubble to, so
    "Open" shows the popup page as a new tab. Extensions that act on "the current tab" from their popup may act on
    that tab instead.
75. **The picker sits in the address pill** (puzzle piece, next to Boost, Copy URL and Site Settings), as in Arc's
    URL bar. On a Web Store page it offers "Add This Extension to NotArc". Extensions that Chromium installed into a
    Space's profile by itself are listed too, with "Manage on Extensions Page" (Chromium owns those).
76. **Updates are manual** ("Update from Chrome Web Store" in each extension's menu): unpacked extensions don't
    auto-update, and NotArc doesn't check the Web Store in the background.
77. **Self-test without the network:** the install path is tested with packages NotArc signs in memory during the
    test (fresh RSA key, never stored) and a stubbed download. A test run can turn Chrome-style pages on with
    `NOTARC_CHROME_PAGES=1` (only together with `--selftest`), since the shared runner passes no extra arguments.

## 2026-11-09: ad blocker filter lists (#53)

78. **Filter lists are never bundled.** EasyList and EasyPrivacy are shown as suggestions in Manage Ad Blockers...
   and downloaded from easylist.to only when the person turns one on. Any other list can be added by its http(s) or
   file address (abp:subscribe links work too). Downloaded copies live in Application Support/NotArc/Filter Lists.
79. **Only a common subset of Adblock Plus syntax is used:** "||host^" network rules with $third-party, $domain= and
   resource-type options ($script, $image, $important, ...), "@@" exceptions (including $document, $elemhide and
   $generichide for whole pages), and "##selector" / "domain##selector" / "~domain##selector" / "#@#" cosmetic rules.
   Path and wildcard patterns, $popup, $csp, $redirect, scriptlets (##+js) and procedural selectors (:has-text and
   friends) are skipped; the dialog's rule count only counts rules NotArc understands. This covers the bulk of
   EasyList (about 68,000 of its rules) and EasyPrivacy (about 47,000).
80. **The existing safety rules still win over any list:** the page itself (main frame) and requests to the page's own
   site are never blocked, so first-party-only rules ($~third-party, $1p) are skipped as they could never apply.
81. **Cosmetic hiding is a style sheet injected when the page finishes loading**, the same way Boosts are, rather than
   at document start. Ads can show for a moment before they're hidden; network blocking already stops most of them.
82. **The built-in host list stays, with its own switch** in the dialog (on by default). The master switch is still
   Settings > Block ads & trackers (off by default, as Arc's was); lists only download, refresh and apply while it's on.
83. **Daily refresh** checks hourly for turned-on lists last downloaded over 24 hours ago. Self-tests never download:
   they subscribe to a local file:// fixture and the refresh timer doesn't start in test runs.

## 2026-11-09: finishing Easels (#49)

84. **Live web clips refresh in a hidden off-screen browser, not from the user's tabs.** A clip stores the page
    address, the dragged region, the page's size and its scroll position. To refresh, NotArc loads the address in a
    short-lived windowless (off-screen rendered) browser in the Space's own profile (so signed-in pages show the same
    content), scrolls to the saved spot, crops the region from the rendered pixels and closes the browser. No DevTools
    on tabs and nothing tied to tab switching: the work only starts when an easel with clips is opened and a clip is
    more than a minute old, or from File > Refresh Live Clips, and it runs asynchronously (the page renders in
    Chromium's own processes, the main thread only copies the cropped pixels, PNG encoding runs on a background
    queue). This needs CEF's
    `windowless_rendering_enabled` at startup; tabs stay windowed. Arc's clips were live views of the page; a refreshed
    picture is the closest local equivalent without keeping a hidden page running per clip.
85. **Clips render at 100% zoom** with the page size the tab had when clipped. A page zoomed in the tab at clip time
    can show a slightly different area after a refresh. Pages that need a click or a scroll inside a frame to show the
    clipped part show their default state.
86. **Drawing tools follow Arc's set (arrow, rectangle, ellipse, freehand) with eight colours of NotArc's own.**
    Shapes are outlines, not filled, and are only clickable near their line, so a capture under an arrow can still be
    picked. Single-letter tool keys (V, T, A, R, O, P) are a guess; Arc's own key bindings weren't recoverable.
87. **Resizing uses four corner handles; pictures and clips keep their proportions, text boxes and drawings don't.**

## 2026-11-09: extension popups and relaunch (#66)

88. **An extension's popup opens in a bubble, not a tab** (replaces 74). Open in the picker shows the extension's
    action popup (manifest `action.default_popup`) in a small borderless panel just under the picker button, left
    edges lined up and kept inside the window, as Chrome and Arc do. The page is a Chrome-style page of its own
    (ChromePageHost, CEF's Views) in the Space's profile, hosted in NotArc's panel, so extension APIs work and the
    popup sees the Space's sign-ins. Links and windows it opens become NotArc tabs. Extensions without a popup have
    no Open item, as before.
89. **The bubble takes the popup's own size, within Chrome's limits** (25x25 to 800x600): Chromium's auto-resize
    reports the page's preferred size (CefBrowserHost::SetAutoResizeEnabled); if it never reports, a small script
    measures the page at its natural width on load and whenever its body changes size. The bubble opens once the
    size is known, or after a second at the smallest size, growing when the page reports.
90. **It closes on** Esc, a click anywhere outside it, the window moving, resizing, closing or changing full screen,
    another window taking focus, NotArc going to the background, a Space switch, or the page calling window.close().
    Esc always closes it: unlike Chrome, the page doesn't get Esc first.
91. **The picker stays a menu**, so an extension's popup is the first item of its row, Open: a menu row that holds
    the extension's actions can't also be clicked.
92. **A relaunch stays necessary.** CEF 156 has no API to load, unload, turn off or update an extension while
    running; Chrome-style extensions load at startup (`--load-extension`). After Install, Update, Remove, Turn
    Off/On or an Arc import, NotArc's usual toast says "Relaunch to apply" with Relaunch Now, which quits and reopens
    the same copy of NotArc through the updater's relaunch path (it asks first if downloads are running, since
    quitting cancels them); session restore brings the tabs back. If Chrome-style pages are set to be off next time,
    the toast says extensions need them instead.
93. **Installing or importing an extension turns Chrome-style pages on** (replaces "Install Extension... works either
    way" in 71). CEF 156's default (Alloy) pages can't run extensions at all: the extension system only exists in
    Chrome-style pages. So with them off, Install Extension... says so in its sheet and its button reads "Turn On and
    Install", and File > Import Extensions from Arc asks "Turn On and Import" / Cancel first. The setting flips only
    once something was actually installed or copied, and takes effect on the relaunch. Import Everything from Arc
    (the first-launch offer) leaves the setting alone: it's a broad import, and Chrome-style pages are still being
    checked on screen.
94. **Self-tests load the fixture extension in every run**, with either setting, so the bubble (a Chrome-style page of
    its own) is checked every time; tabs stay Alloy-style unless Chrome-style pages are on. The bubble never becomes
    key in a test, keeps the test window's 1% alpha and ignores clicks; Esc and an outside click go through the
    bubble's own event handler, and Relaunch Now is counted instead of relaunching.

## 2026-11-09: signed and notarized releases

95. **Releases are signed with a Developer ID Application certificate and notarized** (from 0.26.0; until 0.25.0 they
    were ad-hoc signed and macOS made people allow them by hand). `scripts/package.sh` signs inside-out with the
    hardened runtime: CEF's dylibs, the framework, each `NotArc Helper*.app` (`app/helper.entitlements`), then the app
    (`app/NotArc.entitlements`). Chromium needs JIT and unsigned executable memory under the hardened runtime, and
    library validation is off as Chrome-family apps do; the app also gets the camera, microphone, location, USB,
    Bluetooth, print and calendar keys its Info.plist already describes. The app is notarized and stapled before it
    goes into the dmg (the updater copies the app out of the dmg), then the dmg is signed, notarized and stapled. The
    identity and notary profile come from the environment; `NOTARC_ADHOC=1` makes a local unsigned build that must
    never be published.
96. **The updater still checks only the SHA-256**, not the signing identity, so ad-hoc copies (0.25.0 and earlier)
    update to signed ones. Because the signature changes, macOS treats the first signed launch as a new app for
    Keychain items and privacy permissions, and may ask once more.

## 2026-11-10: Dock icon, Arc import offer, logins on re-import

97. **The bundle icon (Icon A, "¬" on indigo) is the default app icon and the first tile in Settings > Appearance.**
    Choosing it sets `NSApp.applicationIconImage` to nil, so the Dock, Finder and Launchpad show the same signed
    `NotArc.icns`. The six drawn colourways stay as options. Builds before 0.26.1 had no bundle tile and older self-test
    runs could save a colourway into the real preferences, so the saved `appIcon` is cleared once at launch
    (`appIconBundleDefault` marks it done; never in self-tests).
98. **The Arc import offer is keyed on what happened, not on having been offered.** It shows at launch while
    `~/Library/Application Support/Arc/User Data` exists and neither `arcImportCompleted` (set when Import Everything
    finishes) nor `arcImportNotNow` (Not Now) is set. The old `arcImportOffered` key is ignored: test and dev launches
    set it without the person ever seeing the sheet. It waits for any other sheet and for the window to be on screen.
    Settings > Profiles has an Import Everything from Arc button too.
99. **Import Everything copies Arc's cookies again, for every Space profile, each time it runs.** They go through each
    Space's CEF cookie manager (`SetCookie`), so Chromium stores them encrypted with NotArc's own Safe Storage key; an
    existing cookie with the same name, domain and path is replaced by Arc's copy. Writing NotArc's Cookies SQLite
    directly was ruled out: CEF holds it open and re-encrypting by hand would duplicate Chromium's code. The one-time
    automatic copy on a Space's first start stays. Arc's key is read once per import (one Keychain prompt at most), on
    a background queue. Unencrypted legacy rows are copied as they are; expired rows are skipped and counted.
100. **Import errors are shown in plain words** in the summary sheet (no key from macOS, NotArc's vault locked, no Arc
    files in a profile, Arc's key didn't unlock its cookies, cookies the store refused), and the sheet warns that a few
    sites may still ask to sign in again (sessions tied to a device or an IP address). Saved passwords NotArc already
    has are counted as "already here" rather than shown as 0 added.

## 2026-11-10: visual parity with Arc

101. **"Done" now means it looks like Arc, not only that it works.** `docs/visual-parity.md` lists every screen and
    state (66 items) with what Arc does and the reference used. A box is ticked only after a hidden render of NotArc
    matches the reference. Arc is never launched for this: the references are Omar's own Arc screenshots, Arc's
    colours and labels, Arc's help pages and public screenshots and videos.
102. **Hidden renders are a built-in switch, `--visual-shots=<plan>`.** It runs with the self-test's isolation and
    keeps the window 30,000 pt off screen at full opacity, so each check is a PNG and no window ever shows. It's kept
    in the app (not a local patch) because every visual item needs it, before and after.
103. **The sidebar scroller is always the overlay kind (V1).** macOS switches scroll views to the always-visible style
    when a mouse is attached; Arc's sidebar never shows a track, so the sidebar's scroll view refuses that switch.
104. **Tab rows fade long titles and show a close button on hover (V2).** Arc 1.169 fades titles (Arc's 2022 videos
    still show "..."); its videos show no cross on the selected row until the pointer is over it. The cross is a
    plain "x" with Arc's hover fill. On a Today tab it archives the tab (like Cmd+W); on a pinned tab or Favorite it unloads
    it and keeps the row. Closing a row that isn't shown keeps the shown tab.
105. **The mini player reads what's playing from the page (V3).** Title, artist and artwork come from the page's
    media session; without one, the page title is used with running clocks taken out. Back and forward show only
    when the page handles previous / next track, because a button that does nothing is worse than none. Mute shows
    only while the pointer is over the card (or while muted), to leave room for the title. Artwork is fetched once
    per address and never in test runs.
106. **Archive is a sidebar panel (V4).** It replaces Favorites, the Space title and the tabs, under the address
    pill. All archived tabs are listed (6,586 imported from Arc is fine: the list only draws the rows on screen),
    newest first, under day headings. One click reopens a tab, like a tab row. The old table window is gone; History
    keeps its own window for now (Arc had no history panel).
107. **The command bar follows Arc's own videos (V5).** Measured from Arc's multitasking video: the card is about 65%
    of the window wide (here 480-780 pt), its top 26% down, 64 pt input row and 50 pt rows; the window behind is
    dimmed in the Space's colour and the selected row is the Space's colour, a shade deeper (Arc blue on the default
    theme). The card is opaque, so the page never shows through. "Switch to Tab" and its arrow show on every open-tab
    row; other rows show Return's action only when selected.
108. **Omar's own Arc screenshot (Oct 26, 1x, dark) is the first reference for the sidebar.** A hidden NotArc render
    at the same window height is measured against it pixel by pixel (pill, Favorites rows, divider, rows, media bar,
    bottom bar all within 2 pt). Where it disagrees with an earlier call, the screenshot wins: long titles end in
    "..." (replaces 104's fade), and the mini player is Arc's 32 pt icon-and-controls bar with no text (replaces 105's
    two-line card; title, artist and artwork are still read from the page, for the tooltip and the icon).
109. **Back and forward in the mini player always show.** Arc shows them for every site; a page without its own
    previous / next track handler skips 10 s back or forward instead.
110. **The pill's site buttons show on hover only (V12).** The screenshot shows a bare pill with just the site; the
    buttons appear when the pointer is over it. A site with a Boost on keeps its Boost button visible, so you can
    still see the Boost is on.
111. **The floating sidebar opens from a 6 pt strip at the window's left edge (V23)** and closes a quarter second after
    the pointer leaves it (not while the command bar is open). It's drawn in the Space's first colour with Arc's
    rounded corners and shadow; Reduce Motion turns the slide off.
112. **The loading glow is a short band in the Space's colour sweeping along the card's top edge (V9).** Arc's own
    glow is a Metal shader we can't copy; this keeps the idea (a moving glow, not a progress bar) with plain Core
    Animation. Reduce Motion leaves it still.
113. **Inactive windows dim the sidebar's content to 55% (V8),** the Space colour stays. The window counts as active
    while it's the main window, so the command bar (a child panel taking key focus) doesn't dim it.
114. **Cmd+L opens the command bar on the address pill, without dimming (V29);** only Cmd+T (a new tab) gets the big
    centred bar over a dimmed window. Arc names both placements (top-left and centred); which one dims is our call.
115. **Peek stays a separate child window, drawn as a card (V39).** It keeps its own browser so Open as Tab still
    moves the page without reloading; the title bar is hidden and the window is clear around a rounded card, so it
    looks like Arc's in-window card.
116. **Background update checks download first, then offer a restart in the sidebar (V27),** like Arc. They stay
    under the existing "Check for updates" setting and still honour Skip This Version; the menu's Check for Updates
    keeps its dialog. Self-tests only post the "ready" notice and count the Restart click.
117. **The + menu stays a native menu (V25).** Arc builds it from AppKit menu items with its own icons; NotArc uses the
    same kind of menu with SF Symbols. A native menu can't be drawn without showing it on screen, so its check is the
    self-test (every row has an icon, Arc's order), not a picture.
118. **The Ctrl+Tab switcher's chosen tile uses a neutral light plate, not the accent colour (V33),** like the macOS
    app switcher Arc's design follows. No Arc picture of it was available; this is a taste call for Omar to check.
