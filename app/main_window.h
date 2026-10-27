// Main browser window: Arc-style vertical sidebar (Space switcher, Favorites, Pinned, Today,
// folders) on the left, web content on the right, plus a command bar.
#pragma once

#import <Cocoa/Cocoa.h>

#import "app/arc_import.h"
#import "app/archive_store.h"

// URL with tracking parameters (utm_*, fbclid, gclid, ...) removed; other parameters keep their order.
NSString* CleanLinkURL(NSString* url);

@class Boost;
@class EaselView;
NSInteger UnreadCountFromTitle(NSString* title);
NSInteger SwipeDirectionForScroll(CGFloat dx, CGFloat dy, BOOL precise, BOOL began);  // -1 back, 1 forward, 0 none  // "Inbox (12)" -> 12

@interface MainWindowController : NSWindowController <NSWindowDelegate>
- (instancetype)initWithSpaces:(NSArray<ArcSpace*>*)spaces focusedSpaceID:(NSString*)focusedID;
// Self-test: Space profiles live in separate "SelfTest Space ..." folders and Arc cookies are not imported,
// so tests never read or change the real profiles.
@property(nonatomic) BOOL selfTestProfiles;
@property(nonatomic, copy) NSString* storePath;  // where the sidebar is saved; nil = don't save
- (void)saveSidebarNow;
- (void)createBrowsers;  // after CefInitialize; opens the first tab of the focused Space
- (void)openTabsForSelfTest:(NSUInteger)count;
- (NSArray<NSDictionary*>*)tabSnapshot;  // tabs that have a live web view
- (void)closeAllBrowsers;

// Command bar / tab actions (menu: Cmd+T, Cmd+L, Cmd+W).
- (IBAction)newTab:(id)sender;
- (IBAction)openLocation:(id)sender;
- (IBAction)closeTab:(id)sender;
- (void)openInNewTab:(NSString*)input;  // URL or search text; new tab at top of Today
- (void)navigateCurrentTab:(NSString*)input;
- (void)closeCurrentTab;

// Sidebar organisation (Arc: drag and drop, Cmd+D pin/unpin, New Folder).
- (IBAction)togglePin:(id)sender;
- (IBAction)newFolder:(id)sender;
- (ArcItem*)createFolderNamed:(NSString*)name;  // at the top of the current Space's Pinned section
// Moves item under parent at index (clamped). Refuses sections, cycles and moves across Spaces.
- (BOOL)moveItem:(ArcItem*)item toParent:(ArcItem*)parent index:(NSInteger)index;
- (ArcItem*)tabWithURLPrefix:(NSString*)prefix;  // current Space, for tests
- (ArcItem*)currentPinnedSection;

// Browser basics (Arc: View / History / Developer menus).
- (IBAction)goBack:(id)sender;
- (IBAction)goForward:(id)sender;
- (IBAction)reloadPage:(id)sender;
- (IBAction)hardReload:(id)sender;
- (IBAction)zoomIn:(id)sender;
- (IBAction)zoomOut:(id)sender;
- (IBAction)actualSize:(id)sender;
- (IBAction)findInPage:(id)sender;
- (IBAction)findNext:(id)sender;
- (IBAction)findPrevious:(id)sender;
- (IBAction)toggleDevTools:(id)sender;
- (IBAction)copyCurrentURL:(id)sender;          // Cmd+Shift+C in Arc
- (IBAction)copyCurrentURLAsMarkdown:(id)sender;  // Cmd+Shift+Opt+C in Arc
- (void)findText:(NSString*)text forward:(BOOL)forward;
@property(nonatomic, readonly) int lastFindCount;  // tests
- (double)currentZoomLevel;                       // tests
- (BOOL)canGoBack;                                // tests
- (NSString*)currentURL;                          // tests
- (BOOL)hasLiveBrowser;                           // tests: the shown tab has a web view
- (void)startDownload:(NSString*)url;  // downloads url from the shown tab
- (BOOL)isLoading;                                // tests: the shown tab is still loading

