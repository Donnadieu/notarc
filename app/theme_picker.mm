#import "app/theme_picker.h"

static NSColor* RGB(double r, double g, double b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }
static BOOL PickerDark(NSView* v) {
  return [[v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
      isEqualToString:NSAppearanceNameDarkAqua];
}
static NSString* Hex(NSColor* c) {
  NSColor* s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!s) return nil;
  return [NSString stringWithFormat:@"#%02X%02X%02X", (int)lround(MAX(0, MIN(1, s.redComponent)) * 255),
                                    (int)lround(MAX(0, MIN(1, s.greenComponent)) * 255), (int)lround(MAX(0, MIN(1, s.blueComponent)) * 255)];
}
static NSColor* FromHex(NSString* hex) {
  NSString* h = [hex hasPrefix:@"#"] ? [hex substringFromIndex:1] : hex;
  if (h.length != 6) return nil;
  unsigned v = 0;
  if (![[NSScanner scannerWithString:h] scanHexInt:&v]) return nil;
  return RGB(((v >> 16) & 0xFF) / 255.0, ((v >> 8) & 0xFF) / 255.0, (v & 0xFF) / 255.0);
}

NSColor* ThemePadColor(NSPoint u) {
  CGFloat x = MAX(0, MIN(1, u.x)), y = MAX(0, MIN(1, u.y));
  return [NSColor colorWithHue:x saturation:0.88 - 0.62 * y brightness:0.52 + 0.46 * y alpha:1];
}
NSPoint ThemePadPointForColor(NSColor* color) {
  NSColor* c = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!c) return NSMakePoint(0.5, 0.5);
  CGFloat h = 0, s = 0, b = 0, a = 0;
  [c getHue:&h saturation:&s brightness:&b alpha:&a];
  return NSMakePoint(h, MAX(0, MIN(1, (b - 0.52) / 0.46)));
}

// Preset pages, in Arc's order of kinds. Single colours are Arc 1.169's own swatch values (ColorPicker* assets);
// the gradient page is NotArc's own mix of them.
static NSArray<NSArray<NSArray<NSString*>*>*>* PresetPages() {
  static NSArray* pages;
  if (!pages) {
    NSArray* (^one)(NSArray*) = ^NSArray*(NSArray* rgb) {
      NSMutableArray* out = [NSMutableArray array];
      for (NSArray* c in rgb) [out addObject:@[ Hex(RGB([c[0] doubleValue], [c[1] doubleValue], [c[2] doubleValue])) ]];
      return out;
    };
    NSArray* brand = one(@[ @[ @0.95, @0.918, @0.894 ], @[ @0.95, @0.608, @0.733 ], @[ @0.651, @0.447, @0.616 ],
                            @[ @0.949, @0.369, @0.42 ], @[ @1, @0.235, @0.097 ], @[ @0.95, @0.84, @0.428 ],
                            @[ @0.451, @0.897, @0.612 ], @[ @0.496, @0.721, @0.838 ], @[ @0.401, @0.404, @0.527 ] ]);
    NSArray* pastel = one(@[ @[ @0.994, @0.984, @0.981 ], @[ @0.985, @0.917, @0.951 ], @[ @0.924, @0.825, @0.918 ],
                             @[ @0.968, @0.804, @0.822 ], @[ @0.98, @0.882, @0.834 ], @[ @0.996, @0.977, @0.906 ],
                             @[ @0.894, @0.988, @0.926 ], @[ @0.88, @0.95, @0.984 ], @[ @0.774, @0.776, @0.888 ] ]);
    NSArray* drab = one(@[ @[ @0.294, @0.231, @0.345 ], @[ @0.384, @0.22, @0.337 ], @[ @0.522, @0.267, @0.267 ],
                           @[ @0.655, @0.439, @0.282 ], @[ @0.82, @0.706, @0.416 ], @[ @0.804, @0.8, @0.659 ],
                           @[ @0.518, @0.659, @0.522 ], @[ @0.204, @0.376, @0.294 ], @[ @0.176, @0.267, @0.408 ] ]);
    NSArray* grey = one(@[ @[ @1, @1, @1 ], @[ @0.9, @0.9, @0.9 ], @[ @0.8, @0.8, @0.8 ], @[ @0.7, @0.7, @0.7 ],
                           @[ @0.5, @0.5, @0.5 ], @[ @0.4, @0.4, @0.4 ], @[ @0.2, @0.2, @0.2 ], @[ @0.1, @0.1, @0.1 ],
                           @[ @0, @0, @0 ] ]);
    NSMutableArray* b = [NSMutableArray array];
    for (NSArray* c in brand) [b addObject:c.firstObject];
    NSArray* gradients = @[ @[ b[1], b[2] ], @[ b[3], b[5] ], @[ b[4], b[5] ], @[ b[6], b[7] ], @[ b[7], b[8] ],
                            @[ b[1], b[7] ], @[ b[2], b[8] ], @[ b[3], b[1], b[5] ], @[ b[7], b[2], b[3] ] ];
    pages = @[ gradients, brand, pastel, drab, grey ];
  }
  return pages;
}

