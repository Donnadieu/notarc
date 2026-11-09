#import <QuartzCore/QuartzCore.h>
// NotArc browser process entry point.
#import <Cocoa/Cocoa.h>

#include <cstdio>
#include <string>
#include <vector>

#import "app/arc_import.h"
#import "app/main_window.h"
#import "app/tidy_title.h"
#import "app/global_hotkey.h"
#import "app/email_peek.h"
#import "app/web_notifications.h"
#import "app/calendar_preview.h"
#import "app/main_window_max.h"
#import "app/arc_max.h"
#import "app/little_window.h"
#import "app/arc_extensions.h"
#import "app/link_routing.h"
#import "app/link_routing_editor.h"
#import "app/bookmark_import.h"
#import "app/shortcuts.h"
#import "app/chrome_page.h"
#include <sqlite3.h>
#import "app/boost_store.h"
#import "app/easel.h"
#import "app/live_folder.h"
#import "app/settings.h"
#include "app/content_blocker.h"
#include "app/browser_client.h"
#import "app/history_store.h"
#import "app/updater.h"
#import "app/downloads.h"
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
  NSUInteger active = [DownloadManager shared].inProgressCount;
  if (active && sender) {
    NSAlert* a = [NSAlert new];
    a.messageText = active == 1 ? @"A download is in progress." : [NSString stringWithFormat:@"%lu downloads are in progress.", (unsigned long)active];
    a.informativeText = @"Quitting NotArc will cancel them.";
    [a addButtonWithTitle:@"Quit"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
  }
  [MainWindowController prepareForQuit];  // other windows come back next launch
  for (NSWindow* w in self.windows) [w performClose:nil];
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property(nonatomic, strong) MainWindowController* window;
@property(nonatomic) BOOL selfTest;
@property(nonatomic) BOOL selfTestReload;  // phase 2: reopen the saved store, no actions
@property(nonatomic, copy) NSString* snapshotPath;  // --sidebar-snapshot=<png>: hidden run that renders the sidebar and quits
@property(nonatomic, copy) NSString* pendingSource;
@property(nonatomic, strong) NSMutableArray<NSString*>* pendingURLs;  // links that arrived before the window
@end

static BOOL gCrashTestDone = NO;
static BOOL gMaxTestDone = NO;    // self-test: the Arc Max checks (#58, #59) printed
static BOOL gLateTestsDone = NO;  // self-test: the last chained page checks (call, capture, PiP) printed  // self-test: the hang check finished (later page tests wait for it)

// Self-test: poll a condition every 0.25 s instead of a fixed wait, then continue (also on timeout).
static void WaitUntil(BOOL (^cond)(void), double timeoutSec, void (^then)(void)) {
  if (cond() || timeoutSec <= 0) { then(); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    WaitUntil(cond, timeoutSec - 0.25, then);
  });
}

@implementation AppDelegate

- (void)buildMenu {
  NSMenu* bar = [NSMenu new];
  NSMenuItem* appItem = [NSMenuItem new];
  [bar addItem:appItem];
  NSMenu* appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"Check for Updates..." action:@selector(checkForUpdates:) keyEquivalent:@""];
  [appMenu addItemWithTitle:@"Settings..." action:@selector(showSettings:) keyEquivalent:@","];
  [appMenu addItemWithTitle:@"Keyboard Shortcuts..." action:@selector(showKeyboardShortcuts:) keyEquivalent:@""];
  [appMenu addItem:[NSMenuItem separatorItem]];
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
  [edit addItemWithTitle:@"Paste and Go" action:@selector(pasteAndGo:) keyEquivalent:@""];
  [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:@"Find..." action:@selector(findInPage:) keyEquivalent:@"f"];
  [edit addItemWithTitle:@"Find Next" action:@selector(findNext:) keyEquivalent:@"g"];
  [edit addItemWithTitle:@"Find Previous" action:@selector(findPrevious:) keyEquivalent:@"G"];
  [edit addItem:[NSMenuItem separatorItem]];
  [edit addItemWithTitle:@"Copy URL" action:@selector(copyCurrentURL:) keyEquivalent:@"C"];
  [edit addItemWithTitle:@"Copy Clean Link" action:@selector(copyCleanLink:) keyEquivalent:@""];
  [edit addItemWithTitle:@"Copy Page as Markdown" action:@selector(copyPageAsMarkdown:) keyEquivalent:@""];  // #59
  NSMenuItem* md = [edit addItemWithTitle:@"Copy URL as Markdown" action:@selector(copyCurrentURLAsMarkdown:)
                            keyEquivalent:@"c"];
  md.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption;
  editItem.submenu = edit;

  NSMenuItem* fileItem = [NSMenuItem new];
  [bar insertItem:fileItem atIndex:1];  // App, File, Edit
  NSMenu* file = [[NSMenu alloc] initWithTitle:@"File"];
  [file addItemWithTitle:@"New Tab" action:@selector(newTab:) keyEquivalent:@"t"];
  [file addItemWithTitle:@"New Window" action:@selector(newWindow:) keyEquivalent:@"n"];
  [file addItemWithTitle:@"Open Location..." action:@selector(openLocation:) keyEquivalent:@"l"];
  [file addItemWithTitle:@"Close Tab" action:@selector(closeTab:) keyEquivalent:@"w"];
  [file addItemWithTitle:@"Undo Close Tab" action:@selector(undoCloseTab:) keyEquivalent:@""];
  [file addItemWithTitle:@"Reopen Archived Tab" action:@selector(reopenLastArchived:) keyEquivalent:@"T"];
  [file addItemWithTitle:@"Print..." action:@selector(printPage:) keyEquivalent:@"p"];
  [file addItemWithTitle:@"Show History" action:@selector(showHistory:) keyEquivalent:@"y"];
  [file addItemWithTitle:@"Show Archive" action:@selector(showArchive:) keyEquivalent:@""];
  [file addItemWithTitle:@"Show Downloads" action:@selector(showDownloads:) keyEquivalent:@"J"];
  [file addItemWithTitle:@"Clear History..." action:@selector(clearHistory:) keyEquivalent:@""];
  [file addItemWithTitle:@"Clear Browsing Data..." action:@selector(clearBrowsingData:) keyEquivalent:@"\x08"]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [file addItemWithTitle:@"Clear Cookies and Refresh" action:@selector(clearCookiesAndRefresh:) keyEquivalent:@""];
  [file addItem:[NSMenuItem separatorItem]];
  [file addItemWithTitle:@"Pin / Unpin Tab" action:@selector(togglePin:) keyEquivalent:@"d"];
  [file addItemWithTitle:@"Add to / Remove from Favorites" action:@selector(toggleFavorite:) keyEquivalent:@""];
  [file addItemWithTitle:@"New Folder" action:@selector(newFolder:) keyEquivalent:@""];
  [file addItemWithTitle:@"New Note" action:@selector(newNote:) keyEquivalent:@"n"].keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagControl;
  [file addItemWithTitle:@"New Easel" action:@selector(newEasel:) keyEquivalent:@""];
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Import Everything from Arc..." action:@selector(importEverythingFromArcMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import Bookmarks..." action:@selector(importBookmarksFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import History..." action:@selector(importHistoryFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import History from Arc" action:@selector(importArcHistoryFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import Extensions from Arc" action:@selector(importArcExtensionsFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Capture to Easel" action:@selector(captureToEasel:) keyEquivalent:@"2"].keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [file addItemWithTitle:@"Add Text to Easel" action:@selector(addEaselText:) keyEquivalent:@""];
  NSMenuItem* captureItem = [file addItemWithTitle:@"Capture" action:nil keyEquivalent:@""];
  NSMenu* capture = [[NSMenu alloc] initWithTitle:@"Capture"];
  [capture addItemWithTitle:@"Capture Area" action:@selector(captureArea:) keyEquivalent:@"3"].keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [capture addItemWithTitle:@"Capture Visible Page" action:@selector(captureVisiblePage:) keyEquivalent:@""];
  [capture addItemWithTitle:@"Capture Full Page" action:@selector(captureFullPage:) keyEquivalent:@""];
  [capture addItemWithTitle:@"Capture in Portrait Mode" action:@selector(capturePortrait:) keyEquivalent:@""];
  captureItem.submenu = capture;
  [file addItemWithTitle:@"New Incognito Window" action:@selector(newIncognitoWindow:) keyEquivalent:@"n"].keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  NSMenuItem* littleItem = [file addItemWithTitle:@"New Little Window" action:@selector(newLittleWindow:)
                                    keyEquivalent:@"n"];
  littleItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [file addItemWithTitle:@"Show Little Windows" action:@selector(showAllLittleWindows:) keyEquivalent:@""];
  [file addItemWithTitle:@"Close Little Windows" action:@selector(closeAllLittleWindows:) keyEquivalent:@""];
  // Peek and Little Window: move the page into the sidebar (handled by those windows only).
  [file addItemWithTitle:@"Open in Sidebar" action:@selector(openInMainWindow:) keyEquivalent:@"o"];
  [file addItemWithTitle:@"Reopen Closed Peek" action:@selector(reopenClosedPeek:) keyEquivalent:@""];
  [file addItemWithTitle:@"Peek Email from This Site" action:@selector(peekEmail:) keyEquivalent:@""];
  [file addItemWithTitle:@"Clear Today" action:@selector(clearToday:) keyEquivalent:@"K"];
  [file addItemWithTitle:@"Reset Pinned Tab" action:@selector(resetPinnedTab:) keyEquivalent:@""];
  [file addItemWithTitle:@"Replace Pinned URL with Current" action:@selector(replacePinnedURL:) keyEquivalent:@""];
  [file addItemWithTitle:@"Reset All Pinned Tabs" action:@selector(resetAllPinnedTabs:) keyEquivalent:@""];
  fileItem.submenu = file;

  // Format (Notes): bold, italic, underline, fonts and lists come from AppKit's text system.
  NSMenuItem* formatItem = [NSMenuItem new];
  [bar addItem:formatItem];
  NSMenu* format = [[NSMenu alloc] initWithTitle:@"Format"];
  NSFontManager* fm = [NSFontManager sharedFontManager];
  NSMenuItem* bold = [format addItemWithTitle:@"Bold" action:@selector(addFontTrait:) keyEquivalent:@"b"];
  bold.tag = NSBoldFontMask; bold.target = fm;
  NSMenuItem* italic = [format addItemWithTitle:@"Italic" action:@selector(addFontTrait:) keyEquivalent:@"i"];
  italic.tag = NSItalicFontMask; italic.target = fm;
  [format addItemWithTitle:@"Underline" action:@selector(underline:) keyEquivalent:@"u"];
  [format addItem:[NSMenuItem separatorItem]];
  [format addItemWithTitle:@"Bigger" action:@selector(modifyFont:) keyEquivalent:@"+"].tag = NSSizeUpFontAction;
  format.itemArray.lastObject.target = fm;
  [format addItemWithTitle:@"Smaller" action:@selector(modifyFont:) keyEquivalent:@"-"].tag = NSSizeDownFontAction;
  format.itemArray.lastObject.target = fm;
  format.itemArray.lastObject.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
  format.itemArray[format.itemArray.count - 2].keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
  [format addItemWithTitle:@"Show Fonts" action:@selector(orderFrontFontPanel:) keyEquivalent:@""].target = fm;  // Cmd+T is New Tab
  [format addItemWithTitle:@"Lists..." action:@selector(orderFrontListPanel:) keyEquivalent:@""];
  formatItem.submenu = format;

  NSMenuItem* viewItem = [NSMenuItem new];
  [bar addItem:viewItem];
  NSMenu* view = [[NSMenu alloc] initWithTitle:@"View"];
  [view addItemWithTitle:@"Toggle Sidebar" action:@selector(toggleSidebar:) keyEquivalent:@"s"];
  [view addItemWithTitle:@"Show Toolbar" action:@selector(toggleToolbar:) keyEquivalent:@"s"]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [view addItemWithTitle:@"Hide Space Header" action:@selector(toggleSpaceHeader:) keyEquivalent:@""];
  [view addItemWithTitle:@"Translate Page" action:@selector(translatePage:) keyEquivalent:@""];
  [view addItemWithTitle:@"Show Next Meeting from Calendar" action:@selector(toggleCalendar:) keyEquivalent:@""];
  // Arc Max (#58, #59): on-device AI, with non-AI fallbacks (app/arc_max.mm).
  [view addItemWithTitle:@"Ask on Page..." action:@selector(showAskOnPage:) keyEquivalent:@"A"];
  [view addItemWithTitle:@"Summarize Page" action:@selector(summarizePage:) keyEquivalent:@""];
  [view addItemWithTitle:@"Tidy Tab Title" action:@selector(tidyTabTitle:) keyEquivalent:@""];
  [view addItemWithTitle:@"Site Settings..." action:@selector(showSiteSettings:) keyEquivalent:@"i"]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [view addItemWithTitle:@"Reset Site Permissions" action:@selector(resetSitePermissions:) keyEquivalent:@""];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItemWithTitle:@"Boost This Site..." action:@selector(editBoost:) keyEquivalent:@"b"]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
  [view addItemWithTitle:@"Zap Element" action:@selector(zapElements:) keyEquivalent:@""];
  [view addItemWithTitle:@"Turn Boost On/Off" action:@selector(toggleBoost:) keyEquivalent:@""];
  [view addItem:[NSMenuItem separatorItem]];
  [view addItemWithTitle:@"Mute / Unmute Tab" action:@selector(toggleMuteCurrentTab:) keyEquivalent:@"m"]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [view addItemWithTitle:@"Focus Mode" action:@selector(toggleFocusMode:) keyEquivalent:@"F"]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift | NSEventModifierFlagOption;
  [view addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"]
      .keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
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
  [split addItemWithTitle:@"Maximize Pane" action:@selector(toggleMaximizePane:) keyEquivalent:@"\r"].keyEquivalentModifierMask = cs;
  [split addItemWithTitle:@"Close Split Pane" action:@selector(closeSplitPane:) keyEquivalent:@"-"]
      .keyEquivalentModifierMask = cs;
  [split addItemWithTitle:@"Focus Next Pane" action:@selector(focusNextPane:) keyEquivalent:@"]"]
      .keyEquivalentModifierMask = cs;
  [split addItemWithTitle:@"Focus Previous Pane" action:@selector(focusPreviousPane:) keyEquivalent:@"["]
      .keyEquivalentModifierMask = cs;
  [split addItemWithTitle:@"Share Split View" action:@selector(shareSplitView:) keyEquivalent:@""];
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
  [spacesMenu addItemWithTitle:@"Edit Theme Color..." action:@selector(editThemeColor:) keyEquivalent:@""];
  [spacesMenu addItemWithTitle:@"Change Space Icon..." action:@selector(changeSpaceIcon:) keyEquivalent:@""];
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
    if (i == 9) go.title = @"Go to Last Tab";
  }
  [tabs addItemWithTitle:@"Switch to Recent Tab" action:@selector(switchToRecentTab:) keyEquivalent:@"\t"]
      .keyEquivalentModifierMask = NSEventModifierFlagControl;
  [tabs addItemWithTitle:@"Tidy Today Tabs" action:@selector(tidyTodayTabs:) keyEquivalent:@""];  // Arc Max (#59)
  tabsItem.submenu = tabs;
  NSApp.mainMenu = bar;
  ApplyShortcutOverrides(bar);  // the user's own shortcuts (Settings > Keyboard Shortcuts...)
}

