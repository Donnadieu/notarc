#import "app/extension_popup.h"

#import <QuartzCore/QuartzCore.h>

#import "app/chrome_page.h"

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_display_handler.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"

const NSSize kExtensionPopupMinSize = {25, 25};
const NSSize kExtensionPopupMaxSize = {800, 600};

NSSize ExtensionPopupClampSize(NSSize s) {
  return NSMakeSize(MIN(kExtensionPopupMaxSize.width, MAX(kExtensionPopupMinSize.width, ceil(s.width))),
                    MIN(kExtensionPopupMaxSize.height, MAX(kExtensionPopupMinSize.height, ceil(s.height))));
}

NSRect ExtensionPopupFrame(NSRect anchor, NSSize size, NSRect bounds) {
  const CGFloat margin = 8, gap = 4;
  NSRect inner = NSInsetRect(bounds, margin, margin);
  CGFloat w = MIN(size.width, MAX(1, inner.size.width)), h = MIN(size.height, MAX(1, inner.size.height));
  CGFloat x = NSMinX(anchor), y = NSMinY(anchor) - gap - h;
  if (x + w > NSMaxX(inner)) x = NSMaxX(inner) - w;
  if (x < NSMinX(inner)) x = NSMinX(inner);
  if (y < NSMinY(inner)) y = NSMinY(inner);
  if (y + h > NSMaxY(inner)) y = NSMaxY(inner) - h;
  return NSMakeRect(round(x), round(y), w, h);
}

@interface ExtensionPopup ()
- (void)pageAutoResized:(NSSize)size;
- (void)pageMeasured:(NSSize)size;
- (void)pageLoaded:(NSString*)url;
- (void)pageFailed;
- (void)pageTitle:(NSString*)title;
- (void)pageClosed;
- (void)pageWantsURL:(NSString*)url;
@end

namespace {

// Which bubble each popup browser belongs to. One client serves every bubble in every window, so callbacks look the
// bubble up by browser id (the same pattern as the tabs' gBrowserOwners).
NSMapTable<NSNumber*, ExtensionPopup*>* gPopupOwners;
ExtensionPopup* PopupOwnerOf(CefRefPtr<CefBrowser> browser) {
  return browser ? [gPopupOwners objectForKey:@(browser->GetIdentifier())] : nil;
}
NSString* Str(const CefString& s) { return [NSString stringWithUTF8String:s.ToString().c_str()] ?: @""; }

const char kSizePrefix[] = "__notarc_popup_size__:";

// Fallback when Chromium's auto-resize doesn't report: the page's own size at its natural width (capped at Chrome's
// maximum), measured on load and again whenever the body changes size.
NSString* const kMeasureJS =
    @"(function(){if(window.__notarcPopupSize)return;window.__notarcPopupSize=1;var last='';"
     "function m(){var d=document.documentElement;if(!d)return;var s=d.getAttribute('style');"
     "d.style.setProperty('width','max-content','important');d.style.setProperty('max-width','800px','important');"
     "var r=d.getBoundingClientRect();if(s===null)d.removeAttribute('style');else d.setAttribute('style',s);"
     "var t=Math.ceil(r.width)+':'+Math.ceil(r.height);if(t!==last){last=t;console.log('__notarc_popup_size__:'+t);}}"
     "m();if(window.ResizeObserver&&document.body){var q=0;new ResizeObserver(function(){if(q)return;q=1;"
     "requestAnimationFrame(function(){q=0;m();});}).observe(document.body);}})();";

class PopupClient : public CefClient, public CefLifeSpanHandler, public CefLoadHandler, public CefDisplayHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }

  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int, const CefString& target_url,
                     const CefString&, WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo&,
                     CefRefPtr<CefClient>&, CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    [PopupOwnerOf(browser) pageWantsURL:Str(target_url)];
    return true;  // never a bare Chromium window: links open as NotArc tabs
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    ExtensionPopup* owner = PopupOwnerOf(browser);
    [gPopupOwners removeObjectForKey:@(browser->GetIdentifier())];
    dispatch_async(dispatch_get_main_queue(), ^{ [owner pageClosed]; });  // window.close(), or our own close
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
    if (!frame->IsMain()) return;
    frame->ExecuteJavaScript(kMeasureJS.UTF8String, frame->GetURL(), 0);
    [PopupOwnerOf(browser) pageLoaded:Str(frame->GetURL())];
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString&,
                   const CefString&) override {
    if (frame->IsMain() && code != ERR_ABORTED) [PopupOwnerOf(browser) pageFailed];
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    [PopupOwnerOf(browser) pageTitle:Str(title)];
  }
  bool OnAutoResize(CefRefPtr<CefBrowser> browser, const CefSize& size) override {
    ExtensionPopup* owner = PopupOwnerOf(browser);
    if (!owner) return false;
    [owner pageAutoResized:NSMakeSize(size.width, size.height)];
    return true;
  }
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t, const CefString& message, const CefString&,
                        int) override {
    std::string m = message.ToString();
    if (m.rfind(kSizePrefix, 0) != 0) return false;
    int w = 0, h = 0;
    if (std::sscanf(m.c_str() + sizeof(kSizePrefix) - 1, "%d:%d", &w, &h) == 2)
      [PopupOwnerOf(browser) pageMeasured:NSMakeSize(w, h)];
    return true;
  }
  IMPLEMENT_REFCOUNTING(PopupClient);
};

