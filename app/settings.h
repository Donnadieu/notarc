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
extern NSString* const kSettingBlockAds;            // BOOL, default NO (Arc's built-in blocker was opt-in)
extern NSString* const kSettingAdBlockExceptions;   // NSArray<NSString*> of hosts where blocking is off
void ApplyContentBlockerSettings(void);            // pushes the settings into the request filter
extern NSString* const kSettingSearchSuggestions;     // BOOL, default YES
NSString* TranslateURLFor(NSString* url, NSString* lang);  // nil for non-web or already translated pages
NSString* OriginalURLForTranslated(NSString* url);          // nil when the page isn't a translation
NSString* PreferredTranslateLanguage(void);                 // first macOS language, e.g. "en", "zh-TW"
NSString* SuggestURLForQuery(NSString* encodedQuery);
NSArray<NSString*>* ParseSearchSuggestions(NSData* json);   // uses the chosen search engine
BOOL SettingBool(NSString* key);
double SettingDouble(NSString* key);

@interface SettingsWindowController : NSWindowController
+ (instancetype)shared;
- (BOOL)defaultBrowserRowConsistent;  // tests
@end
