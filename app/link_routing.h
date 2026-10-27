// Arc's Air Traffic Control (#34): rules that send links opened from other apps to a Space or a Little Window.
// Rules come from NotArc's LinkRouting.json, seeded once from Arc's StorableLinkRouting.json (read-only).
#pragma once

#import <Foundation/Foundation.h>

@interface LinkRule : NSObject
@property(nonatomic, copy) NSString* matchType;   // contains | exact | startsWith | domain | regex
@property(nonatomic, copy) NSString* pattern;     // URL part to match; nil = any URL
@property(nonatomic, copy) NSString* sourceApp;   // bundle ID of the app the link came from; nil = any app
@property(nonatomic, copy) NSString* destination; // "space" | "little"
@property(nonatomic, copy) NSString* spaceID;     // nil = the most recent Space
@end

@interface LinkRouting : NSObject
@property(nonatomic, copy) NSArray<LinkRule*>* rules;
@property(nonatomic, copy) NSString* defaultDestination;  // "little" | "space"
@property(nonatomic, copy) NSString* defaultSpaceID;
+ (instancetype)fromArcFile:(NSString*)path;               // nil if missing or unreadable
+ (instancetype)loadFrom:(NSString*)path;
- (BOOL)saveTo:(NSString*)path;
// First rule that matches, or nil (then defaultDestination applies).
- (LinkRule*)ruleForURL:(NSString*)url sourceApp:(NSString*)bundleID;
@end

BOOL LinkRuleMatchesURL(LinkRule* rule, NSString* url);
NSString* LinkRoutingPath(BOOL selfTest);