#pragma mark Views

@class ThemePickerController;
@interface ThemePickerController ()
- (void)padDidChange;
- (NSMutableArray<NSValue*>*)dots;
@end

// The dotted pad; every grid dot shows the colour it would give, and the theme's dots sit on top with a white ring.
@interface ThemePadView : NSView
@property(nonatomic, weak) ThemePickerController* owner;
@property(nonatomic) NSInteger dragging;
@end
@implementation ThemePadView
- (BOOL)isFlipped { return NO; }
- (NSRect)field { return NSInsetRect(self.bounds, 14, 14); }
- (NSPoint)unitFor:(NSPoint)p {
  NSRect f = self.field;
  return NSMakePoint(MAX(0, MIN(1, (p.x - NSMinX(f)) / NSWidth(f))), MAX(0, MIN(1, (p.y - NSMinY(f)) / NSHeight(f))));
}
- (NSPoint)pointFor:(NSPoint)u {
  NSRect f = self.field;
  return NSMakePoint(NSMinX(f) + u.x * NSWidth(f), NSMinY(f) + u.y * NSHeight(f));
}
- (void)drawRect:(NSRect)dirty {
  BOOL dark = PickerDark(self);
  NSBezierPath* bg = [NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:12 yRadius:12];
  [(dark ? [NSColor colorWithWhite:1 alpha:0.06] : [NSColor colorWithWhite:0 alpha:0.04]) setFill];
  [bg fill];
  NSRect f = self.field;
  const int cols = 17, rows = 11;
  for (int i = 0; i < cols; ++i)
    for (int j = 0; j < rows; ++j) {
      NSPoint u = NSMakePoint(i / (double)(cols - 1), j / (double)(rows - 1));
      NSPoint c = NSMakePoint(NSMinX(f) + u.x * NSWidth(f), NSMinY(f) + u.y * NSHeight(f));
      [[ThemePadColor(u) colorWithAlphaComponent:dark ? 0.8 : 0.85] setFill];
      [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - 2, c.y - 2, 4, 4)] fill];
    }
  NSArray<NSValue*>* dots = self.owner.dots;
  if (dots.count > 1) {  // a thin line through the dots shows the gradient's order
    NSBezierPath* line = [NSBezierPath bezierPath];
    for (NSUInteger i = 0; i < dots.count; ++i) {
      NSPoint p = [self pointFor:dots[i].pointValue];
      if (i) [line lineToPoint:p]; else [line moveToPoint:p];
    }
    [[NSColor colorWithWhite:1 alpha:0.6] setStroke];
    line.lineWidth = 1.5;
    [line stroke];
  }
  for (NSValue* v in dots) {
    NSPoint p = [self pointFor:v.pointValue];
    NSRect r = NSMakeRect(p.x - 11, p.y - 11, 22, 22);
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
    sh.shadowBlurRadius = 4;
    sh.shadowOffset = NSMakeSize(0, -1);
    [sh set];
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:r] fill];
    [NSGraphicsContext restoreGraphicsState];
    [ThemePadColor(v.pointValue) setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 3, 3)] fill];
  }
}
- (void)mouseDown:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  NSMutableArray<NSValue*>* dots = self.owner.dots;
  self.dragging = -1;
  for (NSInteger i = (NSInteger)dots.count - 1; i >= 0; --i) {
    NSPoint d = [self pointFor:dots[(NSUInteger)i].pointValue];
    if (hypot(d.x - p.x, d.y - p.y) <= 14) { self.dragging = i; break; }
  }
  if (self.dragging < 0) {  // a click on the pad moves the last dot there (or adds the first one)
    if (!dots.count) [dots addObject:[NSValue valueWithPoint:[self unitFor:p]]];
    self.dragging = (NSInteger)dots.count - 1;
  }
  [self mouseDragged:e];
}
- (void)mouseDragged:(NSEvent*)e {
  if (self.dragging < 0) return;
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  [self.owner moveDot:(NSUInteger)self.dragging toUnitPoint:[self unitFor:p]];
}
- (void)mouseUp:(NSEvent*)e { self.dragging = -1; }
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

