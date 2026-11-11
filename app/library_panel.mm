// The sidebar's Library panel. See library_panel.h.
#import "app/library_panel.h"

#import <QuartzCore/QuartzCore.h>
#include <initializer_list>

NSString* ArchiveGroupTitle(NSDate* when, NSDate* now, NSCalendar* cal) {
  if (!when) return @"Earlier";
  NSDate* today = [cal startOfDayForDate:now];
  NSDate* day = [cal startOfDayForDate:when];
  NSInteger days = [cal components:NSCalendarUnitDay fromDate:day toDate:today options:0].day;
  if (days <= 0) return @"Today";
  if (days == 1) return @"Yesterday";
  NSDateFormatter* f = [NSDateFormatter new];
  f.calendar = cal;
  f.locale = NSLocale.currentLocale;
  if (days < 7) {
    f.dateFormat = @"EEEE";
    return [f stringFromDate:when];
  }
  if (days < 14) return @"Last Week";
  BOOL sameYear = [cal component:NSCalendarUnitYear fromDate:when] == [cal component:NSCalendarUnitYear fromDate:now];
  f.dateFormat = sameYear ? @"LLLL" : @"LLLL yyyy";
  return [f stringFromDate:when];
}

NSString* const kLibraryHome = @"home";

static BOOL PanelIsDark(NSView* v) {
  return [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
         NSAppearanceNameDarkAqua;
}

@implementation LibraryEntry
- (instancetype)init {
  if ((self = [super init])) _progress = -1;
  return self;
}
+ (instancetype)entry:(NSString*)title detail:(NSString*)detail icon:(NSImage*)icon open:(void (^)(void))open {
  LibraryEntry* e = [LibraryEntry new];
  e.title = title;
  e.detail = detail;
  e.icon = icon;
  e.open = open;
  return e;
}
@end

@implementation DownloadCardView {
  BOOL _solid, _hover;
  NSImageView* _icon;
  NSTextField* _name;
  NSTextField* _status;
  NSView* _barTrack;
  NSView* _barFill;
  double _progress;
  void (^_open)(void);
}
- (instancetype)initWithFrame:(NSRect)frame solid:(BOOL)solid {
  if (!(self = [super initWithFrame:frame])) return nil;
  _solid = solid;
  self.wantsLayer = YES;
  self.layer.cornerRadius = 8;
  _icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
  _icon.imageScaling = NSImageScaleProportionallyUpOrDown;
  _name = [NSTextField labelWithString:@""];
  _name.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  _name.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _status = [NSTextField labelWithString:@""];
  _status.font = [NSFont systemFontOfSize:11];
  _barTrack = [NSView new];
  _barTrack.wantsLayer = YES;
  _barTrack.layer.cornerRadius = 1.5;
  _barFill = [NSView new];
  _barFill.wantsLayer = YES;
  _barFill.layer.cornerRadius = 1.5;
  [_barTrack addSubview:_barFill];
  for (NSView* v in @[ _icon, _name, _status, _barTrack ]) [self addSubview:v];
  self.identifier = @"downloadCard";
  return self;
}
- (BOOL)hasProgressBar { return !_barTrack.hidden; }
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)e { _hover = YES; [self applyFill]; }
- (void)mouseExited:(NSEvent*)e { _hover = NO; [self applyFill]; }
- (void)mouseUp:(NSEvent*)e { if (_open && e.clickCount == 1) _open(); }
- (void)viewDidChangeEffectiveAppearance { [super viewDidChangeEffectiveAppearance]; [self applyFill]; }
- (void)applyFill {
  BOOL dark = PanelIsDark(self);
  NSColor* c;
  if (_solid)  // Arc 1.169: DownloadItemBackground white / 0.05, Hovered 0.96 / 0.12
    c = dark ? [NSColor colorWithWhite:_hover ? 0.12 : 0.05 alpha:1] : [NSColor colorWithWhite:_hover ? 0.96 : 1 alpha:1];
  else
    c = dark ? [NSColor colorWithWhite:1 alpha:_hover ? 0.14 : 0.07] : [NSColor colorWithWhite:1 alpha:_hover ? 0.75 : 0.45];
  self.layer.backgroundColor = c.CGColor;
  _barTrack.layer.backgroundColor = [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.12].CGColor;
  _barFill.layer.backgroundColor = NSColor.controlAccentColor.CGColor;
}
- (void)showEntry:(LibraryEntry*)e textColor:(NSColor*)tc {
  tc = tc ?: NSColor.labelColor;
  _icon.image = e.icon;
  _name.stringValue = e.title ?: @"";
  _name.textColor = tc;
  _status.stringValue = e.detail ?: @"";
  _status.textColor = [tc colorWithAlphaComponent:0.5];
  _progress = e.progress;
  _barTrack.hidden = e.progress < 0;
  _open = [e.open copy];
  self.toolTip = e.searchText;
  self.needsLayout = YES;
  [self applyFill];
}
- (void)layout {
  [super layout];
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  _icon.frame = NSMakeRect(10, (H - 28) / 2, 28, 28);
  BOOL bar = !_barTrack.hidden;
  _name.frame = NSMakeRect(46, H / 2 + (bar ? 3 : 1), W - 56, 17);
  _status.frame = NSMakeRect(46, H / 2 - (bar ? 13 : 16), W - 56, 14);
  _barTrack.frame = NSMakeRect(46, 8, W - 58, 3);
  _barFill.frame = NSMakeRect(0, 0, round((W - 58) * MAX(0.02, MIN(1, _progress))), 3);
}
@end

