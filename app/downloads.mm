#import "app/downloads.h"

#include <map>

NSString* const kSettingDownloadFolder = @"downloadFolder";

static std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> g_callbacks;

static NSString* Bytes(int64_t n) {
  return [NSByteCountFormatter stringFromByteCount:n countStyle:NSByteCountFormatterCountStyleFile];
}

@implementation DownloadEntry
- (NSString*)fileName { return self.path.lastPathComponent ?: self.url.lastPathComponent; }
- (NSString*)statusText {
  switch (self.state) {
    case DownloadComplete: return Bytes(self.total > 0 ? self.total : self.received);
    case DownloadCanceled: return @"Cancelled";
    case DownloadFailed: return @"Failed";
    case DownloadInProgress: {
      NSString* s = self.total > 0 ? [NSString stringWithFormat:@"%@ of %@", Bytes(self.received), Bytes(self.total)]
                                   : Bytes(self.received);
      return self.speed > 0 ? [NSString stringWithFormat:@"%@, %@/s", s, Bytes(self.speed)] : s;
    }
  }
}
@end

@interface DownloadsWindowController : NSWindowController <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSMenuDelegate>
- (void)reload;
@end

@implementation DownloadManager {
  NSMutableArray<DownloadEntry*>* _entries;
  DownloadsWindowController* _window;
}

+ (instancetype)shared {
  static DownloadManager* m;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    m = [DownloadManager new];
    m->_entries = [NSMutableArray array];
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
      kSettingDownloadFolder : [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject]
    }];
  });
  return m;
}

- (NSArray<DownloadEntry*>*)entries { return _entries; }

- (NSString*)folder {
  NSString* f = self.folderOverride ?: [NSUserDefaults.standardUserDefaults stringForKey:kSettingDownloadFolder];
  [NSFileManager.defaultManager createDirectoryAtPath:f withIntermediateDirectories:YES attributes:nil error:nil];
  return f;
}

- (NSString*)destinationForSuggestedName:(NSString*)name {
  name = [[name stringByReplacingOccurrencesOfString:@"/" withString:@"_"] stringByReplacingOccurrencesOfString:@":" withString:@"_"];
  if (!name.length || [name hasPrefix:@"."]) name = [@"download" stringByAppendingString:name ?: @""];
  NSString* dir = [self folder];
  NSString* base = name.stringByDeletingPathExtension, *ext = name.pathExtension;
  NSString* path = [dir stringByAppendingPathComponent:name];
  NSMutableSet* taken = [NSMutableSet set];
  for (DownloadEntry* e in _entries) if (e.state == DownloadInProgress && e.path) [taken addObject:e.path];
  for (int i = 1; [NSFileManager.defaultManager fileExistsAtPath:path] || [taken containsObject:path]; ++i) {
    NSString* n = [NSString stringWithFormat:@"%@ (%d)", base, i];
    path = [dir stringByAppendingPathComponent:ext.length ? [n stringByAppendingPathExtension:ext] : n];
  }
  return path;
}

- (DownloadEntry*)entry:(uint32_t)cefId {
  for (DownloadEntry* e in _entries) if (e.cefId == cefId) return e;
  return nil;
}

- (void)changed {
  [_window reload];
  if (self.onChange) self.onChange();
}

- (void)begin:(uint32_t)cefId url:(NSString*)url path:(NSString*)path {
  DownloadEntry* e = [self entry:cefId];
  if (!e) {
    e = [DownloadEntry new];
    e.cefId = cefId;
    e.started = [NSDate date];
    [_entries insertObject:e atIndex:0];
  }
  e.url = url;
  e.path = path;
  e.state = DownloadInProgress;
  [self changed];
}

- (void)update:(uint32_t)cefId received:(int64_t)received total:(int64_t)total speed:(int64_t)speed
          path:(NSString*)path state:(DownloadState)state {
  DownloadEntry* e = [self entry:cefId];
  if (!e) return;
  e.received = received;
  e.total = total;
  e.speed = speed;
  if (path.length) e.path = path;
  DownloadState was = e.state;
  e.state = state;
  if (state != DownloadInProgress) g_callbacks.erase(cefId);
  if (was == DownloadInProgress && state == DownloadComplete && e.path)
    [NSDistributedNotificationCenter.defaultCenter postNotificationName:@"com.apple.DownloadFileFinished"
                                                                 object:e.path];  // bounces the Dock's Downloads stack
  [self changed];
}

- (void)cancel:(DownloadEntry*)entry {
  auto it = g_callbacks.find(entry.cefId);
  if (it != g_callbacks.end()) it->second->Cancel();
}

- (NSUInteger)inProgressCount {
  NSUInteger n = 0;
  for (DownloadEntry* e in _entries) n += e.state == DownloadInProgress;
  return n;
}

- (void)clearFinished {
  [_entries filterUsingPredicate:[NSPredicate predicateWithFormat:@"state == %d", DownloadInProgress]];
  [self changed];
}

- (NSArray<DownloadEntry*>*)entriesMatching:(NSString*)query {
  if (!query.length) return _entries;
  return [_entries filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(DownloadEntry* e, NSDictionary*) {
    return [e.fileName localizedCaseInsensitiveContainsString:query] || [e.url localizedCaseInsensitiveContainsString:query];
  }]];
}

- (void)showWindow {
  if (!_window) _window = [DownloadsWindowController new];
  [_window reload];
  [_window showWindow:nil];
  [_window.window makeKeyAndOrderFront:nil];
}
@end

std::string DownloadsDestination(const std::string& suggested_name) {
  return [[DownloadManager shared] destinationForSuggestedName:[NSString stringWithUTF8String:suggested_name.c_str()]].UTF8String;
}

