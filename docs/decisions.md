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

## 2026-11-09: ad blocker filter lists (#53)

1. **Filter lists are never bundled.** EasyList and EasyPrivacy are shown as suggestions in Manage Ad Blockers...
   and downloaded from easylist.to only when the person turns one on. Any other list can be added by its http(s) or
   file address (abp:subscribe links work too). Downloaded copies live in Application Support/NotArc/Filter Lists.
2. **Only a common subset of Adblock Plus syntax is used:** "||host^" network rules with $third-party, $domain= and
   resource-type options ($script, $image, $important, ...), "@@" exceptions (including $document, $elemhide and
   $generichide for whole pages), and "##selector" / "domain##selector" / "~domain##selector" / "#@#" cosmetic rules.
   Path and wildcard patterns, $popup, $csp, $redirect, scriptlets (##+js) and procedural selectors (:has-text and
   friends) are skipped; the dialog's rule count only counts rules NotArc understands. This covers the bulk of
   EasyList (about 68,000 of its rules) and EasyPrivacy (about 47,000).
3. **The existing safety rules still win over any list:** the page itself (main frame) and requests to the page's own
   site are never blocked, so first-party-only rules ($~third-party, $1p) are skipped as they could never apply.
4. **Cosmetic hiding is a style sheet injected when the page finishes loading**, the same way Boosts are, rather than
   at document start. Ads can show for a moment before they're hidden; network blocking already stops most of them.
5. **The built-in host list stays, with its own switch** in the dialog (on by default). The master switch is still
   Settings > Block ads & trackers (off by default, as Arc's was); lists only download, refresh and apply while it's on.
6. **Daily refresh** checks hourly for turned-on lists last downloaded over 24 hours ago. Self-tests never download:
   they subscribe to a local file:// fixture and the refresh timer doesn't start in test runs.
