#import "app/updater.h"

#import <Cocoa/Cocoa.h>
#include <CommonCrypto/CommonDigest.h>

static NSString* const kLastCheckKey = @"updaterLastCheck";
static NSString* const kSkipVersionKey = @"updaterSkipVersion";
NSString* const kSettingCheckForUpdates = @"checkForUpdates";

int UpdaterCompareVersions(NSString* a, NSString* b) {
  NSCharacterSet* strip = [NSCharacterSet characterSetWithCharactersInString:@"vV "];
  NSArray* pa = [[a stringByTrimmingCharactersInSet:strip] componentsSeparatedByString:@"."];
  NSArray* pb = [[b stringByTrimmingCharactersInSet:strip] componentsSeparatedByString:@"."];
  for (NSUInteger i = 0; i < MAX(pa.count, pb.count); ++i) {
    NSInteger x = i < pa.count ? [pa[i] integerValue] : 0, y = i < pb.count ? [pb[i] integerValue] : 0;
    if (x != y) return x < y ? -1 : 1;
  }
  return 0;
}

static NSString* g_versionOverride;

NSString* UpdaterCurrentVersion(void) {
  if (g_versionOverride) return g_versionOverride;
  return NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"0";
}

static NSError* Err(NSString* msg) {
  return [NSError errorWithDomain:@"NotArcUpdater" code:1 userInfo:@{NSLocalizedDescriptionKey : msg}];
}

static NSString* SHA256OfFile(NSString* path) {
  NSInputStream* in = [NSInputStream inputStreamWithFileAtPath:path];
  if (!in) return nil;
  [in open];
  CC_SHA256_CTX ctx;
  CC_SHA256_Init(&ctx);
  uint8_t buf[1 << 16];
  NSInteger n;
  while ((n = [in read:buf maxLength:sizeof buf]) > 0) CC_SHA256_Update(&ctx, buf, (CC_LONG)n);
  [in close];
  unsigned char md[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256_Final(md, &ctx);
  NSMutableString* hex = [NSMutableString string];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; ++i) [hex appendFormat:@"%02x", md[i]];
  return hex;
}

static int Run(NSString* tool, NSArray<NSString*>* args, NSString** output) {
  NSTask* t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:tool];
  t.arguments = args;
  NSPipe* pipe = [NSPipe pipe];
  t.standardOutput = pipe;
  t.standardError = pipe;
  if (![t launchAndReturnError:nil]) return -1;
  NSData* data = [pipe.fileHandleForReading readDataToEndOfFile];
  [t waitUntilExit];
  if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
  return t.terminationStatus;
}

@implementation UpdateInfo
@end

@implementation Updater {
  NSTimer* _timer;
  BOOL _busy;
}

+ (instancetype)shared {
  static Updater* u;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    u = [Updater new];
    u.feedURL = @"https://api.github.com/repos/Donnadieu/notarc/releases/latest";
  });
  return u;
}

+ (UpdateInfo*)infoFromReleaseJSON:(NSDictionary*)json {
  if (![json isKindOfClass:NSDictionary.class] || [json[@"draft"] boolValue] || [json[@"prerelease"] boolValue])
    return nil;
  UpdateInfo* info = [UpdateInfo new];
  info.version = [json[@"tag_name"] stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"vV"]];
  info.notes = json[@"body"];
  for (NSDictionary* asset in json[@"assets"]) {
    NSString* name = asset[@"name"];
    NSURL* url = [NSURL URLWithString:asset[@"browser_download_url"] ?: @""];
    if ([name hasSuffix:@"-arm64.dmg"]) info.dmgURL = url;
    if ([name hasSuffix:@"-arm64.dmg.sha256"]) info.sha256URL = url;
  }
  return info.version.length && info.dmgURL && info.sha256URL ? info : nil;
}

- (void)fetchLatest:(void (^)(UpdateInfo*, NSError*))done {
  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:self.feedURL]];
  [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
  [req setValue:[@"NotArc/" stringByAppendingString:UpdaterCurrentVersion()] forHTTPHeaderField:@"User-Agent"];
  req.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  [[NSURLSession.sharedSession dataTaskWithRequest:req
                                 completionHandler:^(NSData* data, NSURLResponse* resp, NSError* error) {
    NSDictionary* json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    UpdateInfo* info = [Updater infoFromReleaseJSON:json];
    NSError* e = error ?: (info ? nil : Err(@"No downloadable release found."));
    dispatch_async(dispatch_get_main_queue(), ^{ done(info, e); });
  }] resume];
}