// Cmd+Option+N from any app opens a Little Window (#42). Never registered by test runs: a self-test must not take
// the key away from the person's own apps while it runs.
- (void)applyLittleHotkey {
  if (self.selfTest || !SettingBool(kSettingLittleHotkey)) {
    GlobalHotkeyRemove();
    return;
  }
  if (GlobalHotkeyInstalled()) return;
  __weak AppDelegate* weakSelf = self;
  GlobalHotkeyInstall(^{
    [NSApp activateIgnoringOtherApps:YES];
    [weakSelf.window newLittleWindow:nil];
  });
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
  self.window.selfTestProfiles = self.selfTest;
  // Self-tests never use Apple's real on-device model (#58): checks see "unavailable" unless they install a stub.
  if (self.selfTest) MaxSetTestModel(@"unavailable:selftest", nil);
  self.window.storePath = storePath;
  self.window.archivePath = ArchiveStorePath(self.selfTest);
  self.window.historyPath = HistoryStorePath(self.selfTest);
  self.window.linkRoutingPath = LinkRoutingPath(self.selfTest);
  if (self.selfTest) {
    [[NSFileManager defaultManager] removeItemAtPath:self.window.linkRoutingPath error:nil];
    // Profiles the self-test makes ("NotArc Profile N") start fresh each run instead of piling up. Only
    // "SelfTest ..." test data is removed; real profiles are never touched.
    NSFileManager* fm = NSFileManager.defaultManager;
    NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
        stringByAppendingPathComponent:@"NotArc"];
    for (NSString* n in [fm contentsOfDirectoryAtPath:support error:nil])
      if ([n hasPrefix:@"SelfTest Space NotArc Profile "]) [fm removeItemAtPath:[support stringByAppendingPathComponent:n] error:nil];
    [fm removeItemAtPath:[support stringByAppendingPathComponent:@"SelfTestProfiles.json"] error:nil];
  }
  if (!self.selfTest) [[Updater shared] scheduleDailyChecks];
  [self applyLittleHotkey];
  if (!self.selfTest) {
    __weak AppDelegate* weakSelf = self;
    WebNotificationsSetClickHandler(^(NSString* itemID) {  // clicking a web notification shows its tab (#78)
      [NSApp activateIgnoringOtherApps:YES];
      [weakSelf.window showItemWithID:itemID];
    });
  }
  if (self.selfTest) [[NSFileManager defaultManager] removeItemAtPath:self.window.historyPath error:nil];
  if (self.selfTest && !self.selfTestReload)
    [[NSFileManager defaultManager] removeItemAtPath:self.window.archivePath error:nil];
  // First launch: bring over Arc's archive once (read-only), like the sidebar import.
  if (![[NSFileManager defaultManager] fileExistsAtPath:self.window.archivePath]) {
    NSMutableArray* imported = ArchiveImportArc([arcDir stringByAppendingPathComponent:@"StorableArchiveItems.json"]);
    ArchiveStoreSave(imported, self.window.archivePath);
    std::fprintf(stderr, "imported %lu archived tabs from Arc\n", (unsigned long)imported.count);
    if (self.selfTest) std::printf("SELFTEST-ARCIMPORT archived=%lu\n", (unsigned long)imported.count);
  }
  BOOL crashedLastTime = SessionMarkerBegin(self.selfTest);
  if (self.selfTest && !self.selfTestReload) crashedLastTime = NO;  // phase 1 starts clean
  if (crashedLastTime) std::fprintf(stderr, "NotArc didn't quit cleanly last time; reopening open tabs\n");
  self.window.restoreOpenTabs = crashedLastTime;
  [self.window saveSidebarNow];  // first launch: persist the import immediately
  if (self.selfTest) {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.window.window.alphaValue = 0.01;
    self.window.window.ignoresMouseEvents = YES;
  }
  [self.window showWindow:nil];
  [self.window createBrowsers];
  if (!self.selfTest) [self.window restoreSavedWindows];  // windows open at the last quit (#39)
  for (NSString* url in self.pendingURLs) [self.window routeExternalLink:url sourceApp:self.pendingSource];
  self.pendingURLs = nil;
  if (!self.selfTest) [NSApp activateIgnoringOtherApps:YES];
  if (!self.selfTest) [self.window offerArcImportIfFirstLaunch];  // never in hidden test runs

  if (self.selfTest) {
    // Hidden run: no Dock icon, never activates, every window 1% opaque (invisible, but not "occluded", so media still plays) and click-through,
    // so a test never shows up on screen or takes focus. Chromium is told not to throttle hidden windows.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer*) {
      for (NSWindow* win in NSApp.windows) {
        if (win.alphaValue > 0.011) win.alphaValue = 0.01;
        win.ignoresMouseEvents = YES;
      }
    }];
    [self.window openTabsForSelfTest:1];  // first tab of every Space, each in its own profile
    if (self.snapshotPath) {
      ArcSpace* busiest = self.window.currentSpace;
      for (ArcSpace* s in self.window.spaces)
        if (s.unpinned.children.count > busiest.unpinned.children.count) busiest = s;
      if (busiest != self.window.currentSpace) [self.window switchToSpace:busiest];
      if (!busiest.unpinned.children.count)  // the self-test copy has no Today tabs: open a few so rows render
        for (NSString* u in @[ @"https://github.com/", @"https://www.youtube.com/", @"https://www.reddit.com/", @"https://news.ycombinator.com/" ])
          [self.window openInNewTab:u];
      std::printf("SNAPSHOT-SPACES %lu current=%s tabs=%lu icons=%lu\n", (unsigned long)self.window.spaces.count,
                  self.window.currentSpace.title.UTF8String, (unsigned long)self.window.currentSpace.unpinned.children.count,
                  (unsigned long)self.window.spaceBarIcons.count);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        std::printf("SNAPSHOT %s\n", [self.window writeSidebarSnapshot:self.snapshotPath] ? "ok" : "failed");
        std::fflush(stdout);
        [self.window closeAllBrowsers];
      });
      return;
    }
    if (!self.selfTestReload) [self runSelfTestActions];
    if (self.selfTestReload) {
      // Phase 2 (run by scripts/test-session-restore.sh): report what came back, then quit cleanly.
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        MainWindowController* w = self.window;
        [w testCookieNamesForURL:@"https://example.org/" done:^(NSArray<NSString*>* names) {
          std::printf("SELFTEST-RESTORE crashedLastTime=%d restored=%lu live=%lu shown=%s sessionLogin=%d savedLogin=%d\n",
                      crashedLastTime, (unsigned long)w.restoredTabCount, (unsigned long)w.liveTabCount,
                      w.shownItem.url.UTF8String ?: "-", [names containsObject:@"notarc_session_login"],
                      [names containsObject:@"notarc_saved_login"]);
          std::fflush(stdout);
          [NSApp terminate:nil];
        }];
      });
    }
    if (!self.selfTestReload)  // Call controls (#47): fake camera + mic only (--use-fake-device-for-media-stream).
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
       WaitUntil(^{ return gCrashTestDone; }, 40, ^{  // the hang check must have the visible tab to itself
        MainWindowController* w = self.window;
        [w openInNewTab:@"https://example.org/call-controls"];
        ArcItem* t = w.shownItem;
        [w setSitePermission:@"microphone" value:@YES forOrigin:@"https://example.org"];
        [w setSitePermission:@"camera" value:@YES forOrigin:@"https://example.org"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [w runJS:@"navigator.mediaDevices.getUserMedia({audio:true,video:true}).then(s=>{window.__s=s;document.title='call:on'},"
                   @"e=>document.title='call:'+e.name)" inItem:t];
          WaitUntil(^{ return (BOOL)(w.callItem == t); }, 10, ^{
            BOOL detected = w.callItem == t && t.usingMic && t.usingCamera;
            BOOL shown = w.callControlsShown;
            [w toggleCallMic:t];
            [w toggleCallCamera:t];
            [w runJS:@"setTimeout(()=>{const s=window.__s;document.title='tracks:'+(s?s.getAudioTracks()[0].enabled+','+"
                     @"s.getVideoTracks()[0].enabled:'none')},300)" inItem:t];
            WaitUntil(^{ return (BOOL)[t.liveTitle hasPrefix:@"tracks:"]; }, 5, ^{
              BOOL off = [t.liveTitle isEqualToString:@"tracks:false,false"] && t.micMuted && t.cameraOff;
              [w toggleCallMic:t];
              [w runJS:@"setTimeout(()=>{document.title='mic2:'+window.__s.getAudioTracks()[0].enabled},300)" inItem:t];
              WaitUntil(^{ return (BOOL)[t.liveTitle hasPrefix:@"mic2:"]; }, 5, ^{
                BOOL back = [t.liveTitle isEqualToString:@"mic2:true"] && !t.micMuted;
                [w runJS:@"window.__s.getTracks().forEach(x=>x.stop())" inItem:t];
                WaitUntil(^{ return (BOOL)(w.callItem == nil); }, 8, ^{
                  if (getenv("NOTARC_CALL_DEBUG")) std::printf("CALL-DEBUG %s\n", t.liveTitle.UTF8String ?: "-");
                  std::printf("SELFTEST-CALLCONTROLS detected=%d shown=%d muted=%d unmuted=%d ended=%d\n", detected, shown, off,
                              back, w.callItem == nil && !w.callControlsShown);
                  [w setSitePermission:@"microphone" value:nil forOrigin:@"https://example.org"];
                  [w setSitePermission:@"camera" value:nil forOrigin:@"https://example.org"];
                  // Capture (#48): visible, area, full page and portrait on a tall test page; files go to a scratch
                  // folder and the clipboard is a private pasteboard, so nothing of the user's is touched.
                  NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"NotArcCaptureSelfTest"];
                  [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
                  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
                  w.captureDirectory = dir;
                  [w runJS:@"document.body.style.height='3000px';document.title='tall'" inItem:t];
                  WaitUntil(^{ return [t.liveTitle isEqualToString:@"tall"]; }, 5, ^{
                    [w capture:@"visible" rect:NSZeroRect done:^(NSData* vis) {
                      NSBitmapImageRep* v = vis ? [NSBitmapImageRep imageRepWithData:vis] : nil;
                      [w capture:@"area" rect:NSMakeRect(10, 10, 100, 50) done:^(NSData* area) {
                        NSBitmapImageRep* a = area ? [NSBitmapImageRep imageRepWithData:area] : nil;
                        [w capture:@"full" rect:NSZeroRect done:^(NSData* full) {
                          NSBitmapImageRep* f = full ? [NSBitmapImageRep imageRepWithData:full] : nil;
                          [w capture:@"portrait" rect:NSZeroRect done:^(NSData* por) {
                            NSBitmapImageRep* p = por ? [NSBitmapImageRep imageRepWithData:por] : nil;
                            double sc = v && v.size.width > 0 ? v.pixelsWide / v.size.width : 1;
                            BOOL visible = v.pixelsWide > 100;
                            BOOL areaOK = a && llabs(a.pixelsWide - (NSInteger)(100 * v.pixelsWide / [w webViewForItem:t].bounds.size.width)) <= 2;
                            BOOL fullOK = f && f.pixelsHigh >= 3000 && f.pixelsHigh > v.pixelsHigh;
                            BOOL portrait = p && p.pixelsWide > v.pixelsWide && p.pixelsHigh > v.pixelsHigh;
                            NSInteger soundsBefore = SoundEffectsPlayedForTest();
                            NSString* path = [w deliverCapture:area];
                            BOOL shutter = SoundEffectsPlayedForTest() == soundsBefore + 1;
                            NSPasteboard* pb = [NSPasteboard pasteboardWithName:@"io.github.donnadieu.notarc.selftest"];
                            BOOL saved = path && [path hasPrefix:dir] && [[NSData dataWithContentsOfFile:path] isEqual:area];
                            BOOL copied = [[pb dataForType:NSPasteboardTypePNG] isEqual:area];
                            (void)sc;
                            std::printf("SELFTEST-CAPTURE visible=%d area=%d full=%d portrait=%d saved=%d copied=%d shutter=%d\n",
                                        visible, areaOK, fullOK, portrait, saved, copied, shutter);
                            if (!areaOK || !fullOK) std::printf("CAPTURE-DEBUG v=%ldx%ld a=%ldx%ld f=%ldx%ld view=%.0f\n",
                                (long)v.pixelsWide, (long)v.pixelsHigh, (long)a.pixelsWide, (long)a.pixelsHigh,
                                (long)f.pixelsWide, (long)f.pixelsHigh, [w webViewForItem:t].bounds.size.width);
                            [pb releaseGlobally];
                            [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
                            // Automatic PiP (#46): a playing video (canvas stream, no network) pops out when its tab is
                            // left and goes back on return. requestPictureInPicture is stubbed so no window ever shows.
                            [w runJS:@"(()=>{const c=document.createElement('canvas');c.width=64;c.height=36;const x=c.getContext('2d');"
                                     @"setInterval(()=>{x.fillStyle='#'+Math.floor(Math.random()*4095).toString(16).padStart(3,'0');"
                                     @"x.fillRect(0,0,64,36)},50);const v=document.createElement('video');"
                                     @"v.srcObject=c.captureStream(20);v.muted=false;v.volume=0.01;document.body.appendChild(v);window.__pipLog=[];"
                                     @"let inPip=null;Object.defineProperty(document,'pictureInPictureElement',{get:()=>inPip});"
                                     @"HTMLVideoElement.prototype.requestPictureInPicture=function(){"
                                     @"if(!navigator.userActivation.isActive)return Promise.reject(new DOMException('','NotAllowedError'));"
                                     @"inPip=this;__pipLog.push('in');return Promise.resolve({})};"
                                     @"document.exitPictureInPicture=()=>{inPip=null;__pipLog.push('out');return Promise.resolve()};"
                                     @"v.play().then(()=>document.title='video:on')})()" inItem:t];
                            WaitUntil(^{ [w pollMediaNow]; return (BOOL)([t.liveTitle isEqualToString:@"video:on"] && t.mediaPlaying); }, 10, ^{
                              BOOL playing = t.mediaPlaying;
                              [w openInNewTab:@"https://example.com/pip-other"];
                              ArcItem* other = w.shownItem;
                              WaitUntil(^{ return t.inPictureInPicture; }, 5, ^{
                                BOOL popped = t.inPictureInPicture;
                                [w showItem:t];
                                WaitUntil(^{ return (BOOL)!t.inPictureInPicture; }, 5, ^{
                                  BOOL back = !t.inPictureInPicture;
                                  [w runJS:@"document.title='piplog:'+__pipLog.join(',')" inItem:t];
                                  WaitUntil(^{ return [t.liveTitle hasPrefix:@"piplog:"]; }, 5, ^{
                                    BOOL log = [t.liveTitle isEqualToString:@"piplog:in,out"];
                                    SettingSetObject(kSettingAutoPiP, @NO);
                                    [w showItem:other];
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                      BOOL offRespected = !t.inPictureInPicture;
                                      SettingSetObject(kSettingAutoPiP, nil);
                                      if (!log) std::printf("PIP-DEBUG %s\n", t.liveTitle.UTF8String);
                                      gLateTestsDone = YES;
                                      std::printf("SELFTEST-AUTOPIP playing=%d popped=%d back=%d gesture=%d settingOff=%d\n", playing,
                                                  popped, back, log, offRespected);
                                    });
                                  });
                                });
                              });
                            });
                          }];
                        }];
                      }];
                    }];
                  });
                });
              });
            });
          });
        });
       });
      });
    // Arc Max (#58, #59): after the late page checks, so its background tab never shares the screen with them.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 135 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      WaitUntil(^{ return gLateTestsDone; }, 40, ^{ [self runMaxSelfTest]; });
    });
    if (!self.selfTestReload)
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 165 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self.window openInNewTab:@"https://example.org/session-restore-marker"];
        [self.window saveSidebarNow];
        // Logins must survive a restart: one session-only and one dated cookie, checked by the reload phase.
        [self.window setTestCookie:@"notarc_session_login" value:@"1" url:@"https://example.org/" session:YES done:nil];
        [self.window setTestCookie:@"notarc_saved_login" value:@"1" url:@"https://example.org/" session:NO done:nil];
      });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 170 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
     WaitUntil(^{ return (BOOL)((gLateTestsDone && gMaxTestDone) || self.selfTestReload); }, 40, ^{
      void (^finish)(void) = ^{
        for (NSDictionary* tab in [self.window tabSnapshot])
          std::printf("SELFTEST space=\"%s\" profile=\"%s\" title=\"%s\" url=%s\n", [tab[@"space"] UTF8String],
                      [tab[@"profile"] UTF8String], [tab[@"title"] UTF8String], [tab[@"url"] UTF8String]);
        std::fflush(stdout);
        [self.window closeAllBrowsers];
      };
      if (self.selfTestReload) { finish(); return; }
      // Multiple windows (#39): runs last so no other check shares the screen with a second window.
      MainWindowController* w = self.window;
      ArcItem* t = w.shownItem;
      int bid = t.browserId;
      MainWindowController* w2 = [w openNewWindowShowing:t];
      BOOL opened = [MainWindowController openWindowCount] == 2 && !w2.isMainWindowController && w.isMainWindowController;
      BOOL shared = w2.spaces == w.spaces && w2.currentSpace == w.currentSpace;
      BOOL moved = w2.shownItem == t && [w2 hostsBrowserOfItem:t] && ![w hostsBrowserOfItem:t] && w.shownItem != t;
      BOOL sameBrowser = bid != 0 && t.browserId == bid;
      // Chrome-style pages (#66, off by default): the page window must follow into the new window.
      BOOL chromeMoved = !ChromePagesEnabled() || ([w2 chromePageOfItem:t isInWindow:w2.window] && ![w chromePageOfItem:t isInWindow:w.window]);
      [w openInNewTab:@"https://example.org/window-sync" background:YES];
      ArcSpace* sp = w.currentSpace;
      ArcItem* added = sp.unpinned.children.firstObject;
      WaitUntil(^{ return [w2 sidebarShowsItem:added]; }, 3, ^{
        BOOL synced = [w2 sidebarShowsItem:added] && w2.shownItem == t;
        [sp.unpinned.children removeObject:added];
        BOOL saved = [MainWindowController savedWindowCount] == 1;
        NSArray<NSDictionary*>* list = [MainWindowController windowStateList];
        BOOL button = [w2 moveToMainButtonShown] && ![w moveToMainButtonShown];
        [w2 moveShownToMainWindow:nil];
        BOOL chromeBack = !ChromePagesEnabled() || [w chromePageOfItem:t isInWindow:w.window];
        BOOL back = w.shownItem == t && [w hostsBrowserOfItem:t] && ![w2 hostsBrowserOfItem:t] && t.browserId == bid;
        [w2.window close];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
          BOOL closed = [MainWindowController openWindowCount] == 1;
          BOOL kept = [w.currentSpace.allTabs containsObject:t] && [w hostsBrowserOfItem:t];
          BOOL forgot = [MainWindowController savedWindowCount] == 0;  // closed by hand: not reopened
          // Next launch: the saved window comes back on its Space; a tab on screen in the main window stays there.
          NSArray<MainWindowController*>* again = [w restoreWindowsFromList:list];
          MainWindowController* w3 = again.firstObject;
          BOOL restored = again.count == 1 && [MainWindowController openWindowCount] == 2 &&
                          w3.currentSpace.spaceID && [w3.currentSpace.spaceID isEqualToString:list.firstObject[@"space"]] &&
                          w.shownItem == t && [w hostsBrowserOfItem:t];
          [w3.window close];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
            BOOL closedAgain = [MainWindowController openWindowCount] == 1;
            [w saveSidebarNow];
            std::printf("SELFTEST-WINDOWS opened=%d shared=%d moved=%d sameBrowser=%d synced=%d back=%d closed=%d kept=%d "
                        "saved=%d forgot=%d restored=%d closedAgain=%d button=%d chromeMoved=%d chromeBack=%d\n",
                        opened, shared, moved, sameBrowser, synced, back, closed, kept, saved, forgot, restored, closedAgain, button,
                        chromeMoved, chromeBack);
            finish();
          });
        });
      });
     });
    });
  }
}

