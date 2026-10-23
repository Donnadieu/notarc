// Downloads (Arc: Library > Downloads). Files save straight into the download folder (Settings),
// with a numbered name if one already exists. The Downloads window (Cmd+Shift+J) lists them with
// progress, filter, Open, Show in Finder, Copy and Cancel. Quitting asks first while any are in progress.
#pragma once

#import <Cocoa/Cocoa.h>

extern NSString* const kSettingDownloadFolder;  // path; default ~/Downloads

typedef NS_ENUM(NSInteger, DownloadState) { DownloadInProgress, DownloadComplete, DownloadCanceled, DownloadFailed };

@interface DownloadEntry : NSObject
@property(nonatomic) uint32_t cefId;
@property(nonatomic, copy) NSString* url;
@property(nonatomic, copy) NSString* path;
@property(nonatomic) int64_t received, total, speed;
@property(nonatomic) DownloadState state;
@property(nonatomic, strong) NSDate* started;
@property(nonatomic, readonly) NSString* fileName;
@property(nonatomic, readonly) NSString* statusText;  // "3.1 of 10 MB, 2 MB/s", "Cancelled", ...
@end

@interface DownloadManager : NSObject
+ (instancetype)shared;
@property(nonatomic, copy) NSString* folderOverride;  // self-test only
@property(nonatomic, readonly) NSArray<DownloadEntry*>* entries;  // newest first
@property(nonatomic, copy) void (^onChange)(void);
- (NSString*)folder;
- (NSString*)destinationForSuggestedName:(NSString*)name;  // unique path in folder
- (void)begin:(uint32_t)cefId url:(NSString*)url path:(NSString*)path;
- (void)update:(uint32_t)cefId received:(int64_t)received total:(int64_t)total speed:(int64_t)speed
          path:(NSString*)path state:(DownloadState)state;
- (void)cancel:(DownloadEntry*)entry;
- (NSUInteger)inProgressCount;
- (void)showWindow;
- (void)clearFinished;
// Filter used by the window (name or URL, case-insensitive).
- (NSArray<DownloadEntry*>*)entriesMatching:(NSString*)query;
@end

// C++ side: the download handler calls these on the UI thread.
#ifdef __cplusplus
#include "include/cef_download_handler.h"
std::string DownloadsDestination(const std::string& suggested_name);
void DownloadsUpdated(CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback);
#endif
