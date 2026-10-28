#import "app/bookmark_import.h"

#import "app/arc_import.h"

static ArcItem* NewFolder(NSString* title) {
  ArcItem* f = [ArcItem new];
  f.itemID = NSUUID.UUID.UUIDString;
  f.title = title.length ? title : @"Folder";
  f.isFolder = YES;
  f.children = [NSMutableArray array];
  return f;
}

static ArcItem* NewTab(NSString* title, NSString* url) {
  ArcItem* t = [ArcItem new];
  t.itemID = NSUUID.UUID.UUIDString;
  t.title = title.length ? title : url;
  t.url = url;
  t.pinnedURL = url;
  t.children = [NSMutableArray array];
  return t;
}

static BOOL Openable(NSString* url) {
  NSString* s = [NSURL URLWithString:url].scheme.lowercaseString;
  return [s isEqualToString:@"http"] || [s isEqualToString:@"https"] || [s isEqualToString:@"file"];
}

static void AddChromiumNode(NSDictionary* node, ArcItem* into, NSUInteger* count) {
  if (![node isKindOfClass:NSDictionary.class]) return;
  if ([node[@"type"] isEqualToString:@"url"]) {
    NSString* url = node[@"url"];
    if ([url isKindOfClass:NSString.class] && Openable(url)) {
      [into.children addObject:NewTab(node[@"name"], url)];
      ++*count;
    }
    return;
  }
  ArcItem* f = NewFolder(node[@"name"]);
  for (NSDictionary* c in [node[@"children"] isKindOfClass:NSArray.class] ? node[@"children"] : @[]) AddChromiumNode(c, f, count);
  if (f.children.count) [into.children addObject:f];
}

ArcItem* BookmarksFromChromiumFile(NSString* path, NSString* folderTitle, NSUInteger* count) {
  NSData* data = [NSData dataWithContentsOfFile:path];
  NSDictionary* root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSDictionary* roots = [root isKindOfClass:NSDictionary.class] ? root[@"roots"] : nil;
  if (![roots isKindOfClass:NSDictionary.class]) return nil;
  NSUInteger n = 0;
  ArcItem* top = NewFolder(folderTitle);
  // Bookmarks bar contents go straight in (as in Arc); the other roots become subfolders.
  NSDictionary* bar = roots[@"bookmark_bar"];
  for (NSDictionary* c in [bar[@"children"] isKindOfClass:NSArray.class] ? bar[@"children"] : @[]) AddChromiumNode(c, top, &n);
  for (NSString* k in @[ @"other", @"synced" ]) AddChromiumNode(roots[k], top, &n);
  if (count) *count = n;
  return top;
}

// Netscape bookmark file: <DT><H3>Folder</H3><DL><p> ... </DL>, <DT><A HREF="...">Title</A>.
ArcItem* BookmarksFromHTMLFile(NSString* path, NSString* folderTitle, NSUInteger* count) {
  NSString* html = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  if (!html || [html rangeOfString:@"<DL" options:NSCaseInsensitiveSearch].location == NSNotFound) return nil;
  NSRegularExpression* tok = [NSRegularExpression
      regularExpressionWithPattern:@"<H3[^>]*>(.*?)</H3>|<A\\s[^>]*HREF=\"([^\"]*)\"[^>]*>(.*?)</A>|<DL|</DL"
                           options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators
                             error:nil];
  ArcItem* top = NewFolder(folderTitle);
  NSMutableArray<ArcItem*>* stack = [NSMutableArray arrayWithObject:top];
  ArcItem* pendingFolder = nil;
  BOOL sawFirstDL = NO;
  NSUInteger n = 0;
  NSString* (^text)(NSString*) = ^NSString*(NSString* s) {
    NSMutableString* m = [s mutableCopy];
    [[NSRegularExpression regularExpressionWithPattern:@"<[^>]+>" options:0 error:nil]
        replaceMatchesInString:m options:0 range:NSMakeRange(0, m.length) withTemplate:@""];
    for (NSArray* e in @[ @[ @"&lt;", @"<" ], @[ @"&gt;", @">" ], @[ @"&quot;", @"\"" ], @[ @"&#39;", @"'" ], @[ @"&apos;", @"'" ],
                          @[ @"&nbsp;", @" " ], @[ @"&amp;", @"&" ] ])
      [m replaceOccurrencesOfString:e[0] withString:e[1] options:0 range:NSMakeRange(0, m.length)];
    return [m stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  };
  for (NSTextCheckingResult* m in [tok matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
    NSString* whole = [html substringWithRange:m.range].uppercaseString;
    if ([m rangeAtIndex:1].location != NSNotFound) {
      pendingFolder = NewFolder(text([html substringWithRange:[m rangeAtIndex:1]]));
    } else if ([m rangeAtIndex:2].location != NSNotFound) {
      NSString* url = [[html substringWithRange:[m rangeAtIndex:2]] stringByReplacingOccurrencesOfString:@"&amp;" withString:@"&"];
      if (Openable(url)) {
        [stack.lastObject.children addObject:NewTab(text([html substringWithRange:[m rangeAtIndex:3]]), url)];
        ++n;
      }
    } else if ([whole hasPrefix:@"<DL"]) {
      if (!sawFirstDL) { sawFirstDL = YES; pendingFolder = nil; continue; }  // the file's outer list
      ArcItem* f = pendingFolder ?: NewFolder(@"Folder");
      [stack.lastObject.children addObject:f];
      [stack addObject:f];
      pendingFolder = nil;
    } else if (stack.count > 1) {  // </DL
      ArcItem* done = stack.lastObject;
      [stack removeLastObject];
      if (!done.children.count) [stack.lastObject.children removeObject:done];
    }
  }
  if (count) *count = n;
  return top;
}

static NSArray<NSArray<NSString*>*>* DetectedProfileFiles(NSString* file);

NSArray<NSArray<NSString*>*>* DetectedBookmarkSources(void) { return DetectedProfileFiles(@"Bookmarks"); }
NSArray<NSArray<NSString*>*>* DetectedHistorySources(void) { return DetectedProfileFiles(@"History"); }

static NSArray<NSArray<NSString*>*>* DetectedProfileFiles(NSString* file) {
  NSString* support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  NSArray* browsers = @[ @[ @"Google Chrome", @"Google/Chrome" ], @[ @"Brave", @"BraveSoftware/Brave-Browser" ],
                         @[ @"Microsoft Edge", @"Microsoft Edge" ], @[ @"Vivaldi", @"Vivaldi" ], @[ @"Chromium", @"Chromium" ] ];
  NSFileManager* fm = NSFileManager.defaultManager;
  NSMutableArray* out = [NSMutableArray array];
  for (NSArray* b in browsers) {
    NSString* dir = [support stringByAppendingPathComponent:b[1]];
    NSDictionary* names = nil;
    NSData* ls = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"Local State"]];
    if (ls) names = [[NSJSONSerialization JSONObjectWithData:ls options:0 error:nil] valueForKeyPath:@"profile.info_cache"];
    for (NSString* p in [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(localizedStandardCompare:)]) {
      NSString* f = [[dir stringByAppendingPathComponent:p] stringByAppendingPathComponent:file];
      if (![fm fileExistsAtPath:f]) continue;
      NSString* pname = [names isKindOfClass:NSDictionary.class] ? names[p][@"name"] : nil;
      [out addObject:@[ [NSString stringWithFormat:@"%@ (%@)", b[0], pname ?: p], f ]];
    }
  }
  return out;
}
