// App icon choice (#74): NotArc's own icon variants, drawn in code (never Arc's artwork). The chosen one is set as
// NSApp.applicationIconImage at launch and whenever it changes, so the Dock shows it while NotArc runs. The signed
// app bundle is never modified, so Finder and a Dock that isn't running NotArc keep the bundle's icon.
#pragma once

#import <Cocoa/Cocoa.h>

extern NSString* const kSettingAppIcon;  // NSString, one of AppIconNames(); default "classic"

NSArray<NSString*>* AppIconNames(void);           // in picker order
NSString* AppIconTitle(NSString* name);           // "Classic", "Sunset", ...
NSImage* AppIconImage(NSString* name);            // cached, resolution independent; nil for unknown names
NSString* CurrentAppIconName(void);               // the setting, or "classic" if unset or unknown
void ApplyAppIcon(void);                          // sets NSApp.applicationIconImage from the setting
CGFloat AppIconDifference(NSImage* a, NSImage* b);  // tests: mean per-channel difference (0-255) at 8x8 pixels
