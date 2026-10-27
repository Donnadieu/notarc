// #66 spike (hidden, isolated like --selftest): can a Chrome-style CEF Views window run a real unpacked extension,
// offer Chromium's password manager, and still hold a native NSView sidebar next to the page?
#import <Cocoa/Cocoa.h>

#include <cstdio>

#include "include/cef_app.h"
#include "include/cef_client.h"
#include "include/views/cef_browser_view.h"
#include "include/views/cef_window.h"
#include "include/wrapper/cef_helpers.h"

void SwapToSecondTab();
CefRefPtr<CefWindow> g_window2;

namespace {

int g_step = 0;
CefRefPtr<CefBrowserView> g_view, g_view2;
bool g_finished = false;
CefRefPtr<CefWindow> g_window;

void Finish(const char* why) {
  if (g_finished) return;
  g_finished = true;
  std::printf("SPIKE-END %s\n", why);
  std::fflush(stdout);
  if (g_window2) g_window2->Close();
  if (g_window) g_window->Close();
  CefQuitMessageLoop();
}

class SpikeClient : public CefClient, public CefDisplayHandler, public CefLoadHandler {
 public:
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnTitleChange(CefRefPtr<CefBrowser> b, const CefString& title) override {
    std::string t = title.ToString();
    std::printf("SPIKE-TITLE step=%d %s\n", g_step, t.c_str());
    std::fflush(stdout);
    if (g_step == 3 && t == "EXT-OK") {
      std::printf("SPIKE-TAB2 extension=1 style=%d\n", g_view2->GetRuntimeStyle());
      g_step = 4;
      Finish("done");
      return;
    }
    if (g_step == 0 && t == "EXT-OK") {
      std::printf("SPIKE-EXTENSION ran=1\n");
      g_step = 1;
      b->GetMainFrame()->LoadURL("chrome://password-manager/passwords");
    }
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> b, CefRefPtr<CefFrame> f, int code) override {
    if (!f->IsMain()) return;
    std::string url = f->GetURL().ToString();
    std::printf("SPIKE-LOAD step=%d code=%d %s\n", g_step, code, url.c_str());
    std::fflush(stdout);
    if (g_step == 1 && url.rfind("chrome://password-manager", 0) == 0) {
      std::printf("SPIKE-PASSWORDMANAGER loaded=%d\n", code == 200 || code == 0);
      g_step = 2;
      dispatch_async(dispatch_get_main_queue(), ^{ SwapToSecondTab(); });
    }
  }
  IMPLEMENT_REFCOUNTING(SpikeClient);
};

class SpikeBrowserViewDelegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  IMPLEMENT_REFCOUNTING(SpikeBrowserViewDelegate);
};

class SpikeWindowDelegate : public CefWindowDelegate {
 public:
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    g_window = window;
    window->AddChildView(g_view);
    // Leave a 273 pt strip on the left for a native sidebar.
    g_view->SetBounds(CefRect(273, 0, 1200 - 273, 800));
    NSView* handle = (__bridge NSView*)window->GetWindowHandle();
    NSWindow* nsw = [handle isKindOfClass:NSWindow.class] ? (NSWindow*)handle : handle.window;
    NSView* sidebar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 273, 800)];
    sidebar.wantsLayer = YES;
    sidebar.layer.backgroundColor = NSColor.systemIndigoColor.CGColor;
    [nsw.contentView addSubview:sidebar positioned:NSWindowBelow relativeTo:nil];
    std::printf("SPIKE-WINDOW style=%d handleClass=%s nswindow=%d sidebarInWindow=%d contentSubviews=%lu\n",
                window->GetRuntimeStyle(), handle ? object_getClassName(handle) : "nil", nsw != nil,
                sidebar.window == nsw && nsw != nil, (unsigned long)nsw.contentView.subviews.count);
    std::fflush(stdout);
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { g_view = nullptr; g_view2 = nullptr; g_window = nullptr; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(-3000, -3000, 1200, 800); }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  bool CanClose(CefRefPtr<CefWindow>) override { return true; }
  IMPLEMENT_REFCOUNTING(SpikeWindowDelegate);
};

}  // namespace