// A home-list row that opens a section.
@interface LibrarySectionRow : NSObject
@property(nonatomic, copy) NSDictionary* info;
@end
@implementation LibrarySectionRow
@end


// Same scroller rule as the sidebar: never a track.
@interface LibraryScrollView : NSScrollView
@end
@implementation LibraryScrollView
- (void)setScrollerStyle:(NSScrollerStyle)style { [super setScrollerStyle:NSScrollerStyleOverlay]; }
@end

@interface LibraryRowView : NSTableRowView
@property(nonatomic) BOOL hovered;
@property(nonatomic) BOOL heading;
@end
@implementation LibraryRowView
- (void)drawBackgroundInRect:(NSRect)r {}
- (void)drawSelectionInRect:(NSRect)r {}
- (void)drawRect:(NSRect)r {
  if (self.heading || !(self.hovered || self.selected)) return;
  BOOL dark = PanelIsDark(self);
  // Arc's sidebar hover / selected fills (same values as the tab rows).
  NSColor* c = self.selected ? (dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.20] : [NSColor colorWithWhite:1 alpha:0.85])
                             : (dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.12] : [NSColor colorWithWhite:1 alpha:0.50]);
  [c setFill];
  [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0, 2.5) xRadius:8 yRadius:8] fill];
}
@end

@interface LibraryTableView : NSTableView
@property(nonatomic) NSInteger hoveredRow;
@end
@implementation LibraryTableView
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                             NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
}
- (void)setHover:(NSInteger)row {
  if (row == self.hoveredRow) return;
  for (NSInteger r : {self.hoveredRow, row}) {
    LibraryRowView* rv = r >= 0 && r < self.numberOfRows ? (LibraryRowView*)[self rowViewAtRow:r makeIfNecessary:NO] : nil;
    if ([rv isKindOfClass:LibraryRowView.class]) {
      rv.hovered = r == row;
      rv.needsDisplay = YES;
    }
  }
  self.hoveredRow = row;
}
- (void)mouseMoved:(NSEvent*)e { [self setHover:[self rowAtPoint:[self convertPoint:e.locationInWindow fromView:nil]]]; }
- (void)mouseExited:(NSEvent*)e { [self setHover:-1]; }
@end

@interface LibraryPanelView () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate>
@end

