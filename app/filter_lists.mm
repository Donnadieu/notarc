#import "app/filter_lists.h"
#import "app/settings.h"
#include "app/content_blocker.h"

#include <CommonCrypto/CommonDigest.h>
#include <string>
#include <vector>

NSString* const kSettingAdBlockLists = @"adBlockFilterLists";
NSString* const kSettingAdBlockBuiltIn = @"adBlockBuiltInList";
NSString* const FilterListsDidChangeNotification = @"FilterListsDidChangeNotification";

static const NSTimeInterval kRefreshInterval = 24 * 60 * 60;  // lists refresh once a day
static const NSUInteger kMaxListBytes = 20 * 1024 * 1024;

@implementation FilterList
@end

@implementation FilterListManager {
  NSMutableSet<NSString*>* _updating;
  NSMutableDictionary<NSString*, NSMutableArray*>* _waiters;
  NSInteger _inflight;
  NSString* _appliedKey;
  NSTimer* _timer;
  dispatch_queue_t _parseQueue;
}

+ (instancetype)shared {
  static FilterListManager* m;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ m = [FilterListManager new]; });
  return m;
}

+ (NSArray<NSArray<NSString*>*>*)suggestions {
  return @[
    @[ @"EasyList", @"https://easylist.to/easylist/easylist.txt" ],
    @[ @"EasyPrivacy", @"https://easylist.to/easylist/easyprivacy.txt" ],
  ];
}

- (instancetype)init {
  if ((self = [super init])) {
    _updating = [NSMutableSet set];
    _waiters = [NSMutableDictionary dictionary];
    _parseQueue = dispatch_queue_create("notarc.filterlists.parse", DISPATCH_QUEUE_SERIAL);
  }
  return self;
}

- (BOOL)busy { return _inflight > 0; }

// MARK: storage

- (NSString*)folder {
  NSString* dir = SettingsMemoryOnly()
      ? [NSTemporaryDirectory() stringByAppendingPathComponent:@"NotArcSelfTestFilterLists"]
      : [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
            stringByAppendingPathComponent:@"NotArc"] stringByAppendingPathComponent:@"Filter Lists"];
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  return dir;
}

