#import "app/main_window.h"
#import "app/sidebar_store.h"
#import "app/archive_store.h"
#import "app/archive_window.h"
#import "app/history_store.h"
#import "app/arc_cookies.h"
#import "app/little_window.h"
#import "app/settings.h"

#include <cstdio>
#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

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
  return SearchURLForQuery(q);
}

static BOOL Contains(ArcItem* root, ArcItem* target);

@interface MainWindowController () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
                                    NSMenuDelegate>
@end

// The gap between two split panes; dragging it resizes them.
@interface SplitDividerView : NSView
@property(nonatomic, weak) MainWindowController* owner;
@property(nonatomic) NSUInteger index;
@property(nonatomic) BOOL horizontal;
@end

@implementation SplitDividerView
- (void)resetCursorRects {
  [self addCursorRect:self.bounds
               cursor:self.horizontal ? NSCursor.resizeUpDownCursor : NSCursor.resizeLeftRightCursor];
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (void)mouseDown:(NSEvent*)event {}
- (void)mouseDragged:(NSEvent*)event {
  NSView* content = self.superview;
  NSPoint p = [content convertPoint:event.locationInWindow fromView:nil];
  NSRect b = content.bounds;
  CGFloat position = self.horizontal ? (b.size.height - p.y) / b.size.height : p.x / b.size.width;
  [self.owner moveDivider:self.index toPosition:position];
}
@end

@implementation MainWindowController {
  NSMutableArray<ArcSpace*>* _spaces;
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
  ArchiveWindowController* _historyWindow;
  HistoryStore* _history;
  BOOL _focusMode;
  BOOL _sidebarWasHidden;
  NSPanel* _findBar;
  NSSearchField* _findField;
  NSTextField* _findLabel;
  int _lastFindCount;
  NSMutableArray<ArcItem*>* _splitItems;  // panes of the active split, in order; nil when no split
  BOOL _splitHorizontal;
  BOOL _commandOpensSplit;
  BOOL _commandOpensLittle;
  BOOL _splitBefore;
  BOOL _pendingSplitHorizontal;
  ArcItem* _splitGroup;  // sidebar item of the split being shown
  NSMutableArray<NSView*>* _dividers;
  NSMutableArray<LittleWindowController*>* _littleWindows;
  LittleWindowController* _peek;
  NSView* _sidebar;
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
    _spaces = [spaces mutableCopy];
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
  _sidebar = sidebar;

  _spacePicker = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(8, bounds.size.height - 72, kSidebarWidth - 16, 26) pullsDown:NO];
  _spacePicker.autoresizingMask = NSViewMinYMargin;
  [self rebuildSpacePicker];
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
  _outline.menu = [[NSMenu alloc] initWithTitle:@"Sidebar"];
  _outline.menu.delegate = self;
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
  ArcSpace* picked = _spacePicker.selectedItem.representedObject;
  if (picked) [self switchToSpace:picked];
}

class BlockDeleteCookies : public CefDeleteCookiesCallback {
 public:
  explicit BlockDeleteCookies(void (^done)(int)) : done_([done copy]) {}
  void OnComplete(int n) override {
    void (^done)(int) = done_;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(n); });
  }
 private:
  void (^done_)(int);
  IMPLEMENT_REFCOUNTING(BlockDeleteCookies);
};

// Visits every cookie, collects those matching `match`; when the visit ends, deletes them one by one
// through DeleteCookies (which reports completion) if `remove`, then reports the count on the main queue.
class MatchCookieVisitor : public CefCookieVisitor {
 public:
  MatchCookieVisitor(CefRefPtr<CefCookieManager> mgr, std::function<bool(const CefCookie&)> match, bool remove,
                     void (^done)(NSUInteger))
      : mgr_(mgr), match_(std::move(match)), remove_(remove), done_([done copy]) {}
  ~MatchCookieVisitor() override {
    auto hits = std::make_shared<std::vector<std::pair<std::string, std::string>>>(std::move(hits_));
    void (^done)(NSUInteger) = done_;
    CefRefPtr<CefCookieManager> mgr = mgr_;
    BOOL remove = remove_;
    dispatch_async(dispatch_get_main_queue(), ^{
      NSUInteger n = hits->size();
      if (!remove || hits->empty()) {
        if (done) done(n);
        return;
      }
      dispatch_group_t g = dispatch_group_create();
      for (auto& h : *hits) {
        dispatch_group_enter(g);
        std::string dbgUrl = h.first, dbgName = h.second;
        if (!mgr->DeleteCookies(h.first, h.second, new BlockDeleteCookies(^(int deleted) {
              if (getenv("NOTARC_COOKIE_DEBUG"))
                fprintf(stderr, "COOKIE-DEL %s %s -> %d\n", dbgUrl.c_str(), dbgName.c_str(), deleted);
              dispatch_group_leave(g);
            })))
          dispatch_group_leave(g);
      }
      dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        if (done) done(n);
      });
    });
  }
  bool Visit(const CefCookie& c, int, int, bool&) override {
    if (getenv("NOTARC_COOKIE_DEBUG") && CefString(&c.name).ToString().rfind("nt_", 0) == 0)
      fprintf(stderr, "COOKIE-SEEN %s domain=%s path=%s match=%d\n", CefString(&c.name).ToString().c_str(),
              CefString(&c.domain).ToString().c_str(), CefString(&c.path).ToString().c_str(), (int)match_(c));
    if (match_(c)) {
      std::string d = CefString(&c.domain).ToString();
      if (!d.empty() && d[0] == '.') d = d.substr(1);
      std::string url = (c.secure ? "https://" : "http://") + d + CefString(&c.path).ToString();
      hits_.emplace_back(url, CefString(&c.name).ToString());
    }
    return true;
  }
 private:
  CefRefPtr<CefCookieManager> mgr_;
  std::function<bool(const CefCookie&)> match_;
  bool remove_;
  void (^done_)(NSUInteger);
  std::vector<std::pair<std::string, std::string>> hits_;
  IMPLEMENT_REFCOUNTING(MatchCookieVisitor);
};

class BlockCompletion : public CefCompletionCallback {
 public:
  explicit BlockCompletion(void (^done)(void)) : done_([done copy]) {}
  void OnComplete() override {
    void (^done)(void) = done_;
    if (done) dispatch_async(dispatch_get_main_queue(), done);
  }
 private:
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(BlockCompletion);
};

class BlockSetCookie : public CefSetCookieCallback {
 public:
  explicit BlockSetCookie(void (^done)(void)) : done_([done copy]) {}
  void OnComplete(bool ok) override {
    if (getenv("NOTARC_COOKIE_DEBUG")) fprintf(stderr, "COOKIE-SET ok=%d\n", ok);
    void (^done)(void) = done_;
    if (done) dispatch_async(dispatch_get_main_queue(), done);
  }
 private:
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(BlockSetCookie);
};

static double CookieCreatedUnix(const CefCookie& c) {
  return c.creation.val / 1e6 - 11644473600.0;  // microseconds since 1601 -> seconds since 1970
}

static std::string HostOf(const std::string& url) {
  NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
  return u.host.lowercaseString.UTF8String ?: "";
}

