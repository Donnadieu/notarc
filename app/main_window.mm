#import "app/main_window.h"
#import "app/sidebar_store.h"
#import "app/archive_store.h"
#import "app/archive_window.h"
#import "app/arc_cookies.h"
#import "app/little_window.h"

#include <cstdio>
#include <atomic>
#include <functional>
#include <map>
#include <set>
#include <string>

#include "app/browser_client.h"
#include "include/cef_browser.h"
#include "include/cef_app.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_cookie.h"

static NSPasteboardType const kSidebarItemPasteboardType = @"io.github.donnadieu.notarc.sidebar-item";

namespace {
constexpr CGFloat kSidebarWidth = 260;

// Chrome-style request contexts initialise asynchronously; browsers created before that fail.
class SpaceContextHandler : public CefRequestContextHandler {
 public:
  explicit SpaceContextHandler(std::function<void()> on_ready) : on_ready_(std::move(on_ready)) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    if (on_ready_) on_ready_();
  }

 private:
  std::function<void()> on_ready_;
  IMPLEMENT_REFCOUNTING(SpaceContextHandler);
};
// Counts down outstanding SetCookie calls and runs `done` on the UI thread after the last one.
class CookieImportCallback : public CefSetCookieCallback {
 public:
  CookieImportCallback(int pending, std::function<void(int ok)> done) : pending_(pending), done_(std::move(done)) {}
  void OnComplete(bool success) override {
    if (success) ok_.fetch_add(1);
    if (pending_.fetch_sub(1) == 1 && done_) done_(ok_.load());
  }

 private:
  std::atomic<int> pending_;
  std::atomic<int> ok_{0};
  std::function<void(int)> done_;
  IMPLEMENT_REFCOUNTING(CookieImportCallback);
};

cef_cookie_same_site_t SameSiteFromChromiumDB(int v) {
  switch (v) {
    case 0: return CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
    case 1: return CEF_COOKIE_SAME_SITE_LAX_MODE;
    case 2: return CEF_COOKIE_SAME_SITE_STRICT_MODE;
    default: return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
  }
}
}  // namespace

NSString* ResolveCommandBarInput(NSString* input) {
  NSString* text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length) return nil;
  BOOL hasScheme = [text rangeOfString:@"://"].location != NSNotFound || [text hasPrefix:@"about:"];
  BOOL looksLikeHost = [text rangeOfString:@" "].location == NSNotFound &&
                       ([text containsString:@"."] || [text hasPrefix:@"localhost"]);
  if (hasScheme) return text;
  if (looksLikeHost) return [@"https://" stringByAppendingString:text];
  NSString* q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  q = [q stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
  q = [q stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
  return [@"https://www.google.com/search?q=" stringByAppendingString:q];
}

static BOOL Contains(ArcItem* root, ArcItem* target);

@interface MainWindowController () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate>
@end

@implementation MainWindowController {
  NSArray<ArcSpace*>* _spaces;
  ArcSpace* _space;  // currently shown Space
  NSPopUpButton* _spacePicker;
  NSOutlineView* _outline;
  NSView* _content;
  CefRefPtr<BrowserClient> _client;
  std::map<int, CefRefPtr<CefBrowser>> _browsers;
  std::map<std::string, CefRefPtr<CefRequestContext>> _contexts;  // profile dir -> context
  std::set<std::string> _readyContexts;
  NSMutableDictionary<NSString*, NSMutableArray<ArcItem*>*>* _pendingTabs;  // waiting for their context
  ArcItem* _shown;
  BOOL _closing;
  NSPanel* _commandBar;
  NSTextField* _commandField;
  BOOL _commandOpensNewTab;
  BOOL _saveScheduled;
  NSMutableArray<ArchivedTab*>* _archive;
  NSTimer* _archiveTimer;
  ArchiveWindowController* _archiveWindow;
  NSPanel* _findBar;
  NSSearchField* _findField;
  NSTextField* _findLabel;
  int _lastFindCount;
  NSMutableArray<ArcItem*>* _splitItems;  // panes of the active split, in order; nil when no split
  BOOL _splitHorizontal;
  BOOL _commandOpensSplit;
  BOOL _commandOpensLittle;
  NSMutableArray<LittleWindowController*>* _littleWindows;
}

- (instancetype)initWithSpaces:(NSArray<ArcSpace*>*)spaces focusedSpaceID:(NSString*)focusedID {
  NSWindow* window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1280, 820)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.title = @"NotArc";
  [window center];
  if ((self = [super initWithWindow:window])) {
    window.delegate = self;
    _spaces = spaces;
    _space = spaces.firstObject;
    for (ArcSpace* s in spaces)
      if ([s.spaceID isEqualToString:focusedID]) _space = s;
    [self buildLayout];
  }
  return self;
}

- (void)buildLayout {
  NSView* root = self.window.contentView;
  NSRect bounds = root.bounds;

  NSVisualEffectView* sidebar = [[NSVisualEffectView alloc]
      initWithFrame:NSMakeRect(0, 0, kSidebarWidth, bounds.size.height)];
  sidebar.material = NSVisualEffectMaterialSidebar;
  sidebar.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  sidebar.autoresizingMask = NSViewHeightSizable;
  [root addSubview:sidebar];

  _spacePicker = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(8, bounds.size.height - 72, kSidebarWidth - 16, 26) pullsDown:NO];
  _spacePicker.autoresizingMask = NSViewMinYMargin;
  for (ArcSpace* s in _spaces) [_spacePicker addItemWithTitle:s.title];
  if (_space) [_spacePicker selectItemAtIndex:[_spaces indexOfObject:_space]];
  _spacePicker.target = self;
  _spacePicker.action = @selector(spaceChanged:);
  [sidebar addSubview:_spacePicker];

  NSScrollView* scroll = [[NSScrollView alloc]
      initWithFrame:NSMakeRect(4, 8, kSidebarWidth - 8, bounds.size.height - 84)];
  scroll.autoresizingMask = NSViewHeightSizable;
  scroll.drawsBackground = NO;
  scroll.hasVerticalScroller = YES;

  _outline = [[NSOutlineView alloc] initWithFrame:scroll.bounds];
  NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"item"];
  col.width = kSidebarWidth - 24;
  [_outline addTableColumn:col];
  _outline.outlineTableColumn = col;
  _outline.headerView = nil;
  _outline.backgroundColor = NSColor.clearColor;
  _outline.rowHeight = 28;
  _outline.style = NSTableViewStyleSourceList;
  _outline.floatsGroupRows = NO;
  _outline.dataSource = self;
  _outline.delegate = self;
  [_outline registerForDraggedTypes:@[ kSidebarItemPasteboardType ]];
  [_outline setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
  scroll.documentView = _outline;
  [sidebar addSubview:scroll];

  _content = [[NSView alloc] initWithFrame:NSMakeRect(kSidebarWidth, 0,
                                                      bounds.size.width - kSidebarWidth,
                                                      bounds.size.height)];
  _content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _content.wantsLayer = YES;
  [root addSubview:_content];

  [self reloadSidebar];
}

