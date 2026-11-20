#import "app/favicon_colors.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <vector>

// Pixels darker, lighter or greyer than this carry no hue worth showing.
static constexpr float kMinSaturation = 0.28f, kMinBrightness = 0.16f;
static constexpr int kHueBins = 36;  // 10 degrees each

void FavColorToHSB(FavColor c, float* h, float* s, float* v) {
  float mx = std::max({c.r, c.g, c.b}), mn = std::min({c.r, c.g, c.b}), d = mx - mn;
  *v = mx;
  *s = mx > 0 ? d / mx : 0;
  float hue = 0;
  if (d > 0) {
    if (mx == c.r) hue = fmodf((c.g - c.b) / d, 6);
    else if (mx == c.g) hue = (c.b - c.r) / d + 2;
    else hue = (c.r - c.g) / d + 4;
    hue *= 60;
    if (hue < 0) hue += 360;
  }
  *h = hue;
}

static FavColor FromHSB(float h, float s, float v) {
  float c = v * s, x = c * (1 - fabsf(fmodf(h / 60, 2) - 1)), m = v - c, r = 0, g = 0, b = 0;
  if (h < 60) r = c, g = x;
  else if (h < 120) r = x, g = c;
  else if (h < 180) g = c, b = x;
  else if (h < 240) g = x, b = c;
  else if (h < 300) r = x, b = c;
  else r = c, b = x;
  FavColor o;
  o.r = r + m, o.g = g + m, o.b = b + m, o.ok = true;
  return o;
}

bool FavColorIsNeutral(FavColor c) {
  if (!c.ok) return true;
  float h, s, v;
  FavColorToHSB(c, &h, &s, &v);
  return s < kMinSaturation || v < kMinBrightness;
}

// Arc's "clamping" strategy: keep the hue, pull saturation and brightness into a band, so a dark slate (Basecamp)
// still shows as a colour and a neon one isn't loud.
FavColor FavGlowColor(FavColor c) {
  if (!c.ok) return c;
  float h, s, v;
  FavColorToHSB(c, &h, &s, &v);
  return FromHSB(h, std::clamp(s, 0.35f, 0.85f), std::clamp(v, 0.6f, 0.96f));
}

namespace {
struct Acc {  // weighted colour sums per hue bin
  double w[kHueBins] = {}, r[kHueBins] = {}, g[kHueBins] = {}, b[kHueBins] = {};
  void add(int bin, double wt, float rr, float gg, float bb) {
    w[bin] += wt, r[bin] += wt * rr, g[bin] += wt * gg, b[bin] += wt * bb;
  }
  double total() const {
    double t = 0;
    for (double x : w) t += x;
    return t;
  }
  // The heaviest hue (a bin with its two neighbours), as the weighted average colour of those three bins.
  FavColor best(double minWeight) const {
    int top = -1;
    double topW = 0;
    for (int i = 0; i < kHueBins; ++i) {
      double s = w[i] + w[(i + 1) % kHueBins] + w[(i + kHueBins - 1) % kHueBins];
      if (s > topW) topW = s, top = i;
    }
    FavColor o;
    if (top < 0 || topW < minWeight) return o;
    double sw = 0, sr = 0, sg = 0, sb = 0;
    for (int k = -1; k <= 1; ++k) {
      int i = (top + k + kHueBins) % kHueBins;
      sw += w[i], sr += r[i], sg += g[i], sb += b[i];
    }
    o.r = (float)(sr / sw), o.g = (float)(sg / sw), o.b = (float)(sb / sw), o.ok = true;
    return o;
  }
};
}  // namespace

FavPalette FaviconPaletteFromRGBA(const uint8_t* rgba, int width, int height, size_t rowBytes, bool premultiplied) {
  FavPalette out;
  if (!rgba || width <= 0 || height <= 0) return out;
  Acc all, side[kFavRingStops];
  double opaque = 0;
  const double cx = (width - 1) / 2.0, cy = (height - 1) / 2.0;
  for (int y = 0; y < height; ++y) {
    const uint8_t* row = rgba + (size_t)y * rowBytes;
    for (int x = 0; x < width; ++x) {
      const uint8_t* p = row + x * 4;
      float a = p[3] / 255.0f;
      if (a < 0.5f) continue;
      opaque += 1;
      float k = premultiplied ? 1 / a : 1;
      FavColor c;
      c.r = std::min(1.0f, p[0] / 255.0f * k), c.g = std::min(1.0f, p[1] / 255.0f * k), c.b = std::min(1.0f, p[2] / 255.0f * k);
      float h, s, v;
      FavColorToHSB(c, &h, &s, &v);
      if (s < kMinSaturation || v < kMinBrightness) continue;  // white, black, grey
      int bin = std::min(kHueBins - 1, (int)(h / (360.0f / kHueBins)));
      double wt = a * (0.5 + s);  // vivid pixels count a little more
      all.add(bin, wt, c.r, c.g, c.b);
      // Which side of the icon: 0 = top, then clockwise (y grows downward).
      double ang = atan2(x - cx, cy - y) * 180 / M_PI;
      if (ang < 0) ang += 360;
      int sec = (int)floor((ang + 180.0 / kFavRingStops) / (360.0 / kFavRingStops)) % kFavRingStops;
      side[sec].add(bin, wt, c.r, c.g, c.b);
    }
  }
  if (opaque <= 0) return out;
  // A few coloured pixels in a grey icon (anti-aliasing) don't make it a coloured icon.
  out.dominant = all.best(std::max(2.0, opaque * 0.04));
  for (int i = 0; i < kFavRingStops; ++i) {
    FavColor c = side[i].best(std::max(1.0, opaque * 0.01));
    out.ring[i] = c.ok ? c : out.dominant;
  }
  return out;
}

