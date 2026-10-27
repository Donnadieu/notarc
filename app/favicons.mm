#import "app/favicons.h"

#include <sqlite3.h>

NSString* FaviconSiteKey(NSString* url) {
  NSString* host = [NSURL URLWithString:url ?: @""].host.lowercaseString;
  if (!host.length) return nil;
  if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
  return host;
}

static NSImage* ImageFromData(NSData* data) {
  NSImage* img = data.length ? [[NSImage alloc] initWithData:data] : nil;
  if (!img || img.size.width < 1) return nil;
  img.size = NSMakeSize(16, 16);
  return img;
}

// Best bitmap (closest to 32 px) for the exact page, else any page on the same site. Opened immutable so a
// database another browser holds open is never locked or changed.
static NSData* LookupIcon(NSString* dbPath, NSString* url, NSString* site) {
  NSString* uri = [NSString stringWithFormat:@"file:%@?immutable=1",
                                             [dbPath stringByAddingPercentEncodingWithAllowedCharacters:
                                                         NSCharacterSet.URLPathAllowedCharacterSet]];
  sqlite3* db = NULL;
  if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
    sqlite3_close(db);
    return nil;
  }
  const char* sql =
      "SELECT b.image_data FROM icon_mapping m JOIN favicon_bitmaps b ON b.icon_id = m.icon_id "
      "WHERE m.page_url = ?1 OR m.page_url LIKE ?2 OR m.page_url LIKE ?3 "
      "ORDER BY (m.page_url = ?1) DESC, ABS(b.width - 32) LIMIT 1";
  sqlite3_stmt* st = NULL;
  NSData* out = nil;
  if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
    NSString* a = [NSString stringWithFormat:@"%%://%@/%%", site];
    NSString* b = [NSString stringWithFormat:@"%%://www.%@/%%", site];
    sqlite3_bind_text(st, 1, url.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 2, a.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_text(st, 3, b.UTF8String, -1, SQLITE_TRANSIENT);
    if (sqlite3_step(st) == SQLITE_ROW) {
      const void* blob = sqlite3_column_blob(st, 0);
      int n = sqlite3_column_bytes(st, 0);
      if (blob && n > 0) out = [NSData dataWithBytes:blob length:(NSUInteger)n];
    }
  }
  sqlite3_finalize(st);
  sqlite3_close(db);
  return out;
}

@implementation FaviconStore {
  NSMutableDictionary<NSString*, id>* _icons;  // site -> NSImage, or NSNull when no database had one
  NSMutableDictionary<NSString*, NSMutableArray*>* _waiting;
  dispatch_queue_t _queue;
}

+ (instancetype)shared {
  static FaviconStore* s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [FaviconStore new]; });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) {
    _icons = [NSMutableDictionary dictionary];
    _waiting = [NSMutableDictionary dictionary];
    _queue = dispatch_queue_create("notarc.favicons", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (NSImage*)iconForURL:(NSString*)url databases:(NSArray<NSString*>*)databases loaded:(void (^)(void))loaded {
  NSString* site = FaviconSiteKey(url);
  if (!site) return nil;
  id known = _icons[site];
  if (known) return [known isKindOfClass:NSImage.class] ? known : nil;
  NSMutableArray* w = _waiting[site];
  if (w) {
    if (loaded) [w addObject:[loaded copy]];
    return nil;
  }
  _waiting[site] = w = [NSMutableArray array];
  if (loaded) [w addObject:[loaded copy]];
  NSArray* dbs = [databases copy];
  NSString* page = [url copy];
  dispatch_async(_queue, ^{
    NSImage* img = nil;
    for (NSString* path in dbs) {
      if (![NSFileManager.defaultManager fileExistsAtPath:path]) continue;
      if ((img = ImageFromData(LookupIcon(path, page, site)))) break;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->_icons[site] || img) self->_icons[site] = img ?: (id)NSNull.null;
      NSArray* blocks = self->_waiting[site];
      [self->_waiting removeObjectForKey:site];
      if (img)
        for (void (^b)(void) in blocks) b();
    });
  });
  return nil;
}

- (void)setIconData:(NSData*)png forURL:(NSString*)url {
  NSString* site = FaviconSiteKey(url);
  NSImage* img = ImageFromData(png);
  if (site && img) _icons[site] = img;
}

@end