@implementation LibraryPanelView {
  NSButton* _backButton;
  NSTextField* _title;
  NSView* _searchBox;
  NSTextField* _search;
  NSImageView* _searchIcon;
  LibraryScrollView* _scroll;
  LibraryTableView* _table;
  NSTextField* _emptyTitle;
  NSTextField* _emptyText;
  NSArray* _rows;  // NSString headings and ArchivedTab entries, in display order
  NSUInteger _count;
  NSDateFormatter* _timeFormat;
  NSDateFormatter* _dayFormat;
  NSString* _section;
  BOOL _cameFromHome;
}

static const CGFloat kHeaderH = 34, kSearchH = 32, kRowH = 41, kHeadingH = 30;

- (instancetype)initWithFrame:(NSRect)frame {
  if (!(self = [super initWithFrame:frame])) return nil;
  self.autoresizingMask = NSViewHeightSizable;
  _textColor = NSColor.labelColor;
  _backButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"chevron.left" accessibilityDescription:@"Back"]
                                   target:self action:@selector(backClicked:)];
  _backButton.bordered = NO;
  _backButton.toolTip = @"Back to Tabs";
  _backButton.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightSemibold];
  [self addSubview:_backButton];
  _section = @"archive";
  _title = [NSTextField labelWithString:@"Archive"];
  _title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  [self addSubview:_title];

  _searchBox = [[NSView alloc] initWithFrame:NSZeroRect];
  _searchBox.wantsLayer = YES;
  _searchBox.layer.cornerRadius = 8;
  [self addSubview:_searchBox];
  _searchIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil]];
  _searchIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
  [_searchBox addSubview:_searchIcon];
  _search = [NSTextField textFieldWithString:@""];
  _search.bezeled = NO;
  _search.drawsBackground = NO;
  _search.focusRingType = NSFocusRingTypeNone;
  _search.font = [NSFont systemFontOfSize:13];
  _search.placeholderString = @"Search Archive";
  _search.delegate = self;
  _search.cell.scrollable = YES;
  [_searchBox addSubview:_search];

  _table = [[LibraryTableView alloc] initWithFrame:NSZeroRect];
  _table.hoveredRow = -1;
  NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"a"];
  col.resizingMask = NSTableColumnAutoresizingMask;
  [_table addTableColumn:col];
  _table.headerView = nil;
  _table.backgroundColor = NSColor.clearColor;
  _table.style = NSTableViewStylePlain;
  _table.intercellSpacing = NSZeroSize;
  _table.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  _table.dataSource = self;
  _table.delegate = self;
  _table.target = self;
  _table.action = @selector(rowClicked:);
  _scroll = [[LibraryScrollView alloc] initWithFrame:NSZeroRect];
  _scroll.documentView = _table;
  _scroll.drawsBackground = NO;
  _scroll.hasVerticalScroller = YES;
  _scroll.autohidesScrollers = YES;
  _scroll.scrollerStyle = NSScrollerStyleOverlay;
  _scroll.automaticallyAdjustsContentInsets = NO;
  [self addSubview:_scroll];

  _emptyTitle = [NSTextField labelWithString:@"Nothing archived yet"];
  _emptyTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  _emptyTitle.alignment = NSTextAlignmentCenter;
  [self addSubview:_emptyTitle];
  _emptyText = [NSTextField wrappingLabelWithString:@"Tabs you close, and Today tabs you leave alone for a while, land here."];
  _emptyText.font = [NSFont systemFontOfSize:12];
  _emptyText.alignment = NSTextAlignmentCenter;
  [self addSubview:_emptyText];

  _timeFormat = [NSDateFormatter new];
  _timeFormat.timeStyle = NSDateFormatterShortStyle;
  _timeFormat.dateStyle = NSDateFormatterNoStyle;
  _dayFormat = [NSDateFormatter new];
  [_dayFormat setLocalizedDateFormatFromTemplate:@"MMMd"];
  return self;
}

