// Manage Ad Blockers... (#53): NotArc's built-in list on/off, subscribed filter lists (rule count, last update, Add
// List, Update Now, Remove) and the sites where blocking is off. Opened from Settings and from Site Settings.
#pragma once

#import <Cocoa/Cocoa.h>

@interface ManageAdBlockersWindowController : NSWindowController
+ (instancetype)shared;
- (void)reload;
// Tests (the window is never shown in self-tests).
- (NSArray<NSString*>*)rowSummaries;  // "builtin=1", "list=<title>|on=1|rules=N|updated=1|suggested=0", "site=<host>"
- (BOOL)addListFromField:(NSString*)url;   // types into the Add field and presses Add List
- (void)toggleBuiltIn;                     // clicks the built-in list checkbox
- (void)removeSiteException:(NSString*)host;
@end
