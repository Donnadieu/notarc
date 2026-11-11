#import "app/settings.h"
#import "app/arc_alert.h"
#import "app/app_icons.h"
#import "app/downloads.h"
#import "app/main_window.h"
#import "app/arc_max.h"
#include "app/content_blocker.h"
#import "app/filter_lists.h"
#import "app/ad_blockers_window.h"
#import "app/shortcuts.h"

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
    kSettingAppIcon : @"notarc",  // kAppIconBundle
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

// Visual parity V58: Arc's settings panes are grouped cards of rows (label at the left, switch or control at the
// right, inset hairlines between rows), small section titles above the cards, and flat rounded buttons in Arc's
// PreferencesButton colours. Drawn by NotArc; the values come from Arc 1.169's colour assets.
static BOOL PrefsDark(NSView* v) {
  return [[v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
      isEqualToString:NSAppearanceNameDarkAqua];
}

@interface SettingsCardView : NSView  // a rounded group of rows
@end
@implementation SettingsCardView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty {
  BOOL dark = PrefsDark(self);
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0.5, 0.5) xRadius:10 yRadius:10];
  [(dark ? [NSColor colorWithWhite:1 alpha:0.05] : [NSColor colorWithWhite:0 alpha:0.03]) setFill];
  [p fill];
  [(dark ? [NSColor colorWithWhite:1 alpha:0.08] : [NSColor colorWithWhite:0 alpha:0.08]) setStroke];
  p.lineWidth = 1;
  [p stroke];
}
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

@interface SettingsHairline : NSView
@end
@implementation SettingsHairline
- (void)drawRect:(NSRect)dirty {
  [(PrefsDark(self) ? [NSColor colorWithWhite:1 alpha:0.08] : [NSColor colorWithWhite:0 alpha:0.08]) setFill];
  NSRectFill(NSMakeRect(0, 0, NSWidth(self.bounds), 1));
}
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

@interface PrefsButton : NSButton  // Arc's flat settings button
@property(nonatomic) BOOL hovered;
@end
@implementation PrefsButton
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    self.bordered = NO;
    self.font = [NSFont systemFontOfSize:13];
  }
  return self;
}
- (NSSize)intrinsicContentSize {
  NSSize t = [self.title sizeWithAttributes:@{ NSFontAttributeName : self.font }];
  return NSMakeSize(ceil(t.width) + 24, 24);
}
- (void)updateTrackingAreas {
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                       owner:self userInfo:nil]];
  [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent*)e { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)e { self.hovered = NO; self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirty {
  BOOL dark = PrefsDark(self), down = self.cell.isHighlighted;
  // PreferencesButtonBackgroundColor: dark (0.878,0.875,0.878,0.07), light (0,0,0,0.15 at most; NotArc uses 0.07
  // at rest so the light pane stays calm, 0.15 when pressed).
  CGFloat a = dark ? (down ? 0.16 : self.hovered ? 0.12 : 0.07) : (down ? 0.15 : self.hovered ? 0.1 : 0.06);
  NSColor* face = dark ? [NSColor colorWithSRGBRed:0.878 green:0.875 blue:0.878 alpha:a] : [NSColor colorWithWhite:0 alpha:a];
  [face setFill];
  [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:6 yRadius:6] fill];
  NSColor* fg = !self.enabled ? NSColor.tertiaryLabelColor
                : dark ? [NSColor colorWithSRGBRed:0.878 green:0.875 blue:0.878 alpha:1]
                       : [NSColor colorWithWhite:0.373 alpha:1];
  NSDictionary* attrs = @{ NSFontAttributeName : self.font, NSForegroundColorAttributeName : fg };
  NSSize t = [self.title sizeWithAttributes:attrs];
  [self.title drawAtPoint:NSMakePoint(round(NSMidX(self.bounds) - t.width / 2), round(NSMidY(self.bounds) - t.height / 2))
           withAttributes:attrs];
}
@end

// Icon pane rows: Arc's round radio (blue fill, white ring when chosen).
@interface IconRadio : NSButton
@end
@implementation IconRadio
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    self.bordered = NO;
    self.title = @"";
    [self setButtonType:NSButtonTypeOnOff];
  }
  return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(22, 22); }