// Cookie domain ".example.com" or "example.com" belongs to host "www.example.com" / "example.com".
static bool CookieBelongsToHost(const CefCookie& c, const std::string& host) {
  std::string d = CefString(&c.domain).ToString();
  if (!d.empty() && d[0] == '.') d = d.substr(1);
  if (d.empty() || host.empty()) return false;
  if (host == d) return true;
  return host.size() > d.size() && host.compare(host.size() - d.size(), d.size(), d) == 0 &&
         host[host.size() - d.size() - 1] == '.';
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
  NSString* name = [(self.selfTestProfiles ? @"SelfTest Space " : @"Space ") stringByAppendingString:space.profileDirectory];
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
  if (!self.selfTestProfiles && ![[NSFileManager defaultManager] fileExistsAtPath:marker]) {
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
  _client->set_link_menu_callback([weakSelf](int browserId, int command, const std::string& url, const std::string&) {
    NSString* target = [NSString stringWithUTF8String:url.c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf handleLinkCommand:command url:target fromBrowser:browserId]; });
  });
  _client->set_open_callback([weakSelf](int browserId, const std::string& url, int disposition, bool gesture) -> bool {
    MainWindowController* strong = weakSelf;
    if (!strong) return false;
    NSString* target = [NSString stringWithUTF8String:url.c_str()];
    // Decide now (so CEF knows not to open its own window), act after this callback returns.
    BOOL handled = [strong handleOpenURL:target fromBrowser:browserId disposition:disposition userGesture:gesture];
    return handled;
  });
  _client->set_navigation_filter([weakSelf](int browserId, const std::string& url) -> bool {
    MainWindowController* strong = weakSelf;
    if (!strong) return false;
    NSString* target = [NSString stringWithUTF8String:url.c_str()];
    if (![strong shouldPeekFromItem:[strong itemForBrowser:browserId] toURL:target]) return false;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openPeek:target]; });
    return true;
  });
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
  [self selectSidebarRowFor:item];
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
  if (url.length && !item.pinnedURL.length && [self isPinnedItem:item]) item.pinnedURL = item.url ?: url;
  if (url.length) item.url = url;
  if (self.historyPath && !_history) _history = [[HistoryStore alloc] initWithPath:self.historyPath];
  if (url.length) [_history recordURL:url title:title space:[self spaceOwningItem:item].title];
  else if (title.length) [_history updateTitle:title forURL:item.url];
  ArcItem* parent = [self parentOfItem:item];
  [_outline reloadItem:parent.isSplit ? parent : item];
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
  [_peek.window close];
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
  return a.isSection || a.isFolder;  // a split is a single row
}

- (BOOL)outlineView:(NSOutlineView*)ov isGroupItem:(id)item {
  return ((ArcItem*)item).isSection;
}

- (BOOL)outlineView:(NSOutlineView*)ov shouldSelectItem:(id)item {
  return ((ArcItem*)item).url.length > 0 || ((ArcItem*)item).isSplit;
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
  NSString* title = a.displayTitle;
  if (a.isSplit) {
    NSMutableArray* names = [NSMutableArray array];
    for (ArcItem* pane in a.children) [names addObject:pane.displayTitle];
    title = [names componentsJoinedByString:@" | "];
  }
  cell.textField.stringValue = title;
  cell.textField.editable = a.isFolder;
  cell.textField.delegate = a.isFolder ? self : nil;
  cell.textField.font = a.isSection ? [NSFont boldSystemFontOfSize:11] : [NSFont systemFontOfSize:13];
  NSString* symbol = a.isSection ? nil : (a.isFolder ? @"folder" : @"globe");
  if (a.isSplit) symbol = a.splitHorizontal ? @"rectangle.split.1x2" : @"rectangle.split.2x1";
  cell.imageView.image = symbol ? [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] : nil;
  return cell;
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification {
  ArcItem* item = [_outline itemAtRow:_outline.selectedRow];
  if (item.isSplit) {
    if ([item.children containsObject:_shown]) return;
    // Reopen the pane that was focused last.
    ArcItem* pane = item.children.firstObject;
    for (ArcItem* c in item.children)
      if (c.lastActiveAt && (!pane.lastActiveAt || [c.lastActiveAt compare:pane.lastActiveAt] == NSOrderedDescending))
        pane = c;
    if (pane) [self showItem:pane];
    return;
  }
  if (item && item != _shown) [self showItem:item];
}

- (void)selectSidebarRowFor:(ArcItem*)item {
  NSInteger row = [_outline rowForItem:item];
  ArcItem* parent = [self parentOfItem:item];
  if (row < 0 && parent.isSplit) row = [_outline rowForItem:parent];
  if (row >= 0 && row != _outline.selectedRow)
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
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
- (void)startDownload:(NSString*)url {
  auto b = [self currentBrowser];
  if (b) b->GetHost()->StartDownload(url.UTF8String);
}

- (BOOL)isLoading { auto b = [self currentBrowser]; return b && b->IsLoading(); }
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
  NSArray<NSNumber*>* fractions = n > 1 && _splitGroup.splitFractions.count == n ? _splitGroup.splitFractions : nil;
  CGFloat each = floor(total / n);
  CGFloat offset = 0;
  for (NSUInteger i = 0; i < n; ++i) {
    CGFloat size = fractions ? floor(total * fractions[i].doubleValue) : each;
    if (i == n - 1) size = MAX(0, (_splitHorizontal ? b.size.height : b.size.width) - offset);  // absorb rounding
    // Horizontal splits stack top to bottom; AppKit's origin is bottom-left.
    NSRect r = _splitHorizontal ? NSMakeRect(0, b.size.height - offset - size, b.size.width, size)
                                : NSMakeRect(offset, 0, size, b.size.height);
    [frames addObject:[NSValue valueWithRect:r]];
    offset += size + gap;
  }
  return frames;
}

// The split on screen is the split item that contains the shown tab.
- (void)syncSplitState {
  ArcItem* parent = _shown ? [self parentOfItem:_shown] : nil;
  if (parent.isSplit && parent.children.count > 1) {
    _splitGroup = parent;
    _splitItems = parent.children;
    _splitHorizontal = parent.splitHorizontal;
  } else {
    _splitGroup = nil;
    _splitItems = nil;
  }
}

- (ArcItem*)splitGroupOfShown { return _splitGroup; }
- (NSUInteger)dividerCount {
  NSUInteger n = 0;
  for (NSView* d in _dividers) n += !d.hidden;
  return n;
}

- (void)layoutDividers:(NSArray<NSValue*>*)frames {
  for (NSView* d in _dividers) [d removeFromSuperview];
  _dividers = [NSMutableArray array];
  for (NSUInteger i = 0; i + 1 < frames.count; ++i) {
    NSRect a = frames[i].rectValue, b = frames[i + 1].rectValue;
    NSRect r = _splitHorizontal ? NSMakeRect(0, NSMaxY(b), _content.bounds.size.width, NSMinY(a) - NSMaxY(b))
                                : NSMakeRect(NSMaxX(a), 0, NSMinX(b) - NSMaxX(a), _content.bounds.size.height);
    SplitDividerView* d = [[SplitDividerView alloc] initWithFrame:r];
    d.owner = self;
    d.index = i;
    d.horizontal = _splitHorizontal;
    [_content addSubview:d positioned:NSWindowAbove relativeTo:nil];
    [_dividers addObject:d];
  }
}

// Moves the boundary between pane index and index+1; each pane keeps at least 10%.
- (void)moveDivider:(NSUInteger)index toPosition:(CGFloat)position {
  NSUInteger n = _splitItems.count;
  if (!_splitGroup || index + 1 >= n) return;
  NSMutableArray<NSNumber*>* f = [NSMutableArray array];
  if (_splitGroup.splitFractions.count == n) [f addObjectsFromArray:_splitGroup.splitFractions];
  else for (NSUInteger i = 0; i < n; ++i) [f addObject:@(1.0 / n)];
  double before = 0;
  for (NSUInteger i = 0; i < index; ++i) before += f[i].doubleValue;
  double pair = f[index].doubleValue + f[index + 1].doubleValue;
  double left = MIN(MAX(position - before, 0.1), pair - 0.1);
  if (pair < 0.2) return;
  f[index] = @(left);
  f[index + 1] = @(pair - left);
  _splitGroup.splitFractions = f;
  [self layoutPanes];
  [self scheduleSave];
}

- (void)layoutPanes {
  [self syncSplitState];
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
  [self layoutDividers:panes.count > 1 ? frames : @[]];
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

// Wraps the tab in a split item at its place in the sidebar (Favorites can't hold splits).
- (ArcItem*)ensureSplitGroupFor:(ArcItem*)item {
  ArcItem* parent = [self parentOfItem:item];
  if (parent.isSplit) return parent;
  if (!parent || parent == _space.favorites) return nil;
  ArcItem* group = [ArcItem new];
  group.itemID = NSUUID.UUID.UUIDString;
  group.isSplit = YES;
  group.children = [NSMutableArray arrayWithObject:item];
  parent.children[[parent.children indexOfObject:item]] = group;
  return group;
}

// Takes a tab out of its split. keep: put it back in the sidebar right after the split (Arc's
// "Separate from Split View"); otherwise the caller removes it. A split left with one tab dissolves.
- (void)detachFromSplit:(ArcItem*)item keep:(BOOL)keep {
  ArcItem* group = [self parentOfItem:item];
  if (!group.isSplit) return;
  ArcItem* holder = [self parentOfItem:group];
  NSUInteger at = [holder.children indexOfObject:group];
  [group.children removeObject:item];
  group.splitFractions = nil;
  if (keep && holder) [holder.children insertObject:item atIndex:at + 1];
  if (group.children.count < 2 && holder) {
    if (group.children.count == 1) holder.children[at] = group.children.firstObject;
    else [holder.children removeObjectAtIndex:at];
  }
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self syncSplitState];
  [self scheduleSave];
}

- (void)paneFocused:(int)browserId {
  ArcItem* item = [self itemForBrowser:browserId];
  if (!item || item == _shown || ![_splitItems containsObject:item]) return;
  _shown.lastActiveAt = [NSDate date];
  _shown = item;
  item.lastActiveAt = [NSDate date];
  [self syncSplitState];
  [self selectSidebarRowFor:item];
}

- (void)beginSplit:(BOOL)horizontal {
  if (!_shown || _splitItems.count >= 4) {
    NSBeep();
    return;
  }
  _commandOpensLittle = NO;
  _splitBefore = NO;
  _pendingSplitHorizontal = horizontal;
  _commandOpensSplit = YES;
  [self showCommandBarForNewTab:YES];
}

- (IBAction)addVerticalSplit:(id)sender { [self beginSplit:NO]; }
- (IBAction)addHorizontalSplit:(id)sender { [self beginSplit:YES]; }

// The new pane is a normal Today tab placed next to the focused pane, like Arc.
- (void)openInSplit:(NSString*)input horizontal:(BOOL)horizontal {
  [self openInSplit:input horizontal:horizontal before:NO];
}

// The new pane is a normal Today tab placed beside the focused pane (after it for right/bottom, before it
// for left/top). The direction sets the layout of the whole split.
- (void)openInSplit:(NSString*)input horizontal:(BOOL)horizontal before:(BOOL)before {
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space || !_shown) return;
  [self syncSplitState];
  if (_splitItems.count >= 4) return;
  ArcItem* group = [self ensureSplitGroupFor:_shown];
  if (!group) {
    NSBeep();
    return;
  }
  group.splitHorizontal = horizontal;
  group.splitFractions = nil;
  ArcItem* tab = [ArcItem new];
  tab.itemID = NSUUID.UUID.UUIDString;
  tab.url = url;
  tab.children = [NSMutableArray array];
  NSUInteger at = [group.children indexOfObject:_shown] + (before ? 0 : 1);
  [group.children insertObject:tab atIndex:at];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  [self showItem:tab];
}

