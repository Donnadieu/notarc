#import "app/archive_store.h"

@implementation ArchivedTab
@end

NSString* ArchiveStorePath(BOOL selfTest) {
  NSString* support =
      [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:@"NotArc"];
  return [support stringByAppendingPathComponent:selfTest ? @"SelfTestArchive.json" : @"Archive.json"];
}

NSMutableArray<ArchivedTab*>* ArchiveStoreLoad(NSString* path) {
  NSMutableArray* out = [NSMutableArray array];
  NSData* bytes = [NSData dataWithContentsOfFile:path];
  NSDictionary* root = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
  if (![root isKindOfClass:NSDictionary.class]) return out;
  for (NSDictionary* d in root[@"items"]) {
    if (![d isKindOfClass:NSDictionary.class]) continue;
    ArchivedTab* t = [ArchivedTab new];
    t.url = d[@"url"];
    t.title = d[@"title"];
    t.spaceID = d[@"spaceID"];
    t.reason = d[@"reason"];
    t.archivedAt = [NSDate dateWithTimeIntervalSinceReferenceDate:[d[@"archivedAt"] doubleValue]];
    [out addObject:t];
  }
  return out;
}

BOOL ArchiveStoreSave(NSArray<ArchivedTab*>* tabs, NSString* path) {
  NSMutableArray* items = [NSMutableArray array];
  for (ArchivedTab* t in tabs)
    [items addObject:@{
      @"url" : t.url ?: @"",
      @"title" : t.title ?: @"",
      @"spaceID" : t.spaceID ?: @"",
      @"reason" : t.reason ?: @"manual",
      @"archivedAt" : @(t.archivedAt.timeIntervalSinceReferenceDate)
    }];
  NSData* bytes = [NSJSONSerialization dataWithJSONObject:@{@"version" : @1, @"items" : items}
                                                  options:NSJSONWritingPrettyPrinted error:nil];
  [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
  return [bytes writeToFile:path atomically:YES];
}

NSTimeInterval AutoArchiveThreshold(void) {
  NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
  if (![d objectForKey:@"autoArchiveThresholdHours"]) return 12 * 3600;
  return [d doubleForKey:@"autoArchiveThresholdHours"] * 3600;
}

NSMutableArray<ArchivedTab*>* ArchiveImportArc(NSString* arcArchivePath) {
  NSMutableArray* out = [NSMutableArray array];
  NSData* bytes = [NSData dataWithContentsOfFile:arcArchivePath];
  NSDictionary* root = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
  if (![root isKindOfClass:NSDictionary.class]) return out;
  for (id entry in root[@"items"]) {  // flat [id, value, id, value] list
    if (![entry isKindOfClass:NSDictionary.class]) continue;
    NSDictionary* tab = entry[@"sidebarItem"][@"data"][@"tab"];
    if (![tab isKindOfClass:NSDictionary.class] || ![tab[@"savedURL"] isKindOfClass:NSString.class]) continue;
    ArchivedTab* t = [ArchivedTab new];
    t.url = tab[@"savedURL"];
    NSString* title = entry[@"sidebarItem"][@"title"];
    t.title = [title isKindOfClass:NSString.class] && title.length ? title : tab[@"savedTitle"];
    if (![t.title isKindOfClass:NSString.class]) t.title = t.url;
    NSDictionary* space = entry[@"source"][@"space"];
    t.spaceID = [space isKindOfClass:NSDictionary.class] ? space[@"_0"] : nil;
    t.reason = [entry[@"reason"] isKindOfClass:NSString.class] ? entry[@"reason"] : @"manual";
    t.archivedAt = [NSDate dateWithTimeIntervalSinceReferenceDate:[entry[@"archivedAt"] doubleValue]];
    [out addObject:t];
  }
  [out sortUsingComparator:^NSComparisonResult(ArchivedTab* a, ArchivedTab* b) {
    return [a.archivedAt compare:b.archivedAt];
  }];
  return out;
}

NSArray<ArchivedTab*>* ArchiveSearch(NSArray<ArchivedTab*>* tabs, NSString* query) {
  NSString* q = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  NSMutableArray* out = [NSMutableArray array];
  for (ArchivedTab* t in tabs.reverseObjectEnumerator) {
    if (q.length && [t.title rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound &&
        [t.url rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound)
      continue;
    [out addObject:t];
  }
  return out;
}
