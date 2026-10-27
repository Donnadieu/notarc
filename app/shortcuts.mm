#import "app/shortcuts.h"

#import "app/settings.h"

static NSString* const kOverrides = @"shortcutOverrides";
static const NSEventModifierFlags kMods = NSEventModifierFlagCommand | NSEventModifierFlagShift |
                                          NSEventModifierFlagOption | NSEventModifierFlagControl;

static NSMutableDictionary<NSString*, NSDictionary*>* Builtins() {
  static NSMutableDictionary* d;
  if (!d) d = [NSMutableDictionary dictionary];
  return d;
}

NSString* ShortcutPath(NSMenuItem* item) {
  NSMutableArray* parts = [NSMutableArray arrayWithObject:item.title ?: @""];
  for (NSMenu* m = item.menu; m && m.supermenu; m = m.supermenu) [parts insertObject:m.title ?: @"" atIndex:0];
  return [parts componentsJoinedByString:@"/"];
}

NSString* ShortcutDisplay(NSString* key, NSEventModifierFlags mods) {
  if (!key.length) return @"";
  NSMutableString* s = [NSMutableString string];
  if (mods & NSEventModifierFlagControl) [s appendString:@"⌃"];
  if (mods & NSEventModifierFlagOption) [s appendString:@"⌥"];
  if (mods & NSEventModifierFlagShift) [s appendString:@"⇧"];
  if (mods & NSEventModifierFlagCommand) [s appendString:@"⌘"];
  NSDictionary* names = @{@"\t" : @"Tab", @"\r" : @"Return", @" " : @"Space", @"\x1b" : @"Esc",
                          [NSString stringWithFormat:@"%C", (unichar)NSLeftArrowFunctionKey] : @"←",
                          [NSString stringWithFormat:@"%C", (unichar)NSRightArrowFunctionKey] : @"→",
                          [NSString stringWithFormat:@"%C", (unichar)NSUpArrowFunctionKey] : @"↑",
                          [NSString stringWithFormat:@"%C", (unichar)NSDownArrowFunctionKey] : @"↓"};
  [s appendString:names[key] ?: key.uppercaseString];
  return s;
}

static void Walk(NSMenu* menu, void (^f)(NSMenuItem*)) {
  for (NSMenuItem* i in menu.itemArray) {
    if (i.submenu) Walk(i.submenu, f);
    else if (!i.isSeparatorItem && i.title.length && i.action) f(i);
  }
}

NSMenuItem* MenuItemAtPath(NSMenu* mainMenu, NSString* path) {
  __block NSMenuItem* found = nil;
  Walk(mainMenu, ^(NSMenuItem* i) { if (!found && [ShortcutPath(i) isEqualToString:path]) found = i; });
  return found;
}

static void Apply(NSMenuItem* i, NSDictionary* d) {
  i.keyEquivalent = d[@"key"] ?: @"";
  i.keyEquivalentModifierMask = (NSEventModifierFlags)[d[@"mods"] unsignedIntegerValue];
}

void ApplyShortcutOverrides(NSMenu* mainMenu) {
  NSDictionary* overrides = SettingObject(kOverrides);
  Walk(mainMenu, ^(NSMenuItem* i) {
    NSString* p = ShortcutPath(i);
    if (!Builtins()[p]) Builtins()[p] = @{@"key" : i.keyEquivalent ?: @"", @"mods" : @(i.keyEquivalentModifierMask & kMods)};
    NSDictionary* o = [overrides isKindOfClass:NSDictionary.class] ? overrides[p] : nil;
    if ([o isKindOfClass:NSDictionary.class]) Apply(i, o);
  });
}

NSString* SetShortcut(NSMenu* mainMenu, NSString* path, NSString* key, NSEventModifierFlags mods) {
  NSMenuItem* item = MenuItemAtPath(mainMenu, path);
  if (!item) return nil;
  NSMutableDictionary* overrides = [([SettingObject(kOverrides) isKindOfClass:NSDictionary.class] ? SettingObject(kOverrides) : @{}) mutableCopy];
  NSDictionary* want = key ? @{@"key" : key.lowercaseString, @"mods" : @(mods & kMods)} : Builtins()[path];
  __block NSString* cleared = nil;
  if ([want[@"key"] length]) {  // one combination, one command: the other one loses it
    Walk(mainMenu, ^(NSMenuItem* i) {
      if (i == item || cleared) return;
      if ([i.keyEquivalent.lowercaseString isEqualToString:want[@"key"]] &&
          (i.keyEquivalentModifierMask & kMods) == [want[@"mods"] unsignedIntegerValue]) {
        cleared = ShortcutPath(i);
        Apply(i, @{@"key" : @"", @"mods" : @0});
        overrides[cleared] = @{@"key" : @"", @"mods" : @0};
      }
    });
  }
  if (key) overrides[path] = want;
  else [overrides removeObjectForKey:path];
  Apply(item, want ?: @{@"key" : @"", @"mods" : @0});
  SettingSetObject(kOverrides, overrides);
  return cleared;
}

#pragma mark Window

@interface ShortcutsWindowController () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation ShortcutsWindowController {
  NSTableView* _table;
  NSArray<NSMenuItem*>* _items;
  NSSearchField* _search;
  id _recorder;
  NSInteger _recordingRow;
  NSTextField* _status;
}

+ (instancetype)shared {
  static ShortcutsWindowController* s;
  if (!s) s = [ShortcutsWindowController new];
  return s;
}