FavPalette FaviconPaletteFromCGImage(CGImageRef image) {
  FavPalette out;
  if (!image) return out;
  const int n = 32;
  std::vector<uint8_t> px(n * n * 4, 0);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(px.data(), n, n, 8, n * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast | (CGBitmapInfo)kCGBitmapByteOrder32Big);
  CGColorSpaceRelease(cs);
  if (!ctx) return out;
  CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
  CGContextDrawImage(ctx, CGRectMake(0, 0, n, n), image);  // row 0 of the buffer is the image's top
  CGContextRelease(ctx);
  return FaviconPaletteFromRGBA(px.data(), n, n, n * 4, true);
}

static int HexDigit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

FavColor FavColorFromCSS(const std::string& in) {
  FavColor o;
  std::string s;
  for (char c : in)
    if (!isspace((unsigned char)c)) s += (char)tolower((unsigned char)c);
  if (!s.empty() && s[0] == '#') {
    std::string h = s.substr(1);
    for (char c : h)
      if (HexDigit(c) < 0) return o;
    if (h.size() == 3 || h.size() == 4) {
      o.r = HexDigit(h[0]) * 17 / 255.0f, o.g = HexDigit(h[1]) * 17 / 255.0f, o.b = HexDigit(h[2]) * 17 / 255.0f;
    } else if (h.size() == 6 || h.size() == 8) {
      o.r = (HexDigit(h[0]) * 16 + HexDigit(h[1])) / 255.0f, o.g = (HexDigit(h[2]) * 16 + HexDigit(h[3])) / 255.0f,
      o.b = (HexDigit(h[4]) * 16 + HexDigit(h[5])) / 255.0f;
    } else {
      return o;
    }
    o.ok = true;
    return o;
  }
  size_t open = s.find('(');
  if ((s.rfind("rgb(", 0) == 0 || s.rfind("rgba(", 0) == 0) && open != std::string::npos && s.back() == ')') {
    float v[3];
    const char* p = s.c_str() + open + 1;
    for (int i = 0; i < 3; ++i) {
      char* end = nullptr;
      v[i] = strtof(p, &end);
      if (end == p) return o;
      if (*end == '%') v[i] *= 2.55f, ++end;
      p = end;
      if (i < 2) {
        if (*p != ',') return o;
        ++p;
      }
    }
    o.r = std::clamp(v[0] / 255, 0.0f, 1.0f), o.g = std::clamp(v[1] / 255, 0.0f, 1.0f), o.b = std::clamp(v[2] / 255, 0.0f, 1.0f);
    o.ok = true;
  }
  return o;
}

NSString* const kFaviconThemeColorJS =
    @"(function(){var m=document.querySelector('meta[name=\"theme-color\"]');"
     "console.log('__notarc_theme__:'+((m&&m.content)||'').slice(0,60));})()";

static NSColor* NSColorFrom(FavColor c) { return [NSColor colorWithSRGBRed:c.r green:c.g blue:c.b alpha:1]; }

@interface FaviconColors ()
@property(nonatomic, readwrite) NSColor* tint;
@property(nonatomic, readwrite) NSArray<NSColor*>* ring;
@property(nonatomic, readwrite) BOOL fromTheme;
@end
@implementation FaviconColors
+ (instancetype)withPalette:(const FavPalette&)p {
  FaviconColors* c = [FaviconColors new];
  if (!p.dominant.ok) return c;
  c.tint = NSColorFrom(FavGlowColor(p.dominant));
  NSMutableArray* ring = [NSMutableArray array];
  for (int i = 0; i < kFavRingStops; ++i) [ring addObject:NSColorFrom(FavGlowColor(p.ring[i]))];
  c.ring = ring;
  return c;
}
@end

// Per icon image: its palette, worked out once on a background queue. The colours shown for a Favorite are that,
// or (for an icon without colour) the site's theme-color.
@interface FaviconPaletteBox : NSObject {
 @public
  FavPalette palette;
}
@end
@implementation FaviconPaletteBox
@end