- (NSUInteger)indexOfShownInSplit { return [_splitItems indexOfObject:_shown]; }

- (IBAction)addLeftSplit:(id)sender {
  [self beginSplit:NO];
  _splitBefore = YES;
}
- (IBAction)addTopSplit:(id)sender {
  [self beginSplit:YES];
  _splitBefore = YES;
}
- (IBAction)flipSplitLayout:(id)sender {
  if (!_splitGroup) return;
  _splitGroup.splitHorizontal = !_splitGroup.splitHorizontal;
  [_outline reloadItem:_splitGroup];
  [self layoutPanes];
  [self scheduleSave];
}

// Removes the focused pane from the split; its tab stays in the sidebar.
- (IBAction)closeSplitPane:(id)sender {
  if (![_splitItems containsObject:_shown]) return;
  NSUInteger index = [_splitItems indexOfObject:_shown];
  NSArray<ArcItem*>* rest = [_splitItems filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock:^BOOL(ArcItem* t, NSDictionary*) { return t != self->_shown; }]];
  ArcItem* next = rest[MIN(index, rest.count - 1)];
  [self detachFromSplit:_shown keep:YES];
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

- (NSUInteger)archiveIdleLittleWindowsAt:(NSDate*)now {
  double hours = SettingDouble(kSettingLittleArchiveHours);
  if (hours <= 0) return 0;
  NSUInteger closed = 0;
  for (LittleWindowController* lw in [_littleWindows copy]) {
    if (lw.window.isKeyWindow || !lw.lastUsedAt) continue;
    if ([now timeIntervalSinceDate:lw.lastUsedAt] < hours * 3600) continue;
    [lw.window close];  // closing without moving archives the page
    ++closed;
  }
  return closed;
}

- (void)setLittleWindowLastUsed:(NSDate*)date index:(NSUInteger)index {
  if (index < _littleWindows.count) _littleWindows[index].lastUsedAt = date;
}
- (void)moveLittleWindowToMain:(NSUInteger)index {
  if (index < _littleWindows.count) [_littleWindows[index] openInMainWindow:nil];
}
- (void)closeLittleWindow:(NSUInteger)index {
  if (index < _littleWindows.count) [_littleWindows[index].window close];
}

- (BOOL)handleOpenURL:(NSString*)url fromBrowser:(int)browserId disposition:(int)disposition userGesture:(BOOL)gesture {
  if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) return NO;
  if (![self itemForBrowser:browserId]) return NO;  // e.g. from a Peek or Little Window: let CEF handle it
  __weak MainWindowController* weakSelf = self;
  if (disposition == CEF_WOD_NEW_WINDOW && gesture && !_peek && SettingBool(kSettingPeekShiftClick)) {
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openPeek:url]; });
    return YES;
  }
  BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
  dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openInNewTab:url background:background]; });
  return YES;
}