void DownloadsUpdated(CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback) {
  DownloadManager* m = [DownloadManager shared];
  uint32_t cefId = item->GetId();
  if (item->IsInProgress()) g_callbacks[cefId] = callback;
  if (![m entry:cefId])
    [m begin:cefId url:[NSString stringWithUTF8String:item->GetURL().ToString().c_str()]
         path:[NSString stringWithUTF8String:item->GetFullPath().ToString().c_str()]];
  if (item->IsInterrupted() && getenv("NOTARC_DOWNLOAD_DEBUG"))
    fprintf(stderr, "DOWNLOAD-INTERRUPTED id=%u reason=%d path=%s\n", cefId, (int)item->GetInterruptReason(),
            item->GetFullPath().ToString().c_str());
  DownloadState state = item->IsComplete()      ? DownloadComplete
                        : item->IsCanceled()    ? DownloadCanceled
                        : item->IsInterrupted() ? DownloadFailed
                                                : DownloadInProgress;
  [m update:cefId received:item->GetReceivedBytes() total:item->GetTotalBytes() speed:item->GetCurrentSpeed()
       path:[NSString stringWithUTF8String:item->GetFullPath().ToString().c_str()] state:state];
}

@implementation DownloadsWindowController {
  NSSearchField* _search;
  NSTableView* _table;
  NSArray<DownloadEntry*>* _rows;
}

- (instancetype)init {
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, 420)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  w.releasedWhenClosed = NO;
  [w center];
  if (!(self = [super initWithWindow:w])) return nil;
  NSView* root = w.contentView;
  _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, 384, 500, 24)];
  _search.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  _search.placeholderString = @"Filter Downloads";
  _search.delegate = self;
  [root addSubview:_search];
  NSButton* clear = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearFinished:)];
  clear.frame = NSMakeRect(522, 382, 86, 28);
  clear.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  [root addSubview:clear];
  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 620, 374)];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
  for (NSArray* c in @[ @[ @"name", @"Name", @330 ], @[ @"status", @"Status", @180 ], @[ @"progress", @"", @90 ] ]) {
    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.title = c[1];
    col.width = [c[2] doubleValue];
    [_table addTableColumn:col];
  }
  _table.dataSource = self;
  _table.delegate = self;
  _table.target = self;
  _table.doubleAction = @selector(openClicked:);
  _table.menu = [NSMenu new];
  _table.menu.delegate = self;
  scroll.documentView = _table;
  [root addSubview:scroll];
  return self;
}

- (void)reload {
  _rows = [[DownloadManager shared] entriesMatching:_search.stringValue];
  [_table reloadData];
  NSUInteger active = [DownloadManager shared].inProgressCount;
  self.window.title = active ? [NSString stringWithFormat:@"Downloads (%lu in progress)", (unsigned long)active] : @"Downloads";
}

- (void)controlTextDidChange:(NSNotification*)n { [self reload]; }
- (void)clearFinished:(id)sender { [[DownloadManager shared] clearFinished]; }

- (DownloadEntry*)clickedEntry {
  NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
  return row >= 0 && row < (NSInteger)_rows.count ? _rows[row] : nil;
}

- (void)openClicked:(id)sender {
  DownloadEntry* e = [self clickedEntry];
  if (e.state == DownloadComplete) [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:e.path]];
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  [menu removeAllItems];
  DownloadEntry* e = [self clickedEntry];
  if (!e) return;
  if (e.state == DownloadComplete) {
    [menu addItemWithTitle:@"Open" action:@selector(openClicked:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Show in Finder" action:@selector(reveal:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Copy" action:@selector(copyFile:) keyEquivalent:@""].target = self;
  }
  [menu addItemWithTitle:@"Copy Download Link" action:@selector(copyLink:) keyEquivalent:@""].target = self;
  if (e.state == DownloadInProgress)
    [menu addItemWithTitle:@"Cancel" action:@selector(cancelDownload:) keyEquivalent:@""].target = self;
}

- (void)reveal:(id)sender {
  [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[ [NSURL fileURLWithPath:[self clickedEntry].path] ]];
}
- (void)copyFile:(id)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard writeObjects:@[ [NSURL fileURLWithPath:[self clickedEntry].path] ]];
}
- (void)copyLink:(id)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[self clickedEntry].url forType:NSPasteboardTypeString];
}
- (void)cancelDownload:(id)sender { [[DownloadManager shared] cancel:[self clickedEntry]]; }

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv { return _rows.count; }

- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  DownloadEntry* e = _rows[row];
  if ([col.identifier isEqualToString:@"progress"]) {
    NSProgressIndicator* p = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(0, 0, 80, 16)];
    p.style = NSProgressIndicatorStyleBar;
    p.indeterminate = e.state == DownloadInProgress && e.total <= 0;
    p.minValue = 0;
    p.maxValue = 1;
    p.doubleValue = e.state == DownloadComplete ? 1 : e.total > 0 ? (double)e.received / e.total : 0;
    p.hidden = e.state != DownloadInProgress;
    if (p.indeterminate) [p startAnimation:nil];
    return p;
  }
  NSTextField* f = [NSTextField labelWithString:@""];
  f.lineBreakMode = NSLineBreakByTruncatingMiddle;
  if ([col.identifier isEqualToString:@"name"]) {
    f.stringValue = e.fileName ?: @"";
    f.toolTip = e.url;
  } else {
    f.stringValue = e.statusText;
    f.textColor = NSColor.secondaryLabelColor;
  }
  return f;
}
@end
