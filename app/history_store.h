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
- (NSUInteger)clearSince:(NSDate*)since;  // removes visits at or after `since`; returns how many
- (void)saveNow;
// Adds visits from another browser, keeping time order; visits already present (same URL and second) are skipped,
// and only the newest kMaxVisits are kept. Returns how many were added.
- (NSUInteger)mergeVisits:(NSArray<ArchivedTab*>*)visits;
@end

NSString* HistoryStorePath(BOOL selfTest);
