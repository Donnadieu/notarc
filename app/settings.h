// NotArc settings, stored in NSUserDefaults, and the Settings window (Cmd+,).
#pragma once

#import <Cocoa/Cocoa.h>

// Keys
extern NSString* const kSettingAutoArchiveHours;       // double; 0 = never. Default 12.
extern NSString* const kSettingSearchEngine;           // "google" | "duckduckgo" | "bing" | "ecosia" | "kagi"
extern NSString* const kSettingPeekPinnedLinks;        // BOOL, default YES
extern NSString* const kSettingPeekShiftClick;         // BOOL, default YES
extern NSString* const kSettingExternalLinksLittle;    // BOOL, default YES (NO = open as a Today tab)
extern NSString* const kSettingLittleArchiveHours;     // double; 0 = never. Default 6.

void SettingsRegisterDefaults(void);
NSString* SearchURLForQuery(NSString* encodedQuery);   // uses the chosen search engine
BOOL SettingBool(NSString* key);
double SettingDouble(NSString* key);

@interface SettingsWindowController : NSWindowController
+ (instancetype)shared;
@end
