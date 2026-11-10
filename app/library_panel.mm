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

static BOOL PanelIsDark(NSView* v) {
  return [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
         NSAppearanceNameDarkAqua;
}

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
  _backButton.frame = NSMakeRect(2, H - kHeaderH + 5, 24, 24);
  _title.frame = NSMakeRect(28, H - kHeaderH + 8, W - 36, 18);
  _searchBox.frame = NSMakeRect(0, H - kHeaderH - kSearchH - 2, W - 2, kSearchH);
  _searchIcon.frame = NSMakeRect(10, (kSearchH - 16) / 2, 16, 16);
  _search.frame = NSMakeRect(32, (kSearchH - 18) / 2, W - 2 - 40, 18);
  CGFloat top = H - kHeaderH - kSearchH - 10;
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
      initWithString:@"Search Archive"
          attributes:@{NSForegroundColorAttributeName : [_textColor colorWithAlphaComponent:0.45], NSFontAttributeName : _search.font}];
  _emptyTitle.textColor = [_textColor colorWithAlphaComponent:0.7];
  _emptyText.textColor = [_textColor colorWithAlphaComponent:0.45];
}

- (void)reload {
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

- (void)focusSearch { [self.window makeFirstResponder:_search]; }
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
    for (id r in _rows)
      if ([r isKindOfClass:ArchivedTab.class]) {
        if (self.reopen) self.reopen(r);
        [self reload];
        break;
      }
    return YES;
  }
  if (sel == @selector(moveDown:) && _table.numberOfRows) {
    [self.window makeFirstResponder:_table];
    for (NSInteger i = 0; i < (NSInteger)_rows.count; ++i)
      if ([_rows[(NSUInteger)i] isKindOfClass:ArchivedTab.class]) {
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
  if (self.back) self.back();
}

- (void)rowClicked:(id)sender { [self openRow:_table.clickedRow]; }
- (void)openRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_rows.count) return;
  id r = _rows[(NSUInteger)row];
  if (![r isKindOfClass:ArchivedTab.class]) return;
  if (self.reopen) self.reopen(r);
  [self reload];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)_rows.count; }
- (CGFloat)tableView:(NSTableView*)t heightOfRow:(NSInteger)row {
  return [_rows[(NSUInteger)row] isKindOfClass:NSString.class] ? kHeadingH : kRowH;
}
- (BOOL)tableView:(NSTableView*)t shouldSelectRow:(NSInteger)row { return [_rows[(NSUInteger)row] isKindOfClass:ArchivedTab.class]; }
- (NSTableRowView*)tableView:(NSTableView*)t rowViewForRow:(NSInteger)row {
  LibraryRowView* rv = [t makeViewWithIdentifier:@"lrow" owner:self] ?: [LibraryRowView new];
  rv.identifier = @"lrow";
  rv.heading = [_rows[(NSUInteger)row] isKindOfClass:NSString.class];
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
  ArchivedTab* tab = r;
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
  NSCalendar* cal = NSCalendar.currentCalendar;
  BOOL recent = tab.archivedAt && [cal components:NSCalendarUnitDay fromDate:tab.archivedAt toDate:[NSDate date] options:0].day < 2;
  when.stringValue = tab.archivedAt ? [(recent ? _timeFormat : _dayFormat) stringFromDate:tab.archivedAt] : @"";
  when.textColor = [_textColor colorWithAlphaComponent:0.35];
  CGFloat ww = ceil(when.attributedStringValue.size.width) + 2;
  when.frame = NSMakeRect(W - 10 - ww, 12.5, ww, 15);
  cell.textField.stringValue = tab.title.length ? tab.title : (tab.url ?: @"");
  cell.textField.textColor = _textColor;
  cell.textField.frame = NSMakeRect(37, 11.5, MAX(20, W - 37 - ww - 18), 18);
  cell.imageView.image = self.iconForURL ? self.iconForURL(tab.url) : nil;
  cell.imageView.contentTintColor = [_textColor colorWithAlphaComponent:0.7];
  cell.toolTip = tab.url;
  return cell;
}
@end
