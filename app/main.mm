// NotArc browser process entry point.
#import <Cocoa/Cocoa.h>

#include <cstdio>
#include <string>

#import "app/arc_import.h"
#import "app/main_window.h"
#import "app/sidebar_store.h"
#import "app/archive_store.h"
#import "app/arc_cookies.h"
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/wrapper/cef_library_loader.h"

// CEF requires the NSApplication subclass to implement CefAppProtocol.
@interface NotArcApplication : NSApplication <CefAppProtocol> {
  BOOL _handlingSendEvent;
}
@end

@implementation NotArcApplication
- (BOOL)isHandlingSendEvent { return _handlingSendEvent; }
- (void)setHandlingSendEvent:(BOOL)value { _handlingSendEvent = value; }
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent scoper;
  [super sendEvent:event];
}
- (void)terminate:(id)sender {
  for (NSWindow* w in self.windows) [w performClose:nil];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) MainWindowController* window;
@property(nonatomic) BOOL selfTest;
@property(nonatomic) BOOL selfTestReload;  // phase 2: reopen the saved store, no actions
@property(nonatomic, strong) NSMutableArray<NSString*>* pendingURLs;  // links that arrived before the window
@end

@implementation AppDelegate

- (void)buildMenu {
  NSMenu* bar = [NSMenu new];
  NSMenuItem* appItem = [NSMenuItem new];
  [bar addItem:appItem];
  NSMenu* appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"Quit NotArc" action:@selector(terminate:) keyEquivalent:@"q"];
  appItem.submenu = appMenu;

  NSMenuItem* editItem = [NSMenuItem new];
  [bar addItem:editItem];
  NSMenu* edit = [[NSMenu alloc] initWithTitle:@"Edit"];
  [edit addItemWithTitle:@"Undo" action:@selector(undo:) keyEquivalent:@"z"];
  [edit addItemWithTitle:@"Redo" action:@selector(redo:) keyEquivalent:@"Z"];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
  [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
  [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:@"Find..." action:@selector(findInPage:) keyEquivalent:@"f"];
  [edit addItemWithTitle:@"Find Next" action:@selector(findNext:) keyEquivalent:@"g"];
  [edit addItemWithTitle:@"Find Previous" action:@selector(findPrevious:) keyEquivalent:@"G"];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:@"Copy URL" action:@selector(copyCurrentURL:) keyEquivalent:@"C"];
  NSMenuItem* md = [edit addItemWithTitle:@"Copy URL as Markdown" action:@selector(copyCurrentURLAsMarkdown:)
                            keyEquivalent:@"c"];
  md.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption;
  editItem.submenu = edit;

  NSMenuItem* fileItem = [NSMenuItem new];
  [bar insertItem:fileItem atIndex:1];  // App, File, Edit
  NSMenu* file = [[NSMenu alloc] initWithTitle:@"File"];
  [file addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@"t"];
  [file addItemWithTitle:@"Open Location..." action:@selector(openLocation:) keyEquivalent:@"l"];
  [file addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@"w"];
  [file addItemWithTitle:@"Reopen Archived Tab" action:@selector(reopenLastArchived:) keyEquivalent:@"T"];
  [file addItemWithTitle:@"Show Archive" action:@selector(showArchive:) keyEquivalent:@"y"];
  [file addItem:[NSMenuItem separatorItem]];
  [file addItemWithTitle:@"Pin / Unpin Tab" action:@selector(togglePin:) keyEquivalent:@"d"];
  [file addItemWithTitle:@"New Folder" action:@selector(newFolder:) keyEquivalent:@""];
  NSMenuItem* littleItem = [file addItemWithTitle:@"New Little Window" action:@selector(newLittleWindow:)
                                    keyEquivalent:@"n"];
  littleItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  // Peek and Little Window: move the page into the sidebar (handled by those windows only).
  [file addItemWithTitle:@"Open in Sidebar" action:@selector(openInMainWindow:) keyEquivalent:@"o"];
  [file addItemWithTitle:@"Clear Today" action:@selector(clearToday:) keyEquivalent:@"K"];
  fileItem.submenu = file;

  NSMenuItem* viewItem = [NSMenuItem new];
  [bar addItem:viewItem];
  NSMenu* view = [[NSMenu alloc] initWithTitle:@"View"];
  [view addItemWithTitle:@"Toggle Sidebar" action:@selector(toggleSidebar:) keyEquivalent:@"s"];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItemWithTitle:@"Reload Page" action:@selector(reloadPage:) keyEquivalent:@"r"];
  [view addItemWithTitle:@"Hard Reload" action:@selector(hardReload:) keyEquivalent:@"R"];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItemWithTitle:@"Zoom In" action:@selector(zoomIn:) keyEquivalent:@"="];
  [view addItemWithTitle:@"Zoom Out" action:@selector(zoomOut:) keyEquivalent:@"-"];
  [view addItemWithTitle:@"Actual Size" action:@selector(actualSize:) keyEquivalent:@"0"];
  [view addItem:[NSMenuItem separatorItem]];
  NSMenuItem* dev = [view addItemWithTitle:@"Developer Tools" action:@selector(toggleDevTools:) keyEquivalent:@"i"];
  dev.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  viewItem.submenu = view;

  NSMenuItem* splitItem = [NSMenuItem new];
  [bar addItem:splitItem];
  NSMenu* split = [[NSMenu alloc] initWithTitle:@"Split View"];
  NSEventModifierFlags cs = NSEventModifierFlagControl | NSEventModifierFlagShift;
  [split addItemWithTitle:@"Add Right Split" action:@selector(addVerticalSplit:) keyEquivalent:@"="]
      .keyEquivalentModifierMask = cs;
  [split addItemWithTitle:@"Add Bottom Split" action:@selector(addHorizontalSplit:) keyEquivalent:@""];
  [split addItemWithTitle:@"Add Left Split" action:@selector(addLeftSplit:) keyEquivalent:@""];
  [split addItemWithTitle:@"Add Top Split" action:@selector(addTopSplit:) keyEquivalent:@""];
  [split addItemWithTitle:@"Flip Split Layout" action:@selector(flipSplitLayout:) keyEquivalent:@""];
  [split addItemWithTitle:@"Close Split Pane" action:@selector(closeSplitPane:) keyEquivalent:@"-"]
      .keyEquivalentModifierMask = cs;
  [split addItemWithTitle:@"Focus Next Pane" action:@selector(focusNextPane:) keyEquivalent:@"]"]
      .keyEquivalentModifierMask = cs;
  for (int i = 1; i <= 4; ++i) {
    NSMenuItem* pane = [split addItemWithTitle:[NSString stringWithFormat:@"Focus Pane %d", i]
                                        action:@selector(focusPaneFromMenu:)
                                 keyEquivalent:[NSString stringWithFormat:@"%d", i]];
    pane.keyEquivalentModifierMask = cs;
    pane.tag = i - 1;
  }
  splitItem.submenu = split;

  NSMenuItem* spacesItem = [NSMenuItem new];
  [bar addItem:spacesItem];
  NSMenu* spacesMenu = [[NSMenu alloc] initWithTitle:@"Spaces"];
  [spacesMenu addItemWithTitle:@"New Space..." action:@selector(newSpace:) keyEquivalent:@""];
  [spacesMenu addItemWithTitle:@"Rename Space..." action:@selector(renameCurrentSpace:) keyEquivalent:@""];
  [spacesMenu addItemWithTitle:@"Delete Space..." action:@selector(deleteCurrentSpace:) keyEquivalent:@""];
  [spacesMenu addItem:[NSMenuItem separatorItem]];
  [spacesMenu addItemWithTitle:@"Move Space Up" action:@selector(moveSpaceUp:) keyEquivalent:@""];
  [spacesMenu addItemWithTitle:@"Move Space Down" action:@selector(moveSpaceDown:) keyEquivalent:@""];
  [spacesMenu addItem:[NSMenuItem separatorItem]];
  unichar left = NSLeftArrowFunctionKey, right = NSRightArrowFunctionKey;
  [spacesMenu addItemWithTitle:@"Previous Space" action:@selector(previousSpace:)
                 keyEquivalent:[NSString stringWithCharacters:&left length:1]]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [spacesMenu addItemWithTitle:@"Next Space" action:@selector(nextSpace:)
                 keyEquivalent:[NSString stringWithCharacters:&right length:1]]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  for (int i = 1; i <= 9; ++i) {
    NSMenuItem* go = [spacesMenu addItemWithTitle:[NSString stringWithFormat:@"Go to Space %d", i]
                                           action:@selector(selectSpaceFromMenu:)
                                    keyEquivalent:[NSString stringWithFormat:@"%d", i]];
    go.keyEquivalentModifierMask = NSEventModifierFlagControl;
    go.tag = i - 1;
  }
  spacesItem.submenu = spacesMenu;

  NSMenuItem* histItem = [NSMenuItem new];
  [bar addItem:histItem];
  NSMenu* hist = [[NSMenu alloc] initWithTitle:@"History"];
  [hist addItemWithTitle:@"Back" action:@selector(goBack:) keyEquivalent:@"["];
  [hist addItemWithTitle:@"Forward" action:@selector(goForward:) keyEquivalent:@"]"];
  unichar la = NSLeftArrowFunctionKey, ra = NSRightArrowFunctionKey, ua = NSUpArrowFunctionKey,
          da = NSDownArrowFunctionKey;
  NSMenuItem* backAlt = [hist addItemWithTitle:@"Back" action:@selector(goBack:)
                                 keyEquivalent:[NSString stringWithCharacters:&la length:1]];
  backAlt.alternate = NO;
  [hist addItemWithTitle:@"Forward" action:@selector(goForward:)
           keyEquivalent:[NSString stringWithCharacters:&ra length:1]];
  histItem.submenu = hist;

  NSMenuItem* tabsItem = [NSMenuItem new];
  [bar addItem:tabsItem];
  NSMenu* tabs = [[NSMenu alloc] initWithTitle:@"Tabs"];
  NSEventModifierFlags co = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [tabs addItemWithTitle:@"Previous Tab" action:@selector(previousTab:)
           keyEquivalent:[NSString stringWithCharacters:&ua length:1]].keyEquivalentModifierMask = co;
  [tabs addItemWithTitle:@"Next Tab" action:@selector(nextTab:)
           keyEquivalent:[NSString stringWithCharacters:&da length:1]].keyEquivalentModifierMask = co;
  for (int i = 1; i <= 9; ++i) {
    NSMenuItem* go = [tabs addItemWithTitle:[NSString stringWithFormat:@"Go to Tab %d", i]
                                     action:@selector(selectTabFromMenu:)
                              keyEquivalent:[NSString stringWithFormat:@"%d", i]];
    go.tag = i - 1;
  }
  tabsItem.submenu = tabs;
  NSApp.mainMenu = bar;
}

