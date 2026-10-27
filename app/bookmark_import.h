// Import bookmarks (#80): Chromium-family browsers' "Bookmarks" JSON (Chrome, Brave, Edge, Vivaldi, Chromium)
// and the bookmark HTML file every browser exports (Safari, Firefox). Read-only on the other browser's side.
#pragma once

#import <Foundation/Foundation.h>

@class ArcItem;

// A folder ArcItem holding the bookmarks as tabs and subfolders; nil if unreadable. *count = bookmarks found.
ArcItem* BookmarksFromChromiumFile(NSString* path, NSString* folderTitle, NSUInteger* count);
ArcItem* BookmarksFromHTMLFile(NSString* path, NSString* folderTitle, NSUInteger* count);

// Installed Chromium-family browsers with a Bookmarks file: @[ @[displayName, path], ... ].
NSArray<NSArray<NSString*>*>* DetectedBookmarkSources(void);