#pragma mark Peek

// "mail.google.com" and "docs.google.com" count as the same site; good enough without a public suffix list.
static NSString* SiteOf(NSString* url) {
  NSString* host = [NSURL URLWithString:url].host.lowercaseString;
  NSArray<NSString*>* parts = [host componentsSeparatedByString:@"."];
  if (parts.count < 2) return host;
  NSString* last2 = [[parts subarrayWithRange:NSMakeRange(parts.count - 2, 2)] componentsJoinedByString:@"."];
  // co.uk, com.au and similar: keep three labels.
  if (parts.count >= 3 && parts[parts.count - 2].length <= 3 && parts.lastObject.length == 2)
    return [[parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)] componentsJoinedByString:@"."];
  return last2;
}

- (BOOL)shouldPeekFromItem:(ArcItem*)item toURL:(NSString*)url {
  if (!item || !url.length || _peek || !SettingBool(kSettingPeekPinnedLinks)) return NO;
  if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) return NO;
  ArcSpace* space = [self spaceOwningItem:item];
  BOOL pinnedOrFavorite = Contains(space.pinned, item) || Contains(space.favorites, item);
  if (!pinnedOrFavorite) return NO;
  auto it = _browsers.find(item.browserId);
  NSString* current = it != _browsers.end()
                          ? [NSString stringWithUTF8String:it->second->GetMainFrame()->GetURL().ToString().c_str()]
                          : item.url;
  NSString* from = SiteOf(current), *to = SiteOf(url);
  return from.length && to.length && ![from isEqualToString:to];
}

- (void)openPeek:(NSString*)url {
  if (_peek || !_space) return;
  __weak MainWindowController* weakSelf = self;
  _peek = [[LittleWindowController alloc] initWithURL:url
      context:[self contextForSpace:_space]
      onMove:^(NSString* movedURL) { [weakSelf openInNewTab:movedURL]; }
      onClose:^(LittleWindowController*, NSString*, NSString*, BOOL) { [weakSelf peekClosed]; }];
  [_peek presentAsPeekOver:self.window];
}

- (void)peekClosed { _peek = nil; }
- (BOOL)isPeeking { return _peek != nil; }
- (void)promotePeekToTab { [_peek openInMainWindow:nil]; }
- (void)closePeek { [_peek.window close]; }

#pragma mark Spaces

static ArcItem* NewSection(NSString* title) {
  ArcItem* section = [ArcItem new];
  section.isSection = YES;
  section.title = title;
  section.children = [NSMutableArray array];
  return section;
}

- (void)rebuildSpacePicker {
  [_spacePicker removeAllItems];
  for (ArcSpace* s in _spaces) {
    [_spacePicker addItemWithTitle:s.title ?: @"Space"];
    _spacePicker.lastItem.representedObject = s;  // titles may repeat
  }
  if (_space) [_spacePicker selectItemAtIndex:[_spaces indexOfObject:_space]];
}

- (void)switchToSpace:(ArcSpace*)space {
  if (!space || space == _space) return;
  _space = space;
  _splitItems = nil;
  [_spacePicker selectItemAtIndex:[_spaces indexOfObject:space]];
  [self reloadSidebar];
  [self scheduleSave];
  ArcItem* first = _space.allTabs.firstObject;
  if (first) [self showItem:first];
  else {
    _shown = nil;
    [self layoutPanes];
  }
}

- (void)selectSpaceAtIndex:(NSUInteger)index {
  if (index < _spaces.count) [self switchToSpace:_spaces[index]];
}

- (NSArray<ArcSpace*>*)spaces { return _spaces; }
- (ArcSpace*)currentSpace { return _space; }

// A new Space shares the current Space's profile, so it starts signed in to the same accounts
// (and shows the same Favorites), like Arc's default.
- (ArcSpace*)createSpaceNamed:(NSString*)name {
  ArcSpace* space = [ArcSpace new];
  space.spaceID = NSUUID.UUID.UUIDString;
  space.title = name.length ? name : @"New Space";
  space.profileDirectory = _space.profileDirectory ?: @"Default";
  space.pinned = NewSection(@"Pinned");
  space.unpinned = NewSection(@"Today");
  for (ArcSpace* s in _spaces)
    if ([s.profileDirectory isEqualToString:space.profileDirectory] && s.favorites) space.favorites = s.favorites;
  NSUInteger at = _space ? [_spaces indexOfObject:_space] + 1 : _spaces.count;
  [_spaces insertObject:space atIndex:at];
  [self rebuildSpacePicker];
  [self switchToSpace:space];
  [self scheduleSave];
  return space;
}

- (void)renameSpace:(ArcSpace*)space to:(NSString*)name {
  if (!space || !name.length) return;
  space.title = name;
  [self rebuildSpacePicker];
  [self scheduleSave];
}

// Deleting a Space archives its Today and Pinned tabs (nothing is lost) and closes their web views.
- (BOOL)deleteSpace:(ArcSpace*)space {
  if (!space || _spaces.count < 2) return NO;
  NSUInteger index = [_spaces indexOfObject:space];
  if (index == NSNotFound) return NO;
  NSMutableArray<ArcItem*>* owned = [NSMutableArray array];
  NSMutableArray<ArcItem*>* stack = [NSMutableArray arrayWithObjects:space.pinned, space.unpinned, nil];
  while (stack.count) {
    ArcItem* item = stack.lastObject;
    [stack removeLastObject];
    if (item.url.length) [owned addObject:item];
    [stack addObjectsFromArray:item.children];
  }
  for (ArcItem* item in owned) {
    [self archiveItem:item space:space reason:@"spaceDeleted"];
    [self unloadItem:item];
  }
  [_spaces removeObjectAtIndex:index];
  if (space == _space) {
    _space = nil;
    _shown = nil;
    [self rebuildSpacePicker];
    [self switchToSpace:_spaces[MIN(index, _spaces.count - 1)]];
  } else {
    [self rebuildSpacePicker];
  }
  [self scheduleSave];
  return YES;
}

- (void)moveSpace:(ArcSpace*)space by:(NSInteger)delta {
  NSInteger from = [_spaces indexOfObject:space];
  NSInteger to = from + delta;
  if (from == NSNotFound || to < 0 || to >= (NSInteger)_spaces.count) return;
  [_spaces removeObjectAtIndex:from];
  [_spaces insertObject:space atIndex:to];
  [self rebuildSpacePicker];
  [self scheduleSave];
}

