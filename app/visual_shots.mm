// Hidden design renders for the visual parity checklist. See visual_shots.h for the plan format.
#import "app/visual_shots.h"
#import "app/downloads.h"

#include <dlfcn.h>
#include <objc/runtime.h>
#include <cstdio>
#include <initializer_list>
#include <string>

#import "app/arc_import.h"
#import "app/main_window.h"
#import "app/settings.h"

static const CGFloat kOffscreen = -30000;
static NSSize gSize = {1280, 820};

BOOL VisualShotsRequested(int argc, char* argv[], NSString** planPath) {
  for (int i = 1; i < argc; ++i)
    if (std::string(argv[i]).rfind("--visual-shots=", 0) == 0) {
      if (planPath) *planPath = [NSString stringWithUTF8String:argv[i] + strlen("--visual-shots=")];
      return YES;
    }
  return NO;
}

// macOS keeps windows on a screen; renders need them far away from every screen, so frames pass through as asked.
static NSRect PassThroughConstrain(id, SEL, NSRect r, NSScreen*) { return r; }

void VisualShotsPrepareWindow(NSWindow* window) {
  // Every window class, before any panel is first placed (a panel's first frame would otherwise land on a screen).
  for (Class k : {NSWindow.class, NSPanel.class, window.class})
    class_replaceMethod(k, @selector(constrainFrameRect:toScreen:), (IMP)PassThroughConstrain,
                        "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}@");
  [window setFrame:NSMakeRect(kOffscreen, kOffscreen, gSize.width, gSize.height) display:NO];
}

void VisualShotsKeepOffscreen(MainWindowController* controller) {
  NSWindow* main = controller.window;
  if (NSMinX(main.frame) > kOffscreen / 3) [main setFrameOrigin:NSMakePoint(kOffscreen, kOffscreen)];
  static NSMutableSet<Class>* patched = [NSMutableSet set];
  for (NSWindow* w in NSApp.windows) {
    if (![patched containsObject:w.class]) {
      [patched addObject:w.class];
      class_replaceMethod(w.class, @selector(constrainFrameRect:toScreen:), (IMP)PassThroughConstrain,
                          "{CGRect={CGPoint=dd}{CGSize=dd}}@:{CGRect={CGPoint=dd}{CGSize=dd}}@");
    }
    BOOL off = NSMaxX(w.frame) < kOffscreen / 3;
    w.alphaValue = off ? 1 : 0.01;  // anything that ever lands on a screen stays invisible
    w.ignoresMouseEvents = YES;
  }
}

typedef CGImageRef (*WindowImageFn)(CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption);

static CGImageRef CopyWindowImage(NSWindow* w) {
  static WindowImageFn fn = (WindowImageFn)dlsym(RTLD_DEFAULT, "CGWindowListCreateImage");
  if (!fn) return NULL;
  return fn(CGRectNull, kCGWindowListOptionIncludingWindow, (CGWindowID)w.windowNumber,
            kCGWindowImageBoundsIgnoreFraming | kCGWindowImageBestResolution);
}

static BOOL WritePNG(CGImageRef img, NSString* path) {
  NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithCGImage:img];
  return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

// The main window plus every offscreen panel above it (command bar, popovers, hover cards), drawn where they sit.
static BOOL ShootWindow(MainWindowController* c, NSString* path) {
  NSWindow* main = c.window;
  CGImageRef base = CopyWindowImage(main);
  if (!base) return NO;
  CGFloat scale = main.backingScaleFactor ?: 2;
  size_t W = CGImageGetWidth(base), H = CGImageGetHeight(base);
  CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(NULL, W, H, 8, 0, cs, kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(cs);
  CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), base);
  CGImageRelease(base);
  int children = 0;
  NSMutableArray<NSWindow*>* order = [NSMutableArray array];
  for (NSNumber* n in [NSWindow windowNumbersWithOptions:0].reverseObjectEnumerator) {  // back to front
    NSWindow* w = [NSApp windowWithWindowNumber:n.integerValue];
    if (w && w != main) [order addObject:w];
  }
  for (NSWindow* w in NSApp.windows)
    if (w != main && ![order containsObject:w]) [order addObject:w];
  for (NSWindow* w in order) {
    if (!w.isVisible || NSMaxX(w.frame) > kOffscreen / 3 || w.alphaValue < 0.9) continue;
    if (!NSIntersectsRect(NSInsetRect(main.frame, -400, -400), w.frame)) continue;
    CGImageRef ci = CopyWindowImage(w);
    if (!ci) continue;
    CGFloat x = (NSMinX(w.frame) - NSMinX(main.frame)) * scale, y = (NSMinY(w.frame) - NSMinY(main.frame)) * scale;
    CGContextDrawImage(ctx, CGRectMake(x, y, CGImageGetWidth(ci), CGImageGetHeight(ci)), ci);
    CGImageRelease(ci);
    children++;
  }
  CGImageRef out = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  BOOL ok = WritePNG(out, path);
  CGImageRelease(out);
  std::printf("VISUAL shot %s %s %zux%zu panels=%d\n", path.lastPathComponent.UTF8String, ok ? "ok" : "failed", W, H,
              children);
  return ok;
}

