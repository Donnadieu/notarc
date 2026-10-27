// Read-only reader for Arc's browsing history (Chromium "History" database: urls + visits), used by
// File > Import from Arc. No Keychain access needed: history isn't encrypted.
#pragma once

#import <Foundation/Foundation.h>

#import "app/archive_store.h"

// The newest `limit` top-level visits (oldest first), each tagged with `spaceName` in `reason`.
// Redirect hops and subframe loads are skipped. Returns nil if the database can't be read.
NSArray<ArchivedTab*>* ArcReadHistory(NSString* dbPath, NSString* spaceName, NSUInteger limit, NSError** error);
NSString* ArcHistoryDBPath(NSString* profileDirectory);  // .../Arc/User Data/<profile>/History
