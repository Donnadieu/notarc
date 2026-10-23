// NotArc's own sidebar store. Arc's files are only read once, on first launch (import);
// after that the sidebar lives in ~/Library/Application Support/NotArc/Sidebar.json.
#pragma once

#import <Foundation/Foundation.h>

#import "app/arc_import.h"

NSString* SidebarStorePath(BOOL selfTest);
// Returns nil when no store exists yet (caller falls back to the Arc import).
NSArray<ArcSpace*>* SidebarStoreLoad(NSString* path, NSString** focusedSpaceID, NSError** error);
BOOL SidebarStoreSave(NSArray<ArcSpace*>* spaces, NSString* focusedSpaceID, NSString* path, NSError** error);
