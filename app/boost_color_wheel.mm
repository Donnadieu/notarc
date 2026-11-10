#import "app/boost_color_wheel.h"

#include <cmath>

BOOL BoostWheelPick(NSPoint p, NSRect wheel, double* hue, double* saturation) {
  CGFloat radius = MIN(wheel.size.width, wheel.size.height) / 2;
  if (radius <= 0) return NO;
  double dx = p.x - NSMidX(wheel), dy = p.y - NSMidY(wheel);
  double h = atan2(dy, dx) * 180 / M_PI;
  if (h < 0) h += 360;
  if (h >= 360) h -= 360;
  double s = MIN(1.0, hypot(dx, dy) / radius);
  if (hue) *hue = s > 0 ? h : 0;
  if (saturation) *saturation = s;
  return YES;
}

NSPoint BoostWheelPoint(double hue, double saturation, NSRect wheel) {
  CGFloat radius = MIN(wheel.size.width, wheel.size.height) / 2;
  double a = hue * M_PI / 180, r = MAX(0.0, MIN(1.0, saturation)) * radius;
  return NSMakePoint(NSMidX(wheel) + r * cos(a), NSMidY(wheel) + r * sin(a));
}

static void HSBToRGB(double h, double s, double v, double* r, double* g, double* b) {
  h = fmod(h, 360) / 60;
  int i = (int)floor(h);
  double f = h - i, p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f));
  switch (i) {
    case 0: *r = v, *g = t, *b = p; break;
    case 1: *r = q, *g = v, *b = p; break;
    case 2: *r = p, *g = v, *b = t; break;
    case 3: *r = p, *g = q, *b = v; break;
    case 4: *r = t, *g = p, *b = v; break;
    default: *r = v, *g = p, *b = q; break;
  }
}

static BOOL TileIsDark(NSView* v) {
  return [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
         NSAppearanceNameDarkAqua;
}

@implementation BoostTile {
  NSTextField* _titleLabel;
  NSTextField* _subLabel;
  NSImageView* _icon;
  BOOL _hovered, _pressed;
}
- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.wantsLayer = YES;
    _titleLabel = [NSTextField labelWithString:@""];
    _titleLabel.alignment = NSTextAlignmentCenter;
    _titleLabel.lineBreakMode = NSLineBreakByClipping;
    [self addSubview:_titleLabel];
    _subLabel = [NSTextField labelWithString:@""];
    _subLabel.alignment = NSTextAlignmentCenter;
    _subLabel.font = [NSFont systemFontOfSize:9 weight:NSFontWeightMedium];
    _subLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _subLabel.allowsDefaultTighteningForTruncation = YES;
    [self addSubview:_subLabel];
    _icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium];
    [self addSubview:_icon];
    _titleFont = [NSFont systemFontOfSize:17 weight:NSFontWeightMedium];
    self.accessibilityRole = NSAccessibilityButtonRole;
  }
  return self;
}
+ (Class)cellClass { return NSActionCell.class; }  // holds target/action
- (BOOL)wantsUpdateLayer { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)layout {
  [super layout];
  NSSize s = self.bounds.size;
  BOOL sub = _subLabel.stringValue.length > 0;
  CGFloat top = sub ? 13 : 0;
  _titleLabel.frame = NSMakeRect(2, top + (s.height - top - 24) / 2, s.width - 4, 24);
  _icon.frame = NSMakeRect((s.width - 22) / 2, top + (s.height - top - 22) / 2, 22, 22);
  _subLabel.frame = NSMakeRect(-2, 4, s.width + 4, 13);
}
- (void)refreshContent {
  _titleLabel.stringValue = _title ?: @"";
  _titleLabel.font = _titleFont;
  _subLabel.stringValue = _subtitle ?: @"";
  _icon.image = _symbolName ? [NSImage imageWithSystemSymbolName:_symbolName accessibilityDescription:_subtitle ?: _title] : nil;
  _icon.hidden = _icon.image == nil;
  _titleLabel.hidden = !_icon.hidden;
  self.accessibilityLabel = _subtitle.length ? _subtitle : _title;
  self.needsLayout = YES;
  self.needsDisplay = YES;
}
- (void)setTitle:(NSString*)t { _title = [t copy]; [self refreshContent]; }
- (void)setSubtitle:(NSString*)t { _subtitle = [t copy]; [self refreshContent]; }
- (void)setTitleFont:(NSFont*)f { _titleFont = f; [self refreshContent]; }
- (void)setSymbolName:(NSString*)n { _symbolName = [n copy]; [self refreshContent]; }
- (void)setSelected:(BOOL)s { _selected = s; self.needsDisplay = YES; }
- (void)updateLayer {
  BOOL dark = TileIsDark(self);
  // Arc colour catalogue (as used for NotArc's sidebar rows): pressed / hovered / resting fills, and Arc's blue
  // (HoveredAndKeyboardSelectedBackground) for the chosen tile.
  NSColor* fill;
  if (_selected) fill = [NSColor colorWithSRGBRed:0.161 green:0.18 blue:0.757 alpha:1];
  else if (_pressed) fill = dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.065]
                                 : [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.063 alpha:0.12];
  else if (_hovered) fill = dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.15]
                                 : [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.063 alpha:0.10];
  else fill = dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.10]
                   : [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.063 alpha:0.05];
  self.layer.backgroundColor = fill.CGColor;
  self.layer.cornerRadius = 10;
  NSColor* fg = _selected ? NSColor.whiteColor : [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.8];
  _titleLabel.textColor = fg;
  _icon.contentTintColor = fg;
  _subLabel.textColor = _selected ? [NSColor colorWithWhite:1 alpha:0.85] : [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.45];
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                                                             NSTrackingInVisibleRect
                                                       owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)e { _hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)e { _hovered = NO; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent*)e { _pressed = YES; self.needsDisplay = YES; }
