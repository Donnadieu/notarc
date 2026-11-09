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