- (void)reloadSidebar {
  [_outline reloadData];
  if (!_space) return;
  if (_space.favorites) [_outline expandItem:_space.favorites];
  [_outline expandItem:_space.pinned];
  [_outline expandItem:_space.unpinned];
}

- (void)spaceChanged:(id)sender {
  NSInteger i = _spacePicker.indexOfSelectedItem;
  if (i < 0 || i >= (NSInteger)_spaces.count) return;
  _space = _spaces[i];
  [self reloadSidebar];
  [self scheduleSave];
  ArcItem* first = _space.allTabs.firstObject;
  if (first) [self showItem:first];
}

// One isolated browser profile per Arc Space (cookies, storage), keyed by Arc's profile name.
- (CefRefPtr<CefRequestContext>)contextForSpace:(ArcSpace*)space {
  std::string key = space.profileDirectory.UTF8String;
  auto it = _contexts.find(key);
  if (it != _contexts.end()) return it->second;
  NSString* support =
      [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:@"NotArc"];
  // Chrome-style CEF only accepts profile dirs that are direct children of root_cache_path.
  NSString* name = [@"Space " stringByAppendingString:space.profileDirectory];
  NSString* path = [support stringByAppendingPathComponent:name];
  [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
  CefRequestContextSettings settings;
  CefString(&settings.cache_path) = path.UTF8String;
  __weak MainWindowController* weakSelf = self;
  NSString* profile = space.profileDirectory;
  CefRefPtr<CefRequestContext> ctx = CefRequestContext::CreateContext(
      settings, new SpaceContextHandler([weakSelf, profile]() { [weakSelf contextReady:profile]; }));
  _contexts[key] = ctx;
  return ctx;
}

// First time a Space's profile starts: copy that Arc profile's logins (cookies) in, then open tabs.
// A marker file in the profile makes this one-time, so later Arc changes never overwrite ours.
- (void)contextReady:(NSString*)profile {
  CefRefPtr<CefRequestContext> ctx = _contexts[profile.UTF8String];
  NSString* marker = [[NSString stringWithUTF8String:ctx->GetCachePath().ToString().c_str()]
      stringByAppendingPathComponent:@"ArcCookiesImported"];
  if (![[NSFileManager defaultManager] fileExistsAtPath:marker]) {
    __weak MainWindowController* weakSelf = self;
    [self importArcCookiesForProfile:profile context:ctx done:^(NSUInteger read, int ok) {
      std::fprintf(stderr, "imported %d/%lu Arc cookies into %s\n", ok, (unsigned long)read, profile.UTF8String);
      if (read > 0)
        [[NSString stringWithFormat:@"%d of %lu\n", ok, (unsigned long)read] writeToFile:marker atomically:YES
                                                                                  encoding:NSUTF8StringEncoding error:nil];
      [weakSelf openPendingTabsForProfile:profile];
    }];
    return;
  }
  [self openPendingTabsForProfile:profile];
}

- (void)importArcCookiesForProfile:(NSString*)profile
                           context:(CefRefPtr<CefRequestContext>)ctx
                              done:(void (^)(NSUInteger read, int ok))done {
  // The Keychain read can block for many seconds (securityd / access prompt). Do it and the
  // SQLite decrypt on a background queue; only the CEF calls happen back on the main thread.
  static dispatch_queue_t queue = dispatch_queue_create("notarc.cookie-import", DISPATCH_QUEUE_SERIAL);
  static NSString* cachedPassword = nil;
  __weak MainWindowController* weakSelf = self;
  dispatch_async(queue, ^{
    NSError* error = nil;
    if (!cachedPassword) cachedPassword = ArcSafeStoragePassword(&error);
    NSArray<ArcCookie*>* cookies =
        cachedPassword ? ArcReadCookies(ArcCookieDBPath(profile), ArcCookieKey(cachedPassword), nullptr, &error) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf setArcCookies:cookies error:error forProfile:profile context:ctx done:done];
    });
  });
}

- (void)setArcCookies:(NSArray<ArcCookie*>*)cookies
                error:(NSError*)error
           forProfile:(NSString*)profile
              context:(CefRefPtr<CefRequestContext>)ctx
                 done:(void (^)(NSUInteger read, int ok))done {
  CefRefPtr<CefCookieManager> manager = ctx->GetCookieManager(nullptr);
  if (!cookies.count || !manager) {
    if (error) std::fprintf(stderr, "Arc cookie import skipped for %s: %s\n", profile.UTF8String,
                            error.localizedDescription.UTF8String);
    done(0, 0);
    return;
  }
  NSUInteger count = cookies.count;
  void (^finish)(NSUInteger, int) = [done copy];
  CefRefPtr<CookieImportCallback> cb = new CookieImportCallback(static_cast<int>(count), [finish, count, manager](int ok) {
    manager->FlushStore(nullptr);
    dispatch_async(dispatch_get_main_queue(), ^{ finish(count, ok); });
  });
  for (ArcCookie* c in cookies) {
    NSString* host = [c.host hasPrefix:@"."] ? [c.host substringFromIndex:1] : c.host;
    NSString* url = [NSString stringWithFormat:@"%@://%@%@", c.secure ? @"https" : @"http", host, c.path ?: @"/"];
    CefCookie cookie;
    CefString(&cookie.name) = c.name.UTF8String;
    CefString(&cookie.value) = c.value.UTF8String;
    if ([c.host hasPrefix:@"."]) CefString(&cookie.domain) = c.host.UTF8String;  // else host-only
    CefString(&cookie.path) = (c.path ?: @"/").UTF8String;
    cookie.secure = c.secure;
    cookie.httponly = c.httpOnly;
    cookie.has_expires = c.hasExpires;
    cookie.expires.val = c.expiresUTC;
    cookie.creation.val = c.creationUTC;
    cookie.last_access.val = c.lastAccessUTC;
    cookie.same_site = SameSiteFromChromiumDB(c.sameSite);
    cookie.priority = c.priority == 0 ? CEF_COOKIE_PRIORITY_LOW
                                      : (c.priority == 2 ? CEF_COOKIE_PRIORITY_HIGH : CEF_COOKIE_PRIORITY_MEDIUM);
    if (!manager->SetCookie(url.UTF8String, cookie, cb)) cb->OnComplete(false);
  }
}

