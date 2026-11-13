// Main browser window: Arc-style vertical sidebar (Space switcher, Favorites, Pinned, Today,
// folders) on the left, web content on the right, plus a command bar.
#pragma once

#import <Cocoa/Cocoa.h>

#import "app/arc_import.h"
#import "app/archive_store.h"

// URL with tracking parameters (utm_*, fbclid, gclid, ...) removed; other parameters keep their order.
NSString* CleanLinkURL(NSString* url);

NSString* MediaBarTitle(NSString* pageTitle);  // the mini player's title for a page title (V3)
@class Boost;
@class BoostColorWheel;
@class AutofillController;
@class EaselView;
@class NoteEditorView;
@class EaselObject;
@class ExtensionPopup;
@class NotArcExtension;
@class ArcExtensionCopy;
NSInteger UnreadCountFromTitle(NSString* title);
NSInteger SwipeDirectionForScroll(CGFloat dx, CGFloat dy, BOOL precise, BOOL began);  // -1 back, 1 forward, 0 none  // "Inbox (12)" -> 12

NSInteger PageDropSide(NSPoint p, NSSize s);  // 0 right, 1 left, 2 bottom, 3 top (#37 drag to split)
NSString* FavoritePreviewKind(NSString* url);  // "gmail", "calendar" or nil (#57)
BOOL OpensLittleWindowForClick(NSEventModifierFlags mods, BOOL gesture);  // Cmd+Option+click on a link (#42)

NSDictionary* SiteSearchFor(NSString* typed);  // Site Search: the site a typed name stands for, or nil