// Intensity as a wave: the further right, the tighter the wave (Arc draws its transparency control this way).
@interface ThemeWaveSlider : NSControl
@property(nonatomic) double value;  // 0.1 ... 1
@end
@implementation ThemeWaveSlider
- (void)drawRect:(NSRect)dirty {
  BOOL dark = PickerDark(self);
  NSRect b = NSInsetRect(self.bounds, 10, 0);
  CGFloat mid = NSMidY(self.bounds), knobX = NSMinX(b) + (self.value - 0.1) / 0.9 * NSWidth(b);
  NSBezierPath* wave = [NSBezierPath bezierPath], *done = [NSBezierPath bezierPath];
  double cycles = 3 + 9 * (self.value - 0.1) / 0.9;
  for (CGFloat x = NSMinX(b); x <= NSMaxX(b); x += 1) {
    CGFloat t = (x - NSMinX(b)) / NSWidth(b);
    NSPoint p = NSMakePoint(x, mid + 4 * sin(t * cycles * 2 * M_PI));
    if (x == NSMinX(b)) [wave moveToPoint:p]; else [wave lineToPoint:p];
    if (x <= knobX) { if (x == NSMinX(b)) [done moveToPoint:p]; else [done lineToPoint:p]; }
  }
  [(dark ? [NSColor colorWithWhite:1 alpha:0.22] : [NSColor colorWithWhite:0 alpha:0.18]) setStroke];
  wave.lineWidth = 2;
  wave.lineCapStyle = NSLineCapStyleRound;
  [wave stroke];
  [(dark ? [NSColor colorWithWhite:1 alpha:0.85] : [NSColor colorWithWhite:0 alpha:0.7]) setStroke];
  done.lineWidth = 2;
  done.lineCapStyle = NSLineCapStyleRound;
  [done stroke];
  NSRect k = NSMakeRect(knobX - 8, mid - 8, 16, 16);
  [NSGraphicsContext saveGraphicsState];
  NSShadow* sh = [NSShadow new];
  sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
  sh.shadowBlurRadius = 3;
  sh.shadowOffset = NSMakeSize(0, -1);
  [sh set];
  [NSColor.whiteColor setFill];
  [[NSBezierPath bezierPathWithOvalInRect:k] fill];
  [NSGraphicsContext restoreGraphicsState];
}
- (void)mouseDown:(NSEvent*)e { [self track:e]; }
- (void)mouseDragged:(NSEvent*)e { [self track:e]; }
- (void)track:(NSEvent*)e {
  NSRect b = NSInsetRect(self.bounds, 10, 0);
  CGFloat x = [self convertPoint:e.locationInWindow fromView:nil].x;
  self.value = 0.1 + 0.9 * MAX(0, MIN(1, (x - NSMinX(b)) / NSWidth(b)));
  self.needsDisplay = YES;
  [self sendAction:self.action to:self.target];
}
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

