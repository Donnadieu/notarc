// Read-only importer for Arc's sidebar (StorableSidebar.json). Format: docs/arc-data-format.md.
#pragma once

#import <Foundation/Foundation.h>

@interface ArcItem : NSObject
@property(nonatomic, copy) NSString* itemID;
@property(nonatomic, copy) NSString* title;      // user rename, else Arc's saved title
@property(nonatomic, copy) NSString* liveTitle;  // title reported by the loaded page
@property(nonatomic, copy) NSString* url;        // nil for folders and section roots; current page
// Pinned tabs and Favorites: the URL the tab returns to when closed or reset (Arc's saved URL).
@property(nonatomic, copy) NSString* pinnedURL;
@property(nonatomic) BOOL isFolder;
@property(nonatomic) BOOL isSection;  // the Pinned / Today root of a Space
// A split view shown as one sidebar item; its children are the panes, in order.
@property(nonatomic) BOOL isSplit;
@property(nonatomic) BOOL splitHorizontal;                       // stacked instead of side by side
@property(nonatomic, copy) NSArray<NSNumber*>* splitFractions;   // pane sizes summing to 1; nil = equal
@property(nonatomic, strong) NSMutableArray<ArcItem*>* children;
@property(nonatomic) int browserId;
@property(nonatomic) BOOL mediaPlaying;  // audio or video playing (not saved)
@property(nonatomic) BOOL mediaPaused;   // has media that was playing and is now paused (not saved)
@property(nonatomic) BOOL audioMuted;
@property(nonatomic) BOOL wasOpen;  // had a live page when last saved (restored after a crash)
@property(nonatomic) BOOL crashed;  // the page's process died; a Reload overlay covers it (not saved)    // tab muted (not saved)  // 0 until a web view exists for this tab
@property(nonatomic, strong) NSDate* lastActiveAt;  // drives auto-archive of Today tabs
- (NSString*)displayTitle;
@end

@interface ArcSpace : NSObject
@property(nonatomic, copy) NSString* spaceID;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* profileDirectory;  // Arc's Chromium profile, e.g. "Profile 4"
@property(nonatomic, strong) ArcItem* pinned;
@property(nonatomic, strong) ArcItem* unpinned;
@property(nonatomic, copy) NSString* shownItemID;  // tab last shown in this Space
@property(nonatomic, strong) ArcItem* favorites;  // Arc "topApps": shared by all Spaces on the same profile
// Space theme: 1-2 hex colours ("#RRGGBB") blended top to bottom over the sidebar, how strongly (0-1), and an
// optional emoji shown before the name. Empty = the plain system sidebar.
@property(nonatomic, copy) NSArray<NSString*>* themeColors;
@property(nonatomic) double themeIntensity;
@property(nonatomic, copy) NSString* iconEmoji;
@property(nonatomic, copy) NSString* colorScheme;  // Arc per-Space appearance: nil/"auto", "light", "dark"
- (NSArray<ArcItem*>*)allTabs;  // depth-first: favorites, pinned, Today
@end

NSString* ArcDataDirectory(void);
NSArray<ArcSpace*>* ArcImportSidebar(NSString* sidebarPath, NSError** error);
NSString* ArcFocusedSpaceID(NSString* windowsPath);
NSString* ArcDescribeSpaces(NSArray<ArcSpace*>* spaces);