- (NSString*)askForSpaceName:(NSString*)message initial:(NSString*)initial {
  NSAlert* alert = [NSAlert new];
  alert.messageText = message;
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  field.stringValue = initial ?: @"";
  alert.accessoryView = field;
  alert.window.initialFirstResponder = field;
  if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
  return [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (IBAction)newSpace:(id)sender {
  NSString* name = [self askForSpaceName:@"New Space" initial:@""];
  if (name) [self createSpaceNamed:name];
}

- (IBAction)renameCurrentSpace:(id)sender {
  NSString* name = [self askForSpaceName:@"Rename Space" initial:_space.title];
  if (name.length) [self renameSpace:_space to:name];
}

- (IBAction)deleteCurrentSpace:(id)sender {
  if (_spaces.count < 2) {
    NSBeep();
    return;
  }
  NSAlert* alert = [NSAlert new];
  alert.messageText = [NSString stringWithFormat:@"Delete \u201c%@\u201d?", _space.title];
  alert.informativeText = @"Its tabs move to the Archive, so you can reopen them later.";
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.buttons.firstObject.hasDestructiveAction = YES;
  if ([alert runModal] == NSAlertFirstButtonReturn) [self deleteSpace:_space];
}

- (IBAction)moveSpaceUp:(id)sender { [self moveSpace:_space by:-1]; }
- (IBAction)moveSpaceDown:(id)sender { [self moveSpace:_space by:1]; }
- (IBAction)nextSpace:(id)sender {
  if (_spaces.count) [self selectSpaceAtIndex:([_spaces indexOfObject:_space] + 1) % _spaces.count];
}
- (IBAction)previousSpace:(id)sender {
  if (_spaces.count) [self selectSpaceAtIndex:([_spaces indexOfObject:_space] + _spaces.count - 1) % _spaces.count];
}
- (IBAction)selectSpaceFromMenu:(NSMenuItem*)sender { [self selectSpaceAtIndex:sender.tag]; }

#pragma mark Arc shortcuts

- (IBAction)toggleSidebar:(id)sender {
  BOOL hide = !_sidebar.hidden;
  _sidebar.hidden = hide;
  NSRect b = self.window.contentView.bounds;
  CGFloat x = hide ? 0 : kSidebarWidth;
  _content.frame = NSMakeRect(x, 0, b.size.width - x, b.size.height);
  [self layoutPanes];
}
- (BOOL)sidebarHidden { return _sidebar.hidden; }

- (IBAction)toggleFocusMode:(id)sender {
  _focusMode = !_focusMode;
  if (_focusMode) {
    _sidebarWasHidden = _sidebar.hidden;
    if (!_sidebar.hidden) [self toggleSidebar:nil];
  } else if (_sidebar.hidden && !_sidebarWasHidden) {
    [self toggleSidebar:nil];
  }
  for (NSWindowButton b : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton})
    [self.window standardWindowButton:b].hidden = _focusMode;
}
- (ArcItem*)shownItem { return _shown; }

- (void)selectTabAtIndex:(NSUInteger)index {
  NSArray<ArcItem*>* tabs = _space.allTabs;
  if (index == 8 && tabs.count) index = tabs.count - 1;  // Cmd+9 = last item, as in Arc and Chrome
  if (index < tabs.count) [self showItem:tabs[index]];
}

- (IBAction)switchToRecentTab:(id)sender {
  ArcItem* best = nil;
  for (ArcItem* t in _space.allTabs) {
    if (t == _shown || !t.lastActiveAt) continue;
    if (!best || [t.lastActiveAt compare:best.lastActiveAt] == NSOrderedDescending) best = t;
  }
  if (best) [self showItem:best];
}

- (IBAction)pasteAndGo:(id)sender {
  NSString* text = [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (text.length) [self openInNewTab:text];
}

- (IBAction)printPage:(id)sender {
  if (auto b = [self currentBrowser]) b->GetHost()->Print();
}
- (IBAction)selectTabFromMenu:(NSMenuItem*)sender { [self selectTabAtIndex:sender.tag]; }

- (void)stepTab:(NSInteger)delta {
  NSArray<ArcItem*>* tabs = _space.allTabs;
  if (!tabs.count) return;
  NSInteger i = _shown ? (NSInteger)[tabs indexOfObject:_shown] : -1;
  if (i == NSNotFound) i = -1;
  i = (i + delta + (NSInteger)tabs.count) % (NSInteger)tabs.count;
  [self showItem:tabs[i]];
}
- (IBAction)nextTab:(id)sender { [self stepTab:1]; }
- (IBAction)previousTab:(id)sender { [self stepTab:-1]; }

// Archives every Today tab in the current Space (Arc: "Clear unpinned tabs").
- (IBAction)clearToday:(id)sender {
  for (ArcItem* item in [_space.unpinned.children copy]) {
    if (item.isFolder) continue;
    if (item.isSplit) {
      for (ArcItem* pane in item.children) {
        [self archiveItem:pane space:_space reason:@"manual"];
        [self unloadItem:pane];
        if (pane == _shown) _shown = nil;
      }
      [_space.unpinned.children removeObject:item];
      continue;
    }
    [self archiveItem:item space:_space reason:@"manual"];
    [self unloadItem:item];
    [_space.unpinned.children removeObject:item];
    if (item == _shown) _shown = nil;
  }
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  if (!_shown) {
    ArcItem* first = _space.allTabs.firstObject;
    if (first) [self showItem:first];
    else [self layoutPanes];
  }
}

- (IBAction)focusPaneFromMenu:(NSMenuItem*)sender {
  if (![_splitItems containsObject:_shown] || (NSUInteger)sender.tag >= _splitItems.count) return;
  [self showItem:_splitItems[sender.tag]];
  if (auto b = [self currentBrowser]) b->GetHost()->SetFocus(true);
}

// Arc closes Peek when you click outside it.
- (void)windowDidBecomeKey:(NSNotification*)note {
  if (note.object == self.window && _peek) [_peek.window close];
}

#pragma mark Context menus

- (void)handleLinkCommand:(int)command url:(NSString*)url fromBrowser:(int)browserId {
  if (!url.length) return;
  switch (command) {
    case BrowserClient::kLinkNewTab: [self openInNewTab:url]; break;
    case BrowserClient::kLinkBackgroundTab: [self openInNewTab:url background:YES]; break;
    case BrowserClient::kLinkSplit: {
      ArcItem* from = [self itemForBrowser:browserId];
      if (from && from != _shown) [self showItem:from];
      [self openInSplit:url horizontal:NO before:NO];
      break;
    }
    case BrowserClient::kLinkPeek: [self openPeek:url]; break;
    case BrowserClient::kLinkLittle: [self openLittleWindow:url]; break;
    case BrowserClient::kLinkCopyMarkdown: {
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"[%@](%@)", url, url]
                                        forType:NSPasteboardTypeString];
      break;
    }
  }
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  if (menu != _outline.menu) return;
  [menu removeAllItems];
  ArcItem* item = _outline.clickedRow >= 0 ? [_outline itemAtRow:_outline.clickedRow] : nil;
  NSMenu* built = item ? [self sidebarMenuForItem:item] : nil;
  for (NSMenuItem* mi in [built.itemArray copy]) {
    [built removeItem:mi];
    [menu addItem:mi];
  }
}

- (NSMenuItem*)menuItem:(NSString*)title action:(SEL)action item:(ArcItem*)item {
  NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  mi.target = self;
  mi.representedObject = item;
  return mi;
}

