// Arc's installed Chrome extensions -> NotArc (#66/#150). Copies each extension's newest version folder out of
// Arc's profiles (read-only on Arc's side) into NotArc's own folder, keyed by extension ID. The manifest "key"
// keeps the same ID, so settings can follow later. Manifest V2 extensions are skipped (Chromium no longer runs them).
#pragma once

#import <Foundation/Foundation.h>

@interface ArcExtensionCopy : NSObject
@property(nonatomic, copy) NSString* extensionID;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* path;  // NotArc's copy
@property(nonatomic) BOOL skippedMV2;
@end

// Arc's "User Data" root (or a test fake) and the profiles to read ("Profile 2", ...). Existing copies are refreshed.
NSArray<ArcExtensionCopy*>* ArcCopyExtensions(NSString* arcUserData, NSArray<NSString*>* profiles, NSString* destination);
// Folders already copied (one per extension), for loading at startup.
NSArray<NSString*>* ArcCopiedExtensionPaths(NSString* destination);
NSString* NotArcExtensionsDirectory(BOOL selfTest);