- (void)start {
  [self buildMenu];
  NSString* arcDir = ArcDataDirectory();
  NSString* storePath = SidebarStorePath(self.selfTest);
  if (self.selfTest && !self.selfTestReload)
    [[NSFileManager defaultManager] removeItemAtPath:storePath error:nil];  // phase 1 starts from the Arc import
  NSError* error = nil;
  NSString* focused = nil;
  // Our own store wins; Arc's files are only imported when we have none yet.
  NSArray<ArcSpace*>* spaces = SidebarStoreLoad(storePath, &focused, &error);
  if (spaces) {
    std::fprintf(stderr, "loaded sidebar from %s\n", storePath.UTF8String);
  } else {
    if (error) std::fprintf(stderr, "sidebar store unreadable (%s); re-importing from Arc\n",
                            error.localizedDescription.UTF8String);
    error = nil;
    spaces = ArcImportSidebar([arcDir stringByAppendingPathComponent:@"StorableSidebar.json"], &error);
    focused = ArcFocusedSpaceID([arcDir stringByAppendingPathComponent:@"StorableWindows.json"]);
  }
  if (!spaces.count) {
    std::fprintf(stderr, "Arc import failed (%s); starting with an empty Space\n",
                 error.localizedDescription.UTF8String ?: "no spaces");
    ArcSpace* fallback = [ArcSpace new];
    fallback.title = @"Home";
    fallback.profileDirectory = @"Default";
    fallback.pinned = [ArcItem new];
    fallback.pinned.isSection = YES;
    fallback.pinned.title = @"Pinned";
    fallback.pinned.children = [NSMutableArray array];
    ArcItem* tab = [ArcItem new];
    tab.url = @"https://www.google.com";
    tab.children = [NSMutableArray array];
    fallback.unpinned = [ArcItem new];
    fallback.unpinned.isSection = YES;
    fallback.unpinned.title = @"Today";
    fallback.unpinned.children = [NSMutableArray arrayWithObject:tab];
    spaces = @[ fallback ];
  }
  self.window = [[MainWindowController alloc] initWithSpaces:spaces focusedSpaceID:focused];
  self.window.storePath = storePath;
  self.window.archivePath = ArchiveStorePath(self.selfTest);
  if (self.selfTest && !self.selfTestReload)
    [[NSFileManager defaultManager] removeItemAtPath:self.window.archivePath error:nil];
  // First launch: bring over Arc's archive once (read-only), like the sidebar import.
  if (![[NSFileManager defaultManager] fileExistsAtPath:self.window.archivePath]) {
    NSMutableArray* imported = ArchiveImportArc([arcDir stringByAppendingPathComponent:@"StorableArchiveItems.json"]);
    ArchiveStoreSave(imported, self.window.archivePath);
    std::fprintf(stderr, "imported %lu archived tabs from Arc\n", (unsigned long)imported.count);
    if (self.selfTest) std::printf("SELFTEST-ARCIMPORT archived=%lu\n", (unsigned long)imported.count);
  }
  [self.window saveSidebarNow];  // first launch: persist the import immediately
  [self.window showWindow:nil];
  [self.window createBrowsers];
  for (NSString* url in self.pendingURLs) [self.window openLittleWindow:url];
  self.pendingURLs = nil;
  [NSApp activateIgnoringOtherApps:YES];

  if (self.selfTest) {
    [self.window openTabsForSelfTest:1];  // first tab of every Space, each in its own profile
    if (!self.selfTestReload) [self runSelfTestActions];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      for (NSDictionary* tab in [self.window tabSnapshot])
        std::printf("SELFTEST space=\"%s\" profile=\"%s\" title=\"%s\" url=%s\n", [tab[@"space"] UTF8String],
                    [tab[@"profile"] UTF8String], [tab[@"title"] UTF8String], [tab[@"url"] UTF8String]);
      std::fflush(stdout);
      [self.window closeAllBrowsers];
    });
  }
}