- (void)prepareUpdate:(UpdateInfo*)info done:(void (^)(NSString*, NSError*))done {
  void (^fail)(NSString*) = ^(NSString* msg) { dispatch_async(dispatch_get_main_queue(), ^{ done(nil, Err(msg)); }); };
  [[NSURLSession.sharedSession dataTaskWithURL:info.sha256URL
                             completionHandler:^(NSData* shaData, NSURLResponse* r1, NSError* e1) {
    NSString* expected = [[[[NSString alloc] initWithData:shaData ?: [NSData data] encoding:NSUTF8StringEncoding]
        componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].firstObject lowercaseString];
    if (expected.length != 64) return fail(@"Couldn't read the update's checksum.");
    [[NSURLSession.sharedSession downloadTaskWithURL:info.dmgURL
                                   completionHandler:^(NSURL* tmp, NSURLResponse* r2, NSError* e2) {
      if (!tmp) return fail(e2.localizedDescription ?: @"Download failed.");
      NSString* stage = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                                    [@"NotArcUpdate-" stringByAppendingString:NSUUID.UUID.UUIDString]];
      NSFileManager* fm = NSFileManager.defaultManager;
      [fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:nil];
      NSString* dmg = [stage stringByAppendingPathComponent:@"NotArc.dmg"];
      [fm moveItemAtPath:tmp.path toPath:dmg error:nil];
      if (![SHA256OfFile(dmg) isEqualToString:expected]) return fail(@"The download didn't match its checksum.");
      NSString* mount = [stage stringByAppendingPathComponent:@"mnt"];
      if (Run(@"/usr/bin/hdiutil", @[ @"attach", @"-nobrowse", @"-readonly", @"-noautoopen", @"-mountpoint", mount, dmg ], nil))
        return fail(@"Couldn't open the downloaded disk image.");
      NSString* staged = [stage stringByAppendingPathComponent:@"NotArc.app"];
      int copied = Run(@"/usr/bin/ditto", @[ [mount stringByAppendingPathComponent:@"NotArc.app"], staged ], nil);
      Run(@"/usr/bin/hdiutil", @[ @"detach", mount, @"-force" ], nil);
      [fm removeItemAtPath:dmg error:nil];
      NSString* got = [NSDictionary dictionaryWithContentsOfFile:
                                        [staged stringByAppendingPathComponent:@"Contents/Info.plist"]][@"CFBundleShortVersionString"];
      if (copied || !got) return fail(@"The disk image didn't contain NotArc.");
      Run(@"/usr/bin/xattr", @[ @"-dr", @"com.apple.quarantine", staged ], nil);
      dispatch_async(dispatch_get_main_queue(), ^{ done(staged, nil); });
    }] resume];
  }] resume];
}

+ (void)setVersionOverride:(NSString*)version { g_versionOverride = [version copy]; }

- (void)installStagedApp:(NSString*)stagedApp {
  [self swapInStagedApp:stagedApp relaunch:YES];
  [NSApp terminate:nil];
}

- (void)swapInStagedApp:(NSString*)stagedApp relaunch:(BOOL)relaunch {
  NSString* target = NSBundle.mainBundle.bundlePath;
  // Swap after we exit: keep the old copy until the new one is in place, then relaunch.
  NSString* script =
      @"while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; "
       "rm -rf \"$3.old\" && mv \"$3\" \"$3.old\" && mv \"$2\" \"$3\" && rm -rf \"$3.old\" || "
       "{ [ -d \"$3\" ] || mv \"$3.old\" \"$3\"; }; [ \"$4\" = 1 ] && open \"$3\"; exit 0";
  NSTask* t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/bin/sh"];
  t.arguments = @[ @"-c", script, @"notarc-update", @(getpid()).stringValue, stagedApp, target, relaunch ? @"1" : @"0" ];
  [t launchAndReturnError:nil];
}

- (void)checkInteractive:(BOOL)interactive {
  if (_busy) return;
  _busy = YES;
  [NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:kLastCheckKey];
  [self fetchLatest:^(UpdateInfo* info, NSError* error) {
    self->_busy = NO;
    NSString* current = UpdaterCurrentVersion();
    if (!info || UpdaterCompareVersions(info.version, current) <= 0) {
      if (!interactive) return;
      NSAlert* a = [NSAlert new];
      a.messageText = info || !error ? @"NotArc is up to date." : @"Couldn't check for updates.";
      a.informativeText = info ? [NSString stringWithFormat:@"You have version %@, the newest available.", current]
                               : error.localizedDescription ?: @"";
      [a runModal];
      return;
    }
    if (!interactive && [[NSUserDefaults.standardUserDefaults stringForKey:kSkipVersionKey] isEqualToString:info.version])
      return;
    NSAlert* a = [NSAlert new];
    a.messageText = [NSString stringWithFormat:@"NotArc %@ is available", info.version];
    a.informativeText = [NSString stringWithFormat:@"You have %@. Your tabs and Spaces are kept.\n\n%@", current,
                                                   info.notes.length > 600 ? [[info.notes substringToIndex:600] stringByAppendingString:@"…"] : info.notes ?: @""];
    [a addButtonWithTitle:@"Install and Relaunch"];
    [a addButtonWithTitle:@"Later"];
    [a addButtonWithTitle:@"Skip This Version"];
    NSModalResponse r = [a runModal];
    if (r == NSAlertThirdButtonReturn) [NSUserDefaults.standardUserDefaults setObject:info.version forKey:kSkipVersionKey];
    if (r != NSAlertFirstButtonReturn) return;
    self->_busy = YES;
    [self prepareUpdate:info done:^(NSString* staged, NSError* err) {
      self->_busy = NO;
      if (staged) return [self installStagedApp:staged];
      NSAlert* f = [NSAlert new];
      f.messageText = @"The update couldn't be installed.";
      f.informativeText = err.localizedDescription ?: @"";
      [f runModal];
    }];
  }];
}

- (void)scheduleDailyChecks {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{kSettingCheckForUpdates : @YES}];
  void (^tick)(void) = ^{
    if (![NSUserDefaults.standardUserDefaults boolForKey:kSettingCheckForUpdates]) return;
    NSDate* last = [NSUserDefaults.standardUserDefaults objectForKey:kLastCheckKey];
    if (last && -last.timeIntervalSinceNow < 24 * 3600) return;
    [self checkInteractive:NO];
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), tick);
  _timer = [NSTimer scheduledTimerWithTimeInterval:3600 repeats:YES block:^(NSTimer*) { tick(); }];
}
@end
