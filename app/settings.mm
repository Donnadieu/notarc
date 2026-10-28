#import "app/settings.h"
#import "app/downloads.h"
#include "app/content_blocker.h"

NSString* const kSettingAutoArchiveHours = @"autoArchiveThresholdHours";
NSString* const kSettingSearchEngine = @"searchEngine";
NSString* const kSettingPeekPinnedLinks = @"peekPinnedLinks";
NSString* const kSettingPeekShiftClick = @"peekShiftClick";
NSString* const kSettingExternalLinksLittle = @"externalLinksOpenInLittleWindow";
NSString* const kSettingLittleArchiveHours = @"littleWindowArchiveHours";
NSString* const kSettingShowToolbar = @"showToolbar";
NSString* const kSettingAutoPiP = @"autoPictureInPicture";
NSString* const kSettingCommandPicks = @"commandBarPicks";
NSString* const kSettingSitePermissions = @"sitePermissions";
NSString* const kSettingShowSpaceHeader = @"showSpaceHeader";

void SettingsRegisterDefaults(void) {
  [NSUserDefaults.standardUserDefaults registerDefaults:@{
    kSettingAutoArchiveHours : @12,
    kSettingSearchEngine : @"google",
    kSettingPeekPinnedLinks : @YES,
    kSettingPeekShiftClick : @YES,
    kSettingExternalLinksLittle : @YES,
    kSettingLittleArchiveHours : @6,
    kSettingShowToolbar : @NO,
    kSettingAutoPiP : @YES,
    kSettingSearchSuggestions : @YES,
    kSettingBlockAds : @NO,
    kSettingSoundEffects : @YES,
    kSettingReorderHaptics : @YES,
    kSettingShowSpaceHeader : @YES,
  }];
}

static NSMutableDictionary* g_memorySettings;
void SettingsUseMemoryOnly(void) { g_memorySettings = [NSMutableDictionary dictionary]; }
void SettingSetBool(NSString* key, BOOL value) {
  if (g_memorySettings) g_memorySettings[key] = @(value);
  else [NSUserDefaults.standardUserDefaults setBool:value forKey:key];
}
id SettingObject(NSString* key) {
  if (g_memorySettings) return g_memorySettings[key];
  return [NSUserDefaults.standardUserDefaults objectForKey:key];
}
void SettingSetObject(NSString* key, id value) {
  if (g_memorySettings) g_memorySettings[key] = value;
  else [NSUserDefaults.standardUserDefaults setObject:value forKey:key];
}
BOOL SettingBool(NSString* key) {
  if (NSNumber* v = g_memorySettings[key]) return v.boolValue;
  return [NSUserDefaults.standardUserDefaults boolForKey:key];
}
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

NSString* const kSettingSearchSuggestions = @"searchSuggestions";
NSString* const kSettingBlockAds = @"blockAdsAndTrackers";
NSString* const kSettingSoundEffects = @"soundEffects";
NSString* const kSettingReorderHaptics = @"reorderHaptics";

static NSInteger g_soundsPlayed = 0, g_haptics = 0;

BOOL PlaySoundEffect(NotArcSound sound) {
  if (!SettingBool(kSettingSoundEffects)) return NO;
  if (g_memorySettings) {  // self-test: never make noise
    ++g_soundsPlayed;
    return YES;
  }
  static NSSound* capture;
  if (!capture) {
    NSString* sys = @"/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/";
    capture = [[NSSound alloc] initWithContentsOfFile:[sys stringByAppendingString:@"Screen Capture.aif"] byReference:YES]
                  ?: [NSSound soundNamed:@"Tink"];
  }
  NSSound* s = sound == NotArcSoundCapture ? capture : nil;
  [s stop];
  [s play];
  return YES;
}
NSInteger SoundEffectsPlayedForTest(void) { return g_soundsPlayed; }

void ReorderHaptic(void) {
  if (!SettingBool(kSettingReorderHaptics)) return;
  ++g_haptics;
  if (g_memorySettings) return;
  [NSHapticFeedbackManager.defaultPerformer performFeedbackPattern:NSHapticFeedbackPatternAlignment
                                                   performanceTime:NSHapticFeedbackPerformanceTimeNow];
}
NSInteger ReorderHapticsForTest(void) { return g_haptics; }
NSString* const kSettingAdBlockExceptions = @"adBlockExceptions";