// Split view: up to 4 tabs side by side (vertical) or stacked (horizontal) in one window.
- (IBAction)addVerticalSplit:(id)sender;    // Ctrl+Shift+=
- (IBAction)addHorizontalSplit:(id)sender;  // Ctrl+Shift+-
- (IBAction)closeSplitPane:(id)sender;      // Ctrl+Shift+W
- (IBAction)focusNextPane:(id)sender;       // Ctrl+Shift+]
- (void)openInSplit:(NSString*)input horizontal:(BOOL)horizontal;
- (NSArray<NSValue*>*)paneFrames;  // tests: frames of the visible panes

// Little Window (Arc: Little Arc): quick-look window for links from other apps (Cmd+Opt+Shift+N for a blank one).
- (void)openLittleWindow:(NSString*)input;
- (IBAction)newLittleWindow:(id)sender;
- (NSUInteger)littleWindowCount;                 // tests
- (void)moveLittleWindowToMain:(NSUInteger)index;
- (void)moveLittleWindow:(NSUInteger)index toSpaceAtIndex:(NSUInteger)spaceIndex;  // tests: its Move to Space menu  // tests: same as its "Open in NotArc" button
- (void)closeLittleWindow:(NSUInteger)index;       // tests

// Links asking for a new tab/window: Shift-click (disposition NEW_WINDOW) opens Peek from any tab, like
// Arc's "Open a Peek window when clicking on links with Shift held"; Cmd-click and target=_blank open a
// Today tab (Cmd-click in the background). Returns YES when handled.
- (BOOL)handleOpenURL:(NSString*)url fromBrowser:(int)browserId disposition:(int)disposition userGesture:(BOOL)gesture;
- (void)openInNewTab:(NSString*)input background:(BOOL)background;
// Split directions (Arc: Add Left/Right/Top/Bottom Split) and Convert to Horizontal/Vertical Split View.
- (IBAction)addLeftSplit:(id)sender;
- (IBAction)addTopSplit:(id)sender;
- (IBAction)flipSplitLayout:(id)sender;
- (void)openInSplit:(NSString*)input horizontal:(BOOL)horizontal before:(BOOL)before;
- (NSUInteger)indexOfShownInSplit;  // tests
// A split is one sidebar item (Arc does the same). Dragging a divider resizes the panes on either side.
- (ArcItem*)splitGroupOfShown;                                   // nil when the shown tab isn't split
- (void)moveDivider:(NSUInteger)index toPosition:(CGFloat)position;  // position: 0-1 along the split
- (NSUInteger)dividerCount;                                      // tests

// Peek: links clicked on a Pinned tab or Favorite that leave its site open in an overlay instead
// of navigating the tab away, so the pinned page stays put.
- (BOOL)shouldPeekFromItem:(ArcItem*)item toURL:(NSString*)url;
- (void)openPeek:(NSString*)url;
- (BOOL)isPeeking;              // tests
- (void)promotePeekToTab;       // tests: same as "Open as Tab"
- (void)closePeek;              // tests

// Spaces: create, rename, delete (tabs go to the Archive), reorder, switch (Ctrl+1-9).
- (IBAction)newSpace:(id)sender;
- (IBAction)renameCurrentSpace:(id)sender;
- (IBAction)deleteCurrentSpace:(id)sender;
- (IBAction)moveSpaceUp:(id)sender;
- (IBAction)moveSpaceDown:(id)sender;
- (IBAction)nextSpace:(id)sender;
- (IBAction)previousSpace:(id)sender;
- (IBAction)selectSpaceFromMenu:(NSMenuItem*)sender;  // tag = index
- (ArcSpace*)createSpaceNamed:(NSString*)name;
- (void)renameSpace:(ArcSpace*)space to:(NSString*)name;
- (BOOL)deleteSpace:(ArcSpace*)space;
// Profiles (Arc: each Space belongs to a browser profile with its own logins, history and Favorites).
// Keyed by profile folder ("Profile 4"); names come from Arc on first launch and are saved in Profiles.json.
- (NSUInteger)importArcHistory;
// One button for everything that can come over from Arc today: history and extensions (logins come over on
// each Space's first page load). Returns counts: @"history", @"extensions", @"skipped".
- (NSDictionary<NSString*, NSNumber*>*)importEverythingFromArcInto:(NSString*)extensionsDir userData:(NSString*)userData;
- (void)offerArcImportIfFirstLaunch;  // first real launch only: "Bring everything over from Arc?"
// File > Import Extensions from Arc: copies the Spaces' Arc extensions; they load with Chrome-style pages.
- (NSArray*)importArcExtensionsInto:(NSString*)destination fromArcUserData:(NSString*)userData;  // File > Import History from Arc: each Space's Arc profile history; returns visits added
- (NSArray<NSString*>*)profileDirectories;            // in display order
- (NSString*)nameOfProfile:(NSString*)profileDirectory;
- (NSString*)createProfileNamed:(NSString*)name;      // returns the new profile folder
- (void)renameProfile:(NSString*)profileDirectory to:(NSString*)name;
- (void)assignSpace:(ArcSpace*)space toProfile:(NSString*)profileDirectory;
- (void)moveSpace:(ArcSpace*)space by:(NSInteger)delta;
- (void)selectSpaceAtIndex:(NSUInteger)index;
- (NSArray<ArcSpace*>*)spaces;
- (ArcSpace*)currentSpace;