@implementation FaviconColorStore {
  NSMapTable<NSImage*, id>* _palettes;  // icon -> FaviconPaletteBox, or NSNull while being worked out
  NSMapTable<NSImage*, NSMutableArray*>* _waiting;
  NSMutableDictionary<NSString*, NSValue*>* _themes;  // site -> FavColor (in an NSValue)
  NSMapTable<NSImage*, NSMutableDictionary*>* _shown;  // icon -> {site|theme: colours handed out (stable objects)}
  dispatch_queue_t _queue;
  std::atomic<NSUInteger> _computed, _onMain;
}

+ (instancetype)shared {
  static FaviconColorStore* s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [FaviconColorStore new]; });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) {
    _palettes = [NSMapTable weakToStrongObjectsMapTable];
    _waiting = [NSMapTable weakToStrongObjectsMapTable];
    _themes = [NSMutableDictionary dictionary];
    _shown = [NSMapTable weakToStrongObjectsMapTable];
    _queue = dispatch_queue_create("notarc.favicon-colors", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
  }
  return self;
}

- (NSUInteger)computeCount { return _computed.load(); }
- (NSUInteger)onMainCount { return _onMain.load(); }

- (FaviconColors*)colorsForPalette:(const FavPalette&)p icon:(NSImage*)icon site:(NSString*)site {
  NSValue* theme = site ? _themes[site] : nil;
  BOOL useTheme = !p.dominant.ok && theme;
  NSString* key = [NSString stringWithFormat:@"%@|%d", site ?: @"", useTheme];
  NSMutableDictionary* forIcon = [_shown objectForKey:icon];
  if (!forIcon) [_shown setObject:(forIcon = [NSMutableDictionary dictionary]) forKey:icon];
  FaviconColors* c = forIcon[key];
  if (c) return c;
  if (useTheme) {
    FavColor t;
    [theme getValue:&t size:sizeof(t)];
    FavPalette tp;
    tp.dominant = t;
    for (int i = 0; i < kFavRingStops; ++i) tp.ring[i] = t;
    c = [FaviconColors withPalette:tp];
    c.fromTheme = YES;
  } else {
    c = [FaviconColors withPalette:p];
  }
  forIcon[key] = c;
  return c;
}

- (FaviconColors*)colorsForIcon:(NSImage*)icon site:(NSString*)site ready:(void (^)(void))ready {
  if (!icon) return nil;
  id known = [_palettes objectForKey:icon];
  if ([known isKindOfClass:FaviconPaletteBox.class])
    return [self colorsForPalette:((FaviconPaletteBox*)known)->palette icon:icon site:site];
  NSMutableArray* w = [_waiting objectForKey:icon];
  if (ready) {
    if (!w) [_waiting setObject:(w = [NSMutableArray array]) forKey:icon];
    [w addObject:[ready copy]];
  }
  if (known) return nil;  // already being worked out
  [_palettes setObject:NSNull.null forKey:icon];
  FaviconPaletteBox* box = [FaviconPaletteBox new];
  if (icon.isTemplate) {  // a symbol stand-in (globe), not a site's icon: neutral
    [_palettes setObject:box forKey:icon];
    _computed++;
    [self finish:icon];
    return nil;
  }
  // NSImage -> CGImage on the main thread (cheap, no pixels touched); the pixels are read in the background.
  CGImageRef cg = [icon CGImageForProposedRect:NULL context:nil hints:nil];
  if (cg) CGImageRetain(cg);
  __weak NSImage* weakIcon = icon;
  dispatch_async(_queue, ^{
    if (NSThread.isMainThread) self->_onMain++;
    FavPalette p = FaviconPaletteFromCGImage(cg);
    if (cg) CGImageRelease(cg);
    self->_computed++;
    dispatch_async(dispatch_get_main_queue(), ^{
      NSImage* i = weakIcon;
      if (!i) return;
      box->palette = p;
      [self->_palettes setObject:box forKey:i];
      [self finish:i];
    });
  });
  return nil;
}

- (void)finish:(NSImage*)icon {
  NSArray* blocks = [[_waiting objectForKey:icon] copy];
  [_waiting removeObjectForKey:icon];
  for (void (^b)(void) in blocks) b();
}

- (BOOL)setThemeColor:(NSString*)css forSite:(NSString*)site {
  if (!site.length) return NO;
  FavColor c = FavColorFromCSS(css.UTF8String ?: "");
  NSValue* now = (c.ok && !FavColorIsNeutral(c)) ? [NSValue valueWithBytes:&c objCType:@encode(FavColor)] : nil;
  NSValue* was = _themes[site];
  if ((!now && !was) || [now isEqual:was]) return NO;
  _themes[site] = now;
  return YES;
}

@end