- (NSMenu*)sidebarMenuForItem:(ArcItem*)item {
  NSMenu* m = [[NSMenu alloc] initWithTitle:@"Sidebar"];
  if (!item || item.isSection) return m;
  ArcItem* section = [self sectionContaining:item];
  BOOL isToday = section == _space.unpinned, isPinned = section == _space.pinned;
  BOOL isTab = item.url.length > 0;
  if (isTab || item.isSplit) [m addItem:[self menuItem:@"Open" action:@selector(menuOpen:) item:item]];
  if (isTab) {
    [m addItem:[self menuItem:@"Open in Split View" action:@selector(menuOpenInSplit:) item:item]];
    [m addItem:[self menuItem:@"Open in Little Window" action:@selector(menuOpenLittle:) item:item]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self menuItem:@"Copy URL" action:@selector(menuCopyURL:) item:item]];
    [m addItem:[self menuItem:@"Copy URL as Markdown" action:@selector(menuCopyMarkdown:) item:item]];
  }
  [m addItem:[NSMenuItem separatorItem]];
  if (isTab || item.isFolder) [m addItem:[self menuItem:@"Rename..." action:@selector(menuRename:) item:item]];
  if (isTab) [m addItem:[self menuItem:@"Duplicate" action:@selector(menuDuplicate:) item:item]];
  if (isToday) [m addItem:[self menuItem:@"Pin" action:@selector(menuTogglePin:) item:item]];
  if (isPinned && [_space.pinned.children containsObject:item])
    [m addItem:[self menuItem:@"Unpin" action:@selector(menuTogglePin:) item:item]];
  if (!isToday && item.pinnedURL.length) {
    [m addItem:[self menuItem:@"Reset to Pinned URL" action:@selector(menuResetPinned:) item:item]];
    [m addItem:[self menuItem:@"Replace Pinned URL with Current" action:@selector(menuReplacePinned:) item:item]];
  }
  if ((isToday || isPinned) && _spaces.count > 1) {
    NSMenuItem* move = [[NSMenuItem alloc] initWithTitle:@"Move to" action:nil keyEquivalent:@""];
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Move to"];
    for (ArcSpace* sp in _spaces) {
      if (sp == _space) continue;
      for (int pinned = 0; pinned < 2; ++pinned) {
        NSMenuItem* mi = [self menuItem:[NSString stringWithFormat:@"%@ in %@", pinned ? @"Pinned" : @"Today", sp.title]
                                 action:@selector(menuMoveToSpace:) item:item];
        mi.representedObject = @[ item, sp, @(pinned) ];
        [sub addItem:mi];
      }
    }
    move.submenu = sub;
    [m addItem:move];
  }
  if (isToday && [_space.unpinned.children containsObject:item]) {
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self menuItem:@"Archive Other Tabs" action:@selector(menuArchiveOthers:) item:item]];
    [m addItem:[self menuItem:@"Archive Tabs Above" action:@selector(menuArchiveAbove:) item:item]];
    [m addItem:[self menuItem:@"Archive Tabs Below" action:@selector(menuArchiveBelow:) item:item]];
  }
  if (isTab) {
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self menuItem:isToday ? @"Archive Tab" : @"Close and Keep Pinned" action:@selector(menuClose:) item:item]];
  }
  return m;
}

- (void)menuOpen:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  [self showItem:item.isSplit ? item.children.firstObject : item];
}
- (void)menuOpenInSplit:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  if (!_shown || item == _shown) return;
  [self openInSplit:item.url horizontal:NO before:NO];
}
- (void)menuOpenLittle:(NSMenuItem*)sender { [self openLittleWindow:((ArcItem*)sender.representedObject).url]; }
- (void)menuCopyURL:(NSMenuItem*)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:((ArcItem*)sender.representedObject).url forType:NSPasteboardTypeString];
}
- (void)menuCopyMarkdown:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  NSString* title = [item.displayTitle stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"[%@](%@)", title, item.url]
                                    forType:NSPasteboardTypeString];
}
- (void)menuRename:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  NSString* name = [self askForSpaceName:@"Rename" initial:item.displayTitle];
  if (name.length) [self renameItem:item to:name];
}
- (void)menuDuplicate:(NSMenuItem*)sender { [self duplicateItem:sender.representedObject]; }
- (void)menuTogglePin:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  if ([self sectionContaining:item] == _space.unpinned) {
    [self moveItem:item toParent:_space.pinned index:_space.pinned.children.count];
    [self markPinnedURLs:item];
  } else {
    [self moveItem:item toParent:_space.unpinned index:0];
    [self clearPinnedURLs:item];
  }
}
- (void)menuMoveToSpace:(NSMenuItem*)sender {
  NSArray* args = sender.representedObject;
  [self moveItem:args[0] toSpace:args[1] pinned:[args[2] boolValue]];
}
- (void)menuArchiveOthers:(NSMenuItem*)sender { [self archiveTodayTabsRelativeTo:sender.representedObject mode:0]; }
- (void)menuArchiveAbove:(NSMenuItem*)sender { [self archiveTodayTabsRelativeTo:sender.representedObject mode:1]; }
- (void)menuArchiveBelow:(NSMenuItem*)sender { [self archiveTodayTabsRelativeTo:sender.representedObject mode:2]; }
- (void)menuResetPinned:(NSMenuItem*)sender { [self resetPinnedItem:sender.representedObject]; }
- (void)menuReplacePinned:(NSMenuItem*)sender { [self replacePinnedURLWithCurrent:sender.representedObject]; }
- (void)menuClose:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  if (item != _shown) [self showItem:item];
  [self closeCurrentTab];
}

// A user rename overrides the page title in the sidebar (Arc: "Rename Current Tab").
- (void)renameItem:(ArcItem*)item to:(NSString*)title {
  if (!item || !title.length) return;
  item.title = title;
  item.liveTitle = nil;
  [_outline reloadItem:item];
  [self scheduleSave];
}

// The copy goes right below the original in Today (a pinned tab's copy goes to the top of Today).
- (ArcItem*)duplicateItem:(ArcItem*)item {
  if (!item.url.length || !_space) return nil;
  ArcItem* copy = [ArcItem new];
  copy.itemID = NSUUID.UUID.UUIDString;
  copy.url = [self itemCurrentURL:item];
  copy.liveTitle = item.liveTitle;
  copy.title = item.title;
  copy.children = [NSMutableArray array];
  ArcItem* parent = [self parentOfItem:item];
  if (parent.isSplit) {
    item = parent;
    parent = [self parentOfItem:parent];
  }
  if ([self sectionContaining:item] == _space.unpinned && parent)
    [parent.children insertObject:copy atIndex:[parent.children indexOfObject:item] + 1];
  else
    [_space.unpinned.children insertObject:copy atIndex:0];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  [self showItem:copy];
  return copy;
}

- (NSString*)itemCurrentURL:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return item.url;
  std::string url = it->second->GetMainFrame()->GetURL().ToString();
  return url.empty() ? item.url : [NSString stringWithUTF8String:url.c_str()];
}

- (NSUInteger)archiveTodayTabsRelativeTo:(ArcItem*)item mode:(int)mode {
  NSMutableArray<ArcItem*>* today = _space.unpinned.children;
  NSUInteger index = [today indexOfObject:item];
  if (index == NSNotFound) return 0;
  NSMutableArray<ArcItem*>* victims = [NSMutableArray array];
  for (NSUInteger i = 0; i < today.count; ++i) {
    ArcItem* t = today[i];
    if (t == item || t.isFolder) continue;
    if ((mode == 1 && i > index) || (mode == 2 && i < index)) continue;
    [victims addObject:t];
  }
  for (ArcItem* t in victims) {
    NSArray<ArcItem*>* tabs = t.isSplit ? [t.children copy] : @[ t ];
    for (ArcItem* tab in tabs) {
      [self archiveItem:tab space:_space reason:@"manual"];
      [self unloadItem:tab];
    }
    [today removeObject:t];
  }
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  if (![_space.allTabs containsObject:_shown]) {
    _shown = nil;
    [self showItem:item.isSplit ? item.children.firstObject : item];
  } else {
    [self layoutPanes];
  }
  return victims.count;
}

