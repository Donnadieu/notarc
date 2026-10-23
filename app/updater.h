// Updates from GitHub Releases, without a paid Apple Developer ID.
// Checks releases/latest once a day (and from the app menu), downloads the DMG, verifies it against
// the release's .sha256 file, copies NotArc.app out of it and swaps it in after NotArc quits.
// The download is made by NotArc itself, so it carries no quarantine flag and needs no right-click > Open.
#pragma once

#import <Foundation/Foundation.h>

// -1, 0, 1 like strcmp; "v0.10.0" > "0.9.3". Non-numeric parts count as 0.
int UpdaterCompareVersions(NSString* a, NSString* b);
NSString* UpdaterCurrentVersion(void);

@interface UpdateInfo : NSObject
@property(nonatomic, copy) NSString* version;
@property(nonatomic, copy) NSURL* dmgURL;
@property(nonatomic, copy) NSURL* sha256URL;
@property(nonatomic, copy) NSString* notes;
@end

@interface Updater : NSObject
+ (instancetype)shared;
@property(nonatomic, copy) NSString* feedURL;  // GitHub API releases/latest
// Parses a GitHub "release" JSON object; nil when there is no arm64 DMG.
+ (UpdateInfo*)infoFromReleaseJSON:(NSDictionary*)json;
- (void)fetchLatest:(void (^)(UpdateInfo* info, NSError* error))done;
// Downloads, verifies the checksum and extracts NotArc.app into a staging folder; returns its path.
- (void)prepareUpdate:(UpdateInfo*)info done:(void (^)(NSString* stagedApp, NSError* error))done;
// Replaces the running bundle with stagedApp after this process exits, then relaunches it.
- (void)installStagedApp:(NSString*)stagedApp;
// Menu / timer entry points. interactive = say "you're up to date" and show errors.
- (void)checkInteractive:(BOOL)interactive;
- (void)scheduleDailyChecks;
@end