- (BOOL)isFlipped { return NO; }

- (void)layout {
  [super layout];
  CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
  BOOL home = [_section isEqual:kLibraryHome];
  _backButton.frame = NSMakeRect(2, H - kHeaderH + 5, 24, 24);
  _title.frame = home ? NSMakeRect(10, H - kHeaderH + 8, W - 20, 18) : NSMakeRect(28, H - kHeaderH + 8, W - 36, 18);
  _backButton.hidden = home;
  _searchBox.hidden = home;
  _searchBox.frame = NSMakeRect(0, H - kHeaderH - kSearchH - 2, W - 2, kSearchH);
  _searchIcon.frame = NSMakeRect(10, (kSearchH - 16) / 2, 16, 16);
  _search.frame = NSMakeRect(32, (kSearchH - 18) / 2, W - 2 - 40, 18);
  CGFloat top = home ? H - kHeaderH - 4 : H - kHeaderH - kSearchH - 10;
  _scroll.frame = NSMakeRect(0, 0, W, MAX(0, top));
  _table.tableColumns.firstObject.width = W;
  _emptyTitle.frame = NSMakeRect(12, top - 70, W - 24, 18);
  _emptyText.frame = NSMakeRect(18, top - 120, W - 36, 44);
  [self applyColors];
}

- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  [self applyColors];
  [_table reloadData];
}

- (void)setTextColor:(NSColor*)textColor {
  _textColor = textColor ?: NSColor.labelColor;
  [self applyColors];
  [_table reloadData];
}

- (void)applyColors {
  // Resolve the alpha variants of dynamic colours (labelColor) in this view's own light/dark look.
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{ [self applyColorsNow]; }];
}
- (void)applyColorsNow {
  BOOL dark = PanelIsDark(self);
  _title.textColor = [_textColor colorWithAlphaComponent:0.9];
  _backButton.contentTintColor = [_textColor colorWithAlphaComponent:0.6];
  // Same fill as the address pill: white ~9% on a dark Space, black ~5% on a light one.
  _searchBox.layer.backgroundColor = (dark ? [NSColor colorWithWhite:1 alpha:0.09] : [NSColor colorWithWhite:0 alpha:0.05]).CGColor;
  _searchIcon.contentTintColor = [_textColor colorWithAlphaComponent:0.45];
  _search.textColor = _textColor;
  _search.placeholderAttributedString = [[NSAttributedString alloc]
      initWithString:[@"Search " stringByAppendingString:_title.stringValue]
          attributes:@{NSForegroundColorAttributeName : [_textColor colorWithAlphaComponent:0.45], NSFontAttributeName : _search.font}];
  _emptyTitle.textColor = [_textColor colorWithAlphaComponent:0.7];
  _emptyText.textColor = [_textColor colorWithAlphaComponent:0.45];
}

- (NSString*)section { return _section; }
- (void)setSection:(NSString*)section { [self openSection:section]; }
- (void)openSection:(NSString*)sectionID {
  _cameFromHome = NO;
  _section = sectionID.length ? [sectionID copy] : kLibraryHome;
  NSString* title = @"Library";
  if ([_section isEqual:@"archive"]) title = @"Archive";
  for (NSDictionary* s in self.sectionsProvider ? self.sectionsProvider() : @[])
    if ([s[@"id"] isEqual:_section]) title = s[@"title"];
  _title.stringValue = title;
  _backButton.toolTip = [_section isEqual:kLibraryHome] ? @"Back to Tabs" : @"Back to Library";
  _search.stringValue = @"";
  self.needsLayout = YES;
  [self layout];
  [self reload];
}

