#import "app/welcome.h"

static NSColor* RGBA(double r, double g, double b, double a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
static BOOL WelcomeDark(NSView* v) {
  return [[v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
      isEqualToString:NSAppearanceNameDarkAqua];
}
// Arc 1.169 colour values: WelcomeScreenCardBackground, WelcomeScreenText, WelcomeGradientBlue / Pink,
// PrimaryButtonFace, AuthFlowDropTargetForegroundCompleted. Numbers only.
static NSColor* WelcomeBackground(BOOL dark) { return dark ? RGBA(0.075, 0.078, 0.094, 1) : RGBA(1, 1, 1, 1); }
static NSColor* WelcomeText(BOOL dark) { return dark ? RGBA(0.882, 0.808, 0.871, 1) : RGBA(0.439, 0.251, 0.404, 1); }
static NSColor* WelcomeTitle(BOOL dark) { return dark ? NSColor.whiteColor : RGBA(0.12, 0.08, 0.14, 1); }
static NSColor* Primary(void) { return RGBA(0.192, 0.224, 0.984, 1); }

#pragma mark Pieces

@interface WelcomeButton : NSButton  // Arc's big rounded welcome buttons: blue (primary) or quiet text
@property(nonatomic) BOOL primary;
@end
@implementation WelcomeButton
- (BOOL)isFlipped { return NO; }
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    self.bordered = NO;
    self.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
  }
  return self;
}
- (void)drawRect:(NSRect)dirty {
  BOOL dark = WelcomeDark(self), down = self.cell.isHighlighted;
  NSColor* fg;
  if (self.primary) {
    [(self.enabled ? (down ? RGBA(0.16, 0.19, 0.83, 1) : Primary()) : RGBA(0.5, 0.52, 0.7, 0.5)) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:NSHeight(self.bounds) / 2 yRadius:NSHeight(self.bounds) / 2] fill];
    fg = NSColor.whiteColor;
  } else {
    fg = [WelcomeText(dark) colorWithAlphaComponent:down ? 0.6 : 0.9];
  }
  NSDictionary* a = @{ NSFontAttributeName : self.font, NSForegroundColorAttributeName : fg };
  NSSize t = [self.title sizeWithAttributes:a];
  [self.title drawAtPoint:NSMakePoint(round(NSMidX(self.bounds) - t.width / 2), round(NSMidY(self.bounds) - t.height / 2))
           withAttributes:a];
}
@end

// One browser to import from: a monogram (no browser logos) and its name; the chosen one has a blue ring.
@interface BrowserCard : NSButton
@property(nonatomic, copy) NSString* name;
@property(nonatomic) BOOL chosen;
@end
@implementation BrowserCard
- (BOOL)isFlipped { return NO; }
- (void)drawRect:(NSRect)dirty {
  BOOL dark = WelcomeDark(self);
  NSRect r = NSInsetRect(self.bounds, 2, 2);
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:14 yRadius:14];
  [(dark ? [NSColor colorWithWhite:1 alpha:self.cell.isHighlighted ? 0.12 : 0.07] : [NSColor colorWithWhite:0 alpha:0.04]) setFill];
  [p fill];
  if (self.chosen) {
    [Primary() setStroke];
    p.lineWidth = 2.5;
    [p stroke];
  }
  NSRect circle = NSMakeRect(NSMidX(r) - 20, NSMaxY(r) - 58, 40, 40);
  [[NSColor colorWithHue:fmod(self.name.hash % 360 / 360.0, 1) saturation:0.45 brightness:dark ? 0.75 : 0.85 alpha:1] setFill];
  [[NSBezierPath bezierPathWithOvalInRect:circle] fill];
  NSString* letter = self.name.length ? [self.name substringToIndex:1].uppercaseString : @"?";
  NSDictionary* la = @{ NSFontAttributeName : [NSFont systemFontOfSize:19 weight:NSFontWeightBold],
                        NSForegroundColorAttributeName : NSColor.whiteColor };
  NSSize ls = [letter sizeWithAttributes:la];
  [letter drawAtPoint:NSMakePoint(NSMidX(circle) - ls.width / 2, NSMidY(circle) - ls.height / 2) withAttributes:la];
  NSMutableParagraphStyle* ps = [NSMutableParagraphStyle new];
  ps.alignment = NSTextAlignmentCenter;
  ps.lineBreakMode = NSLineBreakByTruncatingTail;
  [self.name drawInRect:NSMakeRect(NSMinX(r) + 6, NSMinY(r) + 10, NSWidth(r) - 12, 18)
         withAttributes:@{ NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightMedium],
                           NSForegroundColorAttributeName : WelcomeTitle(dark), NSParagraphStyleAttributeName : ps }];
}
@end