// Browser-basics test: waits for the new tab's web view (its Space profile may still be starting),
// then runs navigate -> back -> zoom -> find -> copy as Markdown, each step a little apart.
- (void)runBasicsTestWhenReady:(int)attempt {
  MainWindowController* w = self.window;
  if (![w hasLiveBrowser] || [w isLoading] || ![[w currentURL] hasPrefix:@"https://example.com"]) {
    if (attempt < 160)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        [self runBasicsTestWhenReady:attempt + 1];
      });
    else {
      std::printf("SELFTEST-BASICS tabNeverLoaded=1 live=%d loading=%d url=%s\n", [w hasLiveBrowser], [w isLoading], [w currentURL].UTF8String);
      [self runRemainingSelfTestActions];
    }
    return;
  }
  [w navigateCurrentTab:@"https://www.iana.org/help/example-domains"];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    BOOL couldGoBack = [w canGoBack];
    [w goBack:nil];
    [w zoomIn:nil];
    [w zoomIn:nil];
    std::printf("SELFTEST-BASICS canGoBack=%d zoomAfter2In=%.1f\n", couldGoBack, [w currentZoomLevel]);
    [w actualSize:nil];
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    std::printf("SELFTEST-BASICS afterBack=%s zoomReset=%.1f\n", [w currentURL].UTF8String, [w currentZoomLevel]);
    [w findText:@"domain" forward:YES];
  });
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [w copyCurrentURLAsMarkdown:nil];
    std::printf("SELFTEST-BASICS findDomainCount=%d markdown=%s\n", w.lastFindCount,
                [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString].UTF8String);
    [self runRemainingSelfTestActions];
  });
}