// Arc Max (#58, #59). Pure parts (ChatGPT address, prompts, reply parsing, HTML and fallbacks) first, then a
// background tab with a known page for page text, Copy Page as Markdown, Ask on Page and summaries, link previews
// (fake fetcher, no network), Tidy Tabs on a scratch Space that isn't in the sidebar, and tidy titles. The model is a
// stub here (both "available" and "off"); the real model's state is only reported (model=available|unavailable:...).
- (void)runMaxSelfTest {
  MainWindowController* w = self.window;
  NSString* liveModel = MaxRealModelAvailability();
  BOOL chatgptURL = [MaxChatGPTURL(@" what is 2+2? & more ") isEqualToString:@"https://chatgpt.com/?q=what%20is%202%2B2%3F%20%26%20more"];
  NSDictionary* (^chatRow)(NSString*) = ^NSDictionary*(NSString* q) {
    for (NSDictionary* d in [w commandSuggestionsFor:q])
      if ([d[@"kind"] isEqualToString:@"chatgpt"]) return d;
    return nil;
  };
  NSDictionary* row = chatRow(@"how tall is mount everest");
  BOOL chatgptRow = [row[@"url"] isEqualToString:@"https://chatgpt.com/?q=how%20tall%20is%20mount%20everest"] &&
                    [[w commandSuggestionsFor:@"how tall is mount everest"].lastObject isEqual:row];
  BOOL urlNoRow = chatRow(@"example.com/page") == nil;
  SettingSetBool(kSettingMaxChatGPT, NO);
  BOOL chatgptOff = chatRow(@"how tall is mount everest") == nil;
  SettingSetObject(kSettingMaxChatGPT, nil);
  SettingSetBool(kSettingMaxEnabled, NO);
  BOOL master = chatRow(@"how tall is mount everest") == nil && !MaxFeatureOn(kSettingMaxPreviews);
  SettingSetObject(kSettingMaxEnabled, nil);
  master = master && MaxFeatureOn(kSettingMaxPreviews) && chatRow(@"how tall is mount everest") != nil;

  NSArray* groups = MaxParseTidyGroups(@"Here you go:\n- **Reading**: 1, 3\nBad: 9\nDup: 1, 2\nCode: 2, 4 and 5\n", 5);
  NSArray* labels = MaxParseTidyGroups(@"3: Programming\n2: Shopping\n3: News\n4: news\n5: Programming", 5);  // line order wins
  BOOL parse = groups.count == 2 && [groups[0][@"name"] isEqualToString:@"Reading"] && [groups[0][@"indexes"] isEqual:(@[ @0, @2 ])] &&
               [groups[1][@"name"] isEqualToString:@"Code"] && [groups[1][@"indexes"] isEqual:(@[ @3, @4 ])] && labels.count == 2 &&
               [labels[0][@"name"] isEqualToString:@"Programming"] && [labels[0][@"indexes"] isEqual:(@[ @0, @4 ])] &&
               [labels[1][@"indexes"] isEqual:(@[ @2, @3 ])] && MaxParseTidyGroups(@"I can't help with that.", 5).count == 0;
  NSArray* sites = MaxGroupTabsBySite(@[ @{@"url" : @"https://github.com/a"}, @{@"url" : @"https://www.bbc.co.uk/news"},
                                         @{@"url" : @"https://gist.github.com/b"}, @{@"url" : @"https://bbc.co.uk/sport"},
                                         @{@"url" : @"https://example.org/"} ]);
  BOOL bySite = sites.count == 2 && [sites[0][@"name"] isEqualToString:@"Github"] && [sites[0][@"indexes"] isEqual:(@[ @0, @2 ])] &&
                [sites[1][@"name"] isEqualToString:@"Bbc"];
  BOOL titles = [MaxCleanModelTitle(@"\"Swift Concurrency Guide.\"\nmore") isEqualToString:@"Swift Concurrency Guide"] &&
                [MaxCleanSummary(@"Here:\n- **One** point\n* Two") isEqualToString:@"Here:\n• One point\n• Two"];
  NSString* longText = [@"" stringByPaddingToLength:20000 withString:@"word " startingAtIndex:0];
  NSString* ask = MaxAskPrompt(@"Who wrote it?", @"T", @"https://example.org/", longText);
  BOOL prompt = [ask containsString:@"Question: Who wrote it?"] && ask.length < 7300 && [MaxTidyTabsPrompt(@[ @{@"title" : @"A", @"url" : @"https://www.x.org/"} ]) containsString:@"1. A (x.org)"];
  NSDictionary* html = MaxParseHTML(@"<html><head><title>Fallback</title><meta property=\"og:title\" content=\"Story &amp; More\">"
                                    @"<meta content='A short description.' name=description><script>var x='<p>no</p>'</script></head>"
                                    @"<body><nav><p>Menu item</p></nav><p>First paragraph text here.</p><p>Second &#8220;quoted&#8221; one.</p></body></html>");
  BOOL htmlOK = [html[@"title"] isEqualToString:@"Story & More"] && [html[@"description"] isEqualToString:@"A short description."] &&
                [html[@"text"] containsString:@"First paragraph text here."] && [html[@"text"] containsString:@"\u201cquoted\u201d"] &&
                ![html[@"text"] containsString:@"Menu item"] && ![html[@"text"] containsString:@"no"];
  BOOL menu = NO;
  for (NSMenuItem* top in NSApp.mainMenu.itemArray)
    for (NSMenuItem* mi in top.submenu.itemArray)
      if (mi.action == @selector(showAskOnPage:) && [mi.keyEquivalent isEqualToString:@"A"]) menu = YES;
  NSView* section = MaxSettingsSection();
  NSUInteger boxes = 0;
  NSMutableArray* stack = [NSMutableArray arrayWithObject:section];
  while (stack.count) {
    NSView* v = stack.lastObject;
    [stack removeLastObject];
    if ([v isKindOfClass:NSButton.class]) ++boxes;
    [stack addObjectsFromArray:v.subviews];
  }
  BOOL settings = boxes == 6;

  // A page we control, loaded in a background tab (never shown, so no other check's tab is disturbed).
  [w openInNewTab:@"https://example.org/max-selftest" background:YES];
  ArcItem* t = w.currentSpace.unpinned.children.firstObject;
  [w maxLoadItemInBackground:t];
  WaitUntil(^{ return (BOOL)(t.browserId && [t.liveTitle hasPrefix:@"Example"]); }, 15, ^{
    [w runJS:@"document.body.innerHTML='<article><h1>Max Test</h1><p>Hello <b>bold</b> and <a href=\"/x\">link</a>.</p>"
             @"<ul><li>one</li><li>two<ul><li>nested</li></ul></li></ul><ol><li>first</li></ol>"
             @"<pre><code>let a = 1;\\n  b();</code></pre><blockquote>quoted words</blockquote>"
             @"<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>2</td></tr></table><img src=\"/i.png\" alt=\"pic\">"
             @"<p>Ada Lovelace wrote the first published program long ago for the engine.</p>"
             @"<p>The sample code on this page is written in JavaScript for testing.</p>"
             @"<p style=\"display:none\">hidden words here</p><script>bad()</script></article>';document.title='Max Test Page'"
          inItem:t];
    WaitUntil(^{ return [t.liveTitle isEqualToString:@"Max Test Page"]; }, 5, ^{
      [w maxPageMarkdownOfItem:t done:^(NSString* md) {
        NSArray* want = @[ @"# Max Test\n\nSource: https://example.org/max-selftest\n\nHello **bold** and [link](https://example.org/x).",
                           @"- one\n- two\n  - nested", @"1. first", @"```\nlet a = 1;\n  b();\n```", @"> quoted words",
                           @"| A | B |\n| --- | --- |\n| 1 | 2 |", @"![pic](https://example.org/i.png)" ];
        BOOL markdown = md.length > 0 && ![md containsString:@"bad()"] && ![md containsString:@"hidden words"];
        for (NSString* x in want)
          if (![md containsString:x]) {
            markdown = NO;
            std::printf("SELFTEST-MAX-DEBUG missing=[%s]\n", [x stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"].UTF8String);
          }
        if (!markdown) std::printf("SELFTEST-MAX-DEBUG md=[%s]\n", [md stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"].UTF8String ?: "nil");
        NSInteger general = NSPasteboard.generalPasteboard.changeCount;
        [w copyMarkdownOfItem:t done:^(NSString* md2) {
          NSPasteboard* pb = [NSPasteboard pasteboardWithName:@"io.github.donnadieu.notarc.selftest"];
          BOOL copied = md2.length && [[pb stringForType:NSPasteboardTypeString] isEqualToString:md2];
          BOOL generalUntouched = NSPasteboard.generalPasteboard.changeCount == general;
          [pb releaseGlobally];
          [w maxPageTextOfItem:t done:^(NSDictionary* page) {
            BOOL pageText = [page[@"text"] containsString:@"Hello bold and link."] && [page[@"title"] isEqualToString:@"Max Test Page"] &&
                            ![page[@"text"] containsString:@"hidden words"];
            __block NSString* seenPrompt = nil;
            MaxSetTestModel(@"available", ^(NSString* ins, NSString* p, MaxReply reply) {
              seenPrompt = p;
              reply([p containsString:@"Question: Who wrote the first program?"] && [p containsString:@"Hello bold"] ? @"Ada wrote it." : @"bad", nil);
            });
            [w askOnPage:@"Who wrote the first program?" item:t done:^(NSString* a1, BOOL ai1) {
              BOOL askAI = ai1 && [a1 isEqualToString:@"Ada wrote it."] && w.maxPanelShown && [w.maxPanelAnswer isEqualToString:@"Ada wrote it."];
              MaxSetTestModel(@"unavailable:off", nil);
              [w askOnPage:@"Who wrote the first program?" item:t done:^(NSString* a2, BOOL ai2) {
                BOOL askFallback = !ai2 && [a2 containsString:@"Ada Lovelace wrote"] && [w.maxPanelNote containsString:@"Apple Intelligence is off"];
                BOOL offersChatGPT = w.maxPanelOffersChatGPT;
                [w summarizeItem:t done:^(NSString* s1, BOOL ai3) {
                  BOOL summaryFallback = !ai3 && [s1 hasPrefix:@"• "];
                  MaxSetTestModel(@"available", ^(NSString* ins, NSString* p, MaxReply reply) {
                    reply([ins containsString:@"bullet"] ? @"- Point one\n- Point two" : @"bad", nil);
                  });
                  [w summarizeItem:t done:^(NSString* s2, BOOL ai4) {
                    BOOL summaryAI = ai4 && [s2 isEqualToString:@"• Point one\n• Point two"] && [w.maxPanelAnswer isEqualToString:s2];
                    [w hideMaxPanels];
                    [self runMaxPreviewAndTidyTest:t
                                           results:[NSString stringWithFormat:
                        @"model=%@ chatgptURL=%d chatgptRow=%d urlNoRow=%d chatgptOff=%d master=%d parse=%d bySite=%d titles=%d "
                        @"prompt=%d html=%d menu=%d settings=%d markdown=%d copied=%d generalUntouched=%d pageText=%d askAI=%d "
                        @"askFallback=%d offersChatGPT=%d summaryFallback=%d summaryAI=%d",
                        [liveModel isEqualToString:@"available"] ? @"available" : liveModel, chatgptURL, chatgptRow, urlNoRow,
                        chatgptOff, master, parse, bySite, titles, prompt, htmlOK, menu, settings, markdown, copied,
                        generalUntouched, pageText, askAI, askFallback, offersChatGPT, summaryFallback, summaryAI]];
                    (void)seenPrompt;
                  }];
                }];
              }];
            }];
          }];
        }];
      }];
    });
  });
}

- (void)runMaxPreviewAndTidyTest:(ArcItem*)t results:(NSString*)first {
  MainWindowController* w = self.window;
  std::printf("SELFTEST-MAX %s\n", first.UTF8String);
  NSMutableArray<NSString*>* fetched = [NSMutableArray array];
  MaxSetTestFetcher(^(NSString* url, MaxFetchDone done) {
    [fetched addObject:url];
    done(@"<html><head><title>Linked Story</title><meta name=description content='About the linked page.'></head>"
         @"<body><p>The linked page explains how previews work in this browser today.</p></body></html>", nil);
  });
  MaxSetTestModel(@"unavailable:off", nil);
  [w maxLinkHovered:@"https://news.example/story" shiftDown:NO];
  BOOL noShift = !w.maxPreviewShown;
  [w maxLinkHovered:@"https://news.example/story" shiftDown:YES];
  WaitUntil(^{ return (BOOL)(w.maxPreviewShown && [w.maxPreviewText isEqualToString:@"About the linked page."]); }, 3, ^{
    BOOL previewFallback = w.maxPreviewShown && [w.maxPreviewText isEqualToString:@"About the linked page."];
    MaxSetTestModel(@"available", ^(NSString* ins, NSString* p, MaxReply reply) {
      reply([p containsString:@"previews work"] ? @"- AI preview point" : @"bad", nil);
    });
    [w maxLinkHovered:@"https://news.example/other" shiftDown:YES];
    WaitUntil(^{ return [w.maxPreviewText isEqualToString:@"• AI preview point"]; }, 3, ^{
      BOOL previewAI = [w.maxPreviewText isEqualToString:@"• AI preview point"];
      [w maxLinkHovered:@"" shiftDown:NO];
      WaitUntil(^{ return (BOOL)!w.maxPreviewShown; }, 2, ^{
        BOOL previewHidden = !w.maxPreviewShown;
        SettingSetBool(kSettingMaxPreviews, NO);
        [w maxLinkHovered:@"https://news.example/third" shiftDown:YES];
        BOOL previewOff = !w.maxPreviewShown;
        SettingSetObject(kSettingMaxPreviews, nil);
        [w maxLinkHovered:@"" shiftDown:NO];
        BOOL fetchedOK = [fetched isEqualToArray:(@[ @"https://news.example/story", @"https://news.example/other" ])];
        BOOL notWeb = !MaxPreviewURLAllowed(@"javascript:alert(1)") && !MaxPreviewURLAllowed(@"file:///etc/hosts");
        MaxSetTestFetcher(nil);

        // Tidy Tabs on a scratch Space that isn't in the sidebar: by site without the model, by topic with it; Undo.
        ArcSpace* sp = [ArcSpace new];
        sp.spaceID = @"max-selftest";
        sp.title = @"Max SelfTest";
        sp.unpinned = [ArcItem new];
        sp.unpinned.isSection = YES;
        sp.unpinned.children = [NSMutableArray array];
        for (NSArray* d in @[ @[ @"swiftlang/swift", @"https://github.com/swiftlang/swift" ],
                               @[ @"Cookie recipe", @"https://cooking.example/cookies" ],
                               @[ @"Pull requests", @"https://github.com/Donnadieu/notarc/pulls" ],
                               @[ @"Banana bread", @"https://bread.example/banana" ],
                               @[ @"Weather", @"https://weather.example/paris" ] ]) {
          ArcItem* it = [ArcItem new];
          it.itemID = NSUUID.UUID.UUIDString;
          it.title = d[0];
          it.url = d[1];
          it.children = [NSMutableArray array];
          [sp.unpinned.children addObject:it];
        }
        NSArray* before = [sp.unpinned.children copy];
        MaxSetTestModel(@"unavailable:off", nil);
        [w tidyTabsInSpace:sp done:^(NSArray<ArcItem*>* folders, BOOL ai) {
          NSArray* kids = sp.unpinned.children;
          BOOL tidySite = !ai && folders.count == 1 && kids.count == 4 && kids[0] == folders[0] &&
                          [folders[0].title isEqualToString:@"Github"] &&
                          [folders[0].children isEqualToArray:(@[ before[0], before[2] ])];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
            NSUndoManager* undo = [w sidebarUndoManager];
            BOOL named = [undo.undoActionName isEqualToString:@"Tidy Tabs"];
            if (named) [undo undo];
            BOOL tidyUndo = named && [sp.unpinned.children isEqualToArray:before];
            MaxSetTestModel(@"available", ^(NSString* ins, NSString* p, MaxReply reply) {
              reply([p containsString:@"5. Weather (weather.example)"] ? @"1: Code\n2: Cooking\n3: code\n4: Cooking\n5: Weather" : @"bad", nil);
            });
            [w tidyTabsInSpace:sp done:^(NSArray<ArcItem*>* f2, BOOL ai2) {
              BOOL tidyAI = ai2 && f2.count == 2 && [f2[0].title isEqualToString:@"Code"] && [f2[1].title isEqualToString:@"Cooking"] &&
                            [f2[1].children isEqualToArray:(@[ before[1], before[3] ])] && sp.unpinned.children.count == 3 &&
                            sp.unpinned.children.lastObject == before[4];
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5), dispatch_get_main_queue(), ^{
                [[w sidebarUndoManager] undo];
                BOOL tidyAIUndo = [sp.unpinned.children isEqualToArray:before];
                // Tidy tab title. Without the model: the rule-based TidyTabTitle (#18) through the same command
                // (the unread count goes), and the command stays visible. With the model (stub): its name; an
                // unusable reply falls back to the rules; the pin entry point (#18's) asks the model. Undo each time.
                NSString* oldLive = t.liveTitle;
                BOOL oldRenamed = t.renamed;
                NSString* oldTitle = t.title;
                t.renamed = NO;
                t.title = nil;
                t.liveTitle = @"(3) Max Test Page";
                MaxSetTestModel(@"unavailable:off", nil);
                NSMenuItem* tidyItem = nil;
                for (NSMenuItem* top in NSApp.mainMenu.itemArray)
                  for (NSMenuItem* mi in top.submenu.itemArray)
                    if (mi.action == @selector(tidyTabTitle:)) tidyItem = mi;
                BOOL tidyEnabled = tidyItem && [(id<NSMenuItemValidation>)w validateMenuItem:tidyItem] && !tidyItem.hidden;
                [w tidyTitleOfItem:t announce:NO done:^(NSString* title0, BOOL ai0) {
                  NSUndoManager* undo2 = [w sidebarUndoManager];
                  BOOL titleFallback = tidyEnabled && !ai0 && [title0 isEqualToString:@"Max Test Page"] && t.renamed &&
                                       [t.displayTitle isEqualToString:@"Max Test Page"] &&
                                       [undo2.undoActionName isEqualToString:@"Tidy Tab Title"];
                  if (titleFallback) [undo2 undo];
                  titleFallback = titleFallback && !t.renamed && [t.displayTitle isEqualToString:@"(3) Max Test Page"];
                  __block int titleCalls = 0;
                  MaxSetTestModel(@"available", ^(NSString* ins, NSString* p, MaxReply reply) {
                    BOOL ok = [p containsString:@"Tab title: (3) Max Test Page"];
                    int call = titleCalls++;
                    reply(!ok ? @"bad" : (call == 0 ? @"\"Max Test.\"" : call == 1 ? @"" : @"Pinned Name"), nil);
                  });
                  [w tidyTitleOfItem:t announce:NO done:^(NSString* title, BOOL ai3) {
                    BOOL tidyTitle = ai3 && [title isEqualToString:@"Max Test"] && [t.displayTitle isEqualToString:@"Max Test"];
                    BOOL titleUndo = [undo2.undoActionName isEqualToString:@"Tidy Tab Title"];
                    if (titleUndo) [undo2 undo];
                    titleUndo = titleUndo && [t.displayTitle isEqualToString:@"(3) Max Test Page"] && !t.renamed;
                    [w tidyTitleOfItem:t announce:NO done:^(NSString* title2, BOOL ai4) {  // empty reply -> rules
                      BOOL titleAIFallback = !ai4 && [title2 isEqualToString:@"Max Test Page"] &&
                                             [t.displayTitle isEqualToString:@"Max Test Page"];
                      if ([undo2.undoActionName isEqualToString:@"Tidy Tab Title"]) [undo2 undo];
                      titleAIFallback = titleAIFallback && !t.renamed;
                      [w tidyTitleOfItem:t announce:NO];  // what pinning calls (markPinnedURLs)
                      WaitUntil(^{ return [t.displayTitle isEqualToString:@"Pinned Name"]; }, 2, ^{
                        BOOL pinTitle = [t.displayTitle isEqualToString:@"Pinned Name"] && t.renamed;
                        MaxSetTestModel(@"unavailable:selftest", nil);  // the rest of the run never sees the real model
                        t.title = oldTitle;
                        t.renamed = oldRenamed;
                        t.liveTitle = oldLive;
                        [w hideMaxPanels];
                        gMaxTestDone = YES;
                        std::printf("SELFTEST-MAXPAGE previewNoShift=%d previewFallback=%d previewAI=%d previewHidden=%d previewOff=%d "
                                    "fetched=%d notWeb=%d tidySite=%d tidyUndo=%d tidyAI=%d tidyAIUndo=%d titleFallback=%d tidyTitle=%d "
                                    "titleUndo=%d titleAIFallback=%d pinTitle=%d\n", noShift, previewFallback, previewAI, previewHidden,
                                    previewOff, fetchedOK, notWeb, tidySite, tidyUndo, tidyAI, tidyAIUndo, titleFallback, tidyTitle,
                                    titleUndo, titleAIFallback, pinTitle);
                      });
                    }];
                  }];
                }];
              });
            }];
          });
        }];
      });
    });
  });
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
      std::printf("SELFTEST-BASICS tabNeverLoaded=1 live=%d loading=%d url=%s itemURL=%s\n", [w hasLiveBrowser], [w isLoading],
                  [w currentURL].UTF8String, w.shownItem.url.UTF8String ?: "-");
      [self runRemainingSelfTestActions];
    }
    return;
  }
  [w navigateCurrentTab:@"https://www.iana.org/help/example-domains"];
  // Wait for the second page to commit (network speed varies) instead of a fixed 5 s.
  WaitUntil(^{ return (BOOL)([w canGoBack] && ![w isLoading]); }, 20, ^{
    BOOL couldGoBack = [w canGoBack];
    [w goBack:nil];
    [w zoomIn:nil];
    [w zoomIn:nil];
    std::printf("SELFTEST-BASICS canGoBack=%d zoomAfter2In=%.1f\n", couldGoBack, [w currentZoomLevel]);
    [w actualSize:nil];
    WaitUntil(^{ return (BOOL)([[w currentURL] hasPrefix:@"https://example.com"] && ![w isLoading]); }, 15, ^{
      std::printf("SELFTEST-BASICS afterBack=%s zoomReset=%.1f\n", [w currentURL].UTF8String, [w currentZoomLevel]);
      [w findText:@"domain" forward:YES];
      WaitUntil(^{ return (BOOL)(w.lastFindCount > 0); }, 5, ^{
        [w copyCurrentURLAsMarkdown:nil];
        std::printf("SELFTEST-BASICS findDomainCount=%d markdown=%s\n", w.lastFindCount,
                    [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString].UTF8String);
        [self runRemainingSelfTestActions];
      });
    });
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
      {  // #38: switch panes both ways with wraparound; share copies every pane's address
        NSArray<ArcItem*>* panes = [w visiblePanesForTest];
        ArcItem* start = w.shownItem;
        NSUInteger i0 = [panes indexOfObject:start];
        [w focusNextPane:nil];
        BOOL next = panes.count == 3 && w.shownItem == panes[(i0 + 1) % 3];
        [w focusPreviousPane:nil];
        [w focusPreviousPane:nil];
        BOOL prevWrap = panes.count == 3 && w.shownItem == panes[(i0 + 2) % 3];
        [w focusNextPane:nil];
        [w shareSplitView:nil];
        NSString* copied = [[NSPasteboard pasteboardWithName:@"io.github.donnadieu.notarc.selftest"] stringForType:NSPasteboardTypeString];
        NSArray* lines = [copied componentsSeparatedByString:@"\n"];
        BOOL share = lines.count == 3 && [copied containsString:@"https://example.com"] && [copied containsString:@"https://example.org"];
        BOOL general = ![[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:copied];
        NSUInteger before = [w paneFrames].count;
        BOOL single = ![w openSplitFromText:@"https://example.com/one"] && [w paneFrames].count == before;
        std::printf("SELFTEST-SPLITSWITCH next=%d prevWrap=%d share=%d generalUntouched=%d back=%d singleIgnored=%d\n", next,
                    prevWrap, share, general, w.shownItem == start, single);
      }
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
      {  // Incognito: in-memory profile, nothing in History or the Archive, wiped when the last window closes.
        NSUInteger histBefore = [w historyVisits].count, archBefore = [w archivedTabs].count;
        [w openIncognitoWindow:@"https://example.com/incognito-selftest"];
        WaitUntil(^{ return (BOOL)([w incognitoWindowCount] == 1); }, 10, ^{
          BOOL inMemory = ![w incognitoContextIsOnDisk];
          LittleWindowController* iw = nil;
          for (NSWindow* win in NSApp.windows)
            if ([win.windowController isKindOfClass:LittleWindowController.class] && ((LittleWindowController*)win.windowController).incognito)
              iw = win.windowController;
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            BOOL dark = [iw.window.appearance.name isEqualToString:NSAppearanceNameDarkAqua];
            [iw openInMainWindow:nil];  // must not move into a Space
            BOOL stayed = iw.window.isVisible || [w incognitoWindowCount] == 1;
            [iw.window close];
            BOOL wiped = [w incognitoWindowCount] == 0 && !w.incognitoContextIsOnDisk;
            (void)histBefore; (void)archBefore;  // other tests add visits meanwhile; look for this page only
            BOOL noTrace = YES;
            for (ArchivedTab* h in [w historyVisits]) if ([h.url containsString:@"incognito-selftest"]) noTrace = NO;
            for (ArchivedTab* h in [w archivedTabs]) if ([h.url containsString:@"incognito-selftest"]) noTrace = NO;
            std::printf("SELFTEST-INCOGNITO opened=1 inMemory=%d dark=%d noMove=%d wiped=%d noTrace=%d\n", inMemory, dark,
                        stayed, wiped, noTrace);
          });
        });
      }
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
      // Arc profiles: make one, rename it, move the new Space onto it (fresh Favorites, own logins), and back.
      NSString* prof = [w createProfileNamed:@"SelfTest Profile"];
      [w renameProfile:prof to:@"SelfTest Profile Renamed"];
      BOOL named = [[w nameOfProfile:prof] isEqualToString:@"SelfTest Profile Renamed"] && [w.profileDirectories containsObject:prof];
      [w assignSpace:made toProfile:prof];
      BOOL assigned = [made.profileDirectory isEqualToString:prof] && made.favorites.children.count == 0 &&
                      [w.currentSpace.allTabs.lastObject.url hasPrefix:@"https://example.com/in-new-space"];
      [w assignSpace:made toProfile:original.profileDirectory];
      BOOL profBack = [made.profileDirectory isEqualToString:original.profileDirectory] && made.favorites == original.favorites;
      BOOL inMenu = [w.spaceMenuTitles containsObject:@"Profile"];
      std::printf("SELFTEST-PROFILES created=%d assigned=%d back=%d menu=%d\n", named, assigned, profBack, inMenu);
      NSUInteger idx = [w.spaces indexOfObject:made];
      [w moveSpace:made by:-1];
      BOOL moved = [w.spaces indexOfObject:made] == idx - 1;
      [w selectSpaceAtIndex:0];
      BOOL selectFirst = w.currentSpace == w.spaces.firstObject;
      // Arc's bottom bar: one icon per Space, current marked; clicking an icon switches.
      NSArray<NSString*>* icons = w.spaceBarIcons;
      BOOL barCount = icons.count == w.spaces.count;
      BOOL barMarked = [icons[0] hasPrefix:@"*"];
      [w clickSpaceBarIcon:[w.spaces indexOfObject:made]];
      BOOL barClick = w.currentSpace == made && [w.spaceBarIcons[[w.spaces indexOfObject:made]] hasPrefix:@"*"];
      // Arc's Space title row: shows the current Space's name (renamed above) and has the Space menu.
      BOOL header = [w.spaceHeaderText hasSuffix:@"SelfTest Renamed"];
      NSArray* menu = w.spaceMenuTitles;
      BOOL menuOK = [menu containsObject:@"Rename Space..."] && [menu containsObject:@"Edit Theme Color..."] &&
                    [menu containsObject:@"Delete Space..."];
      std::printf("SELFTEST-SPACEBAR icons=%d current=%d click=%d header=%d menu=%d\n", barCount, barMarked, barClick, header,
                  menuOK);
      // Arc motion: switching to a later Space slides in from the right, an earlier one from the left; the page pops.
      BOOL reduce = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
      NSUInteger madeIdx = [w.spaces indexOfObject:made];
      NSUInteger popsBefore = w.cardPopCount;
      [w selectSpaceAtIndex:0];
      NSString* back = w.lastSpaceSlide;
      [w selectSpaceAtIndex:madeIdx];
      NSString* fwd = w.lastSpaceSlide;
      BOOL slide = reduce ? [back isEqualToString:@"none"] : ([back isEqualToString:@"left"] && [fwd isEqualToString:@"right"]);
      BOOL pop = reduce || w.cardPopCount > popsBefore;
      std::printf("SELFTEST-MOTION slide=%d pop=%d reduceMotion=%d\n", slide, pop, reduce);
      // Arc per-Space appearance: Light/Dark switch the sidebar rows to Arc's light/dark values; Automatic follows macOS.
      {
        ArcSpace* sp = w.currentSpace;
        ArcItem* sel = w.shownItem;
        [w setColorScheme:@"light" forSpace:sp];
        [w.window displayIfNeeded];
        BOOL light = !w.sidebarIsDark && [[w sidebarRowStyleForItem:sel] containsString:@"alpha=0.85"];
        // Arc's card edge (#122): hairline border in both modes, a soft shadow only in light mode.
        NSString* edgeLight = w.pageCardEdgeStyle;
        if (![edgeLight hasSuffix:@"0.10"]) std::printf("SELFTEST-FRAME-DEBUG %s\n", [w performSelector:@selector(pageCardEdgeDebug)] ? [(NSString*)[w performSelector:@selector(pageCardEdgeDebug)] UTF8String] : "");
        [w setColorScheme:@"dark" forSpace:sp];
        [w.window displayIfNeeded];
        BOOL dark = w.sidebarIsDark && [[w sidebarRowStyleForItem:sel] containsString:@"alpha=0.20"];
        NSString* edgeDark = w.pageCardEdgeStyle;
        BOOL edge = [edgeLight isEqualToString:@"border=0.05 shadow=0.10"] && [edgeDark isEqualToString:@"border=0.05 shadow=0.00"];
        BOOL frame = w.pageCardRadius == 8 && NSMaxX(w.pageCardFrame) == NSMaxX(w.window.contentView.bounds) - 9 &&
                     NSMinY(w.pageCardFrame) == 9;
        std::printf("SELFTEST-FRAME edge=%d frame=%d light=[%s] dark=[%s]\n", edge, frame, edgeLight.UTF8String,
                    edgeDark.UTF8String);
        [w setColorScheme:nil forSpace:sp];
        BOOL autoOK = w.window.appearance == nil && sp.colorScheme == nil;
        BOOL menu = [w.spaceMenuTitles containsObject:@"Appearance"];
        if (!(light && dark)) std::printf("SELFTEST-APPEARANCE-DEBUG sel=%s style=[%s]\n", sel.url.UTF8String ?: "nil",
                                           [w sidebarRowStyleForItem:sel].UTF8String);
        std::printf("SELFTEST-APPEARANCE light=%d dark=%d auto=%d menu=%d\n", light, dark, autoOK, menu);
      }
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
    // Updater: version ordering, GitHub release parsing, and a real download + checksum + extract of
    // the published release (nothing is installed).
    // Downloads: a real small file into a temp folder, twice, so the second gets a numbered name.
    // Pinned tabs keep their saved URL: navigate away, close (stays pinned, back to saved URL), reset, replace.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 42 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/pin-home"];
      ArcItem* t = w.shownItem;
      [w togglePin:nil];
      BOOL pinned = [w isPinnedItem:t] && [t.pinnedURL isEqualToString:@"https://example.com/pin-home"];
      [w navigateCurrentTab:@"https://example.org/elsewhere"];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BOOL moved = [t.url hasPrefix:@"https://example.org/elsewhere"] && [t.pinnedURL isEqualToString:@"https://example.com/pin-home"];
        [w showItem:t];
        [w closeCurrentTab];
        BOOL keptAndReset = [w isPinnedItem:t] && t.browserId == 0 && [t.url isEqualToString:@"https://example.com/pin-home"];
        [w showItem:t];
        [w navigateCurrentTab:@"https://example.org/new-home"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [w replacePinnedURLWithCurrent:t];
          BOOL replaced = [t.pinnedURL hasPrefix:@"https://example.org/new-home"];
          [w navigateCurrentTab:@"https://example.com/third"];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            NSUInteger reset = [w resetPinnedTabsInSpace];
            BOOL backHome = [t.url hasPrefix:@"https://example.org/new-home"];
            [w togglePin:nil];
            BOOL unpinnedCleared = ![w isPinnedItem:t] && t.pinnedURL == nil;
            std::printf("SELFTEST-PINNED pinned=%d savedKept=%d closeKeptReset=%d replaced=%d resetCount=%lu backHome=%d unpinCleared=%d\n",
                        pinned, moved, keptAndReset, replaced, (unsigned long)reset, backHome, unpinnedCleared);
          });
        });
      });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 44 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      BOOL before = w.sidebarHidden;
      // Arc layout: 273 pt sidebar, page card inset 10 top / 9 right / 9 bottom, radius 8; full window in focus mode.
      NSRect wb = w.window.contentView.bounds, cf = w.pageCardFrame;
      BOOL cardOK = !before && !w.toolbarShown && cf.origin.x == 273 && cf.origin.y == 9 &&
                    NSMaxX(wb) - NSMaxX(cf) == 9 && NSMaxY(wb) - NSMaxY(cf) == 10 && w.pageCardRadius == 8;
      // Arc sidebar top: 36 pt address pill, 8 pt from the left, 46 pt below the window top, showing the site.
      NSRect pf = w.sidebarAddressFrame;
      NSString* host = [NSURL URLWithString:w.currentURL].host ?: @"";
      if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
      BOOL pillOK = pf.origin.x == 8 && pf.size.height == 36 && NSMaxY(wb) - NSMaxY(pf) == 46 && host.length &&
                    [w.sidebarAddressText isEqualToString:host];
      // Arc sidebar rows: 36 pt pills, radius 8; selected 20% white (dark) / 85% white (light), hover lighter.
      ArcItem* shownTab = w.shownItem;
      ArcItem* otherTab = nil;
      // Favorites are grid tiles, not rows: pick a tab that has a sidebar row.
      for (ArcItem* t in w.currentSpace.allTabs)
        if (t != shownTab && t.url.length && !t.isSplit && [w sidebarRowStyleForItem:t].length) { otherTab = t; break; }
      NSString* selStyle = shownTab ? [w sidebarRowStyleForItem:shownTab] : @"";
      [w hoverSidebarItem:otherTab];
      NSString* hovStyle = otherTab ? [w sidebarRowStyleForItem:otherTab] : @"";
      [w hoverSidebarItem:nil];
      NSString* offStyle = otherTab ? [w sidebarRowStyleForItem:otherTab] : @"";
      BOOL rowsOK = [selStyle hasPrefix:@"h=36 r=8 sel=1"] && [hovStyle containsString:@"hover=1"] &&
                    [offStyle hasSuffix:@"alpha=0.00"];
      // Arc sidebar: Favorites as tiles 90 pt below the top (8 pt in); Space title right under them.
      NSRect gf = w.favoritesGridFrame, hf = w.spaceHeaderFrame;
      BOOL gridOK = w.currentSpace.favorites.children.count == 0 ||
                    (gf.origin.x == 8 && NSMaxY(wb) - NSMaxY(gf) == 90 && w.favoriteTileTitles.count > 0 && NSMaxY(hf) < NSMinY(gf));
      {  // Arc's unread badge on Favorites: count from the page title, per-tab "Show Unread Badge".
        BOOL parse = UnreadCountFromTitle(@"Inbox (12) - me@example.com - Gmail") == 12 &&
                     UnreadCountFromTitle(@"(3) Slack | general") == 3 && UnreadCountFromTitle(@"Mail - 5 unread") == 5 &&
                     UnreadCountFromTitle(@"[7] Feed") == 7 && UnreadCountFromTitle(@"GitHub") == 0 &&
                     UnreadCountFromTitle(@"Arc 1.169 release notes") == 0;
        ArcItem* fav = w.currentSpace.favorites.children.firstObject;
        BOOL toggle = YES;
        if (fav.url.length) {
          NSMenuItem* mi = [[w sidebarMenuForItem:fav] itemWithTitle:@"Show Unread Badge"];
          BOOL before = mi && mi.state == NSControlStateValueOn;
          [NSApp sendAction:mi.action to:mi.target from:mi];
          BOOL hidden = fav.hideUnreadBadge && [[w sidebarMenuForItem:fav] itemWithTitle:@"Show Unread Badge"].state == NSControlStateValueOff;
          [NSApp sendAction:mi.action to:mi.target from:mi];
          toggle = before && hidden && !fav.hideUnreadBadge;
        }
        std::printf("SELFTEST-UNREAD parse=%d toggle=%d\n", parse, toggle);
        BOOL swipe = SwipeDirectionForScroll(12, 1, YES, YES) == -1 && SwipeDirectionForScroll(-12, 1, YES, YES) == 1 &&
                     SwipeDirectionForScroll(3, 10, YES, YES) == 0 && SwipeDirectionForScroll(12, 0, NO, YES) == 0 &&
                     SwipeDirectionForScroll(12, 0, YES, NO) == 0;
        std::printf("SELFTEST-SWIPE direction=%d installed=%d\n", swipe, w.swipeNavigationInstalled);
        {  // #27: swiping over the sidebar walks the Spaces, with no wraparound at either end.
          ArcSpace* start = w.currentSpace;
          NSUInteger n = w.spaces.count;
          [w selectSpaceAtIndex:0];
          BOOL noWrap = ![w swipeSpacesBy:-1] && w.currentSpace == w.spaces.firstObject;
          BOOL next = n < 2 || ([w swipeSpacesBy:1] && w.currentSpace == w.spaces[1]);
          BOOL back = n < 2 || ([w swipeSpacesBy:-1] && w.currentSpace == w.spaces[0]);
          [w selectSpaceAtIndex:n - 1];
          BOOL endStop = ![w swipeSpacesBy:1];
          [w switchToSpace:start];
          std::printf("SELFTEST-SPACESWIPE next=%d back=%d noWrap=%d endStop=%d spaces=%d\n", next, back, noWrap, endStop,
                      n >= 2);
        }
        {  // Import bookmarks: Chromium JSON and a Netscape HTML export, into a Pinned folder.
          NSString* tmp = NSTemporaryDirectory();
          NSString* js = [tmp stringByAppendingPathComponent:@"selftest-Bookmarks"];
          [@"{\"roots\":{\"bookmark_bar\":{\"type\":\"folder\",\"name\":\"Bar\",\"children\":["
            "{\"type\":\"url\",\"name\":\"Example\",\"url\":\"https://example.com/\"},"
            "{\"type\":\"url\",\"name\":\"JS\",\"url\":\"javascript:void(0)\"},"
            "{\"type\":\"folder\",\"name\":\"Work\",\"children\":[{\"type\":\"url\",\"name\":\"Docs\",\"url\":\"https://docs.example.com/\"}]}]},"
            "\"other\":{\"type\":\"folder\",\"name\":\"Other bookmarks\",\"children\":[{\"type\":\"url\",\"name\":\"O\",\"url\":\"https://other.example/\"}]},"
            "\"synced\":{\"type\":\"folder\",\"name\":\"Mobile\",\"children\":[]}}}"
              writeToFile:js atomically:YES encoding:NSUTF8StringEncoding error:nil];
          NSUInteger cn = 0, hn = 0;
          ArcItem* cf = BookmarksFromChromiumFile(js, @"SelfTest Chrome", &cn);
          BOOL chrome = cn == 3 && cf.children.count == 3 && [cf.children[1].title isEqualToString:@"Work"] &&
                        cf.children[1].isFolder && [cf.children[2].title isEqualToString:@"Other bookmarks"];
          NSString* ht = [tmp stringByAppendingPathComponent:@"selftest-bookmarks.html"];
          [@"<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<TITLE>Bookmarks</TITLE><H1>Bookmarks</H1>\n<DL><p>\n"
            "<DT><A HREF=\"https://a.example/?x=1&amp;y=2\" ADD_DATE=\"1\">A &amp; B</A>\n"
            "<DT><H3>Folder One</H3>\n<DL><p>\n<DT><A HREF=\"https://b.example/\">B</A>\n"
            "<DT><H3>Empty</H3>\n<DL><p>\n</DL><p>\n</DL><p>\n</DL><p>\n"
              writeToFile:ht atomically:YES encoding:NSUTF8StringEncoding error:nil];
          ArcItem* hf = BookmarksFromHTMLFile(ht, @"SelfTest HTML", &hn);
          BOOL html = hn == 2 && hf.children.count == 2 && [hf.children[0].url isEqualToString:@"https://a.example/?x=1&y=2"] &&
                      [hf.children[0].title isEqualToString:@"A & B"] && [hf.children[1].title isEqualToString:@"Folder One"] &&
                      hf.children[1].children.count == 1;
          NSUInteger pinnedBefore = w.currentSpace.pinned.children.count;
          BOOL added = [w addImportedBookmarks:cf] && w.currentSpace.pinned.children.count == pinnedBefore + 1;
          [w.currentSpace.pinned.children removeObject:cf];
          std::printf("SELFTEST-BOOKMARKS chrome=%d html=%d pinned=%d\n", chrome, html, added);
          {  // Keyboard shortcut overrides (settings are memory-only in tests).
            NSMenu* mm = NSApp.mainMenu;
            NSString* p = @"File/New Easel";
            NSMenuItem* easel = MenuItemAtPath(mm, p);
            SetShortcut(mm, p, @"e", NSEventModifierFlagCommand | NSEventModifierFlagOption);
            BOOL set = [easel.keyEquivalent isEqualToString:@"e"] &&
                       (easel.keyEquivalentModifierMask & NSEventModifierFlagOption) &&
                       [SettingObject(@"shortcutOverrides")[p][@"key"] isEqualToString:@"e"];
            // Taking New Tab's Cmd+T: New Tab loses it, Reset gives it back.
            NSMenuItem* newTab = MenuItemAtPath(mm, @"File/New Tab");
            NSString* cleared = SetShortcut(mm, p, @"t", NSEventModifierFlagCommand);
            BOOL conflict = [cleared isEqualToString:@"File/New Tab"] && newTab.keyEquivalent.length == 0;
            SetShortcut(mm, @"File/New Tab", nil, 0);
            SetShortcut(mm, p, nil, 0);
            BOOL reset = [newTab.keyEquivalent isEqualToString:@"t"] && easel.keyEquivalent.length == 0 &&
                         !SettingObject(@"shortcutOverrides")[p];
            BOOL display = [ShortcutDisplay(@"n", NSEventModifierFlagCommand | NSEventModifierFlagShift) isEqualToString:@"⇧⌘N"];
            BOOL window = [ShortcutsWindowController shared].window != nil && ![ShortcutsWindowController shared].window.isVisible;
            {  // AppleScript (#76): dictionary loaded, KVC wrappers, and a real script run in this process only.
              NSScriptSuiteRegistry* reg = NSScriptSuiteRegistry.sharedScriptSuiteRegistry;
              BOOL dict = [reg classDescriptionWithAppleEventCode:'NAtb'] != nil && [reg classDescriptionWithAppleEventCode:'NAsp'] != nil;
              NSArray* tabs = [w.window valueForKey:@"scriptTabs"];
              NSArray* spaces = [w.window valueForKey:@"scriptSpaces"];
              id active = [w.window valueForKey:@"scriptActiveTab"];
              BOOL kvc = tabs.count > 0 && spaces.count == w.spaces.count &&
                         [[active valueForKey:@"uniqueID"] isEqualToString:w.shownItem.itemID];
              NSDictionary* err = nil;
              NSAppleEventDescriptor* r = [[[NSAppleScript alloc] initWithSource:
                  @"tell current application\nset n to 0\nrepeat with w in windows\nset c to count of spaces of w\n"
                  @"if c > n then set n to c\nend repeat\nreturn n as text\nend tell"] executeAndReturnError:&err];
              BOOL script = r && r.stringValue.integerValue == (NSInteger)w.spaces.count;
              if (!script) std::printf("SELFTEST-APPLESCRIPT-DEBUG %s %s\n", r.stringValue.UTF8String ?: "-", err.description.UTF8String ?: "-");
              std::printf("SELFTEST-APPLESCRIPT dictionary=%d kvc=%d script=%d\n", dict, kvc, script);
            }
            {  // Search suggestions (#31): parser on engine-shaped JSON, rows from a stub (no network), off switches.
              NSArray* g = ParseSearchSuggestions([@"[\"arc\",[\"arc browser\",\"arc raiders\",\"arc browser\"]]" dataUsingEncoding:NSUTF8StringEncoding]);
              NSArray* k = ParseSearchSuggestions([@"[{\"phrase\":\"kagi one\"},{\"phrase\":\"kagi two\"}]" dataUsingEncoding:NSUTF8StringEncoding]);
              BOOL parse = [g isEqualToArray:(@[ @"arc browser", @"arc raiders" ])] && [k isEqualToArray:(@[ @"kagi one", @"kagi two" ])] &&
                           ParseSearchSuggestions([@"oops" dataUsingEncoding:NSUTF8StringEncoding]).count == 0;
              NSUserDefaults* ud = NSUserDefaults.standardUserDefaults;
              [ud setVolatileDomain:@{kSettingSearchEngine : @"duckduckgo"} forName:NSArgumentDomain];
              BOOL engineURL = [SuggestURLForQuery(@"x") hasPrefix:@"https://duckduckgo.com/ac/"];
              [ud setVolatileDomain:@{kSettingSearchEngine : @"kagi"} forName:NSArgumentDomain];
              engineURL = engineURL && [SuggestURLForQuery(@"x") hasPrefix:@"https://kagi.com/api/autosuggest"];
              [ud setVolatileDomain:@{} forName:NSArgumentDomain];
              w.searchSuggestionStub = @{@"zebra crossing" : @[ @"zebra crossing rules", @"zebra crossing uk", @"zebra crossing history", @"zebra crossing 4" ]};
              [w commandSuggestionsAfterFetch:@"zebra crossing" done:^(NSArray<NSDictionary*>* items) {
                NSMutableArray* found = [NSMutableArray array];
                for (NSDictionary* d in items) if ([d[@"kind"] isEqualToString:@"search"]) [found addObject:d[@"title"]];
                BOOL rows = found.count == 3 && [found.firstObject isEqualToString:@"zebra crossing rules"] &&
                            [items.firstObject[@"kind"] isEqualToString:@"go"];
                SettingSetObject(kSettingSearchSuggestions, @NO);
                [w commandSuggestionsAfterFetch:@"zebra crossing x" done:^(NSArray<NSDictionary*>* off) {
                  BOOL offOK = YES;
                  for (NSDictionary* d in off) if ([d[@"kind"] isEqualToString:@"search"]) offOK = NO;
                  SettingSetObject(kSettingSearchSuggestions, nil);
                  [w commandSuggestionsAfterFetch:@"github.com" done:^(NSArray<NSDictionary*>* url) {
                    BOOL urlOK = YES;
                    for (NSDictionary* d in url) if ([d[@"kind"] isEqualToString:@"search"]) urlOK = NO;
                    w.searchSuggestionStub = nil;
                    {  // #52 translate page: URL round trip only (no network in tests)
                      NSString* tr = TranslateURLFor(@"https://example.com/a?b=1", @"fr");
                      NSURLComponents* tc = [NSURLComponents componentsWithString:tr];
                      BOOL build = [tc.host isEqualToString:@"translate.google.com"] && [tr containsString:@"tl=fr"];
                      BOOL back = [OriginalURLForTranslated(tr) isEqualToString:@"https://example.com/a?b=1"];
                      BOOL goog = [OriginalURLForTranslated(@"https://www-my--site-com.translate.goog/p?q=2&_x_tr_sl=auto&_x_tr_tl=en")
                          isEqualToString:@"https://www.my-site.com/p?q=2"];
                      BOOL skip = !TranslateURLFor(@"notarc://easel/x", @"en") && !TranslateURLFor(tr, @"en") &&
                                  !OriginalURLForTranslated(@"https://example.com/");
                      std::printf("SELFTEST-TRANSLATE build=%d back=%d goog=%d skip=%d lang=%d\n", build, back, goog, skip,
                                  PreferredTranslateLanguage().length >= 2);
                      // Translate offer: other languages only, by primary subtag; once per site per launch.
                      BOOL rule = [TranslateOfferFor(@"fr", @[ @"en-US" ]) isEqualToString:@"fr"] &&
                                  !TranslateOfferFor(@"en-GB", @[ @"en-US", @"fr" ]) && !TranslateOfferFor(@"", @[ @"en" ]) &&
                                  !TranslateOfferFor(@"und", @[ @"en" ]) && [TranslateOfferFor(@"pt_BR", @[ @"de" ]) isEqualToString:@"pt"];
                      NSString* mine = PreferredTranslateLanguage();
                      NSString* foreign = [mine hasPrefix:@"ja"] ? @"fr" : @"ja";
                      ArcItem* shown = w.shownItem;
                      [w browser:shown.browserId pageLanguage:foreign];
                      BOOL offered = shown.browserId && [w.lastTranslateOffer isEqualToString:foreign];
                      [w browser:shown.browserId pageLanguage:@"ko"];
                      BOOL once = [w.lastTranslateOffer isEqualToString:foreign];
                      std::printf("SELFTEST-TRANSLATEOFFER rule=%d offered=%d oncePerSite=%d\n", rule, offered, once);
                    }
                    {  // #53 ad & tracker blocking: request filter logic and the per-site exception (memory-only settings)
                      namespace cb = content_blocker;
                      BOOL offByDefault = !SettingBool(kSettingBlockAds) && !cb::Enabled() &&
                                          !cb::ShouldBlock("https://securepubads.doubleclick.net/x.js", "https://news.example/", false);
                      SettingSetBool(kSettingBlockAds, YES);
                      ApplyContentBlockerSettings();
                      BOOL blocks = cb::ShouldBlock("https://securepubads.g.doubleclick.net/tag/js/gpt.js", "https://news.example/a", false) &&
                                    cb::ShouldBlock("https://www.google-analytics.com/g/collect", "https://shop.example/", false);
                      BOOL mainFrame = !cb::ShouldBlock("https://doubleclick.net/", "https://doubleclick.net/", true);
                      BOOL firstParty = !cb::ShouldBlock("https://ads.taboola.com/x", "https://www.taboola.com/", false);
                      BOOL clean = !cb::ShouldBlock("https://cdn.example.net/app.js", "https://news.example/", false) &&
                                   !cb::ShouldBlock("https://notdoubleclick.net/x", "https://news.example/", false);
                      [w setAdBlocking:NO forHost:@"www.news.example"];
                      BOOL exception = ![w adBlockingOnForHost:@"news.example"] &&
                                       !cb::ShouldBlock("https://doubleclick.net/x", "https://sub.news.example/", false) &&
                                       cb::ShouldBlock("https://doubleclick.net/x", "https://other.example/", false);
                      [w setAdBlocking:YES forHost:@"news.example"];
                      BOOL restored = [w adBlockingOnForHost:@"news.example"] &&
                                      cb::ShouldBlock("https://doubleclick.net/x", "https://news.example/", false);
                      SettingSetBool(kSettingBlockAds, NO);
                      ApplyContentBlockerSettings();
                      BOOL off = !cb::ShouldBlock("https://doubleclick.net/x", "https://news.example/", false);
                      {  // #74 sound effects and reorder haptics: settings gate them; tests count instead of playing
                        NSInteger s0 = SoundEffectsPlayedForTest(), h0 = ReorderHapticsForTest();
                        BOOL onByDefault = SettingBool(kSettingSoundEffects) && SettingBool(kSettingReorderHaptics);
                        BOOL plays = PlaySoundEffect(NotArcSoundCapture) && SoundEffectsPlayedForTest() == s0 + 1;
                        ReorderHaptic();
                        BOOL tick = ReorderHapticsForTest() == h0 + 1;
                        SettingSetBool(kSettingSoundEffects, NO);
                        SettingSetBool(kSettingReorderHaptics, NO);
                        BOOL silent = !PlaySoundEffect(NotArcSoundCapture) && SoundEffectsPlayedForTest() == s0 + 1;
                        ReorderHaptic();
                        BOOL noTick = ReorderHapticsForTest() == h0 + 1;
                        SettingSetBool(kSettingSoundEffects, YES);
                        SettingSetBool(kSettingReorderHaptics, YES);
                        std::printf("SELFTEST-SOUNDS onByDefault=%d plays=%d tick=%d silent=%d noTick=%d\n", onByDefault, plays,
                                    tick, silent, noTick);
                      }
                      std::printf("SELFTEST-ADBLOCK offByDefault=%d blocks=%d mainFrame=%d firstParty=%d clean=%d exception=%d "
                                  "restored=%d off=%d list=%d\n", offByDefault, blocks, mainFrame, firstParty, clean, exception,
                                  restored, off, (int)cb::ListSize() > 100);
                    }
                    std::printf("SELFTEST-SEARCHSUGGEST parse=%d engine=%d rows=%d settingOff=%d noURL=%d\n", parse, engineURL, rows,
                                offOK, urlOK);
                  }];
                }];
              }];
            }
            {  // Default browser (#69): read-only checks; never changes the system setting or shows macOS's prompt.
              NSURL* app = DefaultBrowserAppURL();
              BOOL detect = app != nil && NotArcIsDefaultBrowser() ==
                  [[NSBundle bundleWithURL:app].bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier];
              BOOL row = [[SettingsWindowController shared] defaultBrowserRowConsistent];
              NSArray* types = NSBundle.mainBundle.infoDictionary[@"CFBundleURLTypes"];
              BOOL schemes = [[types.firstObject[@"CFBundleURLSchemes"] componentsJoinedByString:@","] isEqualToString:@"http,https"];
              std::printf("SELFTEST-DEFAULTBROWSER detect=%d row=%d schemes=%d\n", detect, row, schemes);
            }
            std::printf("SELFTEST-SHORTCUTEDIT set=%d conflict=%d reset=%d display=%d window=%d\n", set, conflict, reset, display, window);
          }
          [[NSFileManager defaultManager] removeItemAtPath:js error:nil];
          [[NSFileManager defaultManager] removeItemAtPath:ht error:nil];
        }
        {  // Air Traffic Control: Arc's rule format, every match type, source-app rules.
          NSString* f = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-linkrouting.json"];
          [@"{\"version\":1,\"defaultDestination\":{\"littleArc\":{\"_0\":{\"mostRecent\":{}}}},\"rules\":["
            "{\"destination\":{\"space\":{\"_0\":{\"mostRecent\":{}}}},\"id\":\"A\",\"sourceComponents\":[{\"componentType\":"
            "{\"urlMatch\":{\"_0\":{\"contains\":{}},\"_1\":\"meet.google.com\"}},\"id\":\"B\"}]},"
            "{\"destination\":{\"space\":{\"_0\":{\"specific\":{\"_0\":\"S2\"}}}},\"id\":\"C\",\"sourceComponents\":[{\"componentType\":"
            "{\"application\":{\"_0\":\"com.tinyspeck.slackmacgap\"}},\"id\":\"D\"}]}]}"
              writeToFile:f atomically:YES encoding:NSUTF8StringEncoding error:nil];
          LinkRouting* lr = [LinkRouting fromArcFile:f];
          LinkRule* meet = [lr ruleForURL:@"https://meet.google.com/abc-defg-hij" sourceApp:@"com.apple.mail"];
          LinkRule* slack = [lr ruleForURL:@"https://example.com/" sourceApp:@"com.tinyspeck.slackmacgap"];
          BOOL arc = lr.rules.count == 2 && [lr.defaultDestination isEqualToString:@"little"] && [meet.destination isEqualToString:@"space"] &&
                     !meet.spaceID && [slack.spaceID isEqualToString:@"S2"] && ![lr ruleForURL:@"https://example.com/" sourceApp:@"com.apple.mail"];
          LinkRule* r = [LinkRule new];
          BOOL types = YES;
          r.matchType = @"domain"; r.pattern = @"github.com";
          types = types && LinkRuleMatchesURL(r, @"https://gist.github.com/x") && !LinkRuleMatchesURL(r, @"https://notgithub.com/");
          r.matchType = @"startsWith"; r.pattern = @"docs.google.com/spreadsheets";
          types = types && LinkRuleMatchesURL(r, @"https://docs.google.com/spreadsheets/d/1") && !LinkRuleMatchesURL(r, @"https://docs.google.com/document/d/1");
          r.matchType = @"exact"; r.pattern = @"example.com";
          types = types && LinkRuleMatchesURL(r, @"https://www.example.com/") && !LinkRuleMatchesURL(r, @"https://example.com/a");
          r.matchType = @"regex"; r.pattern = @"/pull/\\d+$";
          types = types && LinkRuleMatchesURL(r, @"https://github.com/a/b/pull/12") && !LinkRuleMatchesURL(r, @"https://github.com/a/b/issues/12");
          NSString* saved = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-linkrouting-roundtrip.json"];
          [lr saveTo:saved];
          LinkRouting* back = [LinkRouting loadFrom:saved];
          BOOL roundTrip = back.rules.count == 2 && [[back ruleForURL:@"https://x.y/" sourceApp:@"com.tinyspeck.slackmacgap"].spaceID isEqualToString:@"S2"];
          // Route a link through the window: a rule for "routed.example" to the current Space opens a Today tab there.
          LinkRule* mine = [LinkRule new];
          mine.matchType = @"contains"; mine.pattern = @"routed.example"; mine.destination = @"space";
          LinkRouting* live = [LinkRouting new];
          live.rules = @[ mine ];
          live.defaultDestination = @"little";
          [live saveTo:w.linkRoutingPath];
          NSString* went = [w routeExternalLink:@"https://routed.example/selftest" sourceApp:nil];
          BOOL routed = [went isEqualToString:w.currentSpace.title] &&
                        [w.currentSpace.unpinned.children.firstObject.url hasPrefix:@"https://routed.example/"];
          {  // Air Traffic Control editor: add / edit / default / remove, each saved to disk at once.
            LinkRoutingEditor* ed = (LinkRoutingEditor*)[w airTrafficControlEditor];
            NSUInteger n0 = ed.routing.rules.count;
            [ed addRule];
            [ed setRuleAt:n0 match:@"domain" pattern:@"figma.com" app:@"" to:@"little" space:nil];
            [ed setDefaultTo:@"space" space:w.currentSpace.spaceID];
            LinkRouting* disk = [LinkRouting loadFrom:w.linkRoutingPath];
            LinkRule* fr = [disk ruleForURL:@"https://www.figma.com/file/1" sourceApp:nil];
            BOOL added = disk.rules.count == n0 + 1 && [fr.destination isEqualToString:@"little"] && !fr.sourceApp;
            BOOL def = [disk.defaultDestination isEqualToString:@"space"] && [disk.defaultSpaceID isEqualToString:w.currentSpace.spaceID];
            [ed removeRuleAt:n0];
            BOOL removed = [LinkRouting loadFrom:w.linkRoutingPath].rules.count == n0;
            BOOL hidden = !ed.window.isVisible;
            std::printf("SELFTEST-ATCEDITOR added=%d default=%d removed=%d hidden=%d\n", added, def, removed, hidden);
          }
          std::printf("SELFTEST-LINKROUTING arcFormat=%d matchTypes=%d roundTrip=%d routed=%d\n", arc, types, roundTrip, routed);
          [[NSFileManager defaultManager] removeItemAtPath:f error:nil];
          [[NSFileManager defaultManager] removeItemAtPath:saved error:nil];
        }
      }
      std::printf("SELFTEST-SIDEBARLOOK grid=%d defaultTheme=%d\n", gridOK,
                  w.currentSpace.themeColors.count || !w.sidebarIsDark || w.defaultThemeShown);
      if (!rowsOK) std::printf("SELFTEST-ROWS-DEBUG sel=[%s] hov=[%s] off=[%s]\n", selStyle.UTF8String, hovStyle.UTF8String, offStyle.UTF8String);
      [w toggleFocusMode:nil];
      NSRect ff = w.pageCardFrame;
      BOOL fullInFocus = NSEqualRects(ff, wb) && w.pageCardRadius == 0;
      BOOL inFocus = w.focusMode && w.sidebarHidden && [w.window standardWindowButton:NSWindowCloseButton].hidden;
      [w toggleFocusMode:nil];
      BOOL out = !w.focusMode && w.sidebarHidden == before && ![w.window standardWindowButton:NSWindowCloseButton].hidden;
      BOOL fsCapable = (w.window.collectionBehavior & NSWindowCollectionBehaviorFullScreenNone) == 0;
      BOOL cardBack = NSEqualRects(w.pageCardFrame, cf);
      std::printf("SELFTEST-FOCUS focus=%d restored=%d fullScreenAllowed=%d card=%d fullInFocus=%d cardBack=%d addressPill=%d rows=%d\n",
                  inFocus, out, fsCapable, cardOK, fullInFocus, cardBack, pillOK, rowsOK);
    });
    // Clear Cookies and Refresh (this site only), then Clear Browsing Data (last hour).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 46 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/clear-test"];
      ArcItem* clearTab = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:clearTab];  // other timed checks may have switched tabs meanwhile
        [w selfTestSetCookie:@"https://example.com/" name:@"nt_site" done:^{
          [w selfTestSetCookie:@"https://example.org/" name:@"nt_other" done:^{
            [w selfTestCountCookiesNamed:@"nt_site" done:^(NSUInteger siteBefore) {
              [w showItem:clearTab];
              [w clearCookiesAndRefreshWithDone:^(NSUInteger removed) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                  [w selfTestCountCookiesNamed:@"nt_site" done:^(NSUInteger siteAfter) {
                    [w selfTestCountCookiesNamed:@"nt_other" done:^(NSUInteger otherKept) {
                      NSDate* since = [NSDate dateWithTimeIntervalSinceNow:-3600];
                      NSUInteger recentVisits = 0;
                      for (ArchivedTab* v in w.historyVisits) recentVisits += [v.archivedAt compare:since] != NSOrderedAscending;
                      [w clearBrowsingDataSince:since history:YES cookies:YES cache:YES
                                           done:^(NSUInteger histRemoved, NSUInteger cookiesRemoved) {
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                          [w selfTestCountCookiesNamed:@"nt_other" done:^(NSUInteger otherAfter) {
                            NSUInteger recentLeft = 0;
                            for (ArchivedTab* v in w.historyVisits) recentLeft += [v.archivedAt compare:since] != NSOrderedAscending;
                            std::printf("SELFTEST-CLEARDATA siteBefore=%lu siteRemoved=%lu siteAfter=%lu otherKept=%lu "
                                        "recentVisits=%lu histRemoved=%lu recentLeft=%lu cookiesRemoved=%lu otherAfter=%lu\n",
                                        (unsigned long)siteBefore, (unsigned long)removed, (unsigned long)siteAfter,
                                        (unsigned long)otherKept, (unsigned long)recentVisits, (unsigned long)histRemoved,
                                        (unsigned long)recentLeft, (unsigned long)cookiesRemoved, (unsigned long)otherAfter);
                          }];
                        });
                      }];
                    }];
                  }];
                });
              }];
            }];
          }];
        }];
      });
    });
    // Clean links and folder duplication.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 48 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      BOOL clean1 = [CleanLinkURL(@"https://a.example/p?id=7&utm_source=x&fbclid=y&UTM_Medium=z#top")
          isEqualToString:@"https://a.example/p?id=7#top"];
      BOOL clean2 = [CleanLinkURL(@"https://a.example/p?gclid=1") isEqualToString:@"https://a.example/p"];
      BOOL clean3 = [CleanLinkURL(@"https://a.example/p?q=a%20b&page=2") isEqualToString:@"https://a.example/p?q=a%20b&page=2"];
      ArcItem* folder = [w createFolderNamed:@"SelfTest DupFolder"];
      [w openInNewTab:@"https://example.com/dup-a"];
      ArcItem* a = w.shownItem;
      [w moveItem:a toParent:folder index:0];
      ArcItem* copy = [w duplicateItem:folder];
      BOOL dup = copy && copy != folder && [copy.title isEqualToString:@"SelfTest DupFolder copy"] &&
                 copy.children.count == folder.children.count && copy.children.count == 1 &&
                 copy.children[0] != a && [((ArcItem*)copy.children[0]).url hasPrefix:@"https://example.com/dup-a"] &&
                 ![copy.itemID isEqualToString:folder.itemID];
      std::printf("SELFTEST-CLEANDUP clean=%d stripAll=%d keepOthers=%d folderDup=%d\n", clean1, clean2, clean3, dup);
    });
    // Undo Close Tab: comes back at the same place, leaves the Archive; Redo closes it again.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/undo-a"];
      ArcItem* a = w.shownItem;
      [w openInNewTab:@"https://example.com/undo-b"];
      NSArray* before = w.currentSpace.allTabs;
      NSUInteger posA = [before indexOfObject:a];
      NSUInteger archived = w.archivedTabs.count;
      [w showItem:a];
      [w closeCurrentTab];
      BOOL gone = ![w.currentSpace.allTabs containsObject:a] && w.archivedTabs.count == archived + 1;
      NSUndoManager* um = [w windowWillReturnUndoManager:w.window];
      BOOL canUndo = um.canUndo && [um.undoActionName isEqualToString:@"Close Tab"];
      [um undo];
      BOOL back = [w.currentSpace.allTabs indexOfObject:a] == posA && w.shownItem == a && w.archivedTabs.count == archived;
      [um redo];
      BOOL redone = ![w.currentSpace.allTabs containsObject:a] && w.archivedTabs.count == archived + 1;
      std::printf("SELFTEST-UNDO closed=%d canUndo=%d restoredSamePlace=%d redo=%d\n", gone, canUndo, back, redone);
    });
    // Space themes: colours tint the sidebar per Space, survive a save/load round trip, icon shows in the picker.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 52 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      ArcSpace* sp = w.currentSpace;
      [w setTheme:@[ @"#5EC8F2", @"#2F6FDE" ] intensity:0.7 forSpace:sp];
      BOOL shown = !w.themeView.hidden;
      CAGradientLayer* g = (CAGradientLayer*)w.themeView.layer.sublayers.firstObject;
      BOOL colors = g.colors.count == 2 && fabs(g.opacity - 0.7) < 0.01;
      [w setIcon:@"🚀 extra" forSpace:sp];
      BOOL icon = [sp.iconEmoji isEqualToString:@"🚀"];
      NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-theme-test.json"];
      SidebarStoreSave(@[ sp ], sp.spaceID, tmp, nil);
      ArcSpace* back = SidebarStoreLoad(tmp, nil, nil).firstObject;
      [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
      BOOL saved = [back.themeColors isEqualToArray:@[ @"#5EC8F2", @"#2F6FDE" ]] && fabs(back.themeIntensity - 0.7) < 0.01 &&
                   [back.iconEmoji isEqualToString:@"🚀"];
      ArcSpace* other = nil;
      for (ArcSpace* s2 in w.spaces) if (s2 != sp) other = s2;
      BOOL perSpace = YES;
      if (other) {
        [w switchToSpace:other];
        // Unthemed Spaces show Arc's default indigo in dark mode, and nothing in light mode.
        perSpace = other.themeColors.count ? !w.themeView.hidden : w.themeView.hidden == !w.defaultThemeShown;
        [w switchToSpace:sp];
        perSpace = perSpace && !w.themeView.hidden;
      }
      // Grain (#26): fades in with the slider, saved with the Space, none on Arc's default theme.
      [w setThemeGrain:0.6 forSpace:sp];
      BOOL grainOn = fabsf(w.themeGrainOpacity - 0.6f * 0.35f) < 0.01;
      NSString* tmp2 = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-grain-test.json"];
      SidebarStoreSave(@[ sp ], sp.spaceID, tmp2, nil);
      BOOL grainSaved = fabs(SidebarStoreLoad(tmp2, nil, nil).firstObject.themeGrain - 0.6) < 0.01;
      [NSFileManager.defaultManager removeItemAtPath:tmp2 error:nil];
      [w setThemeGrain:0 forSpace:sp];
      BOOL grainOff = w.themeGrainOpacity == 0;
      std::printf("SELFTEST-GRAIN on=%d saved=%d off=%d\n", grainOn, grainSaved, grainOff);
      [w setTheme:nil intensity:0.5 forSpace:sp];
      BOOL cleared = w.themeView.hidden == !w.defaultThemeShown;
      [w setIcon:@"" forSpace:sp];
      std::printf("SELFTEST-THEME shown=%d colors=%d icon=%d saved=%d perSpace=%d cleared=%d\n", shown, colors, icon, saved,
                  perSpace, cleared && sp.iconEmoji == nil);
    });
    // Hover card on a sidebar tab.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 54 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://www.example.com/hover?x=1"];
      ArcItem* t = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:t];  // other timed checks may have opened tabs meanwhile
        NSArray* lines = [w showHoverCardForItem:t];
        BOOL shown = w.hoverCardShown;
        BOOL host = [lines containsObject:@"example.com"];
        BOOL url = [lines.lastObject hasPrefix:@"https://www.example.com/hover"];
        BOOL state = [lines[2] hasPrefix:@"Showing now"];
        [w hideHoverCard];
        std::printf("SELFTEST-HOVER shown=%d host=%d url=%d state=%d hidden=%d\n", shown, host, url, state, !w.hoverCardShown);
      });
    });
    // Media: a tab playing audio gets a speaker in the sidebar and drives the media bar from another tab.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 56 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/media-test"];
      ArcItem* m = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        // 20 s of a quiet 440 Hz tone as a WAV blob in an <audio> element.
        [w runJS:@"(function(){var r=8000,n=r*20,b=new ArrayBuffer(44+n*2),v=new DataView(b);"
                  "function s(o,t){for(var i=0;i<t.length;i++)v.setUint8(o+i,t.charCodeAt(i));}"
                  "s(0,'RIFF');v.setUint32(4,36+n*2,true);s(8,'WAVEfmt ');v.setUint32(16,16,true);v.setUint16(20,1,true);"
                  "v.setUint16(22,1,true);v.setUint32(24,r,true);v.setUint32(28,r*2,true);v.setUint16(32,2,true);"
                  "v.setUint16(34,16,true);s(36,'data');v.setUint32(40,n*2,true);"
                  "for(var i=0;i<n;i++)v.setInt16(44+i*2,Math.sin(i*2*Math.PI*440/r)*200,true);"
                  "var a=document.createElement('audio');a.src=URL.createObjectURL(new Blob([b],{type:'audio/wav'}));"
                  "document.body.appendChild(a);a.play();})()" inItem:m];
        __block int waits = 0;
        __block void (^check)(void);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"  // broken by check = nil
        check = ^{
          if (w.shownItem != m) [w showItem:m];  // a hidden test window plays only the shown tab promptly
          [w pollMediaNow];
          if (!m.mediaPlaying && ++waits < 60) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), check);
            return;
          }
          check = nil;
          {
            BOOL playing = m.mediaPlaying;
            [w showItem:m];  // other timed checks may have switched tabs meanwhile
            BOOL barHiddenWhileShown = w.mediaBarItem == nil;
            [w openInNewTab:@"https://example.com/media-other"];
            BOOL bar = w.mediaBarItem == m;
            [w toggleMuteItem:m];
            BOOL muted = m.audioMuted;
            [w toggleMuteItem:m];
            [w togglePlayItem:m];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
              BOOL paused = !m.mediaPlaying && m.mediaPaused && w.mediaBarItem == m;
              [w togglePlayItem:m];
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                BOOL resumed = m.mediaPlaying;
                [w togglePlayItem:m];
                std::printf("SELFTEST-MEDIA playing=%d barHiddenOnSameTab=%d bar=%d mute=%d unmuted=%d paused=%d resumed=%d\n",
                            playing, barHiddenWhileShown, bar, muted, !m.audioMuted, paused, resumed);
              });
            });
          }
        };
