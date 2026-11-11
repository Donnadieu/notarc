// The sidebar's Library panel (Arc: the Library button at the bottom left). It takes the place of the Space's
// tabs inside the sidebar, under the address pill and above the bottom bar, and goes away with Back, Esc or a
// Space switch. First section: Archive, a searchable list of archived tabs grouped by when they were archived.
#pragma once

#import <Cocoa/Cocoa.h>

#import "app/archive_store.h"

// Group headings for an archive list, newest first: "Today", "Yesterday", weekday names for the last week, then
// "Last Week", then month names ("October", or "October 2025" for another year). Pure, for tests.
NSString* ArchiveGroupTitle(NSDate* when, NSDate* now, NSCalendar* calendar);

// One row in a Library section other than Archive (a Space, a download, a capture, an easel, a note, a Boost).
@interface LibraryEntry : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* detail;  // right-hand text (size, date, site)
@property(nonatomic, strong) NSImage* icon;
@property(nonatomic) BOOL tintIcon;           // a template symbol drawn in the text colour
@property(nonatomic, copy) void (^open)(void);
@property(nonatomic, copy) NSString* searchText;
@property(nonatomic) BOOL card;               // a download card (icon, name, status, progress)
@property(nonatomic) double progress;         // 0-1 while downloading; < 0 = none
+ (instancetype)entry:(NSString*)title detail:(NSString*)detail icon:(NSImage*)icon open:(void (^)(void))open;
@end

// Arc's download card: the file's icon, its name, a status line and a thin progress bar while it downloads, on a
// rounded fill that brightens under the pointer. solid = the Downloads tray's opaque colours (Arc's
// DownloadItemBackground / Hovered); otherwise the sidebar's translucent fills.
@interface DownloadCardView : NSView
- (instancetype)initWithFrame:(NSRect)frame solid:(BOOL)solid;
- (void)showEntry:(LibraryEntry*)entry textColor:(NSColor*)textColor;
@property(nonatomic, readonly) BOOL hasProgressBar;  // tests
@end

// Arc's Library: a home list (Spaces, then Archive, Downloads, Media, Easels, Notes, Boosts with counts) and each
// section opened in place, with Back to the home list.
extern NSString* const kLibraryHome;
@interface LibraryPanelView : NSView
@property(nonatomic, copy) NSArray<NSDictionary*>* (^sectionsProvider)(void);    // @{id,title,symbol,count}
@property(nonatomic, copy) NSArray<LibraryEntry*>* (^entriesProvider)(NSString* sectionID);
@property(nonatomic, copy) NSString* section;  // kLibraryHome, @"archive", or a section id from sectionsProvider
- (void)openSection:(NSString*)sectionID;
- (NSString*)homeDescription;            // tests: the home list's headings and section rows
@property(nonatomic, copy) NSArray<ArchivedTab*>* (^archiveProvider)(void);
@property(nonatomic, copy) void (^reopen)(ArchivedTab* tab);
@property(nonatomic, copy) NSImage* (^iconForURL)(NSString* url);
@property(nonatomic, copy) void (^back)(void);
@property(nonatomic, strong) NSColor* textColor;  // the Space's tab text colour
- (void)reload;
- (void)focusSearch;
- (void)setQuery:(NSString*)query;      // tests
- (NSUInteger)visibleCount;              // archived tabs shown (not counting headings)
- (NSArray<NSString*>*)groupTitles;      // tests
- (NSString*)styleDescription;           // tests: layout of the header, search field and rows
- (void)openRowForTest:(NSUInteger)index;  // tests: click the n-th non-heading row
@end
