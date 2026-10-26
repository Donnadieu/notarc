#import "app/arc_import.h"

static NSString* Str(id value) {
  return [value isKindOfClass:NSString.class] ? value : nil;
}

static NSDictionary* Dict(id value) {
  return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

// Arc serialises Swift dictionaries as flat [key, value, key, value] arrays.
static NSArray<NSDictionary*>* Values(id list) {
  NSMutableArray* out = [NSMutableArray array];
  if (![list isKindOfClass:NSArray.class]) return out;
  for (id x in list)
    if ([x isKindOfClass:NSDictionary.class]) [out addObject:x];
  return out;
}

@implementation ArcItem
- (NSString*)displayTitle {
  if (self.liveTitle.length) return self.liveTitle;
  if (self.title.length) return self.title;
  if (self.noteID) return @"Untitled Note";
  return self.url ?: @"Untitled";
}
@end

@implementation ArcSpace
- (NSArray<ArcItem*>*)allTabs {
  NSMutableArray* out = [NSMutableArray array];
  __block void (^walk)(ArcItem*);
  __block __weak void (^weakWalk)(ArcItem*);
  weakWalk = walk = ^(ArcItem* item) {
    if (item.url.length) [out addObject:item];
    for (ArcItem* child in item.children) weakWalk(child);
  };
  if (self.favorites) walk(self.favorites);
  if (self.pinned) walk(self.pinned);
  if (self.unpinned) walk(self.unpinned);
  return out;
}
@end

NSString* ArcDataDirectory(void) {
  NSString* support =
      NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  return [support stringByAppendingPathComponent:@"Arc"];
}

static ArcItem* BuildItem(NSString* itemID, NSDictionary<NSString*, NSDictionary*>* byID, int depth) {
  NSDictionary* raw = byID[itemID];
  if (!raw || depth > 64) return nil;
  ArcItem* item = [ArcItem new];
  item.itemID = itemID;
  item.children = [NSMutableArray array];
  NSDictionary* data = Dict(raw[@"data"]);
  NSDictionary* tab = Dict(data[@"tab"]);
  NSString* title = Str(raw[@"title"]);
  if (tab) {
    item.url = Str(tab[@"savedURL"]);
    item.pinnedURL = item.url;  // only kept for pinned tabs and Favorites (see MainWindowController)
    id last = tab[@"timeLastActiveAt"];  // seconds since 2001-01-01
    if ([last isKindOfClass:NSNumber.class])
      item.lastActiveAt = [NSDate dateWithTimeIntervalSinceReferenceDate:[last doubleValue]];
    if (!title.length) title = Str(tab[@"savedTitle"]);
  } else {
    item.isFolder = YES;
  }
  item.title = title;
  for (id childID in raw[@"childrenIds"]) {
    if (![childID isKindOfClass:NSString.class]) continue;
    ArcItem* child = BuildItem(childID, byID, depth + 1);
    if (child) [item.children addObject:child];
  }
  return item;
}

// containerIDs is ["pinned", <uuid>, "unpinned", <uuid>].
static NSString* ContainerID(NSArray* containerIDs, NSString* kind) {
  if (![containerIDs isKindOfClass:NSArray.class]) return nil;
  for (NSUInteger i = 0; i + 1 < containerIDs.count; ++i)
    if ([Str(containerIDs[i]) isEqualToString:kind]) return Str(containerIDs[i + 1]);
  return nil;
}

NSArray<ArcSpace*>* ArcImportSidebar(NSString* sidebarPath, NSError** error) {
  NSData* bytes = [NSData dataWithContentsOfFile:sidebarPath options:0 error:error];
  if (!bytes) return nil;
  NSDictionary* root = Dict([NSJSONSerialization JSONObjectWithData:bytes options:0 error:error]);
  if (!root) return nil;

  // Arc can hold several sidebar containers (e.g. a Little Arc / standalone window with one untitled
  // Space). The main one is the container with the most titled Spaces.
  NSDictionary* container = nil;
  NSInteger best = -1;
  for (id c in Dict(root[@"sidebar"])[@"containers"]) {
    if (!Dict(c)[@"spaces"]) continue;
    NSInteger titled = 0;
    for (NSDictionary* sp in Values(Dict(c)[@"spaces"]))
      if (Str(sp[@"title"]).length) ++titled;
    if (titled > best) {
      best = titled;
      container = c;
    }
  }
  if (!container) {
    if (error)
      *error = [NSError errorWithDomain:@"ArcImport" code:1
                               userInfo:@{NSLocalizedDescriptionKey : @"No sidebar container with spaces"}];
    return nil;
  }

  NSMutableDictionary<NSString*, NSDictionary*>* byID = [NSMutableDictionary dictionary];
  for (NSDictionary* item in Values(container[@"items"]))
    if (Str(item[@"id"])) byID[item[@"id"]] = item;

  // Favorites ("topApps") live in one container per Chromium profile, not per Space.
  NSMutableDictionary<NSString*, NSString*>* favoritesByProfile = [NSMutableDictionary dictionary];
  for (NSDictionary* item in byID.allValues) {
    NSDictionary* topApps = Dict(Dict(Dict(Dict(item[@"data"])[@"itemContainer"])[@"containerType"])[@"topApps"]);
    NSDictionary* which = Dict(topApps[@"_0"]);
    if (!which) continue;
    NSString* profile = which[@"default"] ? @"Default" : Str(Dict(Dict(which[@"custom"])[@"_0"])[@"directoryBasename"]);
    if (profile) favoritesByProfile[profile] = item[@"id"];
  }

  NSMutableArray<ArcSpace*>* spaces = [NSMutableArray array];
  NSMutableDictionary<NSString*, ArcItem*>* favoritesBuilt = [NSMutableDictionary dictionary];
  for (NSDictionary* raw in Values(container[@"spaces"])) {
    ArcSpace* space = [ArcSpace new];
    space.spaceID = Str(raw[@"id"]);
    space.title = Str(raw[@"title"]) ?: @"Space";
    NSDictionary* custom = Dict(Dict(Dict(raw[@"profile"])[@"custom"])[@"_0"]);
    space.profileDirectory = Str(custom[@"directoryBasename"]) ?: @"Default";
    space.pinned = BuildItem(ContainerID(raw[@"containerIDs"], @"pinned"), byID, 0);
    space.unpinned = BuildItem(ContainerID(raw[@"containerIDs"], @"unpinned"), byID, 0);
    if (!space.pinned) space.pinned = [ArcItem new];
    if (!space.unpinned) space.unpinned = [ArcItem new];
    for (ArcItem* section in @[ space.pinned, space.unpinned ]) {
      section.isFolder = NO;
      section.isSection = YES;
      if (!section.children) section.children = [NSMutableArray array];
    }
    NSString* favID = favoritesByProfile[space.profileDirectory];
    if (favID) {
      // Spaces on the same profile share one Favorites tree (same objects, so state is shared too).
      ArcItem* fav = favoritesBuilt[space.profileDirectory] ?: BuildItem(favID, byID, 0);
      favoritesBuilt[space.profileDirectory] = fav;
      fav.isFolder = NO;
      fav.isSection = YES;
      fav.title = @"Favorites";
      space.favorites = fav;
    }
    space.pinned.title = @"Pinned";
    space.unpinned.title = @"Today";
    [spaces addObject:space];
  }
  return spaces;
}

NSString* ArcFocusedSpaceID(NSString* windowsPath) {
  NSData* bytes = [NSData dataWithContentsOfFile:windowsPath];
  if (!bytes) return nil;
  NSDictionary* root = Dict([NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil]);
  id windows = root[@"windows"];
  if (![windows isKindOfClass:NSArray.class] || [windows count] == 0) return nil;
  return Str(Dict([windows firstObject])[@"focusedSpaceID"]);
}

static void Describe(NSMutableString* out, ArcItem* item, int depth) {
  for (ArcItem* child in item.children) {
    [out appendFormat:@"%*s%@ %@\n", depth * 2, "", child.isFolder ? @"[folder]" : @"-", child.displayTitle];
    Describe(out, child, depth + 1);
  }
}

NSString* ArcDescribeSpaces(NSArray<ArcSpace*>* spaces) {
  NSMutableString* out = [NSMutableString string];
  for (ArcSpace* space in spaces) {
    [out appendFormat:@"SPACE \"%@\" profile=%@ tabs=%lu\n", space.title, space.profileDirectory,
                      (unsigned long)space.allTabs.count];
    [out appendFormat:@"  FAVORITES (%lu)\n", (unsigned long)space.favorites.children.count];
    if (space.favorites) Describe(out, space.favorites, 2);
    [out appendFormat:@"  PINNED (%lu)\n", (unsigned long)space.pinned.children.count];
    Describe(out, space.pinned, 2);
    [out appendFormat:@"  TODAY (%lu)\n", (unsigned long)space.unpinned.children.count];
    Describe(out, space.unpinned, 2);
  }
  return out;
}
