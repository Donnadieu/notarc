#import "app/settings.h"
#import "app/downloads.h"

NSString* const kSettingAutoArchiveHours = @"autoArchiveThresholdHours";
NSString* const kSettingSearchEngine = @"searchEngine";
NSString* const kSettingPeekPinnedLinks = @"peekPinnedLinks";
NSString* const kSettingPeekShiftClick = @"peekShiftClick";
NSString* const kSettingExternalLinksLittle = @"externalLinksOpenInLittleWindow";
NSString* const kSettingLittleArchiveHours = @"littleWindowArchiveHours";

void SettingsRegisterDefaults(void) {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{
    kSettingAutoArchiveHours : @12,
    kSettingSearchEngine : @"google",
    kSettingPeekPinnedLinks : @YES,
    kSettingPeekShiftClick : @YES,
    kSettingExternalLinksLittle : @YES,
    kSettingLittleArchiveHours : @6,
  }];
}

BOOL SettingBool(NSString* key) { return [NSUserDefaults.standardUserDefaults boolForKey:key]; }
double SettingDouble(NSString* key) { return [NSUserDefaults.standardUserDefaults doubleForKey:key]; }

static NSArray<NSArray<NSString*>*>* Engines() {
  return @[
    @[ @"google", @"Google", @"https://www.google.com/search?q=" ],
    @[ @"duckduckgo", @"DuckDuckGo", @"https://duckduckgo.com/?q=" ],
    @[ @"bing", @"Bing", @"https://www.bing.com/search?q=" ],
    @[ @"ecosia", @"Ecosia", @"https://www.ecosia.org/search?q=" ],
    @[ @"kagi", @"Kagi", @"https://kagi.com/search?q=" ],
  ];
}

NSString* SearchURLForQuery(NSString* q) {
  NSString* chosen = [NSUserDefaults.standardUserDefaults stringForKey:kSettingSearchEngine];
  for (NSArray<NSString*>* e in Engines())
    if ([e[0] isEqualToString:chosen]) return [e[2] stringByAppendingString:q];
  return [Engines()[0][2] stringByAppendingString:q];
}

// Archive intervals offered in Arc: 12 hours, 24 hours, 7 days, 30 days, never.
static NSArray* ArchiveChoices() {
  return @[ @[ @"After 6 hours", @6 ], @[ @"After 12 hours", @12 ], @[ @"After 24 hours", @24 ], @[ @"After 7 days", @(24 * 7) ],
            @[ @"After 30 days", @(24 * 30) ], @[ @"Never", @0 ] ];
}
static NSArray* LittleArchiveChoices() {
  return @[ @[ @"After 1 hour", @1 ], @[ @"After 6 hours", @6 ], @[ @"After 12 hours", @12 ],
            @[ @"After 24 hours", @24 ], @[ @"Never", @0 ] ];
}

@implementation SettingsWindowController {
  NSPopUpButton* _engine;
  NSPopUpButton* _archive;
  NSPopUpButton* _littleArchive;
  NSTextField* _folderLabel;
}

+ (instancetype)shared {
  static SettingsWindowController* shared;
  if (!shared) shared = [SettingsWindowController new];
  return shared;
}

- (NSPopUpButton*)popup:(NSArray*)choices key:(NSString*)key action:(SEL)action {
  NSPopUpButton* p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  double current = SettingDouble(key);
  for (NSArray* c in choices) {
    [p addItemWithTitle:c[0]];
    p.lastItem.representedObject = c[1];
    if (fabs([c[1] doubleValue] - current) < 0.01) [p selectItem:p.lastItem];
  }
  p.target = self;
  p.action = action;
  return p;
}

- (NSButton*)check:(NSString*)title key:(NSString*)key {
  NSButton* b = [NSButton checkboxWithTitle:title target:self action:@selector(toggled:)];
  b.identifier = key;
  b.state = SettingBool(key) ? NSControlStateValueOn : NSControlStateValueOff;
  return b;
}

- (NSTextField*)note:(NSString*)text {
  NSTextField* f = [NSTextField wrappingLabelWithString:text];
  f.font = [NSFont systemFontOfSize:11];
  f.textColor = NSColor.secondaryLabelColor;
  return f;
}

- (NSTextField*)heading:(NSString*)text {
  NSTextField* f = [NSTextField labelWithString:text];
  f.font = [NSFont boldSystemFontOfSize:13];
  return f;
}

