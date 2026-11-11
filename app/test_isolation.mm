#import "app/test_isolation.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#include <os/lock.h>
#include <pwd.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString* const kBundleID = @"io.github.donnadieu.notarc";

static BOOL g_active = NO;
static os_unfair_lock g_lock = OS_UNFAIR_LOCK_INIT;
static NSMutableDictionary* g_written;  // key -> value, or NSNull for removed (standardUserDefaults only)
static NSSet* g_realKeys;               // keys the user's own NotArc preferences hold (hidden in tests)
static NSUInteger g_blockedWrites = 0;
static NSDictionary* g_profileTimes;    // real profile file -> mtime at install
static NSMutableArray* g_debug;

NSString* TestIsolationRealHome(void) {
  struct passwd* pw = getpwuid(getuid());
  return pw && pw->pw_dir ? [NSString stringWithUTF8String:pw->pw_dir] : @"";
}

BOOL TestIsolationHomeIsolated(void) {
  NSString* real = TestIsolationRealHome().stringByStandardizingPath.stringByResolvingSymlinksInPath;
  NSString* home = NSHomeDirectory().stringByStandardizingPath.stringByResolvingSymlinksInPath;
  return real.length && home.length && ![real isEqualToString:home];
}

BOOL TestIsolationActive(void) { return g_active; }

static NSArray<NSString*>* RealProfileFiles(void) {
  NSString* home = TestIsolationRealHome();
  NSString* data = [home stringByAppendingPathComponent:@"Library/Application Support/NotArc"];
  return @[
    [home stringByAppendingPathComponent:@"Library/Preferences/io.github.donnadieu.notarc.plist"],
    [data stringByAppendingPathComponent:@"Sidebar.json"],
    [data stringByAppendingPathComponent:@"History.json"],
    [data stringByAppendingPathComponent:@"Archive.json"],
    [data stringByAppendingPathComponent:@"Space Profile 1/Cookies"],
    [data stringByAppendingPathComponent:@"Default/Cookies"],
  ];
}

// stat() only: works even where the folder itself can't be listed or read.
static NSDictionary* ProfileTimes(void) {
  NSMutableDictionary* out = [NSMutableDictionary dictionary];
  for (NSString* p in RealProfileFiles()) {
    struct stat st;
    out[p] = stat(p.fileSystemRepresentation, &st) == 0
                 ? [NSString stringWithFormat:@"%ld.%09ld", (long)st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
                 : @"-";
  }
  return out;
}

static BOOL IsTracked(NSUserDefaults* d) { return g_active && d == NSUserDefaults.standardUserDefaults; }

// Returns YES and sets *found / *value when the test store or the hidden real keys decide the answer.
static BOOL TestLookup(NSUserDefaults* d, NSString* key, id* value) {
  if (!IsTracked(d) || !key) return NO;
  os_unfair_lock_lock(&g_lock);
  id v = g_written[key];
  BOOL hidden = [g_realKeys containsObject:key];
  os_unfair_lock_unlock(&g_lock);
  if (v) {
    *value = v == NSNull.null ? nil : v;
    return YES;
  }
  if (hidden) {  // the user's own saved value: read as if never set
    *value = [d volatileDomainForName:NSArgumentDomain][key] ?: [d volatileDomainForName:NSRegistrationDomain][key];
    return YES;
  }
  return NO;
}

static void TestStore(NSUserDefaults* d, NSString* key, id value) {
  [d willChangeValueForKey:key];
  os_unfair_lock_lock(&g_lock);
  g_written[key] = value ?: NSNull.null;
  g_blockedWrites++;
  os_unfair_lock_unlock(&g_lock);
  [d didChangeValueForKey:key];
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:NSUserDefaultsDidChangeNotification object:d];
  });
}

