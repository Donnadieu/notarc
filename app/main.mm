#import <QuartzCore/QuartzCore.h>
// NotArc browser process entry point.
#import <Cocoa/Cocoa.h>

#include <objc/runtime.h>
#include <cstdio>
#include <string>
#include <vector>

#import "app/floating_video.h"
#import "app/arc_import.h"
#import "app/arc_alert.h"
#import "app/theme_picker.h"
#import "app/welcome.h"
#import "app/main_window.h"
#import "app/tidy_title.h"
#import "app/global_hotkey.h"
#import "app/email_peek.h"
#import "app/visual_shots.h"
#import "app/library_panel.h"
#import "app/web_notifications.h"
#import "app/calendar_preview.h"
#import "app/main_window_max.h"
#import "app/arc_max.h"
#import "app/little_window.h"
#import "app/arc_extensions.h"
#import "app/extensions.h"
#import "app/extension_popup.h"
#import "app/link_routing.h"
#import "app/link_routing_editor.h"
#import "app/bookmark_import.h"
#import "app/shortcuts.h"
#import "app/chrome_page.h"
#include <sqlite3.h>
#import <CommonCrypto/CommonCrypto.h>
#import "app/boost_store.h"
#import "app/boost_color_wheel.h"
#import "app/easel.h"
#import "app/note_editor.h"
#import "app/easel_clip.h"
#import "app/live_folder.h"
#import "app/settings.h"
#import "app/test_isolation.h"
#import "app/app_icons.h"
#include "app/content_blocker.h"
#import "app/filter_lists.h"
#import "app/ad_blockers_window.h"
#include "app/browser_client.h"
#import "app/history_store.h"
#import "app/updater.h"
#import "app/downloads.h"
#import "app/sidebar_store.h"
#import "app/archive_store.h"
#import "app/arc_cookies.h"
#import "app/tab_thumbnails.h"
#import "app/autofill.h"
#import "app/password_store.h"
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
    ArcAlert* a = [ArcAlert new];
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
@property(nonatomic) BOOL freshInstall;  // no saved sidebar yet: the welcome shows (V56)
@property(nonatomic, copy) NSString* visualPlan;  // --visual-shots=<plan>: hidden design renders (app/visual_shots.h)
@property(nonatomic, copy) NSString* pendingSource;
@property(nonatomic, strong) NSMutableArray<NSString*>* pendingURLs;  // links that arrived before the window
@end

static BOOL gCrashTestDone = NO;
static BOOL gMaxTestDone = NO;    // self-test: the Arc Max checks (#58, #59) printed
// Self-test fixture extension (#66): popup and options pages with known titles, no scripts.
static NSString* gTestExtensionID;  // installed and loaded at launch in every test run
static NSData* TestExtensionIconPNG(void) {  // a 16 px blue square: the fixture's own toolbar icon (V69)
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:16 pixelsHigh:16 bitsPerSample:8
                                                             samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                              colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  for (int y = 0; y < 16; ++y)
    for (int x = 0; x < 16; ++x) [rep setColor:[NSColor colorWithDeviceRed:0.2 green:0.4 blue:0.9 alpha:1] atX:x y:y];
  return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}
static NSDictionary<NSString*, NSData*>* TestExtensionFiles(NSString* name, int manifestVersion) {
  NSString* manifest = [NSString stringWithFormat:@"{\"manifest_version\":%d,\"name\":\"%@\",\"version\":\"1.2\",\"icons\":{\"16\":\"icon.png\"},"
                                                  @"\"action\":{\"default_popup\":\"popup.html\"},\"options_page\":\"options.html\"}",
                                                  manifestVersion, name];
  return @{
    @"manifest.json" : [manifest dataUsingEncoding:NSUTF8StringEncoding],
    @"icon.png" : TestExtensionIconPNG(),
    @"popup.html" : [@"<!doctype html><title>NotArc Extension Popup</title><div style=\"width:240px;height:120px\">popup</div>"
                      dataUsingEncoding:NSUTF8StringEncoding],
    @"options.html" : [@"<!doctype html><title>NotArc Extension Options</title><p>options</p>" dataUsingEncoding:NSUTF8StringEncoding],
  };
}
static void InstallSelfTestExtension(NSString* dir) {
  [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
  NSString* extID = nil;
  NSData* crx = BuildTestCRX(TestExtensionFiles(@"NotArc Test Extension", 3), &extID);
  if (crx && InstallExtensionCRX(crx, extID, dir, nil)) gTestExtensionID = extID;
}
static BOOL gAdBlockTestDone = NO;  // self-test: the filter-list page check (#53) printed
static BOOL gEaselToolsDone = NO;  // self-test: the easel tools check printed (#49)
static BOOL gLateTestsDone = NO;  // self-test: the last chained page checks (call, capture, PiP) printed  // self-test: the hang check finished (later page tests wait for it)

// Self-test: poll a condition every 0.25 s instead of a fixed wait, then continue (also on timeout).
static void WaitUntil(BOOL (^cond)(void), double timeoutSec, void (^then)(void)) {
  if (cond() || timeoutSec <= 0) { then(); return; }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    WaitUntil(cond, timeoutSec - 0.25, then);
  });
}

// Hidden runs: any window that comes onto a screen (Chromium's own picture-in-picture window included) is 1% opaque
// and click-through before it's ordered in, so it never flashes on Omar's screen. Windows parked far off every screen
// (visual renders) keep the alpha they're given.
static IMP gOrderWindowIMP, gSetAlphaIMP;
static BOOL OnSomeScreen(NSWindow* w) { return NSMaxX(w.frame) > -10000 && NSMaxY(w.frame) > -10000; }
static void HiddenSetAlpha(NSWindow* w, SEL sel, CGFloat a) {
  if (a > 0.011 && OnSomeScreen(w)) a = 0.01;
  ((void (*)(id, SEL, CGFloat))gSetAlphaIMP)(w, sel, a);
}
static void HiddenOrderWindow(NSWindow* w, SEL sel, NSWindowOrderingMode mode, NSInteger rel) {
  if (mode != NSWindowOut && OnSomeScreen(w)) {
    ((void (*)(id, SEL, CGFloat))gSetAlphaIMP)(w, @selector(setAlphaValue:), 0.01);
    w.ignoresMouseEvents = YES;
  }
  ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))gOrderWindowIMP)(w, sel, mode, rel);
}
static void KeepTestWindowsHidden(void) {
  if (gOrderWindowIMP) return;
  gSetAlphaIMP = method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(setAlphaValue:)), (IMP)HiddenSetAlpha);
  gOrderWindowIMP = method_setImplementation(class_getInstanceMethod(NSWindow.class, @selector(orderWindow:relativeTo:)),
                                             (IMP)HiddenOrderWindow);
}


// Self-test fixtures for password import (#67): Chromium-format "Login Data" and "Web Data" files encrypted with a
// throwaway key, never a real browser's.
static void SelfTestExec(sqlite3* db, NSString* sql, NSArray* binds) {
  sqlite3_stmt* st = NULL;
  if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) return;
  int i = 1;
  for (id b in binds) {
    if ([b isKindOfClass:NSData.class]) sqlite3_bind_blob(st, i, [b bytes], (int)[b length], SQLITE_TRANSIENT);
    else if ([b isKindOfClass:NSNumber.class]) sqlite3_bind_int64(st, i, [b longLongValue]);
    else sqlite3_bind_text(st, i, [b UTF8String], -1, SQLITE_TRANSIENT);
    ++i;
  }
  sqlite3_step(st);
  sqlite3_finalize(st);
}

static void SelfTestMakeLoginData(NSString* path, NSData* key, NSArray<NSArray*>* rows) {  // [realm, user, pw|nil=never]
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  sqlite3* db = NULL;
  sqlite3_open(path.UTF8String, &db);
  sqlite3_exec(db, "CREATE TABLE logins(origin_url TEXT, action_url TEXT, username_element TEXT, username_value TEXT,"
                   " password_element TEXT, password_value BLOB, signon_realm TEXT, date_created INTEGER,"
                   " blacklisted_by_user INTEGER)", NULL, NULL, NULL);
  for (NSArray* r in rows) {
    BOOL never = [r[2] isKindOfClass:NSNull.class];
    NSData* pw = never ? [NSData data] : [r[2] isKindOfClass:NSData.class] ? r[2]
                                                                          : ChromiumEncryptValue([r[2] dataUsingEncoding:NSUTF8StringEncoding], key);
    SelfTestExec(db, @"INSERT INTO logins VALUES(?,?,?,?,?,?,?,?,?)",
                 @[ [r[0] stringByAppendingString:@"login"], r[0], @"u", r[1], @"p", pw, r[0], @13300000000000000, @(never) ]);
  }
  sqlite3_close(db);
}

// Arc-format (Chromium DB version 24) "Cookies": each row is [host_key, name, value, path, secure, httponly, samesite,
// expires (seconds from now, 0 = session), key (nil = stored unencrypted)]. v24 values carry SHA-256(host) first.
static void SelfTestMakeCookies(NSString* path, NSArray<NSArray*>* rows) {
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  sqlite3* db = NULL;
  sqlite3_open(path.UTF8String, &db);
  sqlite3_exec(db, "CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);"
                   "INSERT INTO meta VALUES('version','24');"
                   "CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL, top_frame_site_key TEXT NOT NULL,"
                   " name TEXT NOT NULL, value TEXT NOT NULL, encrypted_value BLOB NOT NULL, path TEXT NOT NULL,"
                   " expires_utc INTEGER NOT NULL, is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,"
                   " last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL, is_persistent INTEGER NOT NULL,"
                   " priority INTEGER NOT NULL, samesite INTEGER NOT NULL, source_scheme INTEGER NOT NULL,"
                   " source_port INTEGER NOT NULL, last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,"
                   " has_cross_site_ancestor INTEGER NOT NULL)", NULL, NULL, NULL);
  int64_t now = (int64_t)(([[NSDate date] timeIntervalSince1970] + 11644473600.0) * 1e6);
  for (NSArray* r in rows) {
    NSString* host = r[0];
    NSData* key = [r[8] isKindOfClass:NSData.class] ? r[8] : nil;
    NSMutableData* plain = [NSMutableData dataWithLength:CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(host.UTF8String, (CC_LONG)strlen(host.UTF8String), (uint8_t*)plain.mutableBytes);
    [plain appendData:[r[2] dataUsingEncoding:NSUTF8StringEncoding]];
    int64_t expires = [r[7] longLongValue] ? now + [r[7] longLongValue] * 1000000LL : 0;
    // An empty NSData binds as NULL, which encrypted_value refuses, so unencrypted rows use a literal X''.
    NSString* enc = key ? @"?" : @"X''";
    NSMutableArray* binds = [@[ @(now - 86400000000LL), host, r[1], key ? @"" : r[2] ] mutableCopy];
    if (key) [binds addObject:ChromiumEncryptValue(plain, key)];
    [binds addObjectsFromArray:@[ r[3], @(expires), r[4], r[5], @(now), @(expires != 0), @(expires != 0), r[6], @(now) ]];
    SelfTestExec(db, [NSString stringWithFormat:@"INSERT INTO cookies VALUES(?,?,'',?,?,%@,?,?,?,?,?,?,?,1,?,2,443,?,0,0)", enc],
                 binds);
  }
  sqlite3_close(db);
}

static void SelfTestMakeWebData(NSString* path, NSData* key, BOOL typeTokens, NSDictionary* a, NSArray* card) {
  [NSFileManager.defaultManager removeItemAtPath:path error:nil];
  sqlite3* db = NULL;
  sqlite3_open(path.UTF8String, &db);
  if (typeTokens) {  // Chrome 113+
    sqlite3_exec(db, "CREATE TABLE local_addresses(guid TEXT); CREATE TABLE local_addresses_type_tokens(guid TEXT, type INTEGER,"
                     " value TEXT)", NULL, NULL, NULL);
    SelfTestExec(db, @"INSERT INTO local_addresses VALUES('g1')", @[]);
    NSDictionary* types = @{@"name" : @7, @"line1" : @30, @"city" : @33, @"state" : @34, @"zip" : @35, @"email" : @9};
    for (NSString* k in a) SelfTestExec(db, @"INSERT INTO local_addresses_type_tokens VALUES('g1',?,?)", @[ types[k], a[k] ]);
  } else {  // older Chrome and Arc
    sqlite3_exec(db, "CREATE TABLE autofill_profiles(guid TEXT, company_name TEXT, street_address TEXT, city TEXT, state TEXT,"
                     " zipcode TEXT, country_code TEXT); CREATE TABLE autofill_profile_names(guid TEXT, first_name TEXT,"
                     " middle_name TEXT, last_name TEXT, full_name TEXT); CREATE TABLE autofill_profile_emails(guid TEXT,"
                     " email TEXT); CREATE TABLE autofill_profile_phones(guid TEXT, number TEXT)", NULL, NULL, NULL);
    SelfTestExec(db, @"INSERT INTO autofill_profiles VALUES('g1','',?,?,?,?,'US')", @[ a[@"line1"], a[@"city"], a[@"state"], a[@"zip"] ]);
    NSArray* name = [a[@"name"] componentsSeparatedByString:@" "];
    SelfTestExec(db, @"INSERT INTO autofill_profile_names VALUES('g1',?,'',?,?)", @[ name[0], name[1], a[@"name"] ]);
    SelfTestExec(db, @"INSERT INTO autofill_profile_emails VALUES('g1',?)", @[ a[@"email"] ]);
  }
  sqlite3_exec(db, "CREATE TABLE credit_cards(guid TEXT, name_on_card TEXT, expiration_month INTEGER, expiration_year INTEGER,"
                   " card_number_encrypted BLOB, nickname TEXT)", NULL, NULL, NULL);
  SelfTestExec(db, @"INSERT INTO credit_cards VALUES('c1',?,?,?,?,'')",
               @[ card[0], card[1], card[2], ChromiumEncryptValue([card[3] dataUsingEncoding:NSUTF8StringEncoding], key) ]);
  sqlite3_close(db);
}

@implementation AppDelegate

- (void)buildMenu {
  NSMenu* bar = [NSMenu new];
  NSMenuItem* appItem = [NSMenuItem new];
  [bar addItem:appItem];
  NSMenu* appMenu = [NSMenu new];
  [appMenu addItemWithTitle:@"Check for Updates..." action:@selector(checkForUpdates:) keyEquivalent:@""];
  [appMenu addItemWithTitle:@"Settings..." action:@selector(showSettings:) keyEquivalent:@","];
  [appMenu addItemWithTitle:@"Passwords..." action:@selector(showPasswords:) keyEquivalent:@""];
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
  NSMenuItem* autoFillItem = [edit addItemWithTitle:@"AutoFill" action:nil keyEquivalent:@""];
  NSMenu* autoFill = [[NSMenu alloc] initWithTitle:@"AutoFill"];
  [autoFill addItemWithTitle:@"Fill Password" action:@selector(fillPassword:) keyEquivalent:@"\\"];
  [autoFill addItemWithTitle:@"Passwords..." action:@selector(showPasswords:) keyEquivalent:@""];
  autoFillItem.submenu = autoFill;
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
  [file addItemWithTitle:@"Export Note as Markdown..." action:@selector(exportNoteAsMarkdown:) keyEquivalent:@""];
  [file addItemWithTitle:@"Copy Note as Markdown" action:@selector(copyNoteAsMarkdown:) keyEquivalent:@""];
  [file addItem:NSMenuItem.separatorItem];
  [file addItemWithTitle:@"Import Everything from Arc..." action:@selector(importEverythingFromArcMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import Bookmarks..." action:@selector(importBookmarksFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import History..." action:@selector(importHistoryFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import Passwords..." action:@selector(importPasswordsFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import History from Arc" action:@selector(importArcHistoryFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Import Extensions from Arc" action:@selector(importArcExtensionsFromMenu:) keyEquivalent:@""];
  [file addItemWithTitle:@"Install Extension..." action:@selector(installExtension:) keyEquivalent:@""];
  [file addItemWithTitle:@"Manage Extensions" action:@selector(manageExtensions:) keyEquivalent:@""];  // chrome://extensions
  [file addItemWithTitle:@"Capture to Easel" action:@selector(captureToEasel:) keyEquivalent:@"2"].keyEquivalentModifierMask =
      NSEventModifierFlagCommand | NSEventModifierFlagShift;
  [file addItemWithTitle:@"Add Text to Easel" action:@selector(addEaselText:) keyEquivalent:@""];
  [file addItemWithTitle:@"Capture Area to Easel" action:@selector(captureAreaToEasel:) keyEquivalent:@""];
  [file addItemWithTitle:@"Capture Full Page to Easel" action:@selector(captureFullPageToEasel:) keyEquivalent:@""];
  [file addItemWithTitle:@"Add Live Clip to Easel" action:@selector(liveClipToEasel:) keyEquivalent:@""];
  [file addItemWithTitle:@"Refresh Live Clips" action:@selector(refreshLiveClipsFromMenu:) keyEquivalent:@""];
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

  // Format (Notes): bold, italic, underline and fonts come from AppKit's text system; the rest from the note editor.
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
  // The note toolbar's commands (sent to the note being edited): paragraph style, strikethrough, lists, link.
  [format addItem:[NSMenuItem separatorItem]];
  [format addItemWithTitle:@"Strikethrough" action:@selector(noteToggleStrikethrough:) keyEquivalent:@""];
  for (NSArray* e in @[ @[ @"Body", @0 ], @[ @"Heading 1", @1 ], @[ @"Heading 2", @2 ], @[ @"Heading 3", @3 ] ])
    [format addItemWithTitle:e[0] action:@selector(noteFormatBlock:) keyEquivalent:@""].tag = [e[1] integerValue];
  [format addItemWithTitle:@"Bulleted List" action:@selector(noteToggleBulletList:) keyEquivalent:@""];
  [format addItemWithTitle:@"Numbered List" action:@selector(noteToggleNumberedList:) keyEquivalent:@""];
  [format addItemWithTitle:@"Checklist" action:@selector(noteToggleChecklist:) keyEquivalent:@""];
  [format addItemWithTitle:@"Add Link..." action:@selector(noteAddLink:) keyEquivalent:@""];
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
  [view addItemWithTitle:@"Turn On Developer Mode for This Site" action:@selector(toggleDeveloperMode:) keyEquivalent:@""];
  [view addItemWithTitle:@"Reset Developer Mode Sites" action:@selector(resetDeveloperModeSites:) keyEquivalent:@""];
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
  [split addItemWithTitle:@"New Note in Split View" action:@selector(newNoteInSplitView:) keyEquivalent:@""];
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
  MigrateAppIconOnce();
  ApplyAppIcon();  // the chosen NotArc icon (#74) in the Dock; the app bundle is never changed
  NSString* arcDir = ArcDataDirectory();
  NSString* storePath = SidebarStorePath(self.selfTest);
  if (self.selfTest && !self.selfTestReload)
    [[NSFileManager defaultManager] removeItemAtPath:storePath error:nil];  // phase 1 starts from the Arc import
  NSError* error = nil;
  NSString* focused = nil;
  // Our own store wins; Arc's files are only imported when we have none yet.
  NSArray<ArcSpace*>* spaces = SidebarStoreLoad(storePath, &focused, &error);
  self.freshInstall = spaces == nil && ![NSFileManager.defaultManager fileExistsAtPath:storePath];  // V56: first launch ever
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
    KeepTestWindowsHidden();
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.window.window.alphaValue = 0.01;
    self.window.window.ignoresMouseEvents = YES;
    if (self.visualPlan) VisualShotsPrepareWindow(self.window.window);
  }
  [self.window showWindow:nil];
  [self.window createBrowsers];
  if (!self.selfTest) [self.window restoreSavedWindows];  // windows open at the last quit (#39)
  for (NSString* url in self.pendingURLs) [self.window routeExternalLink:url sourceApp:self.pendingSource];
  self.pendingURLs = nil;
  if (!self.selfTest) [NSApp activateIgnoringOtherApps:YES];
  if (!self.selfTest) {  // never in hidden test runs
    if (self.freshInstall && !SettingBool(@"welcomeCompleted")) [self.window showWelcome];  // V56: Arc's welcome, then import
    else [self.window offerArcImportIfFirstLaunch];
  }

  if (self.selfTest) {
    // Hidden run: no Dock icon, never activates, every window 1% opaque (invisible, but not "occluded", so media still plays) and click-through,
    // so a test never shows up on screen or takes focus. Chromium is told not to throttle hidden windows.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:YES block:^(NSTimer*) {
      if (self.visualPlan) {
        VisualShotsKeepOffscreen(self.window);
        return;
      }
      for (NSWindow* win in NSApp.windows) {
        if (win.alphaValue > 0.011) win.alphaValue = 0.01;
        win.ignoresMouseEvents = YES;
      }
    }];
    [self.window openTabsForSelfTest:1];  // first tab of every Space, each in its own profile
    if (self.visualPlan) {
      VisualShotsRun(self.window, self.visualPlan);
      return;
    }
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
                            NSString* cc = w.captureCardState;  // Visual parity V46: the capture result card
                            std::printf("SELFTEST-CAPTURELOOK card=%d\n", [cc isEqual:@"card=1 actions=3 corner=1"]);
                            if (![cc isEqual:@"card=1 actions=3 corner=1"]) std::printf("SELFTEST-CAPTURELOOK-DEBUG %s\n", cc.UTF8String);
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
                                      std::printf("SELFTEST-AUTOPIP playing=%d popped=%d back=%d gesture=%d settingOff=%d\n", playing,
                                                  popped, back, log, offRespected);
                                      [self runThumbnailSelfTest:other leaving:t];
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
     WaitUntil(^{ return (BOOL)((gLateTestsDone && gMaxTestDone && gAdBlockTestDone && gEaselToolsDone) || self.selfTestReload); }, 45, ^{
      void (^finish)(void) = ^{
        // Last check of every run: nothing above touched the user's real profile or settings.
        std::printf("SELFTEST-REALPROFILE %s\n", TestIsolationReport().UTF8String);
        std::printf("SELFTEST-REALPROFILE-DEBUG %s\n", TestIsolationDebug().UTF8String);
        for (NSDictionary* tab in [self.window tabSnapshot])
          std::printf("SELFTEST space=\"%s\" profile=\"%s\" title=\"%s\" url=%s\n", [tab[@"space"] UTF8String],
                      [tab[@"profile"] UTF8String], [tab[@"title"] UTF8String], [tab[@"url"] UTF8String]);
        std::fflush(stdout);
        [self.window closeAllBrowsers];
      };
      if (self.selfTestReload) { finish(); return; }
      // Window buttons and the pill's Boost brush, the floating video and mini player, the page fills its card
      // (white bar/border fix), then multiple windows; the last two resize or move the window.
      [self runWindowButtonsSelfTest:^{
      [self runFloatingVideoThenPageFit:^{
      // Multiple windows (#39): runs last so no other check shares the screen with a second window.
      MainWindowController* w = self.window;
      // The crash-restore test expects the marker tab on screen when the run saves. Checks that end after it opened
      // (Max, Easel clips) show their own tab for a moment, so put the marker back first.
      for (ArcSpace* space in w.spaces)
        for (ArcItem* it in space.allTabs)
          if ([it.url hasPrefix:@"https://example.org/session-restore-marker"] && w.shownItem != it) {
            if (space != w.currentSpace) [w switchToSpace:space];
            [w showItem:it];
          }
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
      }];  // runPageFitSelfTest
      }];  // runWindowButtonsSelfTest
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
                // The menu follows the shown tab: show this one just for the check, then put the other back at once
                // (other timed checks switch tabs concurrently).
                ArcItem* shownBefore = w.shownItem;
                if (shownBefore != t) [w showItem:t];
                BOOL tidyEnabled = tidyItem && [(id<NSMenuItemValidation>)w validateMenuItem:tidyItem] && !tidyItem.hidden;
                if (shownBefore && shownBefore != t) [w showItem:shownBefore];
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
        [w findInPage:nil];  // Visual parity V35: Arc's floating find bar at the card's top-right
        NSString* fb = w.findBarStyle;
        [w closeFindBar:nil];
        std::printf("SELFTEST-FINDBAR arcStyle=%d\n", [fb isEqual:@"buttons=3 card=1 corner=1"]);
        if (![fb isEqual:@"buttons=3 card=1 corner=1"]) std::printf("SELFTEST-FINDBAR-DEBUG %s\n", fb.UTF8String);
        [w copyCurrentURLAsMarkdown:nil];
        std::printf("SELFTEST-BASICS findDomainCount=%d markdown=%s\n", w.lastFindCount,
                    [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString].UTF8String);
        [self runRemainingSelfTestActions];
      });
    });
  });
}

// Basics run alone first; the other steps would otherwise navigate or close its tab mid-test.
// Visual parity V52 (theme picker) and V54 (New Space card). Runs first, before any timed check, since it switches
// Spaces, changes the theme and shows a popover and a card.
- (void)runSpaceCardsSelfTest {
  MainWindowController* w = self.window;
  ArcSpace* sp = w.currentSpace;
  {  // Visual parity V52: Arc's theme picker popover drives the Space theme live (dots, presets, modes, sliders).
    NSString* ownScheme = sp.colorScheme;
    NSArray* ownColors = sp.themeColors;
    double ownIntensity = sp.themeIntensity, ownGrain = sp.themeGrain;
    [w setTheme:nil intensity:0.5 forSpace:sp];
    [w editThemeColor:nil];
    ThemePickerController* tp = w.themePickerForTest;
    BOOL popover = w.themePickerShown && tp != nil;
    NSString* look = [tp lookDescription];
    BOOL looks = [look isEqualToString:@"pad=1 dots=0 modes=3 wave=1 dial=1 swatches=9 pages=5 plusMinus=1"];
    [tp addDot];
    BOOL one = sp.themeColors.count == 1 && !w.themeView.hidden;
    [tp addDot];
    [tp addDot];
    [tp addDot];  // the fourth is ignored: at most three colours
    BOOL three = sp.themeColors.count == 3 && tp.colors.count == 3;
    NSString* before = sp.themeColors.firstObject;
    [tp moveDot:0 toUnitPoint:NSMakePoint(0.05, 0.9)];
    BOOL dragged = ![sp.themeColors.firstObject isEqual:before];
    [tp pickPreset:7 onPage:0];
    BOOL preset = sp.themeColors.count == 3 && [sp.themeColors isEqualToArray:tp.colors];
    [tp pickPreset:4 onPage:1];
    BOOL single = sp.themeColors.count == 1;
    [tp setIntensityValue:0.8];
    [tp setGrainValue:0.5];
    BOOL sliders = fabs(sp.themeIntensity - 0.8) < 0.01 && fabs(sp.themeGrain - 0.5) < 0.01;
    [tp chooseScheme:@"light"];
    [w.window displayIfNeeded];
    BOOL light = [sp.colorScheme isEqual:@"light"] && !w.sidebarIsDark;
    [tp chooseScheme:@"auto"];
    BOOL autoBack = sp.colorScheme == nil;
    while (tp.colors.count) [tp removeDot];
    BOOL cleared2 = sp.themeColors.count == 0;
    [w closeThemePicker];
    [w setTheme:ownColors intensity:ownIntensity forSpace:sp];
    [w setThemeGrain:ownGrain forSpace:sp];
    [w setColorScheme:ownScheme forSpace:sp];
    std::printf("SELFTEST-THEMEPICKER popover=%d look=%d oneColor=%d threeMax=%d drag=%d preset=%d single=%d sliders=%d "
                "light=%d autoBack=%d removeAll=%d\n", popover, looks, one, three, dragged, preset, single, sliders, light,
                autoBack, cleared2);
    if (!looks) std::printf("SELFTEST-THEMEPICKER-DEBUG %s\n", look.UTF8String);
  }
  {  // Visual parity V54: Arc's New Space card (icon, name, profile, theme) makes the Space in one step.
    ArcSpace* before = w.currentSpace;
    NSUInteger count = w.spaces.count;
    [w newSpace:nil];
    NSString* look = [w newSpaceCardLook];
    NSString* want = [NSString stringWithFormat:@"card=1 emoji=1 name=1 profiles=%lu swatches=9",
                                                (unsigned long)w.profileDirectories.count + 2];
    [w fillNewSpaceCard:@"SelfTest Card Space" emoji:@"\U0001F9EA" swatch:3];
    [[w newSpaceCardForTest] dismissWithResponse:NSAlertFirstButtonReturn];
    ArcSpace* made = w.currentSpace;
    BOOL created = made != before && w.spaces.count == count + 1 && [made.title isEqual:@"SelfTest Card Space"] &&
                   [made.iconEmoji isEqual:@"\U0001F9EA"] && [made.themeColors.firstObject isEqual:@"#F25E6B"] &&
                   [made.profileDirectory isEqual:before.profileDirectory];
    [w deleteSpace:made];
    [w switchToSpace:before];
    [w newSpace:nil];
    [[w newSpaceCardForTest] dismissWithResponse:NSAlertSecondButtonReturn];
    BOOL cancelled = w.spaces.count == count && w.currentSpace == before && [w newSpaceCardForTest] == nil;
    std::printf("SELFTEST-NEWSPACE card=%d created=%d cancelled=%d\n", [look isEqual:want], created, cancelled);
    if (![look isEqual:want]) std::printf("SELFTEST-NEWSPACE-DEBUG %s\n", look.UTF8String);
  }
}

// Visual parity V60: NotArc's dialogs are Arc-style cards over the dimmed window, answered by Return and Esc.
- (void)runAlertLookSelfTest {
  NSWindow* win = self.window.window;
  __block NSModalResponse first = 0, second = 0;
  ArcAlert* a = [ArcAlert new];
  a.messageText = @"Delete this Space?";
  a.informativeText = @"Self-test dialog.";
  [a addButtonWithTitle:@"Delete"].hasDestructiveAction = YES;
  [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:win completionHandler:^(NSModalResponse r) { first = r; }];
  NSString* look = [a lookDescription];
  BOOL shown = ArcAlertShownOn(win) && !win.attachedSheet;
  [a.window performKeyEquivalent:[NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0
                                                  timestamp:0 windowNumber:a.window.windowNumber context:nil
                                                 characters:@"\r" charactersIgnoringModifiers:@"\r" isARepeat:NO keyCode:36]];
  BOOL gone = !ArcAlertShownOn(win) && !a.isShown && a.window.parentWindow == nil;
  ArcAlert* b = [ArcAlert new];
  b.messageText = @"Second";
  [b addButtonWithTitle:@"OK"];
  [b addButtonWithTitle:@"Cancel"];
  [b beginSheetModalForWindow:win completionHandler:^(NSModalResponse r) { second = r; }];
  NSString* lookB = [b lookDescription];
  [b.window cancelOperation:nil];
  BOOL ok = [look isEqual:@"card=1 child=1 scrim=1 radius=16 primary=0 destructive=1 neutral=1 returnKey=1 escKey=1"] &&
            [lookB isEqual:@"card=1 child=1 scrim=1 radius=16 primary=1 destructive=0 neutral=1 returnKey=1 escKey=1"];
  std::printf("SELFTEST-ALERTLOOK arcCard=%d shownOverWindow=%d returnFirst=%d escCancel=%d dismissed=%d\n", ok, shown,
              first == NSAlertFirstButtonReturn, second == NSAlertSecondButtonReturn, gone && !ArcAlertShownOn(win));
  if (!ok) std::printf("SELFTEST-ALERTLOOK-DEBUG %s | %s\n", look.UTF8String, lookB.UTF8String);
}