- (void)openPendingTabsForProfile:(NSString*)profile {
  _readyContexts.insert(profile.UTF8String);
  NSArray<ArcItem*>* pending = _pendingTabs[profile];
  [_pendingTabs removeObjectForKey:profile];
  for (ArcItem* item in pending) {
    [self ensureBrowserForItem:item];
    if (item == _shown) [self showItem:item];
  }
}

- (ArcSpace*)spaceOwningItem:(ArcItem*)item {
  if ([_space.allTabs containsObject:item]) return _space;
  for (ArcSpace* s in _spaces)
    if ([s.allTabs containsObject:item]) return s;
  return _space;
}

// Must run after CefInitialize, on the main (CEF UI) thread.
- (void)createBrowsers {
  __weak MainWindowController* weakSelf = self;
  _client = new BrowserClient(
      [weakSelf](int browserId, const std::string& title) {
        [weakSelf browser:browserId title:[NSString stringWithUTF8String:title.c_str()] url:nil];
      },
      [weakSelf](int browserId, const std::string& url) {
        [weakSelf browser:browserId title:nil url:[NSString stringWithUTF8String:url.c_str()]];
      });
  _client->set_focus_callback([weakSelf](int browserId) { [weakSelf paneFocused:browserId]; });
  _client->set_find_callback([weakSelf](int browserId, int count, int active) {
    [weakSelf findResult:count active:active];
  });
  ArcItem* first = _space.allTabs.firstObject;
  if (first) [self showItem:first];
  [self startAutoArchiveTimer];
}

// Web views are created lazily, the first time a tab is opened (Arc does the same).
- (void)ensureBrowserForItem:(ArcItem*)item {
  if (item.browserId || !item.url.length || !_client || !_content) return;
  ArcSpace* space = [self spaceOwningItem:item];
  CefRefPtr<CefRequestContext> context = [self contextForSpace:space];
  if (!_readyContexts.count(space.profileDirectory.UTF8String)) {
    if (!_pendingTabs) _pendingTabs = [NSMutableDictionary dictionary];
    NSMutableArray* queue = _pendingTabs[space.profileDirectory] ?: [NSMutableArray array];
    if (![queue containsObject:item]) [queue addObject:item];
    _pendingTabs[space.profileDirectory] = queue;
    return;
  }
  CefWindowInfo info;
  NSRect r = _content.bounds;
  info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(_content),
                  CefRect(0, 0, static_cast<int>(r.size.width), static_cast<int>(r.size.height)));
  CefBrowserSettings settings;
  CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
      info, _client, item.url.UTF8String, settings, nullptr, context);
  if (!browser) {
    std::fprintf(stderr, "failed to create browser for %s\n", item.url.UTF8String);
    return;
  }
  NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.frame = _content.bounds;
  item.browserId = browser->GetIdentifier();
  _browsers[item.browserId] = browser;
}

- (void)showItem:(ArcItem*)item {
  if (!item.url.length) return;
  _shown.lastActiveAt = [NSDate date];  // the tab we leave was active until now
  _shown = item;
  item.lastActiveAt = [NSDate date];
  [self ensureBrowserForItem:item];
  [self layoutPanes];
  NSInteger row = [_outline rowForItem:item];
  if (row >= 0) [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)openTabsForSelfTest:(NSUInteger)count {
  NSUInteger opened = 0;
  for (ArcSpace* s in _spaces) {
    NSArray<ArcItem*>* tabs = s.allTabs;
    for (NSUInteger i = 0; i < MIN(count, tabs.count); ++i, ++opened) [self ensureBrowserForItem:tabs[i]];
  }
}

- (ArcItem*)itemForBrowser:(int)browserId {
  for (ArcSpace* s in _spaces)
    for (ArcItem* t in s.allTabs)
      if (t.browserId == browserId) return t;
  return nil;
}

- (void)browser:(int)browserId title:(NSString*)title url:(NSString*)url {
  ArcItem* item = [self itemForBrowser:browserId];
  if (!item) return;
  if (title.length) item.liveTitle = title;
  if (url.length) item.url = url;
  [_outline reloadItem:item];
  [self scheduleSave];
}

- (NSArray<NSDictionary*>*)tabSnapshot {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcSpace* s in _spaces)
    for (ArcItem* t in s.allTabs)
      if (t.browserId)
        [out addObject:@{@"space" : s.title, @"profile" : s.profileDirectory, @"title" : t.displayTitle,
                         @"url" : t.url ?: @""}];
  return out;
}

- (void)closeAllBrowsers {
  _closing = YES;
  for (LittleWindowController* lw in [_littleWindows copy]) [lw.window close];
  if (_client) _client->set_quit_when_empty(true);
  if (_browsers.empty()) {
    [self.window close];
    return;
  }
  for (auto& kv : _browsers) kv.second->GetHost()->CloseBrowser(true);
}

#pragma mark NSOutlineView

- (NSArray<ArcItem*>*)childrenOf:(id)item {
  if (!item) {
    if (!_space) return @[];
    return _space.favorites ? @[ _space.favorites, _space.pinned, _space.unpinned ]
                            : @[ _space.pinned, _space.unpinned ];
  }
  return ((ArcItem*)item).children;
}

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(id)item {
  return [self childrenOf:item].count;
}

- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)index ofItem:(id)item {
  return [self childrenOf:item][index];
}

- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)item {
  ArcItem* a = item;
  return a.isSection || a.isFolder;
}

- (BOOL)outlineView:(NSOutlineView*)ov isGroupItem:(id)item {
  return ((ArcItem*)item).isSection;
}

- (BOOL)outlineView:(NSOutlineView*)ov shouldSelectItem:(id)item {
  return ((ArcItem*)item).url.length > 0;
}

- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(id)item {
  ArcItem* a = item;
  NSTableCellView* cell = [ov makeViewWithIdentifier:@"cell" owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, col.width, 28)];
    cell.identifier = @"cell";
    NSImageView* icon = [[NSImageView alloc] initWithFrame:NSMakeRect(2, 6, 16, 16)];
    [cell addSubview:icon];
    cell.imageView = icon;
    NSTextField* label = [NSTextField labelWithString:@""];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.frame = NSMakeRect(24, 5, col.width - 28, 18);
    label.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:label];
    cell.textField = label;
  }
  cell.textField.stringValue = a.displayTitle;
  cell.textField.editable = a.isFolder;
  cell.textField.delegate = a.isFolder ? self : nil;
  cell.textField.font = a.isSection ? [NSFont boldSystemFontOfSize:11] : [NSFont systemFontOfSize:13];
  NSString* symbol = a.isSection ? nil : (a.isFolder ? @"folder" : @"globe");
  cell.imageView.image = symbol ? [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] : nil;
  return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification {
  id item = [_outline itemAtRow:_outline.selectedRow];
  if (item && item != _shown) [self showItem:item];
}

#pragma mark Persistence

// Coalesce bursts of changes (page titles arrive several times per load) into one write.
- (void)scheduleSave {
  if (!self.storePath || _saveScheduled) return;
  _saveScheduled = YES;
  __weak MainWindowController* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakSelf saveSidebarNow];
  });
}

- (void)saveSidebarNow {
  _saveScheduled = NO;
  if (!self.storePath) return;
  NSError* error = nil;
  if (!SidebarStoreSave(_spaces, _space.spaceID, self.storePath, &error))
    std::fprintf(stderr, "sidebar save failed: %s\n", error.localizedDescription.UTF8String);
}

#pragma mark Browser basics

- (CefRefPtr<CefBrowser>)currentBrowser {
  auto it = _browsers.find(_shown.browserId);
  return it == _browsers.end() ? nullptr : it->second;
}

- (IBAction)goBack:(id)sender { if (auto b = [self currentBrowser]) b->GoBack(); }
- (IBAction)goForward:(id)sender { if (auto b = [self currentBrowser]) b->GoForward(); }
- (IBAction)reloadPage:(id)sender { if (auto b = [self currentBrowser]) b->Reload(); }
- (IBAction)hardReload:(id)sender { if (auto b = [self currentBrowser]) b->ReloadIgnoreCache(); }
- (BOOL)hasLiveBrowser { return [self currentBrowser] != nullptr; }
- (BOOL)canGoBack { auto b = [self currentBrowser]; return b && b->CanGoBack(); }
- (NSString*)currentURL {
  auto b = [self currentBrowser];
  return b ? [NSString stringWithUTF8String:b->GetMainFrame()->GetURL().ToString().c_str()] : _shown.url;
}

// Chromium zoom levels: 0 = 100%, each step is a factor of 1.2.
- (void)stepZoom:(double)delta {
  auto b = [self currentBrowser];
  if (!b) return;
  double level = delta == 0 ? 0 : b->GetHost()->GetZoomLevel() + delta;
  b->GetHost()->SetZoomLevel(MAX(-7.6, MIN(9.0, level)));
}
- (IBAction)zoomIn:(id)sender { [self stepZoom:0.5]; }
- (IBAction)zoomOut:(id)sender { [self stepZoom:-0.5]; }
- (IBAction)actualSize:(id)sender { [self stepZoom:0]; }
- (double)currentZoomLevel { auto b = [self currentBrowser]; return b ? b->GetHost()->GetZoomLevel() : 0; }

- (IBAction)findInPage:(id)sender {
  if (!_findBar) {
    _findBar = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 340, 40)
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _findBar.backgroundColor = NSColor.windowBackgroundColor;
    _findField = [[NSSearchField alloc] initWithFrame:NSMakeRect(8, 8, 240, 24)];
    _findField.placeholderString = @"Find in page";
    _findField.delegate = (id<NSSearchFieldDelegate>)self;
    _findField.sendsSearchStringImmediately = YES;
    [_findBar.contentView addSubview:_findField];
    _findLabel = [NSTextField labelWithString:@""];
    _findLabel.frame = NSMakeRect(254, 12, 80, 16);
    [_findBar.contentView addSubview:_findLabel];
  }
  NSRect f = self.window.frame;
  [_findBar setFrameOrigin:NSMakePoint(NSMaxX(f) - 356, NSMaxY(f) - 80)];
  [self.window addChildWindow:_findBar ordered:NSWindowAbove];
  [_findBar makeKeyAndOrderFront:nil];
  [_findBar makeFirstResponder:_findField];
}

- (void)hideFindBar {
  if (auto b = [self currentBrowser]) b->GetHost()->StopFinding(true);
  [self.window removeChildWindow:_findBar];
  [_findBar orderOut:nil];
  [self.window makeKeyWindow];
}

- (void)findText:(NSString*)text forward:(BOOL)forward {
  auto b = [self currentBrowser];
  if (!b) return;
  if (!text.length) {
    b->GetHost()->StopFinding(true);
    _findLabel.stringValue = @"";
    return;
  }
  b->GetHost()->Find(text.UTF8String, forward, false, true);
}

- (IBAction)findNext:(id)sender { [self findText:_findField.stringValue forward:YES]; }
- (IBAction)findPrevious:(id)sender { [self findText:_findField.stringValue forward:NO]; }

- (void)findResult:(int)count active:(int)active {
  _lastFindCount = count;
  _findLabel.stringValue = count ? [NSString stringWithFormat:@"%d of %d", active, count] : @"No matches";
}

- (int)lastFindCount { return _lastFindCount; }