// Moving to another Space changes the profile, so the tab reloads there (Arc does the same).
- (BOOL)moveItem:(ArcItem*)item toSpace:(ArcSpace*)space pinned:(BOOL)pinned {
  if (!item || !space || space == _space || item.isSection) return NO;
  ArcItem* parent = [self parentOfItem:item];
  if (parent.isSplit) [self detachFromSplit:item keep:YES];
  BOOL removed = NO;
  for (ArcItem* section in [self sectionsOfSpace:_space]) removed = removed || RemoveItem(section, item);
  if (!removed) return NO;
  NSMutableArray<ArcItem*>* stack = [NSMutableArray arrayWithObject:item];
  while (stack.count) {
    ArcItem* t = stack.lastObject;
    [stack removeLastObject];
    if (t == _shown) _shown = nil;
    [self unloadItem:t];
    [stack addObjectsFromArray:t.children];
  }
  ArcItem* target = pinned ? space.pinned : space.unpinned;
  [target.children insertObject:item atIndex:pinned ? target.children.count : 0];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  if (!_shown) {
    ArcItem* first = _space.allTabs.firstObject;
    if (first) [self showItem:first];
    else [self layoutPanes];
  }
  return YES;
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
    else if (_commandOpensSplit) [self openInSplit:text horizontal:_pendingSplitHorizontal before:_splitBefore];
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

- (void)openInNewTab:(NSString*)input background:(BOOL)background {
  if (!background) {
    [self openInNewTab:input];
    return;
  }
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space) return;
  ArcItem* tab = [ArcItem new];
  tab.itemID = NSUUID.UUID.UUIDString;
  tab.url = url;
  tab.children = [NSMutableArray array];
  tab.lastActiveAt = [NSDate date];
  [_space.unpinned.children insertObject:tab atIndex:0];
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];  // the web view is created when the tab is first shown
}

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
  // A closed pinned pane stays pinned (unloaded) next to its split; a Today pane is archived.
  if ([self parentOfItem:item].isSplit) [self detachFromSplit:item keep:!isToday];
  if (isToday) [self archiveItem:item space:_space reason:@"manual"];  // Arc archives closed Today tabs
  [self unloadItem:item];
  // Close and Keep Pinned: the tab stays and reopens at its saved URL.
  if (!isToday && item.pinnedURL.length) {
    item.url = item.pinnedURL;
    item.liveTitle = nil;
  }
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
  if (_shown) [self selectSidebarRowFor:_shown];
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
  ArcItem* item = _splitGroup ?: _shown;  // pinning a split pins the whole split
  if (!item) return;
  ArcItem* section = [self sectionContaining:item];
  if (section == _space.unpinned) {
    [self moveItem:item toParent:_space.pinned index:_space.pinned.children.count];
    [self markPinnedURLs:item];
  } else if (section == _space.pinned) {
    [self moveItem:item toParent:_space.unpinned index:0];
    [self clearPinnedURLs:item];
  }
}

- (void)markPinnedURLs:(ArcItem*)item {
  if (item.url.length) item.pinnedURL = [self itemCurrentURL:item];
  for (ArcItem* c in item.children) [self markPinnedURLs:c];
}
- (void)clearPinnedURLs:(ArcItem*)item {
  item.pinnedURL = nil;
  for (ArcItem* c in item.children) [self clearPinnedURLs:c];
}

- (BOOL)isPinnedItem:(ArcItem*)item {
  ArcItem* section = [self sectionContaining:item];
  return section && section != _space.unpinned;
}

- (void)resetPinnedItem:(ArcItem*)item {
  if (!item.pinnedURL.length) return;
  item.url = item.pinnedURL;
  item.liveTitle = nil;
  auto it = _browsers.find(item.browserId);
  if (it != _browsers.end()) it->second->GetMainFrame()->LoadURL(item.pinnedURL.UTF8String);
  [_outline reloadItem:item];
  [self scheduleSave];
}

- (void)replacePinnedURLWithCurrent:(ArcItem*)item {
  if (![self isPinnedItem:item] || !item.url.length) return;
  item.pinnedURL = [self itemCurrentURL:item];
  [self scheduleSave];
}

- (NSUInteger)resetPinnedTabsInSpace {
  NSUInteger n = 0;
  for (ArcItem* t in _space.allTabs) {
    if (![self isPinnedItem:t] || !t.pinnedURL.length) continue;
    if ([[self itemCurrentURL:t] isEqualToString:t.pinnedURL] && [t.url isEqualToString:t.pinnedURL]) continue;
    if (t == _shown) {
      [self resetPinnedItem:t];
    } else {
      [self unloadItem:t];
      t.url = t.pinnedURL;
      t.liveTitle = nil;
    }
    ++n;
  }
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  if (_shown) [self selectSidebarRowFor:_shown];
  [self scheduleSave];
  return n;
}

- (IBAction)resetPinnedTab:(id)sender { if (_shown) [self resetPinnedItem:_shown]; }
- (IBAction)replacePinnedURL:(id)sender { if (_shown) [self replacePinnedURLWithCurrent:_shown]; }
- (IBAction)resetAllPinnedTabs:(id)sender { [self resetPinnedTabsInSpace]; }

- (BOOL)validateMenuItem:(NSMenuItem*)mi {
  if (mi.action == @selector(resetPinnedTab:) || mi.action == @selector(replacePinnedURL:))
    return _shown && [self isPinnedItem:_shown] && _shown.pinnedURL.length;
  return YES;
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
    [weakSelf archiveIdleLittleWindowsAt:[NSDate date]];
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
      _splitItems = nil;
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

- (HistoryStore*)historyStore {
  if (!_history && self.historyPath) _history = [[HistoryStore alloc] initWithPath:self.historyPath];
  return _history;
}

- (NSArray<ArchivedTab*>*)historyVisits { return [self historyStore].visits ?: @[]; }

- (IBAction)showHistory:(id)sender {
  if (!_historyWindow) {
    __weak MainWindowController* weakSelf = self;
    _historyWindow = [[ArchiveWindowController alloc]
        initWithProvider:^NSArray<ArchivedTab*>* { return [weakSelf historyVisits]; }
                  reopen:^(ArchivedTab* visit) { [weakSelf openInNewTab:visit.url]; }];
    _historyWindow.baseTitle = @"History";
    [_historyWindow setPlaceholder:@"Search history" dateHeader:@"Visited" reasonHeader:@"Space"];
  }
  [_historyWindow reload];
  [_historyWindow showWindow:nil];
}

- (std::vector<CefRefPtr<CefRequestContext>>)allContexts {
  std::vector<CefRefPtr<CefRequestContext>> out;
  for (auto& kv : _contexts) out.push_back(kv.second);
  if (auto g = CefRequestContext::GetGlobalContext()) out.push_back(g);
  return out;
}

- (void)clearBrowsingDataSince:(NSDate*)since history:(BOOL)history cookies:(BOOL)cookies cache:(BOOL)cache
                          done:(void (^)(NSUInteger, NSUInteger))done {
  NSUInteger historyRemoved = 0;
  if (history) {
    historyRemoved = since ? [[self historyStore] clearSince:since] : [self historyStore].visits.count;
    if (!since) [[self historyStore] clear];
    [_historyWindow reload];
  }
  auto contexts = [self allContexts];
  dispatch_group_t group = dispatch_group_create();
  __block NSUInteger cookiesRemoved = 0;
  double sinceUnix = since ? since.timeIntervalSince1970 : 0;
  for (auto& ctx : contexts) {
    if (cookies) {
      if (auto mgr = ctx->GetCookieManager(nullptr)) {
        dispatch_group_enter(group);
        BOOL started = mgr->VisitAllCookies(new MatchCookieVisitor(mgr,
            [sinceUnix](const CefCookie& c) { return sinceUnix == 0 || CookieCreatedUnix(c) >= sinceUnix - 1; }, true,
            ^(NSUInteger n) {
              cookiesRemoved += n;
              dispatch_group_leave(group);
            }));
        if (!started) dispatch_group_leave(group);
      }
    }
    if (cache) {
      dispatch_group_enter(group);
      ctx->ClearHttpCache(new BlockCompletion(^{ dispatch_group_leave(group); }));
    }
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    if (done) done(historyRemoved, cookiesRemoved);
  });
}