// Shortcuts matching Arc's: Cmd+S sidebar, Cmd+1-9 tab N, Cmd+Opt+Up/Down tabs, Cmd+Shift+K clear Today,
// Ctrl+Shift+1-4 split pane N.
- (IBAction)toggleSidebar:(id)sender;
- (IBAction)selectTabFromMenu:(NSMenuItem*)sender;  // tag = index
- (IBAction)nextTab:(id)sender;
- (IBAction)switchToRecentTab:(id)sender;  // Ctrl+Tab: the most recently used other tab in this Space
- (IBAction)pasteAndGo:(id)sender;          // clipboard URL or search text -> new Today tab
- (IBAction)printPage:(id)sender;
// Focus mode: hides the sidebar and the window's title-bar buttons so only the page shows. The
// same command (Cmd+Opt+Shift+F) leaves it; full screen is the standard macOS one (Ctrl+Cmd+F).
@property(nonatomic, readonly) BOOL focusMode;
- (IBAction)toggleFocusMode:(id)sender;
// Space themes (Arc: Edit Theme Color, Change Space Icon). nil/empty colours = no theme.
- (void)setTheme:(NSArray<NSString*>*)colors intensity:(double)intensity forSpace:(ArcSpace*)space;
- (void)setIcon:(NSString*)emoji forSpace:(ArcSpace*)space;
- (void)switchToSpace:(ArcSpace*)space;
- (IBAction)editThemeColor:(id)sender;
// Hover cards: resting the pointer on a sidebar tab for a moment shows a card with its title, site,
// full address and when it was last used. Returns the card's text lines (for tests).
- (NSArray<NSString*>*)showHoverCardForItem:(ArcItem*)item;
// Media in the sidebar: tabs playing sound show a speaker; a bar at the bottom of the sidebar controls the
// tab that is playing (or was last playing) while you look at another tab.
- (void)toggleMuteItem:(ArcItem*)item;
- (void)togglePlayItem:(ArcItem*)item;   // pauses playing media, or resumes media this tab paused
- (void)pollMediaNow;                    // asks every open tab for its media state
@property(nonatomic, readonly) ArcItem* mediaBarItem;  // tab shown in the media bar, nil when hidden
- (IBAction)toggleMuteCurrentTab:(id)sender;
- (void)runJS:(NSString*)js inItem:(ArcItem*)item;
// Crashed and frozen pages: a crashed tab shows "This page crashed" with Reload; a page that stops
// responding gets a sheet offering Wait or Exit Page (which shows the crashed view).
- (void)reloadCrashedItem:(ArcItem*)item;
// Multi-select: Cmd/Shift-click selects several sidebar rows; the sidebar menu then acts on all of them.
- (NSArray<ArcItem*>*)selectedSidebarItems;
- (void)selectSidebarItems:(NSArray<ArcItem*>*)items;
- (void)archiveItems:(NSArray<ArcItem*>*)items;          // Today tabs archived, pinned tabs closed (kept)
- (NSString*)linksForItems:(NSArray<ArcItem*>*)items markdown:(BOOL)markdown;
- (ArcItem*)newFolderWithItems:(NSArray<ArcItem*>*)items;
- (ArcItem*)newNestedFolderIn:(ArcItem*)folder;
// Closing a Peek without opening it as a tab offers "Undo" (toast for 6 s, and Edit > Undo / Cmd+Z).
- (IBAction)reopenClosedPeek:(id)sender;
// View > Show Toolbar: back/forward/reload and the full address above the page (Enter goes to what you type).
// View > Hide Space Header: hides the Space picker at the top of the sidebar. Both are remembered.
- (IBAction)toggleToolbar:(id)sender;
// Site prompts. Permission requests (camera, microphone, location, notifications, ...) and links that open
// another app show a sheet; "Remember for this site" stores the answer in the sitePermissions setting.
// Tab > Reset Site Permissions forgets them for the current site.
@property(nonatomic, readonly) NSString* pendingSitePrompt;  // tests: kind:origin of the sheet showing, or nil
- (void)answerSitePrompt:(BOOL)allow remember:(BOOL)remember;  // tests: same as clicking the sheet
- (IBAction)resetSitePermissions:(id)sender;
// View > Site Settings (Cmd+Shift+I): popover for the current site with its connection security, a row per
// common permission (Ask / Allow / Block), Clear Cookies and Refresh, and Reset Permissions.
- (IBAction)showSiteSettings:(id)sender;
@property(nonatomic, readonly) BOOL siteSettingsShown;
- (NSArray<NSString*>*)siteSettingsRows;  // tests: "name=ask|allow|block" for each row, then "secure=0|1"
- (void)setSitePermission:(NSString*)name value:(NSNumber*)allow forOrigin:(NSString*)origin;  // nil = ask
- (NSDictionary*)sitePermissionsForOrigin:(NSString*)origin;
// Command bar suggestions. Each is @{kind, title, subtitle, key} plus the object it acts on; kinds:
// "go" (typed text), "tab" (switch to an open/pinned tab in any Space), "space", "history", "action" (menu
// command), "site" (top visited site, shown when the field is empty). Picks are counted and rank higher later.
- (NSArray<NSDictionary*>*)commandSuggestionsFor:(NSString*)text;
- (void)performCommandSuggestion:(NSDictionary*)suggestion;
- (IBAction)toggleSpaceHeader:(id)sender;
@property(nonatomic, readonly) BOOL toolbarShown;
@property(nonatomic, readonly) BOOL spaceHeaderShown;
@property(nonatomic, readonly) NSString* toolbarAddress;  // what the address field shows
- (void)submitToolbarAddress:(NSString*)text;            // tests: same as typing it and pressing Enter
@property(nonatomic, readonly) NSString* lastClosedPeekURL;
@property(nonatomic, readonly) BOOL peekToastShown;
// Session restore: each Space reopens on the tab it last showed. After a crash (restoreOpenTabs set
// before createBrowsers) the tabs that had pages open are loaded again too.
@property(nonatomic) BOOL restoreOpenTabs;
@property(nonatomic, readonly) NSUInteger restoredTabCount;
- (NSUInteger)liveTabCount;  // Arc: "New Nested Folder"; added at the top of the folder  // in Pinned, where the first pinned item was
- (void)loadURL:(NSString*)url inItem:(ArcItem*)item;
- (void)sendKeyToItem:(ArcItem*)item;  // used by the self-test to trigger the hang monitor
@property(nonatomic, readonly) ArcItem* hungItem;
- (void)answerHungSheet:(BOOL)exitPage;  // page the Wait/Exit sheet is about, nil if none
- (void)hideHoverCard;
@property(nonatomic, readonly) BOOL hoverCardShown;
- (IBAction)changeSpaceIcon:(id)sender;
@property(nonatomic, readonly) NSView* themeView;  // the tint layer over the sidebar (for tests)
// Clear Browsing Data: history and cookies from `since` on (nil = all time) in every Space's profile;
// the HTTP cache is always cleared in full (Chromium has no time range for it).
- (void)clearBrowsingDataSince:(NSDate*)since history:(BOOL)history cookies:(BOOL)cookies cache:(BOOL)cache
                          done:(void (^)(NSUInteger historyRemoved, NSUInteger cookiesRemoved))done;