static ArcItem* FindTab(ArcSpace* space, NSString* text) {
  for (ArcItem* t in space.allTabs)
    if ([t.url containsString:text] || [t.displayTitle containsString:text]) return t;
  return nil;
}

@interface VisualPlan : NSObject
@property(nonatomic, weak) MainWindowController* controller;
@property(nonatomic, strong) NSArray<NSString*>* lines;
@property(nonatomic) NSUInteger next;
@property(nonatomic, copy) NSString* outDir;
- (void)step;
@end

@implementation VisualPlan
- (void)after:(double)sec {
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(sec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    [self step];
  });
}
- (void)step {
  MainWindowController* c = self.controller;
  if (!c) return;
  while (self.next < self.lines.count) {
    NSString* line = [self.lines[self.next++] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!line.length || [line hasPrefix:@"#"]) continue;
    NSRange sp = [line rangeOfString:@" "];
    NSString* cmd = sp.location == NSNotFound ? line : [line substringToIndex:sp.location];
    NSString* arg = sp.location == NSNotFound ? @"" : [[line substringFromIndex:sp.location + 1]
                                                         stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray<NSString*>* args = [arg componentsSeparatedByString:@" "];
    std::printf("VISUAL %s\n", line.UTF8String);
    std::fflush(stdout);
    if ([cmd isEqual:@"wait"]) { [self after:arg.doubleValue]; return; }
    if ([cmd isEqual:@"out"]) {
      self.outDir = arg.stringByExpandingTildeInPath;
      [NSFileManager.defaultManager createDirectoryAtPath:self.outDir withIntermediateDirectories:YES attributes:nil error:nil];
    } else if ([cmd isEqual:@"size"] && args.count >= 2) {
      gSize = NSMakeSize(args[0].doubleValue, args[1].doubleValue);
      [c.window setFrame:NSMakeRect(kOffscreen, kOffscreen, gSize.width, gSize.height) display:YES];
    } else if ([cmd isEqual:@"appearance"]) {
      NSApp.appearance = [arg isEqual:@"dark"]    ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
                         : [arg isEqual:@"light"] ? [NSAppearance appearanceNamed:NSAppearanceNameAqua]
                                                  : nil;
    } else if ([cmd isEqual:@"space"]) {
      NSUInteger i = (NSUInteger)arg.integerValue;
      if (i < c.spaces.count) [c switchToSpace:c.spaces[i]];
    } else if ([cmd isEqual:@"theme"] && args.count >= 3) {
      NSUInteger i = (NSUInteger)args[0].integerValue;
      NSArray* colors = [args subarrayWithRange:NSMakeRange(1, args.count - 2)];
      if (i < c.spaces.count) [c setTheme:colors intensity:args.lastObject.doubleValue forSpace:c.spaces[i]];
    } else if ([cmd isEqual:@"newtab"] || [cmd isEqual:@"open"]) {
      [c openInNewTab:arg];
    } else if ([cmd isEqual:@"show"]) {
      ArcItem* t = FindTab(c.currentSpace, arg);
      if (t) [c showItem:t];
      std::printf("VISUAL show %s\n", t ? t.url.UTF8String : "not found");
    } else if ([cmd isEqual:@"split"] && args.count >= 2) {  // split <url> <url> [<url> ...]
      [c openSplitFromText:[args componentsJoinedByString:@"\n"]];
    } else if ([cmd isEqual:@"newspace"]) {
      ArcSpace* s = [c createSpaceNamed:arg.length ? arg : @"Empty"];
      if (s) [c switchToSpace:s];
    } else if ([cmd isEqual:@"peek-sidebar"]) {
      if (!c.sidebarHidden) [c toggleSidebar:nil];
      [c beginSidebarPeekForTest];
    } else if ([cmd isEqual:@"loading"]) {
      if (c.shownItem) [c setItem:c.shownItem loadingForTest:![arg isEqual:@"0"]];
    } else if ([cmd isEqual:@"inactive"]) {
      [c sidebarDimmedForTest:![arg isEqual:@"0"]];
    } else if ([cmd isEqual:@"hover-today"]) {
      SEL s = NSSelectorFromString(@"setSidebarHoverRow:");
      NSOutlineView* ov = [c valueForKey:@"_outline"];
      NSInteger row = [ov rowForItem:c.currentSpace.unpinned];
      ((void (*)(id, SEL, NSInteger))[c methodForSelector:s])(c, s, row);
    } else if ([cmd isEqual:@"peek"]) {
      [c openPeek:arg];
      // macOS moves a window onto a screen when it's first ordered in; put the Peek back where it was asked to be.
      NSWindowController* pk = [c valueForKey:@"_peek"];
      NSView* content = [c valueForKey:@"_content"];
      NSRect card = [c.window convertRectToScreen:[content convertRect:content.bounds toView:nil]];
      [pk.window setFrame:NSMakeRect(NSMinX(card) + card.size.width * 0.05, NSMinY(card) + card.size.height * 0.04,
                                     card.size.width * 0.90, card.size.height * 0.96 - 8)
                  display:YES];
    } else if ([cmd isEqual:@"close-peek"]) {
      [c closePeek];
    } else if ([cmd isEqual:@"toast"]) {
      SEL s = NSSelectorFromString(@"showToast:action:selector:");
      ((void (*)(id, SEL, id, id, SEL))[c methodForSelector:s])(c, s, arg, @"Undo", NSSelectorFromString(@"hideToast"));
    } else if ([cmd isEqual:@"find"]) {
      [c findInPage:nil];
      NSTextField* f = [c valueForKey:@"_findField"];
      f.stringValue = arg;
      [c findText:arg forward:YES];
    } else if ([cmd isEqual:@"crash"]) {  // crash <tab>: show the crashed-page view on it (no real crash)
      ArcItem* t = FindTab(c.currentSpace, arg);
      if (t) {
        SEL s = NSSelectorFromString(@"showCrashedViewFor:status:");
        ((void (*)(id, SEL, id, int))[c methodForSelector:s])(c, s, t, 3);
      }
    } else if ([cmd isEqual:@"audible"] || [cmd isEqual:@"muted"]) {  // audible|muted <tab>: the row of a tab with sound
      ArcItem* t = FindTab(c.currentSpace, arg);
      if (t) {
        t.mediaPlaying = YES;
        t.audioMuted = [cmd isEqual:@"muted"];
        [c reloadSidebarItemForTest:t];
      }
    } else if ([cmd isEqual:@"update-ready"]) {
      [NSNotificationCenter.defaultCenter postNotificationName:@"NotArcUpdateReady" object:nil
                                                      userInfo:@{@"version" : arg.length ? arg : @"0.27.0", @"staged" : @"/nonexistent"}];
    } else if ([cmd isEqual:@"meeting"]) {  // a fake "Standup in 5 min" card (memory-only settings)
      SEL s = NSSelectorFromString(@"showMeetingForVisualShots");
      if ([c respondsToSelector:s]) ((void (*)(id, SEL))[c methodForSelector:s])(c, s);
    } else if ([cmd isEqual:@"snap"]) {  // snap <tab>: show it and keep a copy of the page as its picture
      ArcItem* t = FindTab(c.currentSpace, arg);
      if (t) {
        [c showItem:t];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1.5]];
        CGImageRef img = CopyWindowImage(c.window);
        NSView* content = [c valueForKey:@"_content"];
        if (img) {
          CGFloat sc = CGImageGetWidth(img) / c.window.frame.size.width;
          NSRect r = [content convertRect:content.bounds toView:nil];
          CGRect crop = CGRectMake(r.origin.x * sc, (c.window.frame.size.height - NSMaxY(r)) * sc, r.size.width * sc, r.size.height * sc);
          CGImageRef part = CGImageCreateWithImageInRect(img, crop);
          if (part) {
            t.thumbnail = [[NSImage alloc] initWithCGImage:part size:NSMakeSize(r.size.width / 3, r.size.height / 3)];
            CGImageRelease(part);
          }
          CGImageRelease(img);
        }
      }
    } else if ([cmd isEqual:@"fake-download"]) {  // fake-download <name> <received> <total>: a download row, no network
      NSArray* a2 = [arg componentsSeparatedByString:@" "];
      static uint32_t fid = 900000;
      ++fid;
      NSString* path = [NSTemporaryDirectory() stringByAppendingPathComponent:a2.firstObject];
      [DownloadManager.shared begin:fid url:[@"https://example.com/" stringByAppendingString:a2.firstObject] path:path];
      if (a2.count >= 3) {
        int64_t rec = [a2[1] longLongValue], tot = [a2[2] longLongValue];
        [DownloadManager.shared update:fid received:rec total:tot speed:rec / 3 path:path
                                 state:rec >= tot ? DownloadComplete : DownloadInProgress];
      }
    } else if ([cmd isEqual:@"front"]) {  // front <ivar>: order a panel kept hidden in test runs to the front (off screen)
      NSWindow* pw = [c valueForKey:arg];
      if ([pw isKindOfClass:NSWindow.class]) {
        pw.hidesOnDeactivate = NO;
        [pw orderFront:nil];
      }
    } else if ([cmd isEqual:@"capture-card"]) {  // the capture result card for the shown page (test pasteboard)
      c.captureDirectory = NSTemporaryDirectory();
      __weak MainWindowController* wc = c;
      [c capture:@"visible" rect:NSZeroRect done:^(NSData* png) { [wc deliverCapture:png]; }];
    } else if ([cmd isEqual:@"library"]) {
      [c showLibrary:nil];
    } else if ([cmd isEqual:@"library-open"]) {
      [c openLibraryRowForTest:(NSUInteger)arg.integerValue];
    } else if ([cmd isEqual:@"site-controls"]) {
      [c showSiteSettings:nil];
    } else if ([cmd isEqual:@"hovercard"]) {
      ArcItem* t = FindTab(c.currentSpace, arg);
      if (t) [c showHoverCardForItem:t];
    } else if ([cmd isEqual:@"switcher"]) {
      [c openTabSwitcherHolding:0];  // shown at once (a held Ctrl would wait for the key to be let go)
    } else if ([cmd isEqual:@"close-switcher"]) {
      [c cancelTabSwitcher];
    } else if ([cmd isEqual:@"little"]) {
      [c openLittleWindow:arg];
    } else if ([cmd isEqual:@"place"]) {  // place <window class> <dx> <dy>: put a child/other window next to the main one
      NSArray* a2 = [arg componentsSeparatedByString:@" "];
      for (NSWindow* w in NSApp.windows)
        if (w != c.window && [NSStringFromClass(w.class) isEqual:a2.firstObject] && w.isVisible && a2.count >= 3) {
          NSRect f = c.window.frame;
          [w setFrameOrigin:NSMakePoint(NSMinX(f) + [a2[1] doubleValue], NSMaxY(f) - [a2[2] doubleValue] - w.frame.size.height)];
        }
    } else if ([cmd isEqual:@"shot-window"]) {  // shot-window <class> <name>: one non-main window on its own
      NSArray* a2 = [arg componentsSeparatedByString:@" "];
      for (NSWindow* w in NSApp.windows)
        if (w != c.window && [NSStringFromClass(w.class) isEqual:a2.firstObject] && w.isVisible && a2.count >= 2) {
          CGImageRef img = CopyWindowImage(w);
          if (img) {
            WritePNG(img, [self.outDir stringByAppendingPathComponent:[a2[1] stringByAppendingString:@".png"]]);
            std::printf("VISUAL shot-window %s %zux%zu\n", [a2[1] UTF8String], CGImageGetWidth(img), CGImageGetHeight(img));
            CGImageRelease(img);
          }
          break;
        }
    } else if ([cmd isEqual:@"hover"]) {
      ArcItem* t = arg.length ? FindTab(c.currentSpace, arg) : nil;
      [c hoverSidebarItem:t];
    } else if ([cmd isEqual:@"js"]) {  // run a script in the shown tab
      if (c.shownItem) [c runJS:arg inItem:c.shownItem];
    } else if ([cmd isEqual:@"poll-media"]) {
      [c pollMediaNow];
    } else if ([cmd isEqual:@"load"]) {
      [c openTabsForSelfTest:(NSUInteger)arg.integerValue];
    } else if ([cmd isEqual:@"do"]) {
      SEL s = NSSelectorFromString(arg);
      if ([c respondsToSelector:s]) [NSApp sendAction:s to:c from:nil];
      else std::printf("VISUAL no action %s\n", arg.UTF8String);
    } else if ([cmd isEqual:@"setting"] && args.count >= 2) {
      SettingSetBool(args[0], args[1].boolValue);
    } else if ([cmd isEqual:@"cmdbar"] || [cmd isEqual:@"cmdbar-current"]) {
      [c showCommandBarForNewTab:[cmd isEqual:@"cmdbar"]];
      // The first time a panel is ordered in, macOS moves it onto a screen; lay it out again, now that it's up.
      SEL relayout = NSSelectorFromString(@"refreshSuggestions");
      if ([c respondsToSelector:relayout]) ((void (*)(id, SEL))[c methodForSelector:relayout])(c, relayout);
      if ([cmd isEqual:@"cmdbar"] && arg.length) {
        NSTextField* f = [c valueForKey:@"_commandField"];
        f.stringValue = arg;
        [(id<NSTextFieldDelegate>)c controlTextDidChange:[NSNotification notificationWithName:NSControlTextDidChangeNotification
                                                                                       object:f]];
      }
    } else if ([cmd isEqual:@"kv"]) {  // print a value, e.g. kv _sidebarScroll.contentView.frame
      id val = nil;
      @try {
        val = [c valueForKeyPath:arg];
      } @catch (NSException* e) {
        val = e.reason;
      }
      std::printf("VISUAL kv %s = %s\n", arg.UTF8String, [val description].UTF8String ?: "nil");
    } else if ([cmd isEqual:@"windows"]) {  // list every window (debugging renders)
      for (NSWindow* w in NSApp.windows)
        std::printf("VISUAL window %s visible=%d alpha=%.2f frame=%s child=%d\n", NSStringFromClass(w.class).UTF8String, w.isVisible,
                    w.alphaValue, NSStringFromRect(w.frame).UTF8String, w.parentWindow != nil);
    } else if ([cmd isEqual:@"close-cmdbar"]) {
      [c hideCommandBar];
    } else if ([cmd isEqual:@"shot"]) {
      ShootWindow(c, [self.outDir stringByAppendingPathComponent:[arg stringByAppendingString:@".png"]]);
    } else if ([cmd isEqual:@"sidebar"]) {
      NSString* p = [self.outDir stringByAppendingPathComponent:[arg stringByAppendingString:@".png"]];
      std::printf("VISUAL sidebar %s %s\n", arg.UTF8String, [c writeSidebarSnapshot:p] ? "ok" : "failed");
    } else if ([cmd isEqual:@"quit"]) {
      std::printf("VISUAL done\n");
      std::fflush(stdout);
      [c closeAllBrowsers];
      return;
    } else {
      std::printf("VISUAL unknown command %s\n", cmd.UTF8String);
    }
    std::fflush(stdout);
  }
  std::printf("VISUAL done\n");
  std::fflush(stdout);
  [c closeAllBrowsers];
}
@end

static VisualPlan* gPlan;

void VisualShotsRun(MainWindowController* controller, NSString* planPath) {
  NSString* text = [NSString stringWithContentsOfFile:planPath encoding:NSUTF8StringEncoding error:nil];
  if (!text) {
    std::printf("VISUAL no plan at %s\n", planPath.UTF8String);
    std::fflush(stdout);
    [controller closeAllBrowsers];
    return;
  }
  gPlan = [VisualPlan new];
  gPlan.controller = controller;
  gPlan.lines = [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
  gPlan.outDir = planPath.stringByDeletingLastPathComponent;
  [gPlan step];
}
