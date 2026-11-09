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
