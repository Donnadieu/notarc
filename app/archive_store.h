// Archived tabs (Arc: StorableArchiveItems.json). Auto-archive closes Today tabs that have been
// inactive longer than the threshold; Arc's options are 6h, 12h (default), 24h, 7d, 30d, never.
#pragma once

#import <Foundation/Foundation.h>

@interface ArchivedTab : NSObject
@property(nonatomic, copy) NSString* url;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* spaceID;
@property(nonatomic, copy) NSString* reason;  // "auto" | "manual"
@property(nonatomic, strong) NSDate* archivedAt;
@end

NSString* ArchiveStorePath(BOOL selfTest);
NSMutableArray<ArchivedTab*>* ArchiveStoreLoad(NSString* path);
BOOL ArchiveStoreSave(NSArray<ArchivedTab*>* tabs, NSString* path);
// Threshold in seconds from user defaults key "autoArchiveThresholdHours" (0 = never). Default 12h.
NSTimeInterval AutoArchiveThreshold(void);
// Arc's StorableArchiveItems.json -> our archive entries (oldest first). Read-only.
NSMutableArray<ArchivedTab*>* ArchiveImportArc(NSString* arcArchivePath);
// Case-insensitive match on title or URL; newest first. Empty query = everything.
NSArray<ArchivedTab*>* ArchiveSearch(NSArray<ArchivedTab*>* tabs, NSString* query);