#pragma clang diagnostic pop
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), check);
      });
    });
    // Crashed page: chrome://crash kills the renderer; the tab shows the crashed view and Reload brings it back.
    // Frozen page: a busy loop plus a key press trips the hang monitor; Exit Page ends it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{  // after MEDIA
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.net/crash-test"];  // own site = own process, so the hang can't stall other checks
      ArcItem* c = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w loadURL:@"chrome://crash" inItem:c];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          BOOL crashed = c.crashed;
          [w reloadCrashedItem:c];
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [w showItem:c];
            BOOL back = !c.crashed && [w.currentURL hasPrefix:@"https://example.net"];
            // The freeze starts inside the page's own key/click handler, so the input Chromium is waiting on is the one
            // that hangs: exactly what the hang monitor detects, independent of reload or timer timing.
            NSString* freezeJS = @"if(!window.__notarcFreeze){window.__notarcFreeze=1;var f=function(){"
                                  "if(window.__notarcFrozen)return;window.__notarcFrozen=1;"
                                  "var t=Date.now();while(Date.now()-t<90000){}};"
                                  "addEventListener('keydown',f,true);addEventListener('mousedown',f,true);}";
            [w runJS:freezeJS inItem:c];
            __block int tries = 0;
            __block void (^poke)(void);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"  // cycle is broken by poke = nil when done
            poke = ^{
              if (w.hungItem || ++tries > 30) {
                BOOL hung = w.hungItem == c;
                [w answerHungSheet:YES];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                  gCrashTestDone = YES;
                  std::printf("SELFTEST-CRASH crashed=%d reloaded=%d hungSheet=%d exitPage=%d sheetGone=%d\n", crashed, back,
                              hung, c.crashed, w.hungItem == nil);
                  [w reloadCrashedItem:c];
                });
                poke = nil;
                return;
              }
              if (w.shownItem != c) [w showItem:c];  // Chromium only watches visible pages for hangs
              [w runJS:freezeJS inItem:c];  // no-op once installed; re-installs if the page was replaced
              [w sendKeyToItem:c];
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), poke);
            };