- (NSString*)pathForURL:(NSString*)url {
  NSData* d = [url dataUsingEncoding:NSUTF8StringEncoding];
  unsigned char md[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(d.bytes, (CC_LONG)d.length, md);
  NSMutableString* hex = [NSMutableString string];
  for (int i = 0; i < 12; ++i) [hex appendFormat:@"%02x", md[i]];
  return [[self folder] stringByAppendingPathComponent:[hex stringByAppendingPathExtension:@"txt"]];
}

- (NSMutableArray<NSMutableDictionary*>*)saved {
  NSMutableArray* out = [NSMutableArray array];
  for (id e in SettingObject(kSettingAdBlockLists))
    if ([e isKindOfClass:NSDictionary.class] && [e[@"url"] isKindOfClass:NSString.class]) [out addObject:[e mutableCopy]];
  return out;
}

- (void)save:(NSArray*)entries {
  SettingSetObject(kSettingAdBlockLists, [entries copy]);
}

- (NSMutableDictionary*)entryForURL:(NSString*)url in:(NSArray*)entries {
  for (NSMutableDictionary* e in entries)
    if ([e[@"url"] isEqualToString:url]) return e;
  return nil;
}

- (void)changed {
  [NSNotificationCenter.defaultCenter postNotificationName:FilterListsDidChangeNotification object:self];
}

- (NSArray<FilterList*>*)lists {
  NSMutableArray* out = [NSMutableArray array];
  NSArray* saved = [self saved];
  for (NSDictionary* e in saved) {
    FilterList* l = [FilterList new];
    l.url = e[@"url"];
    l.title = [e[@"title"] length] ? e[@"title"] : e[@"url"];
    l.enabled = [e[@"enabled"] boolValue];
    l.rules = [e[@"rules"] integerValue];
    l.updated = [e[@"updated"] doubleValue] > 0 ? [NSDate dateWithTimeIntervalSince1970:[e[@"updated"] doubleValue]] : nil;
    l.error = [e[@"error"] length] ? e[@"error"] : nil;
    l.updating = [_updating containsObject:l.url];
    [out addObject:l];
  }
  for (NSArray<NSString*>* s in FilterListManager.suggestions) {
    if ([self entryForURL:s[1] in:saved]) continue;
    FilterList* l = [FilterList new];
    l.title = s[0];
    l.url = s[1];
    l.suggested = YES;
    [out addObject:l];
  }
  return out;
}

// MARK: changes

- (void)setList:(NSString*)url enabled:(BOOL)enabled {
  NSMutableArray* saved = [self saved];
  NSMutableDictionary* e = [self entryForURL:url in:saved];
  if (!e) {
    if (!enabled) return;
    NSString* title = @"";
    for (NSArray<NSString*>* s in FilterListManager.suggestions)
      if ([s[1] isEqualToString:url]) title = s[0];
    e = [@{@"url" : url, @"title" : title} mutableCopy];
    [saved addObject:e];
  }
  e[@"enabled"] = @(enabled);
  [self save:saved];
  BOOL needsDownload = enabled && (![e[@"updated"] doubleValue] ||
                                   ![NSFileManager.defaultManager fileExistsAtPath:[self pathForURL:url]]);
  if (needsDownload) [self updateList:url done:nil];
  [self reloadRules];
  [self changed];
}

static BOOL AcceptableListURL(NSURL* u) {
  NSString* s = u.scheme.lowercaseString;
  if ([s isEqualToString:@"file"]) return u.path.length > 0;
  return ([s isEqualToString:@"https"] || [s isEqualToString:@"http"]) && u.host.length > 0;
}

- (BOOL)addListURL:(NSString*)input {
  NSString* url = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if ([url hasPrefix:@"abp:subscribe?"]) {  // "Subscribe" links on filter list sites: abp:subscribe?location=...
    for (NSURLQueryItem* q in [NSURLComponents componentsWithString:url].queryItems)
      if ([q.name isEqualToString:@"location"] && q.value.length) url = q.value;
  }
  NSURL* u = [NSURL URLWithString:url];
  if (!u || !AcceptableListURL(u)) return NO;
  NSMutableArray* saved = [self saved];
  NSMutableDictionary* existing = [self entryForURL:url in:saved];
  if (existing && [existing[@"enabled"] boolValue]) return NO;
  [self setList:url enabled:YES];
  return YES;
}

- (void)removeList:(NSString*)url {
  NSMutableArray* saved = [self saved];
  NSMutableDictionary* e = [self entryForURL:url in:saved];
  if (!e) return;
  [saved removeObject:e];
  [self save:saved];
  [NSFileManager.defaultManager removeItemAtPath:[self pathForURL:url] error:nil];
  [self reloadRules];
  [self changed];
}

- (void)updateAll {
  for (NSDictionary* e in [self saved])
    if ([e[@"enabled"] boolValue]) [self updateList:e[@"url"] done:nil];
}

- (NSArray<NSString*>*)listsDueForRefreshAt:(NSDate*)now {
  NSMutableArray* due = [NSMutableArray array];
  for (NSDictionary* e in [self saved]) {
    if (![e[@"enabled"] boolValue]) continue;
    double updated = [e[@"updated"] doubleValue];
    if (updated <= 0 || now.timeIntervalSince1970 - updated >= kRefreshInterval) [due addObject:e[@"url"]];
  }
  return due;
}

- (void)startDailyRefresh {
  if (_timer || SettingsMemoryOnly()) return;  // self-tests never download
  __weak FilterListManager* weakSelf = self;
  void (^check)(void) = ^{
    FilterListManager* m = weakSelf;
    if (!m || !SettingBool(kSettingBlockAds)) return;
    for (NSString* url in [m listsDueForRefreshAt:[NSDate date]]) [m updateList:url done:nil];
  };
  _timer = [NSTimer scheduledTimerWithTimeInterval:60 * 60 repeats:YES block:^(NSTimer*) { check(); }];
  _timer.tolerance = 5 * 60;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC), dispatch_get_main_queue(), check);
}

// MARK: download

