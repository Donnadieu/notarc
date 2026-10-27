// Site icons for the sidebar: pages report their icon while loaded; tabs that aren't loaded use the icon Chromium
// already saved in the Space's own profile, or (read-only) the one Arc saved for the same site.
#pragma once

#import <AppKit/AppKit.h>

@interface FaviconStore : NSObject
+ (instancetype)shared;
// The icon for the page's site, or nil while unknown. When nil, a lookup in `databases` (Chromium "Favicons" files,
// read-only) starts in the background and `loaded` runs on the main queue if it finds one.
- (NSImage*)iconForURL:(NSString*)url databases:(NSArray<NSString*>*)databases loaded:(void (^)(void))loaded;
// A live page reported its icon (PNG data).
- (void)setIconData:(NSData*)png forURL:(NSString*)url;
@end

NSString* FaviconSiteKey(NSString* url);  // host without "www.", or nil
