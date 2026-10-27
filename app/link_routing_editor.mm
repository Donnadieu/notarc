#import "app/link_routing_editor.h"

#import "app/link_routing.h"

static NSArray<NSArray<NSString*>*>* MatchChoices() {
  return @[ @[ @"contains", @"URL contains" ], @[ @"domain", @"Domain is" ], @[ @"startsWith", @"URL starts with" ],
            @[ @"exact", @"URL is exactly" ], @[ @"regex", @"URL matches regex" ] ];
}

@interface LinkRoutingEditor () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation LinkRoutingEditor {
  NSString* _path;
  NSArray<NSArray<NSString*>*>* _spaces;
  LinkRouting* _routing;
  NSTableView* _table;
  NSPopUpButton* _default;
}

- (instancetype)initWithPath:(NSString*)path spaces:(NSArray<NSArray<NSString*>*>*)spaces {
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 380)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
  w.title = @"Air Traffic Control";
  w.releasedWhenClosed = NO;
  w.minSize = NSMakeSize(620, 260);
  if (!(self = [super initWithWindow:w])) return nil;
  _path = [path copy];
  _spaces = [spaces copy];
  _routing = [LinkRouting loadFrom:path];
  if (!_routing) {
    _routing = [LinkRouting new];
    _routing.rules = @[];
    _routing.defaultDestination = @"little";
  }
  [self buildUI];
  return self;
}

- (LinkRouting*)routing { return _routing; }

- (void)save {
  [_routing saveTo:_path];
}

// Destination popup: Most recent Space, each Space, Little Window. representedObject "space:<id>" / "space:" / "little".
- (NSPopUpButton*)destinationPopupTo:(NSString*)to space:(NSString*)spaceID {
  NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  [p addItemWithTitle:@"Most recent Space"];
  p.lastItem.representedObject = @"space:";
  for (NSArray* s in _spaces) {
    [p addItemWithTitle:s[1]];
    p.lastItem.representedObject = [@"space:" stringByAppendingString:s[0]];
  }
  [p addItemWithTitle:@"Little Window"];
  p.lastItem.representedObject = @"little";
  NSString* want = [to isEqualToString:@"little"] ? @"little" : [@"space:" stringByAppendingString:spaceID ?: @""];
  for (NSMenuItem* i in p.itemArray) if ([i.representedObject isEqualToString:want]) [p selectItem:i];
  return p;
}

static void SplitDestination(NSString* rep, NSString** to, NSString** spaceID) {
  if ([rep isEqualToString:@"little"]) { *to = @"little"; *spaceID = nil; return; }
  *to = @"space";
  NSString* sid = [rep substringFromIndex:6];
  *spaceID = sid.length ? sid : nil;
}

- (void)buildUI {
  NSView* c = self.window.contentView;
  NSTextField* intro = [NSTextField wrappingLabelWithString:
      @"Choose where links you open from other apps go. The first rule that matches wins; links that match no rule "
      @"use the default below."];
  intro.textColor = NSColor.secondaryLabelColor;

  _table = [[NSTableView alloc] initWithFrame:NSZeroRect];
  for (NSArray* col in @[ @[ @"match", @"If the link", @150 ], @[ @"pattern", @"", @180 ], @[ @"app", @"From app (bundle ID, optional)", @170 ],
                           @[ @"to", @"Open in", @160 ] ]) {
    NSTableColumn* tc = [[NSTableColumn alloc] initWithIdentifier:col[0]];
    tc.title = col[1];
    tc.width = [col[2] doubleValue];
    [_table addTableColumn:tc];
  }
  _table.rowHeight = 28;
  _table.dataSource = self;
  _table.delegate = self;
  _table.usesAlternatingRowBackgroundColors = YES;
  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scroll.documentView = _table;
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;

  NSSegmentedControl* plusMinus = [NSSegmentedControl segmentedControlWithImages:@[
    [NSImage imageNamed:NSImageNameAddTemplate], [NSImage imageNamed:NSImageNameRemoveTemplate]
  ] trackingMode:NSSegmentSwitchTrackingMomentary target:self action:@selector(plusMinus:)];

  _default = [self destinationPopupTo:_routing.defaultDestination space:_routing.defaultSpaceID];
  _default.target = self;
  _default.action = @selector(defaultChanged:);
  NSStackView* def = [NSStackView stackViewWithViews:@[ [NSTextField labelWithString:@"Everything else opens in:"], _default ]];

  for (NSView* v in @[ intro, scroll, plusMinus, def ]) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [c addSubview:v];
  }
  [NSLayoutConstraint activateConstraints:@[
    [intro.topAnchor constraintEqualToAnchor:c.topAnchor constant:18],
    [intro.leadingAnchor constraintEqualToAnchor:c.leadingAnchor constant:20],
    [intro.trailingAnchor constraintEqualToAnchor:c.trailingAnchor constant:-20],
    [scroll.topAnchor constraintEqualToAnchor:intro.bottomAnchor constant:12],
    [scroll.leadingAnchor constraintEqualToAnchor:intro.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:intro.trailingAnchor],
    [plusMinus.topAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:8],
    [plusMinus.leadingAnchor constraintEqualToAnchor:scroll.leadingAnchor],
    [def.centerYAnchor constraintEqualToAnchor:plusMinus.centerYAnchor],
    [def.trailingAnchor constraintEqualToAnchor:scroll.trailingAnchor],
    [plusMinus.bottomAnchor constraintEqualToAnchor:c.bottomAnchor constant:-16],
  ]];
  [self.window center];
}