// The tour's little drawings: a browser window in miniature, with the step's feature picked out.
@interface TourPicture : NSView
@property(nonatomic, copy) NSString* kind;
@end
@implementation TourPicture
- (void)drawRect:(NSRect)dirty {
  BOOL dark = WelcomeDark(self);
  NSRect frame = NSInsetRect(self.bounds, 2, 2);
  NSColor* space = dark ? RGBA(0.20, 0.17, 0.42, 1) : RGBA(0.82, 0.80, 0.98, 1);
  NSColor* ink = dark ? [NSColor colorWithWhite:1 alpha:0.22] : [NSColor colorWithWhite:0 alpha:0.14];
  NSColor* page = dark ? RGBA(0.13, 0.13, 0.16, 1) : NSColor.whiteColor;
  NSColor* accent = Primary();
  void (^fill)(NSColor*, NSRect, CGFloat) = ^(NSColor* c, NSRect r, CGFloat rad) {
    [c setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad] fill];
  };
  if ([self.kind isEqual:@"spaces"]) {  // three Spaces, three colours, swiped between
    NSArray* colors = @[ RGBA(0.95, 0.61, 0.73, 1), RGBA(0.50, 0.72, 0.84, 1), RGBA(0.45, 0.90, 0.61, 1) ];
    CGFloat w = (NSWidth(frame) - 40) / 3;
    for (NSUInteger i = 0; i < 3; ++i) {
      NSRect s = NSMakeRect(NSMinX(frame) + 10 + i * (w + 10), NSMinY(frame) + 10, w, NSHeight(frame) - 20);
      fill([colors[i] colorWithAlphaComponent:dark ? 0.55 : 0.8], s, 12);
      for (int j = 0; j < 4; ++j) fill(ink, NSMakeRect(NSMinX(s) + 12, NSMaxY(s) - 30 - j * 22, w - 24, 12), 6);
      for (NSUInteger d = 0; d < 3; ++d)
        fill(d == i ? [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.6] : ink,
             NSMakeRect(NSMidX(s) - 22 + d * 18, NSMinY(s) + 12, 8, 8), 4);
    }
    return;
  }
  fill(space, frame, 14);
  NSRect sidebar = NSMakeRect(NSMinX(frame) + 10, NSMinY(frame) + 10, 104, NSHeight(frame) - 20);
  NSRect card = NSMakeRect(NSMaxX(sidebar) + 8, NSMinY(frame) + 8, NSMaxX(frame) - NSMaxX(sidebar) - 16, NSHeight(frame) - 16);
  for (int i = 0; i < 3; ++i) fill([NSColor colorWithWhite:dark ? 1 : 0 alpha:0.25], NSMakeRect(NSMinX(sidebar) + 2 + i * 10, NSMaxY(sidebar) - 8, 6, 6), 3);
  fill(ink, NSMakeRect(NSMinX(sidebar), NSMaxY(sidebar) - 30, NSWidth(sidebar), 14), 6);
  if ([self.kind isEqual:@"split"]) {
    CGFloat half = (NSWidth(card) - 6) / 2;
    fill(page, NSMakeRect(NSMinX(card), NSMinY(card), half, NSHeight(card)), 8);
    fill(page, NSMakeRect(NSMinX(card) + half + 6, NSMinY(card), half, NSHeight(card)), 8);
    [[accent colorWithAlphaComponent:0.8] setStroke];
    NSBezierPath* o = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(card) + half + 6, NSMinY(card), half, NSHeight(card))
                                                      xRadius:8 yRadius:8];
    o.lineWidth = 2;
    [o stroke];
  } else {
    fill(page, card, 8);
  }
  // Sidebar rows: pinned above the divider, Today below.
  CGFloat y = NSMaxY(sidebar) - 54;
  for (int i = 0; i < 6; ++i) {
    if (i == 2) {
      fill(ink, NSMakeRect(NSMinX(sidebar) + 6, y + 6, NSWidth(sidebar) - 12, 1), 0);
      y -= 10;
    }
    BOOL lit = ([self.kind isEqual:@"pin"] && i == 1) || ([self.kind isEqual:@"split"] && i == 3);
    fill(lit ? [accent colorWithAlphaComponent:0.85] : ink, NSMakeRect(NSMinX(sidebar), y, NSWidth(sidebar), 14), 6);
    y -= 20;
  }
  if ([self.kind isEqual:@"pin"]) {  // a tab dragged up above the line
    NSBezierPath* arrow = [NSBezierPath bezierPath];
    CGFloat ax = NSMaxX(sidebar) + 2, ay = NSMaxY(sidebar) - 120;
    [arrow moveToPoint:NSMakePoint(ax, ay)];
    [arrow curveToPoint:NSMakePoint(ax, ay + 44) controlPoint1:NSMakePoint(ax + 26, ay + 10) controlPoint2:NSMakePoint(ax + 26, ay + 34)];
    [arrow moveToPoint:NSMakePoint(ax, ay + 44)];
    [arrow lineToPoint:NSMakePoint(ax + 9, ay + 47)];
    [arrow moveToPoint:NSMakePoint(ax, ay + 44)];
    [arrow lineToPoint:NSMakePoint(ax + 6, ay + 36)];
    [accent setStroke];
    arrow.lineWidth = 2.5;
    arrow.lineCapStyle = NSLineCapStyleRound;
    [arrow stroke];
  }
  if ([self.kind isEqual:@"commandbar"]) {  // the command bar over the dimmed window
    fill([NSColor colorWithWhite:0 alpha:0.25], frame, 14);
    NSRect bar = NSMakeRect(NSMidX(frame) - 130, NSMaxY(frame) - 150, 260, 120);
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.4];
    sh.shadowBlurRadius = 16;
    sh.shadowOffset = NSMakeSize(0, -6);
    [sh set];
    fill(dark ? RGBA(0.16, 0.16, 0.2, 1) : NSColor.whiteColor, bar, 12);
    [NSGraphicsContext restoreGraphicsState];
    fill(ink, NSMakeRect(NSMinX(bar) + 14, NSMaxY(bar) - 30, 150, 14), 7);
    fill([accent colorWithAlphaComponent:0.9], NSMakeRect(NSMinX(bar) + 8, NSMaxY(bar) - 62, NSWidth(bar) - 16, 22), 7);
    fill(ink, NSMakeRect(NSMinX(bar) + 14, NSMaxY(bar) - 88, 120, 10), 5);
    fill(ink, NSMakeRect(NSMinX(bar) + 14, NSMaxY(bar) - 108, 100, 10), 5);
  }
}
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

