// Favorite tile colours, as in Arc: the open Favorite gets a thin border in its site's colours and a light tint of
// them, and a fainter one on hover. Arc takes them from the favicon (its FaviconDominantColorFetcher, a median-cut
// "dominant colour" with a clamping strategy); a multi-colour icon such as Gmail's gives a border that runs through
// its colours around the tile.
//
// The colours come from the icon's pixels: the most common saturated colour (white, black and grey are skipped),
// plus one colour per side of the icon for the border's gradient. Icons with no colour (GitHub's black cat) fall back
// to the page's <meta name="theme-color">, then to a neutral tint. Work happens on a background queue, once per icon
// image, cached; a new favicon is a new image and gets new colours.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>

struct FavColor {
  float r = 0, g = 0, b = 0;  // sRGB 0..1
  bool ok = false;
};

constexpr int kFavRingStops = 8;  // border gradient stops, starting at the top, clockwise

struct FavPalette {
  FavColor dominant;              // most common saturated colour; ok=false for black/white/grey icons
  FavColor ring[kFavRingStops];   // the colour on each side of the icon (falls back to dominant)
};

// Pixels: 8-bit RGBA, rows top to bottom. `premultiplied`: colour channels already multiplied by alpha.
FavPalette FaviconPaletteFromRGBA(const uint8_t* rgba, int width, int height, size_t rowBytes, bool premultiplied);
// "#rgb", "#rrggbb", "#rrggbbaa", "rgb(r, g, b)", "rgba(r, g, b, a)" -> colour; anything else (names, var()) -> ok=false.
FavColor FavColorFromCSS(const std::string& css);
// White, black or grey (no hue to show).
bool FavColorIsNeutral(FavColor c);
// The colour as drawn: brightness and saturation clamped into a band that reads on light and dark sidebars.
FavColor FavGlowColor(FavColor c);
void FavColorToHSB(FavColor c, float* h, float* s, float* v);  // h in degrees 0..360

#ifdef __OBJC__
#import <AppKit/AppKit.h>

@interface FaviconColors : NSObject
@property(nonatomic, readonly) NSColor* tint;                 // the main colour, clamped for drawing; nil = neutral
@property(nonatomic, readonly) NSArray<NSColor*>* ring;       // kFavRingStops colours around the tile (top, clockwise)
@property(nonatomic, readonly) BOOL fromTheme;                // the icon had no colour; the page's theme-color is used
@end

@interface FaviconColorStore : NSObject
+ (instancetype)shared;
// The colours for a favicon, or nil while they're being worked out (`ready` then runs on the main queue).
// `site` (FaviconSiteKey) picks the page's theme-color when the icon itself has no colour.
- (FaviconColors*)colorsForIcon:(NSImage*)icon site:(NSString*)site ready:(void (^)(void))ready;
// A page reported its <meta name="theme-color"> (CSS colour text; empty clears). Returns YES when it changed.
- (BOOL)setThemeColor:(NSString*)css forSite:(NSString*)site;
@property(nonatomic, readonly) NSUInteger computeCount;   // tests: icons worked out so far
@property(nonatomic, readonly) NSUInteger onMainCount;    // tests: of those, how many ran on the main thread (want 0)
@end

// The palette of an image (drawn at 32x32). Thread-safe.
FavPalette FaviconPaletteFromCGImage(CGImageRef image);

// The page script that reports the theme-color as a "__notarc_theme__:<css>" console line.
extern NSString* const kFaviconThemeColorJS;
#endif
