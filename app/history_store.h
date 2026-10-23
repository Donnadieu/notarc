// Browsing history (Arc: Cmd+Y). Each top-level navigation is one visit; a later title change
// updates the newest visit of that URL. Capped so the file stays small.
#pragma once

#import <Foundation/Foundation.h>

#import "app/archive_store.h"

@interface HistoryStore : NSObject
- (instancetype)initWithPath:(NSString*)path;
// Rows reuse ArchivedTab: archivedAt = visit time, reason = Space name.
@property(nonatomic, readonly) NSArray<ArchivedTab*>* visits;  // oldest first
- (void)recordURL:(NSString*)url title:(NSString*)title space:(NSString*)space;
- (void)updateTitle:(NSString*)title forURL:(NSString*)url;
- (void)clear;
- (void)saveNow;
@end

NSString* HistoryStorePath(BOOL selfTest);