#pragma mark Welcome

@implementation WelcomeView {
  NSString* _page;
  NSTextField* _title;
  NSTextField* _body;
  TourPicture* _picture;
  WelcomeButton* _primary;
  WelcomeButton* _secondary;
  NSView* _grid;
  NSMutableArray<BrowserCard*>* _cards;
  NSInteger _chosen;
  NSProgressIndicator* _spinner;
  NSImageView* _check;
  NSSwitch* _makeDefault;
  NSTextField* _makeDefaultLabel;
  NSString* _summary;
}

+ (NSArray<NSString*>*)pageOrder { return @[ @"welcome", @"pin", @"spaces", @"split", @"commandbar", @"import", @"progress", @"done" ]; }

- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    self.wantsLayer = YES;
    _chosen = -1;
    _title = [NSTextField wrappingLabelWithString:@""];
    _title.alignment = NSTextAlignmentCenter;
    _body = [NSTextField wrappingLabelWithString:@""];
    _body.alignment = NSTextAlignmentCenter;
    _body.font = [NSFont systemFontOfSize:15];
    _picture = [TourPicture new];
    _primary = [WelcomeButton new];
    _primary.primary = YES;
    _primary.target = self;
    _primary.action = @selector(next);
    _primary.keyEquivalent = @"\r";
    _secondary = [WelcomeButton new];
    _secondary.target = self;
    _secondary.action = @selector(secondaryPressed:);
    _grid = [NSView new];
    _spinner = [NSProgressIndicator new];
    _spinner.style = NSProgressIndicatorStyleSpinning;
    _spinner.controlSize = NSControlSizeRegular;
    _check = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"checkmark.circle.fill" accessibilityDescription:@"Done"]];
    _check.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:56 weight:NSFontWeightRegular];
    _check.contentTintColor = RGBA(0.243, 0.659, 0.18, 1);
    _makeDefault = [NSSwitch new];
    _makeDefault.state = NSControlStateValueOn;
    _makeDefaultLabel = [NSTextField labelWithString:@"Make NotArc my default browser"];
    _makeDefaultLabel.font = [NSFont systemFontOfSize:13];
    for (NSView* v in @[ _picture, _title, _body, _grid, _spinner, _check, _makeDefault, _makeDefaultLabel, _primary, _secondary ])
      [self addSubview:v];
    [self showPage:@"welcome"];
  }
  return self;
}

- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSView*)hitTest:(NSPoint)p {  // the welcome covers the whole window: nothing under it takes clicks
  NSView* v = [super hitTest:p];
  return v ?: (NSPointInRect([self convertPoint:p fromView:self.superview], self.bounds) ? self : nil);
}
- (void)mouseDown:(NSEvent*)e {}

- (void)drawRect:(NSRect)dirty {
  BOOL dark = WelcomeDark(self);
  [WelcomeBackground(dark) setFill];
  NSRectFill(self.bounds);
  // Arc's welcome glow: soft blue and pink light behind the middle of the window.
  NSPoint c = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds));
  CGFloat r = MAX(NSWidth(self.bounds), NSHeight(self.bounds)) * 0.42;
  for (NSArray* g in @[ @[ RGBA(0, 0.278, 1, dark ? 0.32 : 0.16), @(-0.18), @(0.1) ],
                        @[ RGBA(1, 0.6, 0.6, dark ? 0.28 : 0.22), @(0.2), @(-0.12) ] ]) {
    NSGradient* grad = [[NSGradient alloc] initWithColors:@[ g[0], [(NSColor*)g[0] colorWithAlphaComponent:0] ]];
    NSPoint at = NSMakePoint(c.x + [g[1] doubleValue] * NSWidth(self.bounds), c.y + [g[2] doubleValue] * NSHeight(self.bounds));
    [grad drawFromCenter:at radius:0 toCenter:at radius:r options:0];
  }
}

- (void)layout {
  [super layout];
  [self place];
}