// Basics run alone first; the other steps would otherwise navigate or close its tab mid-test.
- (void)runSelfTestActions {
  [self.window openInNewTab:@"https://example.com"];
  [self runBasicsTestWhenReady:0];
}

- (void)runRemainingSelfTestActions {
  {
    [self.window openInNewTab:@"example.com"];            // command bar: bare host -> https
    [self.window openInNewTab:@"arc browser reverse engineering"];  // command bar: search
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self.window navigateCurrentTab:@"https://www.wikipedia.org"];  // replaces the search tab
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 12 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self.window openInNewTab:@"https://news.ycombinator.com"];
      [self.window closeCurrentTab];  // must not quit the app
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      ArcItem* folder = [w createFolderNamed:@"SelfTest Folder"];
      ArcItem* example = [w tabWithURLPrefix:@"https://example.com"];
      ArcItem* wiki = [w tabWithURLPrefix:@"https://www.wikipedia.org"];
      BOOL intoFolder = [w moveItem:example toParent:folder index:0];      // Today -> folder in Pinned
      BOOL pinned = [w moveItem:wiki toParent:[w currentPinnedSection] index:99];  // Today -> end of Pinned
      BOOL cycle = [w moveItem:folder toParent:folder index:0];            // must be refused
      std::printf("SELFTEST-ORG folder=%d intoFolder=%d pinned=%d cycleRefused=%d\n", folder != nil, intoFolder,
                  pinned, !cycle);
      [w saveSidebarNow];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInSplit:@"https://example.com" horizontal:NO];
      [w openInSplit:@"https://example.org" horizontal:NO];
      NSArray<NSValue*>* f = [w paneFrames];
      BOOL sideBySide = f.count == 3 && NSMaxX(f[0].rectValue) <= NSMinX(f[1].rectValue) &&
                        NSMaxX(f[1].rectValue) <= NSMinX(f[2].rectValue);
      std::printf("SELFTEST-SPLIT panes=%lu sideBySide=%d widths=%.0f,%.0f,%.0f\n", (unsigned long)f.count, sideBySide,
                  f.count > 0 ? f[0].rectValue.size.width : 0, f.count > 1 ? f[1].rectValue.size.width : 0,
                  f.count > 2 ? f[2].rectValue.size.width : 0);
      [w closeSplitPane:nil];
      std::printf("SELFTEST-SPLIT afterClosePane=%lu\n", (unsigned long)[w paneFrames].count);
      [w closeSplitPane:nil];
      std::printf("SELFTEST-SPLIT afterSecondClose=%lu\n", (unsigned long)[w paneFrames].count);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 17 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openLittleWindow:@"https://example.com/little-moved"];
      [w openLittleWindow:@"https://example.org/little-closed"];
      std::printf("SELFTEST-LITTLE open=%lu\n", (unsigned long)[w littleWindowCount]);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 18 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSUInteger archivedBefore = [w archivedTabs].count;
      [w moveLittleWindowToMain:0];
      BOOL inSidebar = [w tabWithURLPrefix:@"https://example.com/little-moved"] != nil;
      [w closeLittleWindow:0];
      ArchivedTab* last = [w archivedTabs].lastObject;
      std::printf("SELFTEST-LITTLE movedInSidebar=%d left=%lu archivedDelta=%ld lastReason=%s lastURL=%s\n", inSidebar,
                  (unsigned long)[w littleWindowCount], (long)([w archivedTabs].count - archivedBefore),
                  last.reason.UTF8String, last.url.UTF8String);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 18500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      ArcItem* pinned = [w currentPinnedSection].children.firstObject;
      while (pinned.isFolder) pinned = pinned.children.firstObject;
      ArcItem* today = [w tabWithURLPrefix:@"https://example.com/little-moved"];  // moved into Today above
      NSString* sameSite = pinned.url ? [[NSURL URLWithString:pinned.url].scheme stringByAppendingFormat:@"://%@/other",
                                                                                    [NSURL URLWithString:pinned.url].host]
                                      : @"";
      std::printf("SELFTEST-PEEK pinnedOther=%d pinnedSameSite=%d todayOther=%d\n",
                  [w shouldPeekFromItem:pinned toURL:@"https://en.wikipedia.org/wiki/Peek"],
                  [w shouldPeekFromItem:pinned toURL:sameSite],
                  [w shouldPeekFromItem:today toURL:@"https://en.wikipedia.org/wiki/Peek"]);
      [w openPeek:@"https://example.net/peeked"];
      BOOL open = [w isPeeking];
      [w promotePeekToTab];
      std::printf("SELFTEST-PEEK opened=%d afterPromote=%d promotedInSidebar=%d\n", open, [w isPeeking],
                  [w tabWithURLPrefix:@"https://example.net/peeked"] != nil);
      [w openPeek:@"https://example.net/discarded"];
      [w closePeek];
      std::printf("SELFTEST-PEEK afterClose=%d discardedInSidebar=%d\n", [w isPeeking],
                  [w tabWithURLPrefix:@"https://example.net/discarded"] != nil);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 21 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSUInteger before = w.spaces.count;
      ArcSpace* original = w.currentSpace;
      ArcSpace* made = [w createSpaceNamed:@"SelfTest Space"];
      BOOL switched = w.currentSpace == made;
      BOOL sameProfile = [made.profileDirectory isEqualToString:original.profileDirectory];
      [w openInNewTab:@"https://example.com/in-new-space"];
      [w renameSpace:made to:@"SelfTest Renamed"];
      NSUInteger idx = [w.spaces indexOfObject:made];
      [w moveSpace:made by:-1];
      BOOL moved = [w.spaces indexOfObject:made] == idx - 1;
      [w selectSpaceAtIndex:0];
      BOOL selectFirst = w.currentSpace == w.spaces.firstObject;
      [w selectSpaceAtIndex:[w.spaces indexOfObject:made]];
      NSUInteger archivedBefore = [w archivedTabs].count;
      BOOL deleted = [w deleteSpace:made];
      std::printf("SELFTEST-SPACES created=%d switched=%d sameProfile=%d renamed=%d moved=%d selectFirst=%d "
                  "deleted=%d count=%lu->%lu archivedOnDelete=%ld lastReason=%s\n",
                  made != nil, switched, sameProfile, [made.title isEqualToString:@"SelfTest Renamed"], moved,
                  selectFirst, deleted, (unsigned long)before, (unsigned long)w.spaces.count,
                  (long)([w archivedTabs].count - archivedBefore),
                  ((ArchivedTab*)[w archivedTabs].lastObject).reason.UTF8String);
      [w saveSidebarNow];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 23 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w toggleSidebar:nil];
      BOOL hidden = [w sidebarHidden];
      [w toggleSidebar:nil];
      BOOL shownAgain = ![w sidebarHidden];
      NSArray<ArcItem*>* tabs = w.currentSpace.allTabs;
      [w selectTabAtIndex:0];
      BOOL first = [w shownItem] == tabs.firstObject;
      [w nextTab:nil];
      BOOL second = tabs.count > 1 && [w shownItem] == tabs[1];
      [w previousTab:nil];
      BOOL back = [w shownItem] == tabs.firstObject;
      [w openInNewTab:@"https://example.com/clear-me"];
      NSUInteger todayBefore = w.currentSpace.unpinned.children.count;
      NSUInteger archivedBefore = [w archivedTabs].count;
      [w clearToday:nil];
      std::printf("SELFTEST-SHORTCUTS sidebarHidden=%d sidebarBack=%d tab1=%d nextTab=%d prevTab=%d "
                  "clearToday=%lu->%lu archivedDelta=%ld\n", hidden, shownAgain, first, second, back,
                  (unsigned long)todayBefore, (unsigned long)w.currentSpace.unpinned.children.count,
                  (long)([w archivedTabs].count - archivedBefore));
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w selectTabAtIndex:0];
      [w openInSplit:@"https://example.com/left" horizontal:NO before:YES];
      NSUInteger leftIdx = [w indexOfShownInSplit];
      [w openInSplit:@"https://example.com/top" horizontal:YES before:YES];
      NSArray<NSValue*>* f = [w paneFrames];
      BOOL stacked = f.count == 3 && NSMinY(f[0].rectValue) >= NSMaxY(f[1].rectValue);
      [w flipSplitLayout:nil];
      NSArray<NSValue*>* g = [w paneFrames];
      BOOL flipped = g.count == 3 && NSMaxX(g[0].rectValue) <= NSMinX(g[1].rectValue);
      [w closeSplitPane:nil];
      [w closeSplitPane:nil];
      int shown = w.shownItem.browserId;
      NSUInteger todayBefore = w.currentSpace.unpinned.children.count;
      BOOL peekHandled = [w handleOpenURL:@"https://example.net/shift" fromBrowser:shown disposition:CEF_WOD_NEW_WINDOW
                              userGesture:YES];
      BOOL bgHandled = [w handleOpenURL:@"https://example.net/cmd" fromBrowser:shown
                            disposition:CEF_WOD_NEW_BACKGROUND_TAB userGesture:YES];
      BOOL unknownIgnored = ![w handleOpenURL:@"https://example.net/x" fromBrowser:-1 disposition:CEF_WOD_NEW_WINDOW
                                  userGesture:YES];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        std::printf("SELFTEST-SPLIT2 leftInsertedBefore=%d topStacked=%d flipped=%d\n", leftIdx == 0, stacked, flipped);
        std::printf("SELFTEST-OPEN shiftPeek=%d peeking=%d cmdBackground=%d todayDelta=%ld stillShown=%d unknownIgnored=%d\n",
                    peekHandled, [w isPeeking], bgHandled,
                    (long)(w.currentSpace.unpinned.children.count - todayBefore), w.shownItem.browserId == shown,
                    unknownIgnored);
        [w closePeek];
      });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 19 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      // Pretend 13h passed: every Today tab except the one on screen should be auto-archived.
      NSUInteger before = [w archivedTabs].count;
      NSUInteger n = [w runAutoArchiveWithThreshold:12 * 3600 now:[NSDate dateWithTimeIntervalSinceNow:13 * 3600]];
      NSUInteger fresh = [w runAutoArchiveWithThreshold:12 * 3600 now:[NSDate date]];
      std::printf("SELFTEST-ARCHIVE autoArchived=%lu stillFreshArchived=%lu archiveTotal=%lu (was %lu)\n",
                  (unsigned long)n, (unsigned long)fresh, (unsigned long)[w archivedTabs].count, (unsigned long)before);
      [w reopenLastArchived:nil];
      std::printf("SELFTEST-ARCHIVE afterReopen=%lu\n", (unsigned long)[w archivedTabs].count);
      std::printf("SELFTEST-ARCHIVE window all=%lu github=%lu nomatch=%lu\n",
                  (unsigned long)[w archiveWindowCountForQuery:@""],
                  (unsigned long)[w archiveWindowCountForQuery:@"github"],
                  (unsigned long)[w archiveWindowCountForQuery:@"zzqqxx-no-such-tab"]);
      [w saveSidebarNow];
    });
  }
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app { return YES; }

