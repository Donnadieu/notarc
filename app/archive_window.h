// Archive browser (Arc: Library > Archive): searchable list, double-click or Return reopens.
#pragma once

#import <Cocoa/Cocoa.h>

#import "app/archive_store.h"

@interface ArchiveWindowController : NSWindowController
- (instancetype)initWithProvider:(NSArray<ArchivedTab*>* (^)(void))provider
                          reopen:(void (^)(ArchivedTab* tab))reopen;
// History reuses this window with its own labels.
@property(nonatomic, copy) NSString* baseTitle;  // default "Archive"
- (void)setPlaceholder:(NSString*)placeholder dateHeader:(NSString*)dateHeader reasonHeader:(NSString*)reasonHeader;
- (void)reload;
- (void)setQuery:(NSString*)query;     // for tests
- (NSUInteger)visibleCount;
@end