- (void)place {
  NSRect b = self.bounds;
  CGFloat W = MIN(520, NSWidth(b) - 80), x = round(NSMidX(b) - W / 2), mid = NSMidY(b);
  BOOL tour = [@[ @"pin", @"spaces", @"split", @"commandbar" ] containsObject:_page];
  BOOL import = [_page isEqual:@"import"];
  CGFloat titleH = ceil([_title.cell cellSizeForBounds:NSMakeRect(0, 0, W, 400)].height);
  CGFloat bodyH = ceil([_body.cell cellSizeForBounds:NSMakeRect(0, 0, W, 400)].height);
  CGFloat top = mid + (tour ? 220 : import ? 200 : 110);
  _picture.hidden = !tour;
  if (tour) {
    _picture.frame = NSMakeRect(round(NSMidX(b) - 210), top - 230, 420, 230);
    top -= 254;
  }
  _check.hidden = ![_page isEqual:@"done"];
  _spinner.hidden = ![_page isEqual:@"progress"];
  if (!_check.hidden) {
    _check.frame = NSMakeRect(round(NSMidX(b) - 34), top - 68, 68, 68);
    top -= 84;
  }
  if (!_spinner.hidden) {
    _spinner.frame = NSMakeRect(round(NSMidX(b) - 16), top - 32, 32, 32);
    top -= 48;
  }
  _title.frame = NSMakeRect(x, top - titleH, W, titleH);
  top -= titleH + 10;
  _body.frame = NSMakeRect(x, top - bodyH, W, bodyH);
  top -= bodyH + 26;
  _grid.hidden = !import;
  if (import) {
    NSUInteger n = _cards.count, cols = MIN((NSUInteger)3, MAX((NSUInteger)1, n)), rows = (n + cols - 1) / MAX((NSUInteger)1, cols);
    CGFloat cw = 140, ch = 104, gap = 14, gw = cols * cw + (cols - 1) * gap, gh = rows * ch + (rows ? rows - 1 : 0) * gap;
    _grid.frame = NSMakeRect(round(NSMidX(b) - gw / 2), top - gh, gw, gh);
    for (NSUInteger i = 0; i < n; ++i) {
      NSUInteger row = i / cols, inRow = MIN(cols, n - row * cols);  // a short last row sits in the middle
      CGFloat shift = (cols - inRow) * (cw + gap) / 2;
      _cards[i].frame = NSMakeRect(shift + (i % cols) * (cw + gap), gh - ch - row * (ch + gap), cw, ch);
    }
    top -= gh + 26;
  }
  BOOL done = [_page isEqual:@"done"];
  _makeDefault.hidden = _makeDefaultLabel.hidden = !done;
  if (done) {
    [_makeDefaultLabel sizeToFit];
    CGFloat rw = 40 + 10 + NSWidth(_makeDefaultLabel.frame);
    _makeDefault.frame = NSMakeRect(round(NSMidX(b) - rw / 2), top - 24, 40, 24);
    _makeDefaultLabel.frame = NSMakeRect(NSMaxX(_makeDefault.frame) + 10, top - 21, NSWidth(_makeDefaultLabel.frame), 18);
    top -= 44;
  }
  _primary.hidden = [_page isEqual:@"progress"];
  _primary.frame = NSMakeRect(round(NSMidX(b) - 110), top - 46, 220, 46);
  _secondary.frame = NSMakeRect(round(NSMidX(b) - 110), top - 46 - 40, 220, 30);
  _secondary.hidden = !_secondary.title.length || [_page isEqual:@"progress"];
}

- (void)setBrowsers:(NSArray<NSDictionary*>*)browsers {
  _browsers = [browsers copy];
  for (BrowserCard* c in _cards) [c removeFromSuperview];
  _cards = [NSMutableArray array];
  for (NSUInteger i = 0; i < _browsers.count; ++i) {
    BrowserCard* c = [BrowserCard new];
    c.bordered = NO;
    c.title = @"";
    c.name = _browsers[i][@"name"];
    c.tag = (NSInteger)i;
    c.target = self;
    c.action = @selector(cardClicked:);
    [_cards addObject:c];
    [_grid addSubview:c];
  }
  _chosen = _browsers.count ? 0 : -1;
  [self refreshCards];
  [self place];
}
- (void)cardClicked:(BrowserCard*)sender { [self chooseBrowserAtIndex:(NSUInteger)sender.tag]; }
- (void)chooseBrowserAtIndex:(NSUInteger)index {
  if (index >= _cards.count) return;
  _chosen = (NSInteger)index;
  [self refreshCards];
}
- (void)refreshCards {
  for (BrowserCard* c in _cards) {
    c.chosen = c.tag == _chosen;
    c.needsDisplay = YES;
  }
  if ([_page isEqual:@"import"]) _primary.enabled = _chosen >= 0;
}

- (NSString*)page { return _page; }

