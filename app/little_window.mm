#import "app/little_window.h"

#include "app/browser_client.h"
#include "include/cef_browser.h"

static const CGFloat kToolbarHeight = 34;

@implementation LittleWindowController {
  CefRefPtr<BrowserClient> _client;
  CefRefPtr<CefBrowser> _browser;
  NSView* _webContainer;
  NSTextField* _titleLabel;
  NSButton* _openButton;
  NSString* _initialURL;
  NSString* _pageTitle;
  NSString* _lastURL;
  LittleWindowMove _onMove;
  LittleWindowClosed _onClose;
  BOOL _moved;
}

- (instancetype)initWithURL:(NSString*)url
                    context:(CefRefPtr<CefRequestContext>)context
                     onMove:(LittleWindowMove)onMove
                    onClose:(LittleWindowClosed)onClose {
  NSRect screen = NSScreen.mainScreen.visibleFrame;
  NSRect frame = NSMakeRect(NSMidX(screen) - 450, NSMidY(screen) - 330, 900, 660);
  NSWindow* window = [[NSWindow alloc]
      initWithContentRect:frame
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.releasedWhenClosed = NO;
  window.level = NSFloatingWindowLevel;  // a quick look stays above the main window
  if (!(self = [super initWithWindow:window])) return nil;
  window.delegate = self;
  _initialURL = [url copy];
  _lastURL = [url copy];
  _onMove = [onMove copy];
  _onClose = [onClose copy];

  NSView* root = window.contentView;
  NSRect b = root.bounds;
  NSView* toolbar = [[NSView alloc] initWithFrame:NSMakeRect(0, b.size.height - kToolbarHeight, b.size.width, kToolbarHeight)];
  toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  _titleLabel = [NSTextField labelWithString:url];
  _titleLabel.frame = NSMakeRect(80, 8, b.size.width - 80 - 150, 18);
  _titleLabel.autoresizingMask = NSViewWidthSizable;
  _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  _titleLabel.textColor = NSColor.secondaryLabelColor;
  [toolbar addSubview:_titleLabel];
  NSButton* open = [NSButton buttonWithTitle:@"Open in NotArc" target:self action:@selector(openInMainWindow:)];
  _openButton = open;
  open.frame = NSMakeRect(b.size.width - 140, 4, 132, 26);
  open.autoresizingMask = NSViewMinXMargin;
  open.bezelStyle = NSBezelStyleRounded;
  [toolbar addSubview:open];
  [root addSubview:toolbar];

  _webContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, b.size.width, b.size.height - kToolbarHeight)];
  _webContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:_webContainer];

  __weak LittleWindowController* weakSelf = self;
  _client = new BrowserClient(
      [weakSelf](int, const std::string& title) {
        [weakSelf pageTitleChanged:[NSString stringWithUTF8String:title.c_str()]];
      },
      [weakSelf](int, const std::string& u) { [weakSelf pageURLChanged:[NSString stringWithUTF8String:u.c_str()]]; });

  CefWindowInfo info;
  NSRect r = _webContainer.bounds;
  info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(_webContainer),
                  CefRect(0, 0, static_cast<int>(r.size.width), static_cast<int>(r.size.height)));
  CefBrowserSettings settings;
  _browser = CefBrowserHost::CreateBrowserSync(info, _client, url.UTF8String, settings, nullptr, context);
  if (_browser) {
    NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(_browser->GetHost()->GetWindowHandle());
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    view.frame = _webContainer.bounds;
  }
  return self;
}

- (void)presentAsPeekOver:(NSWindow*)parent {
  NSWindow* w = self.window;
  w.level = NSNormalWindowLevel;
  w.styleMask = w.styleMask & ~NSWindowStyleMaskMiniaturizable;
  _openButton.title = @"Open as Tab";
  NSRect f = parent.frame;
  CGFloat inset = 0.08;
  [w setFrame:NSInsetRect(f, f.size.width * inset, f.size.height * inset) display:NO];
  [parent addChildWindow:w ordered:NSWindowAbove];
  [w makeKeyAndOrderFront:nil];
}

- (void)cancelOperation:(id)sender { [self.window close]; }
- (IBAction)closeTab:(id)sender { [self.window close]; }  // Cmd+W closes a Peek or Little Window

- (void)pageTitleChanged:(NSString*)title {
  _pageTitle = [title copy];
  _titleLabel.stringValue = title;
  self.window.title = title;
}

- (void)pageURLChanged:(NSString*)url {
  if (url.length) _lastURL = [url copy];
}

- (NSString*)currentURL {
  if (_browser) {
    std::string u = _browser->GetMainFrame()->GetURL().ToString();
    if (!u.empty()) return [NSString stringWithUTF8String:u.c_str()];
  }
  return _lastURL;
}

- (NSString*)pageTitle { return _pageTitle ?: self.currentURL; }

- (IBAction)openInMainWindow:(id)sender {
  NSString* url = self.currentURL;
  _moved = YES;
  if (_onMove && url.length) _onMove(url);
  [self.window close];
}

- (void)windowWillClose:(NSNotification*)notification {
  [self.window.parentWindow removeChildWindow:self.window];
  NSString* url = self.currentURL;
  NSString* title = self.pageTitle;
  if (_browser) {
    _browser->GetHost()->CloseBrowser(true);
    _browser = nullptr;
  }
  [_webContainer removeFromSuperview];  // CEF tears down a child browser when its view goes away
  _webContainer = nil;
  LittleWindowClosed done = _onClose;
  _onClose = nil;
  if (done) done(self, url, title, _moved);
}

@end
