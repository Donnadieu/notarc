// Archive browser (Arc: Library > Archive): searchable list, double-click or Return reopens.
#pragma once

#import <Cocoa/Cocoa.h>

#import "app/archive_store.h"

@interface ArchiveWindowController : NSWindowController
- (instancetype)initWithProvider:(NSArray<ArchivedTab*>* (^)(void))provider
                          reopen:(void (^)(ArchivedTab* tab))reopen;
- (void)reload;
- (void)setQuery:(NSString*)query;     // for tests
- (NSUInteger)visibleCount;
@end
