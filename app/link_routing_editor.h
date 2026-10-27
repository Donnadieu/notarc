// Arc's Air Traffic Control settings (#34): edit the rules that send links from other apps to a Space or a
// Little Window. Every change is saved straight away to LinkRouting.json.
#pragma once

#import <Cocoa/Cocoa.h>

@class LinkRouting;

@interface LinkRoutingEditor : NSWindowController
// spaces: @[ @[spaceID, title], ... ]
- (instancetype)initWithPath:(NSString*)path spaces:(NSArray<NSArray<NSString*>*>*)spaces;
@property(nonatomic, readonly) LinkRouting* routing;
// Editing (the table's controls call these; tests too).
- (void)addRule;
- (void)removeRuleAt:(NSUInteger)index;
- (void)setRuleAt:(NSUInteger)index match:(NSString*)match pattern:(NSString*)pattern app:(NSString*)app
               to:(NSString*)destination space:(NSString*)spaceID;
- (void)setDefaultTo:(NSString*)destination space:(NSString*)spaceID;
@end
