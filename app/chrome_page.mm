#import "app/chrome_page.h"

#import <QuartzCore/QuartzCore.h>

#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"

BOOL ChromePagesEnabled(void) {
  static BOOL on = [NSUserDefaults.standardUserDefaults boolForKey:@"chromePages"] ||
                   [NSProcessInfo.processInfo.arguments containsObject:@"--chrome-pages"];
  return on;
}

namespace {

class PageViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  IMPLEMENT_REFCOUNTING(PageViewDelegate);
};

class PageWindowDelegate : public CefWindowDelegate {
 public:
  explicit PageWindowDelegate(CefRefPtr<CefBrowserView> view, CefRect bounds) : view_(view), bounds_(bounds) {}
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    window_ = window;
    window->AddChildView(view_);
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override {
    view_ = nullptr;
    window_ = nullptr;
  }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return bounds_; }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  bool CanClose(CefRefPtr<CefWindow>) override { return true; }
  bool CanResize(CefRefPtr<CefWindow>) override { return false; }
  bool CanMinimize(CefRefPtr<CefWindow>) override { return false; }
  bool CanMaximize(CefRefPtr<CefWindow>) override { return false; }
  CefRefPtr<CefWindow> window() { return window_; }

 private:
  CefRefPtr<CefBrowserView> view_;
  CefRefPtr<CefWindow> window_;
  CefRect bounds_;
  IMPLEMENT_REFCOUNTING(PageWindowDelegate);
};

}  // namespace

// The placeholder reports every move/resize/visibility change, including ones from its ancestors.
@interface ChromePagePlaceholder : NSView
@property(nonatomic, weak) ChromePageHost* host;
@end

@implementation ChromePagePlaceholder
- (void)setFrame:(NSRect)frame {
  [super setFrame:frame];
  [self.host syncFrame];
}
- (void)setHidden:(BOOL)hidden {
  [super setHidden:hidden];
  [self.host syncFrame];
}
- (void)viewDidMoveToWindow { [self.host syncFrame]; }
- (void)viewDidUnhide { [self.host syncFrame]; }
- (void)viewDidHide { [self.host syncFrame]; }
- (void)resizeWithOldSuperviewSize:(NSSize)size {
  [super resizeWithOldSuperviewSize:size];
  [self.host syncFrame];
}
@end

@implementation ChromePageHost {
  CefRefPtr<CefBrowserView> _view;
  CefRefPtr<PageWindowDelegate> _delegate;
  ChromePagePlaceholder* _placeholder;
  NSWindow* _attachedTo;
  id _moveObserver;
}

- (instancetype)initWithClient:(CefRefPtr<CefClient>)client
                           url:(NSString*)url
                       context:(CefRefPtr<CefRequestContext>)context
                     hostView:(NSView*)hostView {
  if (!(self = [super init])) return nil;
  _placeholder = [[ChromePagePlaceholder alloc] initWithFrame:hostView.bounds];
  _placeholder.host = self;
  _placeholder.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [hostView addSubview:_placeholder];
  CefBrowserSettings settings;
  _view = CefBrowserView::CreateBrowserView(client, url.UTF8String, settings, nullptr, context, new PageViewDelegate);
  if (!_view) return self;
  NSRect s = [self screenRect];
  // Created off screen; syncFrame puts it on the card once it's attached.
  _delegate = new PageWindowDelegate(_view, CefRect(-10000, -10000, MAX(1, (int)s.size.width), MAX(1, (int)s.size.height)));
  CefWindow::CreateTopLevelWindow(_delegate);
  NSWindow* w = [self pageWindow];
  w.opaque = NO;
  w.backgroundColor = NSColor.clearColor;
  w.hasShadow = NO;
  w.collectionBehavior |= NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorTransient;
  [self syncFrame];
  return self;
}

- (NSView*)placeholder { return _placeholder; }

- (NSWindow*)pageWindow {
  CefRefPtr<CefWindow> w = _delegate ? _delegate->window() : nullptr;
  if (!w) return nil;
  NSView* v = (__bridge NSView*)w->GetWindowHandle();
  return [v isKindOfClass:NSWindow.class] ? (NSWindow*)v : v.window;
}

- (CefRefPtr<CefBrowser>)browser { return _view ? _view->GetBrowser() : nullptr; }

- (NSRect)screenRect {
  NSWindow* main = _placeholder.window;
  if (!main) return _placeholder.bounds;
  return [main convertRectToScreen:[_placeholder convertRect:_placeholder.bounds toView:nil]];
}

- (void)syncFrame {
  NSWindow* page = [self pageWindow];
  if (!page) return;
  NSWindow* main = _placeholder.window;
  BOOL visible = main && !_placeholder.isHiddenOrHasHiddenAncestor && _placeholder.bounds.size.width > 1;
  if (_attachedTo != main) {
    if (_attachedTo) [_attachedTo removeChildWindow:page];
    if (_moveObserver) [NSNotificationCenter.defaultCenter removeObserver:_moveObserver];
    _moveObserver = nil;
    _attachedTo = main;
    if (main) {
      __weak ChromePageHost* weakSelf = self;
      _moveObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification
                                                                      object:main
                                                                       queue:nil
                                                                  usingBlock:^(NSNotification*) { [weakSelf syncFrame]; }];
    }
  }
  if (!visible) {
    if (page.parentWindow) [page.parentWindow removeChildWindow:page];
    [page orderOut:nil];
    return;
  }
  [page setFrame:[self screenRect] display:YES];
  if (page.parentWindow != main) [main addChildWindow:page ordered:NSWindowAbove];
  // The page card's rounded corners (Arc: 10 pt, continuous).
  NSView* content = page.contentView;
  content.wantsLayer = YES;
  CGFloat radius = _placeholder.superview.layer.cornerRadius;
  content.layer.cornerRadius = radius > 0 ? radius : 10;
  content.layer.cornerCurve = kCACornerCurveContinuous;
  content.layer.masksToBounds = YES;
}

- (void)close {
  if (_moveObserver) [NSNotificationCenter.defaultCenter removeObserver:_moveObserver];
  _moveObserver = nil;
  NSWindow* page = [self pageWindow];
  if (page.parentWindow) [page.parentWindow removeChildWindow:page];
  CefRefPtr<CefBrowser> b = [self browser];
  if (b) b->GetHost()->CloseBrowser(true);
  CefRefPtr<CefWindow> w = _delegate ? _delegate->window() : nullptr;
  if (w) w->Close();
  [_placeholder removeFromSuperview];
  _placeholder.host = nil;
  _view = nullptr;
}

- (void)dealloc {
  if (_moveObserver) [NSNotificationCenter.defaultCenter removeObserver:_moveObserver];
}
@end