- (instancetype)init {
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 520)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
  w.title = @"Keyboard Shortcuts";
  w.releasedWhenClosed = NO;
  if (!(self = [super initWithWindow:w])) return nil;
  _recordingRow = -1;
  _search = [NSSearchField new];
  _search.placeholderString = @"Search commands";
  _search.target = self;
  _search.action = @selector(reload);
  _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
  for (NSArray* c in @[ @[ @"cmd", @"Command", @360 ], @[ @"key", @"Shortcut", @140 ] ]) {
    NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    tc.title = c[1];
    tc.width = [c[2] doubleValue];
    [_table addTableColumn:tc];
  }
  _table.dataSource = self;
  _table.delegate = self;
  _table.doubleAction = @selector(record:);
  _table.target = self;
  _table.usesAlternatingRowBackgroundColors = YES;
  NSScrollView* scroll = [NSScrollView new];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;
  NSButton* change = [NSButton buttonWithTitle:@"Change..." target:self action:@selector(record:)];
  NSButton* clear = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(clearShortcut:)];
  NSButton* reset = [NSButton buttonWithTitle:@"Reset" target:self action:@selector(resetShortcut:)];
  _status = [NSTextField labelWithString:@"Double-click a command, then press the new keys. Esc cancels."];
  _status.textColor = NSColor.secondaryLabelColor;
  NSView* c = w.contentView;
  for (NSView* v in @[ _search, scroll, change, clear, reset, _status ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:v];
  }
  [NSLayoutConstraint activateConstraints:@[
    [_search.topAnchor constraintEqualToAnchor:c.topAnchor constant:14],
    [_search.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:16],
    [_search.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-16],
    [scroll.topAnchor constraintEqualToAnchor:_search.bottomAnchor constant:10],
    [scroll.leadingAnchor constraintEqualToAnchor:_search.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:_search.trailingAnchor],
    [change.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:10],
    [change.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [clear.centerYAnchor constraintEqualToAnchor:change.centerYAnchor],
    [clear.leadingAnchor constraintEqualToAnchor:change.trailingAnchor constant:6],
    [reset.centerYAnchor constraintEqualToAnchor:change.centerYAnchor],
    [reset.leadingAnchor constraintEqualToAnchor:clear.trailingAnchor constant:6],
    [_status.topAnchor constraintEqualToAnchor:change.bottomAnchor constant:8],
    [_status.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [_status.trailingAnchor constraintLessThanOrEqualToAnchor:scroll.trailingAnchor],
    [_status.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-14],
  ]];
  [self reload];
  [w center];
  return self;
}

- (void)reload {
  NSString* q = _search.stringValue.lowercaseString;
  NSMutableArray* items = [NSMutableArray array];
  Walk(NSApp.mainMenu, ^(NSMenuItem* i) {
    if (!q.length || [ShortcutPath(i).lowercaseString containsString:q]) [items addObject:i];
  });
  _items = items;
  [_table reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)_items.count; }

- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  NSMenuItem* i = _items[(NSUInteger)row];
  NSString* text = [col.identifier isEqualToString:@"cmd"]
      ? [ShortcutPath(i) stringByReplacingOccurrencesOfString:@"/" withString:@" › "]
      : (row == _recordingRow ? @"Press keys..." : ShortcutDisplay(i.keyEquivalent, i.keyEquivalentModifierMask & kMods));
  NSTextField* f = [NSTextField labelWithString:text];
  f.lineBreakMode = NSLineBreakByTruncatingTail;
  return f;
}

- (void)record:(id)sender {
  NSInteger row = _table.selectedRow;
  if (row < 0) return;
  [self stopRecording];
  _recordingRow = row;
  [_table reloadData];
  __weak ShortcutsWindowController* weakSelf = self;
  _recorder = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* e) {
    ShortcutsWindowController* me = weakSelf;
    if (!me || e.window != me.window) return e;
    if (e.keyCode == 53) { [me stopRecording]; return nil; }  // Esc
    NSEventModifierFlags mods = e.modifierFlags & kMods;
    NSString* key = e.charactersIgnoringModifiers.lowercaseString;
    if (!(mods & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption)) || !key.length) {
      me->_status.stringValue = @"Use at least one of ⌘, ⌃ or ⌥.";
      return nil;
    }
    [me assign:key mods:mods];
    return nil;
  }];
}

- (void)assign:(NSString*)key mods:(NSEventModifierFlags)mods {
  NSInteger row = _recordingRow;
  [self stopRecording];
  if (row < 0 || row >= (NSInteger)_items.count) return;
  NSString* cleared = SetShortcut(NSApp.mainMenu, ShortcutPath(_items[(NSUInteger)row]), key, mods);
  _status.stringValue = cleared ? [NSString stringWithFormat:@"Taken from %@.", [cleared stringByReplacingOccurrencesOfString:@"/" withString:@" › "]]
                                : @"Saved.";
  [_table reloadData];
}

- (void)stopRecording {
  if (_recorder) [NSEvent removeMonitor:_recorder];
  _recorder = nil;
  _recordingRow = -1;
  [_table reloadData];
}

- (void)clearShortcut:(id)sender {
  if (_table.selectedRow < 0) return;
  SetShortcut(NSApp.mainMenu, ShortcutPath(_items[(NSUInteger)_table.selectedRow]), @"", 0);
  [_table reloadData];
}

- (void)resetShortcut:(id)sender {
  if (_table.selectedRow < 0) return;
  SetShortcut(NSApp.mainMenu, ShortcutPath(_items[(NSUInteger)_table.selectedRow]), nil, 0);
  [_table reloadData];
}
@end