// Links clicked in other apps (when NotArc is the default browser) open in a Little Window.
- (void)application:(NSApplication*)app openURLs:(NSArray<NSURL*>*)urls {
  for (NSURL* url in urls) {
    if (!self.window) {
      if (!self.pendingURLs) self.pendingURLs = [NSMutableArray array];
      [self.pendingURLs addObject:url.absoluteString];
    } else {
      [self.window openLittleWindow:url.absoluteString];
    }
  }
}
@end

int main(int argc, char* argv[]) {
  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]) == "--check-arc-cookies") {  // decrypt Arc cookies; print counts only, never values
      @autoreleasepool {
        NSError* error = nil;
        NSString* pw = ArcSafeStoragePassword(&error);
        if (!pw) {
          std::fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
          return 1;
        }
        NSData* key = ArcCookieKey(pw);
        for (NSString* profile in @[ @"Profile 2", @"Profile 3", @"Profile 4" ]) {
          ArcCookieStats st;
          NSArray<ArcCookie*>* cookies = ArcReadCookies(ArcCookieDBPath(profile), key, &st, &error);
          NSUInteger google = 0;
          for (ArcCookie* c in cookies)
            if ([c.host hasSuffix:@"google.com"] && [c.name isEqualToString:@"SID"]) ++google;
          std::printf("COOKIES profile=\"%s\" total=%lu usable=%lu expired=%lu undecryptable=%lu googleSID=%lu\n",
                      profile.UTF8String, (unsigned long)st.total, (unsigned long)cookies.count,
                      (unsigned long)st.expired, (unsigned long)st.undecryptable, (unsigned long)google);
        }
      }
      return 0;
    }
    if (std::string(argv[i]) == "--dump-store" || std::string(argv[i]) == "--dump-selftest-store") {
      @autoreleasepool {
        NSString* path = SidebarStorePath(std::string(argv[i]) == "--dump-selftest-store");
        NSError* error = nil;
        NSString* focused = nil;
        NSArray* spaces = SidebarStoreLoad(path, &focused, &error);
        if (!spaces) {
          std::fprintf(stderr, "no store at %s (%s)\n", path.UTF8String, error.localizedDescription.UTF8String ?: "missing");
          return 1;
        }
        std::printf("STORE %s focused=%s\n%s", path.UTF8String, focused.UTF8String ?: "-",
                    ArcDescribeSpaces(spaces).UTF8String);
      }
      return 0;
    }
    if (std::string(argv[i]) == "--dump-arc") {  // print the imported Arc sidebar and exit
      @autoreleasepool {
        NSError* error = nil;
        NSArray* spaces = ArcImportSidebar(
            [ArcDataDirectory() stringByAppendingPathComponent:@"StorableSidebar.json"], &error);
        if (!spaces) {
          std::fprintf(stderr, "import failed: %s\n", error.localizedDescription.UTF8String);
          return 1;
        }
        std::printf("%s", ArcDescribeSpaces(spaces).UTF8String);
      }
      return 0;
    }
  }

  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInMain()) return 1;
  CefMainArgs main_args(argc, argv);

  @autoreleasepool {
    [NotArcApplication sharedApplication];

    BOOL selfTest = NO;
    for (int i = 1; i < argc; ++i)
      if (std::string(argv[i]) == "--selftest") selfTest = YES;
    BOOL selfTestReload = NO;
    for (int i = 1; i < argc; ++i)
      if (std::string(argv[i]) == "--selftest-reload") selfTest = selfTestReload = YES;

    CefSettings settings;
    settings.no_sandbox = true;
    NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                             .firstObject stringByAppendingPathComponent:@"NotArc"];
    NSString* cache = [support stringByAppendingPathComponent:selfTest ? @"SelfTestProfile" : @"Default"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    CefString(&settings.root_cache_path) = support.UTF8String;
    CefString(&settings.cache_path) = cache.UTF8String;

    if (!CefInitialize(main_args, settings, nullptr, nullptr)) return CefGetExitCode();

    AppDelegate* delegate = [AppDelegate new];
    delegate.selfTest = selfTest;
    delegate.selfTestReload = selfTestReload;
    NSApp.delegate = delegate;
    [delegate performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];

    CefRunMessageLoop();
    CefShutdown();
  }
  return 0;
}