// Grain as a dial: drag up or around to turn it; the tick shows how much.
@interface ThemeGrainDial : NSControl
@property(nonatomic) double value;  // 0 ... 1
@end
@implementation ThemeGrainDial {
  NSPoint _start;
  double _startValue;
}
- (void)drawRect:(NSRect)dirty {
  BOOL dark = PickerDark(self);
  NSRect r = NSInsetRect(self.bounds, 3, 3);
  [NSGraphicsContext saveGraphicsState];
  NSShadow* sh = [NSShadow new];
  sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
  sh.shadowBlurRadius = 3;
  sh.shadowOffset = NSMakeSize(0, -1);
  [sh set];
  [(dark ? [NSColor colorWithWhite:0.26 alpha:1] : NSColor.whiteColor) setFill];
  [[NSBezierPath bezierPathWithOvalInRect:r] fill];
  [NSGraphicsContext restoreGraphicsState];
  // Ridges around the edge, like a knurled knob.
  NSPoint c = NSMakePoint(NSMidX(r), NSMidY(r));
  CGFloat rad = NSWidth(r) / 2;
  [(dark ? [NSColor colorWithWhite:1 alpha:0.15] : [NSColor colorWithWhite:0 alpha:0.12]) setStroke];
  for (int i = 0; i < 24; ++i) {
    double a = i * M_PI / 12;
    NSBezierPath* t = [NSBezierPath bezierPath];
    [t moveToPoint:NSMakePoint(c.x + cos(a) * (rad - 4), c.y + sin(a) * (rad - 4))];
    [t lineToPoint:NSMakePoint(c.x + cos(a) * (rad - 1), c.y + sin(a) * (rad - 1))];
    [t stroke];
  }
  double angle = (225 - 270 * self.value) * M_PI / 180;  // 7 o'clock (none) to 5 o'clock (most)
  NSBezierPath* tick = [NSBezierPath bezierPath];
  [tick moveToPoint:NSMakePoint(c.x + cos(angle) * rad * 0.2, c.y + sin(angle) * rad * 0.2)];
  [tick lineToPoint:NSMakePoint(c.x + cos(angle) * (rad - 6), c.y + sin(angle) * (rad - 6))];
  [(dark ? [NSColor colorWithWhite:1 alpha:0.9] : [NSColor colorWithWhite:0 alpha:0.75]) setStroke];
  tick.lineWidth = 2.5;
  tick.lineCapStyle = NSLineCapStyleRound;
  [tick stroke];
}
- (void)mouseDown:(NSEvent*)e {
  _start = [self convertPoint:e.locationInWindow fromView:nil];
  _startValue = self.value;
}
- (void)mouseDragged:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  self.value = MAX(0, MIN(1, _startValue + ((p.y - _start.y) + (p.x - _start.x)) / 120.0));
  self.needsDisplay = YES;
  [self sendAction:self.action to:self.target];
}
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

@interface ThemeSwatch : NSButton
@property(nonatomic, copy) NSArray<NSString*>* colors;
@end
@implementation ThemeSwatch
- (void)drawRect:(NSRect)dirty {
  NSRect r = NSInsetRect(self.bounds, 1.5, 1.5);
  NSBezierPath* o = [NSBezierPath bezierPathWithOvalInRect:r];
  NSMutableArray* cs = [NSMutableArray array];
  for (NSString* h in self.colors) if (NSColor* c = FromHex(h)) [cs addObject:c];
  if (cs.count > 1) [[[NSGradient alloc] initWithColors:cs] drawInBezierPath:o angle:-45];
  else { [(NSColor*)cs.firstObject ?: NSColor.grayColor setFill]; [o fill]; }
  [(PickerDark(self) ? [NSColor colorWithWhite:1 alpha:0.2] : [NSColor colorWithWhite:0 alpha:0.12]) setStroke];
  o.lineWidth = 1;
  [o stroke];
}
@end

#pragma mark Controller

@implementation ThemePickerController {
  NSMutableArray<NSValue*>* _dots;
  double _intensity, _grain;
  NSString* _scheme;
  ThemePadView* _pad;
  ThemeWaveSlider* _wave;
  ThemeGrainDial* _dial;
  NSSegmentedControl* _modes;
  NSButton* _plus, *_minus;
  NSMutableArray<ThemeSwatch*>* _swatches;
  NSUInteger _page;
  NSArray<NSString*>* _exactColors;  // a preset's own colours until a dot moves
}

- (instancetype)initWithColors:(NSArray<NSString*>*)colors intensity:(double)intensity grain:(double)grain scheme:(NSString*)scheme {
  if ((self = [super initWithNibName:nil bundle:nil])) {
    _dots = [NSMutableArray array];
    for (NSString* h in colors)
      if (NSColor* c = FromHex(h)) [_dots addObject:[NSValue valueWithPoint:ThemePadPointForColor(c)]];
    while (_dots.count > 3) [_dots removeLastObject];
    _exactColors = colors.count ? [colors subarrayWithRange:NSMakeRange(0, MIN(colors.count, (NSUInteger)3))] : nil;
    _intensity = colors.count ? MAX(0.1, MIN(1, intensity ?: 0.5)) : 0.5;
    _grain = MAX(0, MIN(1, grain));
    _scheme = [scheme isEqual:@"light"] || [scheme isEqual:@"dark"] ? scheme : @"auto";
  }
  return self;
}

