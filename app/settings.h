// NotArc settings, stored in NSUserDefaults, and the Settings window (Cmd+,).
#pragma once

#import <Cocoa/Cocoa.h>

// Keys
extern NSString* const kSettingAutoArchiveHours;       // double; 0 = never. Default 12.
extern NSString* const kSettingSearchEngine;           // "google" | "duckduckgo" | "bing" | "ecosia" | "kagi"
extern NSString* const kSettingPeekPinnedLinks;        // BOOL, default YES
extern NSString* const kSettingPeekShiftClick;         // BOOL, default YES
extern NSString* const kSettingExternalLinksLittle;    // BOOL, default YES (NO = open as a Today tab)
// Self-test runs call SettingsUseMemoryOnly() so SettingSetBool never writes the user's real preferences.
void SettingsUseMemoryOnly(void);
void SettingSetBool(NSString* key, BOOL value);
id SettingObject(NSString* key);
void SettingSetObject(NSString* key, id value);
extern NSString* const kSettingCommandPicks;
extern NSString* const kSettingSitePermissions;        // dictionary: origin -> {permission name -> YES/NO}           // dictionary: suggestion key -> times picked (ranking)
extern NSString* const kSettingAutoPiP;                // BOOL, default YES: a playing video pops out when you leave its tab (#46)
extern NSString* const kSettingShowToolbar;            // BOOL, default NO: address bar with the full URL above pages
extern NSString* const kSettingShowSpaceHeader;        // BOOL, default YES: Space picker at the top of the sidebar
extern NSString* const kSettingLittleArchiveHours;     // double; 0 = never. Default 6.

void SettingsRegisterDefaults(void);
NSString* SearchURLForQuery(NSString* encodedQuery);
// Default browser (#69). Reads only; MakeNotArcDefaultBrowser asks macOS, which shows its own confirmation.
NSURL* DefaultBrowserAppURL(void);  // the app that opens https links now
BOOL NotArcIsDefaultBrowser(void);
void MakeNotArcDefaultBrowser(void (^done)(BOOL ok));
// Search suggestions (#31): the chosen engine's suggestion endpoint (OpenSearch JSON), and its parser.
extern NSString* const kSettingSoundEffects;        // BOOL, default YES (Arc: "Play Arc sound effects")
extern NSString* const kSettingReorderHaptics;      // BOOL, default YES (Arc: "Haptic feedback when reordering tabs")
// Sound effects (#74): plays macOS's own system sounds, never Arc's. Returns YES if the effect was due (setting on);
// self-test runs count it instead of making noise.
typedef NS_ENUM(NSInteger, NotArcSound) { NotArcSoundCapture };
BOOL PlaySoundEffect(NotArcSound sound);
NSInteger SoundEffectsPlayedForTest(void);
void ReorderHaptic(void);                           // trackpad tick while reordering tabs, if on
NSInteger ReorderHapticsForTest(void);
extern NSString* const kSettingBlockAds;            // BOOL, default NO (Arc's built-in blocker was opt-in)
extern NSString* const kSettingAdBlockExceptions;   // NSArray<NSString*> of hosts where blocking is off
void ApplyContentBlockerSettings(void);            // pushes the settings into the request filter
extern NSString* const kSettingTidyTitles;
extern NSString* const kSettingCalendar;  // BOOL, default NO: next meeting from the Mac's Calendar in the sidebar (#56)
extern NSString* const kSettingLittleHotkey;       // BOOL, default YES: Cmd+Option+N opens a Little Window from any app (#42)
extern NSString* const kSettingLittleModifierClick;  // BOOL, default YES: Cmd+Option+click on a link opens it in a Little Window  // BOOL, default YES: pinning a tab gives it a short, clean name (#18)
extern NSString* const kSettingSearchSuggestions;     // BOOL, default YES
NSString* TranslateURLFor(NSString* url, NSString* lang);  // nil for non-web or already translated pages
NSString* OriginalURLForTranslated(NSString* url);          // nil when the page isn't a translation
NSString* PreferredTranslateLanguage(void);
// Translate offer (#52): the page's language code to offer translating from, or nil when it's empty, undetermined or
// one of the person's own languages (compared by primary subtag: "en-GB" page, "en-US" Mac = no offer).
NSString* TranslateOfferFor(NSString* pageLang, NSArray<NSString*>* preferredLanguages);
extern NSString* const kSettingTranslateOffer;  // BOOL, default YES: offer to translate pages in other languages                 // first macOS language, e.g. "en", "zh-TW"
NSString* SuggestURLForQuery(NSString* encodedQuery);
NSArray<NSString*>* ParseSearchSuggestions(NSData* json);   // uses the chosen search engine
BOOL SettingBool(NSString* key);
double SettingDouble(NSString* key);

