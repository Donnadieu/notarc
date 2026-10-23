// Read-only importer for Arc's sidebar (StorableSidebar.json). Format: docs/arc-data-format.md.
#pragma once

#import <Foundation/Foundation.h>

@interface ArcItem : NSObject
@property(nonatomic, copy) NSString* itemID;
@property(nonatomic, copy) NSString* title;      // user rename, else Arc's saved title
@property(nonatomic, copy) NSString* liveTitle;  // title reported by the loaded page
@property(nonatomic, copy) NSString* url;        // nil for folders and section roots
@property(nonatomic) BOOL isFolder;
@property(nonatomic) BOOL isSection;  // the Pinned / Today root of a Space
// A split view shown as one sidebar item; its children are the panes, in order.
@property(nonatomic) BOOL isSplit;
@property(nonatomic) BOOL splitHorizontal;                       // stacked instead of side by side
@property(nonatomic, copy) NSArray<NSNumber*>* splitFractions;   // pane sizes summing to 1; nil = equal
@property(nonatomic, strong) NSMutableArray<ArcItem*>* children;
@property(nonatomic) int browserId;  // 0 until a web view exists for this tab
@property(nonatomic, strong) NSDate* lastActiveAt;  // drives auto-archive of Today tabs
- (NSString*)displayTitle;
@end

@interface ArcSpace : NSObject
@property(nonatomic, copy) NSString* spaceID;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* profileDirectory;  // Arc's Chromium profile, e.g. "Profile 4"
@property(nonatomic, strong) ArcItem* pinned;
@property(nonatomic, strong) ArcItem* unpinned;
@property(nonatomic, strong) ArcItem* favorites;  // Arc "topApps": shared by all Spaces on the same profile
- (NSArray<ArcItem*>*)allTabs;  // depth-first: favorites, pinned, Today
@end

NSString* ArcDataDirectory(void);
NSArray<ArcSpace*>* ArcImportSidebar(NSString* sidebarPath, NSError** error);
NSString* ArcFocusedSpaceID(NSString* windowsPath);
NSString* ArcDescribeSpaces(NSArray<ArcSpace*>* spaces);
