// The sidebar's Library panel (Arc: the Library button at the bottom left). It takes the place of the Space's
// tabs inside the sidebar, under the address pill and above the bottom bar, and goes away with Back, Esc or a
// Space switch. First section: Archive, a searchable list of archived tabs grouped by when they were archived.
#pragma once

#import <Cocoa/Cocoa.h>

#import "app/archive_store.h"

// Group headings for an archive list, newest first: "Today", "Yesterday", weekday names for the last week, then
// "Last Week", then month names ("October", or "October 2025" for another year). Pure, for tests.
NSString* ArchiveGroupTitle(NSDate* when, NSDate* now, NSCalendar* calendar);

@interface LibraryPanelView : NSView
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
@end