- (void)drawRect:(NSRect)dirty {
  NSRect r = NSInsetRect(NSMakeRect(0, 0, 22, 22), 1, 1);
  if (self.state == NSControlStateValueOn) {
    [[NSColor colorWithSRGBRed:0.192 green:0.224 blue:0.945 alpha:1] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:r] fill];
    [NSColor.whiteColor setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 6, 6)] fill];
  } else {
    [(PrefsDark(self) ? [NSColor colorWithWhite:1 alpha:0.3] : [NSColor colorWithWhite:0 alpha:0.25]) setStroke];
    NSBezierPath* o = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(r, 0.5, 0.5)];
    o.lineWidth = 1.5;
    [o stroke];
  }
}
@end

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
  NSMutableDictionary<NSString*, NSButton*>* _iconTiles;  // icon name -> its radio in the Icon pane
  NSMutableDictionary<NSString*, NSSwitch*>* _checks;   // setting key -> switch
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

// A switch row: the label at the left, Arc's switch at the right of the card.
- (NSView*)check:(NSString*)title key:(NSString*)key { return [self check:title key:key accessory:nil]; }
- (NSView*)check:(NSString*)title key:(NSString*)key accessory:(NSView*)accessory {
  NSSwitch* sw = [NSSwitch new];
  sw.controlSize = NSControlSizeSmall;
  sw.identifier = key;
  sw.target = self;
  sw.action = @selector(toggled:);
  sw.state = SettingBool(key) ? NSControlStateValueOn : NSControlStateValueOff;
  _checks[key] = sw;
  NSTextField* label = [NSTextField wrappingLabelWithString:title];
  label.font = [NSFont systemFontOfSize:13];
  [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView* row = [NSStackView stackViewWithViews:accessory ? @[ label, accessory, sw ] : @[ label, sw ]];
  row.distribution = NSStackViewDistributionFill;
  row.spacing = 12;
  row.identifier = @"settingsSwitchRow";
  return row;
}

- (NSButton*)button:(NSString*)title action:(SEL)action target:(id)target {
  PrefsButton* b = [PrefsButton new];
  b.title = title;
  b.target = target;
  b.action = action;
  return b;
}

- (NSTextField*)note:(NSString*)text {
  NSTextField* f = [NSTextField wrappingLabelWithString:text];
  f.font = [NSFont systemFontOfSize:11];
  f.textColor = NSColor.secondaryLabelColor;
  f.identifier = @"settingsNote";
  return f;
}

- (NSTextField*)heading:(NSString*)text {
  NSTextField* f = [NSTextField labelWithString:text];
  f.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  f.identifier = @"settingsHeading";
  return f;
}

- (NSStackView*)row:(NSArray<NSView*>*)views {
  NSStackView* row = [NSStackView stackViewWithViews:views];
  row.spacing = 10;
  return row;
}

// A pane: section titles, each followed by a card of rows; a note sits under the row before it. A fixed width so
// every pane lines up.
- (NSView*)pane:(NSArray<NSView*>*)views {
  const CGFloat inner = kPaneWidth - 56, rowInset = 14;
  NSMutableArray<NSView*>* blocks = [NSMutableArray array];
  __block NSMutableArray<NSView*>* rows = nil;  // rows of the open card
  void (^flush)(void) = ^{
    if (!rows.count) return;
    NSMutableArray* parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < rows.count; ++i) {
      if (i) {
        SettingsHairline* h = [SettingsHairline new];
        [h.heightAnchor constraintEqualToConstant:1].active = YES;
        [h.widthAnchor constraintEqualToConstant:inner - 2 * rowInset].active = YES;
        [parts addObject:h];
      }
      [parts addObject:rows[i]];
    }
    NSStackView* stack = [NSStackView stackViewWithViews:parts];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 0;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    SettingsCardView* card = [SettingsCardView new];
    card.identifier = @"settingsCard";
    [card addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.topAnchor constraintEqualToAnchor:card.topAnchor constant:2],
      [stack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-2],
      [stack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:rowInset],
      [stack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-rowInset],
      [card.widthAnchor constraintEqualToConstant:inner],
    ]];
    [blocks addObject:card];
    rows = nil;
  };
  for (NSView* v in views) {
    if ([v.identifier isEqualToString:@"settingsHeading"]) {
      flush();
      [blocks addObject:v];
      continue;
    }
    if (!rows) rows = [NSMutableArray array];
    NSStackView* last = (NSStackView*)rows.lastObject;
    if ([v.identifier isEqualToString:@"settingsNote"] && [last.identifier isEqualToString:@"settingsRow"]) {
      [v.widthAnchor constraintEqualToConstant:inner - 2 * rowInset].active = YES;
      [last addArrangedSubview:v];  // under the row it explains
      continue;
    }
    if ([v isKindOfClass:NSTextField.class] && ((NSTextField*)v).cell.wraps)
      [v.widthAnchor constraintEqualToConstant:inner - 2 * rowInset].active = YES;
    if ([v.identifier isEqualToString:@"settingsSwitchRow"])
      [v.widthAnchor constraintEqualToConstant:inner - 2 * rowInset].active = YES;
    NSStackView* row = [NSStackView stackViewWithViews:@[ v ]];
    row.orientation = NSUserInterfaceLayoutOrientationVertical;
    row.alignment = NSLayoutAttributeLeading;
    row.spacing = 4;
    row.edgeInsets = NSEdgeInsetsMake(9, 0, 9, 0);
    row.identifier = @"settingsRow";
    [rows addObject:row];
  }
  flush();
  NSStackView* stack = [NSStackView stackViewWithViews:blocks];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  for (NSUInteger i = 0; i + 1 < blocks.count; ++i)  // more room after a card than after a title
    if ([blocks[i] isKindOfClass:SettingsCardView.class]) [stack setCustomSpacing:20 afterView:blocks[i]];
  stack.edgeInsets = NSEdgeInsetsMake(20, 28, 24, 28);
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