- (void)reload {
  if (![_section isEqual:@"archive"]) {
    [self reloadEntries];
    return;
  }
  NSArray<ArchivedTab*>* all = self.archiveProvider ? self.archiveProvider() : @[];
  NSArray<ArchivedTab*>* found = ArchiveSearch(all, _search.stringValue ?: @"");  // newest first
  NSMutableArray* rows = [NSMutableArray arrayWithCapacity:found.count + 16];
  NSCalendar* cal = NSCalendar.currentCalendar;
  NSDate* now = [NSDate date];
  NSString* last = nil;
  for (ArchivedTab* t in found) {
    NSString* g = ArchiveGroupTitle(t.archivedAt, now, cal);
    if (![g isEqualToString:last]) [rows addObject:g];
    last = g;
    [rows addObject:t];
  }
  _rows = rows;
  _count = found.count;
  _table.hoveredRow = -1;
  [_table reloadData];
  BOOL empty = all.count == 0;
  _emptyTitle.hidden = _emptyText.hidden = !empty && found.count > 0;
  _emptyTitle.stringValue = empty ? @"Nothing archived yet" : @"No matches";
  _emptyText.stringValue = empty ? @"Tabs you close, and Today tabs you leave alone for a while, land here."
                                 : @"Try another word from the page's title or address.";
}

- (void)reloadEntries {
  NSMutableArray* rows = [NSMutableArray array];
  NSUInteger count = 0;
  if ([_section isEqual:kLibraryHome]) {
    NSArray* spaces = self.entriesProvider ? self.entriesProvider(@"spaces") : @[];
    if (spaces.count) {
      [rows addObject:@"Spaces"];
      [rows addObjectsFromArray:spaces];
      count += spaces.count;
    }
    [rows addObject:@"Library"];
    for (NSDictionary* s in self.sectionsProvider ? self.sectionsProvider() : @[]) {
      LibrarySectionRow* r = [LibrarySectionRow new];
      r.info = s;
      [rows addObject:r];
      ++count;
    }
  } else {
    NSString* q = _search.stringValue.lowercaseString ?: @"";
    for (LibraryEntry* e in self.entriesProvider ? self.entriesProvider(_section) : @[]) {
      NSString* hay = [NSString stringWithFormat:@"%@ %@", e.title ?: @"", e.searchText ?: e.detail ?: @""].lowercaseString;
      if (q.length && ![hay containsString:q]) continue;
      [rows addObject:e];
      ++count;
    }
  }
  _rows = rows;
  _count = count;
  _table.hoveredRow = -1;
  [_table reloadData];
  BOOL empty = count == 0;
  _emptyTitle.hidden = _emptyText.hidden = !empty;
  _emptyTitle.stringValue = _search.stringValue.length ? @"No matches" : [NSString stringWithFormat:@"No %@ yet", _title.stringValue];
  _emptyText.stringValue = _search.stringValue.length ? @"Try another word." : @"";
}
- (NSString*)homeDescription {
  NSMutableArray* out = [NSMutableArray array];
  for (id r in _rows) {
    if ([r isKindOfClass:NSString.class]) [out addObject:[@"#" stringByAppendingString:r]];
    else if ([r isKindOfClass:LibrarySectionRow.class]) [out addObject:((LibrarySectionRow*)r).info[@"title"]];
    else if ([r isKindOfClass:LibraryEntry.class]) [out addObject:@"space"];
  }
  return [out componentsJoinedByString:@","];
}
- (void)openRowForTest:(NSUInteger)index {
  NSUInteger n = 0;
  for (NSUInteger i = 0; i < _rows.count; ++i) {
    if ([_rows[i] isKindOfClass:NSString.class]) continue;
    if (n++ == index) {
      [self openRow:(NSInteger)i];
      return;
    }
  }
}