void ApplyContentBlockerSettings(void) {
  content_blocker::SetEnabled(SettingBool(kSettingBlockAds));
  std::vector<std::string> hosts;
  for (id h in SettingObject(kSettingAdBlockExceptions))
    if ([h isKindOfClass:NSString.class]) hosts.push_back(((NSString*)h).UTF8String);
  content_blocker::SetExceptions(hosts);
}

NSURL* DefaultBrowserAppURL(void) {
  return [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:[NSURL URLWithString:@"https://example.com"]];
}

BOOL NotArcIsDefaultBrowser(void) {
  NSURL* app = DefaultBrowserAppURL();
  if (!app) return NO;
  NSString* bid = [NSBundle bundleWithURL:app].bundleIdentifier;
  return [bid isEqualToString:NSBundle.mainBundle.bundleIdentifier];
}

void MakeNotArcDefaultBrowser(void (^done)(BOOL ok)) {
  NSURL* me = NSBundle.mainBundle.bundleURL;
  NSWorkspace* ws = NSWorkspace.sharedWorkspace;
  // http first; macOS asks once and applies the choice to https too.
  [ws setDefaultApplicationAtURL:me toOpenURLsWithScheme:@"http" completionHandler:^(NSError* e1) {
    [NSWorkspace.sharedWorkspace setDefaultApplicationAtURL:me toOpenURLsWithScheme:@"https" completionHandler:^(NSError* e2) {
      dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(!e1 && !e2 && NotArcIsDefaultBrowser()); });
    }];
  }];
}