- (void)showPage:(NSString*)page {
  if (![[WelcomeView pageOrder] containsObject:page]) return;
  _page = page;
  BOOL dark = WelcomeDark(self);
  NSDictionary* text = @{
    @"welcome" : @[ @"Welcome to NotArc", @"The browser that keeps your tabs, Spaces and logins the way you left them in Arc. Here's a one-minute tour.", @"Get Started", @"" ],
    @"pin" : @[ @"Pin what you keep coming back to", @"Drag a tab above the line to pin it. Everything below is Today: it tidies itself away after a while, and stays searchable in the Archive.",
                @"Next", @"Back" ],
    @"spaces" : @[ @"A Space for each part of your life", @"Work, home, a side project: each Space has its own tabs, colour and icon. Swipe or press Ctrl+1, 2, 3 to move between them.", @"Next", @"Back" ],
    @"split" : @[ @"Two pages, side by side", @"Drag a tab onto the page, or press Ctrl+Shift+=, to open a split view.",
                  @"Next", @"Back" ],
    @"commandbar" : @[ @"Everything starts with Cmd+T", @"Type to search, open a site, switch to a tab or run a command. Cmd+L does the same for the page you're on.", @"Next", @"Back" ],
    @"import" : @[ @"Bring your browser with you", @"Pick where your logins, history and bookmarks come from. The other browser isn't changed.", @"Import", @"Start Fresh" ],
    @"progress" : @[ @"Bringing everything over", @"Your logins, history and extensions are on their way. macOS may ask once to let NotArc read the other browser's key.", @"", @"" ],
    @"done" : @[ @"You're all set", _summary.length ? _summary : @"Everything is ready. Have a calm day on the internet.",
                 @"Start Browsing", @"" ],
  };
  NSArray* t = text[page];
  BOOL hero = [page isEqual:@"welcome"];
  _title.stringValue = t[0];
  _title.font = [NSFont systemFontOfSize:hero ? 38 : 26 weight:hero ? NSFontWeightBold : NSFontWeightSemibold];
  _title.textColor = WelcomeTitle(dark);
  _body.stringValue = t[1];
  _body.textColor = WelcomeText(dark);
  _primary.title = t[2];
  _primary.enabled = ![page isEqual:@"import"] || _chosen >= 0;
  _secondary.title = t[3];
  _picture.kind = page;
  _picture.needsDisplay = YES;
  if ([page isEqual:@"import"] && !_cards.count) _secondary.title = @"";
  if ([page isEqual:@"progress"]) [_spinner startAnimation:nil];
  else [_spinner stopAnimation:nil];
  [self place];
  self.needsDisplay = YES;
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  if (_page) [self showPage:_page];
}

- (void)next {
  NSArray* order = [WelcomeView pageOrder];
  if ([_page isEqual:@"import"]) {
    if (_chosen < 0 || (NSUInteger)_chosen >= _browsers.count) return;
    NSDictionary* browser = _browsers[(NSUInteger)_chosen];
    [self showPage:@"progress"];
    __weak WelcomeView* weakSelf = self;
    void (^done)(NSString*, BOOL) = ^(NSString* summary, BOOL ok) {
      WelcomeView* me = weakSelf;
      if (!me) return;
      me->_summary = summary;
      [me showPage:@"done"];
    };
    if (self.importChosen) self.importChosen(browser, done);
    else done(nil, YES);
    return;
  }
  if ([_page isEqual:@"done"]) {
    if (self.finished) self.finished(_makeDefault.state == NSControlStateValueOn);
    return;
  }
  NSUInteger i = [order indexOfObject:_page];
  NSString* nextPage = i + 1 < order.count ? order[i + 1] : @"done";
  if ([nextPage isEqual:@"import"] && !_browsers.count) nextPage = @"done";  // nothing to import from
  [self showPage:nextPage];
}
- (void)back {
  NSArray* order = [WelcomeView pageOrder];
  NSUInteger i = [order indexOfObject:_page];
  if (i > 0 && i != NSNotFound && i < [order indexOfObject:@"progress"]) [self showPage:order[i - 1]];
}
- (void)skipImport {
  _summary = @"Nothing was imported. You can bring things over any time from File > Import.";
  [self showPage:@"done"];
}
- (void)secondaryPressed:(id)sender {
  if ([_page isEqual:@"import"]) [self skipImport];
  else [self back];
}
- (void)cancelOperation:(id)sender { [self back]; }

- (NSString*)lookDescription {
  return [NSString stringWithFormat:@"glow=1 title=%@ primary=%@ cards=%lu picture=%d", _title.stringValue,
                                    _primary.hidden ? @"-" : _primary.title, (unsigned long)_cards.count, !_picture.hidden];
}
@end
