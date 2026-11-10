#import "app/little_window.h"

#include "app/browser_client.h"
#include "include/cef_browser.h"

static const CGFloat kToolbarHeight = 34;

@implementation LittleWindowController {
  NSPopUpButton* _spaceMenu;
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
  BOOL _incognito;
  BOOL _peekMode;
  NSView* _peekCard;
  NSView* _peekButtons;
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
  self.lastUsedAt = [NSDate date];
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
  _spaceMenu = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(b.size.width - 140 - 44, 4, 40, 26) pullsDown:YES];
  _spaceMenu.autoresizingMask = NSViewMinXMargin;
  _spaceMenu.toolTip = @"Move to Space";
  _spaceMenu.hidden = YES;
  [toolbar addSubview:_spaceMenu];
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

- (BOOL)incognito { return _incognito; }

- (void)makeIncognito {
  _incognito = YES;
  NSWindow* w = self.window;
  w.level = NSNormalWindowLevel;
  w.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  w.backgroundColor = [NSColor colorWithSRGBRed:0.13 green:0.12 blue:0.16 alpha:1];
  _openButton.hidden = YES;  // a private page never moves into a saved Space
  _spaceMenu.hidden = YES;
  NSImageView* mask = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"eyeglasses" accessibilityDescription:@"Incognito"]];
  mask.contentTintColor = NSColor.whiteColor;
  NSView* toolbar = _titleLabel.superview;
  mask.frame = NSMakeRect(toolbar.bounds.size.width - 128, 8, 20, 18);
  mask.autoresizingMask = NSViewMinXMargin;
  [toolbar addSubview:mask];
  NSTextField* label = [NSTextField labelWithString:@"Incognito"];
  label.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  label.textColor = NSColor.whiteColor;
  label.frame = NSMakeRect(toolbar.bounds.size.width - 104, 8, 96, 18);
  label.autoresizingMask = NSViewMinXMargin;
  [toolbar addSubview:label];
  w.title = @"Incognito";
}

- (void)presentAsPeekOver:(NSWindow*)parent {
  NSRect f = parent.frame;
  [self presentAsPeekOver:parent inRect:NSInsetRect(f, f.size.width * 0.08, f.size.height * 0.08)];
}

// Arc's Peek: the page as a large rounded card floating over the (dimmed) page, no title bar; two small round
// buttons sit above its top-right corner: Open as Tab and close.
- (void)presentAsPeekOver:(NSWindow*)parent inRect:(NSRect)area {
  NSWindow* w = self.window;
  w.level = NSNormalWindowLevel;
  w.styleMask = w.styleMask & ~(NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable);
  for (NSWindowButton b : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton})
    [w standardWindowButton:b].hidden = YES;
  w.opaque = NO;
  w.backgroundColor = NSColor.clearColor;
  w.hasShadow = NO;
  w.movable = NO;
  _openButton.title = @"Open as Tab";
  _peekMode = YES;
  [w setFrame:area display:NO];
  NSView* root = w.contentView;
  NSRect b = root.bounds;
  NSView* toolbar = _titleLabel.superview;
  toolbar.hidden = YES;
  const CGFloat bar = 30;
  _webContainer.frame = NSMakeRect(0, 0, b.size.width, b.size.height - bar);
  _webContainer.wantsLayer = YES;
  _webContainer.layer.cornerRadius = 10;
  _webContainer.layer.masksToBounds = YES;
  _webContainer.layer.borderWidth = 1;
  _webContainer.layer.borderColor = [NSColor colorWithWhite:0 alpha:0.12].CGColor;
  if (!_peekCard) {  // the card's shadow, drawn behind the page (the page view itself is clipped)
    _peekCard = [[NSView alloc] initWithFrame:_webContainer.frame];
    _peekCard.wantsLayer = YES;
    _peekCard.layer.backgroundColor = NSColor.whiteColor.CGColor;
    _peekCard.layer.cornerRadius = 10;
    _peekCard.layer.shadowColor = NSColor.blackColor.CGColor;
    _peekCard.layer.shadowOpacity = 0.45;
    _peekCard.layer.shadowRadius = 24;
    _peekCard.layer.shadowOffset = CGSizeMake(0, -6);
    _peekCard.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:_peekCard positioned:NSWindowBelow relativeTo:_webContainer];
  }
  _peekCard.frame = _webContainer.frame;
  if (!_peekButtons) {
    _peekButtons = [[NSView alloc] initWithFrame:NSMakeRect(b.size.width - 62, b.size.height - 26, 62, 24)];
    _peekButtons.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    NSArray* defs = @[ @[ @"arrow.up.left.and.arrow.down.right", @"openInMainWindow:", @"Open as Tab" ],
                       @[ @"xmark", @"closeTab:", @"Close Peek" ] ];
    CGFloat x = 0;
    for (NSArray* d in defs) {
      NSButton* btn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:d[0] accessibilityDescription:d[2]]
                                         target:self action:NSSelectorFromString(d[1])];
      btn.bordered = NO;
      btn.toolTip = d[2];
      btn.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightBold];
      btn.contentTintColor = NSColor.whiteColor;
      btn.wantsLayer = YES;
      btn.layer.cornerRadius = 12;
      btn.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:0.85].CGColor;
      btn.frame = NSMakeRect(x, 0, 24, 24);
      [_peekButtons addSubview:btn];
      x += 30;
    }
    [root addSubview:_peekButtons];
  }
  [parent addChildWindow:w ordered:NSWindowAbove];
  [w makeKeyAndOrderFront:nil];
}