// Translate page (#52): Arc used Chromium's translate bubble, which isn't in CEF. NotArc opens the page through
// Google's page translator into your language; "Show Original" goes back to the page itself.
NSString* TranslateURLFor(NSString* url, NSString* lang) {
  NSURL* u = [NSURL URLWithString:url];
  if (!u.host.length || !([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"])) return nil;
  if (OriginalURLForTranslated(url)) return nil;  // already translated
  NSString* tl = lang.length ? lang : @"en";
  NSURLComponents* c = [NSURLComponents componentsWithString:@"https://translate.google.com/translate"];
  c.queryItems = @[ [NSURLQueryItem queryItemWithName:@"sl" value:@"auto"], [NSURLQueryItem queryItemWithName:@"tl" value:tl],
                    [NSURLQueryItem queryItemWithName:@"u" value:url] ];
  return c.URL.absoluteString;
}

NSString* OriginalURLForTranslated(NSString* url) {
  NSURLComponents* c = [NSURLComponents componentsWithString:url];
  if (!c.host) return nil;
  if ([c.host isEqualToString:@"translate.google.com"]) {
    for (NSURLQueryItem* q in c.queryItems)
      if ([q.name isEqualToString:@"u"] && q.value.length) return q.value;
    return nil;
  }
  // The translator serves pages from <host with dots as dashes>.translate.goog; map back to the real host.
  if ([c.host hasSuffix:@".translate.goog"]) {
    NSString* h = [c.host substringToIndex:c.host.length - @".translate.goog".length];
    h = [[h stringByReplacingOccurrencesOfString:@"--" withString:@"\x01"] stringByReplacingOccurrencesOfString:@"-" withString:@"."];
    h = [h stringByReplacingOccurrencesOfString:@"\x01" withString:@"-"];
    NSMutableArray* keep = [NSMutableArray array];
    for (NSURLQueryItem* q in c.queryItems)
      if (![q.name hasPrefix:@"_x_tr_"]) [keep addObject:q];
    c.host = h;
    c.queryItems = keep.count ? keep : nil;
    return c.URL.absoluteString;
  }
  return nil;
}

NSString* PreferredTranslateLanguage(void) {
  NSString* l = NSLocale.preferredLanguages.firstObject ?: @"en";
  if ([l hasPrefix:@"zh"]) return [l containsString:@"Hant"] || [l containsString:@"TW"] ? @"zh-TW" : @"zh-CN";
  return [l componentsSeparatedByString:@"-"].firstObject;
}

NSString* SuggestURLForQuery(NSString* q) {
  NSDictionary* urls = @{
    @"google" : @"https://suggestqueries.google.com/complete/search?client=firefox&q=",
    @"duckduckgo" : @"https://duckduckgo.com/ac/?type=list&q=",
    @"bing" : @"https://api.bing.com/osjson.aspx?query=",
    @"ecosia" : @"https://ac.ecosia.org/autocomplete?type=list&q=",
    @"kagi" : @"https://kagi.com/api/autosuggest?q=",
  };
  NSString* chosen = [NSUserDefaults.standardUserDefaults stringForKey:kSettingSearchEngine];
  return [(urls[chosen ?: @"google"] ?: urls[@"google"]) stringByAppendingString:q];
}

// ["query", ["s1", "s2", ...], ...] (OpenSearch); also accepts [{"phrase": ...}] lists.
NSArray<NSString*>* ParseSearchSuggestions(NSData* json) {
  if (!json.length) return @[];
  id o = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
  NSMutableArray* out = [NSMutableArray array];
  NSArray* list = nil;
  if ([o isKindOfClass:NSArray.class]) {
    NSArray* a = o;
    if (a.count >= 2 && [a[1] isKindOfClass:NSArray.class]) list = a[1];
    else list = a;
  }
  for (id x in list) {
    NSString* s = [x isKindOfClass:NSString.class] ? x
                : ([x isKindOfClass:NSDictionary.class] && [x[@"phrase"] isKindOfClass:NSString.class] ? x[@"phrase"] : nil);
    if (s.length && ![out containsObject:s]) [out addObject:s];
    if (out.count >= 5) break;
  }
  return out;
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
  NSTextField* _defaultLabel;
  NSButton* _defaultButton;
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

// Default Browser (#69): shows which app opens links now, and a button that asks macOS to make it NotArc.
- (NSView*)defaultBrowserRow {
  _defaultLabel = [NSTextField labelWithString:@""];
  _defaultButton = [NSButton buttonWithTitle:@"Make NotArc Default Browser" target:self action:@selector(makeDefault:)];
  [self refreshDefaultBrowser];
  NSStackView* row = [NSStackView stackViewWithViews:@[ _defaultLabel, _defaultButton ]];
  row.spacing = 12;
  return row;
}

- (void)refreshDefaultBrowser {
  BOOL mine = NotArcIsDefaultBrowser();
  NSURL* app = DefaultBrowserAppURL();
  NSString* name = app ? [NSFileManager.defaultManager displayNameAtPath:app.path].stringByDeletingPathExtension : @"another app";
  _defaultLabel.stringValue = mine ? @"NotArc is your default browser." : [NSString stringWithFormat:@"Links open in %@.", name];
  _defaultButton.hidden = mine;
}

- (void)makeDefault:(id)sender {
  __weak SettingsWindowController* weakSelf = self;
  MakeNotArcDefaultBrowser(^(BOOL ok) { [weakSelf refreshDefaultBrowser]; });
}

- (BOOL)defaultBrowserRowConsistent {  // tests
  if (!_defaultLabel) [self defaultBrowserRow];
  return _defaultButton.hidden == NotArcIsDefaultBrowser() && _defaultLabel.stringValue.length > 0;
}

- (void)windowDidBecomeKey:(NSNotification*)n { [self refreshDefaultBrowser]; }

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
  w.delegate = (id<NSWindowDelegate>)self;  // refresh the default-browser line whenever Settings comes forward

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
    @[ NSGridCell.emptyContentView, [self check:@"Show search suggestions in the command bar" key:kSettingSearchSuggestions] ],
    @[ NSGridCell.emptyContentView, [self check:@"Block ads & trackers" key:kSettingBlockAds] ],
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
    [self heading:@"Default Browser"],
    [self defaultBrowserRow],
    [self heading:@"Links"],
    [self check:@"Open a Peek window when clicking on links to other sites" key:kSettingPeekPinnedLinks],
    [self note:@"Only affects Pinned tabs and Favorites."],
    [self check:@"Open a Peek window when clicking on links with Shift held" key:kSettingPeekShiftClick],
    [self check:@"Automatically open picture-in-picture when leaving a tab with a playing video" key:kSettingAutoPiP],
    [self check:@"Play sound effects" key:kSettingSoundEffects],
    [self check:@"Haptic feedback when reordering tabs" key:kSettingReorderHaptics],
    [NSButton buttonWithTitle:@"Air Traffic Control..." target:nil action:@selector(showAirTrafficControl:)],
    [self note:@"Rules that send links from other apps to a Space or a Little Window. Your Arc rules come over on first launch."],
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
  if ([sender.identifier isEqualToString:kSettingBlockAds]) ApplyContentBlockerSettings();
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