- (NSMutableArray<NSValue*>*)dots { return _dots; }

static NSButton* RoundIcon(NSString* symbol, NSString* tip, id target, SEL action) {
  NSButton* b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip]
                                   target:target action:action];
  b.bezelStyle = NSBezelStyleCircular;
  b.bordered = YES;
  b.toolTip = tip;
  return b;
}

- (void)loadView {
  const CGFloat W = 300;
  NSView* v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, 356)];
  _modes = [NSSegmentedControl segmentedControlWithImages:@[
    [NSImage imageWithSystemSymbolName:@"sparkles" accessibilityDescription:@"Automatic"],
    [NSImage imageWithSystemSymbolName:@"sun.max" accessibilityDescription:@"Light"],
    [NSImage imageWithSystemSymbolName:@"moon" accessibilityDescription:@"Dark"],
  ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(modeClicked:)];
  for (NSInteger i = 0; i < 3; ++i) {
    [_modes setWidth:34 forSegment:i];
    [_modes setToolTip:@[ @"Automatic", @"Light", @"Dark" ][(NSUInteger)i] forSegment:i];
  }
  _modes.frame = NSMakeRect(16, 318, 112, 24);
  _modes.selectedSegment = (NSInteger)[@[ @"auto", @"light", @"dark" ] indexOfObject:_scheme];
  _minus = RoundIcon(@"minus", @"Remove a colour", self, @selector(removeDot));
  _plus = RoundIcon(@"plus", @"Add a colour", self, @selector(addDot));
  _minus.frame = NSMakeRect(W - 16 - 58, 316, 28, 28);
  _plus.frame = NSMakeRect(W - 16 - 28, 316, 28, 28);
  _pad = [[ThemePadView alloc] initWithFrame:NSMakeRect(16, 112, W - 32, 194)];
  _pad.owner = self;
  _pad.dragging = -1;
  _wave = [[ThemeWaveSlider alloc] initWithFrame:NSMakeRect(10, 64, W - 82, 34)];
  _wave.value = _intensity;
  _wave.target = self;
  _wave.action = @selector(waveChanged:);
  _wave.toolTip = @"Intensity";
  _dial = [[ThemeGrainDial alloc] initWithFrame:NSMakeRect(W - 16 - 40, 61, 40, 40)];
  _dial.value = _grain;
  _dial.target = self;
  _dial.action = @selector(dialChanged:);
  _dial.toolTip = @"Grain";
  NSButton* prev = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Previous"]
                                      target:self action:@selector(prevPage:)];
  NSButton* next = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.right" accessibilityDescription:@"Next"]
                                      target:self action:@selector(nextPage:)];
  for (NSButton* b in @[ prev, next ]) b.bordered = NO;
  prev.frame = NSMakeRect(10, 20, 16, 24);
  next.frame = NSMakeRect(W - 26, 20, 16, 24);
  _swatches = [NSMutableArray array];
  const CGFloat sw = 22, gap = (W - 64 - 9 * sw) / 8;
  for (NSUInteger i = 0; i < 9; ++i) {
    ThemeSwatch* s = [[ThemeSwatch alloc] initWithFrame:NSMakeRect(32 + i * (sw + gap), 21, sw, sw)];
    s.bordered = NO;
    s.title = @"";
    s.tag = (NSInteger)i;
    s.target = self;
    s.action = @selector(swatchClicked:);
    [_swatches addObject:s];
    [v addSubview:s];
  }
  for (NSView* x in @[ _modes, _minus, _plus, _pad, _wave, _dial, prev, next ]) [v addSubview:x];
  self.view = v;
  self.preferredContentSize = v.frame.size;
  [self showPage:0];
  [self refreshControls];
}

- (void)showPage:(NSUInteger)page {
  NSArray* p = PresetPages()[page % PresetPages().count];
  _page = page % PresetPages().count;
  for (NSUInteger i = 0; i < _swatches.count; ++i) {
    _swatches[i].colors = i < p.count ? p[i] : @[];
    _swatches[i].hidden = i >= p.count;
    _swatches[i].needsDisplay = YES;
  }
}
- (void)prevPage:(id)sender { [self showPage:_page + PresetPages().count - 1]; }
- (void)nextPage:(id)sender { [self showPage:_page + 1]; }
- (NSUInteger)presetPageCount { return PresetPages().count; }