// Visual parity V56/V57: the welcome covers the window, walks the tour, offers the browsers, imports, and goes.
- (void)runWelcomeSelfTest {
  MainWindowController* w = self.window;
  [w showWelcome];
  WelcomeView* wv = w.welcomeViewForTest;
  BOOL covers = wv && NSEqualRects(wv.frame, w.window.contentView.bounds) && wv.superview == w.window.contentView;
  NSString* hello = [wv lookDescription];
  BOOL welcome = [hello hasPrefix:@"glow=1 title=Welcome to NotArc primary=Get Started"];
  NSMutableArray* pages = [NSMutableArray array];
  for (int i = 0; i < 5; ++i) {
    [wv next];
    [pages addObject:wv.page];
  }
  BOOL tour = [pages isEqualToArray:@[ @"pin", @"spaces", @"split", @"commandbar", @"import" ]];
  [wv back];
  BOOL back = [wv.page isEqual:@"commandbar"];
  [wv next];
  NSString* importLook = [wv lookDescription];
  BOOL cards = wv.browsers.count >= 1 && [importLook containsString:[NSString stringWithFormat:@"cards=%lu", (unsigned long)wv.browsers.count]] &&
               [wv.browsers.firstObject[@"kind"] isEqual:@"arc"];  // the test home has Arc's files
  __block NSDictionary* picked = nil;
  wv.importChosen = ^(NSDictionary* b, void (^done)(NSString*, BOOL)) {  // no real import in a test
    picked = b;
    done(@"SelfTest import", YES);
  };
  [wv chooseBrowserAtIndex:0];
  [wv next];
  BOOL imported = [picked[@"name"] isEqual:@"Arc"] && [wv.page isEqual:@"done"];
  [wv next];  // Start Browsing
  BOOL gone = w.welcomeViewForTest == nil && SettingBool(@"welcomeCompleted");
  std::printf("SELFTEST-WELCOME covers=%d welcome=%d tour=%d back=%d importCards=%d imported=%d closed=%d\n", covers, welcome,
              tour, back, cards, imported, gone);
  if (!welcome || !cards) std::printf("SELFTEST-WELCOME-DEBUG %s | %s\n", hello.UTF8String, importLook.UTF8String);
  SettingSetObject(@"welcomeCompleted", nil);
  SettingSetObject(@"defaultBrowserOffered", nil);
  SettingSetObject(@"arcImportNotNow", nil);
}

// One window button drawn the way it is now, its middle pixel as r,g,b (0-1).
static NSColor* WindowButtonMiddle(NSButton* b) {
  b.needsDisplay = YES;
  NSBitmapImageRep* rep = [b bitmapImageRepForCachingDisplayInRect:b.bounds];
  if (!rep) return nil;
  [b cacheDisplayInRect:b.bounds toBitmapImageRep:rep];
  return [[rep colorAtX:rep.pixelsWide / 2 y:rep.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}
// Visual parity V73: the window's own macOS buttons (no drawn copies), at Arc's spots, in macOS's red, yellow and green.
// Fills *coloured and *placed; returns the measured colours and centres for the log.
static NSString* WindowButtonsLook(NSWindow* win, BOOL* system, BOOL* placed, BOOL* coloured) {
  *system = *placed = *coloured = YES;
  NSMutableArray* parts = [NSMutableArray array];
  const NSWindowButton kinds[3] = {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};
  const CGFloat arcX[3] = {20, 43, 66};  // centres, measured on Omar's Arc screenshot (Nov 11, 1x): 20.5 / 43.5 / 66.5
  for (int i = 0; i < 3; ++i) {
    NSButton* b = [win standardWindowButton:kinds[i]];
    *system &= b && [NSStringFromClass(b.class) hasPrefix:@"_NSTheme"] && b.enabled && !b.isHiddenOrHasHiddenAncestor &&
               b.alphaValue > 0.99;
    NSRect f = b ? [b convertRect:b.bounds toView:nil] : NSZeroRect;
    CGFloat cx = NSMidX(f), cy = win.frame.size.height - NSMidY(f);
    *placed &= fabs(cx - arcX[i]) <= 1.5 && fabs(cy - 24) <= 1.5;
    NSColor* c = b ? WindowButtonMiddle(b) : nil;
    double r = c.redComponent, g = c.greenComponent, bl = c.blueComponent;
    // Inactive macOS buttons are flat grey (r = g = b); active ones are clearly red, yellow and green.
    BOOL hue = i == 0 ? (r - g > 0.25 && r - bl > 0.25) : i == 1 ? (r > 0.6 && g > 0.45 && r - bl > 0.3 && g - bl > 0.3)
                                                                 : (g - r > 0.2 && g - bl > 0.2);
    *coloured &= c != nil && hue;
    [parts addObject:[NSString stringWithFormat:@"%d:%.2f,%.2f,%.2f@%.1f,%.1f", i, r, g, bl, cx, cy]];
  }
  return [parts componentsJoinedByString:@" "];
}

// Omar, Nov 12: (a) Arc's window buttons are macOS's own red, yellow and green with their shading and rims; NotArc's
// came out as flat grey circles whenever its window wasn't the key one (a Chrome-style page window took key, or another
// app was in front). They must look the same in an active and an inactive window. (b) NotArc showed a blue paintbrush
// (the Boost button) after the domain on a site with a Boost on; Arc keeps Boosts in the site control center and shows
// no Boost icon in the address pill, on a plain site or a Boosted one. The hidden test window is never key, so it is
// the inactive case as macOS sees it; "active" is NotArc's own active state (sidebar not dimmed, V8).
- (void)runWindowButtonsSelfTest:(void (^)(void))done {
  MainWindowController* w = self.window;
  NSWindow* win = w.window;
  BOOL sys1, placed1, activeLook, sys2, placed2, inactiveLook;
  [w sidebarDimmedForTest:NO];
  NSString* active = WindowButtonsLook(win, &sys1, &placed1, &activeLook);
  [w sidebarDimmedForTest:YES];
  NSString* inactive = WindowButtonsLook(win, &sys2, &placed2, &inactiveLook);
  [w sidebarDimmedForTest:NO];
  BOOL notKey = !win.isKeyWindow;  // the case Omar saw: drawn while another window has key focus
  // AppKit lays the title bar out again on its own (an appearance change, as when macOS turns dark at sunset): the
  // buttons must come back to Arc's spots without the window becoming main.
  NSAppearance* was = win.appearance;
  win.appearance = [NSAppearance appearanceNamed:[[win.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameDarkAqua, NSAppearanceNameAqua ]] isEqual:NSAppearanceNameDarkAqua] ? NSAppearanceNameAqua : NSAppearanceNameDarkAqua];
  NSView* bar = [win standardWindowButton:NSWindowCloseButton].superview.superview;
  bar.needsLayout = YES;
  [bar layoutSubtreeIfNeeded];
  win.appearance = was;
  bar.needsLayout = YES;
  [bar layoutSubtreeIfNeeded];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
  BOOL sys3, stayPlaced, look3;
  NSString* later = WindowButtonsLook(win, &sys3, &stayPlaced, &look3);
  std::printf("SELFTEST-WINDOWBUTTONS system=%d placed=%d activeLook=%d inactiveLook=%d notKey=%d stayPlaced=%d\n",
              sys1 && sys2 && sys3, placed1 && placed2, activeLook, inactiveLook && look3, notKey, stayPlaced);
  if (!(sys1 && sys2 && sys3 && placed1 && placed2 && activeLook && inactiveLook && look3 && stayPlaced))
    std::printf("SELFTEST-WINDOWBUTTONS-DEBUG active=[%s] inactive=[%s] later=[%s]\n", active.UTF8String,
                inactive.UTF8String, later.UTF8String);
  // The pill: no Boost brush on a plain site, nor on a site with a Boost on (idle or hovered).
  static NSString* const kPlain = @"https://plain.notarc.test/";
  static NSString* const kBoosted = @"https://boosted.notarc.test/";
  BrowserClient::SetTestResponse(kPlain.UTF8String, "<!doctype html><title>plain site</title><p>plain");
  BrowserClient::SetTestResponse(kBoosted.UTF8String, "<!doctype html><title>boosted site</title><p>boosted");
  [w deleteBoostForHost:@"plain.notarc.test"];
  [w setBoostForHost:@"boosted.notarc.test" configure:^(Boost* b) { b.enabled = YES; b.hue = -1; }];
  [w openInNewTab:kPlain];
  ArcItem* plain = w.shownItem;
  [w openInNewTab:kBoosted];
  ArcItem* boosted = w.shownItem;
  WaitUntil(^{ return (BOOL)([plain.liveTitle isEqual:@"plain site"] && [boosted.liveTitle isEqual:@"boosted site"]); }, 10, ^{
    NSString* (^brush)(ArcItem*) = ^NSString*(ArcItem* t) {  // "<idle>|<hover>", each 1 when the brush shows
      [w showItem:t];
      NSString* idleOrder = w.pillButtonOrder;
      NSString* idleState = w.pillButtonState;  // "<shown>/<all>"; with no hover, nothing may show
      [w setPillHoveredForTest:YES];
      NSString* hoverOrder = w.pillButtonOrder;
      [w setPillHoveredForTest:NO];
      BOOL idle = [idleOrder containsString:@"boost"] || ![idleState hasPrefix:@"0/"];
      return [NSString stringWithFormat:@"%d|%d", idle, (int)[hoverOrder containsString:@"boost"]];
    };
    NSString* p = brush(plain);
    NSString* b = brush(boosted);
    BOOL boostOn = [w.boostIndicatorState isEqual:@"on"];  // the Boosted site really has its Boost on
    std::printf("SELFTEST-PILLBOOST plainIdle=%d plainHover=%d boostOn=%d boostedIdle=%d boostedHover=%d\n",
                [p hasPrefix:@"0|"], [p hasSuffix:@"|0"], boostOn, [b hasPrefix:@"0|"], [b hasSuffix:@"|0"]);
    [w deleteBoostForHost:@"boosted.notarc.test"];
    [w showItem:boosted];
    [w closeTab:nil];
    [w showItem:plain];
    [w closeTab:nil];
    std::fflush(stdout);
    done();
  });
  });  // dispatch_after (title bar relayout)
}

// The page fills its card exactly (Omar, Nov 11: a white bar above the page and a white border around Google's sign-in
// page, after resizing the window). A local page as wide as its viewport reports its size; after every window resize
// and sidebar toggle the page, its Chrome-style page window (if any) and the white backing under the card must all
// match the card, nothing may be wider than the viewport, and a finished load (here a single-page app that only
// pushState()s) leaves no loading glow. Puts the window and the sidebar back when done.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"  // broken by next = nil when done
- (void)runPageFitSelfTest:(void (^)(void))done {
  MainWindowController* w = self.window;
  NSWindow* win = w.window;
  NSRect startFrame = win.frame;
  BOOL startHidden = w.sidebarHidden;
  static NSString* const kURL = @"https://pagefit.notarc.test/";
  BrowserClient::SetTestResponse(kURL.UTF8String,
      "<!doctype html><meta name=viewport content='width=device-width'><title>pagefit</title>"
      "<style>html,body{margin:0;background:#123}#bar{width:100%;height:40px;background:#0a0}</style><div id=bar></div>"
      "<script>function r(){document.title='fit:'+innerWidth+'x'+innerHeight+':'+document.documentElement.scrollWidth+':'+"
      "document.documentElement.clientWidth}r();onresize=r;history.pushState({},'', '/app');</script>");
  [w openInNewTab:kURL];
  ArcItem* t = w.shownItem;
  // Each step: what to do, then what the card and the page say. Sizes: Omar's case (wider and 10 pt shorter, so a
  // stale backing sticks out at the top), a smaller window, the sidebar hidden and back, and the start size again.
  NSArray<NSArray*>* steps = @[
    @[ @"start", [NSValue valueWithRect:NSZeroRect] ],
    @[ @"wider-shorter", [NSValue valueWithRect:NSMakeRect(NSMinX(startFrame), NSMinY(startFrame) + 10, NSWidth(startFrame) + 160, NSHeight(startFrame) - 10)] ],
    @[ @"small", [NSValue valueWithRect:NSMakeRect(NSMinX(startFrame), NSMinY(startFrame), 1000, 700)] ],
    @[ @"switch-tabs", @"switch" ],
    @[ @"background-pages", @"background" ],  // pages made for tabs that aren't shown (as at launch) stay hidden
    @[ @"sidebar-hidden", @"toggle" ],
    @[ @"sidebar-shown", @"toggle" ],
    @[ @"back", [NSValue valueWithRect:startFrame] ],
  ];
  __block NSUInteger stepIndex = 0;
  __block BOOL edgeOK = YES, pageOK = YES, windowOK = YES, sizeOK = YES, noOverflow = YES, glowOK = YES, onlyShown = YES;
  __block NSMutableArray<NSString*>* debug = [NSMutableArray array];
  __block void (^next)(void);
  void (^finish)(void) = ^{
    if (w.sidebarHidden != startHidden) [w toggleSidebar:nil];
    [win setFrame:startFrame display:YES];
    BOOL loaded = t && !t.loading;
    if (t && w.shownItem == t) [w closeCurrentTab];
    BrowserClient::SetTestResponse(kURL.UTF8String, "");
    std::printf("SELFTEST-PAGEFIT loaded=%d steps=%lu edge=%d page=%d pageWindow=%d viewportMatchesCard=%d nothingClipped=%d "
                "noGlowAfterLoad=%d onlyShownPageWindow=%d\n", loaded, (unsigned long)stepIndex, edgeOK, pageOK, windowOK, sizeOK,
                noOverflow, glowOK, onlyShown);
    for (NSString* d in debug) std::printf("SELFTEST-PAGEFIT-DEBUG %s\n", d.UTF8String);
    std::fflush(stdout);
    dispatch_async(dispatch_get_main_queue(), ^{
      next = nil;  // the block refers to itself; let it go on the next turn, not while it runs
      if (done) done();
    });
  };
  next = ^{
    if (stepIndex >= steps.count) { finish(); return; }
    NSArray* step = steps[stepIndex++];
    if ([step[1] isEqual:@"toggle"]) [w toggleSidebar:nil];
    else if ([step[1] isEqual:@"background"]) [w openTabsForSelfTest:3];
    else if ([step[1] isEqual:@"switch"]) {  // away to another tab and back
      for (ArcItem* other in w.currentSpace.allTabs)
        if (other != t && other.browserId) { [w showItem:other]; break; }
    }
    else if (!NSIsEmptyRect([step[1] rectValue])) [win setFrame:[step[1] rectValue] display:YES];
    if (w.shownItem != t) [w showItem:t];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      [w runJS:@"r()" inItem:t];
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        NSString* state = [w pageFitState];
        NSString* title = t.liveTitle ?: @"";
        NSRect card = w.pageCardFrame;
        NSArray<NSString*>* p = [title hasPrefix:@"fit:"] ? [[title substringFromIndex:4] componentsSeparatedByString:@":"] : @[];
        NSArray<NSString*>* wh = p.count == 3 ? [p[0] componentsSeparatedByString:@"x"] : @[];
        BOOL size = wh.count == 2 && fabs(wh[0].doubleValue - NSWidth(card)) < 1 && fabs(wh[1].doubleValue - NSHeight(card)) < 1;
        BOOL fits = p.count == 3 && p[1].integerValue <= p[2].integerValue && p[2].integerValue > 0;
        edgeOK &= [state hasPrefix:@"edge=1"];
        pageOK &= [state containsString:@" page=1"];
        windowOK &= [state containsString:@" window=1"];
        glowOK &= [state containsString:@" glow=1"] && !t.loading;
        onlyShown &= [state containsString:@" others=1"];
        sizeOK &= size;
        noOverflow &= fits;
        [debug addObject:[NSString stringWithFormat:@"%@ title=%@ %@", step[0], title, state]];
        next();
      });
    });
  };
  WaitUntil(^{ return (BOOL)(t && [t.liveTitle hasPrefix:@"fit:"] && !t.loading); }, 20, ^{ next(); });
}
#pragma clang diagnostic pop

