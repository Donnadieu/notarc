#import "app/settings.h"
#import "app/app_icons.h"
#import "app/downloads.h"
#import "app/main_window.h"
#import "app/arc_max.h"
#include "app/content_blocker.h"
#import "app/filter_lists.h"
#import "app/ad_blockers_window.h"

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
    kSettingTidyTitles : @YES,
    kSettingCalendar : @NO,
    kSettingTranslateOffer : @YES,
    kSettingLittleHotkey : @YES,
    kSettingLittleModifierClick : @YES,
    kSettingBlockAds : @NO,
    kSettingAdBlockBuiltIn : @YES,
    kSettingSoundEffects : @YES,
    kSettingReorderHaptics : @YES,
    kSettingShowSpaceHeader : @YES,
    kSettingSpaceAppearance : @"auto",
    kSettingDeveloperModeLocal : @YES,
    kSettingAppIcon : @"classic",
  }];
  [NSUserDefaults.standardUserDefaults registerDefaults:MaxDefaultSettings()];  // Settings > Max (#58, #59)
}

static NSMutableDictionary* g_memorySettings;
void SettingsUseMemoryOnly(void) { g_memorySettings = [NSMutableDictionary dictionary]; }
BOOL SettingsMemoryOnly(void) { return g_memorySettings != nil; }
// What a key reads as when it isn't set in memory. Memory-only (self-test) runs skip the user's saved preferences
// (read through cfprefsd even with CFFIXED_USER_HOME set, so a real "appIcon" or "defaultSpaceAppearance" made checks
// fail) and read only the argument domain (tests' volatile overrides) and the registered defaults.
static id FallbackObject(NSString* key) {
  NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
  if (!g_memorySettings) return [d objectForKey:key];
  return [d volatileDomainForName:NSArgumentDomain][key] ?: [d volatileDomainForName:NSRegistrationDomain][key];
}
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
  if (g_memorySettings) return [FallbackObject(key) respondsToSelector:@selector(boolValue)] && [FallbackObject(key) boolValue];
  return [NSUserDefaults.standardUserDefaults boolForKey:key];
}
double SettingDouble(NSString* key) {
  if (g_memorySettings) {
    id v = g_memorySettings[key] ?: FallbackObject(key);
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : 0;
  }
  return [NSUserDefaults.standardUserDefaults doubleForKey:key];
}
id SettingValueOrDefault(NSString* key) { return SettingObject(key) ?: FallbackObject(key); }

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
NSString* const kSettingTidyTitles = @"tidyTitles";
NSString* const kSettingCalendar = @"calendarNextMeeting";
NSString* const kSettingTranslateOffer = @"translateOffer";
NSString* const kSettingLittleHotkey = @"littleHotkey";
NSString* const kSettingLittleModifierClick = @"littleModifierClick";
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
  content_blocker::SetBuiltInEnabled(SettingBool(kSettingAdBlockBuiltIn));
  [FilterListManager.shared reloadRules];  // parses subscribed lists in the background (only when blocking is on)
  [FilterListManager.shared startDailyRefresh];
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

NSString* const kSettingSpaceAppearance = @"defaultSpaceAppearance";
NSString* const kSettingChromePages = @"chromePages";
NSString* const kSettingDeveloperModeLocal = @"developerModeLocalSites";
NSString* const kSettingDeveloperModeHosts = @"developerModeHosts";

// Memory-only runs keep only what they changed, so fall back to the registered defaults.
static id SettingValue(NSString* key) { return SettingValueOrDefault(key); }

NSString* DefaultSpaceAppearance(void) {
  id v = SettingValue(kSettingSpaceAppearance);
  return [v isEqual:@"light"] || [v isEqual:@"dark"] ? v : @"auto";
}

void SettingsDidChange(void) { [MainWindowController settingsDidChange]; }

#pragma mark Developer Mode (#68)

static NSString* DevHostKey(NSString* host) {
  NSString* h = host.lowercaseString;
  if ([h hasPrefix:@"["] && [h hasSuffix:@"]"] && h.length > 2) h = [h substringWithRange:NSMakeRange(1, h.length - 2)];
  if ([h hasSuffix:@"."]) h = [h substringToIndex:h.length - 1];
  if ([h hasPrefix:@"www."]) h = [h substringFromIndex:4];
  return h;
}

