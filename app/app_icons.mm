#import "app/app_icons.h"
#import "app/settings.h"

NSString* const kSettingAppIcon = @"appIcon";

// name, title, gradient top, gradient bottom, glyph colour (hex RGB). All NotArc's own colours and artwork.
static NSArray<NSArray*>* Variants() {
  return @[
    @[ @"classic", @"Classic", @0x6E6AF0, @0x3B35B8, @0xFFFFFF ],
    @[ @"sunset", @"Sunset", @0xFF9A4D, @0xE0336F, @0xFFFFFF ],
    @[ @"forest", @"Forest", @0x3FCF8A, @0x0C7352, @0xFFFFFF ],
    @[ @"midnight", @"Midnight", @0x30334A, @0x0B0C16, @0x7FE3FF ],
    @[ @"paper", @"Paper", @0xFFFFFF, @0xDCDDE3, @0x1F2030 ],
    @[ @"candy", @"Candy", @0xFFA6DA, @0x8B7BFF, @0xFFFFFF ],
  ];
}

static NSColor* Hex(NSNumber* n, CGFloat alpha = 1) {
  unsigned v = n.unsignedIntValue;
  return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0
                             alpha:alpha];
}

static NSArray* VariantNamed(NSString* name) {
  for (NSArray* v in Variants())
    if ([v[0] isEqualToString:name]) return v;
  return nil;
}

NSArray<NSString*>* AppIconNames(void) {
  NSMutableArray* out = [NSMutableArray array];
  for (NSArray* v in Variants()) [out addObject:v[0]];
  return out;
}

NSString* AppIconTitle(NSString* name) { return VariantNamed(name)[1] ?: name; }

// The mark: a browser window with a sidebar on the left (NotArc's layout), on a macOS-style rounded square.
static void DrawIcon(NSArray* v, NSRect r) {
  CGFloat s = MIN(r.size.width, r.size.height) / 1024.0;
  NSRect body = NSMakeRect(r.origin.x + 100 * s, r.origin.y + 100 * s, 824 * s, 824 * s);
  NSBezierPath* shape = [NSBezierPath bezierPathWithRoundedRect:body xRadius:185 * s yRadius:185 * s];
  [NSGraphicsContext saveGraphicsState];
  NSShadow* shadow = [NSShadow new];
  shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.28];
  shadow.shadowOffset = NSMakeSize(0, -10 * s);
  shadow.shadowBlurRadius = 24 * s;
  [shadow set];
  [Hex(v[3]) setFill];
  [shape fill];
  [NSGraphicsContext restoreGraphicsState];
  [[[NSGradient alloc] initWithStartingColor:Hex(v[2]) endingColor:Hex(v[3])] drawInBezierPath:shape angle:-90];

  NSColor* glyph = Hex(v[4]);
  NSRect win = NSMakeRect(r.origin.x + 242 * s, r.origin.y + 302 * s, 540 * s, 420 * s);
  NSBezierPath* frame = [NSBezierPath bezierPathWithRoundedRect:win xRadius:64 * s yRadius:64 * s];
  [[glyph colorWithAlphaComponent:0.22] setFill];
  [frame fill];
  // Sidebar strip, clipped to the window's rounded corners.
  [NSGraphicsContext saveGraphicsState];
  [frame addClip];
  [glyph setFill];
  NSRectFill(NSMakeRect(win.origin.x, win.origin.y, 168 * s, win.size.height));
  [NSGraphicsContext restoreGraphicsState];
  frame.lineWidth = 34 * s;
  [glyph setStroke];
  [frame stroke];
  // Window buttons and two tabs in the sidebar, and a page card next to it.
  [Hex(v[3]) setFill];
  for (int i = 0; i < 3; ++i)
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(win.origin.x + (40 + i * 34) * s, NSMaxY(win) - 76 * s, 22 * s, 22 * s)] fill];
  for (int i = 0; i < 2; ++i) {
    NSRect tab = NSMakeRect(win.origin.x + 40 * s, NSMaxY(win) - (150 + i * 60) * s, 96 * s, 26 * s);
    [[NSBezierPath bezierPathWithRoundedRect:tab xRadius:13 * s yRadius:13 * s] fill];
  }
  NSRect page = NSMakeRect(win.origin.x + 206 * s, win.origin.y + 50 * s, win.size.width - 252 * s, win.size.height - 100 * s);
  [[glyph colorWithAlphaComponent:0.9] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:page xRadius:30 * s yRadius:30 * s] fill];
}

NSImage* AppIconImage(NSString* name) {
  static NSMutableDictionary<NSString*, NSImage*>* cache;
  NSArray* v = VariantNamed(name);
  if (!v) return nil;
  if (!cache) cache = [NSMutableDictionary dictionary];
  if (NSImage* img = cache[name]) return img;
  NSImage* img = [NSImage imageWithSize:NSMakeSize(1024, 1024) flipped:NO drawingHandler:^BOOL(NSRect dst) {
    DrawIcon(v, dst);
    return YES;
  }];
  cache[name] = img;
  return img;
}

NSString* CurrentAppIconName(void) {
  id v = SettingValueOrDefault(kSettingAppIcon);
  return [v isKindOfClass:NSString.class] && VariantNamed(v) ? v : @"classic";
}

void ApplyAppIcon(void) { NSApp.applicationIconImage = AppIconImage(CurrentAppIconName()); }

// Both images are drawn at 64x64 with high-quality scaling, then averaged down to 8x8, so a vector image and a
// bitmap copy of it (what NSApp.applicationIconImage hands back) compare as nearly equal.
static NSData* Pixels8(NSImage* image) {
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:64 pixelsHigh:64 bitsPerSample:8
                                                            samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                                                             colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:256
                                                               bitsPerPixel:32];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
  NSGraphicsContext.currentContext.imageInterpolation = NSImageInterpolationHigh;
  [image drawInRect:NSMakeRect(0, 0, 64, 64) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1];
  [NSGraphicsContext restoreGraphicsState];
  uint8_t out[8 * 8 * 4];
  const uint8_t* px = rep.bitmapData;
  for (int by = 0; by < 8; ++by)
    for (int bx = 0; bx < 8; ++bx)
      for (int c = 0; c < 4; ++c) {
        int sum = 0;
        for (int y = 0; y < 8; ++y)
          for (int x = 0; x < 8; ++x) sum += px[(by * 8 + y) * 256 + (bx * 8 + x) * 4 + c];
        out[(by * 8 + bx) * 4 + c] = (uint8_t)(sum / 64);
      }
  return [NSData dataWithBytes:out length:sizeof(out)];
}

CGFloat AppIconDifference(NSImage* a, NSImage* b) {
  if (!a || !b) return 255;
  NSData *pa = Pixels8(a), *pb = Pixels8(b);
  const uint8_t *x = (const uint8_t*)pa.bytes, *y = (const uint8_t*)pb.bytes;
  double sum = 0;
  for (NSUInteger i = 0; i < pa.length; ++i) sum += abs((int)x[i] - (int)y[i]);
  return sum / pa.length;
}