CefRefPtr<PopupClient> SharedPopupClient() {
  static CefRefPtr<PopupClient> client = new PopupClient();
  return client;
}

}  // namespace

@implementation ExtensionPopup {
  ChromePageHost* _host;
  NSView* _container;
  __weak NSWindow* _parent;
  __weak NSView* _anchor;
  NSRect _anchorRect;  // screen coordinates, taken when the bubble opens
  BOOL _hidden;
  BOOL _shown;
  BOOL _closing;
  BOOL _autoResized;
  id _eventMonitor;
  NSMutableArray* _observers;
}

- (instancetype)initWithURL:(NSString*)url
                    context:(CefRefPtr<CefRequestContext>)context
                     parent:(NSWindow*)parent
                     anchor:(NSView*)anchor
                     hidden:(BOOL)hidden {
  if (!(self = [super init])) return nil;
  _url = [url copy];
  _parent = parent;
  _anchor = anchor;
  _hidden = hidden;
  _observers = [NSMutableArray array];
  NSView* a = anchor.window == parent && !anchor.isHiddenOrHasHiddenAncestor ? anchor : nil;
  NSRect content = [parent contentRectForFrameRect:parent.frame];
  _anchorRect = a ? [parent convertRectToScreen:[a convertRect:a.bounds toView:nil]]
                  : NSMakeRect(NSMinX(content) + 8, NSMaxY(content) - 48, 30, 30);  // no picker button on screen

  _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, kExtensionPopupMinSize.width, kExtensionPopupMinSize.height)
                                      styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                        backing:NSBackingStoreBuffered
                                          defer:NO];
  _panel.releasedWhenClosed = NO;
  _panel.opaque = NO;
  _panel.backgroundColor = NSColor.clearColor;
  _panel.hasShadow = YES;
  _panel.becomesKeyOnlyIfNeeded = YES;
  _panel.hidesOnDeactivate = NO;
  _panel.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
  if (hidden) {  // self-test: as invisible and click-through as the hidden test window
    _panel.alphaValue = parent.alphaValue;
    _panel.ignoresMouseEvents = YES;
  }
  NSVisualEffectView* bg = [[NSVisualEffectView alloc] initWithFrame:_panel.contentView.bounds];
  bg.material = NSVisualEffectMaterialPopover;
  bg.state = NSVisualEffectStateActive;
  bg.wantsLayer = YES;
  bg.layer.cornerRadius = 10;
  bg.layer.cornerCurve = kCACornerCurveContinuous;
  bg.layer.masksToBounds = YES;
  _panel.contentView = bg;

  // The page is built in a view that isn't in any window yet, so its window stays off screen (and, in tests, is
  // made invisible) before the bubble is placed.
  _container = [[NSView alloc] initWithFrame:bg.bounds];
  _container.wantsLayer = YES;
  _container.layer.cornerRadius = 10;
  _container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _host = [[ChromePageHost alloc] initWithClient:SharedPopupClient() url:url context:context hostView:_container];
  CefRefPtr<CefBrowser> browser = _host.browser;
  if (!browser) {
    [_host close];
    _host = nil;
    return nil;
  }
  if (!gPopupOwners) gPopupOwners = [NSMapTable strongToWeakObjectsMapTable];
  [gPopupOwners setObject:self forKey:@(browser->GetIdentifier())];
  NSWindow* page = _host.pageWindow;
  if (hidden) {
    page.alphaValue = parent.alphaValue;
    page.ignoresMouseEvents = YES;
  }
  page.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
  browser->GetHost()->SetAutoResizeEnabled(true, CefSize((int)kExtensionPopupMinSize.width, (int)kExtensionPopupMinSize.height),
                                           CefSize((int)kExtensionPopupMaxSize.width, (int)kExtensionPopupMaxSize.height));
  _isOpen = YES;
  // Shown once the page has a size; a slow page shows at the smallest size and grows when it reports.
  __weak ExtensionPopup* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [weakSelf showIfNeeded]; });
  return self;
}

- (NSWindow*)pageWindow { return _host.pageWindow; }

- (void)runJS:(NSString*)js {
  CefRefPtr<CefBrowser> b = _host.browser;
  if (b) b->GetMainFrame()->ExecuteJavaScript(js.UTF8String, b->GetMainFrame()->GetURL(), 0);
}

- (void)place {
  NSWindow* parent = _parent;
  if (!parent) return;
  NSSize size = ExtensionPopupClampSize(_pageSize.width > 0 ? _pageSize : kExtensionPopupMinSize);
  [_panel setFrame:ExtensionPopupFrame(_anchorRect, size, parent.frame) display:YES];
}