- (void)mouseUp:(NSEvent*)e {
  _pressed = NO;
  self.needsDisplay = YES;
  if (NSPointInRect([self convertPoint:e.locationInWindow fromView:nil], self.bounds)) [self sendAction:self.action to:self.target];
}
- (BOOL)accessibilityPerformPress { return [self sendAction:self.action to:self.target]; }
@end

@implementation BoostColorWheel {
  CGImageRef _disc;
  NSSize _discPixels;
  BOOL _dragging;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    _intensity = 0.6;
    _saturation = 0;
    self.accessibilityLabel = @"Boost colour wheel";
    self.accessibilityRole = NSAccessibilityColorWellRole;
  }
  return self;
}
- (void)dealloc {
  if (_disc) CGImageRelease(_disc);
}
- (BOOL)isFlipped { return NO; }
- (BOOL)acceptsFirstMouse:(NSEvent*)e { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (NSRect)wheelRect {
  CGFloat d = MIN(self.bounds.size.width, self.bounds.size.height) - 16;  // room for the puck at the rim
  return NSMakeRect(NSMidX(self.bounds) - d / 2, NSMidY(self.bounds) - d / 2, d, d);
}
- (NSPoint)pointForHue:(double)hue saturation:(double)saturation { return BoostWheelPoint(hue, saturation, [self wheelRect]); }

- (void)setHue:(double)hue saturation:(double)saturation {
  _hue = fmod(fmod(hue, 360) + 360, 360);
  _saturation = MAX(0.0, MIN(1.0, saturation));
  self.needsDisplay = YES;
}
- (void)setHasColor:(BOOL)hasColor {
  _hasColor = hasColor;
  self.needsDisplay = YES;
}
- (void)setIntensity:(double)intensity {
  _intensity = intensity;
  self.needsDisplay = YES;
}

- (void)pickPoint:(NSPoint)p { [self pick:p final:YES]; }
- (void)pick:(NSPoint)p final:(BOOL)final {
  double h = 0, s = 0;
  if (!BoostWheelPick(p, [self wheelRect], &h, &s)) return;
  [self setHue:h saturation:s];
  _hasColor = YES;
  if (self.onChange) self.onChange(self, final);
}

- (void)mouseDown:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  NSRect w = [self wheelRect];
  if (hypot(p.x - NSMidX(w), p.y - NSMidY(w)) > w.size.width / 2 + 10) return;  // outside the disc
  _dragging = YES;
  [self pick:p final:NO];
}
- (void)mouseDragged:(NSEvent*)e {
  if (_dragging) [self pick:[self convertPoint:e.locationInWindow fromView:nil] final:NO];
}
- (void)mouseUp:(NSEvent*)e {
  if (!_dragging) return;
  _dragging = NO;
  [self pick:[self convertPoint:e.locationInWindow fromView:nil] final:YES];
}

