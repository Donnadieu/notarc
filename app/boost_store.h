// Boosts: per-site customisations (Arc 1.169 Boosts, rebuilt from scratch, stored locally in Boosts.json).
// A Boost matches a host (and its subdomains) and can recolour the page, change font, text size and case,
// hide ("zap") elements by CSS selector, and add custom CSS and JavaScript.
#pragma once

#import <Foundation/Foundation.h>

@interface Boost : NSObject
@property(nonatomic, copy) NSString* host;          // e.g. "example.org"
@property(nonatomic) BOOL enabled;
@property(nonatomic) double hue;                    // 0-360, or < 0 for no colour
@property(nonatomic) double colorStrength;          // 0-1
@property(nonatomic, copy) NSString* font;          // nil = page font
@property(nonatomic) double textZoom;               // 1 = 100%
@property(nonatomic, copy) NSString* textTransform; // nil, "uppercase", "lowercase"
@property(nonatomic, strong) NSMutableArray<NSString*>* zaps;  // CSS selectors to hide
@property(nonatomic, copy) NSString* css;
@property(nonatomic, copy) NSString* js;
- (BOOL)matchesURL:(NSString*)url;
- (NSString*)styleSheet;   // everything except custom JS, as one CSS string
@end

NSString* BoostStorePath(BOOL selfTest);
NSMutableArray<Boost*>* BoostStoreLoad(NSString* path);
BOOL BoostStoreSave(NSArray<Boost*>* boosts, NSString* path);
// Host of a URL without "www.", lowercased; nil for non-web URLs.
NSString* BoostHostForURL(NSString* url);
// JavaScript that applies (or, when boost is nil/disabled, removes) a Boost in the page. Idempotent.
NSString* BoostApplyScript(Boost* boost);
// JavaScript for Zap mode: highlights the element under the mouse; a click reports its selector through
// console.log("__notarc_zap__:<selector>"); Escape reports "__notarc_zap__:" (cancel).
NSString* BoostZapModeScript(void);