// The panes, in Arc's toolbar order: General, Profiles, Max, Links, Shortcuts, Icon, Advanced (Arc's Account pane has
// no NotArc equivalent). Space appearance, which Arc sets in its theme picker, also has a row in General.
- (void)buildPanes {
  _checks = [NSMutableDictionary dictionary];
  [self addPane:@"general" title:@"General" symbol:@"gearshape" view:[self generalPane]];
  [self addPane:@"profiles" title:@"Profiles" symbol:@"person.crop.circle" view:[self profilesPane]];
  [self addPane:@"max" title:@"Max" symbol:@"sparkles" view:[self maxPane]];  // #58, #59
  [self addPane:@"links" title:@"Links" symbol:@"macwindow.on.rectangle" view:[self linksPane]];
  [self addPane:@"shortcuts" title:@"Shortcuts" symbol:@"command" view:[self shortcutsPane]];
  [self addPane:@"icon" title:@"Icon" symbol:@"app.badge" view:[self iconPane]];
  [self addPane:@"advanced" title:@"Advanced" symbol:@"slider.horizontal.3" view:[self advancedPane]];
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

- (BOOL)writePaneSnapshotsTo:(NSString*)folder {  // <pane>.png (light) and <pane>-dark.png, on the window background
  BOOL ok = YES;
  for (NSTabViewItem* item in _tabs.tabViewItems) {
    NSView* v = item.viewController.view;
    for (NSString* mode in @[ @"", @"-dark" ]) {
      v.appearance = [NSAppearance appearanceNamed:mode.length ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
      [v setFrameSize:v.fittingSize];
      [v layoutSubtreeIfNeeded];
      NSBitmapImageRep* rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
      [v.appearance performAsCurrentDrawingAppearance:^{
        NSGraphicsContext* g = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
        [NSGraphicsContext saveGraphicsState];
        NSGraphicsContext.currentContext = g;
        [NSColor.windowBackgroundColor setFill];
        NSRectFill(v.bounds);
        [NSGraphicsContext restoreGraphicsState];
      }];
      [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
      NSString* path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"%@%@.png", item.identifier, mode]];
      ok = [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES] && ok;
    }
    v.appearance = nil;
  }
  return ok;
}

#pragma mark General

// Default Browser (#69): shows which app opens links now, and a button that asks macOS to make it NotArc.
- (NSView*)defaultBrowserRow {
  _defaultLabel = [NSTextField labelWithString:@""];
  _defaultButton = [self button:@"Make NotArc Default Browser" action:@selector(makeDefault:) target:self];
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

  _folderLabel = [NSTextField labelWithString:[NSUserDefaults.standardUserDefaults stringForKey:kSettingDownloadFolder]
                                                  .stringByAbbreviatingWithTildeInPath ?: @""];
  _folderLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _folderLabel.textColor = NSColor.secondaryLabelColor;
  [_folderLabel.widthAnchor constraintLessThanOrEqualToConstant:260].active = YES;
  NSButton* choose = [self button:@"Change..." action:@selector(chooseFolder:) target:self];

  return [self pane:@[
    [self heading:@"Default Browser"],
    [self defaultBrowserRow],
    [self heading:@"Search"],
    [self labeled:@"Search engine" control:_engine],
    [self check:@"Show search suggestions in the command bar" key:kSettingSearchSuggestions],
    [self heading:@"Tabs"],
    [self labeled:@"Archive Today tabs" control:_archive],
    [self note:@"Pinned tabs, Favorites and sites in Developer Mode are never archived. Archived tabs stay searchable in the Archive (Cmd+Y)."],
    [self check:@"Tidy tab titles when pinning" key:kSettingTidyTitles],
    [self heading:@"Spaces"],
    [self spaceAppearanceRow],
    [self note:@"For every Space that uses the default. A Space can pick its own in its theme picker."],
    [self heading:@"Browsing"],
    [self check:@"Show my next meeting from Calendar in the sidebar" key:kSettingCalendar],
    [self check:@"Offer to translate pages in other languages" key:kSettingTranslateOffer],
    [self check:@"Block ads & trackers" key:kSettingBlockAds
         accessory:[self button:@"Manage..." action:@selector(showManageAdBlockers:) target:self]],
    [self heading:@"Media & Feedback"],
    [self check:@"Open picture-in-picture when leaving a tab with a playing video" key:kSettingAutoPiP],
    [self check:@"Play sound effects" key:kSettingSoundEffects],
    [self check:@"Haptic feedback when reordering tabs" key:kSettingReorderHaptics],
    [self heading:@"Downloads"],
    [self labeled:@"Download location" control:[self row:@[ _folderLabel, choose ]]],
  ]];
}

// "Label ........ control": a row with the control at the card's right edge.
- (NSView*)labeled:(NSString*)title control:(NSView*)control {
  NSTextField* label = [NSTextField labelWithString:title];
  label.font = [NSFont systemFontOfSize:13];
  NSView* gap = [NSView new];
  [gap setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView* row = [NSStackView stackViewWithViews:@[ label, gap, control ]];
  row.spacing = 10;
  row.identifier = @"settingsSwitchRow";  // full card width, like a switch row
  return row;
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

- (void)toggled:(NSControl*)sender {
  SettingSetBool(sender.identifier, [(NSSwitch*)sender state] == NSControlStateValueOn);
  if ([sender.identifier isEqualToString:kSettingBlockAds]) {
    ApplyContentBlockerSettings();
    [NSNotificationCenter.defaultCenter postNotificationName:FilterListsDidChangeNotification object:nil];
  }
  if ([sender.identifier isEqualToString:kSettingDeveloperModeLocal]) SettingsDidChange();
  if ([sender.identifier isEqualToString:kSettingMaxEnabled]) [self refreshMaxFeatures];
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
  _profileTable.usesAlternatingRowBackgroundColors = NO;
  _profileTable.backgroundColor = NSColor.clearColor;
  _profileTable.style = NSTableViewStylePlain;
  _profileTable.rowHeight = 26;
  _profileTable.dataSource = self;
  _profileTable.delegate = self;
  _profileTable.target = self;
  _profileTable.doubleAction = @selector(renameProfile:);
  NSScrollView* scroll = [NSScrollView new];
  scroll.documentView = _profileTable;
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSNoBorder;
  scroll.drawsBackground = NO;
  [scroll.widthAnchor constraintEqualToConstant:kPaneWidth - 84].active = YES;
  [scroll.heightAnchor constraintEqualToConstant:190].active = YES;
  [self refreshProfiles];
  return [self pane:@[
    [self heading:@"Profiles"],
    [self note:@"Each Space belongs to a profile, with its own logins, history and Favorites. To move a Space to "
               @"another profile, use its menu (Space name > Profile)."],
    scroll,
    [self row:@[ [self button:@"New Profile..." action:@selector(newProfile:) target:self],
                 [self button:@"Rename..." action:@selector(renameProfile:) target:self] ]],
    [self heading:@"Import from Arc"],
    [self button:@"Import Everything from Arc..." action:@selector(importEverythingFromArcMenu:) target:nil],
    [self note:@"Copies Arc's logins (so you stay signed in), history, extensions, saved passwords, addresses and cards "
               @"into the matching profiles. Safe to run again: it brings Arc's latest logins and adds nothing twice."],
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
  ArcAlert* a = [ArcAlert new];
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

#pragma mark Icon

// Arc's Icon pane: one card, one row per icon (radio, a preview, the name in bold).
- (NSView*)iconRow:(NSString*)name {
  IconRadio* radio = [IconRadio new];
  radio.identifier = name;
  radio.target = self;
  radio.action = @selector(iconClicked:);
  NSButton* preview = [NSButton buttonWithImage:AppIconImage(name) target:self action:@selector(iconClicked:)];
  preview.identifier = name;
  preview.bordered = NO;
  preview.imageScaling = NSImageScaleProportionallyUpOrDown;
  [preview.widthAnchor constraintEqualToConstant:54].active = YES;
  [preview.heightAnchor constraintEqualToConstant:54].active = YES;
  NSTextField* label = [NSTextField labelWithString:AppIconTitle(name)];
  label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];
  NSStackView* row = [NSStackView stackViewWithViews:@[ radio, preview, label ]];
  row.spacing = 14;
  _iconTiles[name] = radio;
  return row;
}

- (void)refreshIconTiles {
  NSString* current = CurrentAppIconName();
  [_iconTiles enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSButton* radio, BOOL*) {
    radio.state = [name isEqualToString:current] ? NSControlStateValueOn : NSControlStateValueOff;
    radio.needsDisplay = YES;
  }];
}

- (NSView*)spaceAppearanceRow {
  _appearance = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  for (NSArray* o in @[ @[ @"Automatic (follows macOS)", @"auto" ], @[ @"Light", @"light" ], @[ @"Dark", @"dark" ] ]) {
    [_appearance addItemWithTitle:o[0]];
    _appearance.lastItem.representedObject = o[1];
  }
  [_appearance selectItemAtIndex:[@[ @"auto", @"light", @"dark" ] indexOfObject:DefaultSpaceAppearance()]];
  _appearance.target = self;
  _appearance.action = @selector(appearanceChosen:);
  return [self labeled:@"Appearance" control:_appearance];
}

- (NSView*)iconPane {
  _iconTiles = [NSMutableDictionary dictionary];
  NSMutableArray* rows = [NSMutableArray arrayWithObject:[self heading:@"App Icon"]];
  for (NSString* name in AppIconNames()) [rows addObject:[self iconRow:name]];
  [rows addObject:[self note:@"Shown in the Dock while NotArc is open. Finder, and the Dock when NotArc is closed, show the NotArc icon."]];
  [self refreshIconTiles];
  return [self pane:rows];
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
  [_iconTiles enumerateKeysAndObjectsUsingBlock:^(NSString* name, NSButton* radio, BOOL*) {
    if (radio.state == NSControlStateValueOn) out = name;
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
    [self button:@"Air Traffic Control..." action:@selector(showAirTrafficControl:) target:nil],
    [self note:@"Rules that send links from other apps to a Space or a Little Window. Your Arc rules come over on first launch."],
    [self row:@[ [NSTextField labelWithString:@"Archive Little Windows:"], _littleArchive ]],
  ]];
}

#pragma mark Max

// Arc's Max pane: the main switch, then one switch per feature (off while Max is off).
- (NSView*)maxPane {
  NSView* pane = [self pane:@[
    [self heading:@"Max"],
    [self check:@"Turn on Max" key:kSettingMaxEnabled],
    [self note:[MaxModelStatusText(MaxModelAvailability()) stringByAppendingString:
                   @" Nothing is sent to a NotArc server. ChatGPT opens chatgpt.com with your own sign-in."]],
    [self heading:@"Features"],
    [self check:@"Ask on Page and page summaries (Cmd+Shift+A)" key:kSettingMaxAskOnPage],
    [self check:@"\"Ask ChatGPT\" in the command bar" key:kSettingMaxChatGPT],
    [self check:@"5-second previews: hold Shift while pointing at a link" key:kSettingMaxPreviews],
    [self check:@"Tidy Tabs: sort Today's tabs into folders" key:kSettingMaxTidyTabs],
    [self check:@"Tidy tab titles with Apple's model (else the built-in rules)" key:kSettingMaxTidyTitles],
  ]];
  [self refreshMaxFeatures];
  return pane;
}
- (void)refreshMaxFeatures {
  BOOL on = SettingBool(kSettingMaxEnabled);
  for (NSString* k in @[ kSettingMaxAskOnPage, kSettingMaxChatGPT, kSettingMaxPreviews, kSettingMaxTidyTabs, kSettingMaxTidyTitles ])
    _checks[k].enabled = on;
}

#pragma mark Shortcuts

// Arc's Shortcuts pane: a searchable list of every command and its keys (the editor that used to be its own window).
- (NSView*)shortcutsPane {
  NSView* editor = [[ShortcutsWindowController shared] contentForSettingsPane];
  return [self pane:@[ [self heading:@"Shortcuts"], editor ]];
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
    [self button:@"Reset Developer Mode Sites" action:@selector(resetDeveloperModeSites:) target:self],
    [self heading:@"Browsing Data"],
    [self button:@"Clear Browsing Data..." action:@selector(clearBrowsingData:) target:self],
    [self heading:@"Reset"],
    [self button:@"Reset All Settings..." action:@selector(resetAllSettings:) target:self],
    [self note:@"Puts every setting in this window back to its default. Spaces, tabs, profiles, history and site "
               @"permissions are kept."],
  ]];
}

// Tests (V58): what a pane is made of.
- (NSString*)paneLook:(NSString*)identifier {
  __block int cards = 0, switches = 0, checkboxes = 0, flat = 0, system = 0, radios = 0;
  __block void (^walk)(NSView*);
  void (^w)(NSView*) = ^(NSView* v) {
    if ([v isKindOfClass:SettingsCardView.class]) cards++;
    else if ([v isKindOfClass:NSSwitch.class]) switches++;
    else if ([v isKindOfClass:IconRadio.class]) radios++;
    else if ([v isKindOfClass:PrefsButton.class]) flat++;
    else if ([v isKindOfClass:NSButton.class] && ((NSButton*)v).bezelStyle == NSBezelStyleRounded && ((NSButton*)v).isBordered &&
             ((NSButton*)v).title.length) system++;
    else if ([v isKindOfClass:NSButton.class] && [NSStringFromClass([v class]) isEqualToString:@"NSButton"] &&
             [(NSButtonCell*)((NSButton*)v).cell showsStateBy] == NSContentsCellMask && ((NSButton*)v).title.length &&
             ((NSButton*)v).imagePosition == NSImageLeft)
      checkboxes++;
    for (NSView* c in v.subviews) walk(c);
  };
  walk = w;
  walk([self viewOfPane:identifier]);
  walk = nil;
  return [NSString stringWithFormat:@"cards=%d switches=%d checkboxes=%d flatButtons=%d systemButtons=%d radios=%d", cards, switches,
                                    checkboxes, flat, system, radios];
}

- (NSNumber*)checkboxForSetting:(NSString*)settingKey {
  NSSwitch* b = _checks[settingKey];
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
  ArcAlert* a = [ArcAlert new];
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