- (void)showIfNeeded {
  if (_shown || !_isOpen) return;
  NSWindow* parent = _parent;
  if (!parent) return [self closeBecause:@"window"];
  _shown = YES;
  [self place];
  [parent addChildWindow:_panel ordered:NSWindowAbove];
  _container.frame = _panel.contentView.bounds;
  [_panel.contentView addSubview:_container];  // the page window follows the placeholder onto the bubble
  [self watch];
  if (!_hidden) {  // typing goes to the popup, as in Chrome
    [_host.pageWindow makeKeyWindow];
    CefRefPtr<CefBrowser> b = _host.browser;
    if (b) b->GetHost()->SetFocus(true);
  }
}

- (BOOL)ownsWindow:(NSWindow*)w {
  for (; w; w = w.parentWindow)
    if (w == _panel || w == _host.pageWindow) return YES;
  return NO;
}

- (void)watch {
  __weak ExtensionPopup* weakSelf = self;
  _eventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown |
                                                                NSEventMaskOtherMouseDown | NSEventMaskKeyDown
                                                        handler:^NSEvent*(NSEvent* e) {
                                                          ExtensionPopup* me = weakSelf;
                                                          return me ? [me handleLocalEvent:e] : e;
                                                        }];
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  NSWindow* parent = _parent;
  void (^on)(NSNotificationName, id, NSString*) = ^(NSNotificationName name, id object, NSString* reason) {
    [self->_observers addObject:[nc addObserverForName:name object:object queue:nil usingBlock:^(NSNotification*) {
      [weakSelf closeBecause:reason];
    }]];
  };
  on(NSWindowWillMoveNotification, parent, @"window");
  on(NSWindowDidResizeNotification, parent, @"window");
  on(NSWindowWillCloseNotification, parent, @"window");
  on(NSWindowDidMiniaturizeNotification, parent, @"window");
  on(NSWindowDidEnterFullScreenNotification, parent, @"window");
  on(NSWindowDidExitFullScreenNotification, parent, @"window");
  on(NSApplicationDidResignActiveNotification, NSApp, @"app");
  [_observers addObject:[nc addObserverForName:NSWindowDidBecomeKeyNotification object:nil queue:nil
                                    usingBlock:^(NSNotification* n) {
                                      ExtensionPopup* me = weakSelf;
                                      if (me && ![me ownsWindow:n.object]) [me closeBecause:@"focus"];
                                    }]];
}

- (NSEvent*)handleLocalEvent:(NSEvent*)e {
  if (!_isOpen) return e;
  if (e.type == NSEventTypeKeyDown) {
    if (e.keyCode == 53 && [self ownsWindow:e.window]) {  // Esc in the bubble closes it
      [self closeBecause:@"esc"];
      return nil;
    }
    return e;
  }
  if (![self ownsWindow:e.window]) [self closeBecause:@"click"];  // the click itself still goes where it was aimed
  return e;
}

- (void)resizeTo:(NSSize)size {
  if (!_isOpen || size.width <= 0 || size.height <= 0) return;
  _pageSize = size;
  if (_shown) [self place];
  else [self showIfNeeded];
}

- (void)pageAutoResized:(NSSize)size {
  _autoResized = YES;
  _sizedBy = @"autoresize";
  [self resizeTo:size];
}

- (void)pageMeasured:(NSSize)size {
  if (_autoResized) return;  // Chromium's own measurement wins
  _sizedBy = @"script";
  [self resizeTo:size];
}

- (void)pageLoaded:(NSString*)url { _loadedURL = [url copy]; }
- (void)pageFailed { _loadFailed = YES; }
- (void)pageTitle:(NSString*)title { _title = [title copy]; }
- (void)pageWantsURL:(NSString*)url {
  if (url.length && self.openURL) self.openURL(url);
}
- (void)pageClosed {
  if (_isOpen) [self closeBecause:@"script"];  // the page called window.close()
}

- (void)closeBecause:(NSString*)reason {
  if (!_isOpen || _closing) return;
  _closing = YES;
  _isOpen = NO;
  _closeReason = [reason copy];
  if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
  _eventMonitor = nil;
  for (id o in _observers) [NSNotificationCenter.defaultCenter removeObserver:o];
  [_observers removeAllObjects];
  BOOL wasKey = _host.pageWindow.isKeyWindow;
  [_host close];
  [_container removeFromSuperview];
  NSWindow* parent = _parent;
  if (_panel.parentWindow) [_panel.parentWindow removeChildWindow:_panel];
  [_panel orderOut:nil];
  if (wasKey && !_hidden && parent.isVisible) [parent makeKeyWindow];
  void (^done)(void) = self.onClose;
  self.onClose = nil;
  if (done) done();
}

- (void)dealloc {
  if (_eventMonitor) [NSEvent removeMonitor:_eventMonitor];
  for (id o in _observers) [NSNotificationCenter.defaultCenter removeObserver:o];
}
@end
