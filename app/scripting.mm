#import "app/scripting.h"

#import "app/arc_import.h"
#import "app/main_window.h"

static MainWindowController* ControllerOf(NSWindow* w) {
  id c = w.windowController;
  return [c isKindOfClass:MainWindowController.class] ? c : nil;
}

static BOOL Under(ArcItem* root, ArcItem* item) {
  for (ArcItem* c in root.children) if (c == item || Under(c, item)) return YES;
  return NO;
}

static NSArray<ArcItem*>* TabsOf(ArcSpace* s) {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcItem* t in s.allTabs) if (t.url.length) [out addObject:t];
  return out;
}

@implementation NAScriptTab
- (NSString*)uniqueID { return self.item.itemID; }
- (NSString*)scriptTitle { return self.item.liveTitle ?: self.item.displayTitle; }
- (NSString*)scriptURL { return self.item.url ?: self.pendingURL; }
- (void)setScriptURL:(NSString*)url {
  if (!self.item) { self.pendingURL = url; return; }
  [self.controller loadURL:url inItem:self.item];
}
- (BOOL)scriptLoading { return [self.controller scriptItem:self.item command:@"loading"]; }
- (NSString*)scriptLocation {
  ArcSpace* s = self.controller.currentSpace;
  if (Under(s.favorites, self.item)) return @"favorites";
  if (Under(s.pinned, self.item)) return @"pinned";
  return @"unpinned";
}
- (NSScriptObjectSpecifier*)objectSpecifier {
  NSScriptObjectSpecifier* win = self.controller.window.objectSpecifier;
  return [[NSUniqueIDSpecifier alloc] initWithContainerClassDescription:(NSScriptClassDescription*)win.keyClassDescription
                                                     containerSpecifier:win key:@"scriptTabs" uniqueID:self.uniqueID];
}
- (id)run:(NSString*)cmd { [self.controller scriptItem:self.item command:cmd]; return nil; }
- (id)handleSelect:(NSScriptCommand*)c { return [self run:@"select"]; }
- (id)handleGoBack:(NSScriptCommand*)c { return [self run:@"back"]; }
- (id)handleGoForward:(NSScriptCommand*)c { return [self run:@"forward"]; }
- (id)handleReload:(NSScriptCommand*)c { return [self run:@"reload"]; }
- (id)handleStop:(NSScriptCommand*)c { return [self run:@"stop"]; }
- (id)handleCloseTab:(NSScriptCommand*)c { return [self run:@"close"]; }
- (id)handleExecute:(NSScriptCommand*)c {
  NSString* js = c.evaluatedArguments[@"javascript"];
  if (js.length) [self.controller runJS:js inItem:self.item];
  return nil;
}
@end

@implementation NAScriptSpace
- (NSString*)uniqueID { return self.space.spaceID; }
- (NSString*)scriptTitle { return self.space.title; }
- (NSArray*)scriptTabs {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcItem* t in TabsOf(self.space)) {
    NAScriptTab* w = [NAScriptTab new];
    w.controller = self.controller;
    w.item = t;
    [out addObject:w];
  }
  return out;
}
- (NSScriptObjectSpecifier*)objectSpecifier {
  NSScriptObjectSpecifier* win = self.controller.window.objectSpecifier;
  return [[NSUniqueIDSpecifier alloc] initWithContainerClassDescription:(NSScriptClassDescription*)win.keyClassDescription
                                                     containerSpecifier:win key:@"scriptSpaces" uniqueID:self.uniqueID];
}
- (id)handleFocus:(NSScriptCommand*)c {
  if (self.space != self.controller.currentSpace) [self.controller switchToSpace:self.space];
  return nil;
}
@end

@implementation NSWindow (NotArcScripting)
- (NSArray*)scriptTabs {
  MainWindowController* m = ControllerOf(self);
  if (!m) return @[];
  NAScriptSpace* s = [NAScriptSpace new];
  s.controller = m;
  s.space = m.currentSpace;
  return s.scriptTabs;
}
- (void)insertInScriptTabs:(NAScriptTab*)tab { [self insertObject:tab inScriptTabsAtIndex:0]; }
- (void)insertObject:(NAScriptTab*)tab inScriptTabsAtIndex:(NSUInteger)index {
  MainWindowController* m = ControllerOf(self);
  if (!m) return;
  [m openInNewTab:tab.pendingURL.length ? tab.pendingURL : @"about:blank"];
  tab.controller = m;
  tab.item = m.shownItem;
}
- (NSArray*)scriptSpaces {
  MainWindowController* m = ControllerOf(self);
  NSMutableArray* out = [NSMutableArray array];
  for (ArcSpace* sp in m.spaces) {
    NAScriptSpace* s = [NAScriptSpace new];
    s.controller = m;
    s.space = sp;
    [out addObject:s];
  }
  return out;
}
- (NAScriptTab*)scriptActiveTab {
  MainWindowController* m = ControllerOf(self);
  if (!m.shownItem) return nil;
  NAScriptTab* t = [NAScriptTab new];
  t.controller = m;
  t.item = m.shownItem;
  return t;
}
- (NAScriptSpace*)scriptActiveSpace {
  MainWindowController* m = ControllerOf(self);
  if (!m) return nil;
  NAScriptSpace* s = [NAScriptSpace new];
  s.controller = m;
  s.space = m.currentSpace;
  return s;
}
- (BOOL)scriptIncognito { return [self.title hasPrefix:@"Incognito"]; }
@end