- (IBAction)toggleDevTools:(id)sender {
  auto b = [self currentBrowser];
  if (!b) return;
  if (b->GetHost()->HasDevTools()) {
    b->GetHost()->CloseDevTools();
    return;
  }
  CefWindowInfo info;
  CefBrowserSettings settings;
  b->GetHost()->ShowDevTools(info, nullptr, settings, CefPoint());
}

- (IBAction)copyCurrentURL:(id)sender {
  NSString* url = [self currentURL];
  if (!url.length) return;
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
}

- (IBAction)copyCurrentURLAsMarkdown:(id)sender {
  NSString* url = [self currentURL];
  if (!url.length) return;
  NSString* title = [_shown.displayTitle stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"[%@](%@)", title, url]
                                    forType:NSPasteboardTypeString];
}

#pragma mark Split view

static const CGFloat kPaneGap = 6;

// Panes on screen: the whole split if the shown tab belongs to it, otherwise just that tab.
- (NSArray<ArcItem*>*)visiblePanes {
  if (_shown && [_splitItems containsObject:_shown]) return _splitItems;
  return _shown ? @[ _shown ] : @[];
}

- (NSArray<NSValue*>*)framesForPaneCount:(NSUInteger)n {
  NSMutableArray* frames = [NSMutableArray array];
  NSRect b = _content.bounds;
  if (n == 0) return frames;
  CGFloat gap = n > 1 ? kPaneGap : 0;
  CGFloat total = (_splitHorizontal ? b.size.height : b.size.width) - gap * (n - 1);
  CGFloat each = floor(total / n);
  for (NSUInteger i = 0; i < n; ++i) {
    CGFloat size = i == n - 1 ? total - each * (n - 1) : each;
    CGFloat offset = i * (each + gap);
    // Horizontal splits stack top to bottom; AppKit's origin is bottom-left.
    NSRect r = _splitHorizontal ? NSMakeRect(0, b.size.height - offset - size, b.size.width, size)
                                : NSMakeRect(offset, 0, size, b.size.height);
    [frames addObject:[NSValue valueWithRect:r]];
  }
  return frames;
}

- (void)layoutPanes {
  NSArray<ArcItem*>* panes = [self visiblePanes];
  for (ArcItem* pane in panes) [self ensureBrowserForItem:pane];
  NSArray<NSValue*>* frames = [self framesForPaneCount:panes.count];
  for (auto& kv : _browsers) {
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < panes.count; ++i)
      if (panes[i].browserId == kv.first) index = i;
    NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(kv.second->GetHost()->GetWindowHandle());
    BOOL visible = index != NSNotFound;
    if (visible) {
      view.frame = frames[index].rectValue;
      // A single pane follows the window; split panes are re-laid out on resize.
      view.autoresizingMask = panes.count == 1 ? (NSViewWidthSizable | NSViewHeightSizable) : NSViewNotSizable;
    }
    view.hidden = !visible;
    kv.second->GetHost()->WasHidden(!visible);
  }
}

- (NSArray<NSValue*>*)paneFrames {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcItem* pane in [self visiblePanes]) {
    auto it = _browsers.find(pane.browserId);
    if (it == _browsers.end()) continue;
    [out addObject:[NSValue valueWithRect:CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(it->second->GetHost()->GetWindowHandle()).frame]];
  }
  return out;
}

- (void)windowDidResize:(NSNotification*)note {
  if (_splitItems.count > 1) [self layoutPanes];
}

- (void)paneFocused:(int)browserId {
  ArcItem* item = [self itemForBrowser:browserId];
  if (!item || item == _shown || ![_splitItems containsObject:item]) return;
  _shown.lastActiveAt = [NSDate date];
  _shown = item;
  item.lastActiveAt = [NSDate date];
  NSInteger row = [_outline rowForItem:item];
  if (row >= 0) [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
}

- (void)beginSplit:(BOOL)horizontal {
  if (!_shown || _splitItems.count >= 4) {
    NSBeep();
    return;
  }
  _commandOpensLittle = NO;
  _splitHorizontal = horizontal;
  _commandOpensSplit = YES;
  [self showCommandBarForNewTab:YES];
}

- (IBAction)addVerticalSplit:(id)sender { [self beginSplit:NO]; }
- (IBAction)addHorizontalSplit:(id)sender { [self beginSplit:YES]; }

// The new pane is a normal Today tab placed next to the focused pane, like Arc.
- (void)openInSplit:(NSString*)input horizontal:(BOOL)horizontal {
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space || !_shown) return;
  if (![_splitItems containsObject:_shown]) {
    _splitItems = [NSMutableArray arrayWithObject:_shown];
    _splitHorizontal = horizontal;
  }
  if (_splitItems.count >= 4) return;
  ArcItem* tab = [ArcItem new];
  tab.itemID = NSUUID.UUID.UUIDString;
  tab.url = url;
  tab.children = [NSMutableArray array];
  [_space.unpinned.children insertObject:tab atIndex:0];
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [_splitItems insertObject:tab atIndex:[_splitItems indexOfObject:_shown] + 1];
  [self scheduleSave];
  [self showItem:tab];
}

// Removes the focused pane from the split; its tab stays in the sidebar.
- (IBAction)closeSplitPane:(id)sender {
  if (![_splitItems containsObject:_shown]) return;
  NSUInteger index = [_splitItems indexOfObject:_shown];
  [_splitItems removeObjectAtIndex:index];
  ArcItem* next = _splitItems[MIN(index, _splitItems.count - 1)];
  if (_splitItems.count < 2) _splitItems = nil;
  [self showItem:next];
}

- (IBAction)focusNextPane:(id)sender {
  if (![_splitItems containsObject:_shown]) return;
  NSUInteger index = ([_splitItems indexOfObject:_shown] + 1) % _splitItems.count;
  [self showItem:_splitItems[index]];
  if (auto b = [self currentBrowser]) b->GetHost()->SetFocus(true);
}

#pragma mark Little Window