// The disc: hue by angle, saturation by distance from the centre, rendered once per size into a bitmap.
- (CGImageRef)discImageForPixels:(NSSize)px {
  if (_disc && NSEqualSizes(px, _discPixels)) return _disc;
  if (_disc) CGImageRelease(_disc);
  size_t w = (size_t)px.width, h = (size_t)px.height;
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, w * 4, cs, kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  uint8_t* data = (uint8_t*)CGBitmapContextGetData(ctx);
  double cx = w / 2.0, cy = h / 2.0, radius = MIN(w, h) / 2.0;
  for (size_t row = 0; row < h; row++) {
    for (size_t col = 0; col < w; col++) {
      double dx = col + 0.5 - cx, dy = cy - (row + 0.5);  // bitmap rows run top-down; y up for the angle
      double d = hypot(dx, dy);
      double alpha = MAX(0.0, MIN(1.0, radius - d));        // one-pixel soft edge
      uint8_t* px8 = data + row * w * 4 + col * 4;
      if (alpha <= 0) { px8[0] = px8[1] = px8[2] = px8[3] = 0; continue; }
      double hue = atan2(dy, dx) * 180 / M_PI;
      if (hue < 0) hue += 360;
      double s = MIN(1.0, d / radius), r, g, b;
      HSBToRGB(hue, pow(s, 0.85), 0.97, &r, &g, &b);
      px8[0] = (uint8_t)lround(r * alpha * 255);
      px8[1] = (uint8_t)lround(g * alpha * 255);
      px8[2] = (uint8_t)lround(b * alpha * 255);
      px8[3] = (uint8_t)lround(alpha * 255);
    }
  }
  _disc = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  _discPixels = px;
  return _disc;
}

- (void)drawRect:(NSRect)dirty {
  NSRect wr = [self wheelRect];
  if (wr.size.width <= 0) return;
  CGFloat scale = self.window.backingScaleFactor ?: 2;
  CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
  CGImageRef disc = [self discImageForPixels:NSMakeSize(ceil(wr.size.width * scale), ceil(wr.size.height * scale))];
  CGContextSaveGState(ctx);
  CGContextSetAlpha(ctx, _hasColor ? 1 : 0.55);  // no colour picked: the wheel waits, a little faded
  CGContextDrawImage(ctx, wr, disc);
  CGContextRestoreGState(ctx);

  // A light dot grid over the disc, so the surface reads as something to drag on.
  NSBezierPath* clip = [NSBezierPath bezierPathWithOvalInRect:wr];
  [NSGraphicsContext saveGraphicsState];
  [clip addClip];
  [[NSColor colorWithWhite:1 alpha:0.28] setFill];
  const CGFloat step = 12, dot = 1.6;
  for (CGFloat y = NSMidY(wr) - floor(wr.size.height / 2 / step) * step; y <= NSMaxY(wr); y += step)
    for (CGFloat x = NSMidX(wr) - floor(wr.size.width / 2 / step) * step; x <= NSMaxX(wr); x += step)
      [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - dot / 2, y - dot / 2, dot, dot)] fill];
  [NSGraphicsContext restoreGraphicsState];
  [[NSColor.labelColor colorWithAlphaComponent:0.12] setStroke];
  NSBezierPath* rim = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(wr, 0.5, 0.5)];
  rim.lineWidth = 1;
  [rim stroke];

  // The puck: a white ring filled with the picked colour (at the chosen intensity).
  NSPoint c = _hasColor ? [self pointForHue:_hue saturation:_saturation] : NSMakePoint(NSMidX(wr), NSMidY(wr));
  NSRect puck = NSMakeRect(c.x - 11, c.y - 11, 22, 22);
  [NSGraphicsContext saveGraphicsState];
  NSShadow* sh = [NSShadow new];
  sh.shadowBlurRadius = 4;
  sh.shadowOffset = NSMakeSize(0, -1);
  sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
  [sh set];
  [[NSColor whiteColor] setFill];
  [[NSBezierPath bezierPathWithOvalInRect:puck] fill];
  [NSGraphicsContext restoreGraphicsState];
  double r = 1, g = 1, b = 1;
  if (_hasColor) HSBToRGB(_hue, pow(_saturation, 0.85), 0.97, &r, &g, &b);  // the same colour as the disc under it
  [[NSColor colorWithSRGBRed:r green:g blue:b alpha:_hasColor ? 0.4 + 0.6 * MAX(0.0, MIN(1.0, _intensity)) : 0.0] setFill];
  [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(puck, 2.5, 2.5)] fill];
  if (!_hasColor) {
    [[NSColor colorWithWhite:0 alpha:0.25] setStroke];
    NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(puck, 6, 6)];
    ring.lineWidth = 1.5;
    [ring stroke];
  }
}
@end