- (NSString*)peekStyleDescription {  // tests
  return [NSString stringWithFormat:@"peek=%d titlebar=%d radius=%.0f buttons=%lu clear=%d", _peekMode,
                                    !_titleLabel.superview.hidden || ![self.window standardWindowButton:NSWindowCloseButton].hidden,
                                    _webContainer.layer.cornerRadius, (unsigned long)_peekButtons.subviews.count,
                                    !self.window.opaque];
}

- (void)cancelOperation:(id)sender { [self.window close]; }
- (IBAction)closeTab:(id)sender { [self.window close]; }  // Cmd+W closes a Peek or Little Window

- (void)pageTitleChanged:(NSString*)title {
  _pageTitle = [title copy];
  _titleLabel.stringValue = title;
  self.window.title = _incognito ? [@"Incognito - " stringByAppendingString:title] : title;
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

- (void)setSpaceNames:(NSArray<NSString*>*)names {
  if (_incognito) return;
  _spaceNames = [names copy];
  [_spaceMenu removeAllItems];
  [_spaceMenu addItemWithTitle:@""];  // pull-down title slot
  _spaceMenu.itemArray.firstObject.image = [NSImage imageWithSystemSymbolName:@"rectangle.stack" accessibilityDescription:@"Move to Space"];
  for (NSUInteger i = 0; i < names.count; ++i) {
    NSMenuItem* mi = [_spaceMenu.menu addItemWithTitle:[@"Move to " stringByAppendingString:names[i]]
                                                action:@selector(spaceChosen:) keyEquivalent:@""];
    mi.target = self;
    mi.tag = (NSInteger)i;
  }
  _spaceMenu.hidden = names.count < 2;
}

- (void)spaceChosen:(NSMenuItem*)sender { [self openInSpaceAtIndex:(NSUInteger)sender.tag]; }

- (void)openInSpaceAtIndex:(NSUInteger)index {
  NSString* url = self.currentURL;
  if (_incognito || !_onMoveToSpace || !url.length || index >= _spaceNames.count) return;
  _moved = YES;
  _onMoveToSpace(url, index);
  [self.window close];
}

- (IBAction)openInMainWindow:(id)sender {
  NSString* url = self.currentURL;
  if (_incognito) return;
  _moved = YES;
  if (_onMove && url.length) _onMove(url);
  [self.window close];
}

- (void)windowDidBecomeKey:(NSNotification*)notification { self.lastUsedAt = [NSDate date]; }
- (void)windowDidResignKey:(NSNotification*)notification { self.lastUsedAt = [NSDate date]; }

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