- (void)openLittleWindow:(NSString*)input {
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space) return;
  ArcSpace* space = _space;
  CefRefPtr<CefRequestContext> context = [self contextForSpace:space];
  __weak MainWindowController* weakSelf = self;
  if (!_readyContexts.count(space.profileDirectory.UTF8String)) {
    // The Space's profile is still starting (e.g. a link arrived at launch); try again shortly.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
      [weakSelf openLittleWindow:url];
    });
    return;
  }
  LittleWindowController* little = [[LittleWindowController alloc] initWithURL:url
      context:context
      onMove:^(NSString* movedURL) { [weakSelf openInNewTab:movedURL]; }
      onClose:^(LittleWindowController* lw, NSString* closedURL, NSString* title, BOOL moved) {
        [weakSelf littleWindowClosed:lw url:closedURL title:title moved:moved space:space];
      }];
  if (!_littleWindows) _littleWindows = [NSMutableArray array];
  [_littleWindows addObject:little];
  [little showWindow:nil];
}

// A Little Window that's closed without being moved still lands in the Archive, like Arc.
- (void)littleWindowClosed:(LittleWindowController*)little
                       url:(NSString*)url
                     title:(NSString*)title
                     moved:(BOOL)moved
                     space:(ArcSpace*)space {
  [_littleWindows removeObject:little];
  if (moved || !url.length || [url isEqualToString:@"about:blank"]) return;
  ArchivedTab* t = [ArchivedTab new];
  t.url = url;
  t.title = title ?: url;
  t.spaceID = space.spaceID;
  t.reason = @"littleWindow";
  t.archivedAt = [NSDate date];
  [[self archive] addObject:t];
  if (self.archivePath) ArchiveStoreSave(_archive, self.archivePath);
}

- (IBAction)newLittleWindow:(id)sender {
  _commandOpensSplit = NO;
  _commandOpensLittle = YES;
  [self showCommandBarForNewTab:YES];
}

- (NSUInteger)littleWindowCount { return _littleWindows.count; }
- (void)moveLittleWindowToMain:(NSUInteger)index {
  if (index < _littleWindows.count) [_littleWindows[index] openInMainWindow:nil];
}
- (void)closeLittleWindow:(NSUInteger)index {
  if (index < _littleWindows.count) [_littleWindows[index].window close];
}

#pragma mark Command bar and tab actions

- (void)showCommandBarForNewTab:(BOOL)newTab {
  _commandOpensNewTab = newTab;
  if (!_commandBar) {
    _commandBar = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 640, 52)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    _commandBar.titlebarAppearsTransparent = YES;
    _commandBar.titleVisibility = NSWindowTitleHidden;
    _commandBar.movable = NO;
    _commandField = [[NSTextField alloc] initWithFrame:NSMakeRect(12, 10, 616, 32)];
    _commandField.font = [NSFont systemFontOfSize:18];
    _commandField.bezeled = NO;
    _commandField.focusRingType = NSFocusRingTypeNone;
    _commandField.drawsBackground = NO;
    _commandField.delegate = self;
    [_commandBar.contentView addSubview:_commandField];
  }
  _commandField.placeholderString = newTab ? @"Search or enter URL (new tab)" : @"Search or enter URL";
  _commandField.stringValue = (!newTab && _shown.url) ? _shown.url : @"";
  NSRect f = self.window.frame;
  [_commandBar setFrameOrigin:NSMakePoint(NSMidX(f) - 320, NSMaxY(f) - 220)];
  [self.window addChildWindow:_commandBar ordered:NSWindowAbove];
  [_commandBar makeKeyAndOrderFront:nil];
  [_commandBar makeFirstResponder:_commandField];
  [_commandField selectText:nil];
}

- (void)hideCommandBar {
  [self.window removeChildWindow:_commandBar];
  [_commandBar orderOut:nil];
  [self.window makeKeyWindow];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
  if (control == _findField) {
    if (command == @selector(insertNewline:)) {
      BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
      [self findText:_findField.stringValue forward:!shift];
      return YES;
    }
    if (command == @selector(cancelOperation:)) {
      [self hideFindBar];
      return YES;
    }
    return NO;
  }
  if (command == @selector(insertNewline:)) {
    NSString* text = _commandField.stringValue;
    [self hideCommandBar];
    if (_commandOpensLittle) [self openLittleWindow:text];
    else if (_commandOpensSplit) [self openInSplit:text horizontal:_splitHorizontal];
    else if (_commandOpensNewTab) [self openInNewTab:text];
    else [self navigateCurrentTab:text];
    _commandOpensSplit = NO;
    _commandOpensLittle = NO;
    return YES;
  }
  if (command == @selector(cancelOperation:)) {
    _commandOpensSplit = NO;
    _commandOpensLittle = NO;
    [self hideCommandBar];
    return YES;
  }
  return NO;
}

- (IBAction)newTab:(id)sender {
  _commandOpensSplit = NO;
  _commandOpensLittle = NO;
  [self showCommandBarForNewTab:YES];
}
- (IBAction)openLocation:(id)sender { [self showCommandBarForNewTab:NO]; }
- (IBAction)closeTab:(id)sender { [self closeCurrentTab]; }

// Arc puts new tabs at the top of the current Space's Today section.
- (void)openInNewTab:(NSString*)input {
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space) return;
  ArcItem* tab = [ArcItem new];
  tab.itemID = NSUUID.UUID.UUIDString;
  tab.url = url;
  tab.children = [NSMutableArray array];
  [_space.unpinned.children insertObject:tab atIndex:0];
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  [self showItem:tab];
}

- (void)navigateCurrentTab:(NSString*)input {
  NSString* url = ResolveCommandBarInput(input);
  if (!url) return;
  if (!_shown) {
    [self openInNewTab:input];
    return;
  }
  auto it = _browsers.find(_shown.browserId);
  if (it == _browsers.end()) {
    // The tab's web view isn't created yet (its Space profile is still starting): load the new
    // address when it is, instead of dropping it.
    _shown.url = url;
    [self ensureBrowserForItem:_shown];
    [self scheduleSave];
    return;
  }
  it->second->GetMainFrame()->LoadURL(url.UTF8String);
}

static BOOL RemoveItem(ArcItem* parent, ArcItem* target) {
  if ([parent.children containsObject:target]) {
    [parent.children removeObject:target];
    return YES;
  }
  for (ArcItem* child in parent.children)
    if (RemoveItem(child, target)) return YES;
  return NO;
}