@implementation NSUserDefaults (NotArcTestIsolation)
- (void)notarcTest_setObject:(id)value forKey:(NSString*)key {
  if (!g_active || !key) return [self notarcTest_setObject:value forKey:key];
  if (IsTracked(self)) return TestStore(self, key, value);
  os_unfair_lock_lock(&g_lock);
  g_blockedWrites++;  // other suites: dropped
  os_unfair_lock_unlock(&g_lock);
}
- (void)notarcTest_removeObjectForKey:(NSString*)key {
  if (!g_active || !key) return [self notarcTest_removeObjectForKey:key];
  if (IsTracked(self)) return TestStore(self, key, nil);
}
- (id)notarcTest_objectForKey:(NSString*)key {
  id v = nil;
  if (TestLookup(self, key, &v)) return v;
  return [self notarcTest_objectForKey:key];
}
- (BOOL)notarcTest_boolForKey:(NSString*)key {
  id v = nil;
  if (TestLookup(self, key, &v)) {
    if ([v isKindOfClass:NSString.class]) return [v boolValue];
    return [v respondsToSelector:@selector(boolValue)] && [v boolValue];
  }
  return [self notarcTest_boolForKey:key];
}
- (NSInteger)notarcTest_integerForKey:(NSString*)key {
  id v = nil;
  if (TestLookup(self, key, &v)) return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
  return [self notarcTest_integerForKey:key];
}
- (BOOL)notarcTest_synchronize {
  if (g_active) return YES;
  return [self notarcTest_synchronize];
}
@end

static void Swap(SEL a, SEL b) {
  Class c = NSUserDefaults.class;
  method_exchangeImplementations(class_getInstanceMethod(c, a), class_getInstanceMethod(c, b));
}

void TestIsolationInstall(void) {
  if (g_active) return;
  g_written = [NSMutableDictionary dictionary];
  g_debug = [NSMutableArray array];
  g_realKeys = [NSSet setWithArray:[NSUserDefaults.standardUserDefaults persistentDomainForName:kBundleID].allKeys ?: @[]];
  g_profileTimes = ProfileTimes();
  Swap(@selector(setObject:forKey:), @selector(notarcTest_setObject:forKey:));
  Swap(@selector(removeObjectForKey:), @selector(notarcTest_removeObjectForKey:));
  Swap(@selector(objectForKey:), @selector(notarcTest_objectForKey:));
  Swap(@selector(boolForKey:), @selector(notarcTest_boolForKey:));
  Swap(@selector(integerForKey:), @selector(notarcTest_integerForKey:));
  Swap(@selector(synchronize), @selector(notarcTest_synchronize));
  g_active = YES;
}

// Another NotArc open (the user's own, on the real profile) may legitimately save its files during a test run.
static BOOL OtherNotArcRunning(void) {
  pid_t me = getpid();
  for (NSRunningApplication* a in [NSRunningApplication runningApplicationsWithBundleIdentifier:kBundleID])
    if (a.processIdentifier != me && !a.terminated) return YES;
  return NO;
}

NSString* TestIsolationReport(void) {
  // Proof the guard works: a direct write is readable in this run but never reaches the saved preferences.
  NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
  NSString* canary = [NSString stringWithFormat:@"canary-%d", getpid()];
  [d setObject:canary forKey:@"notarcSelfTestCanary"];
  [d synchronize];
  BOOL canaryHeld = [[d objectForKey:@"notarcSelfTestCanary"] isEqual:canary] &&
                    ![d persistentDomainForName:kBundleID][@"notarcSelfTestCanary"];
  [d removeObjectForKey:@"notarcSelfTestCanary"];
  NSDictionary* now = ProfileTimes();
  BOOL prefsSame = YES, dataSame = YES;
  for (NSString* p in RealProfileFiles()) {
    if ([now[p] isEqual:g_profileTimes[p]]) continue;
    if ([p hasSuffix:@".plist"]) prefsSame = NO;
    else dataSame = NO;
    [g_debug addObject:[NSString stringWithFormat:@"changed:%@", p.lastPathComponent]];
  }
  if ((!prefsSame || !dataSame) && OtherNotArcRunning()) {
    [g_debug addObject:@"anotherNotArcOpen(counted as untouched)"];
    prefsSame = dataSame = YES;
  }
  os_unfair_lock_lock(&g_lock);
  NSUInteger blocked = g_blockedWrites;
  os_unfair_lock_unlock(&g_lock);
  return [NSString stringWithFormat:@"isolatedHome=%d prefsUntouched=%d dataUntouched=%d canaryHeld=%d blockedWrites=%lu",
                                    TestIsolationHomeIsolated(), prefsSame, dataSame, canaryHeld, (unsigned long)blocked];
}

NSString* TestIsolationDebug(void) {
  os_unfair_lock_lock(&g_lock);
  NSArray* keys = [g_written.allKeys sortedArrayUsingSelector:@selector(compare:)];
  os_unfair_lock_unlock(&g_lock);
  return [NSString stringWithFormat:@"%@ written=%@", [g_debug componentsJoinedByString:@","] ?: @"",
                                    [keys componentsJoinedByString:@","]];
}