class Tab2Delegate : public CefBrowserViewDelegate {
 public:
  cef_runtime_style_t GetBrowserRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  ChromeToolbarType GetChromeToolbarType(CefRefPtr<CefBrowserView>) override { return CEF_CTT_NONE; }
  IMPLEMENT_REFCOUNTING(Tab2Delegate);
};

void SwapWithContext(CefRefPtr<CefRequestContext> ctx);

class SpikeContextHandler : public CefRequestContextHandler {
 public:
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> ctx) override {
    std::printf("SPIKE-CONTEXT initialized\n");
    std::fflush(stdout);
    CefRefPtr<CefRequestContext> keep = ctx;
    dispatch_async(dispatch_get_main_queue(), ^{ SwapWithContext(keep); });
  }
  IMPLEMENT_REFCOUNTING(SpikeContextHandler);
};

// Like switching tabs in NotArc: take the first page out of the window and put a second one, in its own
// Space profile (separate request context / cookie jar), in its place.
void SwapToSecondTab() {
  NSString* dir = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"] stringByAppendingPathComponent:@"SelfTest Space Spike"];
  CefRequestContextSettings rcs;
  CefString(&rcs.cache_path) = dir.UTF8String;
  // A new Space profile finishes setting up asynchronously; the page is made once it's ready.
  CefRequestContext::CreateContext(rcs, new SpikeContextHandler);
}

class Tab2WindowDelegate : public CefWindowDelegate {
 public:
  void OnWindowCreated(CefRefPtr<CefWindow> window) override {
    g_window2 = window;
    window->AddChildView(g_view2);
    NSView* h1 = (__bridge NSView*)g_window->GetWindowHandle();
    NSView* h2 = (__bridge NSView*)window->GetWindowHandle();
    NSWindow* main = h1.window;
    NSWindow* card = h2.window;
    // The tab's window sits exactly over the page card area of the main window and moves with it.
    NSRect f = main.frame;
    [card setFrame:NSMakeRect(f.origin.x + 273, f.origin.y, f.size.width - 273, f.size.height) display:NO];
    [main addChildWindow:card ordered:NSWindowAbove];
    std::printf("SPIKE-CHILDWINDOW style=%d viewStyle=%d attached=%d sameSpaceAsMain=%d\n", window->GetRuntimeStyle(),
                g_view2->GetRuntimeStyle(), card.parentWindow == main, NSEqualRects(card.frame, NSMakeRect(f.origin.x + 273, f.origin.y, f.size.width - 273, f.size.height)));
    std::fflush(stdout);
  }
  void OnWindowDestroyed(CefRefPtr<CefWindow>) override { g_view2 = nullptr; g_window2 = nullptr; }
  cef_runtime_style_t GetWindowRuntimeStyle() override { return CEF_RUNTIME_STYLE_CHROME; }
  CefRect GetInitialBounds(CefRefPtr<CefWindow>) override { return CefRect(-3000, -3000, 927, 800); }
  bool IsFrameless(CefRefPtr<CefWindow>) override { return true; }
  bool CanClose(CefRefPtr<CefWindow>) override { return true; }
  IMPLEMENT_REFCOUNTING(Tab2WindowDelegate);
};

void SwapWithContext(CefRefPtr<CefRequestContext> ctx) {
  CefBrowserSettings settings;
  g_view2 = CefBrowserView::CreateBrowserView(new SpikeClient, "https://example.com/?tab2", settings, nullptr, ctx,
                                              new Tab2Delegate);
  if (!g_window || !g_view2) { Finish("swap-null"); return; }
  g_step = 3;
  CefWindow::CreateTopLevelWindow(new Tab2WindowDelegate);
}

void RunViewsSpike() {
  CefBrowserSettings settings;
  g_view = CefBrowserView::CreateBrowserView(new SpikeClient, "https://example.com/", settings, nullptr, nullptr,
                                             new SpikeBrowserViewDelegate);
  CefWindow::CreateTopLevelWindow(new SpikeWindowDelegate);
  std::printf("SPIKE-VIEW style=%d\n", g_view ? g_view->GetRuntimeStyle() : -1);
  std::fflush(stdout);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ Finish("timeout"); });
}