BOOL DeveloperModeIsLocalHost(NSString* host) {
  NSString* h = DevHostKey(host);
  if (!h.length) return NO;
  if ([h isEqualToString:@"localhost"] || [h hasSuffix:@".localhost"] || [h hasSuffix:@".local"]) return YES;
  if ([h isEqualToString:@"::1"] || [h isEqualToString:@"0.0.0.0"]) return YES;
  NSArray* parts = [h componentsSeparatedByString:@"."];
  if (parts.count != 4 || ![parts[0] isEqualToString:@"127"]) return NO;
  NSCharacterSet* nonDigits = NSCharacterSet.decimalDigitCharacterSet.invertedSet;
  for (NSString* p in parts)
    if (!p.length || [p rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;
  return YES;
}

static NSDictionary* DevHosts() {
  id d = SettingValue(kSettingDeveloperModeHosts);
  return [d isKindOfClass:NSDictionary.class] ? d : @{};
}

static BOOL DevDefaultFor(NSString* h) { return SettingBool(kSettingDeveloperModeLocal) && DeveloperModeIsLocalHost(h); }

BOOL DeveloperModeOnForHost(NSString* host) {
  NSString* h = DevHostKey(host);
  if (!h.length) return NO;
  NSNumber* v = DevHosts()[h];
  if ([v isKindOfClass:NSNumber.class]) return v.boolValue;
  return DevDefaultFor(h);
}

BOOL DeveloperModeOnForURL(NSString* url) {
  NSURL* u = url.length ? [NSURL URLWithString:url] : nil;
  if (!([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"])) return NO;
  return DeveloperModeOnForHost(u.host);
}

void SetDeveloperMode(BOOL on, NSString* host) {
  NSString* h = DevHostKey(host);
  if (!h.length) return;
  NSMutableDictionary* d = [DevHosts() mutableCopy];
  if (on == DevDefaultFor(h)) [d removeObjectForKey:h];  // keep only choices that differ from the default
  else d[h] = @(on);
  SettingSetObject(kSettingDeveloperModeHosts, d);
  SettingsDidChange();
}

NSArray<NSString*>* DeveloperModeChosenHosts(void) {
  NSMutableArray* out = [NSMutableArray array];
  [DevHosts() enumerateKeysAndObjectsUsingBlock:^(NSString* k, NSNumber* v, BOOL*) {
    if ([v isKindOfClass:NSNumber.class] && v.boolValue) [out addObject:k];
  }];
  return [out sortedArrayUsingSelector:@selector(compare:)];
}

void ResetDeveloperModeHosts(void) {
  SettingSetObject(kSettingDeveloperModeHosts, @{});
  SettingsDidChange();
}

NSString* SidebarAddressTextForURL(NSString* url) {
  if (DeveloperModeOnForURL(url)) {
    // The whole address with its port; the scheme is left out so host:port stays visible in the narrow pill.
    NSRange r = [url rangeOfString:@"://"];
    return r.location == NSNotFound ? url : [url substringFromIndex:NSMaxRange(r)];
  }
  NSString* host = [NSURL URLWithString:url].host ?: url;
  if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
  return host;
}

#pragma mark Reset settings

static NSArray<NSString*>* ResettableKeys() {
  return @[
    kSettingAutoArchiveHours, kSettingSearchEngine, kSettingPeekPinnedLinks, kSettingPeekShiftClick,
    kSettingExternalLinksLittle, kSettingLittleArchiveHours, kSettingShowToolbar, kSettingAutoPiP,
    kSettingSearchSuggestions, kSettingBlockAds, kSettingSoundEffects, kSettingReorderHaptics, kSettingShowSpaceHeader,
    kSettingDownloadFolder, kSettingChromePages, kSettingSpaceAppearance, kSettingAppIcon, kSettingDeveloperModeLocal,
    kSettingDeveloperModeHosts,
  ];
}

void ResetAllSettings(void) {
  for (NSString* k in ResettableKeys()) {
    if (g_memorySettings) [g_memorySettings removeObjectForKey:k];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:k];
  }
  ApplyContentBlockerSettings();
  ApplyAppIcon();
  SettingsDidChange();
}

NSDictionary* SettingsMemorySnapshotForTest(void) { return [g_memorySettings copy]; }
void SettingsMemoryRestoreForTest(NSDictionary* snapshot) {
  if (g_memorySettings) g_memorySettings = [snapshot mutableCopy] ?: [NSMutableDictionary dictionary];
}

#pragma mark Settings window

// Archive intervals offered in Arc: 12 hours, 24 hours, 7 days, 30 days, never.
static NSArray* ArchiveChoices() {
  return @[ @[ @"After 6 hours", @6 ], @[ @"After 12 hours", @12 ], @[ @"After 24 hours", @24 ], @[ @"After 7 days", @(24 * 7) ],
            @[ @"After 30 days", @(24 * 30) ], @[ @"Never", @0 ] ];
}
static NSArray* LittleArchiveChoices() {
  return @[ @[ @"After 1 hour", @1 ], @[ @"After 6 hours", @6 ], @[ @"After 12 hours", @12 ],
            @[ @"After 24 hours", @24 ], @[ @"Never", @0 ] ];
}

static const CGFloat kPaneWidth = 540;

@interface SettingsWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate>
@end

@implementation SettingsWindowController {
  NSTabViewController* _tabs;
  NSPopUpButton* _engine;
  NSPopUpButton* _archive;
  NSPopUpButton* _littleArchive;
  NSPopUpButton* _appearance;
  NSTextField* _folderLabel;
  NSTextField* _defaultLabel;
  NSButton* _defaultButton;
  NSTableView* _profileTable;
  NSArray<NSString*>* _profileDirs;
  NSMutableDictionary<NSString*, NSView*>* _iconTiles;  // icon name -> tile (its layer border marks the choice)
  NSMutableDictionary<NSString*, NSButton*>* _checks;   // setting key -> checkbox
  NSTextField* _devSites;
}

+ (instancetype)shared {
  static SettingsWindowController* shared;
  if (!shared) shared = [SettingsWindowController new];
  return shared;
}

static MainWindowController* Browser() { return [MainWindowController mainController]; }

#pragma mark Building blocks

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
  _checks[key] = b;
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

- (NSStackView*)row:(NSArray<NSView*>*)views {
  NSStackView* row = [NSStackView stackViewWithViews:views];
  row.spacing = 10;
  return row;
}

// A pane: views stacked top to bottom, left aligned, a fixed width so every pane lines up.
- (NSView*)pane:(NSArray<NSView*>*)views {
  NSStackView* stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 10;
  stack.edgeInsets = NSEdgeInsetsMake(20, 28, 24, 28);
  for (NSView* v in stack.views) {
    if ([v isKindOfClass:NSTextField.class] && ((NSTextField*)v).cell.wraps)
      [v.widthAnchor constraintEqualToConstant:kPaneWidth - 56].active = YES;
  }
  [stack.widthAnchor constraintEqualToConstant:kPaneWidth].active = YES;
  return stack;
}

- (void)addPane:(NSString*)identifier title:(NSString*)title symbol:(NSString*)sfSymbol view:(NSView*)view {
  NSViewController* vc = [NSViewController new];
  vc.view = view;
  vc.title = title;
  [view layoutSubtreeIfNeeded];
  vc.preferredContentSize = view.fittingSize;
  NSTabViewItem* item = [NSTabViewItem tabViewItemWithViewController:vc];
  item.identifier = identifier;
  item.label = title;
  item.image = [NSImage imageWithSystemSymbolName:sfSymbol accessibilityDescription:title];
  [_tabs addTabViewItem:item];
}

// The panes, in toolbar order (Arc: General, Profiles, Links, Max, Advanced, plus its App Icon pane, which NotArc
// folds into Appearance). To add a pane, add one line here; the Max pane goes between Links and Advanced.
- (void)buildPanes {
  _checks = [NSMutableDictionary dictionary];
  [self addPane:@"general" title:@"General" symbol:@"gearshape" view:[self generalPane]];
  [self addPane:@"profiles" title:@"Profiles" symbol:@"person.2" view:[self profilesPane]];
  [self addPane:@"appearance" title:@"Appearance" symbol:@"paintpalette" view:[self appearancePane]];
  [self addPane:@"links" title:@"Links" symbol:@"link" view:[self linksPane]];
  [self addPane:@"max" title:@"Max" symbol:@"sparkles" view:[self pane:@[ MaxSettingsSection() ]]];  // #58, #59
  [self addPane:@"advanced" title:@"Advanced" symbol:@"gearshape.2" view:[self advancedPane]];
}

- (instancetype)init {
  NSTabViewController* tabs = [NSTabViewController new];
  tabs.tabStyle = NSTabViewControllerTabStyleToolbar;
  tabs.transitionOptions = NSViewControllerTransitionCrossfade | NSViewControllerTransitionAllowUserInteraction;
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, kPaneWidth, 400)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered
                                                defer:YES];
  w.toolbarStyle = NSWindowToolbarStylePreference;
  w.releasedWhenClosed = NO;
  self = [super initWithWindow:w];
  if (!self) return nil;
  _tabs = tabs;
  w.delegate = self;  // refresh the default-browser line and the profile list whenever Settings comes forward
  [DownloadManager shared];  // registers the folder default
  [self buildPanes];
  w.contentViewController = tabs;  // after the panes exist, so the toolbar is built with all of them
  [w center];
  return self;
}

- (void)windowDidBecomeKey:(NSNotification*)n {
  [self refreshDefaultBrowser];
  [self refreshProfiles];
  [self refreshDeveloperSites];
}

- (NSArray<NSString*>*)paneIdentifiers {
  NSMutableArray* out = [NSMutableArray array];
  for (NSTabViewItem* i in _tabs.tabViewItems) [out addObject:i.identifier];
  return out;
}

- (NSTabViewItem*)paneItem:(NSString*)identifier {
  for (NSTabViewItem* i in _tabs.tabViewItems)
    if ([i.identifier isEqual:identifier]) return i;
  return nil;
}

- (void)selectPane:(NSString*)identifier {
  NSTabViewItem* item = [self paneItem:identifier];
  if (item) _tabs.selectedTabViewItemIndex = [_tabs.tabViewItems indexOfObject:item];
}

- (NSString*)selectedPane {
  NSInteger i = _tabs.selectedTabViewItemIndex;
  return i >= 0 && i < (NSInteger)_tabs.tabViewItems.count ? _tabs.tabViewItems[i].identifier : nil;
}

- (NSView*)viewOfPane:(NSString*)identifier { return [self paneItem:identifier].viewController.view; }

- (BOOL)writePaneSnapshotsTo:(NSString*)folder {
  BOOL ok = YES;
  for (NSTabViewItem* item in _tabs.tabViewItems) {
    NSView* v = item.viewController.view;
    v.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    [v setFrameSize:v.fittingSize];
    [v layoutSubtreeIfNeeded];
    NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    NSString* path = [folder stringByAppendingPathComponent:[item.identifier stringByAppendingString:@".png"]];
    ok = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES] && ok;
    v.appearance = nil;
  }
  return ok;
}

#pragma mark General

// Default Browser (#69): shows which app opens links now, and a button that asks macOS to make it NotArc.
- (NSView*)defaultBrowserRow {
  _defaultLabel = [NSTextField labelWithString:@""];
  _defaultButton = [NSButton buttonWithTitle:@"Make NotArc Default Browser" target:self action:@selector(makeDefault:)];
  [self refreshDefaultBrowser];
  return [self row:@[ _defaultLabel, _defaultButton ]];
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

- (BOOL)hasCheckboxForKey:(NSString*)key { return [self checkboxForSetting:key] != nil; }  // tests

- (NSView*)generalPane {
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

  NSGridView* general = [NSGridView gridViewWithViews:@[
    @[ [NSTextField labelWithString:@"Search engine:"], _engine ],
    @[ NSGridCell.emptyContentView, [self check:@"Show search suggestions in the command bar" key:kSettingSearchSuggestions] ],
    @[ NSGridCell.emptyContentView, [self check:@"Tidy tab titles when pinning" key:kSettingTidyTitles] ],
    @[ NSGridCell.emptyContentView, [self check:@"Show my next meeting from Calendar in the sidebar" key:kSettingCalendar] ],
    @[ NSGridCell.emptyContentView, [self check:@"Offer to translate pages in other languages" key:kSettingTranslateOffer] ],
    @[ NSGridCell.emptyContentView, [NSStackView stackViewWithViews:@[
         [self check:@"Block ads & trackers" key:kSettingBlockAds],
         [NSButton buttonWithTitle:@"Manage Ad Blockers..." target:self action:@selector(showManageAdBlockers:)] ]] ],
    @[ [NSTextField labelWithString:@"Archive Today tabs:"], _archive ],
  ]];
  [general columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;

  _folderLabel = [NSTextField labelWithString:[NSUserDefaults.standardUserDefaults stringForKey:kSettingDownloadFolder]
                                                  .stringByAbbreviatingWithTildeInPath ?: @""];
  _folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  [_folderLabel.widthAnchor constraintLessThanOrEqualToConstant:280].active = YES;
  NSButton* choose = [NSButton buttonWithTitle:@"Change..." target:self action:@selector(chooseFolder:)];

  return [self pane:@[
    general,
    [self note:@"Pinned tabs, Favorites and sites in Developer Mode are never archived. Archived tabs stay searchable in the Archive (Cmd+Y)."],
    [self heading:@"Default Browser"],
    [self defaultBrowserRow],
    [self heading:@"Media & Feedback"],
    [self check:@"Automatically open picture-in-picture when leaving a tab with a playing video" key:kSettingAutoPiP],
    [self check:@"Play sound effects" key:kSettingSoundEffects],
    [self check:@"Haptic feedback when reordering tabs" key:kSettingReorderHaptics],
    [self heading:@"Downloads"],
    [self row:@[ [NSTextField labelWithString:@"Download location:"], _folderLabel, choose ]],
  ]];
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

- (void)showManageAdBlockers:(id)sender { [ManageAdBlockersWindowController.shared showWindow:sender]; }

- (void)toggled:(NSButton*)sender {
  SettingSetBool(sender.identifier, sender.state == NSControlStateValueOn);
  if ([sender.identifier isEqualToString:kSettingBlockAds]) {
    ApplyContentBlockerSettings();
    [NSNotificationCenter.defaultCenter postNotificationName:FilterListsDidChangeNotification object:nil];
  }
  if ([sender.identifier isEqualToString:kSettingDeveloperModeLocal]) SettingsDidChange();
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

#pragma mark Profiles

- (NSView*)profilesPane {
  _profileTable = [NSTableView new];
  for (NSArray* c in @[ @[ @"name", @"Profile", @170 ], @[ @"spaces", @"Spaces", @290 ] ]) {
    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1];
    col.width = [c[2] doubleValue];
    [_profileTable addTableColumn:col];
  }
  _profileTable.usesAlternatingRowBackgroundColors = YES;
  _profileTable.rowHeight = 22;
  _profileTable.dataSource = self;
  _profileTable.delegate = self;
  _profileTable.target = self;
  _profileTable.doubleAction = @selector(renameProfile:);
  NSScrollView* scroll = [NSScrollView new];
  scroll.documentView = _profileTable;
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;
  [scroll.widthAnchor constraintEqualToConstant:kPaneWidth - 56].active = YES;
  [scroll.heightAnchor constraintEqualToConstant:190].active = YES;
  [self refreshProfiles];
  return [self pane:@[
    [self heading:@"Profiles"],
    [self note:@"Each Space belongs to a profile, with its own logins, history and Favorites. To move a Space to "
               @"another profile, use its menu (Space name > Profile)."],
    scroll,
    [self row:@[ [NSButton buttonWithTitle:@"New Profile..." target:self action:@selector(newProfile:)],
                 [NSButton buttonWithTitle:@"Rename..." target:self action:@selector(renameProfile:)] ]],
  ]];
}

- (void)refreshProfiles {
  _profileDirs = [Browser() profileDirectories] ?: @[];
  [_profileTable reloadData];
}

- (NSString*)spacesOfProfile:(NSString*)dir {
  NSMutableArray* names = [NSMutableArray array];
  for (ArcSpace* s in [Browser() spaces])
    if ([s.profileDirectory isEqualToString:dir]) [names addObject:s.title.length ? s.title : @"Space"];
  return names.count ? [names componentsJoinedByString:@", "] : @"No Spaces";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv { return _profileDirs.count; }

- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  NSString* dir = _profileDirs[row];
  BOOL name = [col.identifier isEqualToString:@"name"];
  NSTextField* f = [NSTextField labelWithString:name ? [Browser() nameOfProfile:dir] : [self spacesOfProfile:dir]];
  f.lineBreakMode = NSLineBreakByTruncatingTail;
  if (!name) f.textColor = NSColor.secondaryLabelColor;
  return f;
}

- (NSArray<NSString*>*)profileRows {
  [self refreshProfiles];
  NSMutableArray* out = [NSMutableArray array];
  for (NSString* dir in _profileDirs)
    [out addObject:[NSString stringWithFormat:@"%@: %@", [Browser() nameOfProfile:dir], [self spacesOfProfile:dir]]];
  return out;
}

- (NSString*)askForName:(NSString*)title initial:(NSString*)initial {
  NSAlert* a = [NSAlert new];
  a.messageText = title;
  NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  field.stringValue = initial ?: @"";
  a.accessoryView = field;
  [a addButtonWithTitle:@"OK"];
  [a addButtonWithTitle:@"Cancel"];
  a.window.initialFirstResponder = field;
  if ([a runModal] != NSAlertFirstButtonReturn) return nil;
  return [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (NSString*)createProfileNamed:(NSString*)name {
  if (!name.length || !Browser()) return nil;
  NSString* dir = [Browser() createProfileNamed:name];
  [self refreshProfiles];
  NSUInteger row = [_profileDirs indexOfObject:dir];
  if (row != NSNotFound) [_profileTable selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  return dir;
}

- (BOOL)renameProfileAtRow:(NSInteger)row to:(NSString*)name {
  if (row < 0 || row >= (NSInteger)_profileDirs.count || !name.length) return NO;
  [Browser() renameProfile:_profileDirs[row] to:name];
  [self refreshProfiles];
  return YES;
}

- (IBAction)newProfile:(id)sender {
  NSString* name = [self askForName:@"New Profile" initial:@""];
  if (name.length) [self createProfileNamed:name];
}

- (IBAction)renameProfile:(id)sender {
  NSInteger row = _profileTable.clickedRow >= 0 ? _profileTable.clickedRow : _profileTable.selectedRow;
  if (row < 0 || row >= (NSInteger)_profileDirs.count) {
    NSBeep();
    return;
  }
  NSString* name = [self askForName:@"Rename Profile" initial:[Browser() nameOfProfile:_profileDirs[row]]];
  if (name.length) [self renameProfileAtRow:row to:name];
}

#pragma mark Appearance

- (NSView*)iconTile:(NSString*)name {
  NSButton* b = [NSButton buttonWithImage:AppIconImage(name) target:self action:@selector(iconClicked:)];
  b.identifier = name;
  b.bordered = NO;
  b.imageScaling = NSImageScaleProportionallyUpOrDown;
  b.toolTip = AppIconTitle(name);
  [b.widthAnchor constraintEqualToConstant:64].active = YES;
  [b.heightAnchor constraintEqualToConstant:64].active = YES;
  NSTextField* label = [NSTextField labelWithString:AppIconTitle(name)];
  label.font = [NSFont systemFontOfSize:11];
  NSStackView* tile = [NSStackView stackViewWithViews:@[ b, label ]];
  tile.orientation = NSUserInterfaceLayoutOrientationVertical;
  tile.spacing = 4;
  tile.edgeInsets = NSEdgeInsetsMake(6, 6, 6, 6);
  tile.wantsLayer = YES;
  tile.layer.cornerRadius = 10;
  _iconTiles[name] = tile;
  return tile;
}

- (void)refreshIconTiles {
  NSString* current = CurrentAppIconName();
  [_iconTiles enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSView* tile, BOOL*) {
    BOOL on = [name isEqualToString:current];
    tile.layer.borderWidth = on ? 2 : 0;
    tile.layer.borderColor = NSColor.controlAccentColor.CGColor;
    tile.layer.backgroundColor = on ? [NSColor.controlAccentColor colorWithAlphaComponent:0.12].CGColor : nil;
  }];
}

- (NSView*)appearancePane {
  _appearance = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  for (NSArray* o in @[ @[ @"Automatic (follows macOS)", @"auto" ], @[ @"Light", @"light" ], @[ @"Dark", @"dark" ] ]) {
    [_appearance addItemWithTitle:o[0]];
    _appearance.lastItem.representedObject = o[1];
  }
  [_appearance selectItemAtIndex:[@[ @"auto", @"light", @"dark" ] indexOfObject:DefaultSpaceAppearance()]];
  _appearance.target = self;
  _appearance.action = @selector(appearanceChosen:);

  _iconTiles = [NSMutableDictionary dictionary];
  NSMutableArray* tiles = [NSMutableArray array];
  for (NSString* name in AppIconNames()) [tiles addObject:[self iconTile:name]];
  NSStackView* icons = [NSStackView stackViewWithViews:tiles];
  icons.spacing = 6;
  [self refreshIconTiles];

  return [self pane:@[
    [self heading:@"Spaces"],
    [self row:@[ [NSTextField labelWithString:@"Appearance:"], _appearance ]],
    [self note:@"For every Space that uses the default. A Space can pick its own in its menu (Space name > Appearance)."],
    [self heading:@"App Icon"],
    icons,
    [self note:@"Shown in the Dock while NotArc is open. Finder keeps the standard icon."],
  ]];
}

- (void)appearanceChosen:(NSPopUpButton*)sender { [self chooseSpaceAppearance:sender.selectedItem.representedObject]; }

- (void)chooseSpaceAppearance:(NSString*)scheme {
  NSString* s = [scheme isEqual:@"light"] || [scheme isEqual:@"dark"] ? scheme : @"auto";
  SettingSetObject(kSettingSpaceAppearance, s);
  [_appearance selectItemAtIndex:[@[ @"auto", @"light", @"dark" ] indexOfObject:s]];
  SettingsDidChange();
}

- (void)iconClicked:(NSButton*)sender { [self chooseAppIcon:sender.identifier]; }

- (void)chooseAppIcon:(NSString*)name {
  if (!AppIconImage(name)) return;
  SettingSetObject(kSettingAppIcon, name);
  ApplyAppIcon();
  [self refreshIconTiles];
}

- (NSString*)appIconShownAsChosen {
  __block NSString* out = nil;
  [_iconTiles enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSView* tile, BOOL*) {
    if (tile.layer.borderWidth > 0) out = name;
  }];
  return out;
}

#pragma mark Links

- (NSView*)linksPane {
  _littleArchive = [self popup:LittleArchiveChoices() key:kSettingLittleArchiveHours action:@selector(littleArchiveChanged:)];
  return [self pane:@[
    [self heading:@"Peek"],
    [self check:@"Open a Peek window when clicking on links to other sites" key:kSettingPeekPinnedLinks],
    [self note:@"Only affects Pinned tabs and Favorites."],
    [self check:@"Open a Peek window when clicking on links with Shift held" key:kSettingPeekShiftClick],
    [self heading:@"Little Window"],
    [self check:@"Open a Little Window when clicking on links with \u2325\u2318 held" key:kSettingLittleModifierClick],
    [self check:@"Open a Little Window when I press \u2325\u2318N in any app" key:kSettingLittleHotkey],
    [self heading:@"Links from Other Apps"],
    [NSButton buttonWithTitle:@"Air Traffic Control..." target:nil action:@selector(showAirTrafficControl:)],
    [self note:@"Rules that send links from other apps to a Space or a Little Window. Your Arc rules come over on first launch."],
    [self row:@[ [NSTextField labelWithString:@"Archive Little Windows:"], _littleArchive ]],
  ]];
}

#pragma mark Advanced

- (NSView*)advancedPane {
  _devSites = [self note:@""];
  [self refreshDeveloperSites];
  return [self pane:@[
    [self heading:@"Pages"],
    [self check:@"Chrome-style pages (extensions, password manager, autofill)" key:kSettingChromePages],
    [self note:@"Takes effect the next time NotArc starts."],
    [self heading:@"Developer Mode"],
    [self check:@"Turn on Developer Mode for localhost, 127.0.0.1 and .local sites" key:kSettingDeveloperModeLocal],
    [self note:@"Developer Mode shows a site's full address with its port in the sidebar, keeps its tabs from being "
               @"archived and adds Developer Tools to the address pill. Turn it on for any site with View > Turn On "
               @"Developer Mode for This Site, or in Site Settings."],
    _devSites,
    [NSButton buttonWithTitle:@"Reset Developer Mode Sites" target:self action:@selector(resetDeveloperModeSites:)],
    [self heading:@"Browsing Data"],
    [NSButton buttonWithTitle:@"Clear Browsing Data..." target:self action:@selector(clearBrowsingData:)],
    [self heading:@"Reset"],
    [NSButton buttonWithTitle:@"Reset All Settings..." target:self action:@selector(resetAllSettings:)],
    [self note:@"Puts every setting in this window back to its default. Spaces, tabs, profiles, history and site "
               @"permissions are kept."],
  ]];
}

- (NSNumber*)checkboxForSetting:(NSString*)settingKey {
  NSButton* b = _checks[settingKey];
  return b ? @(b.state == NSControlStateValueOn) : nil;
}

- (void)refreshDeveloperSites {
  NSArray* hosts = DeveloperModeChosenHosts();
  _devSites.stringValue = hosts.count ? [@"Also on for: " stringByAppendingString:[hosts componentsJoinedByString:@", "]]
                                      : @"No other sites are in Developer Mode.";
}

- (NSString*)developerModeSitesText {
  [self refreshDeveloperSites];
  return _devSites.stringValue;
}

- (IBAction)resetDeveloperModeSites:(id)sender {
  ResetDeveloperModeHosts();
  [self refreshDeveloperSites];
}

- (IBAction)clearBrowsingData:(id)sender { [Browser() clearBrowsingData:sender]; }

- (IBAction)resetAllSettings:(id)sender {
  NSAlert* a = [NSAlert new];
  a.messageText = @"Reset all settings?";
  a.informativeText = @"Every setting goes back to its default. Your Spaces, tabs, profiles, history and site permissions are kept.";
  [a addButtonWithTitle:@"Reset"];
  [a addButtonWithTitle:@"Cancel"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  ResetAllSettings();
  [self rebuildPanes];
}

// Rebuilds every pane from the current settings, staying on the same pane.
- (void)rebuildPanes {
  NSString* shown = [self selectedPane];
  for (NSTabViewItem* i in [_tabs.tabViewItems copy]) [_tabs removeTabViewItem:i];
  [self buildPanes];
  if (shown) [self selectPane:shown];
}
@end

NSString* TranslateOfferFor(NSString* pageLang, NSArray<NSString*>* preferredLanguages) {
  NSString* (^primary)(NSString*) = ^NSString*(NSString* l) {
    return [[l.lowercaseString stringByReplacingOccurrencesOfString:@"_" withString:@"-"] componentsSeparatedByString:@"-"].firstObject;
  };
  NSString* page = primary([pageLang stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] ?: @"");
  if (page.length < 2 || page.length > 3 || [page isEqualToString:@"und"] || [page isEqualToString:@"mul"]) return nil;
  for (NSString* l in preferredLanguages)
    if ([primary(l) isEqualToString:page]) return nil;
  return page;
}
