// AppleScript support (#76): NotArc.sdef maps windows, Spaces and tabs onto these wrappers.
#pragma once
#import <Cocoa/Cocoa.h>
@class MainWindowController, ArcItem, ArcSpace;
@interface NAScriptTab : NSObject
@property(nonatomic, weak) MainWindowController* controller;
@property(nonatomic, strong) ArcItem* item;
@property(nonatomic, copy) NSString* pendingURL;  // "make new tab with properties {URL:...}"
@end
@interface NAScriptSpace : NSObject
@property(nonatomic, weak) MainWindowController* controller;
@property(nonatomic, strong) ArcSpace* space;
@end