- (void)refreshControls {
  _minus.enabled = _dots.count > 0;
  _plus.enabled = _dots.count < 3;
  _wave.enabled = _dots.count > 0;
  _wave.alphaValue = _dots.count ? 1 : 0.4;
  _pad.needsDisplay = YES;
}

- (NSArray<NSString*>*)colors {
  if (_exactColors.count == _dots.count && _exactColors) return _exactColors;
  NSMutableArray* out = [NSMutableArray array];
  for (NSValue* d in _dots) [out addObject:Hex(ThemePadColor(d.pointValue))];
  return out;
}
- (double)intensity { return _intensity; }
- (double)grain { return _grain; }
- (NSString*)scheme { return _scheme; }

- (void)padDidChange {
  [self refreshControls];
  if (self.themeChanged) self.themeChanged(self.colors, _intensity, _grain);
}

- (void)addDot {
  if (_dots.count >= 3) return;
  _exactColors = nil;
  NSPoint last = _dots.count ? _dots.lastObject.pointValue : NSMakePoint(0.7, 0.55);
  NSPoint p = _dots.count ? NSMakePoint(fmod(last.x + 0.2, 1.0), MAX(0.15, MIN(0.85, last.y + (_dots.count == 1 ? -0.2 : 0.25))))
                          : last;
  [_dots addObject:[NSValue valueWithPoint:p]];
  [self padDidChange];
}
- (void)removeDot {
  if (!_dots.count) return;
  [_dots removeLastObject];
  _exactColors = nil;
  [self padDidChange];
}
- (void)moveDot:(NSUInteger)index toUnitPoint:(NSPoint)p {
  if (index >= _dots.count) return;
  _exactColors = nil;
  _dots[index] = [NSValue valueWithPoint:NSMakePoint(MAX(0, MIN(1, p.x)), MAX(0, MIN(1, p.y)))];
  [self padDidChange];
}
- (void)pickPreset:(NSUInteger)index onPage:(NSUInteger)page {
  NSArray* p = PresetPages()[page % PresetPages().count];
  if (index >= p.count) return;
  NSArray<NSString*>* colors = p[index];
  [_dots removeAllObjects];
  for (NSString* h in colors) [_dots addObject:[NSValue valueWithPoint:ThemePadPointForColor(FromHex(h))]];
  _exactColors = colors;
  [self padDidChange];
}
- (void)swatchClicked:(NSButton*)sender { [self pickPreset:(NSUInteger)sender.tag onPage:_page]; }

- (void)chooseScheme:(NSString*)scheme {
  _scheme = [scheme isEqual:@"light"] || [scheme isEqual:@"dark"] ? scheme : @"auto";
  _modes.selectedSegment = (NSInteger)[@[ @"auto", @"light", @"dark" ] indexOfObject:_scheme];
  if (self.schemeChanged) self.schemeChanged(_scheme);
}
- (void)modeClicked:(NSSegmentedControl*)sender {
  [self chooseScheme:@[ @"auto", @"light", @"dark" ][(NSUInteger)MAX(0, MIN(2, sender.selectedSegment))]];
}
- (void)setIntensityValue:(double)v {
  _intensity = MAX(0.1, MIN(1, v));
  _wave.value = _intensity;
  _wave.needsDisplay = YES;
  if (_dots.count && self.themeChanged) self.themeChanged(self.colors, _intensity, _grain);
}
- (void)setGrainValue:(double)v {
  _grain = MAX(0, MIN(1, v));
  _dial.value = _grain;
  _dial.needsDisplay = YES;
  if (self.themeChanged) self.themeChanged(self.colors, _intensity, _grain);
}
- (void)waveChanged:(ThemeWaveSlider*)s { [self setIntensityValue:s.value]; }
- (void)dialChanged:(ThemeGrainDial*)d { [self setGrainValue:d.value]; }

- (NSString*)lookDescription {
  (void)self.view;
  NSUInteger shown = 0;
  for (ThemeSwatch* s in _swatches) shown += !s.hidden;
  return [NSString stringWithFormat:@"pad=%d dots=%lu modes=%ld wave=%d dial=%d swatches=%lu pages=%lu plusMinus=%d",
                                    _pad != nil, (unsigned long)_dots.count, (long)_modes.segmentCount, _wave != nil, _dial != nil,
                                    (unsigned long)shown, (unsigned long)PresetPages().count, _plus != nil && _minus != nil];
}
@end