#pragma mark Editing

- (void)addRule {
  LinkRule* r = [LinkRule new];
  r.matchType = @"contains";
  r.pattern = @"";
  r.destination = @"space";
  _routing.rules = [_routing.rules arrayByAddingObject:r];
  [self save];
  [_table reloadData];
}

- (void)removeRuleAt:(NSUInteger)index {
  if (index >= _routing.rules.count) return;
  NSMutableArray* m = [_routing.rules mutableCopy];
  [m removeObjectAtIndex:index];
  _routing.rules = m;
  [self save];
  [_table reloadData];
}

- (void)setRuleAt:(NSUInteger)index match:(NSString*)match pattern:(NSString*)pattern app:(NSString*)app
               to:(NSString*)destination space:(NSString*)spaceID {
  if (index >= _routing.rules.count) return;
  LinkRule* r = _routing.rules[index];
  if (match) r.matchType = match;
  if (pattern) r.pattern = pattern;
  if (app) r.sourceApp = app.length ? app : nil;
  if (destination) {
    r.destination = destination;
    r.spaceID = spaceID;
  }
  [self save];
}

- (void)setDefaultTo:(NSString*)destination space:(NSString*)spaceID {
  _routing.defaultDestination = destination;
  _routing.defaultSpaceID = spaceID;
  [self save];
}

- (void)plusMinus:(NSSegmentedControl*)sender {
  if (sender.selectedSegment == 0) {
    [self addRule];
    NSInteger row = (NSInteger)_routing.rules.count - 1;
    [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    [_table editColumn:1 row:row withEvent:nil select:YES];
  } else if (_table.selectedRow >= 0) {
    [self removeRuleAt:(NSUInteger)_table.selectedRow];
  }
}

- (void)defaultChanged:(NSPopUpButton*)sender {
  NSString* to, *sid;
  SplitDestination(sender.selectedItem.representedObject, &to, &sid);
  [self setDefaultTo:to space:sid];
}

#pragma mark Table

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)_routing.rules.count; }

- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  LinkRule* r = _routing.rules[(NSUInteger)row];
  NSString* ident = col.identifier;
  NSControl* v;
  if ([ident isEqualToString:@"match"]) {
    NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSArray* m in MatchChoices()) {
      [p addItemWithTitle:m[1]];
      p.lastItem.representedObject = m[0];
      if ([m[0] isEqualToString:r.matchType]) [p selectItem:p.lastItem];
    }
    p.action = @selector(matchChanged:);
    v = p;
  } else if ([ident isEqualToString:@"to"]) {
    NSPopUpButton* p = [self destinationPopupTo:r.destination space:r.spaceID];
    p.action = @selector(destinationChanged:);
    v = p;
  } else {
    NSTextField* f = [NSTextField textFieldWithString:([ident isEqualToString:@"pattern"] ? r.pattern : r.sourceApp) ?: @""];
    f.placeholderString = [ident isEqualToString:@"pattern"] ? @"meet.google.com" : @"any app";
    f.bordered = NO;
    f.drawsBackground = NO;
    f.action = @selector(textChanged:);
    f.identifier = ident;
    f.cell.sendsActionOnEndEditing = YES;
    v = f;
  }
  v.target = self;
  v.tag = row;
  v.controlSize = NSControlSizeSmall;
  return v;
}

- (void)matchChanged:(NSPopUpButton*)p {
  [self setRuleAt:(NSUInteger)p.tag match:p.selectedItem.representedObject pattern:nil app:nil to:nil space:nil];
}

- (void)destinationChanged:(NSPopUpButton*)p {
  NSString* to, *sid;
  SplitDestination(p.selectedItem.representedObject, &to, &sid);
  [self setRuleAt:(NSUInteger)p.tag match:nil pattern:nil app:nil to:to space:sid];
}

- (void)textChanged:(NSTextField*)f {
  NSString* text = [f.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  BOOL pattern = [f.identifier isEqualToString:@"pattern"];
  [self setRuleAt:(NSUInteger)f.tag match:nil pattern:pattern ? text : nil app:pattern ? nil : text to:nil space:nil];
}
@end