// Floating video and mini player (V75-V80), on a local page (no network) that plays a short video with
// media-session metadata. The float is Chromium's real picture-in-picture window, kept 1% opaque like every test window.
- (void)runFloatingVideoSelfTest:(void (^)(void))done {
  MainWindowController* w = self.window;
  NSString* dir = [NSHomeDirectory() stringByAppendingPathComponent:@"NotArcMediaTest"];
  NSData* html = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"media-test.html"]];
  NSData* webm = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"media-test.webm"]];
  NSData* icon = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"icon.png"]];
  if (!html || !webm) {
    std::printf("SELFTEST-FLOATVIDEO floated=0 size=0 corner=0 anchored=0 miniHidden=0 fixture=0\n");
    done();
    return;
  }
  auto serve = [](NSString* url, NSData* d) {
    BrowserClient::SetTestResponse(url.UTF8String, d ? std::string((const char*)d.bytes, d.length) : std::string());
  };
  serve(@"https://media.example/watch", html);
  serve(@"https://media.example/media-test.webm", webm);
  serve(@"https://media.example/icon.png", icon);
  void (^finish)(void) = ^{
    serve(@"https://media.example/watch", nil);
    serve(@"https://media.example/media-test.webm", nil);
    serve(@"https://media.example/icon.png", nil);
    done();
  };
  [w openInNewTab:@"https://media.example/watch"];
  ArcItem* t = w.shownItem;
  BOOL (^floating)(void) = ^BOOL { return w.floatingVideoWindow != nil && w.floatingVideoItem == t; };
  WaitUntil(^{ [w pollMediaNow]; return (BOOL)(t.mediaPlaying && t.mediaTitle.length); }, 15, ^{
    BOOL playing = t.mediaPlaying;
    [w openInNewTab:@"https://example.com/float-other"];
    ArcItem* other = w.shownItem;
    WaitUntil(floating, 8, ^{
      // A. Leaving the playing tab floats the video: Arc's size, corners and place over the sidebar's bottom-left.
      NSWindow* fw = w.floatingVideoWindow;
      NSRect f = w.floatingVideoFrame, m = w.window.frame;
      BOOL floated = playing && fw.isVisible && t.inPictureInPicture;
      BOOL size = fabs(NSWidth(f) - 222) <= 1 && fabs(NSHeight(f) - 125) <= 1;
      BOOL corner = fabs(w.floatingVideoCornerRadius - 6) < 0.01;
      BOOL anchored = fw && fw.parentWindow == w.window && fabs(NSMinX(f) - NSMinX(m) - 20) <= 1 && fabs(NSMinY(f) - NSMinY(m) - 98) <= 1;
      BOOL miniHidden = w.mediaBarItem != t;  // (another check's paused tab may still have the bar)
      std::printf("SELFTEST-FLOATVIDEO floated=%d size=%d corner=%d anchored=%d miniHidden=%d noChromiumName=%d\n", floated, size,
                  corner, anchored, miniHidden, w.floatingVideoHidesChromiumBar);
      if (!(floated && size && anchored)) std::printf("FLOAT-DEBUG frame=%s main=%s playing=%d pip=%d\n", NSStringFromRect(f).UTF8String,
                                                      NSStringFromRect(m).UTF8String, playing, t.inPictureInPicture);
      // B. Hover controls: back to the tab, the site, play/pause, minimize, close and the progress bar; the pointer
      // reaches NotArc's controls, never Chromium's own.
      [w setFloatingControlsHoveredForTest:YES];
      WaitUntil(^{ [w pollMediaNow]; return (BOOL)([w.floatingControlsState containsString:@"progress=1"]); }, 5, ^{
        NSString* s = w.floatingControlsState;
        auto has = [&](NSString* k) { return (int)[[NSString stringWithFormat:@" %@ ", s] containsString:[NSString stringWithFormat:@" %@ ", k]]; };
        std::printf("SELFTEST-FLOATCONTROLS hover=%d back=%d site=%d play=%d minimize=%d close=%d progress=%d hit=%d\n", has(@"hover=1"),
                    has(@"back=1"), has(@"site=media.example"), has(@"play=1"), has(@"minimize=1"), has(@"close=1"),
                    has(@"progress=1"), has(@"hit=1"));
        if (!has(@"hit=1") || !has(@"progress=1")) std::printf("FLOATCONTROLS-DEBUG %s\n", s.UTF8String);
        // C. The big button pauses and plays the page's video.
        [w pressFloatingControl:@"playpause"];
        WaitUntil(^{ [w pollMediaNow]; return (BOOL)(!t.mediaPlaying && t.mediaPaused); }, 5, ^{
          BOOL paused = !t.mediaPlaying && t.mediaPaused;
          [w pressFloatingControl:@"playpause"];
          WaitUntil(^{ [w pollMediaNow]; return t.mediaPlaying; }, 5, ^{
            std::printf("SELFTEST-FLOATPLAY paused=%d resumed=%d\n", paused, t.mediaPlaying);
            // D. The back arrow returns to the video's tab (the video goes back into the page); leaving floats it again.
            [w pressFloatingControl:@"back"];
            WaitUntil(^{ return (BOOL)(w.shownItem == t && !floating() && !t.inPictureInPicture); }, 5, ^{
              BOOL back = w.shownItem == t && !floating();
              [w showItem:other];
              WaitUntil(floating, 8, ^{
                std::printf("SELFTEST-FLOATBACK back=%d refloat=%d\n", back, floating());
                // E. Close: the video goes away, the sound keeps playing in the mini player.
                [w pressFloatingControl:@"close"];
                WaitUntil(^{ [w pollMediaNow]; return (BOOL)(!floating() && !t.inPictureInPicture && w.mediaBarItem == t); }, 6, ^{
                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                    [w pollMediaNow];
                    WaitUntil(^{ return t.mediaPlaying; }, 3, ^{
                      std::printf("SELFTEST-FLOATCLOSE closed=%d stillPlaying=%d miniPlayer=%d\n", !floating() && !t.inPictureInPicture,
                                  t.mediaPlaying, w.mediaBarItem == t);
                      // F. The mini player shows the site's icon (not the artwork); hovering shows the title, reopen and close.
                      [w setMediaArtworkForTest:[NSImage imageWithSystemSymbolName:@"music.note" accessibilityDescription:nil]
                                            url:t.mediaArtworkURL];
                      [w setMediaCardHoveredForTest:YES];
                      NSString* mp = w.miniPlayerState;
                      auto mhas = [&](NSString* k) { return (int)[[NSString stringWithFormat:@" %@ ", mp] containsString:[NSString stringWithFormat:@" %@ ", k]]; };
                      std::printf("SELFTEST-MINIPLAYERHOVER favicon=%d tall=%d title=%d reopen=%d close=%d\n", mhas(@"favicon=1"),
                                  mhas(@"h=64"), [mp containsString:@"title=LIKA - Morning coffee groove|"], mhas(@"reopen=1"),
                                  mhas(@"close=1"));
                      if (!mhas(@"h=64") || !mhas(@"favicon=1")) std::printf("MINIPLAYER-DEBUG %s\n", mp.UTF8String);
                      [w setMediaCardHoveredForTest:NO];
                      // G. Its play button plays the sound without bringing the video back; the speaker sets the volume.
                      [w mediaBarPlay:nil];
                      WaitUntil(^{ [w pollMediaNow]; return (BOOL)(!t.mediaPlaying && t.mediaPaused); }, 5, ^{
                        BOOL mpaused = !t.mediaPlaying && t.mediaPaused;
                        [w mediaBarPlay:nil];
                        WaitUntil(^{ [w pollMediaNow]; return t.mediaPlaying; }, 5, ^{
                          BOOL resumed = t.mediaPlaying;
                          [w setMediaVolume:0.3 forItem:t];
                          [w runJS:@"setTimeout(()=>{document.title='vol:'+document.querySelector('video').volume.toFixed(2)},300)" inItem:t];
                          WaitUntil(^{ return [t.liveTitle hasPrefix:@"vol:"]; }, 4, ^{
                            std::printf("SELFTEST-MINIPLAYERAUDIO paused=%d resumed=%d noVideo=%d volume=%d\n", mpaused, resumed,
                                        !floating() && !t.inPictureInPicture, [t.liveTitle isEqualToString:@"vol:0.30"]);
                            [w runJS:@"document.title='Media test page'" inItem:t];
                            // H. Reopen brings the floating video back; minimize sends it to the mini player again.
                            [w pressMiniPlayerControl:@"reopen"];
                            WaitUntil(floating, 6, ^{
                              BOOL reopened = floating();
                              BOOL hiddenWhileFloating = w.mediaBarItem != t;
                              [w pressFloatingControl:@"minimize"];
                              WaitUntil(^{ [w pollMediaNow]; return (BOOL)(!floating() && w.mediaBarItem == t); }, 6, ^{
                                BOOL minimized = !floating() && w.mediaBarItem == t;
                                WaitUntil(^{ [w pollMediaNow]; return t.mediaPlaying; }, 3, ^{
                                  std::printf("SELFTEST-MINIPLAYERREOPEN reopened=%d miniHidden=%d minimized=%d playing=%d\n", reopened,
                                              hiddenWhileFloating, minimized, t.mediaPlaying);
                                  [self runMiniPlayerReopenClickSelfTest:t done:^{
                                  // I. Another Space on another profile: the sound keeps playing and the mini player stays.
                                  ArcSpace* home = w.currentSpace, *away = nil;
                                  for (ArcSpace* s in w.spaces)
                                    if (![s.profileDirectory isEqualToString:home.profileDirectory]) away = s;
                                  [w switchToSpace:away];
                                  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                    [w pollMediaNow];
                                    WaitUntil(^{ return (BOOL)(t.mediaPlaying && w.mediaBarItem == t); }, 3, ^{
                                      std::printf("SELFTEST-MINIPLAYERSPACE otherProfile=%d playing=%d miniPlayer=%d\n",
                                                  away != nil && w.currentSpace == away, t.mediaPlaying, w.mediaBarItem == t);
                                      // J. The mini player's X stops the sound and removes the player.
                                      [w pressMiniPlayerControl:@"close"];
                                      WaitUntil(^{ [w pollMediaNow]; return (BOOL)(!t.mediaPlaying && w.mediaBarItem != t); }, 5, ^{
                                        BOOL stopped = !t.mediaPlaying, removed = w.mediaBarItem != t;
                                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                          [w pollMediaNow];
                                          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                            std::printf("SELFTEST-MINIPLAYERSTOP stopped=%d removed=%d staysGone=%d\n", stopped, removed,
                                                        !t.mediaPlaying && w.mediaBarItem != t);
                                            std::fflush(stdout);
                                            [w switchToSpace:home];
                                            finish();
                                          });
                                        });
                                      });
                                    });
                                  });
                                  }];
                                });
                              });
                            });
                          });
                        });
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}

// K. Real clicks on the mini player's Open Picture in Picture (Omar, Nov 13: clicking it did nothing; the checks above
// call the action directly). The window hit-tests the button's centre like a mouse-down. The float must come back with
// the same video at the same time, still playing (no reload, no restart), after a minimize, after a close (sound only)
// and with the video's tab in another Space on another profile.
- (void)runMiniPlayerReopenClickSelfTest:(ArcItem*)t done:(void (^)(void))done {
  MainWindowController* w = self.window;
  BOOL (^floating)(void) = ^BOOL { return w.floatingVideoWindow != nil && w.floatingVideoItem == t; };
  BOOL (^mini)(void) = ^BOOL {
    [w pollMediaNow];
    return (BOOL)(!floating() && w.mediaBarItem == t && t.mediaPlaying);
  };
  // Marks the page and its video once, so a reload or a restart of the video shows.
  [w runJS:@"(()=>{if(window.__reo)return;const v=document.querySelector('video');window.__reo=1;window.__restarts=0;"
           @"v.__reo=1;['emptied','loadstart','abort'].forEach(e=>v.addEventListener(e,()=>window.__restarts++));})()"
      inItem:t];
  // Brings a float up the way that already works (the action itself), for a case whose click came before.
  void (^toFloat)(void (^)(void)) = ^(void (^then)(void)) {
    if (floating()) { then(); return; }
    [w pressMiniPlayerControl:@"reopen"];
    WaitUntil(floating, 6, then);
  };
  void (^clickCase)(NSString*, void (^)(void)) = ^(NSString* name, void (^next)(void)) {
    WaitUntil(mini, 6, ^{
      BOOL ready = mini();
      [w runJS:@"(()=>{const v=document.querySelector('video');"
               @"document.title='pre:'+v.currentTime.toFixed(2)+':'+(isFinite(v.duration)?v.duration:0).toFixed(2);})()"
          inItem:t];
      WaitUntil(^{ return [t.liveTitle hasPrefix:@"pre:"]; }, 3, ^{
        NSArray<NSString*>* pre = [t.liveTitle hasPrefix:@"pre:"] ? [[t.liveTitle substringFromIndex:4] componentsSeparatedByString:@":"] : @[];
        double ct0 = pre.count == 2 ? pre[0].doubleValue : -1, dur = pre.count == 2 ? pre[1].doubleValue : 0;
        CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
        [w setMediaCardHoveredForTest:YES];  // the pointer is on the card: the reopen button shows
        NSString* hit = [w clickMiniPlayerControl:@"reopen"];
        WaitUntil(floating, 6, ^{
          BOOL floated = floating();
          BOOL miniHidden = w.mediaBarItem != t;
          BOOL anchored = floated && w.floatingVideoWindow.parentWindow == w.window;
          [w runJS:@"(()=>{const v=document.querySelector('video'),p=document.pictureInPictureElement;"
                   @"document.title='post:'+(p===v&&v.__reo===1&&window.__reo===1?1:0)+':'+v.currentTime.toFixed(2)+':'+"
                   @"(v.paused?0:1)+':'+window.__restarts;})()"
              inItem:t];
          WaitUntil(^{ return [t.liveTitle hasPrefix:@"post:"]; }, 3, ^{
            double dt = CFAbsoluteTimeGetCurrent() - t0;
            NSArray<NSString*>* post = [t.liveTitle hasPrefix:@"post:"] ? [[t.liveTitle substringFromIndex:5] componentsSeparatedByString:@":"] : @[];
            BOOL sameMedia = post.count == 4 && [post[0] isEqualToString:@"1"] && [post[3] isEqualToString:@"0"];
            double ct1 = post.count == 4 ? post[1].doubleValue : -1;
            double expect = dur > 0 ? fmod(ct0 + dt, dur) : ct0 + dt;
            double off = fabs(ct1 - expect);
            if (dur > 0) off = MIN(off, dur - off);  // the test video loops
            BOOL sameTime = ct0 >= 0 && ct1 >= 0 && off < 1.5;
            BOOL playing = post.count == 4 && [post[2] isEqualToString:@"1"];
            std::printf("SELFTEST-MINIREOPENCLICK case=%s ready=%d hitButton=%d floated=%d miniHidden=%d anchored=%d "
                        "sameMedia=%d sameTime=%d playing=%d\n", name.UTF8String, ready, [hit isEqualToString:@"button"],
                        floated, miniHidden, anchored, sameMedia, sameTime, playing);
            if (!(floated && sameMedia && sameTime && playing && [hit isEqualToString:@"button"]))
              std::printf("MINIREOPENCLICK-DEBUG case=%s hit=%s ct0=%.2f ct1=%.2f expect=%.2f dur=%.2f title=%s\n",
                          name.UTF8String, hit.UTF8String, ct0, ct1, expect, dur, t.liveTitle.UTF8String);
            std::fflush(stdout);
            [w setMediaCardHoveredForTest:NO];
            [w runJS:@"document.title='Media test page'" inItem:t];
            next();
          });
        });
      });
    });
  };
  // 1. After the float was minimized (the check above ends there).
  clickCase(@"minimize", ^{
    // 2. After the float was closed: only the sound plays on.
    toFloat(^{
      [w pressFloatingControl:@"close"];
      clickCase(@"close", ^{
        // 3. From another Space on another profile, the video's tab staying in its own Space.
        toFloat(^{
          [w pressFloatingControl:@"minimize"];
          ArcSpace* home = w.currentSpace, *away = nil;
          for (ArcSpace* s in w.spaces)
            if (![s.profileDirectory isEqualToString:home.profileDirectory]) away = s;
          WaitUntil(mini, 6, ^{
            [w switchToSpace:away];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
              clickCase(away && w.currentSpace == away ? @"space" : @"space-noswitch", ^{
                toFloat(^{
                  [w pressFloatingControl:@"minimize"];
                  [w switchToSpace:home];
                  WaitUntil(mini, 6, ^{
                    [self runFloatResizeSelfTest:t then:^{
                      // 4. The X: a real click stops the sound (the page's video pauses) and the player goes.
                      WaitUntil(mini, 6, ^{
                        BOOL ready = mini();
                        [w setMediaCardHoveredForTest:YES];
                        NSString* hit = [w clickMiniPlayerControl:@"close"];
                        WaitUntil(^{ [w pollMediaNow]; return (BOOL)(!t.mediaPlaying && w.mediaBarItem != t); }, 5, ^{
                          [w runJS:@"document.title='x:'+(document.querySelector('video').paused?1:0)" inItem:t];
                          WaitUntil(^{ return [t.liveTitle hasPrefix:@"x:"]; }, 3, ^{
                            BOOL paused = [t.liveTitle isEqualToString:@"x:1"];
                            std::printf("SELFTEST-MINICLOSECLICK ready=%d hitButton=%d stopped=%d pagePaused=%d removed=%d\n",
                                        ready, [hit isEqualToString:@"button"], !t.mediaPlaying, paused, w.mediaBarItem != t);
                            if (![hit isEqualToString:@"button"]) std::printf("MINICLOSECLICK-DEBUG hit=%s\n", hit.UTF8String);
                            std::fflush(stdout);
                            [w setMediaCardHoveredForTest:NO];
                            // Playing again brings the mini player back for the checks after this one.
                            [w runJS:@"(()=>{document.title='Media test page';const v=document.querySelector('video');"
                                     @"v.__notarcPaused=false;v.play();})()" inItem:t];
                            WaitUntil(mini, 6, ^{ done(); });
                          });
                        });
                      });
                    }];
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}

// Floating video resize (Omar, Nov 13): real drags on the float's corner and edge, in the hidden float. The size follows
// the pointer within Arc's limits and the screen, keeps the video's shape and the opposite corner, the controls fit at
// the smallest and largest sizes, and the size is remembered for the next float.
- (void)runFloatResizeSelfTest:(ArcItem*)t then:(void (^)(void))done {
  MainWindowController* w = self.window;
  BOOL (^floating)(void) = ^BOOL { return w.floatingVideoWindow != nil && w.floatingVideoItem == t; };
  [w pressMiniPlayerControl:@"reopen"];
  WaitUntil(floating, 6, ^{
    BOOL had = floating();
    NSRect f0 = w.floatingVideoFrame;
    double aspect = NSWidth(f0) > 0 ? NSHeight(f0) / NSWidth(f0) : 0;
    NSRect vis = w.floatingVideoWindow.screen.visibleFrame;
    // The top-right corner, 100 pt out: the bottom-left corner stays.
    NSPoint c = NSMakePoint(NSMaxX(f0) - 2, NSMaxY(f0) - 2);
    NSString* hit = [w dragInWindowForTest:w.floatingControlsWindow fromScreen:c toScreen:NSMakePoint(c.x + 100, c.y + 100 * aspect)];
    NSRect f1 = w.floatingVideoFrame;
    BOOL resized = NSWidth(f1) >= NSWidth(f0) + 95 && NSWidth(f1) <= NSWidth(f0) + 105;
    BOOL keepsAspect = NSWidth(f1) > 0 && fabs(NSHeight(f1) / NSWidth(f1) - aspect) < 0.02;
    BOOL anchored = fabs(NSMinX(f1) - NSMinX(f0)) < 1 && fabs(NSMinY(f1) - NSMinY(f0)) < 1 &&
                    w.floatingVideoWindow.parentWindow == w.window;
    BOOL saved = resized && fabs(SettingDouble(@"floatingVideoWidth") - NSWidth(f1)) < 1;
    BOOL cursor = [w.floatingControlsState containsString:@"resizeCursor=1"];
    // As far as it goes: Arc's largest size (or the screen), the controls laid out inside.
    c = NSMakePoint(NSMaxX(f1) - 2, NSMaxY(f1) - 2);
    [w dragInWindowForTest:w.floatingControlsWindow fromScreen:c toScreen:NSMakePoint(c.x + 3000, c.y + 3000)];
    NSRect fmax = w.floatingVideoFrame;
    BOOL maxOK = NSWidth(fmax) <= kFloatingVideoMaxWidth + 0.5 &&
                 (NSWidth(fmax) >= kFloatingVideoMaxWidth - 0.5 || NSMaxX(fmax) >= NSMaxX(vis) - 1 || NSMaxY(fmax) >= NSMaxY(vis) - 1);
    BOOL onScreenMax = NSContainsRect(NSInsetRect(vis, -0.5, -0.5), fmax);
    BOOL fitsMax = [w.floatingControlsState containsString:@"fits=1"];
    // And as small as it goes.
    c = NSMakePoint(NSMaxX(fmax) - 2, NSMaxY(fmax) - 2);
    [w dragInWindowForTest:w.floatingControlsWindow fromScreen:c toScreen:NSMakePoint(c.x - 3000, c.y - 3000)];
    NSRect fmin = w.floatingVideoFrame;
    BOOL minOK = fabs(NSWidth(fmin) - kFloatingVideoMinWidth) < 0.5 && fabs(NSHeight(fmin) / NSWidth(fmin) - aspect) < 0.02;
    BOOL fitsMin = [w.floatingControlsState containsString:@"fits=1"];
    BOOL anchoredMin = fabs(NSMinX(fmin) - NSMinX(f0)) < 1 && fabs(NSMinY(fmin) - NSMinY(f0)) < 1;
    // The left edge, 60 pt out: the right edge stays.
    NSPoint e = NSMakePoint(NSMinX(fmin) + 2, NSMidY(fmin));
    [w dragInWindowForTest:w.floatingControlsWindow fromScreen:e toScreen:NSMakePoint(e.x - 60, e.y)];
    NSRect fe = w.floatingVideoFrame;
    BOOL edge = fabs(NSWidth(fe) - NSWidth(fmin) - 60) <= 1 && fabs(NSMaxX(fe) - NSMaxX(fmin)) < 1 &&
                fabs(NSHeight(fe) / NSWidth(fe) - aspect) < 0.02 && NSContainsRect(NSInsetRect(vis, -0.5, -0.5), fe);
    CGFloat kept = NSWidth(fe);
    // Remembered: the next float comes back at that size.
    [w pressFloatingControl:@"minimize"];
    WaitUntil(^{ return (BOOL)!floating(); }, 5, ^{
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w pressMiniPlayerControl:@"reopen"];
        WaitUntil(floating, 6, ^{
          NSRect fr = w.floatingVideoFrame;
          BOOL remembered = floating() && fabs(NSWidth(fr) - kept) < 1 && NSWidth(fe) > NSWidth(fmin) + 30;
          std::printf("SELFTEST-FLOATRESIZE floated=%d resized=%d keepsAspect=%d anchored=%d saved=%d cursor=%d maxOK=%d "
                      "onScreen=%d fitsMax=%d minOK=%d fitsMin=%d anchoredMin=%d edge=%d remembered=%d\n", had, resized,
                      keepsAspect, anchored, saved, cursor, maxOK, onScreenMax, fitsMax, minOK, fitsMin, anchoredMin, edge,
                      remembered);
          if (!(resized && minOK && edge && remembered))
            std::printf("FLOATRESIZE-DEBUG hit=%s f0=%s f1=%s max=%s min=%s edge=%s again=%s screen=%s state=%s\n",
                        hit.UTF8String, NSStringFromRect(f0).UTF8String, NSStringFromRect(f1).UTF8String,
                        NSStringFromRect(fmax).UTF8String, NSStringFromRect(fmin).UTF8String, NSStringFromRect(fe).UTF8String,
                        NSStringFromRect(fr).UTF8String, NSStringFromRect(vis).UTF8String, w.floatingControlsState.UTF8String);
          std::fflush(stdout);
          SettingSetObject(@"floatingVideoWidth", nil);  // Arc's size again for the checks after this one
          [w pressFloatingControl:@"minimize"];
          done();
        });
      });
    });
  });
}

// Sidebar resize (Omar, Nov 13: dragging its right edge did nothing). Real drags on the edge of the hidden window: the
// width follows the pointer within Arc's limits, the cursor changes on the edge, everything fits at every width, and
// the width is kept per window (the main window's in the settings, the others' in Windows.json).
- (void)runSidebarResizeSelfTest:(void (^)(void))done {
  MainWindowController* w = self.window;
  NSPoint (^edgeOf)(MainWindowController*) = ^NSPoint(MainWindowController* c) {
    NSRect f = c.window.frame;
    return NSMakePoint(NSMinX(f) + c.sidebarWidth - 1, NSMinY(f) + NSHeight(f) / 2);
  };
  CGFloat w0 = w.sidebarWidth;
  NSPoint a = edgeOf(w);
  NSString* hit = [w dragInWindowForTest:w.window fromScreen:a toScreen:NSMakePoint(a.x + 60, a.y)];
  CGFloat w1 = w.sidebarWidth;
  BOOL follows = fabs(w1 - (w0 + 60)) <= 1;
  BOOL handle = [w.sidebarEdgeState containsString:@"handle=1"], cursor = [w.sidebarEdgeState containsString:@"cursor=1"];
  BOOL saved = follows && fabs(SettingDouble(@"sidebarWidth") - w1) < 0.5;
  NSString* midState = w.sidebarLayoutState;
  a = edgeOf(w);
  [w dragInWindowForTest:w.window fromScreen:a toScreen:NSMakePoint(a.x + 1000, a.y)];
  CGFloat wmax = w.sidebarWidth;
  NSString* maxState = w.sidebarLayoutState;
  a = edgeOf(w);
  [w dragInWindowForTest:w.window fromScreen:a toScreen:NSMakePoint(a.x - 1000, a.y)];
  CGFloat wmin = w.sidebarWidth;
  NSString* minState = w.sidebarLayoutState;
  BOOL limits = fabs(wmax - kSidebarMaxWidth) < 0.5 && fabs(wmin - kSidebarMinWidth) < 0.5;
  a = edgeOf(w);
  [w dragInWindowForTest:w.window fromScreen:a toScreen:NSMakePoint(a.x + 50, a.y)];
  CGFloat wmain = w.sidebarWidth;  // 250: the main window's, saved for the next launch
  // Another window: its own width comes back from Windows.json, and a drag there changes only that window's.
  ArcSpace* sp = w.currentSpace;
  NSArray<MainWindowController*>* opened = [w restoreWindowsFromList:@[ @{@"space" : sp.spaceID ?: @"", @"sidebarWidth" : @310} ]];
  MainWindowController* w2 = opened.firstObject;
  BOOL perWindowRestored = w2 && fabs(w2.sidebarWidth - 310) < 0.5;
  a = edgeOf(w2);
  [w dragInWindowForTest:w2.window fromScreen:a toScreen:NSMakePoint(a.x + 20, a.y)];
  NSDictionary* entry = nil;
  for (NSDictionary* d in [MainWindowController windowStateList]) entry = d;
  BOOL perWindowSaved = w2 && fabs(w2.sidebarWidth - 330) <= 1 && fabs([entry[@"sidebarWidth"] doubleValue] - w2.sidebarWidth) < 0.5 &&
                        fabs(w.sidebarWidth - wmain) < 0.5 && fabs(SettingDouble(@"sidebarWidth") - wmain) < 0.5;
  // A window with no width of its own (and the main window at the next launch) opens at the saved one.
  NSArray<MainWindowController*>* fresh = [w restoreWindowsFromList:@[ @{@"space" : sp.spaceID ?: @""} ]];
  MainWindowController* w3 = fresh.firstObject;
  BOOL launch = w3 && fabs(wmain - (kSidebarMinWidth + 50)) <= 1 && fabs(w3.sidebarWidth - wmain) < 0.5;
  NSString* w2State = w2.sidebarLayoutState;
  [w2.window close];
  [w3.window close];
  [w setSidebarWidth:kSidebarDefaultWidth];
  SettingSetObject(@"sidebarWidth", nil);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
    std::printf("SELFTEST-SIDEBARRESIZE handle=%d cursor=%d follows=%d saved=%d limits=%d fitsMid=%d fitsMax=%d fitsMin=%d "
                "fitsOther=%d perWindowRestored=%d perWindowSaved=%d launch=%d backToDefault=%d\n", handle, cursor, follows,
                saved, limits, [midState hasPrefix:@"fits=1"], [maxState hasPrefix:@"fits=1"], [minState hasPrefix:@"fits=1"],
                [w2State hasPrefix:@"fits=1"], perWindowRestored, perWindowSaved, launch,
                fabs(w.sidebarWidth - kSidebarDefaultWidth) < 0.5);
    if (!(follows && limits && perWindowSaved && [maxState hasPrefix:@"fits=1"] && [minState hasPrefix:@"fits=1"]))
      std::printf("SIDEBARRESIZE-DEBUG hit=%s w0=%.0f w1=%.0f max=%.0f min=%.0f main=%.0f w2=%.0f mid=[%s] maxS=[%s] minS=[%s] "
                  "other=[%s]\n", hit.UTF8String, w0, w1, wmax, wmin, wmain, w2.sidebarWidth, midState.UTF8String,
                  maxState.UTF8String, minState.UTF8String, w2State.UTF8String);
    std::fflush(stdout);
    done();
  });
}

// Sidebar hide and show (Omar, Nov 13: after the toggle hid the sidebar he couldn't bring it back). Arc 1.169: the page
// keeps an even margin all round, the pointer at the window's left edge slides the sidebar out over the page and
// leaving hides it, the toggle (or Cmd-S) there pins it back, and each window keeps its own state. Real clicks and
// pointer moves (posted mouse-moved events, as the window server sends them).
- (void)runSidebarToggleSelfTest:(void (^)(void))done {
  MainWindowController* w = self.window;
  NSWindow* win = w.window;
  if (w.sidebarHidden) [w toggleSidebar:nil];
  void (^move)(NSPoint) = ^(NSPoint screen) {
    [NSApp postEvent:[NSEvent mouseEventWithType:NSEventTypeMouseMoved location:[win convertPointFromScreen:screen]
                                   modifierFlags:0 timestamp:NSProcessInfo.processInfo.systemUptime
                                    windowNumber:win.windowNumber context:nil eventNumber:0 clickCount:0 pressure:0]
             atStart:NO];
  };
  BOOL (^peeking)(void) = ^BOOL { return [w.sidebarPeekState hasPrefix:@"peeking=1"]; };
  NSPoint leftEdge = NSMakePoint(NSMinX(win.frame) + 1, NSMidY(win.frame));
  NSPoint middle = NSMakePoint(NSMidX(win.frame) + 200, NSMidY(win.frame));
  // 1. A real click on the toggle hides the sidebar; the page keeps an even, rounded margin on all four sides.
  NSString* hit1 = [w clickAtScreenForTest:w.sidebarToggleScreenPoint];
  BOOL clickHides = w.sidebarHidden;
  BOOL savedHidden = SettingBool(@"sidebarHidden");
  NSRect card = w.pageCardFrame, b = win.contentView.bounds;
  CGFloat l = NSMinX(card), r = NSMaxX(b) - NSMaxX(card), bt = NSMinY(card), tp = NSMaxY(b) - NSMaxY(card);
  BOOL equalInsets = w.toolbarShown || (l >= 4 && fabs(l - r) < 0.5 && fabs(l - bt) < 0.5 && fabs(l - tp) < 0.5 && w.pageCardCornerRadius > 0);
  // 2. The pointer at the far left edge slides it out over the page (the page stays put).
  move(leftEdge);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    BOOL hoverShows = peeking();
    if (!hoverShows) [w beginSidebarPeekForTest];  // so the rest still runs
    BOOL pageStays = NSEqualRects(w.pageCardFrame, card);
    BOOL onTop = [w topWindowAtScreenPointForTest:w.sidebarToggleScreenPoint] == w.sidebarToggleWindow && w.sidebarToggleWindow;
    // 3. Leaving it hides it again.
    move(middle);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      BOOL leaveHides = !peeking() && w.sidebarHidden;
      if (peeking()) [w endSidebarPeekForTest];
      // 4. Out again, and a real click on its toggle pins it back: docked, the page laid out beside it.
      move(leftEdge);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BOOL hoverAgain = peeking();
        if (!hoverAgain) [w beginSidebarPeekForTest];
        NSString* hit2 = [w clickAtScreenForTest:w.sidebarToggleScreenPoint];
        BOOL pinClick = !w.sidebarHidden && !peeking() && NSMinX(w.pageCardFrame) >= w.sidebarWidth - 0.5 &&
                        !SettingBool(@"sidebarHidden");
        if (peeking()) [w endSidebarPeekForTest];
        if (w.sidebarHidden) [w toggleSidebar:nil];
        // 5. Cmd-S (Arc's Hide Sidebar / Show Sidebar) both ways, and from the floating sidebar it pins it.
        NSMenuItem* key = nil;
        for (NSMenuItem* top in NSApp.mainMenu.itemArray)
          for (NSMenuItem* it in top.submenu.itemArray)
            if ([it.keyEquivalent isEqualToString:@"s"] && it.keyEquivalentModifierMask == NSEventModifierFlagCommand) key = it;
        BOOL shortcut = key.action == @selector(toggleSidebar:);
        if (shortcut) [NSApp sendAction:key.action to:w from:key];
        BOOL keyHides = w.sidebarHidden;
        if (shortcut) [NSApp sendAction:key.action to:w from:key];
        BOOL keyShows = !w.sidebarHidden;
        if (!w.sidebarHidden) [w toggleSidebar:nil];
        [w beginSidebarPeekForTest];
        if (shortcut) [NSApp sendAction:key.action to:w from:key];
        BOOL keyPins = !w.sidebarHidden && !peeking();
        if (peeking()) [w endSidebarPeekForTest];
        if (w.sidebarHidden) [w toggleSidebar:nil];
        // 6. Per window: one saved hidden opens hidden; hiding or showing it is saved with it, not as the main window's.
        ArcSpace* sp = w.currentSpace;
        MainWindowController* w2 = [w restoreWindowsFromList:@[ @{@"space" : sp.spaceID ?: @"", @"sidebarHidden" : @YES} ]].firstObject;
        BOOL opensHidden = w2 && w2.sidebarHidden;
        [w2 toggleSidebar:nil];
        NSDictionary* entry = nil;
        for (NSDictionary* d in [MainWindowController windowStateList]) entry = d;
        BOOL savedShown = w2 && !w2.sidebarHidden && entry && ![entry[@"sidebarHidden"] boolValue];
        [w2 toggleSidebar:nil];
        for (NSDictionary* d in [MainWindowController windowStateList]) entry = d;
        BOOL perWindow = opensHidden && savedShown && [entry[@"sidebarHidden"] boolValue] && !w.sidebarHidden &&
                         !SettingBool(@"sidebarHidden");
        [w2.window close];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
          std::printf("SELFTEST-SIDEBARTOGGLE clickHides=%d savedHidden=%d equalInsets=%d hoverShows=%d pageStays=%d overlayOnTop=%d "
                      "leaveHides=%d hoverAgain=%d pinClick=%d shortcut=%d keyHides=%d keyShows=%d keyPins=%d perWindow=%d\n",
                      clickHides, savedHidden, equalInsets, hoverShows, pageStays, onTop, leaveHides, hoverAgain, pinClick,
                      shortcut, keyHides, keyShows, keyPins, perWindow);
          if (!(clickHides && equalInsets && hoverShows && onTop && pinClick && perWindow))
            std::printf("SIDEBARTOGGLE-DEBUG hit1=%s hit2=%s card=%s insets=%.1f/%.1f/%.1f/%.1f radius=%.1f opensHidden=%d "
                        "savedShown=%d\n", hit1.UTF8String, hit2.UTF8String, NSStringFromRect(card).UTF8String, l, r, bt, tp,
                        w.pageCardCornerRadius, opensHidden, savedShown);
          std::fflush(stdout);
          done();
        });
      });
    });
  });
}

// E-G: a tab switch while a request waits (Chromium takes the request off a hidden tab and asks again when it's shown,
// so one request can reach NotArc twice), a remembered request from a background tab, and a remembered request with
// the tab switched away and back at once.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
// H. As YouTube and Google Calendar ask: a service worker's push subscription and the page's own request at once
// (both are the notifications permission), then Allow.
- (void)runSitePermissionPushCase:(void (^)(ArcItem*))done {
  MainWindowController* w = self.window;
  NSString* html = @"<!doctype html><title>perm</title><body>ask</body>";
  NSData* page = [html dataUsingEncoding:NSUTF8StringEncoding];
  NSData* sw = [@"self.addEventListener('push',()=>{});" dataUsingEncoding:NSUTF8StringEncoding];
  BrowserClient::SetTestResponse("https://perm-h.example/sw.js", std::string((const char*)sw.bytes, sw.length));
  BrowserClient::SetTestResponse("https://perm-h.example/", std::string((const char*)page.bytes, page.length));
  [w openInNewTab:@"https://perm-h.example/"];
  ArcItem* h = w.shownItem;
  WaitUntil(^{ return (BOOL)(!h.loading && [h.liveTitle isEqualToString:@"perm"]); }, 10, ^{
    [w runJS:@"(async()=>{try{const r=await navigator.serviceWorker.register('/sw.js');await navigator.serviceWorker.ready;"
             @"const a=r.pushManager.subscribe({userVisibleOnly:true,applicationServerKey:"
             @"'BEl62iUYgUivxIkv69yViEuiBIa-Ib9-SkvMeAtA3LFgDzkrxZJjSgSnfckjBJuBkr3qBUYIHBQFLXYp5Nksh8U'}).catch(e=>'sub:'+e.name);"
             @"const b=Notification.requestPermission();const [x,y]=await Promise.all([a,b]);document.title='n:'+y+'|'+(typeof x==='string'?x:'sub');"
             @"}catch(e){document.title='n:err:'+e.name;}})()"
        inItem:h];
    __block int clicks = 0;
    __block void (^answer)(int);
    answer = ^(int left) {
      if (w.pendingSitePrompt) {
        [w clickAtScreenForTest:[w sitePromptButtonScreenPoint:YES]];
        ++clicks;
      }
      if (left <= 0 || [h.liveTitle hasPrefix:@"n:"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          std::printf("SELFTEST-PERMPUSH survived=1\n");
          std::printf("PERMPUSH-DEBUG cards=%d\n", clicks);
          std::printf("PERMPUSH-DEBUG title=%s\n", h.liveTitle.UTF8String ?: "-");
          std::fflush(stdout);
          BrowserClient::SetTestResponse("https://perm-h.example/sw.js", "");
          dispatch_async(dispatch_get_main_queue(), ^{
            answer = nil;
            done(h);
          });
        });
        return;
      }
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ answer(left - 1); });
    };
    answer(20);
  });
}

- (void)runSitePermissionSwitchCases:(NSArray<ArcItem*>*)earlier done:(void (^)(void))done {
  MainWindowController* w = self.window;
  NSString* html = @"<!doctype html><title>perm</title><body>ask</body>";
  NSData* page = [html dataUsingEncoding:NSUTF8StringEncoding];
  for (NSString* u in @[ @"https://perm-e.example/", @"https://perm-f.example/", @"https://perm-g.example/" ])
    BrowserClient::SetTestResponse(u.UTF8String, std::string((const char*)page.bytes, page.length));
  NSString* ask = @"Notification.requestPermission().then(r=>document.title='n:'+r,e=>document.title='n:err')";
  ArcItem* other = earlier.firstObject;
  // Clicks Allow on every card that shows within a few seconds (a request asked again shows again).
  __block void (^allowAll)(int, int, void (^)(int));
  allowAll = ^(int left, int clicks, void (^then)(int)) {
    if (left <= 0) { then(clicks); return; }
    if (w.pendingSitePrompt) {
      [w clickAtScreenForTest:[w sitePromptButtonScreenPoint:YES]];
      ++clicks;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ allowAll(left - 1, clicks, then); });
  };
  [w openInNewTab:@"https://perm-e.example/"];
  ArcItem* e = w.shownItem;
  WaitUntil(^{ return (BOOL)(!e.loading && [e.liveTitle isEqualToString:@"perm"]); }, 10, ^{
    [w runJS:ask inItem:e];
    WaitUntil(^{ return (BOOL)(w.pendingSitePrompt.length > 0); }, 10, ^{
      BOOL asked = w.pendingSitePrompt != nil;
      [w showItem:other];  // away while the card waits, and back
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        [w showItem:e];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          allowAll(8, 0, ^(int clicks) {
            std::printf("SELFTEST-PERMSWITCH asked=%d granted=%d survived=1 cardsAnswered=%d\n", asked,
                        [e.liveTitle isEqualToString:@"n:granted"], clicks);
            std::fflush(stdout);
            // F. Remembered, asked from a tab in the background, then shown.
            [w rememberSite:@"https://perm-f.example" names:@[ @"notifications" ] allow:YES];
            [w openInNewTab:@"https://perm-f.example/" background:YES];
            ArcItem* f = nil;
            for (ArcItem* x in w.currentSpace.allTabs)
              if ([x.url hasPrefix:@"https://perm-f.example"]) f = x;
            WaitUntil(^{ return (BOOL)(f && !f.loading && [f.liveTitle isEqualToString:@"perm"]); }, 10, ^{
              [w runJS:ask inItem:f];
              dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [w showItem:f];
                WaitUntil(^{ return (BOOL)[f.liveTitle hasPrefix:@"n:"]; }, 6, ^{
                  std::printf("SELFTEST-PERMBACKGROUND survived=1\n");  // Chromium holds a hidden tab's request; nothing to answer
                  std::printf("PERMBACKGROUND-DEBUG title=%s\n", f.liveTitle.UTF8String ?: "-");
                  std::fflush(stdout);
                  // G. Remembered, and the tab switched away and back at once.
                  [w rememberSite:@"https://perm-g.example" names:@[ @"notifications" ] allow:YES];
                  [w openInNewTab:@"https://perm-g.example/"];
                  ArcItem* g = w.shownItem;
                  WaitUntil(^{ return (BOOL)(!g.loading && [g.liveTitle isEqualToString:@"perm"]); }, 10, ^{
                    [w runJS:ask inItem:g];
                    for (int i = 0; i < 3; ++i) {
                      [w showItem:other];
                      [w showItem:g];
                    }
                    WaitUntil(^{ return (BOOL)[g.liveTitle hasPrefix:@"n:"]; }, 6, ^{
                      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                        std::printf("SELFTEST-PERMQUICKSWITCH granted=%d survived=1\n", [g.liveTitle isEqualToString:@"n:granted"]);
                        std::fflush(stdout);
                        [self runSitePermissionPushCase:^(ArcItem* hItem) {
                        NSMutableArray* all = [earlier mutableCopy];
                        for (ArcItem* x in @[ e, f ?: e, g ]) if (![all containsObject:x]) [all addObject:x];
                        for (ArcItem* x in all) {
                          if (w.shownItem != x) [w showItem:x];
                          [w resetSitePermissions:nil];
                          [w closeCurrentTab];
                        }
                        if (hItem) {
                          if (w.shownItem != hItem) [w showItem:hItem];
                          [w resetSitePermissions:nil];
                          [w closeCurrentTab];
                        }
                        dispatch_async(dispatch_get_main_queue(), ^{
                          allowAll = nil;  // the block refers to itself; let it go on the next turn
                          done();
                        });
                        }];
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}
#pragma clang diagnostic pop

// Site requests (Omar, Nov 13: NotArc closed twice, the second time 17 s after it reopened, inside Chromium's
// PermissionRequest::PermissionGranted when NotArc answered Allow). Local pages ask for notifications: a real click
// on Allow (remembered), the next request answered from what was remembered, two requests at once, and a request
// answered after the page went on to another address. Each must end with the page told, and NotArc still running.
- (void)runSitePermissionSelfTest:(void (^)(void))done {
  MainWindowController* w = self.window;
  NSString* html = @"<!doctype html><title>perm</title><body>ask</body>";
  NSData* page = [html dataUsingEncoding:NSUTF8StringEncoding];
  for (NSString* u in @[ @"https://perm-a.example/", @"https://perm-b.example/", @"https://perm-c.example/", @"https://perm-d.example/",
                          @"https://perm-d.example/next" ])
    BrowserClient::SetTestResponse(u.UTF8String, std::string((const char*)page.bytes, page.length));
  NSString* ask = @"Notification.requestPermission().then(r=>document.title='n:'+r,e=>document.title='n:err')";
  void (^open)(NSString*, void (^)(ArcItem*)) = ^(NSString* url, void (^then)(ArcItem*)) {
    [w openInNewTab:url];
    ArcItem* t = w.shownItem;
    WaitUntil(^{ return (BOOL)(!t.loading && [t.liveTitle isEqualToString:@"perm"]); }, 10, ^{ then(t); });
  };
  // A. A real click on Allow (Remember ticked), on the request's own card.
  open(@"https://perm-a.example/", ^(ArcItem* a) {
    [w runJS:ask inItem:a];
    WaitUntil(^{ if (w.shownItem != a) [w showItem:a]; return (BOOL)(w.pendingSitePrompt.length > 0); }, 10, ^{
      BOOL asked = [w.pendingSitePrompt hasPrefix:@"notifications:"];
      [w setSitePromptRememberForTest:YES];
      NSString* hit = [w clickAtScreenForTest:[w sitePromptButtonScreenPoint:YES]];
      WaitUntil(^{ return (BOOL)[a.liveTitle hasPrefix:@"n:"]; }, 6, ^{
        BOOL granted = [a.liveTitle isEqualToString:@"n:granted"];
        BOOL remembered = [[w sitePermissionsForOrigin:@"https://perm-a.example"][@"notifications"] boolValue];
        std::printf("SELFTEST-PERMCLICK asked=%d clickedAllow=%d granted=%d remembered=%d\n", asked,
                    [hit hasSuffix:@":NSButton"], granted, remembered);
        std::fflush(stdout);
        // B. Remembered "yes" (as after a relaunch): answered at once, no card.
        [w rememberSite:@"https://perm-b.example" names:@[ @"notifications" ] allow:YES];
        open(@"https://perm-b.example/", ^(ArcItem* b) {
          [w runJS:ask inItem:b];
          WaitUntil(^{ return (BOOL)[b.liveTitle hasPrefix:@"n:"]; }, 6, ^{
            std::printf("SELFTEST-PERMREMEMBERED granted=%d noCard=%d\n", [b.liveTitle isEqualToString:@"n:granted"],
                        w.pendingSitePrompt == nil);
            std::fflush(stdout);
            // C. Two requests at once (pages often ask twice), then Allow.
            open(@"https://perm-c.example/", ^(ArcItem* c) {
              [w runJS:[NSString stringWithFormat:@"%@;Notification.requestPermission();", ask] inItem:c];
              WaitUntil(^{ if (w.shownItem != c) [w showItem:c]; return (BOOL)(w.pendingSitePrompt.length > 0); }, 10, ^{
                [w setSitePromptRememberForTest:NO];
                NSString* hitC = [w clickAtScreenForTest:[w sitePromptButtonScreenPoint:YES]];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                  if (w.pendingSitePrompt) [w clickAtScreenForTest:[w sitePromptButtonScreenPoint:YES]];  // a second card
                  WaitUntil(^{ return (BOOL)[c.liveTitle hasPrefix:@"n:"]; }, 6, ^{
                    std::printf("SELFTEST-PERMTWICE clickedAllow=%d granted=%d\n", [hitC hasSuffix:@":NSButton"],
                                [c.liveTitle isEqualToString:@"n:granted"]);
                    std::fflush(stdout);
                    // D. The page moves on before the answer: Allow then must not reach a request Chromium dropped.
                    open(@"https://perm-d.example/", ^(ArcItem* d) {
                      [w runJS:ask inItem:d];
                      WaitUntil(^{ if (w.shownItem != d) [w showItem:d]; return (BOOL)(w.pendingSitePrompt.length > 0); }, 10, ^{
                        [w runJS:@"location.href='https://perm-d.example/next'" inItem:d];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                          if (w.pendingSitePrompt) [w clickAtScreenForTest:[w sitePromptButtonScreenPoint:YES]];
                          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                            std::printf("SELFTEST-PERMAFTERLEAVE survived=1 noCardLeft=%d\n", w.pendingSitePrompt == nil);
                            std::fflush(stdout);
                            [self runSitePermissionSwitchCases:@[ a, b, c, d ] done:done];
                          });
                        });
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
  });
}

- (void)runFloatingVideoThenPageFit:(void (^)(void))done {
  [self runFloatingVideoSelfTest:^{ [self runSidebarResizeSelfTest:^{ [self runSidebarToggleSelfTest:^{ [self runSitePermissionSelfTest:^{ [self runPageFitSelfTest:done]; }]; }]; }]; }];
}

- (void)runSelfTestActions {
  if ([NSProcessInfo.processInfo.environment[@"NOTARC_SELFTEST_ONLY"] isEqualToString:@"buttons"]) {  // quick local loop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self runWindowButtonsSelfTest:^{
        std::printf("SELFTEST-REALPROFILE %s\n", TestIsolationReport().UTF8String);
        std::fflush(stdout);
        [self.window closeAllBrowsers];
      }];
    });
    return;
  }
  if ([NSProcessInfo.processInfo.environment[@"NOTARC_SELFTEST_ONLY"] isEqualToString:@"pagefit"]) {  // quick local loop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self runPageFitSelfTest:^{
        std::printf("SELFTEST-REALPROFILE %s\n", TestIsolationReport().UTF8String);
        std::fflush(stdout);
        [self.window closeAllBrowsers];
      }];
    });
    return;
  }
  if ([NSProcessInfo.processInfo.environment[@"NOTARC_SELFTEST_ONLY"] isEqualToString:@"permissions"]) {  // quick local loop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self runSitePermissionSelfTest:^{
        std::printf("SELFTEST-REALPROFILE %s\n", TestIsolationReport().UTF8String);
        std::fflush(stdout);
        [self.window closeAllBrowsers];
      }];
    });
    return;
  }
  if ([NSProcessInfo.processInfo.environment[@"NOTARC_SELFTEST_ONLY"] isEqualToString:@"miniplayer"]) {  // quick local loop
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [self runFloatingVideoSelfTest:^{
       [self runSidebarResizeSelfTest:^{
       [self runSidebarToggleSelfTest:^{
        std::printf("SELFTEST-REALPROFILE %s\n", TestIsolationReport().UTF8String);
        std::fflush(stdout);
        [self.window closeAllBrowsers];
       }];
       }];
      }];
    });
    return;
  }
  [self runAlertLookSelfTest];
  [self runSpaceCardsSelfTest];
  [self runWelcomeSelfTest];
  [self.window openInNewTab:@"https://example.com"];
  [self runBasicsTestWhenReady:0];
}

// Tab thumbnails (#65) in hover cards (#19) and the Ctrl+Tab switcher. Runs last in the late chain (sets gLateTestsDone).
- (void)runThumbnailSelfTest:(ArcItem*)src leaving:(ArcItem*)t {
  MainWindowController* w = self.window;
  [w showItem:src];
  [w runJS:@"document.documentElement.style.background='#3b82f6';document.body.style.background='#3b82f6';"
           @"document.body.innerHTML='';document.title='thumb:blue'" inItem:src];
  WaitUntil(^{ return [src.liveTitle isEqualToString:@"thumb:blue"]; }, 5, ^{
    NSImage* before = src.thumbnail;
    [w scheduleThumbnailOfShown];  // the page is blue now: copy it 1 s from now
    WaitUntil(^{
      if (w.shownItem != src) { [w showItem:src]; }  // other timed checks may switch tabs; showing again restarts the wait
      return (BOOL)(src.thumbnail != nil && src.thumbnail != before);
    }, 8, ^{
      NSImage* th = src.thumbnail;
      CGImageRef cg = [th CGImageForProposedRect:NULL context:nil hints:nil];
      NSBitmapImageRep* px = cg ? [[NSBitmapImageRep alloc] initWithCGImage:cg] : nil;
      BOOL taken = th != nil && th != before;
      BOOL small = px && px.pixelsWide <= 480 && px.pixelsWide >= 200 && px.pixelsHigh <= px.pixelsWide;
      NSColor* mid = [[px colorAtX:px.pixelsWide / 2 y:px.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
      // The hidden test window is 1% opaque, so the copy keeps the page's hue, not its exact colour: check it's clearly blue.
      BOOL page = mid && mid.blueComponent - mid.redComponent > 0.15 && mid.blueComponent - mid.greenComponent > 0.15;
      if (!page) std::printf("THUMB-DEBUG mid=%.2f,%.2f,%.2f %ldx%ld\n", mid.redComponent, mid.greenComponent, mid.blueComponent,
                             (long)px.pixelsWide, (long)px.pixelsHigh);
      [w showItem:t];
      [w showHoverCardForItem:src];
      BOOL inCard = w.hoverCardHasThumbnail;
      NSString* hoverLook = w.hoverCardStyle;  // Visual parity V34: Arc's card (picture edge to edge, link row)
      [w hideHoverCard];
      [w showHoverCardForItem:t];  // the tab on screen shows no (stale) picture
      BOOL notShown = !w.hoverCardHasThumbnail;
      [w hideHoverCard];
      // Ctrl+Tab held: the shown tab first, the tab just left selected, with its picture; Tab steps, release switches.
      [w openTabSwitcherHolding:0];
      NSArray<ArcItem*>* items = w.tabSwitcherItems;
      BOOL open = w.tabSwitcherShown;
      BOOL order = items.count >= 2 && items[0] == t && items[1] == src && w.tabSwitcherSelection == src;
      BOOL thumb = [w tabSwitcherShowsThumbnailFor:src];
      NSString* switcherLook = w.tabSwitcherStyle;  // Visual parity V33
      [w stepTabSwitcher:1];
      BOOL stepped = w.tabSwitcherSelection == (items.count > 2 ? items[2] : items[0]);
      [w stepTabSwitcher:-1];
      [w commitTabSwitcher];
      BOOL switched = w.shownItem == src && !w.tabSwitcherShown;
      [w openTabSwitcherHolding:0];
      [w cancelTabSwitcher];
      BOOL cancelled = w.shownItem == src && !w.tabSwitcherShown;
      // Flip between the two tabs every 0.15 s, as someone tapping through tabs would. Each switch only re-arms the
      // 1 s timer, so no copy may start while flipping, and the thumbnail code's share of a switch must stay tiny.
      long startedBeforeFlips = TabThumbnailStatsGet().started;
      NSMutableArray<NSNumber*>* flipMs = [NSMutableArray array];
      const int kFlips = 10;
      for (int f = 0; f < kFlips; ++f)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(f * 0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
          CFAbsoluteTime f0 = CFAbsoluteTimeGetCurrent();
          [w showItem:(f % 2 == 0) ? t : src];
          [flipMs addObject:@((CFAbsoluteTimeGetCurrent() - f0) * 1000)];
        });
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kFlips - 1) * 0.15 * NSEC_PER_SEC + 0.3 * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
        // The point of this design (#176 was reverted for it): starting a copy and receiving it cost the main thread
        // almost nothing, unlike the synchronous window copy (10-110 ms each).
        TabThumbnailStats s = TabThumbnailStatsGet();
        BOOL fast = s.started > 0 && s.maxKickoffMs < 5 && s.maxDeliverMs < 5;
        BOOL flipNoCopy = flipMs.count == kFlips && s.started == startedBeforeFlips;
        BOOL switchFast = s.switches >= kFlips && s.maxSwitchHookMs < 1;
        double flipMax = 0, flipSum = 0;
        for (NSNumber* n in flipMs) {
          flipMax = MAX(flipMax, n.doubleValue);
          flipSum += n.doubleValue;
        }
        std::printf("THUMB-TIME copies=%ld done=%ld failed=%ld kickoffMaxMs=%.2f kickoffMeanMs=%.3f deliverMaxMs=%.2f "
                    "latencyMaxMs=%.0f latencyMeanMs=%.0f switches=%ld switchHookMaxMs=%.3f flipShowItemMaxMs=%.2f "
                    "flipShowItemMeanMs=%.2f\n",
                    s.started, s.finished, s.failed, s.maxKickoffMs, s.started ? s.totalKickoffMs / s.started : 0, s.maxDeliverMs,
                    s.maxLatencyMs, s.finished ? s.totalLatencyMs / s.finished : 0, s.switches, s.maxSwitchHookMs, flipMax,
                    flipMs.count ? flipSum / flipMs.count : 0);
        std::printf("SELFTEST-THUMBNAIL taken=%d small=%d page=%d inCard=%d notForShown=%d fast=%d switchFast=%d flipNoCopy=%d\n",
                    taken, small, page, inCard, notShown, fast, switchFast, flipNoCopy);
        std::printf("SELFTEST-TABSWITCHER open=%d order=%d thumbnail=%d stepped=%d switched=%d cancelled=%d\n", open, order,
                    thumb, stepped, switched, cancelled);
        BOOL hoverOK = [hoverLook isEqual:@"banner=1 edge=1 link=1"];
        BOOL switcherOK = [switcherLook hasSuffix:@" neutral=1"] &&
                          [switcherLook containsString:[NSString stringWithFormat:@"tiles=%lu shadows=%lu icons=%lu",
                                                        (unsigned long)items.count, (unsigned long)items.count, (unsigned long)items.count]];
        std::printf("SELFTEST-HOVERSWITCHLOOK hoverCard=%d switcher=%d\n", hoverOK, switcherOK);
        if (!hoverOK || !switcherOK) std::printf("SELFTEST-HOVERSWITCHLOOK-DEBUG %s | %s\n", hoverLook.UTF8String, switcherLook.UTF8String);
        gLateTestsDone = YES;
      });
    });
  });
}

// Notes (#50), part 2: Arc's note look and format bar, notes as split panes, Markdown export. Runs right after
// SELFTEST-NOTES in the same timed block, synchronously, so no other check moves the shown tab in between.
- (void)runNoteFormatSelfTest {
  MainWindowController* w = self.window;
  ArcSpace* space = w.currentSpace;
  NSFontManager* fm = NSFontManager.sharedFontManager;
  NSInteger generalBefore = NSPasteboard.generalPasteboard.changeCount;
  ArcItem* n = [w createNoteWithID:nil];
  NoteEditorView* ed = [w noteEditorForItem:n];
  NoteTextView* tv = ed.textView;
  NSUInteger controls = 0;
  NSButton* italicButton = nil;
  for (NSControl* c in ed.toolbarControls) {
    if (c.action && c.target == tv) ++controls;
    if (c.action == @selector(noteToggleItalic:)) italicButton = (NSButton*)c;
  }
  [ed setFrameSize:ed.frame.size];  // lays the parts out
  NSString* barLook = ed.floatingBarDescription;  // Visual parity V44: floating rounded bar, "Untitled" placeholder
  BOOL toolbar = ed && controls >= 9 && ed.toolbar.superview == ed && [barLook isEqual:@"floating=1 centred=1 radius=10 placeholder=1"];
  if (!toolbar) std::printf("SELFTEST-NOTESTYLE-DEBUG controls=%lu %s\n", (unsigned long)controls, barLook.UTF8String);
  [w typeInNote:@"Plan\nIntro\nmilk\neggs\nbread\nwash car\nsee the docs now"];
  NSTextStorage* ts = tv.textStorage;
  NSFont* (^fontAt)(NSString*) = ^NSFont*(NSString* word) {
    NSRange r = [ts.string rangeOfString:word];
    return r.location == NSNotFound ? nil : [ts attribute:NSFontAttributeName atIndex:r.location effectiveRange:nil];
  };
  void (^select)(NSString*) = ^(NSString* word) { tv.selectedRange = [ts.string rangeOfString:word]; };
  BOOL title = fontAt(@"Plan").pointSize >= 28 && fontAt(@"Intro").pointSize < 16 && [n.displayTitle isEqualToString:@"Plan"];
  BOOL readable = ed.readingWidth > 200 && ed.readingWidth <= 681 && ed.sideMargin >= 28;
  select(@"Intro");
  [tv applyBlock:NoteBlockHeading2];
  BOOL heading = fontAt(@"Intro").pointSize == 20 && ([fm traitsOfFont:fontAt(@"Intro")] & NSBoldFontMask);
  tv.selectedRange = NSUnionRange([ts.string rangeOfString:@"milk"], [ts.string rangeOfString:@"eggs"]);
  [tv applyList:NoteListBullet];
  select(@"bread");
  [tv applyList:NoteListNumber];
  select(@"wash car");
  [tv applyList:NoteListCheck];
  BOOL checked = [tv toggleCheckboxInParagraphAt:[ts.string rangeOfString:@"wash car"].location];
  select(@"car");
  [tv noteToggleUnderline:nil];
  select(@"see");
  [tv noteToggleBold:nil];
  select(@"the");
  [italicButton performClick:nil];  // through the format bar
  select(@"docs");
  [tv setLinkOnSelection:@"https://example.org/docs"];
  select(@"now");
  [tv noteToggleStrikethrough:nil];
  BOOL lists = [ts.string containsString:@"\u2022\tmilk\n\u2022\teggs\n1.\tbread\n\u2611\twash car"];
  BOOL italic = ([fm traitsOfFont:fontAt(@"the")] & NSItalicFontMask) != 0;
  NSString* scheme = space.colorScheme;
  [w setColorScheme:@"dark" forSpace:space];
  BOOL dark = [ed looksDark];
  [w setColorScheme:@"light" forSpace:space];
  BOOL light = [ed looksLight];
  [w setColorScheme:scheme forSpace:space];
  NSString* md = [w markdownForNote:n];
  BOOL roundTrip = [NoteMarkdown([w savedNote:n]) isEqualToString:md];
  std::printf("SELFTEST-NOTESTYLE toolbar=%d title=%d readable=%d heading=%d lists=%d checked=%d italic=%d dark=%d light=%d "
              "roundTrip=%d\n", toolbar, title, readable, heading, lists, checked, italic, dark, light, roundTrip);

  // Markdown: File > Export Note as Markdown... (written straight to a temp file here) and Copy Note as Markdown.
  NSString* expected = @"# Plan\n\n### Intro\n\n- milk\n- eggs\n1. bread\n- [x] wash <u>car</u>\n\n"
                       @"**see** *the* [docs](https://example.org/docs) ~~now~~\n";
  BOOL markdown = [md isEqualToString:expected];
  if (!markdown) std::printf("SELFTEST-NOTEMD-DEBUG got=%s\n", [[md stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"] UTF8String]);
  NSMenuItem* exportItem = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(exportNoteAsMarkdown:) keyEquivalent:@""];
  BOOL menuEnabled = [(id<NSMenuItemValidation>)w validateMenuItem:exportItem];
  [w copyNoteAsMarkdown:nil];
  NSPasteboard* pb = [w copyPasteboard];
  BOOL copied = [[pb stringForType:NSPasteboardTypeString] isEqualToString:md];
  BOOL markdownType = [[pb stringForType:@"net.daringfireball.markdown"] isEqualToString:md];
  NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-selftest-note.md"];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
  BOOL exported = [w exportNote:n toPath:path] &&
                  [[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] isEqualToString:expected];
  [[NSFileManager defaultManager] removeItemAtPath:path error:nil];

  // Split view: a page opened beside a note...
  [w openInSplit:@"https://example.org/beside-note" horizontal:NO];
  ArcItem* page = w.shownItem;
  NoteEditorView* left = [w noteEditorForItem:n];
  NSArray<NSValue*>* pf = [w paneFrames];
  NSArray* panes = [w visiblePanesForTest];
  BOOL pageBesideNote = panes.count == 2 && panes[0] == n && panes[1] == page && left && pf.count == 1 &&
                        NSMaxX(left.frame) <= NSMinX(pf[0].rectValue) + 0.5 &&
                        fabs(left.frame.size.width - pf[0].rectValue.size.width) < 10;
  [w.window makeFirstResponder:left.textView];  // clicking into the note pane focuses it
  BOOL focusNote = w.shownItem == n && [w visiblePanesForTest].count == 2;
  [w.window makeFirstResponder:nil];
  // ...and a new note beside a page (Split View > New Note in Split View).
  [w openInNewTab:@"https://example.org/note-split"];
  ArcItem* page2 = w.shownItem;
  [w newNoteInSplitView:nil];
  ArcItem* n2 = w.shownItem;
  NoteEditorView* right = [w noteEditorForItem:n2];
  NSArray<NSValue*>* pf2 = [w paneFrames];
  BOOL noteBesidePage = n2.noteID && n2 != n && [[w visiblePanesForTest] isEqualToArray:@[ page2, n2 ]] && right &&
                        pf2.count == 1 && NSMaxX(pf2[0].rectValue) <= NSMinX(right.frame) + 0.5 && right.frame.size.width > 100;
  [w typeInNote:@"Side note"];
  BOOL typed = [right.textView.string isEqualToString:@"Side note"] && [n2.displayTitle isEqualToString:@"Side note"];
  [w showItem:page2];  // the page pane focused: the note stays on screen beside it
  BOOL staysBeside = [w noteEditorForItem:n2] == right && [w paneFrames].count == 1 && [w visiblePanesForTest].count == 2;
  // An existing note moves into another split (one document, never copied).
  [w openInNewTab:@"https://example.org/note-move"];
  ArcItem* page3 = w.shownItem;
  [w openInSplit:n.url horizontal:NO];
  NSUInteger copies = 0;
  for (ArcItem* t in space.allTabs) copies += [t.url isEqualToString:n.url];
  BOOL moved = copies == 1 && w.shownItem == n && [[w visiblePanesForTest] isEqualToArray:@[ page3, n ]] && [w noteEditorForItem:n] &&
               [[w markdownForNote:n] isEqualToString:md];
  for (ArcItem* t in @[ n, n2 ]) {
    [w showItem:t];
    [w closeTab:nil];
  }
  [w showItem:page3];
  BOOL offForPages = ![(id<NSMenuItemValidation>)w validateMenuItem:exportItem] && [w visiblePanesForTest].count == 1;
  for (ArcItem* t in @[ page, page2, page3 ]) {
    [w showItem:t];
    [w closeTab:nil];
  }
  BOOL generalUntouched = NSPasteboard.generalPasteboard.changeCount == generalBefore;
  std::printf("SELFTEST-NOTESPLIT pageBesideNote=%d focusNote=%d noteBesidePage=%d typed=%d staysBeside=%d moved=%d\n",
              pageBesideNote, focusNote, noteBesidePage, typed, staysBeside, moved);
  std::printf("SELFTEST-NOTEMD markdown=%d menuEnabled=%d copied=%d markdownType=%d exported=%d offForPages=%d generalUntouched=%d\n",
              markdown, menuEnabled, copied, markdownType, exported, offForPages, generalUntouched);
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
      {  // Visual parity V38: Arc's Little Arc frame (Space colour, rounded page card, "Open in" capsule)
        NSString* ls = w.littleWindowStyle;
        BOOL look = [ls hasPrefix:@"tinted=1 card=8 "] && [ls hasSuffix:@" capsule=1"];
        std::printf("SELFTEST-LITTLELOOK arcStyle=%d\n", look);
        if (!look) std::printf("SELFTEST-LITTLELOOK-DEBUG %s\n", ls.UTF8String);
      }
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
      NSString* peekStyle = w.peekStyle;  // Visual parity V39: Arc's floating card, no title bar, page dimmed
      BOOL peekLook = [peekStyle isEqual:@"peek=1 titlebar=0 radius=10 buttons=2 clear=1 scrim=1"];
      std::printf("SELFTEST-PEEKLOOK card=%d\n", peekLook);
      if (!peekLook) std::printf("SELFTEST-PEEKLOOK-DEBUG %s\n", peekStyle.UTF8String);
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
      NSString* motion = w.spaceSwitchMotion;  // V55: push with a spring overshoot, theme colours cross-fade
      BOOL springSlide = reduce || ([motion hasPrefix:@"push=1 spring=1"] &&
                                    (w.themeView.hidden || [motion hasSuffix:@"crossfade=1"]));
      std::printf("SELFTEST-SPACEMOTION spring=%d\n", springSlide);
      if (!springSlide) std::printf("SELFTEST-SPACEMOTION-DEBUG %s\n", motion.UTF8String);
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
      NSString* hideMotion = w.lastSidebarMotion;
      [w toggleSidebar:nil];
      BOOL shownAgain = ![w sidebarHidden];
      {  // Visual parity V66: the sidebar slides out / in and the page card follows, on a spring; none with Reduce Motion.
        BOOL reduce = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
        NSString* showMotion = w.lastSidebarMotion;
        BOOL ok = reduce ? [hideMotion isEqual:@"none"] && [showMotion isEqual:@"none"]
                         : [hideMotion isEqual:@"slide=1 card=1"] && [showMotion isEqual:@"slide=1 card=1"];
        std::printf("SELFTEST-SIDEBARMOTION springs=%d\n", ok);
        if (!ok) std::printf("SELFTEST-SIDEBARMOTION-DEBUG hide=%s show=%s\n", hideMotion.UTF8String, showMotion.UTF8String);
      }
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
      {  // V65: Clear sends the rows flying to the Library button
        NSString* cm = w.sidebarRowMotion;
        BOOL flew = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion || [cm hasSuffix:@"library=1"];
        std::printf("SELFTEST-CLEARMOTION toLibrary=%d\n", flew);
        if (!flew) std::printf("SELFTEST-CLEARMOTION-DEBUG %s\n", cm.UTF8String);
      }
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
      {  // Visual parity V2: close button on the hovered row only, long titles end in "..." as in Arc 1.169.
        NSString* selAcc = shownTab ? [w tabRowAccessoriesForItem:shownTab] : @"";
        [w hoverSidebarItem:otherTab];
        NSString* hovAcc = otherTab ? [w tabRowAccessoriesForItem:otherTab] : @"";
        [w hoverSidebarItem:nil];
        NSString* offAcc = otherTab ? [w tabRowAccessoriesForItem:otherTab] : @"";
        BOOL closeShown = [selAcc hasPrefix:@"close=0"] && [hovAcc hasPrefix:@"close=1"] && [offAcc hasPrefix:@"close=0"];
        BOOL room = [selAcc hasSuffix:@"room=1"] && [hovAcc hasSuffix:@"room=1"];
        ArcItem* longTab = nil;
        for (ArcItem* t in w.currentSpace.unpinned.children)
          if (t != shownTab && t.url.length && !t.isSplit) { longTab = t; break; }
        NSString* savedTitle = longTab.title;
        BOOL savedRenamed = longTab.renamed;
        longTab.title = @"A very long tab title that keeps going well past the right edge of the sidebar row";
        longTab.renamed = YES;
        [w reloadSidebarItemForTest:longTab];
        NSString* longAcc = longTab ? [w tabRowAccessoriesForItem:longTab] : @"";
        BOOL fade = [longAcc containsString:@"ellipsis=1"];  // Arc 1.169: long titles end in "..."
        longTab.title = savedTitle;
        longTab.renamed = savedRenamed;
        [w reloadSidebarItemForTest:longTab];
        // The close button on a row that isn't shown closes that tab (archived) and leaves the shown tab alone.
        NSUInteger todayBefore = w.currentSpace.unpinned.children.count;
        [w openInNewTab:@"https://closebutton.example/" background:YES];
        ArcItem* extra = nil;
        for (ArcItem* t in w.currentSpace.unpinned.children)
          if ([t.url hasPrefix:@"https://closebutton.example/"]) extra = t;
        BOOL pressed = extra && [w pressCloseButtonOfItem:extra];
        BOOL closeOther = pressed && w.shownItem == shownTab && w.currentSpace.unpinned.children.count == todayBefore &&
                          ![w.currentSpace.unpinned.children containsObject:extra];
        std::printf("SELFTEST-TABROWS closeShown=%d room=%d ellipsis=%d closeOther=%d\n", closeShown, room, fade, closeOther);
        if (!closeShown || !room || !fade)
          std::printf("SELFTEST-TABROWS-DEBUG sel=[%s] hov=[%s] off=[%s] long=[%s]\n", selAcc.UTF8String, hovAcc.UTF8String,
                      offAcc.UTF8String, longAcc.UTF8String);
      }
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
      [w showItem:shownTab];
      NSString* pillIdle = w.pillButtonState;
      [w setPillHoveredForTest:YES];
      NSString* pillHover = w.pillButtonState;
      [w setPillHoveredForTest:NO];
      BOOL pillButtons = [pillIdle hasPrefix:@"0/"] && [pillHover componentsSeparatedByString:@"/"].firstObject.integerValue >= 2 &&
                         [[pillHover componentsSeparatedByString:@"/"].firstObject isEqual:[pillHover componentsSeparatedByString:@"/"].lastObject];
      std::printf("SELFTEST-SIDEBARLOOK grid=%d defaultTheme=%d noScrollTrack=%d dots=%d pillButtons=%d\n", gridOK,
                  w.currentSpace.themeColors.count || !w.sidebarIsDark || w.defaultThemeShown, w.sidebarScrollerIsOverlay,
                  w.spaceDotsAreArcStyle, pillButtons);
      if (!pillButtons) std::printf("SELFTEST-SIDEBARLOOK-DEBUG pill idle=%s hover=%s\n", pillIdle.UTF8String, pillHover.UTF8String);
      {  // Visual parity V8, V9, V17, V23: inactive dimming, loading spinner + glow, Today's Clear, the floating sidebar.
        BOOL dim = [w sidebarDimmedForTest:YES];
        BOOL undim = ![w sidebarDimmedForTest:NO];
        [w showItem:shownTab];
        [w setItem:shownTab loadingForTest:YES];
        NSString* loadOn = [w loadingIndicatorStateForItem:shownTab];
        [w setItem:shownTab loadingForTest:NO];
        NSString* loadOff = [w loadingIndicatorStateForItem:shownTab];
        BOOL spinner = [loadOn isEqual:@"spinner=1 icon=0 glow=1"] && [loadOff isEqual:@"spinner=0 icon=1 glow=0"];
        NSString* clear = w.todayClearState;
        BOOL clearOK = w.currentSpace.unpinned.children.count == 0 || [clear isEqual:@"before=0 during=1 after=0"];
        BOOL wasHidden = w.sidebarHidden;
        if (!wasHidden) [w toggleSidebar:nil];
        NSString* strip = w.sidebarPeekState;
        [w beginSidebarPeekForTest];
        NSString* peek = w.sidebarPeekState;
        [w endSidebarPeekForTest];
        NSString* after = w.sidebarPeekState;
        if (!wasHidden) [w toggleSidebar:nil];
        BOOL peekOK = [strip hasPrefix:@"peeking=0 strip=1"] && [peek hasPrefix:@"peeking=1 strip=0 floating=1 radius=10"] &&
                      [peek hasSuffix:@"cardFull=1"] && [after hasPrefix:@"peeking=0 strip=1"] && w.sidebarHidden == wasHidden &&
                      !w.sidebarHidden;
        std::printf("SELFTEST-SIDEBARSTATES inactiveDim=%d activeFull=%d spinner=%d clear=%d peek=%d\n", dim, undim, spinner, clearOK,
                    peekOK);
        if (!spinner || !clearOK || !peekOK)
          std::printf("SELFTEST-SIDEBARSTATES-DEBUG load=[%s][%s] clear=[%s] peek=[%s][%s][%s]\n", loadOn.UTF8String, loadOff.UTF8String,
                      clear.UTF8String, strip.UTF8String, peek.UTF8String, after.UTF8String);
      }
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
      NSString* openMotion = w.sidebarRowMotion;
      NSArray* before = w.currentSpace.allTabs;
      NSUInteger posA = [before indexOfObject:a];
      NSUInteger archived = w.archivedTabs.count;
      [w showItem:a];
      [w closeCurrentTab];
      {  // Visual parity V65: the new row grew in; the closed row squashed away and the row under it slid up.
        BOOL reduce = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
        NSString* closeMotion = w.sidebarRowMotion;
        BOOL grew = reduce || [openMotion hasPrefix:@"grow=1 "];
        BOOL shrank = reduce || ([closeMotion containsString:@"ghosts=1"] && ![closeMotion hasPrefix:@"grow=1"]);
        std::printf("SELFTEST-ROWMOTION grow=%d closeShrinks=%d\n", grew, shrank);
        NSString* metrics = w.layoutMetricsForTest;  // V63/V64: Arc's type and measurements, read from the live layout
        NSString* want = @"sidebar=273 inset=8 pill=36 pillRadius=10 row=36 pitch=41 rowRadius=8 card=8 favRadius=10 "
                         @"tab=14-medium space=13-semibold address=13-regular command=20";
        std::printf("SELFTEST-METRICS arcSizes=%d\n", [metrics isEqual:want]);
        if (![metrics isEqual:want]) std::printf("SELFTEST-METRICS-DEBUG %s\n", metrics.UTF8String);
        NSString* drag = w.dragLookForTest;  // V21: gap opens, lifted pill, folder lights up, page drop splits
        std::printf("SELFTEST-DRAGLOOK arcStyle=%d\n", [drag isEqual:@"gap=1 lifted=1 folderHighlight=1 pageSplit=1"]);
        if (![drag isEqual:@"gap=1 lifted=1 folderHighlight=1 pageSplit=1"])
          std::printf("SELFTEST-DRAGLOOK-DEBUG %s | %s\n", drag.UTF8String, w.dragLookDebugForTest.UTF8String);
        if (!grew || !shrank) std::printf("SELFTEST-ROWMOTION-DEBUG open=%s close=%s\n", openMotion.UTF8String, closeMotion.UTF8String);
      }
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
      {  // Visual parity V53: three colours paint a three-stop gradient, with grain over it
        [w setTheme:@[ @"#F29BBB", @"#A6729D", @"#7EB8D6" ] intensity:0.8 forSpace:sp];
        [w setThemeGrain:0.5 forSpace:sp];
        CAGradientLayer* g3 = (CAGradientLayer*)w.themeView.layer.sublayers.firstObject;
        BOOL three = g3.colors.count == 3 && w.themeGrainOpacity > 0.1f;
        std::printf("SELFTEST-GRADIENT threeStops=%d grain=%d\n", g3.colors.count == 3, three);
        [w setThemeGrain:0 forSpace:sp];
      }
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
                  "document.body.appendChild(a);"
                  "if(navigator.mediaSession){navigator.mediaSession.metadata=new MediaMetadata({title:'Test Track',artist:'Test Artist'});"
                  "navigator.mediaSession.setActionHandler('nexttrack',function(){document.title='next:on';});}"
                  "a.play();})()" inItem:m];
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
            {  // Visual parity V3: Arc's mini player card (what's playing, the site, back/play/forward, mute on hover).
              [w pollMediaNow];
              NSString* card = w.mediaCardDescription;
              BOOL meta = [card containsString:@"title=Test Track subtitle=Test Artist"] &&
                          [card containsString:@"tip=Test Track — Test Artist"];
              BOOL buttons = [card containsString:@"prev=1 play=1 next=1 mute=1"];
              BOOL noText = [card hasSuffix:@"text=0"];  // Arc shows no text in the bar
              BOOL size = [card hasPrefix:@"h=32"] && [card containsString:@"art=1"];
              BOOL clock = [MediaBarTitle(@"brain.fm (2:52)") isEqualToString:@"brain.fm"] &&
                           [MediaBarTitle(@"\u25B6 Song - Artist 1:02 / 3:40") isEqualToString:@"Song - Artist"] &&
                           [MediaBarTitle(@"Lisbon - Wikipedia") isEqualToString:@"Lisbon - Wikipedia"];
              [w mediaBarNext:nil];
              std::printf("SELFTEST-MINIPLAYER meta=%d buttons=%d noText=%d size=%d clock=%d\n", meta, buttons, noText, size,
                          clock);
              if (!meta || !buttons || !size) std::printf("SELFTEST-MINIPLAYER-DEBUG %s\n", card.UTF8String);
            }
            [w reloadSidebarItemForTest:m];
            NSString* sp1 = [w speakerStateForItem:m];  // Visual parity V26: site icon kept, speaker button at the right
            [w toggleMuteItem:m];
            BOOL muted = m.audioMuted;
            NSString* sp2 = [w speakerStateForItem:m];
            [w toggleMuteItem:m];
            BOOL speakerOK = [sp1 isEqual:@"speaker=1 muted=0"] && [sp2 isEqual:@"speaker=1 muted=1"];
            std::printf("SELFTEST-SPEAKER arcStyle=%d\n", speakerOK);
            if (!speakerOK) std::printf("SELFTEST-SPEAKER-DEBUG %s | %s\n", sp1.UTF8String, sp2.UTF8String);
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
          NSString* sad = [w crashViewStyleForItem:c];  // Visual parity V10: drawing, one line, Reload as a link
          std::printf("SELFTEST-SADTAB arcStyle=%d\n", [sad isEqual:@"glyph=1 line=1 link=1"]);
          if (![sad isEqual:@"glyph=1 line=1 link=1"]) std::printf("SELFTEST-SADTAB-DEBUG %s\n", sad.UTF8String);
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
    // Omar, Nov 11 (V69): the address pill's hover row is Arc's: this profile's pinned extensions (their own icons),
    // the puzzle (More) for the rest, Copy URL, then the site control center; no Boost brush (V74, Nov 12).
    // Pin / Unpin round-trips, and clicking a pinned icon opens its popup under that icon.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 53 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSString* fx = gTestExtensionID ?: @"-";
      NSString* (^order)(void) = ^NSString*(void) {
        NSMutableArray* parts = [[w.pillButtonOrder componentsSeparatedByString:@","] mutableCopy];
        [parts removeObject:@"devtools"];
        if (![w.boostIndicatorState isEqual:@"on"]) return [parts componentsJoinedByString:@","];
        [parts removeObject:@"boost"];
        return [parts componentsJoinedByString:@","];
      };
      [w setPillHoveredForTest:YES];
      NSString* pinned = order();
      BOOL arcOrder = [pinned isEqual:[NSString stringWithFormat:@"ext:%@,more,copy,site", fx]];
      BOOL noBoost = ![w.pillButtonOrder containsString:@"boost"];  // Arc: never a Boost brush in the pill (V74)
      BOOL ownIcon = [w pillExtensionHasOwnIcon:fx];
      [w setExtension:fx pinned:NO];
      NSString* unpinned = order();
      NSMenu* picker = [w extensionPickerMenuForURL:nil];
      BOOL pinItem = [[picker itemWithTitle:@"NotArc Test Extension"].submenu itemWithTitle:@"Pin"] != nil;
      [w setExtension:fx pinned:YES];
      BOOL pinRoundTrip = [unpinned isEqual:@"more,copy,site"] && pinItem && [order() isEqual:pinned] && [w extensionIsPinned:fx];
      ExtensionPopup* pop = [w clickPillExtensionForTest:fx];
      NSView* anchor = [w extensionPopupAnchor];
      BOOL opensUnderIcon = pop != nil && [anchor isKindOfClass:NSButton.class] && [anchor.identifier isEqual:[@"ext:" stringByAppendingString:fx]];
      if (pop.isOpen) [pop closeBecause:@"test"];
      [w setPillHoveredForTest:NO];
      BOOL anchorBack = [w extensionPopupAnchor] == nil || ![[w extensionPopupAnchor].identifier hasPrefix:@"ext:"];
      std::printf("SELFTEST-PILLROW arcOrder=%d noBoost=%d ownIcon=%d pinRoundTrip=%d opensUnderIcon=%d anchorBack=%d\n", arcOrder,
                  noBoost, ownIcon, pinRoundTrip, opensUnderIcon, anchorBack);
      if (!arcOrder || !pinRoundTrip) std::printf("SELFTEST-PILLROW-DEBUG pinned=%s unpinned=%s ext=%s\n", pinned.UTF8String, unpinned.UTF8String, fx.UTF8String);
    });
    // Chrome extensions (#66). First the action popup as a bubble (both settings: self-test runs always load the fixture
    // extension, installed at startup through the real CRX install path, and the bubble is a Chrome-style page of its
    // own): the picker's Open shows chrome-extension://<id>/popup.html in a panel under the picker button (or the
    // address pill without it), sized to the page (240x120 box + 8 px body margins = 256x136), invisible like the test
    // window; Esc, a click outside and the page's window.close() each close it. Then, with Chrome-style pages on,
    // Options and chrome://extensions open in tabs and a stubbed Chrome Web Store page reports whether Chromium's own
    // Web Store install API is there (info only).
    // Each wait is capped so this finishes before the hang check (75 s) needs the visible tab to itself.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 57 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSMenu* menu = [w extensionPickerMenuForURL:nil];
      NSMenuItem* row = [menu itemWithTitle:@"NotArc Test Extension"];
      NSMenuItem* open = [row.submenu itemWithTitle:@"Open"];
      NSMenuItem* options = [row.submenu itemWithTitle:@"Options"];
      NotArcExtension* fixture = row.representedObject;
      BOOL installedAtStart = gTestExtensionID != nil && row != nil;
      if (open) [NSApp sendAction:open.action to:open.target from:open];
      ExtensionPopup* p = w.extensionPopup;
      NSString* expectURL = [NSString stringWithFormat:@"chrome-extension://%@/popup.html", gTestExtensionID];
      WaitUntil(^{ return (BOOL)(p.loadedURL && p.title && p.sizedBy && p.panel.isVisible); }, 5, ^{
       NSWindow* win = w.window;
       NSRect f = p.panel.frame;
       NSView* anchor = [w extensionPopupAnchor];
       NSRect a = [win convertRectToScreen:[anchor convertRect:anchor.bounds toView:nil]];
       BOOL created = p != nil && p.panel != nil && p.pageWindow != nil;
       BOOL anchored = p.panel.parentWindow == win && NSContainsRect(win.frame, f) && NSMaxY(f) <= NSMinY(a) &&
                       NSMinY(a) - NSMaxY(f) <= 12 && NSMinX(f) < NSMaxX(a) && NSMaxX(f) > NSMinX(a);
       NSRect pf = p.pageWindow.frame;
       BOOL pageOnBubble = p.pageWindow.parentWindow == p.panel && fabs(NSMinX(pf) - NSMinX(f)) <= 1 &&
                           fabs(NSMinY(pf) - NSMinY(f)) <= 1 && fabs(pf.size.width - f.size.width) <= 1 &&
                           fabs(pf.size.height - f.size.height) <= 1;
       BOOL url = [p.loadedURL isEqualToString:expectURL] && [p.title isEqualToString:@"NotArc Extension Popup"] && !p.loadFailed;
       BOOL sized = fabs(f.size.width - 256) <= 2 && fabs(f.size.height - 136) <= 2;
       BOOL clamp = NSEqualSizes(ExtensionPopupClampSize(NSMakeSize(3, 3)), NSMakeSize(25, 25)) &&
                    NSEqualSizes(ExtensionPopupClampSize(NSMakeSize(2000, 900)), NSMakeSize(800, 600)) &&
                    NSEqualSizes(ExtensionPopupClampSize(NSMakeSize(300.2, 200)), NSMakeSize(301, 200)) &&
                    NSContainsRect(NSMakeRect(0, 0, 500, 400), ExtensionPopupFrame(NSMakeRect(450, 350, 26, 26), NSMakeSize(300, 500),
                                                                                    NSMakeRect(0, 0, 500, 400)));
       BOOL hidden = p.panel.alphaValue <= 0.011 && p.panel.ignoresMouseEvents && p.pageWindow.alphaValue <= 0.011 &&
                     p.pageWindow.ignoresMouseEvents && !p.pageWindow.isKeyWindow && win.alphaValue <= 0.011;
       NSString* sizedBy = p.sizedBy;
       NSEvent* esc = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                                   windowNumber:p.pageWindow.windowNumber context:nil characters:@"\x1b"
                    charactersIgnoringModifiers:@"\x1b" isARepeat:NO keyCode:53];
       BOOL escConsumed = [p handleLocalEvent:esc] == nil;
       BOOL escCloses = escConsumed && !p.isOpen && [p.closeReason isEqualToString:@"esc"] && !p.panel.isVisible &&
                        !p.panel.parentWindow && w.extensionPopup == nil;
       ExtensionPopup* p2 = [w showPopupOfExtension:fixture];
       WaitUntil(^{ return (BOOL)(p2.panel.isVisible && p2.loadedURL); }, 3, ^{
        NSEvent* click = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(400, 300) modifierFlags:0
                                           timestamp:0 windowNumber:w.window.windowNumber context:nil eventNumber:0
                                          clickCount:1 pressure:1];
        BOOL passedOn = [p2 handleLocalEvent:click] == click;
        BOOL clickOutside = p2 && passedOn && !p2.isOpen && [p2.closeReason isEqualToString:@"click"] && !p2.panel.isVisible;
        ExtensionPopup* p3 = [w showPopupOfExtension:fixture];
        WaitUntil(^{ return (BOOL)(p3.panel.isVisible && p3.loadedURL); }, 3, ^{
         [p3 runJS:@"window.close()"];
         WaitUntil(^{ return (BOOL)(p3 && !p3.isOpen); }, 3, ^{
          BOOL scriptClose = p3 && !p3.isOpen && [p3.closeReason isEqualToString:@"script"] && !p3.panel.isVisible &&
                             w.extensionPopup == nil;
          if (p3.isOpen) [p3 closeBecause:@"test"];
          std::printf("SELFTEST-EXTPOPUP installed=%d created=%d anchored=%d pageOnBubble=%d url=%d sized=%d clamp=%d hidden=%d "
                      "escCloses=%d clickOutside=%d scriptClose=%d\n", installedAtStart, created, anchored, pageOnBubble, url,
                      sized, clamp, hidden, escCloses, clickOutside, scriptClose);
          std::printf("SELFTEST-EXTPOPUP-DEBUG sizedBy=%s size=%gx%g page=%gx%g anchorY=%g top=%g reason3=%s\n",
                      sizedBy.UTF8String ?: "-", f.size.width, f.size.height, p.pageSize.width, p.pageSize.height, NSMinY(a),
                      NSMaxY(f), p3.closeReason.UTF8String ?: "-");
          std::fflush(stdout);
          if (!ChromePagesEnabled()) {
            std::printf("SELFTEST-EXTPAGES chromePagesOff=1\n");
            return;
          }
          BOOL popup = url;
          if (options) [NSApp sendAction:options.action to:options.target from:options];
        ArcItem* optionsTab = options ? w.shownItem : nil;
        WaitUntil(^{ return [optionsTab.liveTitle isEqualToString:@"NotArc Extension Options"]; }, 4, ^{
          BOOL optionsOK = [optionsTab.liveTitle isEqualToString:@"NotArc Extension Options"];
          NSMenuItem* manage = [menu itemWithTitle:@"Manage Extensions"];
          [NSApp sendAction:manage.action to:manage.target from:manage];
          ArcItem* extTab = w.shownItem;
          WaitUntil(^{ return [extTab.liveTitle isEqualToString:@"Extensions"]; }, 4, ^{
            BOOL extensionsPage = [extTab.liveTitle isEqualToString:@"Extensions"] && [extTab.url hasPrefix:@"chrome://extensions"];
            std::printf("SELFTEST-EXTPAGES installedAtStart=%d popup=%d options=%d extensionsPage=%d\n", installedAtStart, popup,
                        optionsOK, extensionsPage);
            NSString* store = [@"https://chromewebstore.google.com/detail/notarc-probe/" stringByAppendingString:gTestExtensionID ?: @""];
            BrowserClient::SetTestResponse(store.UTF8String, "<!doctype html><title>probe</title><script>document.title='WS:'+"
                                                  "(window.chrome&&chrome.webstorePrivate?1:0)+':'+(window.chrome&&chrome.management?1:0)"
                                                  "</script>");
            [w openInNewTab:store];
            ArcItem* storeTab = w.shownItem;
            WaitUntil(^{ return [storeTab.liveTitle hasPrefix:@"WS:"]; }, 4, ^{
              NSArray* parts = [storeTab.liveTitle componentsSeparatedByString:@":"];
              std::printf("SELFTEST-WEBSTORE-DEBUG loaded=%d webstorePrivate=%s management=%s\n", parts.count == 3,
                          parts.count == 3 ? [parts[1] UTF8String] : "-", parts.count == 3 ? [parts[2] UTF8String] : "-");
              BrowserClient::SetTestResponse(store.UTF8String, "");
            });
          });
        });
         });
        });
       });
      });
    });
    // Chrome extensions (#66), both settings: Install Extension... from a Web Store link or ID (download stubbed with
    // CRX packages signed here), tampered/wrong-ID/Manifest V2 packages refused, then the picker: listing, on/off,
    // relaunch offer, Remove, the pill button, the menu bar items and the Settings switch.
    // The packages are signed off the main thread (RSA keys + zip), so timed checks elsewhere aren't held up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 58 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
     NSString *goodID = nil, *otherID = nil, *oldID = nil;
     NSData* good = BuildTestCRX(TestExtensionFiles(@"Picker Test", 3), &goodID);
     NSData* other = BuildTestCRX(TestExtensionFiles(@"Someone Else", 3), &otherID);
     NSData* old = BuildTestCRX(TestExtensionFiles(@"Old Format", 2), &oldID);
     dispatch_async(dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      BOOL pagesAtStart = SettingBool(kSettingChromePages);  // installs below turn it on; put back at the end
      NSFileManager* fm = NSFileManager.defaultManager;
      NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-installed-extensions"];
      [fm removeItemAtPath:dir error:nil];
      w.extensionsDirectoryOverride = dir;
      NSMutableData* tampered = [good mutableCopy];
      if (tampered.length > 40) ((uint8_t*)tampered.mutableBytes)[tampered.length - 40] ^= 0x5A;
      NSString* wrongID = @"abcdefghijklmnopabcdefghijklmnop";
      NSMutableDictionary<NSString*, NSData*>* serve = [NSMutableDictionary dictionary];
      NSMutableArray<NSString*>* asked = [NSMutableArray array];
      if (goodID) serve[goodID] = tampered;
      serve[wrongID] = other;
      if (oldID) serve[oldID] = old;
      SetExtensionFetcherForTest(^(NSURL* url, void (^done)(NSData*, NSError*)) {
        [asked addObject:url.absoluteString];
        NSData* d = nil;
        for (NSString* k in serve) if ([url.absoluteString containsString:[@"id%3D" stringByAppendingString:k]]) d = serve[k];
        done(d, nil);
      });
      NSString* storeURL = [NSString stringWithFormat:@"https://chromewebstore.google.com/detail/picker-test/%@?hl=en", goodID];
      BOOL parse = [ExtensionIDFromInput(storeURL) isEqualToString:goodID] &&
                   [ExtensionIDFromInput([@"https://chrome.google.com/webstore/detail/x/" stringByAppendingString:goodID]) isEqualToString:goodID] &&
                   [ExtensionIDFromInput(goodID) isEqualToString:goodID] && !ExtensionIDFromInput([@"https://example.com/detail/" stringByAppendingString:goodID]) &&
                   !ExtensionIDFromInput(@"not an id");
      BOOL crxURL = [WebStoreCRXURL(goodID).host isEqualToString:@"clients2.google.com"] && [WebStoreCRXURL(goodID).absoluteString containsString:goodID];
      [w installExtensionFromInput:goodID done:^(NSString* n1, NSError* e1) {
        BOOL tamperRefused = !n1 && e1 && ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:goodID]];
        [w installExtensionFromInput:wrongID done:^(NSString* n2, NSError* e2) {
          BOOL wrongIDRefused = !n2 && e2 && ExtensionLoadPaths(dir, nil).count == 0;
          [w installExtensionFromInput:oldID done:^(NSString* n3, NSError* e3) {
            BOOL mv2Refused = !n3 && [e3.localizedDescription containsString:@"Manifest V2"];
            __block BOOL badInput = NO;
            [w installExtensionFromInput:@"https://example.com/not-an-extension" done:^(NSString* n4, NSError* e4) { badInput = !n4 && e4; }];
            if (goodID) serve[goodID] = good;
            [w installExtensionFromInput:storeURL done:^(NSString* n5, NSError* e5) {
              NSString* root = [dir stringByAppendingPathComponent:goodID];
              NSData* md = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]];
              NSDictionary* m = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:nil] : nil;
              NSData* key = [m[@"key"] isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:m[@"key"] options:0] : nil;
              BOOL installed = [n5 isEqualToString:@"Picker Test"] && ExtensionLoadPaths(dir, nil).count == 1;
              BOOL keepsID = key && [ExtensionIDForPublicKey(key) isEqualToString:goodID];
              BOOL stubbedOnly = asked.count == 4;
              for (NSString* u in asked) if (![u hasPrefix:@"https://clients2.google.com/service/update2/crx?"]) stubbedOnly = NO;
              std::printf("SELFTEST-EXTINSTALL parse=%d crxURL=%d tamperRefused=%d wrongIDRefused=%d mv2Refused=%d badInput=%d "
                          "installed=%d keepsID=%d stubbedOnly=%d\n", parse, crxURL, tamperRefused, wrongIDRefused, mv2Refused,
                          badInput, installed, keepsID, stubbedOnly);
              // The picker.
              NSMenu* menu = [w extensionPickerMenuForURL:@"https://example.com/"];
              NSMenuItem* row = [menu itemWithTitle:@"Picker Test"];
              NSArray* sub = [row.submenu.itemArray valueForKey:@"title"];
              BOOL listed = row && [sub containsObject:@"Open"] && [sub containsObject:@"Options"] && [sub containsObject:@"Turn Off"] &&
                            [sub containsObject:@"Remove..."];
              NSArray* titles = [menu.itemArray valueForKey:@"title"];
              BOOL footer = [titles containsObject:@"Install Extension..."] && [titles containsObject:@"Chrome Web Store"] &&
                            [titles containsObject:@"Manage Extensions"] &&
                            [menu itemWithTitle:@"Manage Extensions"].enabled == ChromePagesEnabled();
              BOOL storePage = [[w extensionPickerMenuForURL:[@"https://chromewebstore.google.com/detail/x/" stringByAppendingString:otherID ?: @""]]
                                   .itemArray.firstObject.title isEqualToString:@"Add This Extension to NotArc"];
              [w setExtension:goodID enabled:NO];
              NSMenu* after = [w extensionPickerMenuForURL:nil];
              BOOL offShown = [[after itemWithTitle:@"Picker Test (off)"].submenu itemWithTitle:@"Turn On"] != nil;
              NSSet* disabled = [NSSet setWithArray:SettingObject(kDisabledExtensionsKey) ?: @[]];
              BOOL offNotLoaded = [disabled containsObject:goodID] && ExtensionLoadPaths(dir, disabled).count == 0;
              NSMenuItem* relaunch = after.itemArray.firstObject;
              BOOL relaunchOffered = [relaunch.title isEqualToString:@"Relaunch NotArc to Apply Changes"];
              NSInteger before = [w relaunchRequestsForTest];
              if (relaunchOffered) [NSApp sendAction:relaunch.action to:relaunch.target from:relaunch];  // counted, never quits
              BOOL relaunchCounted = [w relaunchRequestsForTest] == before + 1;
              [w setExtension:goodID enabled:YES];
              BOOL onAgain = ExtensionLoadPaths(dir, [NSSet setWithArray:SettingObject(kDisabledExtensionsKey) ?: @[]]).count == 1;
              BOOL removed = [w removeExtensionWithID:goodID] && ![fm fileExistsAtPath:root] &&
                             [[w extensionPickerMenuForURL:nil] itemWithTitle:@"No extensions yet"] != nil;
              BOOL button = [w extensionPickerButtonShown] == ChromePagesEnabled();
              NSMenuItem *fileInstall = nil, *fileManage = nil;
              for (NSMenuItem* top in NSApp.mainMenu.itemArray)
                for (NSMenuItem* mi in top.submenu.itemArray) {
                  if (mi.action == @selector(installExtension:)) fileInstall = mi;
                  if (mi.action == @selector(manageExtensions:)) fileManage = mi;
                }
              BOOL menuBar = fileInstall && fileManage && [(id<NSMenuItemValidation>)w validateMenuItem:fileManage] == ChromePagesEnabled();
              BOOL settings = [[SettingsWindowController shared] hasCheckboxForKey:@"chromePages"];
              std::printf("SELFTEST-EXTPICKER listed=%d footer=%d storePage=%d offShown=%d offNotLoaded=%d relaunchOffered=%d "
                          "relaunchCounted=%d onAgain=%d removed=%d button=%d menuBar=%d settings=%d\n", listed, footer, storePage,
                          offShown, offNotLoaded, relaunchOffered, relaunchCounted, onAgain, removed, button, menuBar, settings);
              // Relaunch offer (#66): the toast with Relaunch Now wired to the relaunch (counted, never quits), and
              // installs or Arc imports turning Chrome-style pages on (memory-only settings, restored after). Waits for
              // any other check's toast to go, and hides its own in the same turn, so no other check sees it.
              WaitUntil(^{ return (BOOL)(w.toastText == nil); }, 8, ^{
               BOOL savedPages = pagesAtStart;
               SettingSetBool(kSettingChromePages, YES);
               [w offerRelaunchForExtensions:@"Picker Test is installed."];
               BOOL toast = [w.toastText isEqualToString:@"Picker Test is installed. Relaunch to apply."];
               NSButton* rb = [w toastButtonTitled:@"Relaunch Now"];
               BOOL wired = rb && rb.target == w && rb.action == @selector(relaunchToApplyExtensions:);
               NSInteger r0 = [w relaunchRequestsForTest];
               [rb performClick:nil];
               BOOL clicked = [w relaunchRequestsForTest] == r0 + 1;
               SettingSetBool(kSettingChromePages, NO);
               [w offerRelaunchForExtensions:@"Picker Test is removed."];
               BOOL offNoButton = [w.toastText hasPrefix:@"Picker Test is removed."] && ![w toastButtonTitled:@"Relaunch Now"];
               [w hideToast];
               [w installExtensionFromInput:@"https://example.com/not-an-extension" done:^(NSString* nb, NSError*) {
                BOOL failKeepsOff = !nb && !SettingBool(kSettingChromePages);
                [w installExtensionFromInput:goodID done:^(NSString* n6, NSError*) {
                 BOOL installTurnsOn = n6 && SettingBool(kSettingChromePages);
                 SettingSetBool(kSettingChromePages, NO);
                 NSString* fake = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-userdata-pages"];
                 NSString* arcDest = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-extensions-pages"];
                 [fm removeItemAtPath:fake error:nil];
                 [fm removeItemAtPath:arcDest error:nil];
                 NSString* prof = w.currentSpace.profileDirectory.length ? w.currentSpace.profileDirectory : @"Default";
                 NSString* d = [NSString stringWithFormat:@"%@/%@/Extensions/cccccccccccccccccccccccccccccccc/1.0_0", fake, prof];
                 [fm createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
                 [@"{\"manifest_version\":3,\"name\":\"Arc Copy\",\"version\":\"1.0\"}" writeToFile:[d stringByAppendingPathComponent:@"manifest.json"]
                                                                                 atomically:YES encoding:NSUTF8StringEncoding error:nil];
                 NSArray* copies = [w importArcExtensionsTurningOnPagesInto:arcDest fromArcUserData:fake];
                 BOOL importTurnsOn = copies.count == 1 && SettingBool(kSettingChromePages);
                 SettingSetBool(kSettingChromePages, savedPages);
                 BOOL restored = SettingBool(kSettingChromePages) == savedPages && !w.toastText;
                 std::printf("SELFTEST-EXTRELAUNCH toast=%d wired=%d clicked=%d offNoButton=%d failKeepsOff=%d installTurnsOn=%d "
                             "importTurnsOn=%d restored=%d\n", toast, wired, clicked, offNoButton, failKeepsOff, installTurnsOn,
                             importTurnsOn, restored);
                 [fm removeItemAtPath:fake error:nil];
                 [fm removeItemAtPath:arcDest error:nil];
                 SetExtensionFetcherForTest(nil);
                 SettingSetObject(kDisabledExtensionsKey, @[]);
                 w.extensionsDirectoryOverride = nil;
                 [fm removeItemAtPath:dir error:nil];
                }];
               }];
              });
            }];
          }];
        }];
      }];
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
      {  // Visual parity V18: Arc's folder row: open / closed folder glyph, bold name, no chevron, children 16 pt in.
        if (![w folderExpanded:folder]) [w toggleFolder:folder];
        NSString* fs = [w folderRowStateForItem:folder];
        BOOL look = [fs isEqual:@"glyph=1 chevron=0 bold=1 indent=16"];
        std::printf("SELFTEST-FOLDERLOOK arcStyle=%d\n", look);
        if (!look) std::printf("SELFTEST-FOLDERLOOK-DEBUG %s\n", fs.UTF8String);
        if (!wasOpen) [w toggleFolder:folder];
      }
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
      {  // Visual parity V27/V28: Arc's sidebar cards; the update banner appears on the ready notice, below the tabs
        [NSNotificationCenter.defaultCenter postNotificationName:UpdaterUpdateReadyNotification object:nil
                                                        userInfo:@{@"version" : @"9.9.9", @"staged" : @"/nonexistent"}];
        [w restartToUpdate:nil];  // memory-only in tests: counted, never quits
        NSString* ub = w.updateBannerState;
        BOOL look = [ub isEqual:@"shown=1 text=NotArc 9.9.9 is ready button=Restart belowTabs=1 clicks=1"];
        std::printf("SELFTEST-UPDATEBANNER arcStyle=%d\n", look);
        if (!look) std::printf("SELFTEST-UPDATEBANNER-DEBUG %s\n", ub.UTF8String);
        [w hideUpdateBannerForTest];
      }
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
        {  // Visual parity V5: Arc's big centred bar: opaque card, 20 pt input, 40 pt rows, Return's action on the pill.
          BOOL card = [style containsString:@"card=CommandBarCardView"] && [style containsString:@"font=20"] &&
                      [style containsString:@"row=50"] && [style containsString:@"scrim=1"];
          BOOL centred = [style hasSuffix:@"centred=1"];
          BOOL hint = ![style containsString:@"hint=-"];
          NSRange wr = [style rangeOfString:@"width="];
          double width = wr.location == NSNotFound ? 0 : [[style substringFromIndex:wr.location + 6] doubleValue];
          BOOL wide = width >= 480 && width <= 780;
          [w showCommandBarForNewTab:NO];
          NSString* inPlace = w.commandBarStyle;
          [w hideCommandBar];
          BOOL onPill = [inPlace hasSuffix:@"scrim=0 centred=1"];
          std::printf("SELFTEST-CMDBARLOOK card=%d centred=%d hint=%d wide=%d onPill=%d\n", card, centred, hint, wide, onPill);
          if (!onPill) std::printf("SELFTEST-CMDBARLOOK-DEBUG cmdL %s\n", inPlace.UTF8String);
          if (!card || !centred || !hint || !wide) std::printf("SELFTEST-CMDBARLOOK-DEBUG %s\n", style.UTF8String);
        }
        {  // Omar, Nov 11 (V67, V68): the pill opens Arc's compact dropdown (348 pt, over the pill, 50 pt rows, at most
           // five, 13 pt text, no dimming); a click outside, Esc or losing focus closes it without navigating.
          NSString* before = w.shownItem.url;
          [w showCommandBarForNewTab:NO];
          NSString* geo = w.commandBarGeometry;
          NSArray* listed = [[w valueForKey:@"_suggestionList"] valueForKey:@"items"];
          NSDictionary* row0 = listed.firstObject;
          BOOL pageFirst = [row0[@"kind"] isEqual:@"go"] && [row0[@"url"] isEqual:before];  // Arc: the page, then recents
          NSRange rr = [geo rangeOfString:@" rows="];
          int rows = rr.location == NSNotFound ? 99 : [[geo substringFromIndex:NSMaxRange(rr)] intValue];
          BOOL compact = [geo hasPrefix:@"compact=1 onPill=1 width=348 "] && rows >= 1 && rows <= 5 &&
                         [geo containsString:@" rowH=50 font=13 scrim=0"];
          NSWindow* bar = w.commandBarWindow;
          NSEvent* (^click)(NSWindow*) = ^NSEvent*(NSWindow* in) {
            return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(NSWidth(in.frame) - 30, 30)
                                 modifierFlags:0 timestamp:0 windowNumber:in.windowNumber context:nil eventNumber:0
                                    clickCount:1 pressure:1];
          };
          [w commandBarFilterEvent:click(bar)];
          BOOL insideKeeps = bar.isVisible;
          [w commandBarFilterEvent:click(w.window)];
          BOOL outsideCloses = !bar.isVisible && [w.shownItem.url isEqual:before];
          [w showCommandBarForNewTab:NO];
          [w commandBarHandleSelectorForTest:@selector(cancelOperation:)];
          BOOL escCloses = !bar.isVisible && [w.shownItem.url isEqual:before];
          [w showCommandBarForNewTab:NO];
          [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidBecomeKeyNotification object:bar];
          [NSNotificationCenter.defaultCenter postNotificationName:NSWindowDidResignKeyNotification object:bar];
          BOOL focusCloses = !bar.isVisible && [w.shownItem.url isEqual:before];
          [w hideCommandBar];
          [w showCommandBarForNewTab:YES];
          NSString* big = w.commandBarGeometry;
          [w hideCommandBar];
          BOOL bigForNewTab = [big hasPrefix:@"compact=0 "] && [big containsString:@" scrim=1"];
          std::printf("SELFTEST-ADDRBAR compact=%d pageFirst=%d insideKeeps=%d outsideCloses=%d escCloses=%d focusCloses=%d bigForNewTab=%d\n",
                      compact, pageFirst, insideKeeps, outsideCloses, escCloses, focusCloses, bigForNewTab);
          if (!compact || !bigForNewTab) std::printf("SELFTEST-ADDRBAR-DEBUG compact: %s | big: %s\n", geo.UTF8String, big.UTF8String);
          // Omar, Nov 11 (V71): Arc's command bar card is see-through (the Space's colour shows through) with 10 pt corners.
          BOOL radius = [big containsString:@" radius=10 "], seeThrough = [big containsString:@" translucent=1"];
          std::printf("SELFTEST-NEWTABLOOK radius=%d translucent=%d\n", radius, seeThrough);
        }
        {  // Visual parity V30/V31: empty bar shows recent tabs and actions; a site's name + Tab starts Site Search
          NSArray* empty = [w commandSuggestionsFor:@""];
          BOOL recents = has(empty, @"tab", @"suggest-");
          BOOL actions = NO;
          for (NSDictionary* d in empty) actions |= [d[@"kind"] isEqual:@"action"];
          BOOL pure = [SiteSearchFor(@"wiki")[@"name"] isEqual:@"Wikipedia"] && [SiteSearchFor(@"YouTube ")[@"name"] isEqual:@"YouTube"] &&
                      SiteSearchFor(@"zq") == nil && SiteSearchFor(@"g") == nil;
          [w showCommandBarForNewTab:YES];
          NSTextField* field = [w valueForKey:@"_commandField"];
          field.stringValue = @"wikipedia";
          [w commandBarHandleSelectorForTest:@selector(insertTab:)];
          NSString* capsule = w.siteSearchState;
          BOOL started = [capsule isEqual:@"capsule=Search Wikipedia fieldAfter=1"] && field.stringValue.length == 0;
          [w commandBarHandleSelectorForTest:@selector(deleteBackward:)];
          BOOL dropped = [w.siteSearchState isEqual:@"none"];
          [w hideCommandBar];
          std::printf("SELFTEST-CMDBARKEYS recents=%d actions=%d sites=%d capsule=%d backspace=%d\n", recents, actions, pure, started, dropped);
          if (!started) std::printf("SELFTEST-CMDBARKEYS-DEBUG %s\n", capsule.UTF8String);
        }
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
          NSString* promptLook = w.sitePromptStyle;  // Visual parity V51: drops down from the address pill, no sheet
          std::printf("SELFTEST-PROMPTLOOK arcStyle=%d\n", [promptLook isEqual:@"popover=1 sheet=0 fromPill=1"]);
          if (![promptLook isEqual:@"popover=1 sheet=0 fromPill=1"]) std::printf("SELFTEST-PROMPTLOOK-DEBUG %s\n", promptLook.UTF8String);
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
    // Passwords and autofill (#67): encryption round trip against a Chromium vector, import from fake Arc and Chrome
    // profiles and a CSV, then on a local login page: save prompt, update, Never, the fill menu (only after a click),
    // filling login / address / card fields, Fill Password, and the Passwords window. Throwaway key, no Keychain.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 95 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSFileManager* fm = NSFileManager.defaultManager;
      PasswordStore* store = [PasswordStore shared];
      // Tests use their own file and an in-memory key, never the Keychain or Passwords.dat.
      BOOL testStore = PasswordStoreIsSelfTest() && [store.path.lastPathComponent isEqualToString:@"SelfTestPasswords.dat"] &&
                       store.usable;
      [fm removeItemAtPath:store.path error:nil];
      [store reload];
      // Chromium's scheme: a blob made outside NotArc (python PBKDF2 + openssl) decrypts, and we produce the same bytes.
      NSData* tk = ArcCookieKey(@"selftest-safe-storage");
      const unsigned char vec[] = {0x76, 0x31, 0x30, 0x83, 0xe1, 0x9b, 0x0a, 0x8b, 0x48, 0x95,
                                   0x5e, 0xc8, 0xe0, 0x75, 0x47, 0x7f, 0x38, 0xed, 0x65};
      NSData* vector = [NSData dataWithBytes:vec length:sizeof(vec)];
      NSData* plain = ChromiumDecryptValue(vector, tk);
      BOOL roundTrip = [[[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] isEqualToString:@"chromium-vector"] &&
                       [ChromiumEncryptValue([@"chromium-vector" dataUsingEncoding:NSUTF8StringEncoding], tk) isEqualToData:vector] &&
                       ![ChromiumDecryptValue(vector, ArcCookieKey(@"wrong")) isEqualToData:plain] &&
                       [[store unseal:[store seal:@"pässwörd ✓"]] isEqualToString:@"pässwörd ✓"];
      // Arc: one Space profile with Login Data (one login, one "Never" site, one android row, one wrong-key row) + Web Data.
      NSString* fake = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-passwords"];
      NSString* prof = w.currentSpace.profileDirectory.length ? w.currentSpace.profileDirectory : @"Default";
      NSString* arcProfile = [fake stringByAppendingPathComponent:prof];
      [fm removeItemAtPath:fake error:nil];
      [fm createDirectoryAtPath:arcProfile withIntermediateDirectories:YES attributes:nil error:nil];
      SelfTestMakeLoginData([arcProfile stringByAppendingPathComponent:@"Login Data"], tk, @[
        @[ @"https://accounts.example.com/", @"arc-user", @"arc-pass-1" ], @[ @"https://never.example/", @"", [NSNull null] ],
        @[ @"android://hash@com.example/", @"x", @"y" ],
        @[ @"https://bad.example/", @"b", ChromiumEncryptValue([@"zzz" dataUsingEncoding:NSUTF8StringEncoding], ArcCookieKey(@"other")) ]
      ]);
      SelfTestMakeWebData([arcProfile stringByAppendingPathComponent:@"Web Data"], tk, NO,
                          @{@"name" : @"Jane Doe", @"line1" : @"1 Main St", @"city" : @"San Francisco", @"state" : @"CA",
                            @"zip" : @"94110", @"email" : @"jane@example.com"},
                          @[ @"Jane Doe", @4, @2031, @"4111 1111 1111 1111" ]);
      w.arcSafeStorageKeyOverride = tk;
      NSDictionary* arc = [w importArcPasswordsFromUserData:fake];
      NSDictionary* arcAgain = [w importArcPasswordsFromUserData:fake];
      w.arcSafeStorageKeyOverride = nil;
      SavedLogin* arcLogin = [store loginForOrigin:@"https://accounts.example.com" username:@"arc-user"];
      BOOL arcOK = [arc[@"passwords"] intValue] == 1 && [arc[@"addresses"] intValue] == 1 && [arc[@"cards"] intValue] == 1 &&
                   [[store passwordFor:arcLogin] isEqualToString:@"arc-pass-1"] && [store isNeverOrigin:@"https://never.example"] &&
                   [arcAgain[@"passwords"] intValue] + [arcAgain[@"addresses"] intValue] + [arcAgain[@"cards"] intValue] == 0;
      // Chrome (newer address format) and a CSV export (Apple Passwords columns, quoted comma).
      NSString* chrome = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-chrome-profile"];
      [fm removeItemAtPath:chrome error:nil];
      [fm createDirectoryAtPath:chrome withIntermediateDirectories:YES attributes:nil error:nil];
      SelfTestMakeLoginData([chrome stringByAppendingPathComponent:@"Login Data"], tk,
                            @[ @[ @"https://chrome.example/", @"c1", @"cp1" ], @[ @"https://chrome.example/", @"c2", @"cp2" ] ]);
      SelfTestMakeWebData([chrome stringByAppendingPathComponent:@"Web Data"], tk, YES,
                          @{@"name" : @"John Roe", @"line1" : @"5 Side Ave", @"city" : @"Austin", @"state" : @"TX",
                            @"zip" : @"73301", @"email" : @"john@example.com"},
                          @[ @"John Roe", @12, @2030, @"5555555555554444" ]);
      NSDictionary* cr = [store importChromiumProfile:chrome key:tk source:@"Google Chrome (Test)"];
      NSDictionary* crAgain = [store importChromiumProfile:chrome key:tk source:@"Google Chrome (Test)"];
      BOOL chromeOK = [cr[@"passwords"] intValue] == 2 && [cr[@"addresses"] intValue] == 1 && [cr[@"cards"] intValue] == 1 &&
                      [crAgain[@"passwords"] intValue] + [crAgain[@"addresses"] intValue] + [crAgain[@"cards"] intValue] == 0 &&
                      [store importChromiumProfile:@"/nonexistent/profile" key:tk source:@"x"] == nil;
      NSString* csv = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-passwords.csv"];
      [@"Title,URL,Username,Password,Notes,OTPAuth\ncsv,https://csv.example/login,\"csv,user\",\"p\"\"w\",,\n"
          writeToFile:csv atomically:YES encoding:NSUTF8StringEncoding error:nil];
      BOOL csvOK = [store importCSVFile:csv source:@"CSV"] == 1 &&
                   [[store passwordFor:[store loginForOrigin:@"https://csv.example" username:@"csv,user"]] isEqualToString:@"p\"w"];
      [fm removeItemAtPath:csv error:nil];
      [fm removeItemAtPath:fake error:nil];
      [fm removeItemAtPath:chrome error:nil];

      // The login page (a local file; the page script normally runs only on http(s) pages).
      BrowserClient::SetAutofillAllowFileURLs(true);
      NSString* page = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-selftest-login.html"];
      NSMutableString* months = [NSMutableString string];
      for (int m = 1; m <= 12; ++m) [months appendFormat:@"<option>%02d</option>", m];
      [[NSString stringWithFormat:
          @"<!doctype html><title>login</title><form id=f onsubmit='event.preventDefault()'><input id=u name=username "
          @"autocomplete=username><input id=p type=password name=password><button type=submit>Sign in</button></form>"
          @"<form id=a onsubmit='event.preventDefault()'><input id=an autocomplete=name><input id=ae type=email name=email>"
          @"<input id=as name=address1><input id=ac name=city><select id=ast name=state><option value=''>-</option>"
          @"<option value=CA>California</option><option value=NY>New York</option></select><input id=az name=zip></form>"
          @"<form id=c><input id=cn autocomplete=cc-number><input id=cc name=cardholder><select id=cm "
          @"autocomplete=cc-exp-month>%@</select><input id=cy autocomplete=cc-exp-year maxlength=2></form>", months]
          writeToFile:page atomically:YES encoding:NSUTF8StringEncoding error:nil];
      [w openInNewTab:[NSURL fileURLWithPath:page].absoluteString];
      ArcItem* t = w.shownItem;
      AutofillController* af = w.autofill;
      NSString* (^byId)(NSString*) = ^(NSString* js) { return [@"var $=function(i){return document.getElementById(i)};" stringByAppendingString:js]; };
      WaitUntil(^{ return (BOOL)([t.liveTitle isEqualToString:@"login"] && t.browserId); }, 10, ^{
        [w runJS:byId(@"setTimeout(function(){document.title='onload:'+(!$('u').value&&!$('p').value)+':'+!!window.__notarcAF},300)") inItem:t];
        WaitUntil(^{ return [t.liveTitle hasPrefix:@"onload:"]; }, 5, ^{
          BOOL noFillOnLoad = [t.liveTitle isEqualToString:@"onload:true:true"] && af.menusOffered == 0;
          [w runJS:byId(@"$('u').value='selftest-user';$('p').value='hunter2-selftest';$('f').requestSubmit()") inItem:t];
          WaitUntil(^{ return [af.pendingSavePrompt hasPrefix:@"Save password"]; }, 5, ^{
            BOOL saveOffered = [af.pendingSavePrompt isEqualToString:@"Save password for this file?"] &&
                               [w.toastText isEqualToString:af.pendingSavePrompt];
            [af savePending:nil];
            BOOL saved = [[store passwordFor:[store loginForOrigin:@"file://" username:@"selftest-user"]] isEqualToString:@"hunter2-selftest"] &&
                         !w.toastText;
            [w runJS:byId(@"$('p').value='hunter3-selftest';$('f').requestSubmit()") inItem:t];
            WaitUntil(^{ return [af.pendingSavePrompt hasPrefix:@"Update"]; }, 5, ^{
              BOOL updatePrompt = [af.pendingSavePrompt hasPrefix:@"Update the saved password for selftest-user"];
              [af savePending:nil];
              BOOL updated = [[store passwordFor:[store loginForOrigin:@"file://" username:@"selftest-user"]] isEqualToString:@"hunter3-selftest"] &&
                             [store checkOrigin:@"file://" username:@"selftest-user" password:@"hunter3-selftest"] == PasswordUnchanged;
              [w runJS:byId(@"$('u').value='other-user';$('p').value='x-pass';$('f').requestSubmit()") inItem:t];
              WaitUntil(^{ return [af.pendingSavePrompt hasPrefix:@"Save password"]; }, 5, ^{
                [af neverPending:nil];
                [w runJS:byId(@"$('u').value='third-user';$('p').value='y-pass';$('f').requestSubmit()") inItem:t];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                  BOOL never = [store isNeverOrigin:@"file://"] && !af.pendingSavePrompt && ![store loginForOrigin:@"file://" username:@"other-user"];
                  [store setNever:NO forOrigin:@"file://"];
                  // Fill: a click into the empty username field offers the saved login; choosing it fills both fields.
                  [w runJS:byId(@"window.__ev=0;['u','p'].forEach(function(i){$(i).value='';$(i).addEventListener('input',function(){window.__ev++})});"
                                @"$('u').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}))") inItem:t];
                  WaitUntil(^{ return (BOOL)(af.menusOffered >= 1); }, 5, ^{
                    BOOL menu = [af.lastMenuGroup isEqualToString:@"login"] && [af.lastMenuTitles isEqualToArray:@[ @"selftest-user" ]];
                    [af chooseMenuItemAtIndex:0];
                    WaitUntil(^{ return (BOOL)(af.lastFilledCount >= 2); }, 5, ^{
                      [w runJS:byId(@"document.title='filled:'+$('u').value+'|'+$('p').value+'|'+window.__ev") inItem:t];
                      WaitUntil(^{ return [t.liveTitle hasPrefix:@"filled:"]; }, 5, ^{
                        BOOL filled = [t.liveTitle isEqualToString:@"filled:selftest-user|hunter3-selftest|2"];
                        // Edit > AutoFill > Fill Password finds the login field without a click.
                        NSInteger menusBefore = af.menusOffered;
                        [w runJS:byId(@"$('u').value='';$('p').value=''") inItem:t];
                        [w showItem:t];
                        [w fillPassword:nil];
                        WaitUntil(^{ return (BOOL)(af.menusOffered > menusBefore); }, 5, ^{
                          BOOL fillMenu = af.menusOffered > menusBefore && [af.lastMenuGroup isEqualToString:@"login"];
                          // Address and card fields offer the imported Arc / Chrome entries; a card asks for device auth.
                          NSInteger m0 = af.menusOffered;
                          [w runJS:byId(@"$('an').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}))") inItem:t];
                          WaitUntil(^{ return (BOOL)(af.menusOffered > m0); }, 5, ^{
                            NSUInteger jane = [af.lastMenuTitles indexOfObjectPassingTest:^BOOL(NSString* s, NSUInteger, BOOL*) {
                              return [s hasPrefix:@"Jane Doe, 1 Main St"];
                            }];
                            BOOL addrMenu = [af.lastMenuGroup isEqualToString:@"address"] && af.lastMenuTitles.count == 2 && jane != NSNotFound;
                            [af chooseMenuItemAtIndex:(NSInteger)jane];
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                              NSInteger m1 = af.menusOffered, auth0 = AutofillAuthRequestsForTest();
                              [w runJS:byId(@"$('cn').dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}))") inItem:t];
                              WaitUntil(^{ return (BOOL)(af.menusOffered > m1); }, 5, ^{
                                NSUInteger visa = [af.lastMenuTitles indexOfObjectPassingTest:^BOOL(NSString* s, NSUInteger, BOOL*) {
                                  return [s hasPrefix:@"•••• 1111"];
                                }];
                                BOOL cardMenu = [af.lastMenuGroup isEqualToString:@"card"] && af.lastMenuTitles.count == 2 && visa != NSNotFound;
                                [af chooseMenuItemAtIndex:(NSInteger)visa];
                                BOOL cardAuth = AutofillAuthRequestsForTest() == auth0 + 1;
                                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                                  [w runJS:byId(@"document.title='af:'+[$('an').value,$('ae').value,$('as').value,$('ac').value,$('ast').value,"
                                                @"$('az').value,$('cn').value,$('cc').value,$('cm').value,$('cy').value].join('|')") inItem:t];
                                  WaitUntil(^{ return [t.liveTitle hasPrefix:@"af:"]; }, 5, ^{
                                    BOOL address = [t.liveTitle hasPrefix:@"af:Jane Doe|jane@example.com|1 Main St|San Francisco|CA|94110|"];
                                    BOOL card = [t.liveTitle hasSuffix:@"|4111111111111111|Jane Doe|04|31"];
                                    if (!address || !card) std::printf("SELFTEST-AUTOFILL-DEBUG %s\n", t.liveTitle.UTF8String);
                                    // Passwords window: search, Show / Copy behind device auth (private pasteboard), Delete.
                                    [w showPasswords:nil];
                                    PasswordsWindowController* pwc = [PasswordsWindowController shared];
                                    pwc.section = 0;
                                    NSUInteger all = (NSUInteger)pwc.rowCount;
                                    [pwc setSearchText:@"selftest-user"];
                                    BOOL search = all == store.logins.count && all == 5 && pwc.rowCount == 1;
                                    NSInteger generalBefore = NSPasteboard.generalPasteboard.changeCount, auth1 = AutofillAuthRequestsForTest();
                                    BOOL hidden = [pwc shownSecretAtRow:0] == nil && [[pwc titleAtRow:0] containsString:@"••••"];
                                    [pwc showSecretAtRow:0];
                                    BOOL shown = hidden && [[pwc shownSecretAtRow:0] isEqualToString:@"hunter3-selftest"] &&
                                                 AutofillAuthRequestsForTest() == auth1 + 1;
                                    [pwc copySecretAtRow:0];
                                    BOOL copied = [[[w copyPasteboard] stringForType:NSPasteboardTypeString] isEqualToString:@"hunter3-selftest"] &&
                                                  NSPasteboard.generalPasteboard.changeCount == generalBefore;
                                    // On disk: encrypted (no plaintext), readable again, unreadable with another key.
                                    NSData* disk = [NSData dataWithContentsOfFile:store.path];
                                    NSData* needle1 = [@"hunter3-selftest" dataUsingEncoding:NSUTF8StringEncoding];
                                    NSData* needle2 = [@"selftest-user" dataUsingEncoding:NSUTF8StringEncoding];
                                    BOOL encrypted = disk.length > 3 && [[disk subdataWithRange:NSMakeRange(0, 3)] isEqualToData:[@"v10" dataUsingEncoding:NSUTF8StringEncoding]] &&
                                                     [disk rangeOfData:needle1 options:0 range:NSMakeRange(0, disk.length)].location == NSNotFound &&
                                                     [disk rangeOfData:needle2 options:0 range:NSMakeRange(0, disk.length)].location == NSNotFound &&
                                                     ![[PasswordStore alloc] initWithPath:store.path key:ArcCookieKey(@"wrong")].usable;
                                    [store reload];
                                    BOOL reloaded = store.logins.count == 5 && store.addresses.count == 2 && store.cards.count == 2 &&
                                                    [[store passwordFor:[store loginForOrigin:@"file://" username:@"selftest-user"]] isEqualToString:@"hunter3-selftest"];
                                    [pwc reload];
                                    [pwc setSearchText:@"selftest-user"];
                                    [pwc deleteRow:0];
                                    BOOL deleted = pwc.rowCount == 0 && ![store loginForOrigin:@"file://" username:@"selftest-user"];
                                    [pwc setSearchText:@""];
                                    // Add... in each section (addresses and cards by hand; a card must pass the Luhn check).
                                    NSDictionary* ann = @{@"name" : @"Ann Lee", @"line1" : @"9 Elm St", @"city" : @"Boston", @"zip" : @"02110"};
                                    pwc.section = 1;
                                    BOOL addAddr = [pwc addEntry:ann] && ![pwc addEntry:ann] && store.addresses.count == 3 && pwc.rowCount == 3;
                                    pwc.section = 2;
                                    BOOL addCard = ![pwc addEntry:@{@"number" : @"4111 1111 1111 1112", @"month" : @"1", @"year" : @"30"}] &&
                                                   [pwc addEntry:@{@"number" : @"3782 822463 10005", @"name" : @"Ann Lee", @"month" : @"7", @"year" : @"29"}] &&
                                                   store.cards.count == 3 && [store.cards.lastObject.summary hasPrefix:@"•••• 0005"] &&
                                                   store.cards.lastObject.expYear == 2029;
                                    pwc.section = 0;
                                    NSDictionary* manual = @{@"website" : @"manual.example", @"username" : @"m", @"password" : @"mp"};
                                    BOOL addLogin = [pwc addEntry:manual] && ![pwc addEntry:manual] &&
                                                    [[store passwordFor:[store loginForOrigin:@"https://manual.example" username:@"m"]] isEqualToString:@"mp"];
                                    BOOL manualAdd = addAddr && addCard && addLogin;
                                    if (!manualAdd) std::printf("SELFTEST-PASSWORDS-DEBUG addAddr=%d addCard=%d addLogin=%d\n", addAddr, addCard, addLogin);
                                    std::printf("SELFTEST-PASSWORDS roundTrip=%d saveOffered=%d saved=%d updatePrompt=%d updated=%d never=%d "
                                                "encrypted=%d reloaded=%d window=%d shown=%d copied=%d deleted=%d testStore=%d manualAdd=%d\n",
                                                roundTrip, saveOffered, saved, updatePrompt, updated, never, encrypted, reloaded,
                                                search, shown, copied, deleted, testStore, manualAdd);
                                    std::printf("SELFTEST-AUTOFILL noFillOnLoad=%d menu=%d filled=%d fillPassword=%d addressMenu=%d address=%d "
                                                "cardMenu=%d cardAuth=%d card=%d arcImport=%d chromeImport=%d csv=%d\n",
                                                noFillOnLoad, menu, filled, fillMenu, addrMenu, address, cardMenu, cardAuth, card, arcOK,
                                                chromeOK, csvOK);
                                    [fm removeItemAtPath:store.path error:nil];
                                    [store reload];
                                    [fm removeItemAtPath:page error:nil];
                                    [w showItem:t];
                                    [w closeTab:nil];
                                    BrowserClient::SetAutofillAllowFileURLs(false);
                                  });
                                });
                              });
                            });
                          });
                        });
                      });
                    });
                  });
                });
              });
            });
          });
        });
      });
    });
    // Filter lists (#53): a list subscribed from a local file (never the network) is parsed (network, exception and
    // cosmetic rules), the Manage Ad Blockers dialog shows it with the suggestions and site exceptions, Update Now
    // re-reads it, and on a page its cosmetic rules hide matching elements. Settings are memory-only.
    // Runs after the call/capture/PiP chain so its tab never takes the screen from the hang or call checks, and while
    // it runs blocking is on for every page; the multi-window check at the end waits for it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 140 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
     WaitUntil(^{ return gLateTestsDone; }, 50, ^{
      MainWindowController* w = self.window;
      namespace cb = content_blocker;
      FilterListManager* mgr = FilterListManager.shared;
      ManageAdBlockersWindowController* dlg = ManageAdBlockersWindowController.shared;  // built, never shown
      NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-selftest-filters.txt"];
      NSString* fixture = @"[Adblock Plus 2.0]\n! Title: NotArc Test List\n! a comment\n"
                           "||ads.fixture.example^\n"
                           "||track.fixture.example^$third-party\n"
                           "||cdn.fixture.example^$script,domain=news.example|~sports.news.example\n"
                           "@@||ok.ads.fixture.example^\n"
                           "@@||allowed-page.example^$document\n"
                           "##.notarc-generic-ad\n"
                           "example.org##.notarc-site-ad\n"
                           "example.org#@#.notarc-generic-unhidden\n"
                           "##.notarc-generic-unhidden\n"
                           "~example.org##.notarc-not-on-example\n"
                           "||popup.fixture.example^$popup\n/banner/*\nexample.com#?#div:has-text(Ad)\n##+js(noop)\n";
      [fixture writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      NSString* url = [NSURL fileURLWithPath:path].absoluteString;
      BOOL suggestedOff = NO;
      int suggestions = 0;
      for (FilterList* l in mgr.lists)
        if (l.suggested && !l.enabled && !l.updated && ([l.title isEqualToString:@"EasyList"] || [l.title isEqualToString:@"EasyPrivacy"]))
          ++suggestions;
      suggestedOff = suggestions == 2;
      BOOL parsed = cb::CountSupportedRules(fixture.UTF8String) == 10 && cb::ListTitle(fixture.UTF8String) == "NotArc Test List";
      SettingSetBool(kSettingBlockAds, YES);
      SettingSetBool(kSettingAdBlockBuiltIn, NO);  // only the fixture's made-up hosts while the page check runs
      ApplyContentBlockerSettings();
      BOOL rejects = ![dlg addListFromField:@"javascript:alert(1)"] && ![dlg addListFromField:@"ftp://lists.example/x.txt"];
      BOOL added = [dlg addListFromField:url];
      WaitUntil(^{ return (BOOL)(!mgr.busy && cb::FilterRuleCount() > 0); }, 10, ^{
        FilterList* mine = nil;
        for (FilterList* l in mgr.lists) if ([l.url isEqualToString:url]) mine = l;
        BOOL subscribed = added && mine.enabled && mine.rules == 10 && mine.updated && [mine.title isEqualToString:@"NotArc Test List"] &&
                          cb::FilterRuleCount() == 10;
        BOOL network = cb::ShouldBlock("https://ads.fixture.example/a.js", "https://news.example/", false, "script") &&
                       cb::ShouldBlock("https://x.ads.fixture.example/i.png", "https://news.example/", false, "image") &&
                       !cb::ShouldBlock("https://ads.fixture.example/", "https://ads.fixture.example/", true) &&
                       !cb::ShouldBlock("https://popup.fixture.example/", "https://news.example/", false);
        BOOL thirdParty = cb::ShouldBlock("https://track.fixture.example/p", "https://news.example/", false) &&
                          !cb::ShouldBlock("https://track.fixture.example/p", "https://www.fixture.example/", false);
        BOOL domainOpt = cb::ShouldBlock("https://cdn.fixture.example/ad.js", "https://www.news.example/", false, "script") &&
                         !cb::ShouldBlock("https://cdn.fixture.example/logo.png", "https://news.example/", false, "image") &&
                         !cb::ShouldBlock("https://cdn.fixture.example/ad.js", "https://other.example/", false, "script") &&
                         !cb::ShouldBlock("https://cdn.fixture.example/ad.js", "https://sports.news.example/", false, "script");
        BOOL exception = !cb::ShouldBlock("https://ok.ads.fixture.example/x", "https://news.example/", false) &&
                         !cb::ShouldBlock("https://ads.fixture.example/x", "https://allowed-page.example/", false) &&
                         cb::CosmeticCSS("https://allowed-page.example/").empty();
        std::string onSite = cb::CosmeticCSS("https://www.example.org/a"), elsewhere = cb::CosmeticCSS("https://other.example/");
        auto has = [](const std::string& css, const char* cls) { return css.find(std::string(cls) + "{display:none") != std::string::npos; };
        BOOL cosmetic = has(onSite, ".notarc-generic-ad") && has(onSite, ".notarc-site-ad") &&
                        !has(onSite, ".notarc-generic-unhidden") && !has(onSite, ".notarc-not-on-example") &&
                        has(elsewhere, ".notarc-generic-ad") && !has(elsewhere, ".notarc-site-ad") &&
                        has(elsewhere, ".notarc-generic-unhidden") && has(elsewhere, ".notarc-not-on-example");
        BOOL builtInOff = !cb::ShouldBlock("https://doubleclick.net/x", "https://news.example/", false);
        [dlg toggleBuiltIn];
        BOOL builtInToggle = SettingBool(kSettingAdBlockBuiltIn) && cb::ShouldBlock("https://doubleclick.net/x", "https://news.example/", false);
        [dlg toggleBuiltIn];
        builtInToggle = builtInToggle && !SettingBool(kSettingAdBlockBuiltIn);
        [w setAdBlocking:NO forHost:@"news.example"];
        BOOL siteOff = !cb::ShouldBlock("https://ads.fixture.example/a.js", "https://news.example/", false) &&
                       cb::CosmeticCSS("https://news.example/").empty();
        [dlg reload];
        NSArray<NSString*>* rows = dlg.rowSummaries;
        BOOL dialog = [rows containsObject:@"builtin=0"] && [rows containsObject:@"list=NotArc Test List|on=1|rules=10|updated=1|suggested=0"] &&
                      [rows containsObject:@"list=EasyList|on=0|rules=0|updated=0|suggested=1"] &&
                      [rows containsObject:@"list=EasyPrivacy|on=0|rules=0|updated=0|suggested=1"] && [rows containsObject:@"site=news.example"];
        if (!dialog) std::printf("SELFTEST-ADBLOCKLISTS-DEBUG rows=%s\n", [rows componentsJoinedByString:@","].UTF8String);
        [dlg removeSiteException:@"news.example"];
        BOOL siteBack = ![dlg.rowSummaries containsObject:@"site=news.example"] &&
                        cb::ShouldBlock("https://ads.fixture.example/a.js", "https://news.example/", false);
        BOOL daily = ![[mgr listsDueForRefreshAt:[NSDate date]] containsObject:url] &&
                     [[mgr listsDueForRefreshAt:[NSDate dateWithTimeIntervalSinceNow:25 * 3600]] containsObject:url];
        [[fixture stringByAppendingString:@"||more.fixture.example^\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [mgr updateList:url done:^(BOOL ok) {
          WaitUntil(^{ return (BOOL)(!mgr.busy && cb::FilterRuleCount() == 11); }, 10, ^{
            FilterList* again = nil;
            for (FilterList* l in mgr.lists) if ([l.url isEqualToString:url]) again = l;
            BOOL updated = ok && again.rules == 11 && cb::ShouldBlock("https://more.fixture.example/x", "https://news.example/", false);
            BOOL noDownloads = YES;  // the suggestions were never fetched
            for (FilterList* l in mgr.lists) if (l.suggested && l.updated) noDownloads = NO;
            std::printf("SELFTEST-ADBLOCKLISTS parsed=%d suggestedOff=%d rejects=%d subscribed=%d network=%d thirdParty=%d "
                        "domainOpt=%d exception=%d cosmetic=%d builtInOff=%d builtInToggle=%d siteOff=%d dialog=%d siteBack=%d "
                        "daily=%d updateNow=%d noDownloads=%d\n", parsed, suggestedOff, rejects, subscribed, network, thirdParty,
                        domainOpt, exception, cosmetic, builtInOff, builtInToggle, siteOff, dialog, siteBack, daily, updated,
                        noDownloads);
            std::fflush(stdout);
            // Cosmetic hiding on a real page: the style sheet goes in on page load and comes out when the list is off.
            {
              [w openInNewTab:@"https://example.org/adblock-cosmetic"];
              ArcItem* t = w.shownItem;
              NSString* probe = @"(function(){if(!document.getElementById('__notarc_adblock__'))return;"
                                 "var d=document.getElementById('nab')||document.createElement('div');d.id='nab';"
                                 "d.innerHTML='<p class=\"notarc-generic-ad\">a</p><p class=\"notarc-site-ad\">b</p>"
                                 "<p class=\"notarc-generic-unhidden\">c</p><p class=\"notarc-control\">d</p>';"
                                 "document.body.appendChild(d);document.title='cosm:'+[].map.call(d.children,function(e){"
                                 "return getComputedStyle(e).display}).join('|');})()";
              __block BOOL loaded = NO;
              WaitUntil(^{
                if (t.liveTitle.length && t.browserId) {
                  loaded = YES;
                  [w runJS:probe inItem:t];
                }
                return (BOOL)[t.liveTitle hasPrefix:@"cosm:"];
              }, 20, ^{
                if (w.shownItem != t) [w showItem:t];
                NSString* on = t.liveTitle ?: @"-";
                BOOL hidden = [on hasPrefix:@"cosm:none|none|"];  // generic rule + this site's rule
                BOOL kept = [on hasSuffix:@"|block|block"];       // "#@#" exception for this site + an unlisted class
                [mgr setList:url enabled:NO];
                WaitUntil(^{ return (BOOL)(!mgr.busy && cb::FilterRuleCount() == 0); }, 10, ^{
                  [w applyAdBlockCosmeticsToBrowser:t.browserId url:t.url];  // what the next page load does
                  [w runJS:@"document.title='off:'+!!document.getElementById('__notarc_adblock__')+'|'+"
                            "getComputedStyle(document.querySelector('.notarc-generic-ad')).display" inItem:t];
                  WaitUntil(^{ return (BOOL)[t.liveTitle hasPrefix:@"off:"]; }, 5, ^{
                    BOOL removed = [t.liveTitle isEqualToString:@"off:false|block"];
                    if (!hidden || !kept || !removed)
                      std::printf("SELFTEST-ADBLOCKCOSMETIC-DEBUG loaded=%d on=[%s] off=[%s]\n", loaded, on.UTF8String,
                                  t.liveTitle.UTF8String);
                    [mgr removeList:url];
                    BOOL gone = YES;
                    for (FilterList* l in mgr.lists) if ([l.url isEqualToString:url]) gone = NO;
                    [NSFileManager.defaultManager removeItemAtPath:path error:nil];
                    SettingSetObject(kSettingAdBlockLists, nil);
                    SettingSetObject(kSettingAdBlockBuiltIn, nil);
                    SettingSetBool(kSettingBlockAds, NO);
                    ApplyContentBlockerSettings();
                    std::printf("SELFTEST-ADBLOCKCOSMETIC hidden=%d kept=%d removed=%d listRemoved=%d off=%d\n", hidden, kept,
                                removed, gone, !cb::Enabled() && SettingBool(kSettingAdBlockBuiltIn));
                    gAdBlockTestDone = YES;
                  });
                });
              });
            }
          });
        }];
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
          BOOL applied = [on isEqualToString:@"boost:none|uppercase|rgb(1, 2, 3)|ran|true|color"];
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
            // Editor (#51): the colour wheel's point -> hue/saturation mapping; a pick on the wheel and the Intensity
            // slider set the Boost's tint, it's saved and the page gets it; a font tile works; the sections are
            // laid out in Arc's order.
            [w setBoostForHost:@"example.org" configure:^(Boost* x) { x.enabled = YES; x.hue = -1; x.font = nil; }];
            if (w.shownItem != t) [w showItem:t];
            [w editBoost:nil];
            BoostColorWheel* wheel = w.boostColorWheel;
            NSRect wr = wheel.wheelRect;
            double h1 = -1, s1 = -1, h2 = -1, s2 = -1, h3 = -1, s3 = -1, h4 = -1, s4 = -1;
            BoostWheelPick(NSMakePoint(NSMidX(wr), NSMidY(wr)), wr, &h1, &s1);
            BoostWheelPick(NSMakePoint(NSMaxX(wr), NSMidY(wr)), wr, &h2, &s2);
            BoostWheelPick(NSMakePoint(NSMidX(wr) - wr.size.width / 4, NSMidY(wr)), wr, &h3, &s3);
            BoostWheelPick(NSMakePoint(NSMidX(wr), NSMaxY(wr) + 30), wr, &h4, &s4);  // outside the rim: clamped
            BOOL math = wr.size.width > 100 && s1 < 0.01 && fabs(h2) < 0.5 && fabs(s2 - 1) < 0.01 && fabs(h3 - 180) < 0.5 &&
                        fabs(s3 - 0.5) < 0.01 && fabs(h4 - 90) < 0.5 && fabs(s4 - 1) < 0.01;
            Boost* eb = w.boostBeingEdited;
            BOOL editing = eb != nil && [eb.host isEqualToString:@"example.org"];
            [wheel pickPoint:[wheel pointForHue:120 saturation:0.5]];
            [w setBoostIntensity:0.8];
            BOOL stored = fabs(eb.hue - 120) < 1 && fabs(eb.saturation - 0.5) < 0.01 && fabs(eb.colorStrength - 0.8) < 0.01 &&
                          eb.enabled && wheel.hasColor;
            BOOL wheelSaved = NO;
            for (Boost* x in BoostStoreLoad(BoostStorePath(YES)))
              if ([x.host isEqualToString:@"example.org"] && fabs(x.hue - 120) < 1 && fabs(x.saturation - 0.5) < 0.01 &&
                  fabs(x.colorStrength - 0.8) < 0.01)
                wheelSaved = YES;
            BOOL fontTile = [w pickBoostFontTile:@"Georgia"] && [eb.font isEqualToString:@"Georgia"];
            NSArray* sections = w.boostPanelSections;
            BOOL sectionsOK = [sections isEqualToArray:@[ @"header", @"color", @"font", @"size", @"case", @"zap", @"code" ]];
            if (!sectionsOK) std::printf("SELFTEST-BOOST-DEBUG sections=[%s]\n", [sections componentsJoinedByString:@","].UTF8String);
            [w runJS:@"(function(){var a=getComputedStyle(document.documentElement,'::after');document.title='tint:'+"
                      "[a.backgroundColor,a.mixBlendMode,a.opacity,getComputedStyle(document.body).fontFamily].join('|')})()"
              inItem:t];
            WaitUntil(^{ return (BOOL)[t.liveTitle hasPrefix:@"tint:"]; }, 5, ^{
              NSString* tint = t.liveTitle;  // hsl(120, 50%, 50%) is rgb(64, 191, 64)
              BOOL pageTint = [tint hasPrefix:@"tint:rgb(64, 191, 64)|color|0.8|"] && [tint containsString:@"Georgia"];
              if (!pageTint) std::printf("SELFTEST-BOOST-DEBUG tint=[%s]\n", tint.UTF8String);
              [w deleteBoostForHost:@"example.org"];
              std::printf("SELFTEST-BOOST applied=%d zapAdded=%d subdomain=%d off=%d saved=%d deleted=%d related=%d "
                          "indicatorOn=%d indicatorOff=%d\n", applied, zapAdded, sub, off, saved, w.savedBoostCount == 0, related,
                          [indOn isEqualToString:@"on"], [indOff isEqualToString:@"off"]);
              std::printf("SELFTEST-BOOSTEDITOR wheelMath=%d editing=%d wheelTint=%d wheelSaved=%d pageTint=%d fontTile=%d "
                          "sections=%d\n", math, editing, stored, wheelSaved, pageTint, fontTile, sectionsOK);
            });
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
          // Unread (Arc's unread dot): "d" arrived after the first fill, so it's unread and the folder counts it; "b"
          // was there from the start. It's saved, and opening the tab clears it.
          ArcItem* fresh = f.children.firstObject;
          if (![w folderExpanded:f]) [w toggleFolder:f];
          BOOL marked = fresh.liveUnread && !keep.liveUnread && [w liveUnreadCountOf:f] == 1;
          BOOL folderCount = [[w liveBadgeForItem:f] isEqualToString:@"1"];
          BOOL dotShown = [[w liveBadgeForItem:fresh] isEqualToString:@"dot"] && [[w liveBadgeForItem:keep] isEqualToString:@""];
          [w saveSidebarNow];
          BOOL unreadSaved = [[NSString stringWithContentsOfFile:SidebarStorePath(YES) encoding:NSUTF8StringEncoding error:nil]
              containsString:@"\"liveUnread\""];
          [w showItem:fresh];
          BOOL cleared = !fresh.liveUnread && [[w liveBadgeForItem:f] isEqualToString:@""] &&
                         [[w liveBadgeForItem:fresh] isEqualToString:@""];
          std::printf("SELFTEST-LIVEUNREAD marked=%d folderCount=%d dot=%d saved=%d cleared=%d\n", marked, folderCount,
                      dotShown, unreadSaved, cleared);
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
    // Live Folders from GitHub (My Pull Requests, read with the Space's sign-in) and YouTube channels. Every page comes
    // from local fixture files (LiveFolderSetTestPages), never the network: signed out shows the sign-in entry; signed in
    // fills the folder from GitHub's search page (server-rendered links) and its embedded page data; a new pull request
    // comes in unread; a YouTube @handle resolves to its channel id and fills from the channel feed.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 145 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"notarc-selftest-live"];
      [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
      NSString* (^put)(NSString*, NSString*) = ^(NSString* name, NSString* text) {
        NSString* path = [dir stringByAppendingPathComponent:name];
        [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return path;
      };
      NSString* head = @"<!DOCTYPE html><html><head><meta name=\"user-login\" content=\"%@\"></head><body>%@</body></html>";
      NSString* (^result)(NSString*, NSString*, NSString*) = ^(NSString* repo, NSString* num, NSString* title) {
        return [NSString stringWithFormat:@"<div class=\"Result\"><h3><div><a href=\"/%@\"><span>%@</span></a></div><div class=\"search-title\">"
                                           "<a class=\"prc-Link\" href=\"/%@/pull/%@\"><span class=\"search-match\">%@</span></a></div></h3>"
                                           "<a class=\"issueNumberLink\" href=\"/%@/pull/%@\" target=\"_blank\">#%@</a>"
                                           "<a href=\"/%@/pull/%@#issuecomment-1\">2 comments</a></div>",
                                          repo, repo, repo, num, title, repo, num, num, repo, num];
      };
      NSString* signedOut = put(@"out.html", [NSString stringWithFormat:head, @"", @"<a href=\"/login\">Sign in</a>"]);
      NSString* mine1 = put(@"mine1.html", [NSString stringWithFormat:head, @"octo",
          [result(@"acme/web", @"12", @"Fix login") stringByAppendingString:result(@"acme/web", @"9", @"Faster &lt;b&gt; builds")]]);
      NSString* mine2 = put(@"mine2.html", [NSString stringWithFormat:head, @"octo",
          [@[ result(@"acme/web", @"13", @"Dark mode"), result(@"acme/web", @"12", @"Fix login"), result(@"acme/web", @"9", @"Faster &lt;b&gt; builds") ]
              componentsJoinedByString:@""]]);
      NSString* review = put(@"review.html", [NSString stringWithFormat:head, @"octo",
          @"<script type=\"application/json\" data-target=\"react-app.embeddedData\">{\"payload\":{\"pullRequests\":["
           "{\"number\":30,\"permalink\":\"https://github.com/acme/api/pull/30\",\"title\":\"Add rate limits\"},"
           "{\"number\":12,\"permalink\":\"https://github.com/acme/web/pull/12\",\"title\":\"Fix login\"}]}}</script>"]);
      NSArray<NSString*>* urls = LiveFolderGitHubMineURLs();
      LiveFolderSetTestPages(@{urls[0] : signedOut, urls[1] : signedOut});
      ArcItem* f = [w createMyPullRequestsFolder];
      WaitUntil(^{ return (BOOL)(f.children.count == 1 && f.liveSignInNeeded); }, 10, ^{
        BOOL signInState = f.children.count == 1 && [f.children[0].url isEqualToString:kLiveFolderGitHubSignInURL] &&
                           [f.children[0].displayTitle containsString:@"Sign in to GitHub"] && [f.liveError containsString:@"GitHub"] &&
                           !f.children[0].liveUnread && !f.liveFilled;
        {  // Visual parity V25: Arc's + menu, an icon on every row, in Arc's order
          NSMutableArray* titles = [NSMutableArray array];
          BOOL icons = YES;
          for (NSMenuItem* it in [w newItemMenu].itemArray) {
            if (it.isSeparatorItem) continue;
            [titles addObject:it.title];
            if (!it.image) icons = NO;
          }
          BOOL order = [[titles componentsJoinedByString:@","]
              isEqual:@"New Tab,New Split View,New Split View Below,New Folder,New Easel,New Note,New Boost,New Live Folder,"
                      @"New Space...,New Profile..."];
          std::printf("SELFTEST-PLUSMENU icons=%d order=%d\n", icons, order);
          if (!order) std::printf("SELFTEST-PLUSMENU-DEBUG %s\n", [titles componentsJoinedByString:@","].UTF8String);
        }
        NSMenu* sub = [w newLiveFolderMenuItem].submenu;
        BOOL menu = [sub itemWithTitle:@"GitHub: My Pull Requests"].action == @selector(newMyPullRequestsFolder:) &&
                    [sub itemWithTitle:@"YouTube Channel..."].action == @selector(newYouTubeLiveFolder:) &&
                    [sub itemWithTitle:@"Feed or GitHub Repository..."].action == @selector(newLiveFolder:);
        LiveFolderSetTestPages(@{urls[0] : mine1, urls[1] : review});
        [w refreshLiveFolder:f done:^(BOOL ok) {
          NSMutableArray* titles = [NSMutableArray array];
          for (ArcItem* c in f.children) [titles addObject:c.displayTitle ?: @""];
          BOOL signedIn = ok && !f.liveSignInNeeded && !f.liveError && f.children.count == 3 &&
                          [f.children[0].url isEqualToString:@"https://github.com/acme/web/pull/12"] &&
                          [titles[0] isEqualToString:@"Fix login · web#12"] && [titles[1] isEqualToString:@"Faster <b> builds · web#9"] &&
                          [titles[2] isEqualToString:@"Review: Add rate limits · api#30"];
          BOOL firstFillRead = f.liveFilled && [w liveUnreadCountOf:f] == 0;
          BOOL once = [w createMyPullRequestsFolder] == f;  // one per Space
          LiveFolderSetTestPages(@{urls[0] : mine2, urls[1] : review});
          if (!signedIn) std::printf("SELFTEST-LIVEGITHUB-DEBUG titles=%s\n", [titles componentsJoinedByString:@"|"].UTF8String);
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
          [w refreshLiveFolder:f done:^(BOOL ok2) {
            ArcItem* added = nil;
            for (ArcItem* c in f.children)
              if ([c.url isEqualToString:@"https://github.com/acme/web/pull/13"]) added = c;
            BOOL newUnread = ok2 && added.liveUnread && [w liveUnreadCountOf:f] == 1 && f.children.count == 4;
            BOOL badge = [[w liveBadgeForItem:f] isEqualToString:@"1"];
            BOOL out = YES, in = NO;
            NSArray* none = LiveFolderParseGitHubHTML([NSString stringWithContentsOfFile:signedOut encoding:NSUTF8StringEncoding error:nil],
                                                      25, NO, &out);
            BOOL parse = none.count == 0 && !out && LiveFolderParseGitHubHTML(@"<html>not github</html>", 25, NO, &in) == nil &&
                         LiveFolderIsGitHubSignedInLanding(@"https://github.com/pulls") &&
                         !LiveFolderIsGitHubSignedInLanding(@"https://github.com/login?return_to=x") &&
                         !LiveFolderIsGitHubSignedInLanding(@"https://github.com/sessions/two-factor");
            [w deleteSidebarItem:f];
            std::printf("SELFTEST-LIVEGITHUB signInState=%d menu=%d signedIn=%d firstFillRead=%d once=%d newUnread=%d badge=%d "
                        "parse=%d\n", signInState, menu, signedIn, firstFillRead, once, newUnread, badge, parse);
            // YouTube: "@handle" -> the channel page (read once) -> channel id -> its public feed.
            NSString* cid = @"UCabcdefghijklmnopqrstuv";
            NSString* page = put(@"channel.html", @"<html><head><link rel=\"canonical\" href=\"https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv\">"
                                                   "<meta property=\"og:title\" content=\"Test &amp; Channel\"></head><body></body></html>");
            NSString* feed = put(@"videos.xml",
                @"<?xml version=\"1.0\" encoding=\"UTF-8\"?><feed xmlns:yt=\"http://www.youtube.com/xml/schemas/2015\" "
                 "xmlns:media=\"http://search.yahoo.com/mrss/\" xmlns=\"http://www.w3.org/2005/Atom\"><title>Test Channel</title>"
                 "<link rel=\"alternate\" href=\"https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv\"/>"
                 "<entry><yt:videoId>vid1</yt:videoId><title>First video</title><link rel=\"alternate\" href=\"https://www.youtube.com/watch?v=vid1\"/>"
                 "<author><name>Test</name><uri>https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv</uri></author>"
                 "<media:group><media:title>First video</media:title></media:group></entry>"
                 "<entry><title>Second video</title><link rel=\"alternate\" href=\"https://www.youtube.com/watch?v=vid2\"/></entry></feed>");
            NSString* feedURL = LiveFolderFetchURL(@"youtube", cid);
            LiveFolderSetTestPages(@{@"https://www.youtube.com/@notarctest" : page, feedURL : feed});
            NSDictionary* in1 = LiveFolderSourceFromInput(@"youtube.com/@notarctest", NO);
            NSDictionary* in2 = LiveFolderSourceFromInput(@"@notarctest", NO);
            NSDictionary* in3 = LiveFolderSourceFromInput(@"https://www.youtube.com/channel/UCabcdefghijklmnopqrstuv/videos", NO);
            BOOL input = [in1[@"kind"] isEqualToString:@"youtube"] && [in1[@"resolve"] isEqualToString:@"https://www.youtube.com/@notarctest"] &&
                         [in2[@"resolve"] isEqualToString:@"https://www.youtube.com/@notarctest"] && [in3[@"source"] isEqualToString:cid] &&
                         LiveFolderSourceFromInput(@"https://www.youtube.com/", NO) == nil &&
                         [feedURL isEqualToString:@"https://www.youtube.com/feeds/videos.xml?channel_id=UCabcdefghijklmnopqrstuv"];
            BOOL fromVideo = [LiveFolderYouTubeChannelIDFromHTML(@"<meta itemprop=\"channelId\" content=\"UCabcdefghijklmnopqrstuv\">", nil)
                                 isEqualToString:cid] && LiveFolderYouTubeChannelIDFromHTML(@"<html></html>", nil) == nil;
            [w createLiveFolderFromInput:@"https://www.youtube.com/@notarctest" done:^(ArcItem* yf) {
              WaitUntil(^{ return (BOOL)(yf.children.count == 2); }, 10, ^{
                BOOL resolved = [yf.liveKind isEqualToString:@"youtube"] && [yf.liveSource isEqualToString:cid] &&
                                [yf.displayTitle isEqualToString:@"Test & Channel"];
                BOOL filled = yf.children.count == 2 && [yf.children[0].url isEqualToString:@"https://www.youtube.com/watch?v=vid1"] &&
                              [yf.children[0].displayTitle isEqualToString:@"First video"] && !yf.children[0].liveUnread;
                if (yf) [w deleteSidebarItem:yf];
                LiveFolderSetTestPages(nil);
                [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
                std::printf("SELFTEST-LIVEYOUTUBE input=%d resolved=%d filled=%d fromVideo=%d\n", input, resolved, filled, fromVideo);
              });
            }];
          }];
          });
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
          {  // Visual parity V43: Arc's easel bar also has Add Image and Capture
            BOOL bar = ev.extraToolCount == 2 && [ev.toolbar.identifier isEqual:@"easelToolbar"] && ev.toolbar.layer.cornerRadius == 12;
            std::printf("SELFTEST-EASELLOOK bar=%d\n", bar);
          }
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
    // Easel tools (#49): drawing (arrow, rectangle, ellipse, pen) and resizing with real mouse events on the canvas,
    // colours, Delete and Esc, all saved; then a live web clip of a local test page that refreshes off-screen (menu and
    // easel opening, never a tab switch), and area / full-page captures into the easel. Runs after the capture chain
    // (it needs the shown tab to itself); the multi-window check waits for gEaselToolsDone.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 135 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
     WaitUntil(^{ return gLateTestsDone; }, 60, ^{
      MainWindowController* w = self.window;
      NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"NotArcEaselClipSelfTest"];
      [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
      NSString* html = [dir stringByAppendingPathComponent:@"clip.html"];
      NSString* (^page)(NSString*) = ^(NSString* lower) {
        return [NSString stringWithFormat:@"<html><head><title>clip</title></head><body style=\"margin:0\"><div style=\""
                                          @"height:300px;background:#00c040\"></div><div style=\"height:1700px;background:%@\">"
                                          @"</div></body></html>", lower];
      };
      [page(@"#0040ff") writeToFile:html atomically:YES encoding:NSUTF8StringEncoding error:nil];
      NSString* pageURL = [NSURL fileURLWithPath:html].absoluteString;
      [w openInNewTab:pageURL];
      ArcItem* tab = w.shownItem;
      // Drawing.
      ArcItem* easel = [w createEaselWithID:nil];
      EaselView* ev = [w easelView];
      BOOL toolbar = ev.toolbar.superview != nil && !ev.toolbar.hidden && ev.toolbar.frame.size.width > 200;
      NSArray<NSString*>* pal = [EaselView palette];
      ev.color = pal[5];
      ev.tool = @"arrow";
      [ev testDragFrom:NSMakePoint(60, 100) to:NSMakePoint(260, 180) steps:6];
      EaselObject* arrow = ev.objects.lastObject;
      BOOL arrowOK = [arrow.kind isEqualToString:@"arrow"] && arrow.points.count == 2 && [arrow.color isEqualToString:pal[5]] &&
                     NSEqualRects(arrow.frame, NSMakeRect(50, 90, 220, 100));
      ev.tool = @"rect";
      [ev testDragFrom:NSMakePoint(60, 220) to:NSMakePoint(200, 300) steps:4];
      EaselObject* rect = ev.objects.lastObject;
      BOOL rectOK = [rect.kind isEqualToString:@"rect"] && NSEqualRects(rect.frame, NSMakeRect(50, 210, 160, 100));
      ev.tool = @"ellipse";
      [ev testDragFrom:NSMakePoint(240, 220) to:NSMakePoint(380, 300) steps:4];
      EaselObject* ellipse = ev.objects.lastObject;
      BOOL ellipseOK = [ellipse.kind isEqualToString:@"ellipse"] && NSEqualRects(ellipse.frame, NSMakeRect(230, 210, 160, 100));
      ev.tool = @"pen";
      NSUInteger before = ev.objects.count;
      [ev testDragFrom:NSMakePoint(60, 360) to:NSMakePoint(300, 380) steps:12];
      EaselObject* pen = ev.objects.lastObject;
      [ev testDragFrom:NSMakePoint(500, 500) to:NSMakePoint(500, 500) steps:1];  // a click draws nothing
      BOOL penOK = ev.objects.count == before + 1 && [pen.kind isEqualToString:@"pen"] && pen.points.count >= 8 &&
                   [ev.tool isEqualToString:@"pen"];
      NSEvent* (^key)(NSString*, unsigned short) = ^(NSString* ch, unsigned short code) {
        return [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0
                            windowNumber:w.window.windowNumber context:nil characters:ch charactersIgnoringModifiers:ch
                               isARepeat:NO keyCode:code];
      };
      [ev keyDown:key(@"\e", 53)];
      BOOL escape = [ev.tool isEqualToString:@"select"];
      [ev keyDown:key(@"r", 15)];
      escape = escape && [ev.tool isEqualToString:@"rect"];
      [ev keyDown:key(@"\e", 53)];
      [ev selectObject:rect];
      ev.color = pal[2];
      BOOL colour = [rect.color isEqualToString:pal[2]] && [arrow.color isEqualToString:pal[5]];
      NSView* rectView = [ev viewForObject:rect];
      NSView* (^hit)(NSPoint) = ^(NSPoint pt) { return [ev hitTest:[ev.superview convertPoint:pt fromView:ev]]; };
      BOOL hitThrough = hit(NSMakePoint(130, 260)) != rectView && hit(NSMakePoint(60, 260)) == rectView;
      // Resizing by the corner handles.
      NSRect rf = rect.frame;
      [ev testDragFrom:NSMakePoint(NSMaxX(rf) - 5, NSMaxY(rf) - 5) to:NSMakePoint(NSMaxX(rf) + 55, NSMaxY(rf) + 35) steps:5];
      BOOL resized = NSEqualRects(rect.frame, NSMakeRect(50, 210, 215, 135)) && NSEqualRects(rectView.frame, rect.frame);
      EaselObject* txt = [ev addText:@"Plan" at:NSMakePoint(420, 100)];
      [w.window makeFirstResponder:ev];
      NSRect tf = txt.frame;
      [ev testDragFrom:NSMakePoint(NSMaxX(tf) - 5, NSMaxY(tf) - 5) to:NSMakePoint(NSMaxX(tf) + 75, NSMaxY(tf) + 15) steps:3];
      BOOL textResized = NSEqualRects(txt.frame, NSMakeRect(420, 100, NSMaxX(tf) + 75 - 420, NSMaxY(tf) + 15 - 100));
      NSBitmapImageRep* pr = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:200 pixelsHigh:100 bitsPerSample:8
          samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
      EaselObject* pic = [ev addImagePNG:[pr representationUsingType:NSBitmapImageFileTypePNG properties:@{}] link:@"https://example.org/pic"];
      NSRect pf = pic.frame;
      [ev testDragFrom:NSMakePoint(NSMaxX(pf) - 5, NSMaxY(pf) - 5) to:NSMakePoint(NSMaxX(pf) + 95, NSMaxY(pf) - 5) steps:4];
      BOOL aspect = NSEqualPoints(pic.frame.origin, pf.origin) && pic.frame.size.width == pf.size.width + 95 &&
                    fabs(pic.frame.size.width / pic.frame.size.height - pf.size.width / pf.size.height) < 0.02;
      if (!aspect) std::printf("SELFTEST-EASELDRAW-DEBUG pic=%s before=%s\n", NSStringFromRect(pic.frame).UTF8String, NSStringFromRect(pf).UTF8String);
      [ev selectObject:pen];
      [w.window makeFirstResponder:ev];
      NSUInteger n0 = ev.objects.count;
      [ev keyDown:key([NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter], 51)];
      BOOL deleted = ev.objects.count == n0 - 1 && ![ev.objects containsObject:pen];
      NSArray* kinds = [ev.objects valueForKey:@"kind"];
      NSString* rectFrame = NSStringFromRect(rect.frame);
      [w showItem:tab];
      BOOL barHidden = ev.toolbar.hidden;
      [w showItem:easel];
      EaselView* ev2 = [w easelView];
      BOOL saved = [[ev2.objects valueForKey:@"kind"] isEqual:kinds] && ev2.objects.count == 5 &&
                   [NSStringFromRect(ev2.objects[1].frame) isEqualToString:rectFrame] && [ev2.objects[1].color isEqualToString:pal[2]] &&
                   ev2.objects[0].points.count == 2 && [ev2.tool isEqualToString:@"select"];
      std::printf("SELFTEST-EASELDRAW toolbar=%d arrow=%d rect=%d ellipse=%d pen=%d escape=%d colour=%d hitThrough=%d "
                  "resized=%d textResized=%d aspect=%d deleted=%d barHidden=%d saved=%d\n", toolbar, arrowOK, rectOK,
                  ellipseOK, penOK, escape, colour, hitThrough, resized, textResized, aspect, deleted, barHidden, saved);
      [w closeTab:nil];  // the drawing easel; the clip below goes into a fresh one
      // Live web clip.
      WaitUntil(^{ if (w.shownItem != tab) [w showItem:tab]; return (BOOL)([tab.liveTitle isEqualToString:@"clip"] && ![w isLoading]); }, 20, ^{
        [w runJS:@"window.scrollTo(0,300);document.title='scrolled'" inItem:tab];
        WaitUntil(^{ return [tab.liveTitle isEqualToString:@"scrolled"]; }, 5, ^{
          if (w.shownItem != tab) [w showItem:tab];
          [w liveClipArea:NSMakeRect(20, 20, 200, 120) done:^(EaselObject* clip) {
            ArcItem* clipEasel = w.shownItem;
            EaselView* cv = [w easelView];
            BOOL clipped = clip && [clip.kind isEqualToString:@"clip"] && [clip.link isEqualToString:pageURL] &&
                           NSEqualRects(clip.region, NSMakeRect(20, 20, 200, 120)) && clip.viewport.width > 220 &&
                           [NSFileManager.defaultManager fileExistsAtPath:[cv.directory stringByAppendingPathComponent:clip.image ?: @"-"]];
            BOOL scrolled = fabs(clip.scroll.y - 300) < 2;
            NSInteger started0 = EaselClipRendersStarted();
            [w showItem:tab];
            [w showItem:clipEasel];
            BOOL notOnSwitch = EaselClipRendersStarted() == started0;  // fresh clip: opening again doesn't re-render
            [page(@"#ff2020") writeToFile:html atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:@"Refresh Live Clips" action:@selector(refreshLiveClipsFromMenu:) keyEquivalent:@""];
            BOOL menu = [(id<NSMenuItemValidation>)w validateMenuItem:mi];
            NSString* oldImage = clip.image;
            NSInteger done0 = w.clipRefreshesFinished;
            [w refreshLiveClipsFromMenu:nil];
            WaitUntil(^{ return (BOOL)(w.clipRefreshesFinished > done0); }, 30, ^{
              if (w.shownItem != clipEasel) [w showItem:clipEasel];  // other timed checks switch tabs concurrently
              EaselView* cv2 = [w easelView];
              EaselObject* c = cv2.liveClips.firstObject;
              NSData* png = [NSData dataWithContentsOfFile:[cv2.directory stringByAppendingPathComponent:c.image ?: @"-"]];
              NSBitmapImageRep* rep = png ? [NSBitmapImageRep imageRepWithData:png] : nil;
              NSColor* px = rep ? [[rep colorAtX:rep.pixelsWide / 2 y:rep.pixelsHigh / 2] colorUsingColorSpace:NSColorSpace.sRGBColorSpace] : nil;
              BOOL refreshed = c && ![c.image isEqualToString:oldImage] && rep.pixelsWide >= 200 && c.refreshedAt.timeIntervalSinceNow > -30;
              // Red, from the scrolled part of the page (unscrolled, the region would be green).
              BOOL live = px && px.redComponent - px.blueComponent > 0.3 && px.redComponent - px.greenComponent > 0.3;
              if (!live) std::printf("SELFTEST-EASELCLIP-DEBUG px=%s size=%ldx%ld\n", px.description.UTF8String ?: "-", (long)rep.pixelsWide, (long)rep.pixelsHigh);
              // Opening an easel refreshes clips older than a minute.
              c.refreshedAt = [NSDate dateWithTimeIntervalSinceNow:-3600];
              [cv2 save];
              [w showItem:tab];
              NSInteger s1 = EaselClipRendersStarted();
              [w showItem:clipEasel];
              BOOL onOpen = EaselClipRendersStarted() == s1 + 1;
              NSInteger done1 = w.clipRefreshesFinished;
              WaitUntil(^{ return (BOOL)(w.clipRefreshesFinished > done1); }, 30, ^{
                // Area and full-page captures straight into the easel (the Capture code from #48).
                [w showItem:tab];
                [w captureToEaselMode:@"area" rect:NSMakeRect(10, 10, 100, 50) done:^(EaselObject* a) {
                  BOOL area = a && [a.kind isEqualToString:@"image"] && [a.link isEqualToString:pageURL] && w.shownItem == clipEasel &&
                              a.frame.size.width > 90 && a.frame.size.width < 340;
                  [w showItem:tab];
                  [w captureToEaselMode:@"full" rect:NSZeroRect done:^(EaselObject* f) {
                    BOOL full = f && [f.kind isEqualToString:@"image"] && f.frame.size.height > f.frame.size.width &&
                                [w easelView].objects.count == 3 && w.shownItem == clipEasel;
                    std::printf("SELFTEST-EASELCLIP clipped=%d scrolled=%d notOnSwitch=%d menu=%d refreshed=%d live=%d onOpen=%d "
                                "area=%d full=%d closed=%d\n", clipped, scrolled, notOnSwitch, menu, refreshed, live, onOpen,
                                area, full, EaselClipRenderersActive() <= 1);
                    [w showItem:clipEasel];
                    [w closeTab:nil];
                    [w showItem:tab];
                    [w closeTab:nil];
                    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
                    gEaselToolsDone = YES;
                  }];
                }];
              });
            });
          }];
        });
      });
     });
    });
    // Import Everything from Arc (#150, Nov 10 fixes): Arc's logins (cookies) are copied into each Space's CEF profile
    // with every field kept, a second import brings Arc's newer values, errors come back in plain words, and the
    // launch offer shows whenever Arc data exists and nothing was imported yet. Fake Arc files and a throwaway key only.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 105 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      NSFileManager* fm = NSFileManager.defaultManager;
      NSData* tk = ArcCookieKey(@"selftest-arc-safe-storage");
      NSString* fake = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-cookies"];
      NSString* prof = w.currentSpace.profileDirectory.length ? w.currentSpace.profileDirectory : @"Default";
      [fm removeItemAtPath:fake error:nil];
      [fm createDirectoryAtPath:[fake stringByAppendingPathComponent:prof] withIntermediateDirectories:YES attributes:nil error:nil];
      NSString* db = ArcCookieDBPathIn(fake, prof);
      NSData* other = ArcCookieKey(@"someone-else");
      // [host, name, value, path, secure, httponly, samesite (DB), expires in s (0 = session), key]
      NSArray* (^rows)(NSString*) = ^NSArray*(NSString* v) {
        return @[ @[ @".cookies.example", @"sid", v, @"/", @1, @1, @1, @86400, tk ],
                  @[ @"www.cookies.example", @"pref", @"dark", @"/", @1, @0, @2, @0, tk ],
                  @[ @"www.cookies.example", @"plain", @"old-row", @"/", @0, @0, @-1, @86400, NSNull.null ],
                  @[ @".cookies.example", @"gone", @"x", @"/", @1, @0, @1, @-3600, tk ],
                  @[ @".cookies.example", @"locked", @"y", @"/", @1, @0, @1, @86400, other ] ];
      };
      SelfTestMakeCookies(db, rows(@"session-1"));
      ArcCookieStats st;
      NSError* err = nil;
      NSArray<ArcCookie*>* read = ArcReadCookies(db, tk, &st, &err);
      BOOL reader = read.count == 3 && st.total == 5 && st.expired == 1 && st.undecryptable == 1;
      NSError* wrongErr = nil;
      NSArray* wrong = ArcReadCookies(db, ArcCookieKey(@"wrong"), &st, &wrongErr);
      NSError* missingErr = nil;
      ArcReadCookies([fake stringByAppendingPathComponent:@"Nope/Cookies"], tk, &st, &missingErr);
      BOOL plainErrors = wrong.count == 1 /* the unencrypted row */ && [missingErr.localizedDescription containsString:@"no cookie file"];
      NSString* lockedOnly = [fake stringByAppendingPathComponent:@"locked-only"];
      [fm createDirectoryAtPath:lockedOnly withIntermediateDirectories:YES attributes:nil error:nil];
      SelfTestMakeCookies([lockedOnly stringByAppendingPathComponent:@"Cookies"], @[ @[ @".x.example", @"a", @"b", @"/", @1, @0, @1, @86400, other ] ]);
      NSError* lockedErr = nil;
      ArcReadCookies([lockedOnly stringByAppendingPathComponent:@"Cookies"], tk, &st, &lockedErr);
      plainErrors = plainErrors && [lockedErr.localizedDescription containsString:@"didn't unlock"];
      // Launch offer and the summary words (pure).
      BOOL offer = ArcImportOfferDue(@{}, YES) && ArcImportOfferDue(@{@"arcImportOffered" : @YES}, YES) &&
                   !ArcImportOfferDue(@{kArcImportCompletedKey : [NSDate date]}, YES) &&
                   !ArcImportOfferDue(@{kArcImportDeclinedKey : @YES}, YES) && !ArcImportOfferDue(@{}, NO) &&
                   ArcImportOfferDue(@{kArcImportDeclinedKey : @NO}, YES);
      NSString* summary = ArcImportSummary(@{@"history" : @2, @"extensions" : @1, @"skipped" : @0,
                                             @"passwordError" : @"macOS didn't give NotArc Arc's key (denied)."},
                                           @{@"set" : @2, @"profiles" : @1, @"errors" : @[ @"Work: Arc has no cookie file for this profile" ]});
      BOOL words = [summary containsString:@"Logins (cookies): 2 copied into 1 profile"] &&
                   [summary containsString:@"not copied. macOS didn't give NotArc Arc's key"] &&
                   [summary containsString:@"Work: Arc has no cookie file"] && [summary containsString:@"may still ask you to sign in"];
      BOOL iconMigration = AppIconMigrationDue(@{kSettingAppIcon : @"forest"}) &&
                           !AppIconMigrationDue(@{kSettingAppIcon : @"forest", @"appIconBundleDefault" : @YES}) &&
                           !AppIconMigrationDue(@{});
      NSString* url = @"https://www.cookies.example/";
      [w importArcCookiesFromUserData:fake key:nil done:^(NSDictionary* noKey) {
        BOOL keyError = [noKey[@"set"] intValue] == 0 && [[noKey[@"errors"] firstObject] containsString:@"macOS didn't give"];
        [w importArcCookiesFromUserData:fake key:tk done:^(NSDictionary* first) {
          [w testCookieDetailsForURL:url done:^(NSArray<NSDictionary*>* c1) {
            NSDictionary *sid = nil, *pref = nil, *plain = nil;
            for (NSDictionary* c in c1) {
              if ([c[@"name"] isEqual:@"sid"]) sid = c;
              if ([c[@"name"] isEqual:@"pref"]) pref = c;
              if ([c[@"name"] isEqual:@"plain"]) plain = c;
            }
            int64_t nowCef = (int64_t)(([[NSDate date] timeIntervalSince1970] + 11644473600.0) * 1e6);
            BOOL copied = [first[@"set"] intValue] >= 3 && c1.count == 3;
            BOOL fields = [sid[@"value"] isEqual:@"session-1"] && [sid[@"domain"] isEqual:@".cookies.example"] &&
                          [sid[@"secure"] boolValue] && [sid[@"httponly"] boolValue] &&
                          [sid[@"samesite"] intValue] == CEF_COOKIE_SAME_SITE_LAX_MODE && [sid[@"hasExpires"] boolValue] &&
                          llabs([sid[@"expires"] longLongValue] - (nowCef + 86400000000LL)) < 600000000LL &&
                          [pref[@"samesite"] intValue] == CEF_COOKIE_SAME_SITE_STRICT_MODE && ![pref[@"httponly"] boolValue] &&
                          ![pref[@"hasExpires"] boolValue] && [pref[@"domain"] isEqual:@"www.cookies.example"] &&
                          [plain[@"value"] isEqual:@"old-row"];
            BOOL reported = [first[@"expired"] intValue] >= 1 && [first[@"locked"] intValue] >= 1;
            SelfTestMakeCookies(db, rows(@"session-2"));  // Arc renewed the session since
            [w importArcCookiesFromUserData:fake key:tk done:^(NSDictionary* second) {
              [w testCookieDetailsForURL:url done:^(NSArray<NSDictionary*>* c2) {
                BOOL renewed = NO;
                for (NSDictionary* c in c2)
                  if ([c[@"name"] isEqual:@"sid"]) renewed = [c[@"value"] isEqual:@"session-2"];
                renewed = renewed && c2.count == 3;
                [w testDeleteCookiesForURL:url done:^{
                  [fm removeItemAtPath:fake error:nil];
                  std::printf("SELFTEST-ARCCOOKIES reader=%d plainErrors=%d keyError=%d copied=%d fields=%d reported=%d "
                              "renewed=%d offer=%d words=%d iconMigration=%d\n", reader, plainErrors, keyError, copied,
                              fields, reported, renewed, offer, words, iconMigration);
                }];
              }];
            }];
          }];
        }];
      }];
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
      [self runNoteFormatSelfTest];
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
        {  // Visual parity V49: Arc's site control center (round actions, sectioned rows, clean-up footer)
          NSString* sc = w.siteControlsStyle;
          BOOL look = [sc hasPrefix:@"actions=5 "] && ([sc containsString:@" sections=2 "] || [sc containsString:@" sections=3 "]) &&
                      [[sc componentsSeparatedByString:@"rows="][1] intValue] >= 7 && ![sc containsString:@" footer=0"];
          std::printf("SELFTEST-SITECONTROLS arcStyle=%d\n", look);
          if (!look) std::printf("SELFTEST-SITECONTROLS-DEBUG %s\n", sc.UTF8String);
          // Omar, Nov 11 (V72): it hangs from the pill's site button, lists this profile's extensions with a pin
          // button each (and Add Extension), and the footer's ... menu holds Arc's clean-up and manage actions.
          BOOL anchored = [sc containsString:@" anchor=site"] || w.sidebarHidden;
          NSRange er = [sc rangeOfString:@" extensions="], pr = [sc rangeOfString:@" pins="];
          int exts = er.location == NSNotFound ? 0 : [[sc substringFromIndex:NSMaxRange(er)] intValue];
          int pins = pr.location == NSNotFound ? -1 : [[sc substringFromIndex:NSMaxRange(pr)] intValue];
          BOOL extRows = exts >= 1 && pins == exts && [sc containsString:@" addExtension=1"];
          BOOL footerMenu = [sc containsString:@" footerMenu=Clear Cache|Clear Cookies|Manage Extensions|Add Extension|"];
          std::printf("SELFTEST-SITECONTROLCENTER anchored=%d extensions=%d footerMenu=%d\n", anchored, extRows, footerMenu);
          if (!anchored || !extRows || !footerMenu) std::printf("SELFTEST-SITECONTROLCENTER-DEBUG %s\n", sc.UTF8String);
        }
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
        {  // Visual parity V42: each new download flew into the Library button and opened the tray of cards
          NSString* tray = [self.window downloadsTrayState];
          NSArray* parts = [tray componentsSeparatedByString:@" "];
          BOOL flew = [[parts.lastObject substringFromIndex:8] integerValue] >= 2;
          BOOL cards = [[parts[1] substringFromIndex:6] integerValue] >= 1;
          [self.window closeDownloadsTrayForTest];
          std::printf("SELFTEST-DOWNLOADLOOK flew=%d cards=%d\n", flew, cards);
          if (!flew || !cards) std::printf("SELFTEST-DOWNLOADLOOK-DEBUG %s\n", tray.UTF8String);
        }
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
          NSString* dest = [NSTemporaryDirectory() stringByAppendingPathComponent:@"selftest-arc-extensions"];  // not the loaded folder
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
          // Omar, Nov 11 (V70): Arc's pinned extensions come along, and copying any turns Chrome-style pages on.
          [@"{\"extensions\":{\"pinned_extensions\":[\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"]}}"
              writeToFile:[NSString stringWithFormat:@"%@/%@/Preferences", fake, prof] atomically:YES encoding:NSUTF8StringEncoding error:nil];
          BOOL pinsRead = [ArcPinnedExtensionIDs(fake, @[ prof ]) isEqual:@[ @"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ]];
          BOOL pagesBefore = SettingBool(kSettingChromePages);
          id pinsBefore = SettingObject(kSettingPinnedExtensions);
          SettingSetBool(kSettingChromePages, NO);
          SettingSetObject(kSettingPinnedExtensions, nil);
          [w clearHistory:nil];
          NSDictionary* all = [w importEverythingFromArcInto:dest userData:fake];
          BOOL pagesOn = SettingBool(kSettingChromePages);
          BOOL pinsKept = [SettingObject(kSettingPinnedExtensions) containsObject:@"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"];
          SettingSetBool(kSettingChromePages, pagesBefore);
          SettingSetObject(kSettingPinnedExtensions, pinsBefore);
          std::printf("SELFTEST-IMPORTALL history=%d extensions=%d skipped=%d pagesOn=%d pinsRead=%d pinsKept=%d\n",
                      [all[@"history"] intValue] == 2, [all[@"extensions"] intValue] == 1, [all[@"skipped"] intValue] == 1,
                      pagesOn, pinsRead, pinsKept);
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
      {  // Visual parity V47: an icon on every row, submenus too
        __block NSMutableArray* bare = [NSMutableArray array];
        __block void (^scan)(NSMenu*);
        void (^s)(NSMenu*) = ^(NSMenu* mm) {
          for (NSMenuItem* mi in mm.itemArray) {
            if (mi.isSeparatorItem) continue;
            if (!mi.image) [bare addObject:mi.title];
            if (mi.submenu) scan(mi.submenu);
          }
        };
        scan = s;
        scan([w sidebarMenuForItem:b]);
        scan = nil;
        std::printf("SELFTEST-MENULOOK icons=%d\n", bare.count == 0);
        if (bare.count) std::printf("SELFTEST-MENULOOK-DEBUG %s\n", [bare componentsJoinedByString:@","].UTF8String);
      }
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
    // Settings window panes (#72), app icon choice (#74) and per-site Developer Mode (#68). Settings are memory-only in
    // test runs; everything changed here is put back before the block ends. Never opens DevTools or shows a window.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 27 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      MainWindowController* w = self.window;
      // App icon at launch (#74): the default NotArc icon is already in place before anything below changes it.
      CGFloat launchDiff = AppIconDifference(NSApp.applicationIconImage, AppIconImage(kAppIconBundle));
      SettingsWindowController* sw = [SettingsWindowController shared];
      NSDictionary* savedSettings = SettingsMemorySnapshotForTest();
      __block NSButton* (^findButton)(NSView*, NSString*) = nil;
      NSButton* (^find)(NSView*, NSString*) = ^NSButton*(NSView* v, NSString* title) {
        if ([v isKindOfClass:NSButton.class] && [((NSButton*)v).title isEqualToString:title]) return (NSButton*)v;
        for (NSView* c in v.subviews)
          if (NSButton* b = findButton(c, title)) return b;
        return nil;
      };
      findButton = find;
      if (const char* dir = getenv("NOTARC_SETTINGS_SNAPSHOT_DIR")) {  // design checks only, never in normal runs
        NSString* folder = [NSString stringWithUTF8String:dir];
        [sw writePaneSnapshotsTo:folder];
        NSArray* names = AppIconNames();
        NSImage* strip = [NSImage imageWithSize:NSMakeSize(140 * names.count, 140) flipped:NO drawingHandler:^BOOL(NSRect r) {
          for (NSUInteger i = 0; i < names.count; ++i)
            [AppIconImage(names[i]) drawInRect:NSMakeRect(140 * i + 6, 6, 128, 128)];
          return YES;
        }];
        NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:[strip CGImageForProposedRect:nil context:nil hints:nil]];
        [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}]
            writeToFile:[folder stringByAppendingPathComponent:@"icons.png"] atomically:YES];
      }
      {  // #72: Arc's panes, everything that was in Settings is still there, Profiles / Appearance / Advanced work.
        BOOL panes = [sw.paneIdentifiers isEqualToArray:@[ @"general", @"profiles", @"max", @"links", @"shortcuts", @"icon", @"advanced" ]] &&
                     [sw checkboxForSetting:kSettingMaxEnabled] != nil;
        [sw selectPane:@"advanced"];
        BOOL select = [sw.selectedPane isEqualToString:@"advanced"];
        [sw selectPane:@"general"];
        BOOL kept = [find([sw viewOfPane:@"links"], @"Air Traffic Control...") action] == @selector(showAirTrafficControl:);
        kept = kept && [find([sw viewOfPane:@"profiles"], @"Import Everything from Arc...") action] ==
                           @selector(importEverythingFromArcMenu:);
        for (NSString* k in @[ kSettingSearchSuggestions, kSettingBlockAds, kSettingAutoPiP, kSettingSoundEffects,
                               kSettingReorderHaptics, kSettingPeekPinnedLinks, kSettingPeekShiftClick ])
          kept = kept && [sw checkboxForSetting:k] != nil;
        NSArray* rows = sw.profileRows;
        ArcSpace* sp = w.currentSpace;
        NSString* mine = [NSString stringWithFormat:@"%@: ", [w nameOfProfile:sp.profileDirectory]];
        BOOL listed = rows.count == w.profileDirectories.count && rows.count > 0;
        BOOL spaceShown = NO;
        for (NSString* r in rows)
          if ([r hasPrefix:mine] && [r containsString:sp.title.length ? sp.title : @"Space"]) spaceShown = YES;
        NSString* dir = [sw createProfileNamed:@"SelfTest Settings Profile"];
        BOOL created = dir && [w.profileDirectories containsObject:dir] &&
                       [sw.profileRows containsObject:@"SelfTest Settings Profile: No Spaces"];
        BOOL renamed = [sw renameProfileAtRow:[w.profileDirectories indexOfObject:dir] to:@"SelfTest Settings Renamed"] &&
                       [[w nameOfProfile:dir] isEqualToString:@"SelfTest Settings Renamed"] &&
                       [sw.profileRows containsObject:@"SelfTest Settings Renamed: No Spaces"];
        // Appearance: the default applies to Spaces without their own choice; a Space's own choice wins.
        NSString* own = sp.colorScheme;
        [w setColorScheme:nil forSpace:sp];
        [sw chooseSpaceAppearance:@"dark"];
        [w.window displayIfNeeded];
        BOOL darkDefault = w.sidebarIsDark && [DefaultSpaceAppearance() isEqualToString:@"dark"];
        [sw chooseSpaceAppearance:@"light"];
        [w.window displayIfNeeded];
        BOOL lightDefault = !w.sidebarIsDark;
        [w setColorScheme:@"dark" forSpace:sp];
        [w.window displayIfNeeded];
        BOOL spaceWins = w.sidebarIsDark;
        [sw chooseSpaceAppearance:@"auto"];
        [w setColorScheme:own forSpace:sp];
        BOOL autoBack = [DefaultSpaceAppearance() isEqualToString:@"auto"] && (own || w.window.appearance == nil);
        // Advanced: Chrome-style pages and Developer Mode switches, Clear Browsing Data and Reset buttons.
        NSView* adv = [sw viewOfPane:@"advanced"];
        BOOL advanced = [sw checkboxForSetting:kSettingChromePages] &&
                        [[sw checkboxForSetting:kSettingChromePages] boolValue] == SettingBool(kSettingChromePages) &&
                        [[sw checkboxForSetting:kSettingDeveloperModeLocal] boolValue] &&
                        find(adv, @"Clear Browsing Data...").action == @selector(clearBrowsingData:) &&
                        find(adv, @"Reset Developer Mode Sites").action == @selector(resetDeveloperModeSites:) &&
                        find(adv, @"Reset All Settings...").action == @selector(resetAllSettings:);
        SettingSetBool(kSettingSoundEffects, NO);
        [sw chooseAppIcon:@"forest"];
        [sw chooseSpaceAppearance:@"dark"];
        SetDeveloperMode(YES, @"reset.example");
        ResetAllSettings();
        BOOL reset = SettingBool(kSettingSoundEffects) && [CurrentAppIconName() isEqualToString:kAppIconBundle] &&
                     [DefaultSpaceAppearance() isEqualToString:@"auto"] && !DeveloperModeOnForHost(@"reset.example") &&
                     SettingDouble(kSettingAutoArchiveHours) == 12;
        SettingsMemoryRestoreForTest(savedSettings);
        ApplyContentBlockerSettings();
        ApplyAppIcon();
        SettingsDidChange();
        [sw selectPane:@"general"];
        {  // Visual parity V58: grouped cards, switches, Arc's flat buttons, the Icon pane's radio list.
          NSString* gen = [sw paneLook:@"general"], *adv2 = [sw paneLook:@"advanced"], *icon = [sw paneLook:@"icon"];
          NSString* links = [sw paneLook:@"links"], *keys = [sw paneLook:@"shortcuts"];
          auto num = ^int(NSString* look, NSString* k) {
            for (NSString* part in [look componentsSeparatedByString:@" "])
              if ([part hasPrefix:[k stringByAppendingString:@"="]]) return [[part substringFromIndex:k.length + 1] intValue];
            return -1;
          };
          BOOL cards = num(gen, @"cards") >= 6 && num(adv2, @"cards") >= 3 && num(links, @"cards") >= 3;
          BOOL switches = num(gen, @"switches") >= 8 && num(gen, @"checkboxes") == 0 && num(links, @"checkboxes") == 0;
          BOOL buttons = num(gen, @"flatButtons") >= 2 && num(adv2, @"flatButtons") >= 3 && num(adv2, @"systemButtons") == 0;
          BOOL iconList = num(icon, @"radios") == (int)AppIconNames().count && num(icon, @"cards") == 1;
          BOOL shortcuts = num(keys, @"cards") == 1 && [sw viewOfPane:@"shortcuts"] != nil;
          [sw chooseAppIcon:AppIconNames().lastObject];
          BOOL radioFollows = [[sw appIconShownAsChosen] isEqualToString:AppIconNames().lastObject];
          [sw chooseAppIcon:kAppIconBundle];
          std::printf("SELFTEST-SETTINGSLOOK cards=%d switches=%d buttons=%d iconList=%d shortcutsPane=%d radioFollows=%d\n", cards,
                      switches, buttons, iconList, shortcuts, radioFollows);
          if (!(cards && switches && buttons && iconList && shortcuts))
            std::printf("SELFTEST-SETTINGSLOOK-DEBUG general[%s] advanced[%s] icon[%s] links[%s] shortcuts[%s]\n", gen.UTF8String,
                        adv2.UTF8String, icon.UTF8String, links.UTF8String, keys.UTF8String);
        }
        std::printf("SELFTEST-SETTINGSPANES panes=%d select=%d kept=%d listed=%d spaceShown=%d created=%d renamed=%d "
                    "darkDefault=%d lightDefault=%d spaceWins=%d autoBack=%d advanced=%d reset=%d\n", panes, select, kept,
                    listed, spaceShown, created, renamed, darkDefault, lightDefault, spaceWins, autoBack, advanced, reset);
      }
      {  // #74: 4-6 NotArc icons, picked in Appearance, applied at once and at launch, saved; the bundle isn't touched.
        NSArray* names = AppIconNames();
        BOOL distinct = names.count >= 4 && names.count <= 7;
        for (NSUInteger i = 0; i < names.count; ++i)
          for (NSUInteger j = i + 1; j < names.count; ++j)
            distinct = distinct && AppIconDifference(AppIconImage(names[i]), AppIconImage(names[j])) > 8;
        BOOL (^shows)(NSString*) = ^BOOL(NSString* n) {
          CGFloat d = AppIconDifference(NSApp.applicationIconImage, AppIconImage(n));
          for (NSString* o in names)
            if (![o isEqualToString:n] && AppIconDifference(NSApp.applicationIconImage, AppIconImage(o)) <= d) return NO;
          return d < 12;  // a bitmap copy of the same icon differs by ~6; other icons by 20+
        };
        BOOL atLaunch = launchDiff < 12 && shows(kAppIconBundle);
        // The default is the bundle's own icon (Icon A), first in the picker, with every size from 16 to 1024 px.
        NSMutableSet* sizes = [NSMutableSet set];
        for (NSImageRep* r in AppIconImage(kAppIconBundle).representations) [sizes addObject:@(r.pixelsWide)];
        BOOL bundleIcon = [names.firstObject isEqualToString:kAppIconBundle] &&
                          [[NSSet setWithArray:@[ @16, @32, @64, @128, @256, @512, @1024 ]] isSubsetOfSet:sizes] &&
                          [[NSUserDefaults.standardUserDefaults volatileDomainForName:NSRegistrationDomain][kSettingAppIcon]
                              isEqual:kAppIconBundle];
        NSString* plist = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents/Info.plist"];
        NSDate* plistDate = [[NSFileManager.defaultManager attributesOfItemAtPath:plist error:nil] fileModificationDate];
        [sw chooseAppIcon:@"sunset"];
        BOOL applied = shows(@"sunset");
        BOOL saved = [SettingObject(kSettingAppIcon) isEqual:@"sunset"] && [sw.appIconShownAsChosen isEqualToString:@"sunset"];
        [sw chooseAppIcon:@"no-such-icon"];
        BOOL unknownIgnored = [CurrentAppIconName() isEqualToString:@"sunset"];
        SettingSetObject(kSettingAppIcon, @"midnight");  // as if saved last time: launch applies it
        ApplyAppIcon();
        BOOL relaunch = shows(@"midnight");
        [sw chooseAppIcon:kAppIconBundle];
        BOOL restored = shows(kAppIconBundle) && [sw.appIconShownAsChosen isEqualToString:kAppIconBundle];
        BOOL bundle = [[[NSFileManager.defaultManager attributesOfItemAtPath:plist error:nil] fileModificationDate]
                          isEqualToDate:plistDate];
        std::printf("SELFTEST-APPICON variants=%d distinct=%d atLaunch=%d applied=%d saved=%d unknownIgnored=%d "
                    "relaunch=%d restored=%d bundleUntouched=%d bundleIcon=%d\n", names.count >= 4, distinct, atLaunch, applied,
                    saved, unknownIgnored, relaunch, restored, bundle, bundleIcon);
      }
      {  // #68 pure rules: local sites on by default; the pill shows host:port/path in Developer Mode.
        BOOL local = DeveloperModeOnForURL(@"http://localhost:3000/") && DeveloperModeOnForURL(@"http://127.0.0.1:8080/x") &&
                     DeveloperModeOnForURL(@"http://myapp.local/") && DeveloperModeOnForURL(@"http://api.localhost:5173/") &&
                     DeveloperModeOnForURL(@"http://[::1]:4000/") && !DeveloperModeOnForURL(@"https://example.com/") &&
                     !DeveloperModeOnForURL(@"http://127.0.0.1.example.com/") && !DeveloperModeOnForURL(@"file:///tmp/x.html") &&
                     !DeveloperModeOnForURL(@"http://localhost.example.com/");
        BOOL pillText = [SidebarAddressTextForURL(@"http://localhost:3000/app?x=1") isEqualToString:@"localhost:3000/app?x=1"] &&
                        [SidebarAddressTextForURL(@"https://www.example.com/a") isEqualToString:@"example.com"];
        SetDeveloperMode(NO, @"localhost");
        BOOL localOff = !DeveloperModeOnForURL(@"http://localhost:3000/") && DeveloperModeOnForURL(@"http://127.0.0.1:3000/");
        ResetDeveloperModeHosts();
        SettingSetBool(kSettingDeveloperModeLocal, NO);
        BOOL autoOff = !DeveloperModeOnForURL(@"http://localhost:3000/");
        SettingSetBool(kSettingDeveloperModeLocal, YES);
        BOOL localBack = DeveloperModeOnForURL(@"http://localhost:3000/");
        __block NSMenuItem* (^findItem)(NSMenu*, SEL) = nil;
        NSMenuItem* (^findMenu)(NSMenu*, SEL) = ^NSMenuItem*(NSMenu* menu, SEL a) {
          for (NSMenuItem* i in menu.itemArray) {
            if (i.action == a) return i;
            if (NSMenuItem* f = i.submenu ? findItem(i.submenu, a) : nil) return f;
          }
          return nil;
        };
        findItem = findMenu;
        BOOL menus = findMenu(NSApp.mainMenu, @selector(toggleDeveloperMode:)) && findMenu(NSApp.mainMenu, @selector(resetDeveloperModeSites:));
        // A real tab: turned on from the menu command, then reset.
        [w openInNewTab:@"https://example.org/devmode?x=1"];
        ArcItem* t = w.shownItem;
        WaitUntil(^{ if (w.shownItem != t) [w showItem:t]; return (BOOL)([[w currentURL] hasPrefix:@"https://example.org/devmode"] && ![w isLoading]); }, 20, ^{
          [w showItem:t];
          BOOL offBefore = ![w devToolsButtonShown] && ![w itemKeptFromAutoArchive:t] && [w.sidebarAddressText isEqualToString:@"example.org"];
          NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:@"" action:@selector(toggleDeveloperMode:) keyEquivalent:@""];
          BOOL menuOn = [(id<NSMenuItemValidation>)w validateMenuItem:mi] && [mi.title isEqualToString:@"Turn On Developer Mode for This Site"];
          [w toggleDeveloperMode:mi];
          BOOL toggled = DeveloperModeOnForHost(@"example.org") && [DeveloperModeChosenHosts() isEqualToArray:@[ @"example.org" ]];
          BOOL fullURL = [w.sidebarAddressText isEqualToString:@"example.org/devmode?x=1"];
          BOOL devTools = [w devToolsButtonShown];
          BOOL kept = [w itemKeptFromAutoArchive:t];
          BOOL menuOff = [(id<NSMenuItemValidation>)w validateMenuItem:mi] && [mi.title isEqualToString:@"Turn Off Developer Mode for This Site"];
          BOOL listed = [sw.developerModeSitesText containsString:@"example.org"];
          [sw resetDeveloperModeSites:nil];
          BOOL reset = !DeveloperModeOnForHost(@"example.org") && DeveloperModeChosenHosts().count == 0 &&
                       DeveloperModeOnForURL(@"http://localhost:3000/") && ![w devToolsButtonShown] &&
                       [w.sidebarAddressText isEqualToString:@"example.org"] && ![w itemKeptFromAutoArchive:t];
          std::printf("SELFTEST-DEVMODE local=%d pillText=%d localOff=%d autoOff=%d localBack=%d menus=%d offBefore=%d "
                      "menuOn=%d toggled=%d fullURL=%d devTools=%d kept=%d menuOff=%d listed=%d reset=%d\n", local,
                      pillText, localOff, autoOff, localBack, menus, offBefore, menuOn, toggled, fullURL, devTools, kept,
                      menuOff, listed, reset);
          if (!(fullURL && offBefore))
            std::printf("SELFTEST-DEVMODE-DEBUG url=%s pill=%s\n", [w currentURL].UTF8String ?: "-", w.sidebarAddressText.UTF8String ?: "-");
          if (w.shownItem == t) [w closeTab:nil];
        });
      }
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
      // Idle archiving skips the window in use. If NotArc happens to be the active app, the Little Window just
      // opened is key, so hand focus back to the main window first (as when the user goes back to it).
      NSWindow* keyBefore = NSApp.keyWindow;
      if (keyBefore && keyBefore != w.window) [w.window makeKeyWindow];
      NSUInteger idleClosed = [w archiveIdleLittleWindowsAt:[NSDate date]];
      if (!idleClosed)
        std::printf("SELFTEST-SETTINGS-DEBUG little=%lu keyWasOther=%d keyNow=%s\n", (unsigned long)before,
                    keyBefore && keyBefore != w.window, NSApp.keyWindow == w.window ? "main" : NSApp.keyWindow ? "other" : "none");
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
      {  // Visual parity V19: Arc's split row, one icon + title per pane with slashes, other panes dimmed.
        NSString* sr = group ? [w splitRowStateForItem:group] : @"";
        BOOL splitRow = [sr isEqual:@"segments=3 slashes=2 dim=2 single=1"];
        std::printf("SELFTEST-SPLITROW arcStyle=%d\n", splitRow);
        if (!splitRow) std::printf("SELFTEST-SPLITROW-DEBUG %s\n", sr.UTF8String);
      }
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
      {  // Visual parity V4: Archive opens inside the sidebar (no window), grouped by day, with search; Back closes it.
        ArcItem* shownBefore = w.shownItem;
        [w showArchive:nil];
        BOOL inSidebar = w.libraryInSidebar;
        NSString* style = w.libraryStyle;
        BOOL look = [style containsString:@"search=32 radius=8 row=41"] && [style hasSuffix:@"placeholder=Search Archive"];
        NSArray* groups = w.libraryGroupTitles;
        NSCalendar* cal = NSCalendar.currentCalendar;
        NSDate* now = [NSDate date];
        BOOL grouping = [ArchiveGroupTitle(now, now, cal) isEqualToString:@"Today"] &&
                        [ArchiveGroupTitle([now dateByAddingTimeInterval:-86400 * 1.0], now, cal) isEqualToString:@"Yesterday"] &&
                        [ArchiveGroupTitle([now dateByAddingTimeInterval:-86400 * 10.0], now, cal) isEqualToString:@"Last Week"] &&
                        ArchiveGroupTitle([now dateByAddingTimeInterval:-86400 * 400.0], now, cal).length > 5 &&
                        (groups.count == 0 || [groups.firstObject length] > 0);
        [w hideLibrary];
        BOOL closed = !w.libraryShown && w.shownItem == shownBefore;
        [w showArchive:nil];
        ArcSpace* home = w.currentSpace;
        [w switchToSpace:w.spaces.lastObject == home ? w.spaces.firstObject : w.spaces.lastObject];
        BOOL closedBySpace = !w.libraryShown;
        [w switchToSpace:home];
        std::printf("SELFTEST-ARCHIVEPANEL inSidebar=%d look=%d grouping=%d closed=%d closedBySpace=%d\n", inSidebar, look, grouping,
                    closed, closedBySpace);
        {  // Visual parity V41: the Library button opens Arc's Library list; a section opens in place; Back returns
          NSString* homeList = w.libraryHomeForTest;
          BOOL list = [homeList hasPrefix:@"#Spaces,space"] &&
                      [homeList hasSuffix:@"#Library,Archive,Downloads,Media,Easels,Notes,Boosts"];
          NSUInteger spaces = w.spaces.count;
          [w openLibraryRowForTest:spaces + 1];  // Downloads
          BOOL opened = [w.librarySectionForTest isEqual:@"downloads"] && w.libraryInSidebar;
          [w.libraryPanelForTest performSelector:@selector(backClicked:) withObject:nil];
          BOOL back = [w.librarySectionForTest isEqual:@"home"] && w.libraryShown;
          [w showLibrary:nil];  // the button again closes it
          BOOL toggled = !w.libraryShown;
          std::printf("SELFTEST-LIBRARYHOME list=%d section=%d back=%d toggles=%d\n", list, opened, back, toggled);
          if (!list) std::printf("SELFTEST-LIBRARYHOME-DEBUG %s\n", homeList.UTF8String);
        }
        if (!look) std::printf("SELFTEST-ARCHIVEPANEL-DEBUG %s\n", style.UTF8String);
      }
      [w saveSidebarNow];
    });
  }
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app { return YES; }

// Links clicked in other apps (when NotArc is the default browser) open in a Little Window.
- (IBAction)showDownloads:(id)sender { [[DownloadManager shared] showWindow]; }

- (IBAction)checkForUpdates:(id)sender { [[Updater shared] checkInteractive:YES]; }

- (IBAction)showAirTrafficControl:(id)sender { [self.window showAirTrafficControl:sender]; }
// Settings > Profiles has the button; the Settings window isn't the browser's, so it lands here.
- (IBAction)importEverythingFromArcMenu:(id)sender { [self.window importEverythingFromArcMenu:sender]; }

- (IBAction)showKeyboardShortcuts:(id)sender {  // Arc keeps them in Settings > Shortcuts
  [[SettingsWindowController shared] showWindow:nil];
  [[SettingsWindowController shared] selectPane:@"shortcuts"];
  [[SettingsWindowController shared].window makeKeyAndOrderFront:nil];
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
  // Self-test logs go to a file: line-buffer them, so a crash doesn't swallow the checks printed just before it.
  for (int i = 1; i < argc; ++i)
    if (std::string(argv[i]) == "--selftest") setvbuf(stdout, NULL, _IOLBF, 0);
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
        std::string(argv[i]).rfind("--sidebar-snapshot=", 0) == 0 || std::string(argv[i]).rfind("--visual-shots=", 0) == 0) {
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
    NSString* extDir = NotArcExtensionsDirectory(testRun);
    NSSet* disabled = [NSSet setWithArray:testRun ? @[] : ([NSUserDefaults.standardUserDefaults arrayForKey:kDisabledExtensionsKey] ?: @[])];
    // Test runs always load the fixture extension (through the real CRX install path): its popup bubble is a
    // Chrome-style page of its own, so it's checked with either setting.
    if (testRun) InstallSelfTestExtension(extDir);
    NSArray<NSString*>* paths = ChromePagesEnabled() || testRun ? ExtensionLoadPaths(extDir, disabled) : @[];
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
    NSString* visualPlan = nil;
    if (VisualShotsRequested(argc, argv, &visualPlan)) selfTest = YES;  // same isolation as the self-test
    NSString* snapshotPath = nil;
    for (int i = 1; i < argc; ++i)
      if (std::string(argv[i]).rfind("--sidebar-snapshot=", 0) == 0) {
        selfTest = YES;  // same isolation as the self-test: test profiles, mock Keychain, hidden window
        snapshotPath = [NSString stringWithUTF8String:argv[i] + strlen("--sidebar-snapshot=")];
      }

    if (selfTest) {
      // Test runs never touch the user's real profile: they need a throwaway home (CFFIXED_USER_HOME, see
      // scripts/make-test-home.py), and their preference writes stay in memory (app/test_isolation.h).
      if (!TestIsolationHomeIsolated()) {
        std::printf("SELFTEST-REALPROFILE isolatedHome=0 refused=1\n");
        std::fprintf(stderr, "NotArc test runs need a throwaway home so they never touch your real profile:\n"
                             "  scripts/make-test-home.py /tmp/notarc-home\n"
                             "  CFFIXED_USER_HOME=/tmp/notarc-home %s %s\n", argv[0], argc > 1 ? argv[1] : "");
        std::fflush(stdout);
        return 3;
      }
      TestIsolationInstall();
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
    // Live easel clips (#49) refresh in a hidden off-screen browser; tabs stay windowed.
    settings.windowless_rendering_enabled = true;

    if (!CefInitialize(main_args, settings, nullptr, nullptr)) return CefGetExitCode();
    SettingsRegisterDefaults();
    if (selfTest) SettingsUseMemoryOnly();
    PasswordStoreConfigure(selfTest);  // tests: throwaway in-memory key, never the Keychain
    ApplyContentBlockerSettings();

    AppDelegate* delegate = [AppDelegate new];
    delegate.selfTest = selfTest;
    delegate.selfTestReload = selfTestReload;
    delegate.snapshotPath = snapshotPath;
    delegate.visualPlan = visualPlan;
    NSApp.delegate = delegate;
    [delegate performSelectorOnMainThread:@selector(start) withObject:nil waitUntilDone:NO];

    CefRunMessageLoop();
    SessionMarkerEnd(selfTest);  // reached only on a clean quit; a crash or force-quit leaves the marker
    CefShutdown();
  }
  return 0;
}
