#import "app/history_store.h"

static const NSUInteger kMaxVisits = 20000;

NSString* HistoryStorePath(BOOL selfTest) {
  NSString* dir = [ArchiveStorePath(selfTest) stringByDeletingLastPathComponent];
  return [dir stringByAppendingPathComponent:selfTest ? @"SelfTestHistory.json" : @"History.json"];
}

static BOOL Recordable(NSString* url) {
  return [url hasPrefix:@"http://"] || [url hasPrefix:@"https://"] || [url hasPrefix:@"file://"];
}

@implementation HistoryStore {
  NSString* _path;
  NSMutableArray<ArchivedTab*>* _visits;
  BOOL _saveQueued;
}

- (instancetype)initWithPath:(NSString*)path {
  if ((self = [super init])) {
    _path = [path copy];
    _visits = ArchiveStoreLoad(path);
  }
  return self;
}

- (NSArray<ArchivedTab*>*)visits { return _visits; }

- (void)recordURL:(NSString*)url title:(NSString*)title space:(NSString*)space {
  if (!Recordable(url)) return;
  ArchivedTab* last = _visits.lastObject;
  // Same page reported again (title change, reload) within a minute: not a new visit.
  if (last && [last.url isEqualToString:url] && -last.archivedAt.timeIntervalSinceNow < 60) {
    if (title.length) last.title = title;
    [self scheduleSave];
    return;
  }
  ArchivedTab* v = [ArchivedTab new];
  v.url = url;
  v.title = title ?: @"";
  v.reason = space ?: @"";
  v.archivedAt = [NSDate date];
  [_visits addObject:v];
  if (_visits.count > kMaxVisits) [_visits removeObjectsInRange:NSMakeRange(0, _visits.count - kMaxVisits)];
  [self scheduleSave];
}

- (void)updateTitle:(NSString*)title forURL:(NSString*)url {
  if (!title.length) return;
  for (ArchivedTab* v in _visits.reverseObjectEnumerator) {
    if ([v.url isEqualToString:url]) {
      if (![v.title isEqualToString:title]) {
        v.title = title;
        [self scheduleSave];
      }
      return;
    }
  }
}

- (NSUInteger)clearSince:(NSDate*)since {
  NSUInteger before = _visits.count;
  NSIndexSet* gone = [_visits indexesOfObjectsPassingTest:^BOOL(ArchivedTab* v, NSUInteger i, BOOL* stop) {
    return [v.archivedAt compare:since] != NSOrderedAscending;
  }];
  [_visits removeObjectsAtIndexes:gone];
  [self saveNow];
  return before - _visits.count;
}

- (void)clear {
  [_visits removeAllObjects];
  [self saveNow];
}

- (void)scheduleSave {
  if (_saveQueued) return;
  _saveQueued = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self saveNow]; });
}

- (void)saveNow {
  _saveQueued = NO;
  ArchiveStoreSave(_visits, _path);
}
@end
