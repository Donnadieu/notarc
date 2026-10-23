// Main browser window: Arc-style vertical sidebar (Space switcher, Favorites, Pinned, Today,
// folders) on the left, web content on the right, plus a command bar.
#pragma once

#import <Cocoa/Cocoa.h>

#import "app/arc_import.h"
#import "app/archive_store.h"

@interface MainWindowController : NSWindowController <NSWindowDelegate>
- (instancetype)initWithSpaces:(NSArray<ArcSpace*>*)spaces focusedSpaceID:(NSString*)focusedID;
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
- (void)moveLittleWindowToMain:(NSUInteger)index;  // tests: same as its "Open in NotArc" button
- (void)closeLittleWindow:(NSUInteger)index;       // tests

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
- (void)moveSpace:(ArcSpace*)space by:(NSInteger)delta;
- (void)selectSpaceAtIndex:(NSUInteger)index;
- (NSArray<ArcSpace*>*)spaces;
- (ArcSpace*)currentSpace;

// Archive (Arc: auto-archive of Today tabs + Cmd+Shift+T style reopen).
@property(nonatomic, copy) NSString* archivePath;
- (NSUInteger)runAutoArchiveWithThreshold:(NSTimeInterval)threshold now:(NSDate*)now;  // returns # archived
- (IBAction)reopenLastArchived:(id)sender;
- (IBAction)showArchive:(id)sender;
- (void)reopenArchivedTab:(ArchivedTab*)tab;
- (NSUInteger)archiveWindowCountForQuery:(NSString*)query;  // tests: opens the window, filters
- (NSArray*)archivedTabs;
@end

NSString* ResolveCommandBarInput(NSString* input);  // URL as-is (https added) or a search URL