- (void)unloadItem:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it != _browsers.end()) {
    NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(it->second->GetHost()->GetWindowHandle());
    it->second->GetHost()->CloseBrowser(true);
    [view removeFromSuperview];  // child browsers are torn down when their view goes away
    _browsers.erase(it);
  }
  item.browserId = 0;
}

- (void)archiveItem:(ArcItem*)item space:(ArcSpace*)space reason:(NSString*)reason {
  if (!item.url.length) return;
  ArchivedTab* t = [ArchivedTab new];
  t.url = item.url;
  t.title = item.displayTitle;
  t.spaceID = space.spaceID;
  t.reason = reason;
  t.archivedAt = [NSDate date];
  [[self archive] addObject:t];
  if (self.archivePath) ArchiveStoreSave(_archive, self.archivePath);
}

- (NSMutableArray<ArchivedTab*>*)archive {
  if (!_archive) _archive = self.archivePath ? ArchiveStoreLoad(self.archivePath) : [NSMutableArray array];
  return _archive;
}

- (NSArray*)archivedTabs { return [self archive]; }

- (void)closeCurrentTab {
  ArcItem* item = _shown;
  if (!item) return;
  NSArray<ArcItem*>* tabs = _space.allTabs;
  NSUInteger index = [tabs indexOfObject:item];
  BOOL isToday = Contains(_space.unpinned, item);
  if ([_splitItems containsObject:item]) {
    [_splitItems removeObject:item];
    if (_splitItems.count < 2) _splitItems = nil;
  }
  if (isToday) [self archiveItem:item space:_space reason:@"manual"];  // Arc archives closed Today tabs
  [self unloadItem:item];
  // Pinned tabs and Favorites stay in the sidebar (Arc just unloads them); Today tabs are removed.
  if (RemoveItem(_space.unpinned, item)) [_outline reloadItem:_space.unpinned reloadChildren:YES];
  else [_outline reloadItem:item];
  [self scheduleSave];
  _shown = nil;
  NSArray<ArcItem*>* remaining = _space.allTabs;
  ArcItem* next = nil;
  for (NSUInteger i = MIN(index, remaining.count); i < remaining.count && !next; ++i)
    if (remaining[i].browserId) next = remaining[i];
  for (ArcItem* t in remaining)
    if (!next && t.browserId) next = t;
  if (next) [self showItem:next];
  else [_outline deselectAll:nil];
}

#pragma mark Sidebar organisation

static ArcItem* ParentOf(ArcItem* root, ArcItem* target) {
  for (ArcItem* child in root.children) {
    if (child == target) return root;
    ArcItem* found = ParentOf(child, target);
    if (found) return found;
  }
  return nil;
}

static BOOL Contains(ArcItem* root, ArcItem* target) {
  if (root == target) return YES;
  for (ArcItem* child in root.children)
    if (Contains(child, target)) return YES;
  return NO;
}

- (NSArray<ArcItem*>*)sectionsOfSpace:(ArcSpace*)space {
  NSMutableArray* out = [NSMutableArray array];
  if (space.favorites) [out addObject:space.favorites];
  if (space.pinned) [out addObject:space.pinned];
  if (space.unpinned) [out addObject:space.unpinned];
  return out;
}

- (ArcItem*)parentOfItem:(ArcItem*)item {
  for (ArcItem* section in [self sectionsOfSpace:_space]) {
    ArcItem* parent = ParentOf(section, item);
    if (parent) return parent;
  }
  return nil;
}

- (ArcItem*)sectionContaining:(ArcItem*)item {
  for (ArcItem* section in [self sectionsOfSpace:_space])
    if (Contains(section, item)) return section;
  return nil;
}

- (ArcItem*)currentPinnedSection { return _space.pinned; }

- (BOOL)moveItem:(ArcItem*)item toParent:(ArcItem*)parent index:(NSInteger)index {
  if (!item || !parent || item.isSection) return NO;
  if (!(parent.isSection || parent.isFolder)) return NO;
  if (Contains(item, parent)) return NO;  // a folder can't go inside itself
  ArcItem* oldParent = [self parentOfItem:item];
  if (!oldParent || ![self sectionContaining:parent]) return NO;  // both must be in the current Space
  NSInteger oldIndex = [oldParent.children indexOfObject:item];
  [oldParent.children removeObjectAtIndex:oldIndex];
  if (oldParent == parent && index > oldIndex) index -= 1;  // removal shifted the target slot
  index = MAX(0, MIN(index, (NSInteger)parent.children.count));
  [parent.children insertObject:item atIndex:index];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  if (parent.isFolder) [_outline expandItem:parent];
  if (_shown) {
    NSInteger row = [_outline rowForItem:_shown];
    if (row >= 0) [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  }
  [self scheduleSave];
  return YES;
}

- (ArcItem*)createFolderNamed:(NSString*)name {
  if (!_space) return nil;
  ArcItem* folder = [ArcItem new];
  folder.itemID = NSUUID.UUID.UUIDString;
  folder.title = name.length ? name : @"New Folder";
  folder.isFolder = YES;
  folder.children = [NSMutableArray array];
  [_space.pinned.children insertObject:folder atIndex:0];
  [_outline reloadItem:_space.pinned reloadChildren:YES];
  [_outline expandItem:folder];
  [self scheduleSave];
  return folder;
}

- (IBAction)newFolder:(id)sender {
  ArcItem* folder = [self createFolderNamed:@"New Folder"];
  NSInteger row = [_outline rowForItem:folder];
  if (row >= 0) [_outline editColumn:0 row:row withEvent:nil select:YES];
}

// Arc's Cmd+D: Today tab -> bottom of Pinned; pinned tab (or one in a pinned folder) -> top of Today.
- (IBAction)togglePin:(id)sender {
  ArcItem* item = _shown;
  if (!item) return;
  ArcItem* section = [self sectionContaining:item];
  if (section == _space.unpinned)
    [self moveItem:item toParent:_space.pinned index:_space.pinned.children.count];
  else if (section == _space.pinned)
    [self moveItem:item toParent:_space.unpinned index:0];
}

- (ArcItem*)tabWithURLPrefix:(NSString*)prefix {
  for (ArcItem* t in _space.allTabs)
    if ([t.url hasPrefix:prefix]) return t;
  return nil;
}

// Folder renames from the sidebar (double-click / New Folder).
- (void)controlTextDidChange:(NSNotification*)note {
  if (note.object == _findField) [self findText:_findField.stringValue forward:YES];
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
  NSTextField* field = note.object;
  if (field == _commandField || field == _findField) return;
  NSInteger row = [_outline rowForView:field];
  ArcItem* item = row >= 0 ? [_outline itemAtRow:row] : nil;
  if (!item || item.isSection || !field.stringValue.length) return;
  item.title = field.stringValue;
  [self scheduleSave];
}

#pragma mark Drag and drop

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView*)ov pasteboardWriterForItem:(id)item {
  ArcItem* a = item;
  if (a.isSection || !a.itemID) return nil;
  NSPasteboardItem* pb = [NSPasteboardItem new];
  [pb setString:a.itemID forType:kSidebarItemPasteboardType];
  return pb;
}

