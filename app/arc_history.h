// Read-only reader for Arc's browsing history (Chromium "History" database: urls + visits), used by
// File > Import from Arc. No Keychain access needed: history isn't encrypted.
#pragma once

#import <Foundation/Foundation.h>

#import "app/archive_store.h"

// The newest `limit` top-level visits (oldest first), each tagged with `spaceName` in `reason`.
// Redirect hops and subframe loads are skipped. Returns nil if the database can't be read.
NSArray<ArchivedTab*>* ArcReadHistory(NSString* dbPath, NSString* spaceName, NSUInteger limit, NSError** error);
NSString* ArcHistoryDBPath(NSString* profileDirectory);
// Other browsers' history (#63), same read-only way. Firefox: places.sqlite. Safari: History.db (macOS only lets
// NotArc read it with Full Disk Access; without it this returns nil).
NSArray<ArchivedTab*>* FirefoxReadHistory(NSString* dbPath, NSString* name, NSUInteger limit, NSError** error);
NSArray<ArchivedTab*>* SafariReadHistory(NSString* dbPath, NSString* name, NSUInteger limit, NSError** error);  // .../Arc/User Data/<profile>/History