- (void)updateList:(NSString*)url done:(void (^)(BOOL ok))done {
  NSMutableArray* waiters = _waiters[url];
  if (waiters) {  // already downloading: just wait for that one
    if (done) [waiters addObject:done];
    return;
  }
  waiters = [NSMutableArray array];
  if (done) [waiters addObject:done];
  _waiters[url] = waiters;
  [_updating addObject:url];
  ++_inflight;
  [self changed];
  NSURL* u = [NSURL URLWithString:url];
  __weak FilterListManager* weakSelf = self;
  void (^finish)(NSData*, NSString*) = ^(NSData* data, NSString* error) {
    // Background: decode and count, then save on the main queue.
    NSString* text = nil;
    size_t rules = 0;
    std::string title;
    if (!error) {
      if (data.length == 0) error = @"The list was empty.";
      else if (data.length > kMaxListBytes) error = @"The list is too large.";
    }
    if (!error) {
      text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
                 ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
      std::string s = text.UTF8String ?: "";
      rules = content_blocker::CountSupportedRules(s);
      title = content_blocker::ListTitle(s);
      if (!rules) error = @"No ad-blocking rules NotArc understands were found.";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf finishDownload:url text:text rules:rules
                         title:[NSString stringWithUTF8String:title.c_str()] error:error];
    });
  };
  if (!u || !AcceptableListURL(u)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ finish(nil, @"Not a web or file address."); });
    return;
  }
  if (u.isFileURL) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSError* err = nil;
      NSData* d = [NSData dataWithContentsOfURL:u options:0 error:&err];
      finish(d, d ? nil : (err.localizedDescription ?: @"Couldn't read the file."));
    });
    return;
  }
  NSURLSessionConfiguration* cfg = NSURLSessionConfiguration.ephemeralSessionConfiguration;
  cfg.timeoutIntervalForRequest = 60;
  NSURLSession* session = [NSURLSession sessionWithConfiguration:cfg];
  [[session dataTaskWithURL:u completionHandler:^(NSData* d, NSURLResponse* resp, NSError* err) {
    NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)resp).statusCode : 200;
    NSString* e = err ? err.localizedDescription
                      : (status != 200 ? [NSString stringWithFormat:@"The server answered %ld.", (long)status] : nil);
    finish(e ? nil : d, e);
  }] resume];
  [session finishTasksAndInvalidate];
}

- (void)finishDownload:(NSString*)url text:(NSString*)text rules:(size_t)rules title:(NSString*)title error:(NSString*)error {
  NSMutableArray* saved = [self saved];
  NSMutableDictionary* e = [self entryForURL:url in:saved];
  BOOL ok = !error && text;
  if (e) {  // still subscribed (it could have been removed while downloading)
    if (ok && [text writeToFile:[self pathForURL:url] atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
      e[@"rules"] = @(rules);
      e[@"updated"] = @(NSDate.date.timeIntervalSince1970);
      [e removeObjectForKey:@"error"];
      if (![e[@"title"] length] && title.length) e[@"title"] = title;
    } else {
      ok = NO;
      e[@"error"] = error ?: @"Couldn't save the list.";
    }
    [self save:saved];
  }
  [_updating removeObject:url];
  NSArray* waiters = _waiters[url];
  [_waiters removeObjectForKey:url];
  --_inflight;
  if (ok) [self reloadRules];
  [self changed];
  for (void (^w)(BOOL) in waiters) w(ok);
}

// MARK: rules

- (void)reloadRules {
  BOOL on = SettingBool(kSettingBlockAds);
  NSMutableArray<NSString*>* paths = [NSMutableArray array];
  NSMutableString* key = [NSMutableString stringWithFormat:@"%d", on];
  if (on)
    for (NSDictionary* e in [self saved]) {
      if (![e[@"enabled"] boolValue]) continue;
      NSString* p = [self pathForURL:e[@"url"]];
      if (![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
      [paths addObject:p];
      [key appendFormat:@"|%@@%@", p, e[@"updated"]];
    }
  if ([key isEqualToString:_appliedKey]) return;  // nothing changed (e.g. a per-site toggle)
  _appliedKey = [key copy];
  ++_inflight;
  __weak FilterListManager* weakSelf = self;
  dispatch_async(_parseQueue, ^{
    std::vector<std::string> texts;
    for (NSString* p in paths) {
      @autoreleasepool {
        NSString* t = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (t) texts.push_back(t.UTF8String);
      }
    }
    content_blocker::SetFilterListTexts(texts);
    dispatch_async(dispatch_get_main_queue(), ^{
      FilterListManager* m = weakSelf;
      if (!m) return;
      --m->_inflight;
      ++m->_reloads;
      [m changed];
    });
  });
}

@end