@class ThemePickerController;
@class ArcAlert;
@class WelcomeView;
extern const CGFloat kSidebarDefaultWidth, kSidebarMinWidth, kSidebarMaxWidth;  // Arc's

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
- (BOOL)tidyTitleOfItem:(ArcItem*)item announce:(BOOL)announce;  // #18 (on-device model first when on, #58)
- (NSString*)ruleTidyTitleOfItem:(ArcItem*)item;                  // TidyTabTitle for the item's title and host
- (BOOL)applyTidyTitle:(NSString*)tidy toItem:(ArcItem*)item announce:(BOOL)announce;  // undoable; NO if unchanged
- (void)usePageTitleOfItem:(ArcItem*)item;
- (void)setThemeGrain:(double)grain forSpace:(ArcSpace*)space;  // #26
- (ThemePickerController*)themePickerForTest;  // V52: the open theme picker, nil when closed
- (BOOL)themePickerShown;
- (NSString*)newSpaceCardLook;  // V54 tests
- (void)showWelcome;  // V56: first-launch welcome and import (V57)
- (WelcomeView*)welcomeViewForTest;
- (NSString*)layoutMetricsForTest;  // V63/V64
- (NSString*)spaceSwitchMotion;  // V55 tests: "push=1 spring=1 crossfade=1"
- (NSString*)lastSidebarMotion;  // V66 tests: "slide=1 card=1" or "none"
- (NSString*)dragLookDebugForTest;
- (NSString*)dragLookForTest;   // V21 tests: "gap=1 lifted=1 folderHighlight=1 pageSplit=1"
- (NSString*)sidebarRowMotion;   // V65 tests: "grow=N slideUp=N ghosts=N library=0|1"
- (ArcAlert*)newSpaceCardForTest;
- (void)fillNewSpaceCard:(NSString*)name emoji:(NSString*)emoji swatch:(NSUInteger)swatch;
- (void)closeThemePicker;
- (float)themeGrainOpacity;
- (BOOL)swipeSpacesBy:(NSInteger)step;
- (IBAction)peekEmail:(id)sender;
- (void)applyCalendarSetting;  // #56
- (void)setCalendarEventsForTest:(NSArray*)events now:(NSDate*)now;
- (NSString*)meetingBarText;
- (BOOL)meetingJoinShown;
- (IBAction)toggleCalendar:(id)sender;
- (NSArray<NSDictionary*>*)gmailPreviewRows:(NSInteger)status body:(NSData*)body;  // #57
- (NSArray<NSDictionary*>*)calendarPreviewRows:(NSArray*)events now:(NSDate*)now;
- (BOOL)browser:(int)browserId notification:(NSString*)json pageURL:(NSString*)pageURL;  // #78
- (NSDictionary*)lastNotification;
- (void)showItemWithID:(NSString*)itemID;
- (BOOL)splitShownWithItem:(ArcItem*)item side:(NSInteger)side;  // drag a tab onto the page (#37)
- (IBAction)toggleMaximizePane:(id)sender;
- (ArcItem*)maximizedPane;
- (NSRect)frameOfPaneItem:(ArcItem*)item;
- (ArcItem*)parentOfItemForTest:(ArcItem*)item;
- (void)handleLinkCommand:(int)command url:(NSString*)url text:(NSString*)text fromBrowser:(int)browserId;  // #70
- (NSSize)lastCopiedImageSize;
- (void)browser:(int)browserId pageLanguage:(NSString*)lang;  // #52 translate offer
- (NSString*)lastTranslateOffer;  // #44
- (NSString*)finishPeekEmail:(NSString*)host status:(NSInteger)status body:(NSData*)body;
@property(nonatomic) NSEventModifierFlags testClickModifiers;
- (IBAction)closeAllLittleWindows:(id)sender;
- (IBAction)showAllLittleWindows:(id)sender;  // tests: keys "held" for the next link click (#42)  // trackpad swipe over the sidebar (#27)
- (IBAction)toggleFavorite:(id)sender;  // Move to / Remove from Favorites (#13)
- (BOOL)moveItemToFavorites:(ArcItem*)item;
- (BOOL)removeItemFromFavorites:(ArcItem*)item pinned:(BOOL)pinned;
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
- (IBAction)focusPreviousPane:(id)sender;   // Ctrl+Shift+[
- (IBAction)shareSplitView:(id)sender;
- (IBAction)translatePage:(id)sender;
- (BOOL)adBlockingOnForHost:(NSString*)host;          // #53
- (IBAction)showManageAdBlockers:(id)sender;          // #53: from Site Settings
- (void)applyAdBlockCosmeticsToBrowser:(int)browserId url:(NSString*)url;  // cosmetic filter rules on page load
- (void)setAdBlocking:(BOOL)on forHost:(NSString*)host;       // View > Translate Page / Show Original (#52)      // copies every pane's address
- (NSString*)splitViewShareText;            // tests
- (NSArray<ArcItem*>*)visiblePanesForTest;  // tests
- (BOOL)openSplitFromText:(NSString*)text;  // 2-4 addresses, one per line -> one split
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
// One button for everything that can come over from Arc: the synchronous part (history, extensions, passwords,
// addresses, cards). Returns counts: @"history", @"extensions", @"skipped", @"passwords" (-1 = no key),
// @"existing", @"addresses", @"cards", @"locked", and @"passwordError" (plain words) when passwords couldn't come.
// File > Import Everything from Arc runs it and then -importArcCookiesFromUserData:key:done: (the logins).
- (NSDictionary*)importEverythingFromArcInto:(NSString*)extensionsDir userData:(NSString*)userData;
// Every Space profile's Arc cookies, copied again through CEF's cookie manager (stored with NotArc's own key).
// Report: @"read", @"set", @"profiles", @"expired", @"locked", @"errors" (plain-word lines). Tests pass a key.
- (void)importArcCookiesFromUserData:(NSString*)userData key:(NSData*)key done:(void (^)(NSDictionary* report))done;
// At launch while Arc data exists and the import hasn't been run (arcImportCompleted) or turned down (arcImportNotNow).
- (void)offerArcImportIfFirstLaunch;
- (IBAction)importEverythingFromArcMenu:(id)sender;  // File menu and Settings > Profiles
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
- (IBAction)switchToRecentTab:(id)sender;  // Ctrl+Tab: the most recently used other tab in this Space (held: switcher)
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
// Air Traffic Control (#34): opens a link from another app where the rules say (a Space or a Little Window).
// Returns "little", or the title of the Space it went to.
- (NSString*)routeExternalLink:(NSString*)url sourceApp:(NSString*)bundleID;
- (IBAction)showAirTrafficControl:(id)sender;
// Incognito window (#40, Cmd+Shift+N): its own in-memory profile, shared by all open Incognito windows and wiped
// when the last one closes. Nothing goes to History, the Archive or disk.
- (IBAction)newIncognitoWindow:(id)sender;
// Multiple windows (#39): one shared sidebar; each window has its own Space and tab.
- (IBAction)newWindow:(id)sender;
- (MainWindowController*)openNewWindowShowing:(ArcItem*)item;  // nil = the current Space's last tab
- (void)moveItemToMainWindow:(ArcItem*)item;
+ (NSUInteger)openWindowCount;
+ (NSArray<NSDictionary*>*)windowStateList;   // other windows: Space, tab, frame
+ (void)saveWindowState;
+ (void)prepareForQuit;                        // keep the other windows for next launch
+ (NSUInteger)savedWindowCount;                // tests
- (NSArray<MainWindowController*>*)restoreWindowsFromList:(NSArray<NSDictionary*>*)list;
- (void)restoreSavedWindows;                   // after createBrowsers
- (BOOL)isMainWindowController;
- (BOOL)hostsBrowserOfItem:(ArcItem*)item;  // tests
- (BOOL)sidebarShowsItem:(ArcItem*)item;    // tests
- (IBAction)moveShownToMainWindow:(id)sender;  // Today header button in other windows
- (BOOL)moveToMainButtonShown;              // tests
- (BOOL)chromePageOfItem:(ArcItem*)item isInWindow:(NSWindow*)win;  // tests
// Chrome extensions (#66). The puzzle-piece button in the address pill (Chrome-style pages on) opens the picker:
// each extension with Open (its popup, in a bubble under the button), Options, Turn Off/On and Remove, plus Install Extension...
// (Chrome Web Store link or ID), Chrome Web Store and Manage Extensions (chrome://extensions). Installs, removals
// and on/off take effect when NotArc relaunches (CEF can only load extensions at startup).
@property(nonatomic, copy) NSString* extensionsDirectoryOverride;  // tests: picker and installs use this folder
- (IBAction)showExtensionPicker:(id)sender;
- (IBAction)installExtension:(id)sender;
- (IBAction)manageExtensions:(id)sender;
- (NSMenu*)extensionPickerMenuForURL:(NSString*)url;  // what the picker shows when the shown tab is at `url`
- (void)installExtensionFromInput:(NSString*)input done:(void (^)(NSString* name, NSError* error))done;
- (BOOL)setExtension:(NSString*)extensionID enabled:(BOOL)enabled;
- (BOOL)removeExtensionWithID:(NSString*)extensionID;
- (BOOL)extensionPickerButtonShown;  // tests
- (NSInteger)relaunchRequestsForTest;
// The extension's action popup in a bubble under the picker button (Chrome-style pages; see extension_popup.h).
- (ExtensionPopup*)showPopupOfExtension:(NotArcExtension*)extension;
@property(nonatomic, readonly) ExtensionPopup* extensionPopup;  // the open bubble, or nil
- (NSView*)extensionPopupAnchor;                                // the picker button, or the address pill without it
// After Install, Remove, Turn Off/On, Update or an import: a toast with Relaunch Now (CEF loads extensions at startup).
- (void)offerRelaunchForExtensions:(NSString*)message;
- (NSButton*)toastButtonTitled:(NSString*)title;  // tests
// Installing or importing an extension turns Chrome-style pages on (they're where extensions run); NO if already on.
- (BOOL)turnOnChromePagesForExtensions;
- (NSArray<ArcExtensionCopy*>*)importArcExtensionsTurningOnPagesInto:(NSString*)destination fromArcUserData:(NSString*)userData;
// AppleScript (#76): "select", "back", "forward", "reload", "stop", "close", or "loading" (returns it) for a tab.
- (BOOL)scriptItem:(ArcItem*)item command:(NSString*)command;
// Call controls (#47): the tab using the camera/mic, and the sidebar's mute / camera-off toggles.
- (ArcItem*)callItem;
- (void)toggleCallMic:(ArcItem*)item;
- (void)toggleCallCamera:(ArcItem*)item;
- (BOOL)callControlsShown;  // tests
- (NSString*)mediaCardDescription;  // tests (V3)
- (void)setMediaCardHoveredForTest:(BOOL)hovered;
// Floating video and mini player (V75-V80). The float is Chromium's picture-in-picture window for the tab.
- (NSWindow*)floatingVideoWindow;                // shown float, or nil
- (ArcItem*)floatingVideoItem;                   // its tab
- (CGFloat)floatingVideoCornerRadius;            // tests
- (NSRect)floatingVideoFrame;                    // where the video shows, in screen points
- (BOOL)floatingVideoHidesChromiumBar;           // tests: Chromium's own site name isn't shown
- (void)setFloatingControlsHoveredForTest:(BOOL)hovered;
- (NSString*)floatingControlsState;              // tests: "hover=1 back=1 site=<host> play=1 ..."
- (void)pressFloatingControl:(NSString*)name;    // "back", "playpause", "minimize", "close"
- (NSString*)miniPlayerState;                    // tests: "h=64 title=<title>| favicon=1 reopen=1 close=1"
- (void)pressMiniPlayerControl:(NSString*)name;  // "reopen", "close"
// Tests: a real click on a mini player button (the window hit-tests its centre, the view there gets the press and
// release). Returns "button" when it reached that button, else what took the click.
- (NSString*)clickMiniPlayerControl:(NSString*)name;
// Tests: a real drag in `win`: the window hit-tests the start, and the view there gets the press, the moves and the
// release (screen points). Returns the class of the view that took it.
- (NSString*)dragInWindowForTest:(NSWindow*)win fromScreen:(NSPoint)from toScreen:(NSPoint)to;
- (NSWindow*)floatingControlsWindow;  // tests: NotArc's controls over the float
// Sidebar width (Arc: drag its right edge). Kept per window: the main window's in the settings, others' in Windows.json.
- (CGFloat)sidebarWidth;
- (void)setSidebarWidth:(CGFloat)width;
- (NSString*)sidebarEdgeState;    // tests: "handle=1 cursor=1"
- (NSString*)sidebarLayoutState;  // tests: "fits=1 ..." when everything in the sidebar fits its width
- (void)setMediaVolume:(double)volume forItem:(ArcItem*)item;
- (void)setMediaArtworkForTest:(NSImage*)image url:(NSString*)url;
- (IBAction)mediaBarPlay:(id)sender;
- (IBAction)mediaBarNext:(id)sender;
@property(nonatomic, copy) NSDictionary<NSString*, NSArray<NSString*>*>* searchSuggestionStub;
- (void)commandSuggestionsAfterFetch:(NSString*)text done:(void (^)(NSArray<NSDictionary*>* items))done;  // tests: query -> suggestions
- (void)pictureInPicture:(BOOL)enter item:(ArcItem*)item done:(void (^)(NSString* result))done;  // #46
- (NSView*)webViewForItem:(ArcItem*)item;
// Import bookmarks (#80): adds the folder to the current Space's Pinned section, like Arc. Returns NO if nil.
- (BOOL)addImportedBookmarks:(ArcItem*)folder;
- (IBAction)importBookmarksFromMenu:(id)sender;  // File > Import Bookmarks...
- (IBAction)importHistoryFromMenu:(id)sender;    // File > Import History... (Chrome, Brave, Edge, Vivaldi, Chromium)
- (NSUInteger)importHistoryFromFile:(NSString*)db browser:(NSString*)name;  // Chromium format; visits added
// kind: @"chromium", @"firefox" or @"safari". Returns visits added, or NSNotFound if the file can't be read.
- (NSUInteger)importHistoryFromFile:(NSString*)db browser:(NSString*)name kind:(NSString*)kind;
- (void)openIncognitoWindow:(NSString*)url;
- (NSUInteger)incognitoWindowCount;  // tests
- (BOOL)incognitoContextIsOnDisk;    // tests: NO = in-memory  // the rule editor (Settings > Links, command bar)
- (NSWindowController*)airTrafficControlEditor;  // tests
@property(nonatomic, copy) NSString* linkRoutingPath;  // set before the first link arrives
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
// Toast with any number of buttons (title, selector name on target); stays `duration` seconds.
- (void)showToast:(NSString*)text buttons:(NSArray<NSArray<NSString*>*>*)buttons target:(id)target
         duration:(NSTimeInterval)duration;