// Appearance (#72): Spaces that haven't chosen their own Light/Dark in their menu use this. "auto" follows macOS.
extern NSString* const kSettingSpaceAppearance;     // "auto" | "light" | "dark", default "auto"
NSString* DefaultSpaceAppearance(void);
extern NSString* const kSettingChromePages;         // BOOL "chromePages", default NO; read once at launch

// Developer Mode (#68), per site as in Arc: shows the full address with its port in the sidebar pill, keeps the tab
// from being auto-archived and puts Developer Tools in the pill. On by itself for local sites (localhost, *.localhost,
// 127.x.x.x, ::1, *.local) unless that's turned off; any site can be turned on or off. Hosts are stored without "www.".
extern NSString* const kSettingDeveloperModeLocal;  // BOOL, default YES: local sites start in Developer Mode
extern NSString* const kSettingDeveloperModeHosts;  // NSDictionary host -> @YES/@NO (only choices that differ)
BOOL DeveloperModeIsLocalHost(NSString* host);
BOOL DeveloperModeOnForHost(NSString* host);
BOOL DeveloperModeOnForURL(NSString* url);          // http(s) pages only
void SetDeveloperMode(BOOL on, NSString* host);
NSArray<NSString*>* DeveloperModeChosenHosts(void); // sites turned on by hand, sorted
void ResetDeveloperModeHosts(void);                 // forgets every per-site choice (Arc: "Reset developer mode enabled hosts")
// What the sidebar address pill shows: the site without "www." normally, the full address (port, path, query) for a
// page in Developer Mode.
NSString* SidebarAddressTextForURL(NSString* url);

// Reset settings (Settings > Advanced): every preference shown in Settings goes back to its default. Spaces, tabs,
// profiles, history, site permissions and keyboard shortcuts are kept.
void ResetAllSettings(void);
NSDictionary* SettingsMemorySnapshotForTest(void);  // memory-only runs: save and put back the in-memory settings
void SettingsMemoryRestoreForTest(NSDictionary* snapshot);
// Tells every browser window to re-read the settings (appearance, toolbar, Space header, pill, Developer Mode).
void SettingsDidChange(void);

// Settings window (Cmd+,): one pane per toolbar tab, like Arc's. Panes are listed in -buildPanes in settings.mm;
// to add one (e.g. Max), write a method that returns its view and add one -addPane:... line there.
@interface SettingsWindowController : NSWindowController
+ (instancetype)shared;
- (BOOL)defaultBrowserRowConsistent;  // tests
- (void)addPane:(NSString*)identifier title:(NSString*)title symbol:(NSString*)sfSymbol view:(NSView*)view;
- (NSArray<NSString*>*)paneIdentifiers;
- (void)selectPane:(NSString*)identifier;
- (NSString*)selectedPane;
- (NSView*)viewOfPane:(NSString*)identifier;
- (BOOL)writePaneSnapshotsTo:(NSString*)folder;  // design checks: <pane>.png for each pane
// Profiles pane (tests drive the same code as its buttons, without the name prompt).
- (NSArray<NSString*>*)profileRows;  // "Name: Space A, Space B" per profile, in table order
- (NSString*)createProfileNamed:(NSString*)name;
- (BOOL)renameProfileAtRow:(NSInteger)row to:(NSString*)name;
// Appearance pane.
- (void)chooseSpaceAppearance:(NSString*)scheme;  // same as the pop-up
- (void)chooseAppIcon:(NSString*)name;            // same as clicking an icon
- (NSString*)appIconShownAsChosen;                // the icon the picker marks as chosen
// Advanced pane.
- (NSNumber*)checkboxForSetting:(NSString*)settingKey;  // @YES/@NO as shown, nil if no pane has one
- (NSString*)developerModeSitesText;
- (IBAction)resetDeveloperModeSites:(id)sender;
- (BOOL)hasCheckboxForKey:(NSString*)key;  // tests
@end
