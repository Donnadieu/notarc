// Keyboard shortcuts with user overrides (#73). Every menu command can get a new key combination, or none;
// overrides are saved in settings ("shortcutOverrides", keyed by menu path such as "File/New Tab") and applied
// to the menu bar at launch.
#pragma once

#import <Cocoa/Cocoa.h>

NSString* ShortcutPath(NSMenuItem* item);  // "File/New Tab"
NSString* ShortcutDisplay(NSString* key, NSEventModifierFlags mods);  // "⌘⇧N"; "" when none
// Remembers each item's built-in shortcut (for Reset), then applies saved overrides. Call after building the menu.
void ApplyShortcutOverrides(NSMenu* mainMenu);
// Sets (key "" = remove) or resets (key nil) one command's shortcut, saves it, and updates the menu.
// Returns the path of another command that had this combination and was cleared, or nil.
NSString* SetShortcut(NSMenu* mainMenu, NSString* path, NSString* key, NSEventModifierFlags mods);
NSMenuItem* MenuItemAtPath(NSMenu* mainMenu, NSString* path);

@interface ShortcutsWindowController : NSWindowController
+ (instancetype)shared;
@end