- (void)hideToast;
@property(nonatomic, readonly) NSString* toastText;  // tests: the toast showing, or nil
// Passwords and autofill (#67, see autofill.h). Edit > AutoFill > Fill Password, NotArc > Passwords...,
// File > Import Passwords...
@property(nonatomic, readonly) AutofillController* autofill;
- (BOOL)autofillRun:(NSString*)js nonce:(NSString*)nonce;
- (void)autofillRunAllFrames:(NSString*)js browser:(int)browserId;
- (NSView*)viewForBrowserId:(int)browserId;
- (IBAction)fillPassword:(id)sender;
- (IBAction)showPasswords:(id)sender;
- (IBAction)importPasswordsFromMenu:(id)sender;
- (NSPasteboard*)copyPasteboard;  // private pasteboard in self-tests
// Arc's saved passwords, addresses and cards (part of Import Everything from Arc, #150). Tests set the key.
@property(nonatomic, copy) NSData* arcSafeStorageKeyOverride;
// @"error" (plain words) when Arc's key or NotArc's own vault isn't available.
- (NSDictionary*)importArcPasswordsFromUserData:(NSString*)userData;
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
@property(nonatomic, readonly) BOOL hoverCardHasThumbnail;  // #65
// Tab thumbnails (#65): copy the shown tab 1 s from now (each switch or load restarts the wait).
- (void)scheduleThumbnailOfShown;
// Recent-tab switcher (Ctrl+Tab held, #32/#65). Tests open it with mods = 0 (no key monitoring) and drive it.
- (void)openTabSwitcherHolding:(NSEventModifierFlags)mods;
- (void)stepTabSwitcher:(NSInteger)delta;
- (void)commitTabSwitcher;
- (void)cancelTabSwitcher;
@property(nonatomic, readonly) BOOL tabSwitcherShown;
@property(nonatomic, readonly) NSArray<ArcItem*>* tabSwitcherItems;
@property(nonatomic, readonly) ArcItem* tabSwitcherSelection;
- (BOOL)tabSwitcherShowsThumbnailFor:(ArcItem*)item;
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
- (NSString*)pageCardEdgeStyle;  // tests: border alpha and shadow opacity of the page card (#122)
- (NSString*)pageFitState;       // tests: "edge=1 page=1 window=1 glow=1 card=WxH chrome=0|1 | debug"
- (NSString*)sidebarAddressText;   // tests: the site shown in the sidebar address pill
// Developer Mode (#68, per site): View > Turn On/Off Developer Mode for This Site, Site Settings, and the reset.
- (IBAction)toggleDeveloperMode:(id)sender;
- (IBAction)resetDeveloperModeSites:(id)sender;
- (BOOL)devToolsButtonShown;                        // tests: the pill's Developer Tools button
- (BOOL)itemKeptFromAutoArchive:(ArcItem*)item;     // Developer Mode tabs are never auto-archived
+ (MainWindowController*)mainController;            // the first browser window (Settings reads profiles from it)
+ (void)settingsDidChange;                          // every window re-reads appearance, toolbar, header, pill
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
// Omar, Nov 11 (V67, V68, V71): clicking the address pill opens Arc's compact dropdown over the pill; Cmd+T keeps
// the big centred bar. A click outside, Esc or another window taking focus closes it with no navigation.
- (NSString*)commandBarGeometry;          // tests: "compact=1 onPill=1 width=348 rows=5 rowH=50 font=13 scrim=0 ..."
- (NSWindow*)commandBarWindow;            // tests
- (NSEvent*)commandBarFilterEvent:(NSEvent*)event;  // the click-outside monitor (nil = swallowed)
// The address pill's hover row (V69): pinned extensions, the puzzle (More), Copy URL, the site control center.
- (NSString*)pillButtonOrder;             // tests: "ext:<id>,more,copy,site" (hidden buttons left out)
- (BOOL)pillExtensionHasOwnIcon:(NSString*)extensionID;  // tests
- (BOOL)extensionIsPinned:(NSString*)extensionID;
- (void)setExtension:(NSString*)extensionID pinned:(BOOL)pinned;
- (ExtensionPopup*)clickPillExtensionForTest:(NSString*)extensionID;
- (void)rebuildPillExtensions;            // after extensions or pins change (and on a profile change)
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
- (BoostColorWheel*)boostColorWheel;            // tests: the editor's colour wheel (after editBoost:)
- (Boost*)boostBeingEdited;                     // tests
- (void)setBoostIntensity:(double)value;        // tests: as if the Intensity slider moved
- (BOOL)pickBoostFontTile:(NSString*)name;      // tests: as if a font tile (e.g. "Georgia") was clicked
- (NSArray<NSString*>*)boostPanelSections;      // tests: header, color, font, size, case, zap, code
// Live Folders
- (IBAction)newLiveFolder:(id)sender;
- (ArcItem*)createLiveFolderKind:(NSString*)kind source:(NSString*)source title:(NSString*)title;
- (void)refreshLiveFolder:(ArcItem*)folder done:(void (^)(BOOL ok))done;
- (BOOL)dismissLiveFolderTab:(ArcItem*)item;
- (IBAction)newMyPullRequestsFolder:(id)sender;
- (IBAction)newYouTubeLiveFolder:(id)sender;
- (NSMenuItem*)newLiveFolderMenuItem;                           // the + menu's New Live Folder submenu
- (ArcItem*)createMyPullRequestsFolder;                          // GitHub: My Pull Requests (one per Space)
- (void)createLiveFolderFromInput:(NSString*)input done:(void (^)(ArcItem* folder))done;
- (NSString*)liveBadgeForItem:(ArcItem*)item;                    // tests: "dot", a folder's unread count, or ""
- (NSUInteger)liveUnreadCountOf:(ArcItem*)folder;
- (void)deleteSidebarItem:(ArcItem*)item;  // tests
- (BOOL)writeSidebarSnapshot:(NSString*)path;  // design checks
- (BOOL)sidebarScrollerIsOverlay;               // tests (visual parity V1)
- (BOOL)spaceDotsAreArcStyle;                   // tests (V24)
- (NSString*)navButtonState;                    // tests (V11)
- (NSString*)pillButtonState;                   // tests (V12)
- (void)setPillHoveredForTest:(BOOL)hovered;
- (void)updateNavButtons;
- (NSString*)sidebarPeekState;                  // tests (V23)
- (void)beginSidebarPeekForTest;
- (void)endSidebarPeekForTest;
- (BOOL)sidebarDimmedForTest:(BOOL)inactive;    // tests (V8)
- (NSString*)todayClearState;                   // tests (V17)
- (NSString*)folderRowStateForItem:(ArcItem*)folder;  // tests (V18)
- (NSString*)peekStyle;                         // tests (V39)
- (NSString*)littleWindowStyle;                 // tests (V38)
- (NSString*)speakerStateForItem:(ArcItem*)item;  // tests (V26)
- (NSString*)crashViewStyleForItem:(ArcItem*)item;  // tests (V10)
- (NSString*)updateBannerState;                 // tests (V27)
- (NSString*)hoverCardStyle;                    // tests (V34)
- (NSString*)tabSwitcherStyle;                  // tests (V33)
- (NSMenu*)newItemMenu;                         // the sidebar's + menu (V25)
- (NSString*)siteControlsStyle;                 // tests (V49)
- (IBAction)showLibrary:(id)sender;
- (NSString*)libraryHomeForTest;                // tests (V41)
- (void)openLibraryRowForTest:(NSUInteger)i;
- (NSString*)librarySectionForTest;
- (id)libraryPanelForTest;
- (NSString*)downloadsTrayState;               // tests (V42)
- (void)closeDownloadsTrayForTest;
- (NSString*)captureCardState;                  // tests (V46)
- (NSString*)siteSearchState;                   // tests (V31)
- (NSString*)sitePromptStyle;                   // tests (V51)
- (BOOL)commandBarHandleSelectorForTest:(SEL)sel;
- (void)hideUpdateBannerForTest;
- (IBAction)restartToUpdate:(id)sender;
- (NSString*)findBarStyle;                      // tests (V35)
- (IBAction)closeFindBar:(id)sender;
- (NSString*)splitRowStateForItem:(ArcItem*)split;  // tests (V19)
- (NSString*)loadingIndicatorStateForItem:(ArcItem*)item;  // tests (V9)
- (void)setItem:(ArcItem*)item loadingForTest:(BOOL)loading;
- (NSString*)tabRowAccessoriesForItem:(ArcItem*)item;  // tests (V2): "close=1 fade=1 clip=1 room=1"
- (BOOL)pressCloseButtonOfItem:(ArcItem*)item;        // tests (V2)
- (void)reloadSidebarItemForTest:(ArcItem*)item;
- (void)closeSidebarTab:(ArcItem*)item;
- (void)setTestCookie:(NSString*)name value:(NSString*)value url:(NSString*)url session:(BOOL)session done:(void (^)(BOOL ok))done;  // tests
- (void)testCookieDetailsForURL:(NSString*)url done:(void (^)(NSArray<NSDictionary*>*))done;  // tests
- (void)testDeleteCookiesForURL:(NSString*)url done:(void (^)(void))done;                      // tests
- (void)testCookieNamesForURL:(NSString*)url done:(void (^)(NSArray<NSString*>* names))done;  // tests
// Easels
- (IBAction)newEasel:(id)sender;
- (IBAction)captureToEasel:(id)sender;
// Capture (#48): area (drag), visible page, full page, portrait mode; each copies the PNG and saves it to Downloads.
- (IBAction)captureArea:(id)sender;
- (IBAction)captureVisiblePage:(id)sender;
- (IBAction)captureFullPage:(id)sender;
- (IBAction)capturePortrait:(id)sender;
- (IBAction)addLastCaptureToEasel:(id)sender;
- (void)capture:(NSString*)mode rect:(NSRect)rect done:(void (^)(NSData* png))done;  // "visible", "full", "portrait", "area"
- (NSString*)deliverCapture:(NSData*)png;  // returns the saved path
@property(nonatomic, copy) NSString* captureDirectory;  // tests: a scratch folder (also switches to a private pasteboard)
- (IBAction)addEaselText:(id)sender;
- (void)easelDidChange:(EaselView*)easel;
- (ArcItem*)createEaselWithID:(NSString*)easelID;
- (EaselView*)easelView;                                  // tests: nil when hidden
- (void)captureShownPageToEasel:(void (^)(BOOL ok))done;  // tests
// Easel captures and live web clips (#49).
- (IBAction)captureAreaToEasel:(id)sender;
- (IBAction)captureFullPageToEasel:(id)sender;
- (IBAction)liveClipToEasel:(id)sender;
- (IBAction)refreshLiveClipsFromMenu:(id)sender;
- (void)captureToEaselMode:(NSString*)mode rect:(NSRect)r done:(void (^)(EaselObject* o))done;  // "area" or "full"
- (void)liveClipArea:(NSRect)r done:(void (^)(EaselObject* clip))done;  // r in page points, top-left origin
- (NSUInteger)refreshLiveClips:(BOOL)force;  // returns how many clips started refreshing
@property(nonatomic) NSInteger clipRefreshesFinished;  // tests
// Notes
- (IBAction)newNote:(id)sender;
- (ArcItem*)createNoteWithID:(NSString*)noteID;
- (void)typeInNote:(NSString*)text;                   // tests
- (NSString*)noteEditorText;                          // tests: nil when the editor is hidden
- (NSString*)savedNoteText:(ArcItem*)note;            // tests
- (void)makeNoteRangeBold:(NSRange)r;                 // tests
- (BOOL)noteRangeIsBold:(ArcItem*)note range:(NSRange)r;  // tests
- (IBAction)newNoteInSplitView:(id)sender;           // Arc: newNoteInSplitView
- (IBAction)exportNoteAsMarkdown:(id)sender;         // File > Export Note as Markdown... (save panel)
- (IBAction)copyNoteAsMarkdown:(id)sender;
- (BOOL)exportNote:(ArcItem*)note toPath:(NSString*)path;  // what the save panel's OK does (tests call it directly)
- (NSString*)markdownForNote:(ArcItem*)note;
- (BOOL)placeInSplit:(ArcItem*)item horizontal:(BOOL)horizontal before:(BOOL)before;
- (NoteEditorView*)noteEditorForItem:(ArcItem*)note;  // tests: nil unless on screen
- (NSAttributedString*)savedNote:(ArcItem*)note;      // tests
- (NSPasteboard*)copyPasteboard;
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
- (void)hideLibrary;
- (BOOL)libraryShown;                       // tests (V4)
- (BOOL)libraryInSidebar;                   // tests (V4)
- (NSString*)libraryStyle;                  // tests (V4)
- (NSArray<NSString*>*)libraryGroupTitles;  // tests (V4)
- (void)reopenArchivedTab:(ArchivedTab*)tab;
- (NSUInteger)archiveWindowCountForQuery:(NSString*)query;  // tests: opens the window, filters
- (NSArray*)archivedTabs;
// Closing a Today tab registers an undo (Edit > Undo Close Tab, Cmd+Z when the page isn't handling it):
// the tab comes back at the same place in the sidebar and leaves the Archive.
@property(nonatomic, readonly) NSUndoManager* sidebarUndoManager;
- (IBAction)undoCloseTab:(id)sender;  // works even while a web page has focus (its own Cmd+Z edits text)
@end

NSString* ResolveCommandBarInput(NSString* input);  // URL as-is (https added) or a search URL

// Import Everything from Arc (#150): the pure parts, for tests.
extern NSString* const kArcImportCompletedKey;  // NSDate: the import ran
extern NSString* const kArcImportDeclinedKey;   // BOOL: "Not Now" on the launch offer
BOOL ArcImportOfferDue(NSDictionary* prefs, BOOL arcDataExists);
NSString* ArcImportSummary(NSDictionary* counts, NSDictionary* cookieReport);