- (instancetype)init {
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 480)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  w.title = @"Settings";
  w.releasedWhenClosed = NO;
  self = [super initWithWindow:w];
  if (!self) return nil;

  _engine = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  NSString* chosen = [NSUserDefaults.standardUserDefaults stringForKey:kSettingSearchEngine];
  for (NSArray<NSString*>* e in Engines()) {
    [_engine addItemWithTitle:e[1]];
    _engine.lastItem.representedObject = e[0];
    if ([e[0] isEqualToString:chosen]) [_engine selectItem:_engine.lastItem];
  }
  _engine.target = self;
  _engine.action = @selector(engineChanged:);
  _archive = [self popup:ArchiveChoices() key:kSettingAutoArchiveHours action:@selector(archiveChanged:)];
  _littleArchive = [self popup:LittleArchiveChoices() key:kSettingLittleArchiveHours
                        action:@selector(littleArchiveChanged:)];

  NSGridView* general = [NSGridView gridViewWithViews:@[
    @[ [NSTextField labelWithString:@"Search engine:"], _engine ],
    @[ [NSTextField labelWithString:@"Archive Today tabs:"], _archive ],
  ]];
  [general columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

  NSGridView* little = [NSGridView gridViewWithViews:@[
    @[ [NSTextField labelWithString:@"Archive Little Windows:"], _littleArchive ],
  ]];

  [DownloadManager shared];  // registers the folder default
  _folderLabel = [NSTextField labelWithString:[NSUserDefaults.standardUserDefaults stringForKey:kSettingDownloadFolder]
                                                  .stringByAbbreviatingWithTildeInPath ?: @""];
  _folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [_folderLabel.widthAnchor constraintLessThanOrEqualToConstant:260].active = YES;
  NSButton* choose = [NSButton buttonWithTitle:@"Change..." target:self action:@selector(chooseFolder:)];
  NSGridView* downloads = [NSGridView gridViewWithViews:@[ @[ [NSTextField labelWithString:@"Download location:"], _folderLabel, choose ] ]];

  NSStackView* stack = [NSStackView stackViewWithViews:@[
    [self heading:@"General"],
    general,
    [self note:@"Pinned tabs and Favorites are never archived. Archived tabs stay searchable in the Archive (Cmd+Y)."],
    [self heading:@"Links"],
    [self check:@"Open a Peek window when clicking on links to other sites" key:kSettingPeekPinnedLinks],
    [self note:@"Only affects Pinned tabs and Favorites."],
    [self check:@"Open a Peek window when clicking on links with Shift held" key:kSettingPeekShiftClick],
    [self check:@"Links from other apps open in a Little Window" key:kSettingExternalLinksLittle],
    [self note:@"When off, links from other apps open as a new tab in Today."],
    little,
    [self heading:@"Downloads"],
    downloads,
  ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 10;
  stack.edgeInsets = NSEdgeInsetsMake(20, 24, 20, 24);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [w.contentView addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:w.contentView.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:w.contentView.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:w.contentView.topAnchor],
    [stack.bottomAnchor constraintLessThanOrEqualToAnchor:w.contentView.bottomAnchor],
  ]];
  for (NSView* v in stack.views)
    if ([v isKindOfClass:NSTextField.class] && ((NSTextField*)v).cell.wraps)
      [v.widthAnchor constraintEqualToConstant:420].active = YES;
  [w center];
  return self;
}

- (void)chooseFolder:(id)sender {
  NSOpenPanel* panel = [NSOpenPanel openPanel];
  panel.canChooseDirectories = YES;
  panel.canChooseFiles = NO;
  panel.canCreateDirectories = YES;
  panel.prompt = @"Choose";
  if ([panel runModal] != NSModalResponseOK || !panel.URL) return;
  [NSUserDefaults.standardUserDefaults setObject:panel.URL.path forKey:kSettingDownloadFolder];
  _folderLabel.stringValue = panel.URL.path.stringByAbbreviatingWithTildeInPath;
}

- (void)toggled:(NSButton*)sender {
  [NSUserDefaults.standardUserDefaults setBool:sender.state == NSControlStateValueOn forKey:sender.identifier];
}
- (void)engineChanged:(NSPopUpButton*)sender {
  [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject forKey:kSettingSearchEngine];
}
- (void)archiveChanged:(NSPopUpButton*)sender {
  [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject forKey:kSettingAutoArchiveHours];
}
- (void)littleArchiveChanged:(NSPopUpButton*)sender {
  [NSUserDefaults.standardUserDefaults setObject:sender.selectedItem.representedObject
                                          forKey:kSettingLittleArchiveHours];
}
@end
