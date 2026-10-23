#import "app/sidebar_store.h"

// Format (version 1):
// { "version": 1, "focusedSpaceID": "...", "spaces": [
//     { "id", "title", "profile", "favorites": Item?, "pinned": Item, "today": Item } ] }
// Item: { "id", "title"?, "savedTitle"?, "url"?, "folder": bool, "children": [Item] }
// Favorites shared by Spaces on the same profile are written once per Space and re-shared on load.

static const NSInteger kStoreVersion = 1;

NSString* SidebarStorePath(BOOL selfTest) {
  NSString* support =
      [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:@"NotArc"];
  return [support stringByAppendingPathComponent:selfTest ? @"SelfTestSidebar.json" : @"Sidebar.json"];
}

static NSDictionary* EncodeItem(ArcItem* item) {
  NSMutableDictionary* d = [NSMutableDictionary dictionary];
  d[@"id"] = item.itemID ?: NSUUID.UUID.UUIDString;
  if (item.title.length && !item.isSection) d[@"title"] = item.title;
  if (item.liveTitle.length) d[@"savedTitle"] = item.liveTitle;
  if (item.url.length) d[@"url"] = item.url;
  if (item.pinnedURL.length) d[@"pinnedURL"] = item.pinnedURL;
  if (item.lastActiveAt) d[@"lastActiveAt"] = @(item.lastActiveAt.timeIntervalSinceReferenceDate);
  d[@"folder"] = @(item.isFolder);
  if (item.isSplit) {
    d[@"split"] = @YES;
    d[@"horizontal"] = @(item.splitHorizontal);
    if (item.splitFractions) d[@"fractions"] = item.splitFractions;
  }
  NSMutableArray* children = [NSMutableArray array];
  for (ArcItem* child in item.children) [children addObject:EncodeItem(child)];
  d[@"children"] = children;
  return d;
}

static ArcItem* DecodeItem(NSDictionary* d, int depth) {
  if (![d isKindOfClass:NSDictionary.class] || depth > 64) return nil;
  ArcItem* item = [ArcItem new];
  item.itemID = d[@"id"];
  item.title = d[@"title"];
  item.liveTitle = d[@"savedTitle"];
  item.url = d[@"url"];
  if ([d[@"pinnedURL"] isKindOfClass:NSString.class]) item.pinnedURL = d[@"pinnedURL"];
  if ([d[@"lastActiveAt"] isKindOfClass:NSNumber.class])
    item.lastActiveAt = [NSDate dateWithTimeIntervalSinceReferenceDate:[d[@"lastActiveAt"] doubleValue]];
  item.isFolder = [d[@"folder"] boolValue];
  item.isSplit = [d[@"split"] boolValue];
  item.splitHorizontal = [d[@"horizontal"] boolValue];
  if ([d[@"fractions"] isKindOfClass:NSArray.class]) item.splitFractions = d[@"fractions"];
  item.children = [NSMutableArray array];
  for (id child in d[@"children"]) {
    ArcItem* c = DecodeItem(child, depth + 1);
    if (c) [item.children addObject:c];
  }
  if (item.isSplit && item.children.count < 2) return item.children.firstObject;  // damaged split: keep the tab
  if (item.splitFractions.count != item.children.count) item.splitFractions = nil;
  return item;
}

static ArcItem* Section(ArcItem* item, NSString* title) {
  if (!item) {
    item = [ArcItem new];
    item.itemID = NSUUID.UUID.UUIDString;
    item.children = [NSMutableArray array];
  }
  item.isSection = YES;
  item.isFolder = NO;
  item.title = title;
  return item;
}

NSArray<ArcSpace*>* SidebarStoreLoad(NSString* path, NSString** focusedSpaceID, NSError** error) {
  if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
  NSData* bytes = [NSData dataWithContentsOfFile:path options:0 error:error];
  if (!bytes) return nil;
  NSDictionary* root = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:error];
  if (![root isKindOfClass:NSDictionary.class] || [root[@"version"] integerValue] != kStoreVersion) {
    if (error && !*error)
      *error = [NSError errorWithDomain:@"SidebarStore" code:1
                               userInfo:@{NSLocalizedDescriptionKey : @"Unknown sidebar store version"}];
    return nil;
  }
  if (focusedSpaceID) *focusedSpaceID = root[@"focusedSpaceID"];
  NSMutableArray<ArcSpace*>* spaces = [NSMutableArray array];
  NSMutableDictionary<NSString*, ArcItem*>* sharedFavorites = [NSMutableDictionary dictionary];
  for (NSDictionary* s in root[@"spaces"]) {
    if (![s isKindOfClass:NSDictionary.class]) continue;
    ArcSpace* space = [ArcSpace new];
    space.spaceID = s[@"id"];
    space.title = s[@"title"] ?: @"Space";
    space.profileDirectory = s[@"profile"] ?: @"Default";
    if ([s[@"themeColors"] isKindOfClass:NSArray.class]) space.themeColors = s[@"themeColors"];
    space.themeIntensity = [s[@"themeIntensity"] respondsToSelector:@selector(doubleValue)] ? [s[@"themeIntensity"] doubleValue] : 0.5;
    if ([s[@"icon"] isKindOfClass:NSString.class]) space.iconEmoji = s[@"icon"];
    if (s[@"favorites"]) {
      ArcItem* fav = sharedFavorites[space.profileDirectory] ?: Section(DecodeItem(s[@"favorites"], 0), @"Favorites");
      sharedFavorites[space.profileDirectory] = fav;
      space.favorites = fav;
    }
    space.pinned = Section(DecodeItem(s[@"pinned"], 0), @"Pinned");
    space.unpinned = Section(DecodeItem(s[@"today"], 0), @"Today");
    [spaces addObject:space];
  }
  return spaces.count ? spaces : nil;
}

BOOL SidebarStoreSave(NSArray<ArcSpace*>* spaces, NSString* focusedSpaceID, NSString* path, NSError** error) {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcSpace* space in spaces) {
    NSMutableDictionary* s = [NSMutableDictionary dictionary];
    s[@"id"] = space.spaceID ?: NSUUID.UUID.UUIDString;
    s[@"title"] = space.title ?: @"Space";
    s[@"profile"] = space.profileDirectory ?: @"Default";
    if (space.themeColors.count) {
      s[@"themeColors"] = space.themeColors;
      s[@"themeIntensity"] = @(space.themeIntensity);
    }
    if (space.iconEmoji.length) s[@"icon"] = space.iconEmoji;
    if (space.favorites) s[@"favorites"] = EncodeItem(space.favorites);
    s[@"pinned"] = EncodeItem(space.pinned);
    s[@"today"] = EncodeItem(space.unpinned);
    [out addObject:s];
  }
  NSMutableDictionary* root = [NSMutableDictionary dictionary];
  root[@"version"] = @(kStoreVersion);
  if (focusedSpaceID) root[@"focusedSpaceID"] = focusedSpaceID;
  root[@"spaces"] = out;
  NSData* bytes = [NSJSONSerialization dataWithJSONObject:root
                                                  options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                    error:error];
  if (!bytes) return NO;
  [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
  return [bytes writeToFile:path options:NSDataWritingAtomic error:error];  // atomic: no half-written file
}
