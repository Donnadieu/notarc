#import "app/arc_history.h"
#import "app/arc_import.h"

#include <sqlite3.h>

NSString* ArcHistoryDBPath(NSString* profileDirectory) {
  return [[[ArcDataDirectory() stringByAppendingPathComponent:@"User Data"] stringByAppendingPathComponent:profileDirectory]
      stringByAppendingPathComponent:@"History"];
}

NSArray<ArchivedTab*>* ArcReadHistory(NSString* dbPath, NSString* spaceName, NSUInteger limit, NSError** error) {
  // immutable=1: never takes a lock or writes a journal, so Arc (even while running) is untouched.
  NSString* uri = [NSString stringWithFormat:@"file:%@?immutable=1",
                                             [dbPath stringByAddingPercentEncodingWithAllowedCharacters:
                                                         NSCharacterSet.URLPathAllowedCharacterSet]];
  sqlite3* db = NULL;
  if (sqlite3_open_v2(uri.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, NULL) != SQLITE_OK) {
    if (error)
      *error = [NSError errorWithDomain:@"ArcHistory" code:1
                               userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"Can't open %@", dbPath]}];
    sqlite3_close(db);
    return nil;
  }
  // Chromium page transitions: core type in the low byte (3 = auto_subframe, 4 = manual_subframe are frames);
  // 0x20000000 / 0x10000000 mark the end / start of a redirect chain - keep only the chain's last hop.
  const char* sql =
      "SELECT u.url, u.title, v.visit_time FROM visits v JOIN urls u ON u.id = v.url "
      "WHERE (v.transition & 255) NOT IN (3, 4) AND ((v.transition & 0x30000000) = 0 OR (v.transition & 0x20000000) != 0) "
      "ORDER BY v.visit_time DESC LIMIT ?1";
  sqlite3_stmt* st = NULL;
  NSMutableArray<ArchivedTab*>* out = [NSMutableArray array];
  if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_int64(st, 1, (sqlite3_int64)limit);
    while (sqlite3_step(st) == SQLITE_ROW) {
      const char* url = (const char*)sqlite3_column_text(st, 0);
      const char* title = (const char*)sqlite3_column_text(st, 1);
      sqlite3_int64 t = sqlite3_column_int64(st, 2);  // microseconds since 1601-01-01
      if (!url || !t) continue;
      ArchivedTab* v = [ArchivedTab new];
      v.url = [NSString stringWithUTF8String:url];
      v.title = title ? [NSString stringWithUTF8String:title] : @"";
      v.reason = spaceName ?: @"";
      v.archivedAt = [NSDate dateWithTimeIntervalSince1970:t / 1e6 - 11644473600.0];
      if (v.url) [out addObject:v];
    }
  } else if (error) {
    *error = [NSError errorWithDomain:@"ArcHistory" code:2
                             userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithUTF8String:sqlite3_errmsg(db)]}];
  }
  sqlite3_finalize(st);
  sqlite3_close(db);
  return [[out reverseObjectEnumerator] allObjects];
}