- (void)focusSearch { [self.window makeFirstResponder:_searchBox.hidden ? _table : _search]; }
- (void)setQuery:(NSString*)query {
  _search.stringValue = query ?: @"";
  [self reload];
}
- (NSUInteger)visibleCount { return _count; }
- (NSArray<NSString*>*)groupTitles {
  NSMutableArray* out = [NSMutableArray array];
  for (id r in _rows)
    if ([r isKindOfClass:NSString.class]) [out addObject:r];
  return out;
}
- (NSString*)styleDescription {
  [self layoutSubtreeIfNeeded];
  if (NSHeight(_searchBox.frame) == 0) [self layout];
  return [NSString stringWithFormat:@"header=%.0f search=%.0f radius=%.0f row=%.0f heading=%.0f placeholder=%@",
                                    NSHeight(_title.frame) ? kHeaderH : 0, NSHeight(_searchBox.frame), _searchBox.layer.cornerRadius,
                                    kRowH, kHeadingH, _search.placeholderAttributedString.string ?: _search.placeholderString];
}

- (void)controlTextDidChange:(NSNotification*)n { [self reload]; }
- (BOOL)control:(NSControl*)c textView:(NSTextView*)tv doCommandBySelector:(SEL)sel {
  if (sel == @selector(cancelOperation:)) {  // Esc: clear the search, then go back
    if (_search.stringValue.length) [self setQuery:@""];
    else [self backClicked:nil];
    return YES;
  }
  if (sel == @selector(insertNewline:)) {  // Return opens the first match
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i)
      if (![_rows[(NSUInteger)i] isKindOfClass:NSString.class]) {
        [self openRow:i];
        break;
      }
    return YES;
  }
  if (sel == @selector(moveDown:) && _table.numberOfRows) {
    [self.window makeFirstResponder:_table];
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i)
      if (![_rows[(NSUInteger)i] isKindOfClass:NSString.class]) {
        [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)i] byExtendingSelection:NO];
        break;
      }
    return YES;
  }
  return NO;
}

- (void)keyDown:(NSEvent*)e {
  if (e.keyCode == 36 || e.keyCode == 76) {  // Return in the list
    [self openRow:_table.selectedRow];
    return;
  }
  if (e.keyCode == 53) {
    [self backClicked:nil];
    return;
  }
  [super keyDown:e];
}

- (void)backClicked:(id)sender {
  // From a section opened off the home list: back to the list. From the home list (or Archive opened on its own,
  // File > Show Archive): out of the Library.
  if (![_section isEqual:kLibraryHome] && _cameFromHome) {
    [self openSection:kLibraryHome];
    return;
  }
  if (self.back) self.back();
}

- (void)rowClicked:(id)sender { [self openRow:_table.clickedRow]; }
- (void)openRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_rows.count) return;
  id r = _rows[(NSUInteger)row];
  if ([r isKindOfClass:LibrarySectionRow.class]) {
    [self openSection:((LibrarySectionRow*)r).info[@"id"]];
    _cameFromHome = YES;
    return;
  }
  if ([r isKindOfClass:LibraryEntry.class]) {
    if (((LibraryEntry*)r).open) ((LibraryEntry*)r).open();
    return;
  }
  if (![r isKindOfClass:ArchivedTab.class]) return;
  if (self.reopen) self.reopen(r);
  [self reload];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)_rows.count; }
- (CGFloat)tableView:(NSTableView*)t heightOfRow:(NSInteger)row {
  id r = _rows[(NSUInteger)row];
  if ([r isKindOfClass:LibraryEntry.class] && ((LibraryEntry*)r).card) return 58;
  return [r isKindOfClass:NSString.class] ? kHeadingH : kRowH;
}
- (BOOL)tableView:(NSTableView*)t shouldSelectRow:(NSInteger)row { return ![_rows[(NSUInteger)row] isKindOfClass:NSString.class]; }
- (NSTableRowView*)tableView:(NSTableView*)t rowViewForRow:(NSInteger)row {
  LibraryRowView* rv = [t makeViewWithIdentifier:@"lrow" owner:self] ?: [LibraryRowView new];
  rv.identifier = @"lrow";
  id rr = _rows[(NSUInteger)row];
  rv.heading = [rr isKindOfClass:NSString.class] || ([rr isKindOfClass:LibraryEntry.class] && ((LibraryEntry*)rr).card);
  rv.hovered = row == _table.hoveredRow;
  return rv;
}

- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  id r = _rows[(NSUInteger)row];
  CGFloat W = col.width;
  if ([r isKindOfClass:NSString.class]) {
    NSTextField* h = [t makeViewWithIdentifier:@"heading" owner:self];
    if (!h) {
      h = [NSTextField labelWithString:@""];
      h.identifier = @"heading";
      h.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    }
    h.stringValue = r;
    h.textColor = [_textColor colorWithAlphaComponent:0.45];  // Arc: SidebarForeground, like the Space title
    h.frame = NSMakeRect(10, 6, W - 20, 15);
    NSView* box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, kHeadingH)];
    [box addSubview:h];
    return box;
  }
  if ([r isKindOfClass:LibraryEntry.class] && ((LibraryEntry*)r).card) {  // the card draws its own fill
    NSView* box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, W, 58)];
    DownloadCardView* card = [[DownloadCardView alloc] initWithFrame:NSMakeRect(0, 3, W, 52) solid:NO];
    card.autoresizingMask = NSViewWidthSizable;
    [card showEntry:r textColor:_textColor];
    [box addSubview:card];
    return box;
  }
  NSTableCellView* cell = [t makeViewWithIdentifier:@"tab" owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, W, kRowH)];
    cell.identifier = @"tab";
    NSImageView* icon = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 12.5, 16, 16)];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [cell addSubview:icon];
    cell.imageView = icon;
    NSTextField* label = [NSTextField labelWithString:@""];
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    [cell addSubview:label];
    cell.textField = label;
    NSTextField* when = [NSTextField labelWithString:@""];
    when.tag = 5;
    when.font = [NSFont systemFontOfSize:11];
    when.alignment = NSTextAlignmentRight;
    [cell addSubview:when];
  }
  NSTextField* when = [cell viewWithTag:5];
  NSString *title = @"", *detail = @"", *tip = nil;
  NSImage* icon = nil;
  BOOL tint = NO;
  if ([r isKindOfClass:ArchivedTab.class]) {
    ArchivedTab* tab = r;
    NSCalendar* cal = NSCalendar.currentCalendar;
    BOOL recent = tab.archivedAt && [cal components:NSCalendarUnitDay fromDate:tab.archivedAt toDate:[NSDate date] options:0].day < 2;
    detail = tab.archivedAt ? [(recent ? _timeFormat : _dayFormat) stringFromDate:tab.archivedAt] : @"";
    title = tab.title.length ? tab.title : (tab.url ?: @"");
    icon = self.iconForURL ? self.iconForURL(tab.url) : nil;
    tip = tab.url;
  } else if ([r isKindOfClass:LibrarySectionRow.class]) {
    NSDictionary* s = ((LibrarySectionRow*)r).info;
    title = s[@"title"];
    NSNumber* n = s[@"count"];
    detail = n && n.integerValue > 0 ? n.stringValue : @"";
    icon = [NSImage imageWithSystemSymbolName:s[@"symbol"] accessibilityDescription:nil];
    tint = YES;
  } else {
    LibraryEntry* e = r;
    title = e.title ?: @"";
    detail = e.detail ?: @"";
    icon = e.icon;
    tint = e.tintIcon;
    tip = e.searchText;
  }
  when.stringValue = detail;
  when.textColor = [_textColor colorWithAlphaComponent:0.35];
  CGFloat ww = ceil(when.attributedStringValue.size.width) + 2;
  when.frame = NSMakeRect(W - 10 - ww, 12.5, ww, 15);
  cell.textField.stringValue = title;
  cell.textField.textColor = _textColor;
  cell.textField.frame = NSMakeRect(37, 11.5, MAX(20, W - 37 - ww - 18), 18);
  cell.imageView.image = icon;
  cell.imageView.contentTintColor = [_textColor colorWithAlphaComponent:tint ? 0.6 : 0.7];
  cell.toolTip = tip;
  return cell;
}
@end