- (ArcItem*)itemWithID:(NSString*)itemID under:(ArcItem*)root {
  if ([root.itemID isEqualToString:itemID]) return root;
  for (ArcItem* child in root.children) {
    ArcItem* found = [self itemWithID:itemID under:child];
    if (found) return found;
  }
  return nil;
}

- (ArcItem*)draggedItem:(id<NSDraggingInfo>)info {
  NSString* itemID = [info.draggingPasteboard stringForType:kSidebarItemPasteboardType];
  if (!itemID) return nil;
  for (ArcItem* section in [self sectionsOfSpace:_space]) {
    ArcItem* found = [self itemWithID:itemID under:section];
    if (found) return found;
  }
  return nil;
}

- (NSDragOperation)outlineView:(NSOutlineView*)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {
  ArcItem* dragged = [self draggedItem:info];
  ArcItem* target = item;
  if (!dragged || !target) return NSDragOperationNone;
  if (!(target.isSection || target.isFolder)) {
    // Dropped onto a tab: insert just after it in its parent.
    ArcItem* parent = [self parentOfItem:target];
    if (!parent) return NSDragOperationNone;
    [ov setDropItem:parent dropChildIndex:[parent.children indexOfObject:target] + 1];
    target = parent;
  }
  if (Contains(dragged, target)) return NSDragOperationNone;
  return NSDragOperationMove;
}

- (BOOL)outlineView:(NSOutlineView*)ov acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index {
  ArcItem* dragged = [self draggedItem:info];
  ArcItem* target = item;
  if (!dragged || !target) return NO;
  if (index == NSOutlineViewDropOnItemIndex) index = target.children.count;
  return [self moveItem:dragged toParent:target index:index];
}

#pragma mark Auto-archive

// Today tabs inactive longer than the threshold are archived (12 hours by default, the same
// default Arc users are used to).
// Pinned tabs, Favorites and the tab on screen are never auto-archived.
- (NSUInteger)runAutoArchiveWithThreshold:(NSTimeInterval)threshold now:(NSDate*)now {
  if (threshold <= 0) return 0;
  NSUInteger archived = 0;
  for (ArcSpace* space in _spaces) {
    for (ArcItem* item in [space.unpinned.children copy]) {
      if (item == _shown || [_splitItems containsObject:item] || item.isFolder || !item.url.length) continue;
      if (!item.lastActiveAt) item.lastActiveAt = now;  // unknown age: start the clock now
      if ([now timeIntervalSinceDate:item.lastActiveAt] < threshold) continue;
      [self archiveItem:item space:space reason:@"auto"];
      [self unloadItem:item];
      [space.unpinned.children removeObject:item];
      ++archived;
    }
  }
  if (archived) {
    [_outline reloadData];
    [self reloadSidebar];
    [self scheduleSave];
  }
  return archived;
}

- (void)startAutoArchiveTimer {
  __weak MainWindowController* weakSelf = self;
  _archiveTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer* t) {
    [weakSelf runAutoArchiveWithThreshold:AutoArchiveThreshold() now:[NSDate date]];
  }];
}

- (IBAction)reopenLastArchived:(id)sender {
  ArchivedTab* last = [self archive].lastObject;
  if (last) [self reopenArchivedTab:last];
}

// Reopening removes the entry from the archive and restores the tab at the top of its Space's Today.
- (void)reopenArchivedTab:(ArchivedTab*)tab {
  if (![[self archive] containsObject:tab]) return;
  [_archive removeObject:tab];
  if (self.archivePath) ArchiveStoreSave(_archive, self.archivePath);
  for (ArcSpace* s in _spaces)
    if ([s.spaceID isEqualToString:tab.spaceID] && s != _space) {
      _space = s;
      [_spacePicker selectItemAtIndex:[_spaces indexOfObject:s]];
      [self reloadSidebar];
    }
  [self openInNewTab:tab.url];
  [_archiveWindow reload];
}

- (IBAction)showArchive:(id)sender {
  if (!_archiveWindow) {
    __weak MainWindowController* weakSelf = self;
    _archiveWindow = [[ArchiveWindowController alloc]
        initWithProvider:^NSArray<ArchivedTab*>* { return [weakSelf archivedTabs]; }
                  reopen:^(ArchivedTab* tab) { [weakSelf reopenArchivedTab:tab]; }];
  }
  [_archiveWindow reload];
  [_archiveWindow showWindow:nil];
}

- (NSUInteger)archiveWindowCountForQuery:(NSString*)query {
  [self showArchive:nil];
  [_archiveWindow setQuery:query];
  return _archiveWindow.visibleCount;
}

#pragma mark NSWindowDelegate

- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (_closing || _browsers.empty() || !_client || _client->open_browser_count() == 0) return YES;
  [self closeAllBrowsers];
  return NO;
}

// CEF destroys a child browser when its host NSView goes away. Removing the content
// view on window close is what actually tears the browsers down (DoClose returns false).
- (void)windowWillClose:(NSNotification*)notification {
  if (notification.object != self.window) return;  // the Archive window closing is not a quit
  for (LittleWindowController* lw in [_littleWindows copy]) [lw.window close];
  [_archiveTimer invalidate];
  [_archiveWindow close];
  [self saveSidebarNow];
  [_content removeFromSuperview];
  _content = nil;
  _browsers.clear();
  if (!_client || _client->open_browser_count() == 0) CefQuitMessageLoop();
}

@end
