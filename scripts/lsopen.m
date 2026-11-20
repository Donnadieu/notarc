// Helper for scripts/test-open-links.py: hands links to a running NotArc copy through Launch Services, the way Mail,
// Slack, One and `open URL` do (NSWorkspace -> Launch Services -> an open-URL event in NotArc).
//   lsopen wait <app> <pid> <secs>   exit 0 once process <pid> is checked in with Launch Services as <app>
//   lsopen send <app> <pid> <url>... exit 0 once Launch Services handed the links to that same process
// It only ever sends to the copy the test started: if <pid> isn't running as <app>, it sends nothing (Launch Services
// would otherwise start another copy of NotArc, outside the test's throwaway home).
#import <Cocoa/Cocoa.h>

static NSRunningApplication* Running(NSString* app, pid_t pid) {
  NSRunningApplication* r = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
  if (!r || r.terminated) return nil;
  NSString* have = r.bundleURL.URLByResolvingSymlinksInPath.path, *want = [NSURL fileURLWithPath:app].URLByResolvingSymlinksInPath.path;
  return [have isEqualToString:want] ? r : nil;
}

int main(int argc, char** argv) {
  @autoreleasepool {
    if (argc < 5) {
      fprintf(stderr, "usage: lsopen wait <app> <pid> <secs> | lsopen send <app> <pid> <url>...\n");
      return 2;
    }
    NSString* mode = @(argv[1]), *app = @(argv[2]);
    pid_t pid = (pid_t)atoi(argv[3]);
    if ([mode isEqualToString:@"wait"]) {
      NSDate* end = [NSDate dateWithTimeIntervalSinceNow:atof(argv[4])];
      while (!Running(app, pid)) {
        if (end.timeIntervalSinceNow < 0) return 1;
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
      }
      return 0;
    }
    if (![mode isEqualToString:@"send"]) return 2;
    if (!Running(app, pid)) {
      fprintf(stderr, "lsopen: %d isn't running as %s; nothing sent\n", pid, argv[2]);
      return 3;
    }
    NSMutableArray<NSURL*>* urls = [NSMutableArray array];
    for (int i = 4; i < argc; ++i) {
      NSString* s = @(argv[i]);
      [urls addObject:[s hasPrefix:@"/"] ? [NSURL fileURLWithPath:s] : [NSURL URLWithString:s]];
    }
    NSWorkspaceOpenConfiguration* c = [NSWorkspaceOpenConfiguration configuration];
    c.activates = NO;  // hidden test copy: never take focus
    c.addsToRecentItems = NO;
    c.createsNewApplicationInstance = NO;
    __block int rc = -1;
    [NSWorkspace.sharedWorkspace openURLs:urls withApplicationAtURL:[NSURL fileURLWithPath:app] configuration:c
                        completionHandler:^(NSRunningApplication* r, NSError* e) {
      if (e) fprintf(stderr, "lsopen: %s\n", e.localizedDescription.UTF8String);
      rc = e ? 1 : (r.processIdentifier == pid ? 0 : 4);
      if (rc == 4) fprintf(stderr, "lsopen: Launch Services used process %d, not %d\n", r.processIdentifier, pid);
    }];
    NSDate* end = [NSDate dateWithTimeIntervalSinceNow:20];
    while (rc < 0 && end.timeIntervalSinceNow > 0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return rc < 0 ? 5 : rc;
  }
}