- (IBAction)clearBrowsingData:(id)sender {
  NSAlert* a = [NSAlert new];
  a.messageText = @"Clear Browsing Data";
  a.informativeText = @"Applies to every Space. Your tabs, Spaces and Archive are not affected.";
  NSView* box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 110)];
  NSPopUpButton* range = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 82, 220, 26) pullsDown:NO];
  NSArray* titles = @[ @"Last hour", @"Last 24 hours", @"Last 7 days", @"Last 4 weeks", @"All time" ];
  NSArray* secs = @[ @3600, @86400, @604800, @2419200, @0 ];
  [range addItemsWithTitles:titles];
  for (NSUInteger i = 0; i < titles.count; ++i) [range itemAtIndex:i].tag = [secs[i] integerValue];
  [range selectItemAtIndex:4];
  NSButton* hist = [NSButton checkboxWithTitle:@"Browsing history" target:nil action:nil];
  NSButton* cook = [NSButton checkboxWithTitle:@"Cookies (signs you out of sites)" target:nil action:nil];
  NSButton* cach = [NSButton checkboxWithTitle:@"Cached images and files (all time)" target:nil action:nil];
  hist.frame = NSMakeRect(0, 56, 300, 20);
  cook.frame = NSMakeRect(0, 30, 300, 20);
  cach.frame = NSMakeRect(0, 4, 300, 20);
  hist.state = NSControlStateValueOn;
  cach.state = NSControlStateValueOn;
  for (NSView* v in @[ range, hist, cook, cach ]) [box addSubview:v];
  a.accessoryView = box;
  [a addButtonWithTitle:@"Clear Data"];
  [a addButtonWithTitle:@"Cancel"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSInteger s = range.selectedItem.tag;
  [self clearBrowsingDataSince:s ? [NSDate dateWithTimeIntervalSinceNow:-s] : nil
                       history:hist.state == NSControlStateValueOn
                       cookies:cook.state == NSControlStateValueOn
                         cache:cach.state == NSControlStateValueOn
                          done:nil];
}

- (void)clearCookiesAndRefreshWithDone:(void (^)(NSUInteger))done {
  CefRefPtr<CefBrowser> b = [self currentBrowser];
  if (!b) {
    if (done) done(0);
    return;
  }
  std::string url = b->GetMainFrame()->GetURL().ToString();
  std::string host = HostOf(url);
  if (getenv("NOTARC_COOKIE_DEBUG"))
    fprintf(stderr, "COOKIE-CLEARSITE url=%s shown=%s\n", url.c_str(), _shown.url.UTF8String ?: "-");
  NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
  if (host.empty() || !([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"])) {
    if (done) done(0);
    return;
  }
  // Site storage (localStorage, IndexedDB, service workers, cache storage) for this origin.
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  NSString* origin = [NSString stringWithFormat:@"%@://%@%@", u.scheme, u.host, u.port ? [NSString stringWithFormat:@":%@", u.port] : @""];
  params->SetString("origin", origin.UTF8String);
  params->SetString("storageTypes", "local_storage,indexeddb,websql,cache_storage,service_workers,file_systems,shader_cache");
  b->GetHost()->ExecuteDevToolsMethod(0, "Storage.clearDataForOrigin", params);
  auto mgr = b->GetHost()->GetRequestContext()->GetCookieManager(nullptr);
  void (^finish)(NSUInteger) = ^(NSUInteger n) {
    b->Reload();
    if (done) done(n);
  };
  if (!mgr || !mgr->VisitAllCookies(new MatchCookieVisitor(mgr,
                  [host](const CefCookie& c) { return CookieBelongsToHost(c, host); }, true, finish)))
    finish(0);
}

- (IBAction)clearCookiesAndRefresh:(id)sender { [self clearCookiesAndRefreshWithDone:nil]; }

- (void)selfTestSetCookie:(NSString*)url name:(NSString*)name done:(void (^)(void))done {
  CefRefPtr<CefBrowser> b = [self currentBrowser];
  auto mgr = b ? b->GetHost()->GetRequestContext()->GetCookieManager(nullptr) : nullptr;
  if (!mgr) return done();
  CefCookie c;
  CefString(&c.name) = name.UTF8String;
  CefString(&c.value) = "1";
  CefString(&c.path) = "/";
  c.secure = [url hasPrefix:@"https"];
  c.has_expires = true;
  c.expires.val = (int64_t)(([NSDate dateWithTimeIntervalSinceNow:3600].timeIntervalSince1970 + 11644473600.0) * 1e6);
  if (!mgr->SetCookie(url.UTF8String, c, new BlockSetCookie(done))) done();
}

- (void)selfTestCountCookiesNamed:(NSString*)name done:(void (^)(NSUInteger))done {
  CefRefPtr<CefBrowser> b = [self currentBrowser];
  auto mgr = b ? b->GetHost()->GetRequestContext()->GetCookieManager(nullptr) : nullptr;
  std::string n = name.UTF8String;
  if (!mgr || !mgr->VisitAllCookies(new MatchCookieVisitor(mgr,
                  [n](const CefCookie& c) { return CefString(&c.name).ToString() == n; }, false, done)))
    done(0);
}

- (IBAction)clearHistory:(id)sender {
  if (sender) {
    NSAlert* a = [NSAlert new];
    a.messageText = @"Clear all browsing history?";
    a.informativeText = @"Your tabs, Spaces and Archive are not affected.";
    [a addButtonWithTitle:@"Clear History"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
  }
  [[self historyStore] clear];
  [_historyWindow reload];
}

- (NSUInteger)historyWindowCountForQuery:(NSString*)query {
  [self showHistory:nil];
  [_historyWindow setQuery:query];
  return _historyWindow.visibleCount;
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
  [_peek.window close];
  [_archiveTimer invalidate];
  [_archiveWindow close];
  [self saveSidebarNow];
  [_content removeFromSuperview];
  _content = nil;
  _browsers.clear();
  if (!_client || _client->open_browser_count() == 0) CefQuitMessageLoop();
}

@end
