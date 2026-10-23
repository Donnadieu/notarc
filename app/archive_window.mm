#import "app/archive_window.h"

@interface ArchiveWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@implementation ArchiveWindowController {
  NSArray<ArchivedTab*>* (^_provider)(void);
  void (^_reopen)(ArchivedTab*);
  NSSearchField* _search;
  NSTableView* _table;
  NSArray<ArchivedTab*>* _rows;
  NSDateFormatter* _dates;
}

- (instancetype)initWithProvider:(NSArray<ArchivedTab*>* (^)(void))provider reopen:(void (^)(ArchivedTab*))reopen {
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 520)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  w.title = @"Archive";
  w.releasedWhenClosed = NO;
  [w center];
  if ((self = [super initWithWindow:w])) {
    _provider = [provider copy];
    _reopen = [reopen copy];
    _dates = [NSDateFormatter new];
    _dates.dateStyle = NSDateFormatterShortStyle;
    _dates.timeStyle = NSDateFormatterShortStyle;
    NSView* root = w.contentView;
    _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(12, 484, 736, 24)];
    _search.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    _search.placeholderString = @"Search archived tabs";
    _search.delegate = self;
    [root addSubview:_search];
    NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 760, 474)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
    for (NSArray* c in @[ @[ @"title", @"Title", @430 ], @[ @"date", @"Archived", @150 ], @[ @"reason", @"How", @80 ] ]) {
      NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
      col.title = c[1];
      col.width = [c[2] doubleValue];
      [_table addTableColumn:col];
    }
    _table.dataSource = self;
    _table.delegate = self;
    _table.target = self;
    _table.doubleAction = @selector(reopenSelected:);
    scroll.documentView = _table;
    [root addSubview:scroll];
    [self reload];
  }
  return self;
}

- (void)reload {
  _rows = ArchiveSearch(_provider(), _search.stringValue);
  [_table reloadData];
  self.window.title =
      [NSString stringWithFormat:@"%@ (%lu)", self.baseTitle ?: @"Archive", (unsigned long)_rows.count];
}

- (void)setPlaceholder:(NSString*)placeholder dateHeader:(NSString*)dateHeader reasonHeader:(NSString*)reasonHeader {
  _search.placeholderString = placeholder;
  [_table tableColumnWithIdentifier:@"date"].title = dateHeader;
  [_table tableColumnWithIdentifier:@"reason"].title = reasonHeader;
  [_table tableColumnWithIdentifier:@"reason"].width = 140;
  [self reload];
}

- (void)setQuery:(NSString*)query {
  _search.stringValue = query ?: @"";
  [self reload];
}

- (NSUInteger)visibleCount { return _rows.count; }

- (void)controlTextDidChange:(NSNotification*)note { [self reload]; }

- (BOOL)control:(NSControl*)control textView:(NSTextView*)tv doCommandBySelector:(SEL)cmd {
  if (cmd == @selector(insertNewline:) && _rows.count) {
    if (_table.selectedRow < 0) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self reopenSelected:nil];
    return YES;
  }
  return NO;
}

- (void)reopenSelected:(id)sender {
  NSInteger row = _table.clickedRow >= 0 ? _table.clickedRow : _table.selectedRow;
  if (row < 0 || row >= (NSInteger)_rows.count) return;
  _reopen(_rows[row]);
  [self reload];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv { return _rows.count; }

- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  NSTextField* f = [tv makeViewWithIdentifier:col.identifier owner:self];
  if (!f) {
    f = [NSTextField labelWithString:@""];
    f.identifier = col.identifier;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
  }
  ArchivedTab* t = _rows[row];
  if ([col.identifier isEqualToString:@"title"]) {
    f.stringValue = t.title.length ? t.title : t.url;
    f.toolTip = t.url;
  } else if ([col.identifier isEqualToString:@"date"]) {
    f.stringValue = [_dates stringFromDate:t.archivedAt];
  } else {
    f.stringValue = t.reason ?: @"";
  }
  return f;
}
@end