- (IBAction)clearBrowsingData:(id)sender;
// Arc's "Clear Cookies and Refresh": the current site's cookies and storage, then reload.
- (void)clearCookiesAndRefreshWithDone:(void (^)(NSUInteger cookiesRemoved))done;
- (IBAction)clearCookiesAndRefresh:(id)sender;
// Self-test helpers (current tab's profile).
- (void)selfTestSetCookie:(NSString*)url name:(NSString*)name done:(void (^)(void))done;
- (void)selfTestCountCookiesNamed:(NSString*)name done:(void (^)(NSUInteger count))done;
// Pinned tabs (Arc): closing keeps the tab and returns it to its saved URL next time.
- (void)showItem:(ArcItem*)item;
- (BOOL)isPinnedItem:(ArcItem*)item;
- (void)resetPinnedItem:(ArcItem*)item;            // back to the saved URL
- (void)replacePinnedURLWithCurrent:(ArcItem*)item;
- (NSUInteger)resetPinnedTabsInSpace;               // unloads and resets every changed pinned tab
- (IBAction)resetPinnedTab:(id)sender;
- (IBAction)replacePinnedURL:(id)sender;
- (IBAction)resetAllPinnedTabs:(id)sender;
- (IBAction)previousTab:(id)sender;
- (IBAction)clearToday:(id)sender;
- (IBAction)focusPaneFromMenu:(NSMenuItem*)sender;  // tag = index
- (void)selectTabAtIndex:(NSUInteger)index;
- (BOOL)sidebarHidden;   // tests
- (NSRect)pageCardFrame;   // tests: the rounded page card, in window content coordinates
- (CGFloat)pageCardRadius;
- (NSString*)sidebarAddressText;   // tests: the site shown in the sidebar address pill
- (NSRect)sidebarAddressFrame;
- (NSString*)sidebarRowStyleForItem:(ArcItem*)item;  // tests: "h=36 r=8 sel=1 hover=0 alpha=0.20"
- (void)hoverSidebarItem:(ArcItem*)item;
- (NSArray<NSString*>*)spaceBarIcons;   // tests: one per Space, "*" marks the current one
- (void)clickSpaceBarIcon:(NSUInteger)index;
- (void)pressSidebarItem:(ArcItem*)item down:(BOOL)down;  // tests
- (void)toggleFolder:(ArcItem*)folder;
- (BOOL)folderExpanded:(ArcItem*)folder;
- (NSString*)folderChevronForItem:(ArcItem*)folder;       // tests
- (BOOL)stockDisclosureShown;                             // tests
- (NSString*)commandBarStyle;
// Boosts
- (IBAction)editBoost:(id)sender;
- (IBAction)zapElements:(id)sender;
- (IBAction)toggleBoost:(id)sender;
- (Boost*)boostForURL:(NSString*)url;
- (Boost*)setBoostForHost:(NSString*)host configure:(void (^)(Boost* b))configure;  // tests
- (void)deleteBoostForHost:(NSString*)host;                                        // tests
- (void)handleZapSelector:(NSString*)selector browser:(int)browserId;               // tests
- (NSUInteger)savedBoostCount;                                                      // tests
- (IBAction)shuffleBoost:(id)sender;
// Live Folders
- (IBAction)newLiveFolder:(id)sender;
- (ArcItem*)createLiveFolderKind:(NSString*)kind source:(NSString*)source title:(NSString*)title;
- (void)refreshLiveFolder:(ArcItem*)folder done:(void (^)(BOOL ok))done;
- (BOOL)dismissLiveFolderTab:(ArcItem*)item;
- (void)deleteSidebarItem:(ArcItem*)item;  // tests
- (BOOL)writeSidebarSnapshot:(NSString*)path;  // design checks
- (void)setTestCookie:(NSString*)name value:(NSString*)value url:(NSString*)url session:(BOOL)session done:(void (^)(BOOL ok))done;  // tests
- (void)testCookieNamesForURL:(NSString*)url done:(void (^)(NSArray<NSString*>* names))done;  // tests
// Easels
- (IBAction)newEasel:(id)sender;
- (IBAction)captureToEasel:(id)sender;
- (IBAction)addEaselText:(id)sender;
- (void)easelDidChange:(EaselView*)easel;
- (ArcItem*)createEaselWithID:(NSString*)easelID;
- (EaselView*)easelView;                                  // tests: nil when hidden
- (void)captureShownPageToEasel:(void (^)(BOOL ok))done;  // tests
// Notes
- (IBAction)newNote:(id)sender;
- (ArcItem*)createNoteWithID:(NSString*)noteID;
- (void)typeInNote:(NSString*)text;                   // tests
- (NSString*)noteEditorText;                          // tests: nil when the editor is hidden
- (NSString*)savedNoteText:(ArcItem*)note;            // tests
- (void)makeNoteRangeBold:(NSRange)r;                 // tests
- (BOOL)noteRangeIsBold:(ArcItem*)note range:(NSRange)r;  // tests
- (NSString*)boostIndicatorState;                                                   // tests: on/off/none
- (void)setColorScheme:(NSString*)scheme forSpace:(ArcSpace*)space;  // nil/"auto", "light", "dark"
- (BOOL)sidebarIsDark;                       // tests
- (BOOL)defaultThemeShown;                   // tests: Arc's default indigo is behind an unthemed Space
- (NSArray<NSString*>*)favoriteTileTitles;   // tests
- (NSMenu*)sidebarMenuForItem:(ArcItem*)item;  // tests
- (BOOL)swipeNavigationInstalled;  // tests
- (NSRect)favoritesGridFrame;                // tests
- (NSRect)spaceHeaderFrame;                  // tests
- (NSString*)lastSpaceSlide;   // tests
- (NSUInteger)cardPopCount;    // tests
- (void)showCommandBarForNewTab:(BOOL)newTab;
- (void)hideCommandBar;               // tests
- (NSString*)spaceHeaderText;               // tests: Space title row text
- (NSArray<NSString*>*)spaceMenuTitles;     // tests: the Space "..." menu              // tests: show the hover state on a row (nil clears)    // tests: pill frame in window coordinates
- (ArcItem*)shownItem;   // tests

