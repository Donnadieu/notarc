// Filter list subscriptions for the ad blocker (#53). The user turns lists on in Manage Ad Blockers...; a list is
// downloaded only then (EasyList and EasyPrivacy are offered as suggestions, never bundled), saved under
// Application Support/NotArc/Filter Lists, refreshed once a day and on demand, and parsed into content_blocker.
#pragma once

#import <Foundation/Foundation.h>

extern NSString* const kSettingAdBlockLists;     // NSArray<NSDictionary*>: subscribed lists (see FilterListManager)
extern NSString* const kSettingAdBlockBuiltIn;   // BOOL, default YES: NotArc's own host list
extern NSString* const FilterListsDidChangeNotification;

// One row of the lists table. Suggested lists that were never turned on have `suggested` set and no rules.
@interface FilterList : NSObject
@property(nonatomic, copy) NSString* url;
@property(nonatomic, copy) NSString* title;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL suggested;     // EasyList / EasyPrivacy shown before the user subscribes
@property(nonatomic) NSInteger rules;    // rules NotArc understood in the last download
@property(nonatomic, strong) NSDate* updated;  // last successful download, nil = never
@property(nonatomic, copy) NSString* error;    // last failed download, nil = fine
@property(nonatomic) BOOL updating;
@end

@interface FilterListManager : NSObject
+ (instancetype)shared;
- (NSArray<FilterList*>*)lists;  // subscribed lists, then suggestions not yet subscribed
// Turning a list on subscribes to it and downloads it if it has never been downloaded.
- (void)setList:(NSString*)url enabled:(BOOL)enabled;
// Adds and downloads a list (http, https or file URL). Returns NO for anything else or a duplicate.
- (BOOL)addListURL:(NSString*)url;
- (void)removeList:(NSString*)url;          // deletes the saved copy; a suggestion goes back to "not downloaded"
- (void)updateAll;                          // Update Now: re-download every turned-on list
- (void)updateList:(NSString*)url done:(void (^)(BOOL ok))done;
// Re-reads the saved copies of the turned-on lists and parses them (in the background) when blocking is on.
- (void)reloadRules;
- (NSArray<NSString*>*)listsDueForRefreshAt:(NSDate*)now;  // turned on and last downloaded over a day ago
- (void)startDailyRefresh;                  // hourly check for lists due; never in self-tests
@property(nonatomic, readonly) BOOL busy;   // a download or parse is in flight (tests)
@property(nonatomic, readonly) NSUInteger reloads;  // finished parses (tests)
+ (NSArray<NSArray<NSString*>*>*)suggestions;  // @[ title, url ]
@end