#pragma clang diagnostic pop
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), poke);
          });
        });
      });
    });
    // Multi-select: select three tabs, copy their links, put them in a new folder, archive two others at once.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      for (int i = 5; i >= 1; --i)
        [w openInNewTab:[NSString stringWithFormat:@"https://example.org/multi-%d", i] background:YES];
      NSArray<ArcItem*>* today = w.currentSpace.unpinned.children;
      if (today.count < 5) {
        std::printf("SELFTEST-MULTI setup=0\n");
        return;
      }
      NSArray<ArcItem*>* three = [today subarrayWithRange:NSMakeRange(0, 3)];
      NSArray<ArcItem*>* two = [today subarrayWithRange:NSMakeRange(3, 2)];
      ArcItem* shownBefore = w.shownItem;
      [w selectSidebarItems:three];
      BOOL selected = w.selectedSidebarItems.count == 3 && w.shownItem == shownBefore;
      NSString* links = [w linksForItems:three markdown:NO];
      BOOL linksOK = [links isEqualToString:@"https://example.org/multi-1\nhttps://example.org/multi-2\nhttps://example.org/multi-3"];
      BOOL md = [[w linksForItems:three markdown:YES] componentsSeparatedByString:@"](https://example.org/multi-"].count == 4;
      ArcItem* folder = [w newFolderWithItems:three];
      BOOL folderOK = folder.children.count == 3 && [w.currentSpace.pinned.children containsObject:folder] &&
                      [folder.children.firstObject.pinnedURL isEqualToString:@"https://example.org/multi-1"];
      NSUInteger archivedBefore = w.archivedTabs.count;
      [w archiveItems:two];
      BOOL archived = w.archivedTabs.count == archivedBefore + 2 && ![w.currentSpace.unpinned.children containsObject:two[0]] &&
                      ![w.currentSpace.unpinned.children containsObject:two[1]];
      ArcItem* nested = [w newNestedFolderIn:folder];
      BOOL nestedOK = nested.isFolder && folder.children.firstObject == nested && folder.children.count == 4;
      NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-nested-test.json"];
      SidebarStoreSave(@[ w.currentSpace ], w.currentSpace.spaceID, tmp, nil);
      ArcSpace* back = SidebarStoreLoad(tmp, nil, nil).firstObject;
      [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
      BOOL nestedSaved = NO;
      for (ArcItem* f in back.pinned.children)
        if ([f.itemID isEqualToString:folder.itemID]) nestedSaved = [f.children.firstObject.itemID isEqualToString:nested.itemID] && f.children.firstObject.isFolder;
      std::printf("SELFTEST-NESTED created=%d saved=%d\n", nestedOK, nestedSaved);
      // Arc folder rows: own chevron (no stock triangle), toggles open/closed; pressed fill; Pinned/Today separator.
      BOOL wasOpen = [w folderExpanded:folder];
      NSString* chev1 = [w folderChevronForItem:folder];
      [w toggleFolder:folder];
      NSString* chev2 = [w folderChevronForItem:folder];
      BOOL toggled = [w folderExpanded:folder] != wasOpen && ![chev1 isEqualToString:chev2] && chev1.length && chev2.length;
      [w toggleFolder:folder];
      ArcItem* anyTab = w.currentSpace.unpinned.children.firstObject;
      [w pressSidebarItem:anyTab down:YES];
      BOOL pressed = [[w sidebarRowStyleForItem:anyTab] containsString:@"pressed=1"];
      [w pressSidebarItem:anyTab down:NO];
      BOOL sep = [[w sidebarRowStyleForItem:w.currentSpace.unpinned] containsString:@"sep=1"];
      std::printf("SELFTEST-FOLDERROWS noTriangle=%d chevronToggles=%d pressed=%d separator=%d\n", !w.stockDisclosureShown,
                  toggled, pressed, sep);
      std::printf("SELFTEST-MULTI selected=%d links=%d markdown=%d folder=%d archived=%d\n", selected, linksOK, md,
                  folderOK, archived);
    });
    // #42: Cmd+Option+click on a link opens it in a Little Window; Close Little Windows; the global Cmd+Option+N key is
    // never registered by a test run.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 75 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSEventModifierFlags cmdOpt = NSEventModifierFlagCommand | NSEventModifierFlagOption;
      BOOL rule = OpensLittleWindowForClick(cmdOpt, YES) && !OpensLittleWindowForClick(NSEventModifierFlagCommand, YES) &&
                  !OpensLittleWindowForClick(cmdOpt, NO) && !OpensLittleWindowForClick(cmdOpt | NSEventModifierFlagShift, YES);
      NSUInteger before = w.littleWindowCount;
      ArcItem* from = w.shownItem;
      w.testClickModifiers = cmdOpt;
      BOOL taken = from.browserId && [w handleOpenURL:@"https://example.org/little-click" fromBrowser:from.browserId
                                         disposition:CEF_WOD_NEW_BACKGROUND_TAB userGesture:YES];
      w.testClickModifiers = 0;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BOOL opened = taken && w.littleWindowCount == before + 1;
        [w closeAllLittleWindows:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          std::printf("SELFTEST-LITTLECLICK rule=%d opened=%d closedAll=%d noGlobalKeyInTests=%d\n", rule, opened,
                      w.littleWindowCount == 0, !GlobalHotkeyInstalled());
        });
      });
    });
    // #44 Email peeking: Gmail's Atom feed (fixture), the sender match, code extraction; a code is copied (test
    // pasteboard), a link-only email opens in a Peek, a signed-out answer explains itself. No network.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSDateFormatter* iso = [NSDateFormatter new];
      iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
      iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
      iso.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
      NSString* (^when)(NSTimeInterval) = ^(NSTimeInterval ago) { return [iso stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-ago]]; };
      NSString* xml = [NSString stringWithFormat:
          @"<?xml version=\"1.0\"?><feed xmlns=\"http://purl.org/atom/ns#\" version=\"0.3\"><title>Gmail</title>"
           "<entry><title>Your Example sign-in code</title><summary>Use 482913 to sign in. It expires in 10 minutes.</summary>"
           "<link rel=\"alternate\" href=\"https://mail.google.com/mail/u/0/?m=1\"/><issued>%@</issued>"
           "<author><name>Example</name><email>no-reply@accounts.example.com</email></author></entry>"
           "<entry><title>Sign in to Other</title><summary>Click the link below to sign in.</summary>"
           "<link rel=\"alternate\" href=\"https://mail.google.com/mail/u/0/?m=2\"/><issued>%@</issued>"
           "<author><name>Other Team</name><email>hello@other.org</email></author></entry>"
           "<entry><title>Old code 111111</title><summary>old</summary><link href=\"https://mail.google.com/x\"/>"
           "<issued>%@</issued><author><name>Stale</name><email>a@stale.net</email></author></entry></feed>",
          when(60), when(120), when(7200)];
      NSData* atom = [xml dataUsingEncoding:NSUTF8StringEncoding];
      NSArray* entries = GmailFeedEntries(atom);
      BOOL parsed = entries.count == 3 && [entries[0][@"email"] isEqualToString:@"no-reply@accounts.example.com"];
      BOOL codes = [AuthCodeInText(@"Your verification code is 731 204") isEqualToString:@"731"] == NO &&
                   [AuthCodeInText(@"Your code: 004512") isEqualToString:@"004512"] &&
                   [AuthCodeInText(@"G-123456 is your Google verification code") isEqualToString:@"123456"] &&
                   AuthCodeInText(@"Meeting at 10:30 on 2026") == nil && [AuthCodeInText(@"Code ABC-123") isEqualToString:@"ABC-123"];
      BOOL stale = EmailPeekMatch(entries, @"stale.net", NSDate.date, 30 * 60) == nil;
      NSString* copied = [w finishPeekEmail:@"www.example.com" status:200 body:atom];
      NSString* pb = [[NSPasteboard pasteboardWithName:@"io.github.donnadieu.notarc.selftest"] stringForType:NSPasteboardTypeString];
      BOOL code = [copied isEqualToString:@"code:482913"] && [pb isEqualToString:@"482913"] &&
                  ![[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"482913"];
      NSString* peeked = [w finishPeekEmail:@"other.org" status:200 body:atom];
      BOOL peek = [peeked isEqualToString:@"peek:https://mail.google.com/mail/u/0/?m=2"];
      BOOL signedOut = [[w finishPeekEmail:@"other.org" status:302 body:nil] isEqualToString:@"signedOut"];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w closePeek];
        std::printf("SELFTEST-EMAILPEEK parsed=%d codes=%d stale=%d copied=%d peek=%d signedOut=%d\n", parsed, codes, stale,
                    code, peek, signedOut);
      });
    });
    // #70 Context menus: which NotArc items a right-click on a link, image, selection or the page gets; the image and
    // page actions copy to the test pasteboard; selected text searches. "Copy Image" fetches with the tab's sign-in.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 85 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      auto titles = [](bool link, bool image, bool sel, bool edit) {
        NSMutableArray* out = [NSMutableArray array];
        for (auto& it : BrowserClient::MenuItemsFor(link, image, sel, edit, "a long piece of selected text here"))
          [out addObject:it.first < 0 ? @"-" : [NSString stringWithUTF8String:it.second.c_str()]];
        return out;
      };
      NSArray* img = titles(false, true, false, false), *page = titles(false, false, false, false);
      NSArray* linkImg = titles(true, true, false, false), *sel = titles(false, false, true, false);
      BOOL menus = [img containsObject:@"Copy Image"] && [img containsObject:@"Save Image to Downloads"] &&
                   ![img containsObject:@"Copy Page URL"] && [page containsObject:@"Capture Page"] &&
                   [page containsObject:@"Boost This Site..."] && [linkImg containsObject:@"-"] &&
                   [linkImg containsObject:@"Open Link in Peek"] && [sel.firstObject hasPrefix:@"Search for \u201Ca long piece"] &&
                   titles(false, false, true, true).count == 0;
      ArcItem* t = w.shownItem;
      NSPasteboard* pb = [NSPasteboard pasteboardWithName:@"io.github.donnadieu.notarc.selftest"];
      [w handleLinkCommand:BrowserClient::kImageCopyAddress url:@"https://example.com/pic.png" text:nil fromBrowser:t.browserId];
      BOOL address = [[pb stringForType:NSPasteboardTypeString] isEqualToString:@"https://example.com/pic.png"];
      [w handleLinkCommand:BrowserClient::kPageCopyMarkdown url:@"https://example.org/p" text:nil fromBrowser:t.browserId];
      BOOL md = [[pb stringForType:NSPasteboardTypeString] hasSuffix:@"](https://example.org/p)"];
      NSUInteger tabsBefore = w.currentSpace.unpinned.children.count;
      [w handleLinkCommand:BrowserClient::kSelectionSearch url:nil text:@"notarc selftest query" fromBrowser:t.browserId];
      ArcItem* search = w.currentSpace.unpinned.children.firstObject;
      BOOL searched = w.currentSpace.unpinned.children.count == tabsBefore + 1 && [search.url containsString:@"notarc"];
      // A tiny PNG served from a data: URL stands in for a page image (no network).
      NSString* png = @"data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGP4z8DwH4QZYAwAR8oH+WdZbrcAAAAASUVORK5CYII=";
      [w handleLinkCommand:BrowserClient::kImageCopy url:png text:nil fromBrowser:t.browserId];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BOOL image = w.lastCopiedImageSize.width == 2 && [pb canReadObjectForClasses:@[ NSImage.class ] options:nil];
        BOOL general = ![[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString] isEqualToString:@"https://example.com/pic.png"];
        if (search) [w deleteSidebarItem:search];
        std::printf("SELFTEST-CONTEXTMENU menus=%d imageAddress=%d pageMarkdown=%d search=%d copyImage=%d generalUntouched=%d\n",
                    menus, address, md, searched, image, general);
      });
    });
    // #37: drag a sidebar tab onto the page -> it joins the shown page in a split on that side; Maximize Pane fills
    // the card with the focused pane and focusing another pane restores the split. Drop-side geometry is pure.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      ArcSpace* sp = w.currentSpace;
      [w openInNewTab:@"https://example.org/drag-split-b"];
      ArcItem* b = sp.unpinned.children.firstObject;
      [w openInNewTab:@"https://example.org/drag-split-a"];
      ArcItem* a = sp.unpinned.children.firstObject;
      NSSize sz = NSMakeSize(1000, 600);
      BOOL sides = PageDropSide(NSMakePoint(950, 300), sz) == 0 &&
                   PageDropSide(NSMakePoint(40, 300), sz) == 1 &&
                   PageDropSide(NSMakePoint(500, 20), sz) == 2 &&
                   PageDropSide(NSMakePoint(500, 590), sz) == 3;
      [w showItem:a];
      BOOL joined = [w splitShownWithItem:b side:1];
      ArcItem* group = [w parentOfItemForTest:a];
      BOOL placed = joined && group.isSplit && group.children.count == 2 && group.children.firstObject == b &&
                    ![sp.unpinned.children containsObject:b] && !group.splitHorizontal;
      BOOL refused = ![w splitShownWithItem:b side:0];  // already in this split
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:b];
        [w toggleMaximizePane:nil];
        NSRect full = [w frameOfPaneItem:b];
        BOOL maxed = w.maximizedPane == b && NSIsEmptyRect([w frameOfPaneItem:a]) && full.size.width > 0;
        [w showItem:a];  // focusing the other pane restores the split
        BOOL restored = w.maximizedPane == nil && !NSIsEmptyRect([w frameOfPaneItem:a]) && !NSIsEmptyRect([w frameOfPaneItem:b]);
        [w deleteSidebarItem:group ?: a];
        std::printf("SELFTEST-DRAGSPLIT sides=%d joined=%d placed=%d refusedTwice=%d maximized=%d restored=%d\n", sides,
                    joined, placed, refused, maxed, restored);
      });
    });
    // #78 Web notifications: a page's new Notification() reaches NotArc (shim injected at load start) and is shown
    // only for sites allowed in Site Settings; tests record instead of posting to Notification Center.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 95 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/notify-test"];
      ArcItem* t = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w setSitePermission:@"notifications" value:@YES forOrigin:@"https://example.com"];
        [w runJS:@"document.title='shim:'+(!!window.__notarcNotify);new Notification('Hello from a page',{body:'It reached macOS'})" inItem:t];
        WaitUntil(^{ return (BOOL)[w.lastNotification[@"title"] isEqualToString:@"Hello from a page"]; }, 6, ^{
          BOOL shown = [w.lastNotification[@"body"] isEqualToString:@"It reached macOS"] &&
                       [w.lastNotification[@"origin"] isEqualToString:@"https://example.com"];
          BOOL shim = [t.liveTitle isEqualToString:@"shim:true"];
          BOOL blocked = ![w browser:t.browserId notification:@"{\"title\":\"x\"}" pageURL:@"https://not-allowed.example/"];
          [w setSitePermission:@"notifications" value:nil forOrigin:@"https://example.com"];
          [w deleteSidebarItem:t];
          std::printf("SELFTEST-NOTIFY shim=%d shown=%d onlyAllowedSites=%d\n", shim, shown, blocked);
        });
      });
    });
    // #56 Calendar: meeting-link finder, which meeting shows (in progress or within 10 min, never all-day), the bar
    // with Join, off when the setting is off. #57 Favorite previews: kinds by site, Gmail rows from the feed fixture,
    // calendar rows. Events are fed in; the test never asks macOS for Calendar access.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      BOOL links = [MeetingLinkInText(@"Join: https://us02web.zoom.us/j/123456789?pwd=abc (passcode 1)") hasPrefix:@"https://us02web.zoom.us/j/123456789"] &&
                   [MeetingLinkInText(@"meet.google.com https://meet.google.com/abc-defg-hij") isEqualToString:@"https://meet.google.com/abc-defg-hij"] &&
                   [MeetingLinkInText(@"https://teams.microsoft.com/l/meetup-join/19%3ameeting_x") hasPrefix:@"https://teams.microsoft.com/l/meetup-join/"] &&
                   MeetingLinkInText(@"Room 4B, https://example.com/agenda") == nil;
      NSDate* now = [NSDate dateWithTimeIntervalSinceReferenceDate:810000000];
      CalendarEvent* (^ev)(NSString*, NSTimeInterval, NSTimeInterval, NSString*, BOOL) =
          ^(NSString* t, NSTimeInterval s, NSTimeInterval len, NSString* link, BOOL allDay) {
            CalendarEvent* e = [CalendarEvent new];
            e.title = t;
            e.start = [now dateByAddingTimeInterval:s];
            e.end = [e.start dateByAddingTimeInterval:len];
            e.meetingURL = link;
            e.allDay = allDay;
            return e;
          };
      NSArray* events = @[ ev(@"Holiday", -3600, 86400, nil, YES), ev(@"Later", 3600, 1800, nil, NO),
                           ev(@"Standup", 300, 900, @"https://meet.google.com/abc-defg-hij", NO) ];
      BOOL pick = [NextMeeting(events, now, 600).title isEqualToString:@"Standup"] &&
                  NextMeeting(@[ events[0], events[1] ], now, 600) == nil &&
                  [NextMeeting(@[ ev(@"Ongoing", -600, 1800, nil, NO) ], now, 600).title isEqualToString:@"Ongoing"];
      SettingSetBool(kSettingCalendar, YES);
      [w setCalendarEventsForTest:events now:now];
      BOOL bar = [w.meetingBarText hasPrefix:@"Standup"] && [w.meetingBarText containsString:@"in 5 min"] && w.meetingJoinShown;
      SettingSetBool(kSettingCalendar, NO);
      [w setCalendarEventsForTest:events now:now];
      BOOL off = w.meetingBarText == nil;
      [w setCalendarEventsForTest:nil now:nil];
      BOOL kinds = [FavoritePreviewKind(@"https://mail.google.com/mail/u/0/#inbox") isEqualToString:@"gmail"] &&
                   [FavoritePreviewKind(@"https://calendar.google.com/calendar/r") isEqualToString:@"calendar"] &&
                   [FavoritePreviewKind(@"https://outlook.office.com/calendar/view/week") isEqualToString:@"calendar"] &&
                   FavoritePreviewKind(@"https://outlook.office.com/mail/") == nil && FavoritePreviewKind(@"https://example.com") == nil;
      NSString* xml = @"<?xml version=\"1.0\"?><feed xmlns=\"http://purl.org/atom/ns#\"><entry><title>Lunch?</title>"
                       "<link href=\"https://mail.google.com/mail/u/0/?m=9\"/><issued>2026-11-09T10:00:00Z</issued>"
                       "<author><name>Sam</name><email>sam@example.com</email></author></entry></feed>";
      NSArray* gm = [w gmailPreviewRows:200 body:[xml dataUsingEncoding:NSUTF8StringEncoding]];
      BOOL gmail = gm.count == 1 && [gm[0][@"text"] isEqualToString:@"Sam \u2014 Lunch?"] && [gm[0][@"url"] hasSuffix:@"m=9"] &&
                   [[w gmailPreviewRows:401 body:nil].firstObject[@"text"] hasPrefix:@"Sign in to Gmail"];
      NSArray* cal = [w calendarPreviewRows:events now:now];
      BOOL calRows = cal.count == 3 && [cal[0][@"text"] hasPrefix:@"All day"];
      std::printf("SELFTEST-CALENDAR links=%d pick=%d bar=%d off=%d\n", links, pick, bar, off);
      std::printf("SELFTEST-FAVPREVIEW kinds=%d gmail=%d calendar=%d\n", kinds, gmail, calRows);
    });
    // Little Window -> another Space via its Move to Space menu.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 62 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      ArcSpace* start = w.currentSpace;
      NSUInteger target = NSNotFound;
      for (NSUInteger i = 0; i < w.spaces.count; ++i)
        if (w.spaces[i] != start && target == NSNotFound) target = i;
      if (target == NSNotFound) { std::printf("SELFTEST-LITTLESPACE skipped=1\n"); return; }
      [w openLittleWindow:@"https://example.com/little-to-space"];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSUInteger before = w.littleWindowCount, archivedBefore = w.archivedTabs.count;
        [w moveLittleWindow:before - 1 toSpaceAtIndex:target];
        ArcSpace* dest = w.spaces[target];
        BOOL there = NO;
        for (ArcItem* t in dest.unpinned.children)
          if ([t.url hasPrefix:@"https://example.com/little-to-space"]) there = YES;
        BOOL switched = w.currentSpace == dest;
        BOOL closed = w.littleWindowCount == before - 1 && w.archivedTabs.count == archivedBefore;
        [w switchToSpace:start];
        std::printf("SELFTEST-LITTLESPACE inOtherSpace=%d switched=%d closedNotArchived=%d\n", there, switched, closed);
      });
    });
    // Closing a Peek offers Undo: toast shown, Undo reopens the same page; opening as a tab offers nothing.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 64 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openPeek:@"https://example.net/peek-undo"];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w closePeek];
        BOOL toast = w.peekToastShown && [w.lastClosedPeekURL hasPrefix:@"https://example.net/peek-undo"];
        BOOL undoName = [w.sidebarUndoManager.undoActionName isEqualToString:@"Close Peek"];
        [w.sidebarUndoManager undo];
        BOOL reopened = w.isPeeking && !w.peekToastShown;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [w promotePeekToTab];
          BOOL noToastAfterPromote = !w.peekToastShown && !w.isPeeking;
          std::printf("SELFTEST-PEEKUNDO toast=%d undoName=%d reopened=%d noToastAfterPromote=%d\n", toast, undoName,
                      reopened, noToastAfterPromote);
        });
      });
    });
    // Toolbar with full URL and Space header toggle (settings restored afterwards so runs stay independent).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 66 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/toolbar-test?q=1"];
      ArcItem* t = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:t];
        [w toggleToolbar:nil];
        BOOL shown = w.toolbarShown;
        BOOL full = [w.toolbarAddress isEqualToString:@"https://example.com/toolbar-test?q=1"];
        NSRect pane = [[w paneFrames].firstObject rectValue];
        BOOL below = NSMaxY(pane) <= w.window.contentView.bounds.size.height - 30;
        [w submitToolbarAddress:@"example.org/toolbar-typed"];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          [w showItem:t];  // other timed checks may have switched tabs meanwhile
          BOOL navigated = [t.url hasPrefix:@"https://example.org/toolbar-typed"] &&
                           [w.toolbarAddress hasPrefix:@"https://example.org/toolbar-typed"];
          [w toggleToolbar:nil];
          BOOL hidden = !w.toolbarShown;
          [w toggleSpaceHeader:nil];
          BOOL headerHidden = !w.spaceHeaderShown;
          [w toggleSpaceHeader:nil];
          std::printf("SELFTEST-TOOLBAR shown=%d fullURL=%d pageBelow=%d typedGo=%d hidden=%d headerToggle=%d\n", shown,
                      full, below, navigated, hidden, headerHidden && w.spaceHeaderShown);
        });
      });
    });
    // Command bar suggestions: open tabs (any Space), Spaces, history, menu actions, top sites, learned ranking.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 68 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/suggest-alpha"];
      [w openInNewTab:@"https://example.com/suggest-beta"];
      ArcItem* alpha = nil;
      for (ArcItem* t in w.currentSpace.allTabs)
        if ([t.url hasPrefix:@"https://example.com/suggest-alpha"]) alpha = t;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        BOOL (^has)(NSArray*, NSString*, NSString*) = ^BOOL(NSArray* list, NSString* kind, NSString* sub) {
          for (NSDictionary* d in list)
            if ([d[@"kind"] isEqualToString:kind] && ([d[@"title"] containsString:sub] || [d[@"url"] containsString:sub] ||
                                                      [((ArcItem*)d[@"item"]).url containsString:sub]))
              return YES;
          return NO;
        };
        NSArray* tabs = [w commandSuggestionsFor:@"suggest-alpha"];
        BOOL first = [tabs.firstObject[@"kind"] isEqualToString:@"go"];
        BOOL tab = has(tabs, @"tab", @"suggest-alpha");
        ArcSpace* other = nil;
        for (ArcSpace* sp in w.spaces) if (sp != w.currentSpace) other = sp;
        BOOL space = !other || has([w commandSuggestionsFor:[other.title substringToIndex:MIN((NSUInteger)3, other.title.length)]],
                                   @"space", other.title);
        BOOL action = has([w commandSuggestionsFor:@"focus mo"], @"action", @"Focus Mode");
        BOOL history = has([w commandSuggestionsFor:@"example"], @"history", @"example") ||
                       has([w commandSuggestionsFor:@"example"], @"tab", @"example");
        BOOL top = [w commandSuggestionsFor:@""].count > 0;
        // Learned ranking: picking the beta tab twice for the query "suggest" puts it first among results.
        NSDictionary* beta = nil;
        for (NSDictionary* d in [w commandSuggestionsFor:@"suggest"])
          if ([d[@"kind"] isEqualToString:@"tab"] && [((ArcItem*)d[@"item"]).url containsString:@"suggest-beta"]) beta = d;
        [w performCommandSuggestion:beta];
        [w performCommandSuggestion:beta];
        BOOL switched = [w.shownItem.url containsString:@"suggest-beta"];
        NSArray* after = [w commandSuggestionsFor:@"suggest"];
        [w showItem:alpha];
        NSArray* after2 = [w commandSuggestionsFor:@"suggest"];
        BOOL learned = after2.count > 1 && [((ArcItem*)after2[1][@"item"]).url containsString:@"suggest-beta"];
        (void)after;
        // Arc command bar look: selected row in Arc blue (2A2EC1) as a pill, icons per row, hairline, placeholder.
        [w showCommandBarForNewTab:YES];
        NSString* style = w.commandBarStyle;
        [w hideCommandBar];
        BOOL styled = [style containsString:@"sel=292EC1"] && [style containsString:@"rowClass=CommandRowView"] &&
                      [style containsString:@"divider=1"] && [style containsString:@"placeholder=Search or Enter URL..."] &&
                      [style containsString:@"cell=NSTableCellView"];
        if (!styled) std::printf("SELFTEST-CMDSTYLE-DEBUG %s\n", style.UTF8String);
        std::printf("SELFTEST-SUGGEST goFirst=%d tab=%d space=%d action=%d history=%d topSites=%d switched=%d learned=%d "
                    "styled=%d\n", first, tab, space, action, history, top, switched, learned, styled);
      });
    });
    // Site prompts: notification permission asked once, remembered; mic denied (never reaches macOS);
    // a mailto: link asks before opening Mail and is cancelled.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 70 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.org/site-prompts"];
      ArcItem* t = w.shownItem;
      __block NSString* firstPrompt = nil, *micPrompt = nil, *mailPrompt = nil;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:t];
        [w resetSitePermissions:nil];  // the SelfTest profile keeps Chromium's answers between runs
        [w runJS:@"Notification.requestPermission().then(r => document.title = 'n1:' + r)" inItem:t];
        WaitUntil(^{ if (w.shownItem != t) [w showItem:t]; return (BOOL)(w.pendingSitePrompt.length > 0); }, 10, ^{
          firstPrompt = w.pendingSitePrompt;
          [w answerSitePrompt:YES remember:YES];
          WaitUntil(^{ return (BOOL)[t.liveTitle hasPrefix:@"n1:"]; }, 5, ^{
            NSString* t1 = t.liveTitle;
            BOOL remembered = [[w sitePermissionsForOrigin:@"https://example.org"][@"notifications"] boolValue];
            [w runJS:@"document.title='mic:start'; navigator.mediaDevices.getUserMedia({audio:true}).then(() => document.title='mic:yes', e => document.title='mic:' + e.name)"
              inItem:t];
            WaitUntil(^{ if (w.shownItem != t) [w showItem:t]; return (BOOL)[w.pendingSitePrompt hasPrefix:@"microphone:"]; }, 10, ^{
              micPrompt = w.pendingSitePrompt;
              [w answerSitePrompt:NO remember:NO];
              WaitUntil(^{ return (BOOL)([t.liveTitle hasPrefix:@"mic:"] && ![t.liveTitle isEqualToString:@"mic:start"]); }, 5, ^{
                NSString* t2 = t.liveTitle;
                [w runJS:@"location.href = 'mailto:selftest@example.com'" inItem:t];
                WaitUntil(^{ if (w.shownItem != t) [w showItem:t]; return (BOOL)[w.pendingSitePrompt hasPrefix:@"open:"]; }, 10, ^{
                  mailPrompt = w.pendingSitePrompt;
                  [w answerSitePrompt:NO remember:NO];
                  [w showItem:t];
                  [w resetSitePermissions:nil];
                  BOOL reset = [w sitePermissionsForOrigin:@"https://example.org"].count == 0;
                  std::printf("SELFTEST-SITEPROMPT asked=%d granted=%d remembered=%d micAsked=%d micDenied=%d mailAsked=%d reset=%d\n",
                              [firstPrompt hasPrefix:@"notifications:https://example.org"], [t1 isEqualToString:@"n1:granted"],
                              remembered, [micPrompt hasPrefix:@"microphone:"], [t2 isEqualToString:@"mic:NotAllowedError"],
                              [mailPrompt hasPrefix:@"open:mailto"], reset);
                  if (getenv("NOTARC_PROMPT_DEBUG"))
                    std::printf("PROMPT-DEBUG %s | %s | %s | %s | %s | url=%s\n", firstPrompt.UTF8String ?: "-", t1.UTF8String ?: "-",
                                micPrompt.UTF8String ?: "-", t2.UTF8String ?: "-", mailPrompt.UTF8String ?: "-", t.url.UTF8String ?: "-");
                });
              });
            });
          });
        });
      });
    });
    // PDFs open in the built-in viewer (not downloaded).
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSUInteger downloadsBefore = [DownloadManager shared].entries.count;
      [w openInNewTab:@"https://www.w3.org/WAI/ER/tests/xhtml/testfiles/resources/pdf/dummy.pdf"];
      ArcItem* t = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:t];
        [w runJS:@"document.title = 'pdf:' + document.contentType + ':' + document.querySelectorAll('embed,iframe').length" inItem:t];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          NSString* title = t.liveTitle ?: @"-";
          BOOL notDownloaded = [DownloadManager shared].entries.count == downloadsBefore;
          BOOL stayed = [t.url hasSuffix:@"dummy.pdf"];
          BOOL viewer = [title hasPrefix:@"pdf:application/pdf"];
          std::printf("SELFTEST-PDF viewer=%d notDownloaded=%d stayed=%d title=%s\n", viewer, notDownloaded, stayed, title.UTF8String);
        });
      });
    });
    // Boosts: a Boost for example.org applies on page load (colour overlay, zap, case, custom CSS and JS), a zap
    // picked in the page is added, turning it off removes it from the page, and it's saved.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w deleteBoostForHost:@"example.org"];
      [w setBoostForHost:@"example.org" configure:^(Boost* b) {
        b.enabled = YES;
        b.hue = 200;
        b.textTransform = @"uppercase";
        [b.zaps removeAllObjects];
        [b.zaps addObject:@"p"];
        b.css = @"body{outline:3px solid rgb(1, 2, 3)}";
        b.js = @"document.documentElement.dataset.boostJs='ran'";
      }];
      [w openInNewTab:@"https://example.org/boost-test"];
      ArcItem* t = w.shownItem;
      NSString* probe = @"try{document.title='boost:'+[getComputedStyle(document.querySelector('p')).display,"
                         "getComputedStyle(document.body).textTransform,getComputedStyle(document.body).outlineColor,"
                         "document.documentElement.dataset.boostJs||'-',!!document.getElementById('__notarc_boost__'),"
                         "getComputedStyle(document.documentElement,'::after').mixBlendMode].join('|')}catch(e){document.title='boost:ERR '+e}";
      WaitUntil(^{ if (w.shownItem != t) [w showItem:t]; return (BOOL)(t.liveTitle.length && ![w isLoading]); }, 20, ^{
        [w runJS:probe inItem:t];
        WaitUntil(^{ return (BOOL)[t.liveTitle hasPrefix:@"boost:"]; }, 5, ^{
          NSString* on = t.liveTitle;
          BOOL applied = [on isEqualToString:@"boost:none|uppercase|rgb(1, 2, 3)|ran|true|hue"];
          [w handleZapSelector:@"a:nth-of-type(1)" browser:t.browserId];
          Boost* b = [w boostForURL:@"https://example.org/x"];
          BOOL zapAdded = [b.zaps containsObject:@"a:nth-of-type(1)"];
          BOOL sub = [w boostForURL:@"https://docs.example.org/"] == b && [w boostForURL:@"https://example.com/"] == nil;
          if (w.shownItem != t) [w showItem:t];  // the indicator follows the shown tab; other checks may switch tabs
          NSString* indOn = w.boostIndicatorState;
          // Zap all related: the selector Option-click picks covers every element with the same tag and classes.
          [w runJS:@"(function(){var d=document.createElement('div');d.id='zrel';"
                    "d.innerHTML='<span class=\\'ad x\\'>1</span><b>k</b><span class=\\'ad x\\'>2</span>';document.body.appendChild(d);})()"
            inItem:t];
          [w runJS:BoostZapModeScript() inItem:t];
          [w runJS:@"document.title='rel:'+window.__notarcZapSel(document.querySelectorAll('span.ad')[1],true);"
                    "document.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape'}))" inItem:t];
          __block BOOL related = NO;
          WaitUntil(^{ return (BOOL)[t.liveTitle hasPrefix:@"rel:"]; }, 5, ^{
            related = [t.liveTitle isEqualToString:@"rel:span.ad.x"];
            if (!related) std::printf("SELFTEST-BOOST-DEBUG rel=[%s]\n", t.liveTitle.UTF8String);
          [w setBoostForHost:@"example.org" configure:^(Boost* x) { x.enabled = NO; }];
          [w runJS:@"document.title='off:'+!!document.getElementById('__notarc_boost__')+'|'+getComputedStyle(document.querySelector('p')).display" inItem:t];
          WaitUntil(^{
            if (w.shownItem != t) [w showItem:t];
            return (BOOL)([t.liveTitle hasPrefix:@"off:"] && [w.boostIndicatorState isEqualToString:@"off"]);
          }, 5, ^{
            BOOL off = [t.liveTitle isEqualToString:@"off:false|block"];
            NSString* indOff = w.boostIndicatorState;
            BOOL saved = w.savedBoostCount == 1;
            if (!applied || !off) std::printf("SELFTEST-BOOST-DEBUG on=[%s] off=[%s]\n", on.UTF8String, t.liveTitle.UTF8String);
            [w deleteBoostForHost:@"example.org"];
            std::printf("SELFTEST-BOOST applied=%d zapAdded=%d subdomain=%d off=%d saved=%d deleted=%d related=%d "
                        "indicatorOn=%d indicatorOff=%d\n", applied, zapAdded, sub, off, saved, w.savedBoostCount == 0, related,
                        [indOn isEqualToString:@"on"], [indOff isEqualToString:@"off"]);
          });
          });
        });
      });
    });
    // Live Folders: a feed (local RSS file, so no network) fills the folder; a refresh adds new entries, drops ones that
    // left the feed and keeps a closed one from coming back; tabs can't be dragged in; GitHub/Atom parsing and input
    // parsing work; it's saved with the sidebar.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSString* feed = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-selftest-feed.xml"];
      NSString* (^rss)(NSArray*) = ^(NSArray* ids) {
        NSMutableString* x = [NSMutableString stringWithString:@"<?xml version=\"1.0\"?><rss version=\"2.0\"><channel><title>T</title>"];
        for (NSString* i in ids)
          [x appendFormat:@"<item><title><![CDATA[Post %@]]></title><link>https://example.org/post/%@</link></item>", i, i];
        [x appendString:@"</channel></rss>"];
        return (NSString*)x;
      };
      [rss(@[ @"a", @"b", @"c" ]) writeToFile:feed atomically:YES encoding:NSUTF8StringEncoding error:nil];
      ArcItem* f = [w createLiveFolderKind:@"feed" source:[NSURL fileURLWithPath:feed].absoluteString title:@"Test Feed"];
      WaitUntil(^{ return (BOOL)(f.children.count == 3); }, 10, ^{
        BOOL filled = f.children.count == 3 && [f.children[0].displayTitle isEqualToString:@"Post a"] &&
                      [f.children[2].url isEqualToString:@"https://example.org/post/c"];
        ArcItem* keep = f.children[1];
        [w dismissLiveFolderTab:f.children[0]];  // close "a"
        [rss(@[ @"d", @"a", @"b" ]) writeToFile:feed atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [w refreshLiveFolder:f done:^(BOOL ok) {
          NSMutableArray* urls = [NSMutableArray array];
          for (ArcItem* c in f.children) [urls addObject:c.url.lastPathComponent];
          BOOL merged = ok && [[urls componentsJoinedByString:@","] isEqualToString:@"d,b"] && f.children[1] == keep;
          [w openInNewTab:@"https://example.org/not-in-feed"];
          ArcItem* tab = w.shownItem;
          BOOL noDrop = ![w moveItem:tab toParent:f index:0];
          [w closeTab:nil];
          NSArray* gh = LiveFolderParse(@"github-prs",
              [@"[{\"html_url\":\"https://github.com/o/r/pull/7\",\"title\":\"Fix\",\"number\":7}]" dataUsingEncoding:NSUTF8StringEncoding], 25);
          NSArray* ghIssues = LiveFolderParse(@"github-issues",
              [@"[{\"html_url\":\"https://github.com/o/r/pull/7\",\"title\":\"PR\",\"pull_request\":{}},{\"html_url\":\"https://github.com/o/r/issues/8\",\"title\":\"Bug\",\"number\":8}]"
                  dataUsingEncoding:NSUTF8StringEncoding], 25);
          NSArray* atom = LiveFolderParse(@"feed",
              [@"<feed xmlns=\"http://www.w3.org/2005/Atom\"><entry><title>E</title><link rel=\"alternate\" href=\"https://example.org/e\"/></entry></feed>"
                  dataUsingEncoding:NSUTF8StringEncoding], 25);
          BOOL parse = gh.count == 1 && [((LiveFolderEntry*)gh[0]).title isEqualToString:@"#7 Fix"] && ghIssues.count == 1 &&
                       [((LiveFolderEntry*)ghIssues[0]).title isEqualToString:@"#8 Bug"] && atom.count == 1 && [((LiveFolderEntry*)atom[0]).url isEqualToString:@"https://example.org/e"];
          NSDictionary* in1 = LiveFolderSourceFromInput(@"https://github.com/Donnadieu/notarc/pulls", NO);
          NSDictionary* in2 = LiveFolderSourceFromInput(@"github.com/Donnadieu/notarc/issues", NO);
          NSDictionary* in3 = LiveFolderSourceFromInput(@"example.com/feed.xml", NO);
          BOOL input = [in1[@"kind"] isEqualToString:@"github-prs"] && [in1[@"source"] isEqualToString:@"Donnadieu/notarc"] &&
                       [in2[@"kind"] isEqualToString:@"github-issues"] && [in3[@"source"] isEqualToString:@"https://example.com/feed.xml"] &&
                       LiveFolderSourceFromInput(@"javascript:alert(1)", NO) == nil;
          NSString* json = [NSString stringWithContentsOfFile:SidebarStorePath(YES) encoding:NSUTF8StringEncoding error:nil];
          [w saveSidebarNow];
          json = [NSString stringWithContentsOfFile:SidebarStorePath(YES) encoding:NSUTF8StringEncoding error:nil];
          BOOL saved = [json containsString:@"notarc-selftest-feed.xml"] && [json containsString:@"dismissed"];
          if (!merged) std::printf("SELFTEST-LIVEFOLDER-DEBUG urls=%s\n", [urls componentsJoinedByString:@","].UTF8String);
          [w deleteSidebarItem:f];
          [[NSFileManager defaultManager] removeItemAtPath:feed error:nil];
          std::printf("SELFTEST-LIVEFOLDER filled=%d merged=%d noDrop=%d parse=%d input=%d saved=%d\n", filled, merged, noDrop,
                      parse, input, saved);
        }];
      });
    });
    // Easels: capturing a page adds a PNG card (with its link) to a new easel, text boxes can be added and moved,
    // everything is saved and reloads when switching back, deleting works, and closing/reopening restores it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.org/easel-src"];
      ArcItem* src = w.shownItem;
      WaitUntil(^{ if (w.shownItem != src) [w showItem:src]; return (BOOL)(src.liveTitle.length && ![w isLoading]); }, 20, ^{
        [w captureShownPageToEasel:^(BOOL captured) {
          ArcItem* easel = w.shownItem;
          EaselView* ev = [w easelView];
          BOOL shown = easel.easelID != nil && ev != nil && easel.browserId == 0;
          EaselObject* img = ev.objects.firstObject;
          BOOL image = img && [img.kind isEqualToString:@"image"] &&
                       [[NSFileManager defaultManager] fileExistsAtPath:[ev.directory stringByAppendingPathComponent:img.image]] &&
                       [img.link hasPrefix:@"https://example.org/easel-src"] && img.frame.size.width > 100;
          EaselObject* txt = [ev addText:@"Trip ideas" at:NSMakePoint(40, 600)];
          [ev moveObject:txt by:NSMakeSize(30, 10)];
          [ev save];
          [w easelDidChange:ev];
          BOOL titled = [easel.displayTitle isEqualToString:@"Trip ideas"];
          [w showItem:src];
          BOOL hidden = [w easelView] == nil;
          [w showItem:easel];
          EaselView* ev2 = [w easelView];
          BOOL reloaded = ev2.objects.count == 2 && [ev2.objects[1].text isEqualToString:@"Trip ideas"] &&
                          NSEqualPoints(ev2.objects[1].frame.origin, NSMakePoint(70, 610));
          [ev2 selectObject:ev2.objects[1]];
          [ev2 deleteSelected];
          [ev2 addText:@"Trip ideas" at:NSMakePoint(40, 600)];
          BOOL deleted = ev2.objects.count == 2;
          NSString* url = easel.url;
          [w closeTab:nil];
          [w openInNewTab:url];
          ArcItem* back = w.shownItem;
          BOOL reopened = back.easelID && [w easelView].objects.count == 2 && [back.displayTitle isEqualToString:@"Trip ideas"];
          [w closeTab:nil];
          [w showItem:src];
          [w closeTab:nil];
          std::printf("SELFTEST-EASEL captured=%d shown=%d image=%d titled=%d hiddenForTabs=%d reloaded=%d deleted=%d reopened=%d\n",
                      captured, shown, image, titled, hidden, reloaded, deleted, reopened);
        }];
      });
    });
    // Notes: a new note shows the editor (no web view), typing names it from its first line and saves rich text,
    // switching away and back reloads it, closing archives it and reopening from the archive brings the text back.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 110 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      ArcItem* note = [w createNoteWithID:nil];
      BOOL editor = w.shownItem == note && [w noteEditorText] != nil && note.browserId == 0;
      [w typeInNote:@"Groceries\nmilk and eggs"];
      [w makeNoteRangeBold:NSMakeRange(0, 9)];
      BOOL titled = [note.displayTitle isEqualToString:@"Groceries"];
      BOOL saved = [[w savedNoteText:note] isEqualToString:@"Groceries\nmilk and eggs"];
      BOOL bold = [w noteRangeIsBold:note range:NSMakeRange(0, 9)] && ![w noteRangeIsBold:note range:NSMakeRange(10, 4)];
      [w openInNewTab:@"https://example.org/after-note"];
      BOOL hidden = [w noteEditorText] == nil;
      [w showItem:note];
      BOOL reloaded = [[w noteEditorText] isEqualToString:@"Groceries\nmilk and eggs"];
      NSString* noteURL = note.url;
      [w closeTab:nil];
      BOOL archived = NO;
      for (ArchivedTab* a in [w archivedTabs]) if ([a.url isEqualToString:noteURL]) archived = YES;
      [w openInNewTab:noteURL];
      ArcItem* back = w.shownItem;
      BOOL reopened = back.noteID && [[w noteEditorText] isEqualToString:@"Groceries\nmilk and eggs"] &&
                      [back.displayTitle isEqualToString:@"Groceries"];
      [w closeTab:nil];
      std::printf("SELFTEST-NOTES editor=%d titled=%d saved=%d bold=%d hiddenForTabs=%d reloaded=%d archived=%d reopened=%d\n",
                  editor, titled, saved, bold, hidden, reloaded, archived, reopened);
    });
    // Site settings popover: rows reflect remembered answers; changing one is stored; clear cookies works from it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 90 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.org/site-settings"];
      ArcItem* t = w.shownItem;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:t];
        [w resetSitePermissions:nil];
        [w setSitePermission:@"camera" value:@NO forOrigin:@"https://example.org"];
        [w showSiteSettings:nil];
        BOOL shown = w.siteSettingsShown;
        NSArray* rows = w.siteSettingsRows;
        BOOL rowsOK = [rows containsObject:@"camera=block"] && [rows containsObject:@"microphone=ask"] &&
                      [rows containsObject:@"secure=1"];
        [w setSitePermission:@"location" value:@YES forOrigin:@"https://example.org"];
        BOOL stored = [[w sitePermissionsForOrigin:@"https://example.org"][@"location"] boolValue] &&
                      [w.siteSettingsRows containsObject:@"location=allow"];
        [w setSitePermission:@"location" value:nil forOrigin:@"https://example.org"];
        BOOL backToAsk = [w.siteSettingsRows containsObject:@"location=ask"];
        [w showSiteSettings:nil];  // toggles closed (animated)
        [w resetSitePermissions:nil];
        BOOL cleared = [w sitePermissionsForOrigin:@"https://example.org"].count == 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          std::printf("SELFTEST-SITESETTINGS shown=%d rows=%d stored=%d backToAsk=%d closed=%d reset=%d\n", shown, rowsOK, stored,
                      backToAsk, !w.siteSettingsShown, cleared);
        });
      });
    });
    // Paste and Go, Ctrl+Tab to the recent tab, Cmd+9 = last tab.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 34 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:@"  https://example.org/pasted \n" forType:NSPasteboardTypeString];
      [w pasteAndGo:nil];
      BOOL pasted = [w.shownItem.url isEqualToString:@"https://example.org/pasted"];
      ArcItem* a = w.shownItem;
      [w openInNewTab:@"https://example.org/recent-b"];
      ArcItem* b = w.shownItem;
      [w switchToRecentTab:nil];
      BOOL backToA = w.shownItem == a;
      [w switchToRecentTab:nil];
      BOOL backToB = w.shownItem == b;
      [w selectTabAtIndex:8];
      BOOL last = w.shownItem == w.currentSpace.allTabs.lastObject;
      std::printf("SELFTEST-QUICK pasteAndGo=%d recentTab=%d recentAgain=%d cmd9Last=%d\n", pasted, backToA, backToB, last);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      DownloadManager* dm = [DownloadManager shared];
      NSString* dir = [[ArchiveStorePath(YES) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"SelfTestDownloads"];
      [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
      dm.folderOverride = dir;
      NSString* url = @"https://github.com/Donnadieu/notarc/releases/download/v0.5.0/NotArc-0.5.0-arm64.dmg.sha256";
      [self.window startDownload:url];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [self.window startDownload:url];
      });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 14 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        NSArray* files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]
            sortedArrayUsingSelector:@selector(compare:)];
        NSUInteger done = 0;
        for (DownloadEntry* e in dm.entries) done += e.state == DownloadComplete;
        NSString* body = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"NotArc-0.5.0-arm64.dmg.sha256"]
                                                   encoding:NSUTF8StringEncoding error:nil];
        [dm showWindow];
        std::printf("SELFTEST-DOWNLOADS entries=%lu complete=%lu inProgress=%lu files=%s contentOK=%d filter=%lu filterNone=%lu\n",
                    (unsigned long)dm.entries.count, (unsigned long)done, (unsigned long)dm.inProgressCount,
                    [files componentsJoinedByString:@"|"].UTF8String, [body hasPrefix:@"88a4734e"],
                    (unsigned long)[dm entriesMatching:@"arm64"].count, (unsigned long)[dm entriesMatching:@"zzz"].count);
        [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
      });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 38 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      BOOL order = UpdaterCompareVersions(@"v0.10.0", @"0.9.3") == 1 && UpdaterCompareVersions(@"0.4", @"0.4.0") == 0 &&
                   UpdaterCompareVersions(@"0.4.0", @"0.4.1") == -1;
      NSDictionary* fake = @{@"tag_name" : @"v9.0.0", @"prerelease" : @NO, @"assets" : @[
        @{@"name" : @"NotArc-9.0.0-arm64.dmg", @"browser_download_url" : @"https://example.com/a.dmg"},
        @{@"name" : @"NotArc-9.0.0-arm64.dmg.sha256", @"browser_download_url" : @"https://example.com/a.dmg.sha256"}]};
      UpdateInfo* parsed = [Updater infoFromReleaseJSON:fake];
      NSMutableDictionary* pre = [fake mutableCopy];
      pre[@"prerelease"] = @YES;
      BOOL parse = [parsed.version isEqualToString:@"9.0.0"] && [parsed.dmgURL.absoluteString hasSuffix:@"a.dmg"] &&
                   ![Updater infoFromReleaseJSON:pre];
      [[Updater shared] fetchLatest:^(UpdateInfo* info, NSError* error) {
        std::printf("SELFTEST-UPDATER order=%d parse=%d current=%s latest=%s error=%s\n", order, parse,
                    UpdaterCurrentVersion().UTF8String, info.version.UTF8String ?: "-",
                    error.localizedDescription.UTF8String ?: "-");
        if (!info) return;
        [[Updater shared] prepareUpdate:info done:^(NSString* staged, NSError* err) {
          NSString* v = [NSDictionary dictionaryWithContentsOfFile:
                                          [staged stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleShortVersionString"];
          std::printf("SELFTEST-UPDATER staged=%d stagedVersion=%s checksumOK=%d error=%s\n", staged != nil,
                      v.UTF8String ?: "-", staged != nil, err.localizedDescription.UTF8String ?: "-");
          if (staged) [NSFileManager.defaultManager removeItemAtPath:staged.stringByDeletingLastPathComponent error:nil];
        }];
      }];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 36 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSUInteger visits = w.historyVisits.count;
      NSUInteger example = [w historyWindowCountForQuery:@"example"];
      NSUInteger none = [w historyWindowCountForQuery:@"zzz-no-such-page"];
      BOOL titled = NO;
      for (ArchivedTab* v in w.historyVisits) if ([v.title isEqualToString:@"Example Domain"]) titled = YES;
      [w clearHistory:nil];
      NSUInteger afterClear = w.historyVisits.count;
      {  // Import History from Arc, against a fake Arc History DB (never Arc's real one).
        NSString* db = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-history.db"];
        [[NSFileManager defaultManager] removeItemAtPath:db error:nil];
        sqlite3* h = NULL;
        sqlite3_open(db.UTF8String, &h);
        sqlite3_exec(h,
            "CREATE TABLE urls(id INTEGER PRIMARY KEY, url TEXT, title TEXT);"
            "CREATE TABLE visits(id INTEGER PRIMARY KEY, url INTEGER, visit_time INTEGER, transition INTEGER);"
            "INSERT INTO urls VALUES(1,'https://example.org/arc-1','Arc One'),(2,'https://example.org/frame','Frame'),"
            "(3,'https://example.org/redirect-hop','Hop');"
            "INSERT INTO visits VALUES(1,1,13300000000000000,1),(2,1,13300000060000000,0),(3,2,13300000070000000,3),"
            "(4,3,13300000080000000,268435456);", NULL, NULL, NULL);
        sqlite3_close(h);
        NSMutableDictionary* o = [NSMutableDictionary dictionary];
        for (ArcSpace* s in w.spaces) o[s.profileDirectory.length ? s.profileDirectory : @"Default"] = db;
        w.arcHistoryOverride = o;
        NSUInteger added = [w importArcHistory], again = [w importArcHistory];
        // #63: the same reader imports Chrome-family history; a fake DB here (never a real browser's).
        [w clearHistory:nil];
        NSUInteger otherAdded = [w importHistoryFromFile:db browser:@"Google Chrome (Test)"];
        NSUInteger otherAgain = [w importHistoryFromFile:db browser:@"Google Chrome (Test)"];
        BOOL otherTagged = NO;
        for (ArchivedTab* v in w.historyVisits) if ([v.reason isEqualToString:@"Google Chrome (Test)"]) otherTagged = YES;
        BOOL missing = [w importHistoryFromFile:@"/nonexistent/History" browser:@"x"] == 0;
        BOOL firefox = NO, safari = NO;
        {  // fake Firefox places.sqlite and Safari History.db (never the real ones)
          NSString* ff = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-places.sqlite"];
          NSString* sf = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-safari-history.db"];
          [NSFileManager.defaultManager removeItemAtPath:ff error:nil];
          [NSFileManager.defaultManager removeItemAtPath:sf error:nil];
          sqlite3* f = NULL;
          sqlite3_open(ff.UTF8String, &f);
          sqlite3_exec(f,
              "CREATE TABLE moz_places(id INTEGER PRIMARY KEY, url TEXT, title TEXT);"
              "CREATE TABLE moz_historyvisits(id INTEGER PRIMARY KEY, place_id INTEGER, visit_date INTEGER, visit_type INTEGER);"
              "INSERT INTO moz_places VALUES(1,'https://example.net/fox','Fox'),(2,'https://example.net/hop','Hop');"
              "INSERT INTO moz_historyvisits VALUES(1,1,1700000000000000,1),(2,2,1700000001000000,5);", NULL, NULL, NULL);
          sqlite3_close(f);
          sqlite3* s = NULL;
          sqlite3_open(sf.UTF8String, &s);
          sqlite3_exec(s,
              "CREATE TABLE history_items(id INTEGER PRIMARY KEY, url TEXT);"
              "CREATE TABLE history_visits(id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT,"
              " redirect_destination INTEGER);"
              "INSERT INTO history_items VALUES(1,'https://example.net/safari'),(2,'http://example.net/old');"
              "INSERT INTO history_visits VALUES(1,1,720000000.0,'Safari Page',NULL),(2,2,720000001.0,'Old',1);",
              NULL, NULL, NULL);
          sqlite3_close(s);
          NSUInteger nf = [w importHistoryFromFile:ff browser:@"Firefox (Test)" kind:@"firefox"];
          NSUInteger ns = [w importHistoryFromFile:sf browser:@"Safari (Test)" kind:@"safari"];
          BOOL foxDated = NO, safTitled = NO;
          for (ArchivedTab* v in w.historyVisits) {
            if ([v.url isEqualToString:@"https://example.net/fox"] && fabs(v.archivedAt.timeIntervalSince1970 - 1700000000) < 1)
              foxDated = YES;
            if ([v.url isEqualToString:@"https://example.net/safari"] && [v.title isEqualToString:@"Safari Page"] &&
                fabs(v.archivedAt.timeIntervalSinceReferenceDate - 720000000) < 1)
              safTitled = YES;
          }
          firefox = nf == 1 && foxDated;
          safari = ns == 1 && safTitled &&
                   [w importHistoryFromFile:@"/nonexistent/History.db" browser:@"Safari" kind:@"safari"] == NSNotFound;
          [NSFileManager.defaultManager removeItemAtPath:ff error:nil];
          [NSFileManager.defaultManager removeItemAtPath:sf error:nil];
        }
        std::printf("SELFTEST-IMPORTHISTORY added=%d again=%d tagged=%d missing=%d firefox=%d safari=%d\n", otherAdded == 2,
                    otherAgain == 0, otherTagged, missing, firefox, safari);
        [w clearHistory:nil];
        added = [w importArcHistory];
        NSUInteger arcRows = 0;
        for (ArchivedTab* v in w.historyVisits) if ([v.url hasPrefix:@"https://example.org/"]) ++arcRows;
        {  // Import Extensions from Arc, against a fake Arc profile (never Arc's real one).
          NSFileManager* fm = NSFileManager.defaultManager;
          NSString* fake = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-userdata"];
          NSString* dest = NotArcExtensionsDirectory(YES);
          [fm removeItemAtPath:fake error:nil];
          [fm removeItemAtPath:dest error:nil];
          NSString* prof = w.currentSpace.profileDirectory.length ? w.currentSpace.profileDirectory : @"Default";
          NSDictionary* exts = @{
            @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" : @"{\"manifest_version\":3,\"name\":\"Test Three\",\"version\":\"1.0\",\"key\":\"x\"}",
            @"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" : @"{\"manifest_version\":2,\"name\":\"Old Two\",\"version\":\"1.0\"}"};
          for (NSString* ident in exts) {
            for (NSString* ver in @[ @"0.9_0", @"1.10_0" ]) {
              NSString* d = [NSString stringWithFormat:@"%@/%@/Extensions/%@/%@", fake, prof, ident, ver];
              [fm createDirectoryAtPath:[d stringByAppendingPathComponent:@"_metadata"] withIntermediateDirectories:YES attributes:nil error:nil];
              [exts[ident] writeToFile:[d stringByAppendingPathComponent:@"manifest.json"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
              [ver writeToFile:[d stringByAppendingPathComponent:@"v.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
          }
          NSArray<ArcExtensionCopy*>* copies = [w importArcExtensionsInto:dest fromArcUserData:fake];
          NSArray* loadable = ArcCopiedExtensionPaths(dest);
          NSString* v = [NSString stringWithContentsOfFile:[dest stringByAppendingPathComponent:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/v.txt"]
                                                  encoding:NSUTF8StringEncoding error:nil];
          BOOL mv2Skipped = NO;
          for (ArcExtensionCopy* c in copies) if (c.skippedMV2 && [c.name isEqualToString:@"Old Two"]) mv2Skipped = YES;
          BOOL noMeta = ![fm fileExistsAtPath:[dest stringByAppendingPathComponent:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/_metadata"]];
          std::printf("SELFTEST-ARCEXTENSIONS copied=%d newest=%d mv2Skipped=%d noMetadata=%d\n", loadable.count == 1,
                      [v isEqualToString:@"1.10_0"], mv2Skipped, noMeta);
          // One button: history (fake DB still set up above) + extensions, in one call.
          [w clearHistory:nil];
          NSDictionary* all = [w importEverythingFromArcInto:dest userData:fake];
          std::printf("SELFTEST-IMPORTALL history=%d extensions=%d skipped=%d\n", [all[@"history"] intValue] == 2,
                      [all[@"extensions"] intValue] == 1, [all[@"skipped"] intValue] == 1);
          [w clearHistory:nil];
          [fm removeItemAtPath:fake error:nil];
          [fm removeItemAtPath:dest error:nil];
        }
        std::printf("SELFTEST-ARCHISTORY added=%d again0=%d onlyPages=%d\n", added == 2, again == 0, arcRows == 2);
        w.arcHistoryOverride = nil;
        [w clearHistory:nil];
        [[NSFileManager defaultManager] removeItemAtPath:db error:nil];
      }
      std::printf("SELFTEST-HISTORY visits=%lu matchExample=%lu matchNone=%lu titled=%d afterClear=%lu\n",
                  (unsigned long)visits, (unsigned long)example, (unsigned long)none, titled, (unsigned long)afterClear);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 32 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/menu-c"];
      [w openInNewTab:@"https://example.com/menu-b"];
      [w openInNewTab:@"https://example.com/menu-a"];
      NSMutableArray<ArcItem*>* today = w.currentSpace.unpinned.children;
      ArcItem* b = today[1];
      NSMutableArray* titles = [NSMutableArray array];
      for (NSMenuItem* mi in [w sidebarMenuForItem:b].itemArray) if (mi.title.length) [titles addObject:mi.title];
      BOOL menuOK = [titles containsObject:@"Rename..."] && [titles containsObject:@"Archive Tabs Below"] &&
                    [titles containsObject:@"Move to"] && [titles containsObject:@"Pin"];
      [w renameItem:b to:@"Renamed Tab"];
      BOOL renamed = [b.displayTitle isEqualToString:@"Renamed Tab"];
      ArcItem* dup = [w duplicateItem:b];
      BOOL dupPlaced = today.count > 2 && today[2] == dup && [dup.url isEqualToString:b.url];
      NSUInteger below = [w archiveTodayTabsRelativeTo:b mode:2];
      BOOL belowOK = [today indexOfObject:b] == today.count - 1;
      NSUInteger above = [w archiveTodayTabsRelativeTo:b mode:1];
      BOOL onlyB = today.count == 1 && today.firstObject == b;
      ArcSpace* from = w.currentSpace;
      ArcSpace* other = nil;
      for (ArcSpace* sp in w.spaces) if (sp != from && !other) other = sp;
      BOOL moved = [w moveItem:b toSpace:other pinned:NO];
      BOOL arrived = other.unpinned.children.firstObject == b && ![from.unpinned.children containsObject:b];
      [w handleLinkCommand:BrowserClient::kLinkBackgroundTab url:@"https://example.org/ctx" fromBrowser:w.shownItem.browserId];
      BOOL linkBg = [((ArcItem*)w.currentSpace.unpinned.children.firstObject).url isEqualToString:@"https://example.org/ctx"];
      [w handleLinkCommand:BrowserClient::kLinkCopyMarkdown url:@"https://example.org/md" fromBrowser:0];
      BOOL md = [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]
          isEqualToString:@"[https://example.org/md](https://example.org/md)"];
      std::printf("SELFTEST-MENUS sidebarMenu=%d renamed=%d duplicateBelow=%d archivedBelow=%lu belowOK=%d "
                  "archivedAbove=%lu onlyLeft=%d movedToSpace=%d arrived=%d linkBackgroundTab=%d linkMarkdown=%d\n",
                  menuOK, renamed, dupPlaced, (unsigned long)below, belowOK, (unsigned long)above, onlyB, moved,
                  arrived, linkBg, md);
      {  // #13: Move to Favorites / Remove from Favorites / Move to Pinned, from the menus and the File menu action
        ArcSpace* sp = w.currentSpace;
        [w openInNewTab:@"https://example.org/fav-move"];
        ArcItem* t = sp.unpinned.children.firstObject;
        NSMutableArray* sub = [NSMutableArray array];
        for (NSMenuItem* mi in [w sidebarMenuForItem:t].itemArray)
          if ([mi.title isEqualToString:@"Move to"]) for (NSMenuItem* s2 in mi.submenu.itemArray) [sub addObject:s2.title];
        BOOL offered = [sub containsObject:@"Favorites"];
        NSUInteger favBefore = sp.favorites.children.count;
        BOOL moved = [w moveItemToFavorites:t] && sp.favorites.children.lastObject == t &&
                     ![sp.unpinned.children containsObject:t] && [w.favoriteTileTitles count] == favBefore + 1 &&
                     [t.pinnedURL hasPrefix:@"https://example.org/fav-move"];
        NSMutableArray* favMenu = [NSMutableArray array];
        for (NSMenuItem* mi in [w sidebarMenuForItem:t].itemArray) [favMenu addObject:mi.title];
        BOOL favMenuOK = [favMenu containsObject:@"Remove from Favorites"] && [favMenu containsObject:@"Move to Pinned"];
        BOOL toPinned = [w removeItemFromFavorites:t pinned:YES] && [sp.pinned.children containsObject:t] &&
                        sp.favorites.children.count == favBefore;
        [w moveItem:t toParent:sp.unpinned index:0];
        [w showItem:t];
        [w toggleFavorite:nil];
        BOOL action = [sp.favorites.children containsObject:t];
        [w toggleFavorite:nil];
        BOOL removed = sp.unpinned.children.firstObject == t && sp.favorites.children.count == favBefore && !t.pinnedURL;
        [w deleteSidebarItem:t];
        std::printf("SELFTEST-FAVORITES offered=%d moved=%d menu=%d toPinned=%d action=%d removed=%d\n", offered, moved,
                    favMenuOK, toPinned, action, removed);
      }
      {  // #18 Tidy tab titles (no AI): the pure function on real-world title shapes, then pin -> tidy -> undo.
        struct { NSString *in, *host, *out; } cases[] = {
            {@"Pull requests · GitHub", @"github.com", @"Pull requests"},
            {@"Inbox (3) - someone@example.com - Gmail", @"mail.google.com", @"Inbox"},
            {@"(12) Home / X", @"x.com", @"Home / X"},
            {@"Project plan - Google Docs", @"docs.google.com", @"Project plan"},
            {@"How to tie a tie - YouTube", @"www.youtube.com", @"How to tie a tie"},
            {@"Example Domain", @"example.com", @"Example Domain"},
            {@"Hacker News", @"news.ycombinator.com", @"Hacker News"},
            {@"Self-driving cars | The Verge", @"www.theverge.com", @"Self-driving cars"},
        };
        int good = 0, n = sizeof(cases) / sizeof(cases[0]);
        for (int i = 0; i < n; ++i) {
          NSString* got = TidyTabTitle(cases[i].in, cases[i].host);
          if ([got isEqualToString:cases[i].out]) ++good;
          else std::printf("SELFTEST-TIDY-DEBUG in=[%s] got=[%s]\n", cases[i].in.UTF8String, got.UTF8String);
        }
        ArcSpace* sp = w.currentSpace;
        [w openInNewTab:@"https://example.org/tidy"];
        ArcItem* t = sp.unpinned.children.firstObject;
        t.liveTitle = @"(2) Tidy me - Example";
        [w showItem:t];
        [w togglePin:nil];
        BOOL pinned = [sp.pinned.children containsObject:t];
        BOOL tidied = pinned && t.renamed && [t.displayTitle isEqualToString:@"Tidy me"];
        t.liveTitle = @"(3) Tidy me - Example";  // the page's own title changes: the tidy name sticks
        BOOL sticks = [t.displayTitle isEqualToString:@"Tidy me"];
        [w usePageTitleOfItem:t];
        BOOL undone = !t.renamed && [t.displayTitle isEqualToString:@"(3) Tidy me - Example"];
        [w renameItem:t to:@"My name"];
        t.liveTitle = @"Something else";
        BOOL renameSticks = [t.displayTitle isEqualToString:@"My name"];
        [w deleteSidebarItem:t];
        std::printf("SELFTEST-TIDY cases=%d pinned=%d tidied=%d sticks=%d undo=%d renameSticks=%d\n", good == n, pinned,
                    tidied, sticks, undone, renameSticks);
      }
      [w saveSidebarNow];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 29 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
      BOOL defaultsOK = SettingDouble(kSettingAutoArchiveHours) == 12 && SettingBool(kSettingPeekPinnedLinks) &&
                        SettingBool(kSettingPeekShiftClick) && SettingDouble(kSettingLittleArchiveHours) == 6;
      // Use the volatile domain so the self-test never changes the user's real settings.
      [d setVolatileDomain:@{kSettingSearchEngine : @"duckduckgo", kSettingPeekShiftClick : @NO,
                             kSettingPeekPinnedLinks : @NO}
                   forName:NSArgumentDomain];
      BOOL ddg = [ResolveCommandBarInput(@"notarc browser") hasPrefix:@"https://duckduckgo.com/?q=notarc"];
      int shown = w.shownItem.browserId;
      [w openInNewTab:@"https://example.com/settings-base"];
      shown = w.shownItem.browserId;
      NSUInteger todayBefore = w.currentSpace.unpinned.children.count;
      BOOL shiftHandled = [w handleOpenURL:@"https://example.net/s" fromBrowser:shown disposition:CEF_WOD_NEW_WINDOW
                               userGesture:YES];
      BOOL shiftWentToTab = shiftHandled && ![w isPeeking];
      [d setVolatileDomain:@{} forName:NSArgumentDomain];
      BOOL restored = [ResolveCommandBarInput(@"x y") hasPrefix:@"https://www.google.com/"];
      [w openLittleWindow:@"https://example.org/idle-little"];
      NSUInteger before = [w littleWindowCount];
      [w setLittleWindowLastUsed:[NSDate dateWithTimeIntervalSinceNow:-7 * 3600] index:before - 1];
      NSUInteger idleClosed = [w archiveIdleLittleWindowsAt:[NSDate date]];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        std::printf("SELFTEST-SETTINGS defaults=%d searchEngine=%d restored=%d shiftPeekOffOpensTab=%d todayDelta=%ld "
                    "idleLittleClosed=%lu lastReason=%s\n", defaultsOK, ddg, restored, shiftWentToTab,
                    (long)(w.currentSpace.unpinned.children.count - todayBefore), (unsigned long)idleClosed,
                    ((ArchivedTab*)[w archivedTabs].lastObject).reason.UTF8String);
      });
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      [w openInNewTab:@"https://example.com/split-base"];  // Favorites can't hold splits, so start from Today
      ArcItem* base = w.shownItem;
      [w openInSplit:@"https://example.com/left" horizontal:NO before:YES];
      BOOL leftIdxOK = [w splitGroupOfShown] != nil && [w indexOfShownInSplit] == 0 &&
                       [w splitGroupOfShown].children[1] == base;
      [w openInSplit:@"https://example.com/top" horizontal:YES before:YES];
      NSArray<NSValue*>* f = [w paneFrames];
      BOOL stacked = f.count == 3 && NSMinY(f[0].rectValue) >= NSMaxY(f[1].rectValue);
      [w flipSplitLayout:nil];
      NSArray<NSValue*>* g = [w paneFrames];
      BOOL flipped = g.count == 3 && NSMaxX(g[0].rectValue) <= NSMinX(g[1].rectValue);
      ArcItem* group = [w splitGroupOfShown];
      BOOL oneItem = group.isSplit && group.children.count == 3 &&
                     [w.currentSpace.unpinned.children containsObject:group];
      NSUInteger dividers = [w dividerCount];
      [w moveDivider:0 toPosition:0.5];
      NSArray<NSValue*>* h = [w paneFrames];
      CGFloat total = h.count == 3 ? NSMaxX(h[2].rectValue) : 1;
      BOOL resized = h.count == 3 && fabs(h[0].rectValue.size.width / total - 0.5) < 0.03;
      [w saveSidebarNow];
      NSString* focused = nil;
      NSArray<ArcSpace*>* saved = SidebarStoreLoad(w.storePath, &focused, nil);
      BOOL persisted = NO;
      for (ArcSpace* sp in saved)
        for (ArcItem* it in sp.unpinned.children)
          if (it.isSplit && it.children.count == 3 && it.splitFractions.count == 3 &&
              fabs(it.splitFractions[0].doubleValue - 0.5) < 0.03)
            persisted = YES;
      std::printf("SELFTEST-SPLIT3 oneSidebarItem=%d dividers=%lu dragResized=%d persisted=%d\n", oneItem,
                  (unsigned long)dividers, resized, persisted);
      [w closeSplitPane:nil];
      [w closeSplitPane:nil];
      std::printf("SELFTEST-SPLIT3 dissolved=%d separatedKept=%d\n", [w splitGroupOfShown] == nil,
                  [w.currentSpace.allTabs containsObject:w.shownItem]);
      int shown = w.shownItem.browserId;
      NSUInteger todayBefore = w.currentSpace.unpinned.children.count;
      BOOL peekHandled = [w handleOpenURL:@"https://example.net/shift" fromBrowser:shown disposition:CEF_WOD_NEW_WINDOW
                              userGesture:YES];
      BOOL bgHandled = [w handleOpenURL:@"https://example.net/cmd" fromBrowser:shown
                            disposition:CEF_WOD_NEW_BACKGROUND_TAB userGesture:YES];
      BOOL unknownIgnored = ![w handleOpenURL:@"https://example.net/x" fromBrowser:-1 disposition:CEF_WOD_NEW_WINDOW
                                  userGesture:YES];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        std::printf("SELFTEST-SPLIT2 leftInsertedBefore=%d topStacked=%d flipped=%d\n", leftIdxOK, stacked, flipped);
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
- (IBAction)showDownloads:(id)sender { [[DownloadManager shared] showWindow]; }

- (IBAction)checkForUpdates:(id)sender { [[Updater shared] checkInteractive:YES]; }

- (IBAction)showAirTrafficControl:(id)sender { [self.window showAirTrafficControl:sender]; }

- (IBAction)showKeyboardShortcuts:(id)sender {
  [[ShortcutsWindowController shared] showWindow:nil];
  [[ShortcutsWindowController shared].window makeKeyAndOrderFront:nil];
}

- (IBAction)showSettings:(id)sender {
  [[SettingsWindowController shared] showWindow:nil];
  [[SettingsWindowController shared].window makeKeyAndOrderFront:nil];
}

// The app a link came from (Air Traffic Control can route by source app), from the open-URL Apple event.
static NSString* SourceAppOfCurrentEvent() {
  NSAppleEventDescriptor* ev = NSAppleEventManager.sharedAppleEventManager.currentAppleEvent;
  NSAppleEventDescriptor* pidDesc = [[ev attributeDescriptorForKeyword:keySenderPIDAttr] coerceToDescriptorType:typeSInt32];
  pid_t pid = pidDesc ? (pid_t)pidDesc.int32Value : 0;
  return pid > 0 ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid].bundleIdentifier : nil;
}

- (void)application:(NSApplication*)app openURLs:(NSArray<NSURL*>*)urls {
  NSString* source = SourceAppOfCurrentEvent();
  for (NSURL* url in urls) {
    if (!self.window) {
      if (!self.pendingURLs) self.pendingURLs = [NSMutableArray array];
      [self.pendingURLs addObject:url.absoluteString];
      if (source) self.pendingSource = source;
    } else {
      [self.window routeExternalLink:url.absoluteString sourceApp:source];
    }
  }
}
@end

// --self-update-test: run from a throwaway copy of NotArc. Pretends to be 0.0.1, downloads and verifies the
// latest release, swaps it into this copy after exiting (no relaunch). The caller checks the copy's version.
static int RunSelfUpdateTest() {
  @autoreleasepool {
    [Updater setVersionOverride:@"0.0.1"];
    __block int rc = 1;
    [[Updater shared] fetchLatest:^(UpdateInfo* info, NSError* error) {
      std::printf("UPDATETEST latest=%s error=%s\n", info.version.UTF8String ?: "-", error.localizedDescription.UTF8String ?: "-");
      if (!info || UpdaterCompareVersions(info.version, UpdaterCurrentVersion()) <= 0) return CFRunLoopStop(CFRunLoopGetMain());
      [[Updater shared] prepareUpdate:info done:^(NSString* staged, NSError* err) {
        std::printf("UPDATETEST staged=%d error=%s\n", staged != nil, err.localizedDescription.UTF8String ?: "-");
        if (staged) {
          [[Updater shared] swapInStagedApp:staged relaunch:NO];
          rc = 0;
        }
        CFRunLoopStop(CFRunLoopGetMain());
      }];
    }];
    CFRunLoopRun();
    std::fflush(stdout);
    return rc;  // exiting lets the swap script replace this bundle
  }
}

int main(int argc, char* argv[]) {
  for (int i = 1; i < argc; ++i) {
    if (std::string(argv[i]) == "--self-update-test") return RunSelfUpdateTest();
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

  // Self-test runs use a throwaway in-memory key for Chromium's cookie encryption instead of the
  // "Chromium Safe Storage" Keychain item, so repeated test runs never show Keychain prompts.
  std::vector<char*> args(argv, argv + argc);
  static char mockKeychain[] = "--use-mock-keychain";
  static char autoplay[] = "--autoplay-policy=no-user-gesture-required";  // media test plays without a click
  static char fakeDevices[] = "--use-fake-device-for-media-stream";  // site-prompt test never touches a real mic
  static char noOcclusion[] = "--disable-backgrounding-occluded-windows";  // hidden test windows still render
  static char noBackground[] = "--disable-renderer-backgrounding";
  static char noMediaSuspend[] = "--disable-background-media-suspend";  // media test plays in the hidden window
  static char noTimerThrottle[] = "--disable-background-timer-throttling";
  static char noMacOcclusion[] = "--disable-features=MacWebContentsOcclusion";  // pages in hidden test windows stay "visible"
  for (int i = 1; i < argc; ++i)
    if (std::string(argv[i]) == "--selftest" || std::string(argv[i]) == "--selftest-reload" ||
        std::string(argv[i]).rfind("--sidebar-snapshot=", 0) == 0) {
      args.push_back(mockKeychain);
      args.push_back(autoplay);
      args.push_back(fakeDevices);
      args.push_back(noOcclusion);
      args.push_back(noBackground);
      args.push_back(noMediaSuspend);
      args.push_back(noTimerThrottle);
      args.push_back(noMacOcclusion);
      break;
    }
  // Chrome-style pages (#66) load the extensions copied from Arc. Chromium keeps only the last --disable-features,
  // so the self-test's occlusion switch is folded in here.
  static std::string loadExt, features;
  {
    BOOL testRun = NO;
    for (char* a : args) if (a == noMacOcclusion) testRun = YES;
    NSArray<NSString*>* paths = ChromePagesEnabled() ? ArcCopiedExtensionPaths(NotArcExtensionsDirectory(testRun)) : @[];
    if (paths.count) {
      loadExt = std::string("--load-extension=") + [paths componentsJoinedByString:@","].UTF8String;
      features = std::string("--disable-features=DisableLoadExtensionCommandLineSwitch") +
                 (testRun ? ",MacWebContentsOcclusion" : "");
      for (auto& a : args) if (a == noMacOcclusion) a = features.data();
      if (!testRun) args.push_back(features.data());
      args.push_back(loadExt.data());
    }
  }
  args.push_back(nullptr);
  argc = static_cast<int>(args.size()) - 1;
  argv = args.data();

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
    NSString* snapshotPath = nil;
    for (int i = 1; i < argc; ++i)
      if (std::string(argv[i]).rfind("--sidebar-snapshot=", 0) == 0) {
        selfTest = YES;  // same isolation as the self-test: test profiles, mock Keychain, hidden window
        snapshotPath = [NSString stringWithUTF8String:argv[i] + strlen("--sidebar-snapshot=")];
      }

    CefSettings settings;
    settings.no_sandbox = true;
    NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES)
                             .firstObject stringByAppendingPathComponent:@"NotArc"];
    NSString* cache = [support stringByAppendingPathComponent:selfTest ? @"SelfTestProfile" : @"Default"];
    [[NSFileManager defaultManager] createDirectoryAtPath:cache withIntermediateDirectories:YES attributes:nil error:nil];
    CefString(&settings.root_cache_path) = support.UTF8String;
    CefString(&settings.cache_path) = cache.UTF8String;
    // Keep session-only logins across restarts, as Arc and Chrome do with "continue where you left off".
    settings.persist_session_cookies = true;

    if (!CefInitialize(main_args, settings, nullptr, nullptr)) return CefGetExitCode();
    SettingsRegisterDefaults();
    if (selfTest) SettingsUseMemoryOnly();
    ApplyContentBlockerSettings();

    AppDelegate* delegate = [AppDelegate new];
    delegate.selfTest = selfTest;
    delegate.selfTestReload = selfTestReload;
    delegate.snapshotPath = snapshotPath;
    NSApp.delegate = delegate;
    [delegate performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];

    CefRunMessageLoop();
    SessionMarkerEnd(selfTest);  // reached only on a clean quit; a crash or force-quit leaves the marker
    CefShutdown();
  }
  return 0;
}