// Little Windows not focused for the "Archive Little Windows" setting are closed (and archived).
- (NSUInteger)archiveIdleLittleWindowsAt:(NSDate*)now;
- (void)setLittleWindowLastUsed:(NSDate*)date index:(NSUInteger)index;  // tests

// Context menus. Links: open in new/background tab, split, Peek, Little Window, copy as Markdown.
// Sidebar items: the actions below, matching Arc's sidebar menu.
- (void)handleLinkCommand:(int)command url:(NSString*)url fromBrowser:(int)browserId;
- (NSMenu*)sidebarMenuForItem:(ArcItem*)item;
- (void)renameItem:(ArcItem*)item to:(NSString*)title;
- (ArcItem*)duplicateItem:(ArcItem*)item;  // tabs and folders (folders copy their whole contents)
- (IBAction)copyCleanLink:(id)sender;      // current page's URL without tracking parameters
// mode: 0 = other tabs, 1 = tabs above, 2 = tabs below (Today only). Returns how many were archived.
- (NSUInteger)archiveTodayTabsRelativeTo:(ArcItem*)item mode:(int)mode;
- (BOOL)moveItem:(ArcItem*)item toSpace:(ArcSpace*)space pinned:(BOOL)pinned;

// Archive (Arc: auto-archive of Today tabs + Cmd+Shift+T style reopen).
@property(nonatomic, copy) NSString* archivePath;
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* arcHistoryOverride;  // tests: profile -> fake History DB
@property(nonatomic, copy) NSString* historyPath;  // set before the first page loads
- (IBAction)showHistory:(id)sender;
- (IBAction)clearHistory:(id)sender;
- (NSArray<ArchivedTab*>*)historyVisits;
- (NSUInteger)historyWindowCountForQuery:(NSString*)query;
- (NSUInteger)runAutoArchiveWithThreshold:(NSTimeInterval)threshold now:(NSDate*)now;  // returns # archived
- (IBAction)reopenLastArchived:(id)sender;
- (IBAction)showArchive:(id)sender;
- (void)reopenArchivedTab:(ArchivedTab*)tab;
- (NSUInteger)archiveWindowCountForQuery:(NSString*)query;  // tests: opens the window, filters
- (NSArray*)archivedTabs;
// Closing a Today tab registers an undo (Edit > Undo Close Tab, Cmd+Z when the page isn't handling it):
// the tab comes back at the same place in the sidebar and leaves the Archive.
@property(nonatomic, readonly) NSUndoManager* sidebarUndoManager;
- (IBAction)undoCloseTab:(id)sender;  // works even while a web page has focus (its own Cmd+Z edits text)
@end

NSString* ResolveCommandBarInput(NSString* input);  // URL as-is (https added) or a search URL
