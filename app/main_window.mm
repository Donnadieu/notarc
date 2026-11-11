#import <QuartzCore/QuartzCore.h>
#import "app/main_window.h"
#import "app/autofill.h"
#import "app/password_store.h"
#import "app/sidebar_store.h"
#import "app/archive_store.h"
#import "app/archive_window.h"
#import "app/library_panel.h"
#import "app/arc_history.h"
#import "app/chrome_page.h"
#import "app/arc_extensions.h"
#import "app/extensions.h"
#import "app/extension_popup.h"
#import "app/updater.h"
#import "app/downloads.h"
#import "app/link_routing.h"
#import "app/link_routing_editor.h"
#import "app/bookmark_import.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "app/history_store.h"
#import "app/arc_cookies.h"
#import "app/little_window.h"
#import "app/settings.h"
#import "app/boost_store.h"
#import "app/boost_color_wheel.h"
#import "app/easel.h"
#import "app/note_editor.h"
#import "app/easel_clip.h"
#import "app/live_folder.h"
#import "app/favicons.h"
#import "app/tidy_title.h"
#import "app/space_fetch.h"
#import "app/email_peek.h"
#import "app/web_notifications.h"
#import "app/calendar_preview.h"
#import "app/tab_thumbnails.h"
#import "app/arc_max.h"
#import "app/main_window_max.h"
#import "app/ad_blockers_window.h"
#include "app/content_blocker.h"
#include "include/cef_devtools_message_observer.h"

#include <cstdio>
#include <atomic>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "app/browser_client.h"
#include "include/cef_browser.h"
#include "include/cef_app.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_cookie.h"
#include "include/cef_urlrequest.h"

static NSPasteboardType const kSidebarItemPasteboardType = @"io.github.donnadieu.notarc.sidebar-item";

namespace {
constexpr CGFloat kSidebarWidth = 273;  // Arc's default (StorableWindows.json sidebarWidth)
// The page sits in a rounded card on the Space colour, as in Arc (measured from Arc 1.169):
constexpr CGFloat kCardInsetTop = 10, kCardInsetSide = 9, kCardInsetBottom = 9, kCardRadius = 8;

// Chrome-style request contexts initialise asynchronously; browsers created before that fail.
class SpaceContextHandler : public CefRequestContextHandler {
 public:
  explicit SpaceContextHandler(std::function<void()> on_ready) : on_ready_(std::move(on_ready)) {}
  void OnRequestContextInitialized(CefRefPtr<CefRequestContext> context) override {
    if (on_ready_) on_ready_();
  }

 private:
  std::function<void()> on_ready_;
  IMPLEMENT_REFCOUNTING(SpaceContextHandler);
};
// Counts down outstanding SetCookie calls and runs `done` on the UI thread after the last one.
class CookieImportCallback : public CefSetCookieCallback {
 public:
  CookieImportCallback(int pending, std::function<void(int ok)> done) : pending_(pending), done_(std::move(done)) {}
  void OnComplete(bool success) override {
    if (success) ok_.fetch_add(1);
    if (pending_.fetch_sub(1) == 1 && done_) done_(ok_.load());
  }

 private:
  std::atomic<int> pending_;
  std::atomic<int> ok_{0};
  std::function<void(int)> done_;
  IMPLEMENT_REFCOUNTING(CookieImportCallback);
};

// Arc imports read SQLite copies and the Keychain off the main thread, one at a time.
dispatch_queue_t ArcImportQueue() {
  static dispatch_queue_t queue = dispatch_queue_create("notarc.arc-import", DISPATCH_QUEUE_SERIAL);
  return queue;
}

// Arc's "Arc Safe Storage" key, read once per launch when it works (macOS may ask the first time). A failure isn't
// kept, so the next import can ask again. Only call it on ArcImportQueue() (serial, so no lock is needed).
NSData* ArcImportKey(NSError** error) {
  static NSData* key = nil;
  if (key) return key;
  NSString* pw = ArcSafeStoragePassword(error);
  if (pw.length) key = ArcCookieKey(pw);
  else if (error && !*error)
    *error = [NSError errorWithDomain:@"ArcCookies" code:2 userInfo:@{NSLocalizedDescriptionKey : @"Arc's key is empty"}];
  return key;
}

cef_cookie_same_site_t SameSiteFromChromiumDB(int v) {
  switch (v) {
    case 0: return CEF_COOKIE_SAME_SITE_NO_RESTRICTION;
    case 1: return CEF_COOKIE_SAME_SITE_LAX_MODE;
    case 2: return CEF_COOKIE_SAME_SITE_STRICT_MODE;
    default: return CEF_COOKIE_SAME_SITE_UNSPECIFIED;
  }
}
}  // namespace

NSString* ResolveCommandBarInput(NSString* input) {
  NSString* text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length) return nil;
  BOOL hasScheme = [text rangeOfString:@"://"].location != NSNotFound || [text hasPrefix:@"about:"];
  BOOL looksLikeHost = [text rangeOfString:@" "].location == NSNotFound &&
                       ([text containsString:@"."] || [text hasPrefix:@"localhost"]);
  if (hasScheme) return text;
  if (looksLikeHost) return [@"https://" stringByAppendingString:text];
  NSString* q = [text stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
  q = [q stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
  q = [q stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
  return SearchURLForQuery(q);
}

static BOOL Contains(ArcItem* root, ArcItem* target);

static NSColor* ColorFromHex(NSString* hex) {
  NSString* h = [hex stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# "]];
  if (h.length != 6) return nil;
  unsigned v = 0;
  if (![[NSScanner scannerWithString:h] scanHexInt:&v]) return nil;
  return [NSColor colorWithSRGBRed:((v >> 16) & 0xFF) / 255.0 green:((v >> 8) & 0xFF) / 255.0 blue:(v & 0xFF) / 255.0 alpha:1];
}

static NSString* HexFromColor(NSColor* c) {
  NSColor* s = [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  if (!s) return nil;
  return [NSString stringWithFormat:@"#%02X%02X%02X", (int)lround(s.redComponent * 255), (int)lround(s.greenComponent * 255),
                                    (int)lround(s.blueComponent * 255)];
}

static const CGFloat kToolbarHeight = 38;
static const CGFloat kSuggestionRow = 50;  // Arc: 50 pt rows (46 pt pill) under a 64 pt input row
static const NSUInteger kMaxSuggestions = 8;

// Data source for the command bar's suggestion list (kept separate from the sidebar's outline delegate).
// Arc: HoveredAndKeyboardSelectedBackground (0.161, 0.18, 0.757), a rounded pill.
static NSColor* CommandSelectedColor() { return [NSColor colorWithSRGBRed:0.161 green:0.18 blue:0.757 alpha:1]; }
// Arc fills the selected row with the Space's own colour, a shade deeper; the default theme uses Arc blue.
static NSColor* gCommandPillColor;
@interface CommandRowView : NSTableRowView
@end
@implementation CommandRowView
- (void)drawSelectionInRect:(NSRect)r {
  [(gCommandPillColor ?: CommandSelectedColor()) setFill];
  [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 0, 2) xRadius:8 yRadius:8] fill];
}
- (BOOL)isEmphasized { return YES; }
@end

// Arc's command bar card: an opaque rounded panel (not see-through glass), hairline edge, deep shadow from the window.
@interface CommandCardView : NSView
@end
@implementation CommandCardView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
  BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
              NSAppearanceNameDarkAqua;
  self.layer.cornerRadius = 14;
  self.layer.masksToBounds = YES;
  self.layer.backgroundColor = (dark ? [NSColor colorWithSRGBRed:0.137 green:0.137 blue:0.149 alpha:1]
                                     : [NSColor colorWithSRGBRed:0.988 green:0.988 blue:0.992 alpha:1]).CGColor;
  self.layer.borderWidth = 1;
  self.layer.borderColor = (dark ? [NSColor colorWithWhite:1 alpha:0.10] : [NSColor colorWithWhite:0 alpha:0.08]).CGColor;
}
@end

@interface CommandSuggestionList : NSObject <NSTableViewDataSource, NSTableViewDelegate>
@property(nonatomic, copy) NSArray<NSDictionary*>* items;
@property(nonatomic, copy) NSImage* (^iconForSuggestion)(NSDictionary* s);  // site icon for tabs, history, top sites
@end
@implementation CommandSuggestionList
- (NSInteger)numberOfRowsInTableView:(NSTableView*)t { return (NSInteger)self.items.count; }
// Arc's command bar rows (colour catalogue): primary text 80%, secondary 33%, selected row in Arc blue with white
// text, an icon per kind. View-based so the selected row can be drawn as a rounded pill.
- (NSView*)tableView:(NSTableView*)t viewForTableColumn:(NSTableColumn*)c row:(NSInteger)row {
  NSDictionary* s = self.items[row];
  NSTableCellView* cell = [t makeViewWithIdentifier:@"cmd" owner:nil];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, c.width, kSuggestionRow)];
    cell.identifier = @"cmd";
    NSImageView* icon = [[NSImageView alloc] initWithFrame:NSMakeRect(14, 17, 16, 16)];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    [cell addSubview:icon];
    cell.imageView = icon;
    NSTextField* title = [NSTextField labelWithString:@""];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    title.frame = NSMakeRect(42, 16, c.width - 54, 18);
    title.autoresizingMask = NSViewWidthSizable;
    [cell addSubview:title];
    cell.textField = title;
    NSTextField* hint = [NSTextField labelWithString:@""];  // Arc: what Return does, on the selected row
    hint.tag = 3;
    hint.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    hint.alignment = NSTextAlignmentRight;
    hint.autoresizingMask = NSViewMinXMargin;
    [cell addSubview:hint];
    // Arc: a small rounded square with an arrow after "Switch to Tab".
    NSImageView* arrow = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"arrow.right" accessibilityDescription:nil]];
    arrow.tag = 4;
    arrow.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightBold];
    arrow.wantsLayer = YES;
    arrow.layer.cornerRadius = 5;
    arrow.autoresizingMask = NSViewMinXMargin;
    [cell addSubview:arrow];
  }
  static NSDictionary* kinds = @{ @"go" : @"Open", @"tab" : @"Switch to Tab", @"space" : @"Switch Space", @"history" : @"Open",
                                  @"action" : @"Run", @"site" : @"Open", @"search" : @"Search",
                                  @"chatgpt" : @"Ask ChatGPT" };
  static NSDictionary* icons = @{ @"go" : @"magnifyingglass", @"tab" : @"square.on.square", @"space" : @"square.stack",
                                  @"history" : @"clock", @"action" : @"command", @"site" : @"globe",
                                  @"search" : @"magnifyingglass", @"chatgpt" : @"bubble.left.and.text.bubble.right" };
  BOOL sel = [t.selectedRowIndexes containsIndex:(NSUInteger)row];
  NSColor* primary = sel ? NSColor.whiteColor : [NSColor.labelColor colorWithAlphaComponent:0.80];
  NSColor* secondary = sel ? [NSColor colorWithWhite:1 alpha:0.70] : [NSColor.labelColor colorWithAlphaComponent:0.33];
  NSMutableAttributedString* a = [[NSMutableAttributedString alloc]
      initWithString:s[@"title"] ?: @""
          attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:14 weight:NSFontWeightMedium], NSForegroundColorAttributeName : primary}];
  NSString* sub = [s[@"subtitle"] length] ? [@"  —  " stringByAppendingString:s[@"subtitle"]] : @"";
  [a appendAttributedString:[[NSAttributedString alloc] initWithString:sub
                                                            attributes:@{NSFontAttributeName : [NSFont systemFontOfSize:13],
                                                                         NSForegroundColorAttributeName : secondary}]];
  cell.textField.attributedStringValue = a;
  NSTextField* hint = [cell viewWithTag:3];
  NSImageView* arrow = [cell viewWithTag:4];
  NSString* kind = s[@"kind"];
  if ([kind isEqual:@"go"] && [s[@"subtitle"] isEqual:@"Search"]) kind = @"search";
  BOOL tabRow = [kind isEqual:@"tab"];
  hint.stringValue = sel || tabRow ? (kinds[kind] ?: @"") : @"";  // Arc keeps "Switch to Tab" on every open-tab row
  hint.textColor = sel ? [NSColor colorWithWhite:1 alpha:0.85] : secondary;
  arrow.hidden = !tabRow;
  arrow.contentTintColor = sel ? NSColor.whiteColor : [NSColor.labelColor colorWithAlphaComponent:0.55];
  arrow.layer.backgroundColor = (sel ? [NSColor colorWithWhite:1 alpha:0.22] : [NSColor.labelColor colorWithAlphaComponent:0.08]).CGColor;
  CGFloat W = cell.bounds.size.width, aw = arrow.hidden ? 0 : 24;
  arrow.frame = NSMakeRect(W - 10 - 24, 13, 24, 24);
  CGFloat hw = hint.stringValue.length ? ceil(hint.attributedStringValue.size.width) + 4 : 0;
  hint.frame = NSMakeRect(W - 14 - aw - (aw ? 4 : 0) - hw, 17, hw, 16);
  CGFloat right = hw ? NSMinX(hint.frame) - 12 : W - 12;
  cell.textField.frame = NSMakeRect(42, 16, MAX(40, right - 42), 18);
  NSImage* site = self.iconForSuggestion ? self.iconForSuggestion(s) : nil;
  cell.imageView.image = site ?: [NSImage imageWithSystemSymbolName:icons[s[@"kind"]] ?: @"globe" accessibilityDescription:nil];
  cell.imageView.contentTintColor = sel ? NSColor.whiteColor : [NSColor.labelColor colorWithAlphaComponent:0.55];
  return cell;
}
- (NSTableRowView*)tableView:(NSTableView*)t rowViewForRow:(NSInteger)row { return [CommandRowView new]; }
- (void)tableViewSelectionDidChange:(NSNotification*)n {
  NSTableView* t = n.object;
  [t reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)t.numberOfRows)]
               columnIndexes:[NSIndexSet indexSetWithIndex:0]];
}
@end

@interface MainWindowController () <NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate,
                                    NSMenuDelegate, NoteEditorDelegate>
@end

// The gap between two split panes; dragging it resizes them.
// Arc's sidebar pill (address bar): translucent white over the Space colour in dark mode, dark tint in light mode
// (Arc colour catalogue: SidebarItemBackground / SidebarItemHoveredBackground). Click opens the command bar.
@interface SidebarPillView : NSView
@property(nonatomic, copy) void (^onClick)(void);
@property(nonatomic, copy) void (^hoverChanged)(void);
@property(nonatomic) BOOL hovered;
@end
@implementation SidebarPillView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {
  BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
              NSAppearanceNameDarkAqua;
  NSColor* c = dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:self.hovered ? 0.15 : 0.10]
                    : [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.063 alpha:self.hovered ? 0.10 : 0.05];
  self.layer.backgroundColor = c.CGColor;
  self.layer.cornerRadius = 10;
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                             NSTrackingInVisibleRect
                                                       owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)e {
  self.hovered = YES;
  self.needsDisplay = YES;
  if (self.hoverChanged) self.hoverChanged();
}
- (void)mouseExited:(NSEvent*)e {
  self.hovered = NO;
  self.needsDisplay = YES;
  if (self.hoverChanged) self.hoverChanged();
}
- (void)mouseUp:(NSEvent*)e { if (self.onClick) self.onClick(); }
@end

// Arc's Space style editor has a grain slider: a fine monochrome noise over the theme colours. NotArc draws its own
// noise tile once (seeded, so it looks the same every launch) and repeats it as a pattern colour.
static constexpr float kMaxGrainOpacity = 0.35;
static CGColorRef GrainPatternColor() {
  static NSColor* color;
  if (!color) {
    const int n = 128;
    NSBitmapImageRep* rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nullptr pixelsWide:n pixelsHigh:n bitsPerSample:8
                                                               samplesPerPixel:2 hasAlpha:YES isPlanar:NO
                                                                colorSpaceName:NSCalibratedWhiteColorSpace bytesPerRow:n * 2
                                                                  bitsPerPixel:16];
    uint32_t seed = 0x9E3779B9u;
    unsigned char* px = rep.bitmapData;
    for (int i = 0; i < n * n; ++i) {
      seed = seed * 1664525u + 1013904223u;  // small LCG: deterministic, no allocation
      unsigned v = seed >> 24;
      px[i * 2] = v > 127 ? 255 : 0;          // white or black speck
      px[i * 2 + 1] = (unsigned char)((v * 37u) & 0x7F);  // varying strength
    }
    NSImage* img = [[NSImage alloc] initWithSize:NSMakeSize(n / 2, n / 2)];  // @2x tile
    [img addRepresentation:rep];
    color = [NSColor colorWithPatternImage:img];
  }
  return color.CGColor;
}

// Arc's page card edge (#122): a hairline border on the card (Arc's colour catalogue: TabListOverlapBorder, black 5%
// in light, white 5% in dark) and, in light mode only, a soft two-layer shadow under it (Arc's card views carry a
// shadowConfiguration and a secondaryShadowConfiguration), so a white page still stands off a pale Space colour.
// The view sits behind the card; the card itself clips the page, so its own layer can't cast the shadow.
@interface CardEdgeView : NSView
@property(nonatomic, weak) NSView* card;
@end
@implementation CardEdgeView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
- (void)setFrame:(NSRect)f { [super setFrame:f]; self.needsDisplay = YES; }
- (void)updateLayer {
  BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
              NSAppearanceNameDarkAqua;
  CGFloat radius = self.card.layer.cornerRadius;
  CGPathRef path = CGPathCreateWithRoundedRect(self.bounds, radius, radius, nullptr);
  self.layer.backgroundColor = NSColor.whiteColor.CGColor;  // hidden under the card; a shadow needs something to cast it
  self.layer.cornerRadius = radius;
  self.layer.shadowPath = path;
  self.layer.shadowColor = NSColor.blackColor.CGColor;
  self.layer.shadowOffset = CGSizeMake(0, -1);
  self.layer.shadowRadius = 4;
  self.layer.shadowOpacity = dark || radius == 0 ? 0 : 0.10;
  CALayer* tight = self.layer.sublayers.firstObject;
  if (!tight) {
    tight = [CALayer layer];
    [self.layer addSublayer:tight];
  }
  tight.frame = self.bounds;
  tight.cornerRadius = radius;
  tight.backgroundColor = NSColor.whiteColor.CGColor;
  tight.shadowPath = path;
  tight.shadowColor = NSColor.blackColor.CGColor;
  tight.shadowOffset = CGSizeZero;
  tight.shadowRadius = 1;
  tight.shadowOpacity = dark || radius == 0 ? 0 : 0.06;
  CGPathRelease(path);
  self.card.layer.borderWidth = radius == 0 ? 0 : 1;
  self.card.layer.borderColor = (dark ? [NSColor colorWithWhite:1 alpha:0.05] : [NSColor colorWithWhite:0 alpha:0.05]).CGColor;
}
@end

// Arc's sidebar rows: 36 pt rounded pills with Arc's selected / hovered / multi-selected colours
// (Arc colour catalogue: TabCellBackgroundCurrent, ...PreviousHovered, ...Mutiselected; light mode adds a shadow).
constexpr CGFloat kRowHeight = 36, kRowRadius = 8;
// Arc measurements (1x screenshot of Arc 1.169's sidebar): rows repeat every 41 pt (36 pt pill + 5 pt gap); the
// Pinned section has no label; Today starts with a hairline 10 pt down, then the "+ New Tab" row.
constexpr CGFloat kRowPitch = 41, kPinnedHeaderHeight = 6, kNewTabHeaderHeight = 64;
// Arc's default (unthemed) dark Space: deep indigo, slightly lighter at the bottom; text is lavender, not white.
static NSColor* ArcDefaultTabText() { return [NSColor colorWithSRGBRed:0xda / 255.0 green:0xd9 / 255.0 blue:0xfe / 255.0 alpha:1]; }

// Arc's sidebar icons (traffic-light row, Library, "+"): white ~60% on a dark Space, black ~45% on a light one
// (measured from Omar's Arc screenshot: #9F9CAF over #120D39).
static NSColor* SidebarIconColor() {
  static NSColor* c = [NSColor colorWithName:@"NotArcSidebarIcon" dynamicProvider:^NSColor*(NSAppearance* a) {
    BOOL dark = [a bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    return dark ? [NSColor colorWithWhite:1 alpha:0.60] : [NSColor colorWithWhite:0 alpha:0.45];
  }];
  return c;
}
static NSColor* SidebarIconDimColor() {  // disabled back / forward
  static NSColor* c = [NSColor colorWithName:@"NotArcSidebarIconDim" dynamicProvider:^NSColor*(NSAppearance* a) {
    BOOL dark = [a bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    return dark ? [NSColor colorWithWhite:1 alpha:0.22] : [NSColor colorWithWhite:0 alpha:0.18];
  }];
  return c;
}
// Arc's Space dots: the current one white ~50%, the others ~17% (black on a light Space).
static NSColor* SpaceDotColor(BOOL current) {
  return [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* a) {
    BOOL dark = [a bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    return [NSColor colorWithWhite:dark ? 1 : 0 alpha:current ? (dark ? 0.50 : 0.45) : (dark ? 0.17 : 0.15)];
  }];
}

// NotArc's crashed-page drawing: a page with a folded corner, torn across by a zig-zag.
static NSImage* SadPageGlyph() {
  static NSImage* glyph;
  if (glyph) return glyph;
  glyph = [NSImage imageWithSize:NSMakeSize(72, 80) flipped:NO drawingHandler:^BOOL(NSRect) {
    [NSColor.blackColor setStroke];
    NSBezierPath* page = [NSBezierPath bezierPath];
    page.lineWidth = 5;
    page.lineJoinStyle = NSLineJoinStyleRound;
    page.lineCapStyle = NSLineCapStyleRound;
    [page moveToPoint:NSMakePoint(8, 6)];
    [page lineToPoint:NSMakePoint(8, 74)];
    [page lineToPoint:NSMakePoint(46, 74)];
    [page lineToPoint:NSMakePoint(64, 56)];
    [page lineToPoint:NSMakePoint(64, 6)];
    [page closePath];
    [page moveToPoint:NSMakePoint(46, 74)];
    [page lineToPoint:NSMakePoint(46, 56)];
    [page lineToPoint:NSMakePoint(64, 56)];
    [page stroke];
    NSBezierPath* tear = [NSBezierPath bezierPath];
    tear.lineWidth = 4;
    tear.lineJoinStyle = NSLineJoinStyleRound;
    tear.lineCapStyle = NSLineCapStyleRound;
    [tear moveToPoint:NSMakePoint(8, 30)];
    for (int k = 1; k <= 6; ++k) [tear lineToPoint:NSMakePoint(8 + k * 56.0 / 6, (k % 2) ? 38 : 28)];
    [tear stroke];
    return YES;
  }];
  [glyph setTemplate:YES];
  return glyph;
}

// A card for the bottom of the sidebar: icon, one line (tag 1) and a capsule button (tag 2).
static NSBox* SidebarBannerCard(NSString* symbol, id target, SEL action, NSString* button) {
  const CGFloat W = kSidebarWidth - 17, H = 36;
  NSBox* card = [[NSBox alloc] initWithFrame:NSMakeRect(8, 44, W, H)];
  card.boxType = NSBoxCustom;
  card.borderWidth = 0;
  card.cornerRadius = 8;
  card.contentViewMargins = NSZeroSize;
  card.fillColor = [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* ap) {
    BOOL dark = [ap bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    return [NSColor colorWithWhite:dark ? 1 : 0 alpha:dark ? 0.10 : 0.06];
  }];
  NSImageView* icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
  icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
  icon.frame = NSMakeRect(10, 10, 16, 16);
  icon.contentTintColor = NSColor.secondaryLabelColor;
  NSTextField* title = [NSTextField labelWithString:@""];
  title.tag = 1;
  title.lineBreakMode = NSLineBreakByTruncatingTail;
  title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
  title.textColor = NSColor.labelColor;
  NSButton* b = [NSButton buttonWithTitle:button target:target action:action];
  b.tag = 2;
  b.bordered = NO;
  b.wantsLayer = YES;
  b.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
  b.attributedTitle = [[NSAttributedString alloc]
      initWithString:button
          attributes:@{NSFontAttributeName : b.font, NSForegroundColorAttributeName : NSColor.labelColor}];
  CGFloat bw = ceil([button sizeWithAttributes:@{NSFontAttributeName : b.font}].width) + 20;
  b.frame = NSMakeRect(W - 7 - bw, 7, bw, 22);
  NSBox* pill = [[NSBox alloc] initWithFrame:b.frame];  // the capsule behind the button, following light / dark
  pill.boxType = NSBoxCustom;
  pill.borderWidth = 0;
  pill.cornerRadius = 11;
  pill.fillColor = [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* ap) {
    BOOL dark = [ap bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    return dark ? NSColor.blackColor : NSColor.whiteColor;
  }];
  pill.identifier = @"bannerPill";
  title.frame = NSMakeRect(32, 10, NSMinX(b.frame) - 6 - 32, 16);
  for (NSView* v in @[ icon, title, pill, b ]) [card.contentView addSubview:v];
  return card;
}

// Arc's folder glyphs (drawn here, 16 pt templates): a closed folder, and an open one whose front leans forward.
static NSImage* FolderGlyph(BOOL open) {
  static NSImage* glyphs[2];
  if (glyphs[open]) return glyphs[open];
  NSImage* img = [NSImage imageWithSize:NSMakeSize(16, 16) flipped:NO drawingHandler:^BOOL(NSRect) {
    [NSColor.blackColor setStroke];
    NSBezierPath* back = [NSBezierPath bezierPath];
    back.lineWidth = 1.4;
    back.lineJoinStyle = NSLineJoinStyleRound;
    // back panel with the tab
    [back moveToPoint:NSMakePoint(1.7, 3)];
    [back lineToPoint:NSMakePoint(1.7, 12.6)];
    [back lineToPoint:NSMakePoint(5.8, 12.6)];
    [back lineToPoint:NSMakePoint(7.3, 11)];
    [back lineToPoint:NSMakePoint(13.6, 11)];
    [back lineToPoint:NSMakePoint(13.6, open ? 8.4 : 3)];
    if (!open) [back lineToPoint:NSMakePoint(1.7, 3)];
    [back stroke];
    NSBezierPath* front = [NSBezierPath bezierPath];
    front.lineWidth = 1.4;
    front.lineJoinStyle = NSLineJoinStyleRound;
    if (open) {  // the front flap, tilted toward the viewer
      [front moveToPoint:NSMakePoint(1.7, 3)];
      [front lineToPoint:NSMakePoint(4.2, 8.4)];
      [front lineToPoint:NSMakePoint(15.2, 8.4)];
      [front lineToPoint:NSMakePoint(12.6, 3)];
      [front closePath];
      [front stroke];
    } else {
      [front moveToPoint:NSMakePoint(1.7, 9.2)];
      [front lineToPoint:NSMakePoint(13.6, 9.2)];
      [front stroke];
    }
    return YES;
  }];
  [img setTemplate:YES];
  glyphs[open] = img;
  return img;
}

static BOOL IsDark(NSView* v) {
  return [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
         NSAppearanceNameDarkAqua;
}
// Arc's tab titles never end in "...": a long title fades out toward the row's right edge.
@interface FadingLabel : NSTextField
- (void)updateFade;
@end
@implementation FadingLabel
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self updateFade];
}
- (void)updateFade {
  self.wantsLayer = YES;
  CGFloat w = self.bounds.size.width;
  if (w <= 0 || self.attributedStringValue.size.width <= w) {
    self.layer.mask = nil;
    return;
  }
  CAGradientLayer* g = [self.layer.mask isKindOfClass:CAGradientLayer.class] ? (CAGradientLayer*)self.layer.mask : [CAGradientLayer layer];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  g.frame = self.bounds;
  g.startPoint = CGPointMake(0, 0.5);
  g.endPoint = CGPointMake(1, 0.5);
  g.colors = @[ (id)NSColor.blackColor.CGColor, (id)NSColor.blackColor.CGColor, (id)NSColor.clearColor.CGColor ];
  g.locations = @[ @0, @(MAX(0.0, 1 - 24 / w)), @1 ];
  self.layer.mask = g;
  [CATransaction commit];
}
- (BOOL)fadesForTest { return self.layer.mask != nil; }
@end

// The close button Arc shows at the right of a tab row while it's hovered.
@interface RowCloseButton : NSButton
@property(nonatomic) BOOL applies;  // the row is a tab (folders, sections and "+ New Tab" have none)
@property(nonatomic) BOOL mouseInside;
@end
@implementation RowCloseButton
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                             NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)e { self.mouseInside = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)e { self.mouseInside = NO; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)r {
  if (self.mouseInside) {  // Arc: SidebarItemHoveredBackground behind the cross
    BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
                NSAppearanceNameDarkAqua;
    [(dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.15] : [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.063 alpha:0.10]) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 2, 2) xRadius:5 yRadius:5] fill];
  }
  [super drawRect:r];
}
@end

// Owner of a tracking area that only reports enter / exit (the left-edge strip and the floating sidebar).
@interface HoverTracker : NSResponder
@property(nonatomic, copy) void (^entered)(void);
@property(nonatomic, copy) void (^exited)(void);
@end
@implementation HoverTracker
- (void)mouseEntered:(NSEvent*)e { if (self.entered) self.entered(); }
- (void)mouseExited:(NSEvent*)e { if (self.exited) self.exited(); }
- (void)mouseMoved:(NSEvent*)e {}
@end

// The thin slanted line between the panes of a split row (Arc: TabCellSlash).
@interface SplitSlashView : NSView
@end
@implementation SplitSlashView
- (void)drawRect:(NSRect)r {
  BOOL dark = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] ==
              NSAppearanceNameDarkAqua;
  [[NSColor colorWithWhite:dark ? 1 : 0 alpha:0.30] setStroke];
  NSBezierPath* p = [NSBezierPath bezierPath];
  p.lineWidth = 1;
  p.lineCapStyle = NSLineCapStyleRound;
  [p moveToPoint:NSMakePoint(NSMinX(self.bounds) + 1.5, NSMinY(self.bounds) + 1)];
  [p lineToPoint:NSMakePoint(NSMaxX(self.bounds) - 1.5, NSMaxY(self.bounds) - 1)];
  [p stroke];
}
@end

// The mini player card: tells its owner when the pointer enters or leaves (mute shows only while it's inside).
static const CGFloat kMediaCardHeight = 32;  // Arc (Omar's screenshot): x 8-264, 32 pt, 46 pt above the window bottom
@interface MediaCardView : NSView
@property(nonatomic, copy) void (^hoverChanged)(BOOL inside);
@property(nonatomic) BOOL inside;
@end
@implementation MediaCardView
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                                                             NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)e {
  self.inside = YES;
  if (self.hoverChanged) self.hoverChanged(YES);
}
- (void)mouseExited:(NSEvent*)e {
  self.inside = NO;
  if (self.hoverChanged) self.hoverChanged(NO);
}
@end

// A page title as the mini player shows it when the page doesn't say what's playing: no running clock such as
// "brain.fm (2:52)" or "1:02 / 3:40", and no leading play triangle.
NSString* MediaBarTitle(NSString* pageTitle) {
  NSString* t = pageTitle ?: @"";
  static NSRegularExpression* clock, *lead;
  if (!clock) {
    clock = [NSRegularExpression regularExpressionWithPattern:@"\\s*[(\\[]?\\d{1,2}(:\\d{2}){1,2}(\\s*/\\s*\\d{1,2}(:\\d{2}){1,2})?[)\\]]?\\s*"
                                                      options:0 error:nil];
    lead = [NSRegularExpression regularExpressionWithPattern:@"^[\\s\\x{25B6}\\x{25BA}\\x{23F8}|\\-:]+" options:0 error:nil];
  }
  t = [clock stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "];
  t = [lead stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@""];
  t = [t stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t-|:"]];
  return t.length ? t : (pageTitle ?: @"");
}

@interface SidebarRowView : NSTableRowView
@property(nonatomic) BOOL hovered;
@property(nonatomic) BOOL multi;
@property(nonatomic) BOOL pressed;
@property(nonatomic) BOOL separatorAbove;  // Arc's hairline between Pinned and Today
@property(nonatomic) BOOL newTabRow;       // Today header: hairline, then a "+ New Tab" pill at the bottom
@end
@implementation SidebarRowView
- (void)setHovered:(BOOL)hovered {
  _hovered = hovered;
  [self syncCloseButton];
}
- (void)setSelected:(BOOL)selected {
  [super setSelected:selected];
  [self syncCloseButton];
}
- (void)didAddSubview:(NSView*)v {
  [super didAddSubview:v];
  [self syncCloseButton];
}
// Arc: the close button shows on the hovered row; the title's fade moves in to make room.
- (void)syncCloseButton {
  for (NSView* cell in self.subviews) {
    RowCloseButton* b = [cell viewWithTag:81];
    if (![b isKindOfClass:RowCloseButton.class]) continue;
    BOOL show = b.applies && self.hovered;  // Arc's own videos: the selected row shows no cross until hovered
    b.hidden = !show;
    if (!b.applies) continue;
    NSButton* speaker = [cell viewWithTag:84];  // the speaker sits left of the cross while it shows
    BOOL sound = speaker && !speaker.hidden;
    if (sound) {
      NSRect sf = speaker.frame;
      sf.origin.x = show ? NSMinX(b.frame) - 22 : cell.bounds.size.width - 34;
      speaker.frame = sf;
    }
    NSTextField* label = ((NSTableCellView*)cell).textField;
    NSRect lf = label.frame;
    CGFloat right = sound ? NSMinX(speaker.frame) - 2 : show ? NSMinX(b.frame) - 2 : cell.bounds.size.width - 8;
    lf.size.width = MAX(0, right - lf.origin.x);
    if (lf.size.width != label.frame.size.width) label.frame = lf;
  }
}
- (NSColor*)fill {
  BOOL dark = IsDark(self);
  if (self.pressed)  // Arc: TabCellBackgroundPressed
    return dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.065]
                : [NSColor colorWithSRGBRed:0.055 green:0.059 blue:0.063 alpha:0.065];
  if (self.selected && self.multi)
    return dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.10] : [NSColor colorWithWhite:0 alpha:0.10];
  if (self.selected) return dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.20] : [NSColor colorWithWhite:1 alpha:0.85];
  if (self.hovered) return dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:0.12] : [NSColor colorWithWhite:1 alpha:0.50];
  return nil;
}
- (void)drawPill {
  NSColor* c = [self fill];
  if (!c) return;
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:[self pillRect] xRadius:kRowRadius yRadius:kRowRadius];
  if (self.selected && !self.multi && !IsDark(self)) {
    [NSGraphicsContext saveGraphicsState];
    NSShadow* sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.20];
    sh.shadowBlurRadius = 2;
    sh.shadowOffset = NSMakeSize(0, -1);
    [sh set];
    [c setFill];
    [path fill];
    [NSGraphicsContext restoreGraphicsState];
    return;
  }
  [c setFill];
  [path fill];
}
// The row view includes the 2 pt gap between rows; the pill itself is 36 pt, as in Arc.
- (NSRect)pillRect {
  if (self.newTabRow) {  // the bottom kRowPitch of the header row
    CGFloat inset = (kRowPitch - kRowHeight) / 2;
    return NSMakeRect(0, self.flipped ? self.bounds.size.height - kRowPitch + inset : inset, self.bounds.size.width, kRowHeight);
  }
  NSRect r = NSInsetRect(self.bounds, 0, (self.bounds.size.height - kRowHeight) / 2);
  r.size.width -= 2;  // Arc: the row pill ends 2 pt short of the address pill (x 8-262 vs 8-264)
  return r;
}
- (void)drawBackgroundInRect:(NSRect)r {
  if (self.separatorAbove) {  // Arc: SidebarSeparator, 15% white (dark) / black (light)
    [(IsDark(self) ? [NSColor colorWithWhite:1 alpha:0.15] : [NSColor colorWithWhite:0 alpha:0.15]) setFill];
    CGFloat y = self.newTabRow ? 10 : 0;
    NSRectFillUsingOperation(NSMakeRect(10, self.flipped ? y : self.bounds.size.height - 1 - y, self.bounds.size.width - 20, 1),
                             NSCompositingOperationSourceOver);
  }
  if (!self.selected) [self drawPill];
}
- (void)drawSelectionInRect:(NSRect)r { [self drawPill]; }
- (BOOL)isEmphasized { return NO; }
- (NSString*)styleDescription {  // tests
  NSColor* c = [[self fill] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  return [NSString stringWithFormat:@"h=%.0f r=%.0f sel=%d hover=%d pressed=%d sep=%d alpha=%.2f", [self pillRect].size.height, kRowRadius,
                                    self.selected, self.hovered, self.pressed, self.separatorAbove, c ? c.alphaComponent : 0];
}
@end

// Arc's sidebar never shows a scrollbar track, even with a mouse attached or "Show scroll bars: Always": the
// scroller is always the thin overlay kind and only appears while you scroll a list that doesn't fit.
@interface SidebarScroller : NSScroller
@end
@implementation SidebarScroller
+ (BOOL)isCompatibleWithOverlayScrollers { return YES; }
@end
@interface SidebarScrollView : NSScrollView
@end
@implementation SidebarScrollView
- (void)setScrollerStyle:(NSScrollerStyle)style { [super setScrollerStyle:NSScrollerStyleOverlay]; }
@end

// Arc doesn't indent top-level tabs under the Pinned/Today headers; only folder contents are indented.
@interface SidebarOutlineView : NSOutlineView
@end
@implementation SidebarOutlineView
// Rows are exactly as wide as the visible sidebar (no hidden scroller gutter), so the pill's right corners show.
- (void)setFrameSize:(NSSize)size {
  NSClipView* clip = (NSClipView*)self.superview;
  if ([clip isKindOfClass:NSClipView.class] && clip.bounds.size.width > 0) size.width = clip.bounds.size.width;
  [super setFrameSize:size];
}
// Arc has no disclosure triangles: folders show their own chevron and toggle on click.
- (NSRect)frameOfOutlineCellAtRow:(NSInteger)row { return NSZeroRect; }
- (void)mouseDown:(NSEvent*)e {
  NSInteger row = [self rowAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
  SidebarRowView* rv = row >= 0 ? (SidebarRowView*)[self rowViewAtRow:row makeIfNecessary:NO] : nil;
  if (![rv isKindOfClass:SidebarRowView.class]) rv = nil;
  rv.pressed = YES;
  rv.needsDisplay = YES;
  [super mouseDown:e];  // tracks until mouse up
  rv.pressed = NO;
  rv.needsDisplay = YES;
}
- (NSRect)frameOfCellAtColumn:(NSInteger)column row:(NSInteger)row {
  NSRect f = [super frameOfCellAtColumn:column row:row];
  NSRect rr = [self rectOfRow:row];
  CGFloat x = NSMinX(rr) + MAX(0, [self levelForRow:row] - 1) * self.indentationPerLevel;
  f.size.width = NSMaxX(rr) - x;
  f.origin.x = x;
  return f;
}
@end


// The window backdrop's Space tint; tells the window when light/dark changes so the default theme can follow.
@interface ThemeBackdropView : NSView
@property(nonatomic, copy) void (^appearanceChanged)(void);
@end
@implementation ThemeBackdropView
- (void)viewDidChangeEffectiveAppearance {
  [super viewDidChangeEffectiveAppearance];
  if (self.appearanceChanged) self.appearanceChanged();
}
@end

// Arc's Space title row: just the name; the "..." button appears on hover; right-click opens the Space menu.
@interface SpaceHeaderView : NSView
@property(nonatomic, weak) NSView* reveal;
@property(nonatomic, copy) NSMenu* (^menuProvider)(void);
@end
@implementation SpaceHeaderView
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                                                             NSTrackingInVisibleRect
                                                       owner:self userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)e { self.reveal.alphaValue = 1; }
- (void)mouseExited:(NSEvent*)e { self.reveal.alphaValue = 0; }
- (NSMenu*)menuForEvent:(NSEvent*)e { return self.menuProvider ? self.menuProvider() : nil; }
@end

// Arc: "Drag a tab from your sidebar into the middle of the screen to create a Split View" (#37). The page card takes
// sidebar drags; the side nearest the pointer is where the new pane goes, shown by a tinted half while dragging.
@interface PageDropView : NSView
@property(nonatomic, weak) MainWindowController* owner;
@property(nonatomic, strong) NSView* preview;
@end

@interface MainWindowController ()
- (BOOL)canDropOnPage:(id<NSDraggingInfo>)info;
- (BOOL)dropOnPage:(id<NSDraggingInfo>)info side:(NSInteger)side;
- (void)favoriteClicked:(ArcItem*)item;
- (void)favoriteHovered:(ArcItem*)item rect:(NSRect)rect;
- (NSMenu*)sidebarMenuForItem:(ArcItem*)item;
- (BOOL)acceptFavoriteDrop:(id<NSDraggingInfo>)info index:(NSUInteger)index;
- (BOOL)canDropFavorite:(id<NSDraggingInfo>)info;
- (NSImage*)iconImageForItem:(ArcItem*)item;
- (ArcItem*)shownItem;
- (BOOL)usingDefaultTheme;
@end

// Arc's Favorites: a grid of icon tiles above the Space (rows of up to 4, balanced: 6 favorites = 2 rows of 3).
// Tiles are 47 pt tall, 8 pt apart, radius 10, 10% white; the open favorite is brighter.
constexpr CGFloat kFavTileHeight = 47, kFavRowGap = 8, kFavColGap = 9, kFavRadius = 10;
// Unread count a page puts in its title, as Gmail ("Inbox (12) - ..."), Slack/LinkedIn/X ("(3) ..."),
// Outlook ("Mail - 5 unread") do. 0 = none. Arc shows it as a badge on the Favorite's tile.
NSInteger UnreadCountFromTitle(NSString* title) {
  if (!title.length) return 0;
  static NSRegularExpression* lead, *paren, *word;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lead = [NSRegularExpression regularExpressionWithPattern:@"^\\s*[\\(\\[](\\d{1,5})\\+?[\\)\\]]" options:0 error:nil];
    paren = [NSRegularExpression regularExpressionWithPattern:@"\\((\\d{1,5})\\+?\\)" options:0 error:nil];
    word = [NSRegularExpression regularExpressionWithPattern:@"(\\d{1,5})\\s+(unread|new)\\b"
                                                     options:NSRegularExpressionCaseInsensitive error:nil];
  });
  NSRange all = NSMakeRange(0, title.length);
  for (NSRegularExpression* re in @[ lead, paren, word ]) {
    NSTextCheckingResult* m = [re firstMatchInString:title options:0 range:all];
    if (m) return [[title substringWithRange:[m rangeAtIndex:1]] integerValue];
  }
  return 0;
}

@interface FavoritesGridView : NSView <NSViewToolTipOwner>
@property(nonatomic, weak) MainWindowController* owner;
@property(nonatomic, copy) NSArray<ArcItem*>* items;
@property(nonatomic) NSInteger hovered;
@property(nonatomic) BOOL dropTarget;
+ (NSUInteger)rowsForCount:(NSUInteger)n;
- (CGFloat)heightForWidth:(CGFloat)w;
@end
@implementation FavoritesGridView
+ (NSUInteger)rowsForCount:(NSUInteger)n { return n ? (n + 3) / 4 : 0; }
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    _hovered = -1;
    [self registerForDraggedTypes:@[ @"io.github.donnadieu.notarc.sidebar-item" ]];
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (NSUInteger)columns {
  NSUInteger n = self.items.count, rows = [FavoritesGridView rowsForCount:n];
  return rows ? (n + rows - 1) / rows : 0;
}
- (CGFloat)heightForWidth:(CGFloat)w {
  NSUInteger rows = [FavoritesGridView rowsForCount:self.items.count];
  return rows ? rows * kFavTileHeight + (rows - 1) * kFavRowGap : 0;
}
- (NSRect)tileRect:(NSUInteger)i {
  NSUInteger cols = MAX((NSUInteger)1, [self columns]);
  CGFloat w = (self.bounds.size.width - (cols - 1) * kFavColGap) / cols;
  NSUInteger r = i / cols, c = i % cols;
  return NSMakeRect(round(c * (w + kFavColGap)), r * (kFavTileHeight + kFavRowGap), round(w), kFavTileHeight);
}
- (NSInteger)indexAt:(NSPoint)p {
  for (NSUInteger i = 0; i < self.items.count; ++i)
    if (NSPointInRect(p, [self tileRect:i])) return (NSInteger)i;
  return -1;
}
- (void)setItems:(NSArray<ArcItem*>*)items {
  _items = [items copy];
  [self removeAllToolTips];
  for (NSUInteger i = 0; i < _items.count; ++i) [self addToolTipRect:[self tileRect:i] owner:self userData:NULL];
  self.needsDisplay = YES;
}
- (void)setFrameSize:(NSSize)s {
  [super setFrameSize:s];
  self.items = _items;
}
- (NSString*)view:(NSView*)v stringForToolTip:(NSToolTipTag)tag point:(NSPoint)p userData:(void*)d {
  NSInteger i = [self indexAt:p];
  return i >= 0 ? self.items[(NSUInteger)i].displayTitle : @"";
}
- (void)drawRect:(NSRect)dirty {
  BOOL dark = IsDark(self);
  ArcItem* shown = [self.owner shownItem];
  for (NSUInteger i = 0; i < self.items.count; ++i) {
    ArcItem* it = self.items[i];
    BOOL sel = it == shown, hov = (NSInteger)i == self.hovered;
    CGFloat a = dark ? (sel ? 0.22 : hov ? 0.15 : 0.10) : (sel ? 0.85 : hov ? 0.6 : 0.4);
    NSColor* fill = dark ? [NSColor colorWithSRGBRed:0.98 green:0.984 blue:1 alpha:a] : [NSColor colorWithWhite:1 alpha:a];
    NSRect r = [self tileRect:i];
    [fill setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:kFavRadius yRadius:kFavRadius] fill];
    NSImage* icon = [self.owner iconImageForItem:it];
    NSRect ir = NSMakeRect(round(NSMidX(r) - 8), round(NSMidY(r) - 8), 16, 16);
    if (icon.isTemplate) {
      NSImage* tinted = [icon copy];
      [tinted lockFocus];
      [(dark ? [NSColor colorWithWhite:1 alpha:0.6] : [NSColor colorWithWhite:0 alpha:0.5]) set];
      NSRectFillUsingOperation(NSMakeRect(0, 0, tinted.size.width, tinted.size.height), NSCompositingOperationSourceAtop);
      [tinted unlockFocus];
      icon = tinted;
    }
    [icon drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    // Arc's unread badge: a small pill over the icon's top-right corner (a dot when there's no room for the number).
    NSInteger unread = it.hideUnreadBadge ? 0 : UnreadCountFromTitle(it.liveTitle);
    if (unread > 0) {
      NSString* text = unread > 99 ? @"99+" : [NSString stringWithFormat:@"%ld", (long)unread];
      NSDictionary* attrs = @{NSFontAttributeName : [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
                              NSForegroundColorAttributeName : NSColor.whiteColor};
      NSSize ts = [text sizeWithAttributes:attrs];
      CGFloat h = 13, w = MAX(h, ceil(ts.width) + 7);
      NSRect b = NSMakeRect(round(NSMaxX(ir) - 5), round(NSMinY(ir) - 6), w, h);
      [[NSColor colorWithSRGBRed:0.96 green:0.27 blue:0.33 alpha:1] setFill];
      [[NSBezierPath bezierPathWithRoundedRect:b xRadius:h / 2 yRadius:h / 2] fill];
      [text drawAtPoint:NSMakePoint(round(NSMidX(b) - ts.width / 2), round(NSMidY(b) - ts.height / 2)) withAttributes:attrs];
    }
  }
  if (self.dropTarget) {
    [[NSColor colorWithWhite:dark ? 1 : 0 alpha:0.25] setStroke];
    NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:kFavRadius yRadius:kFavRadius];
    p.lineWidth = 2;
    [p stroke];
  }
}
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                                             NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                                       owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent*)e {
  NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
  if (i != self.hovered) {
    self.hovered = i;
    self.needsDisplay = YES;
    [self.owner favoriteHovered:i >= 0 ? self.items[(NSUInteger)i] : nil rect:i >= 0 ? [self tileRect:(NSUInteger)i] : NSZeroRect];
  }
}
- (void)mouseExited:(NSEvent*)e {
  self.hovered = -1;
  self.needsDisplay = YES;
  [self.owner favoriteHovered:nil rect:NSZeroRect];
}
- (void)mouseUp:(NSEvent*)e {
  NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
  if (i >= 0) [self.owner favoriteClicked:self.items[(NSUInteger)i]];
}
- (NSMenu*)menuForEvent:(NSEvent*)e {
  NSInteger i = [self indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
  return i >= 0 ? [self.owner sidebarMenuForItem:self.items[(NSUInteger)i]] : nil;
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
  BOOL ok = [self.owner canDropFavorite:info];
  self.dropTarget = ok;
  self.needsDisplay = YES;
  return ok ? NSDragOperationMove : NSDragOperationNone;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return self.dropTarget ? NSDragOperationMove : NSDragOperationNone; }
- (void)draggingExited:(id<NSDraggingInfo>)info { self.dropTarget = NO; self.needsDisplay = YES; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
  self.dropTarget = NO;
  self.needsDisplay = YES;
  NSInteger i = [self indexAt:[self convertPoint:info.draggingLocation fromView:nil]];
  return [self.owner acceptFavoriteDrop:info index:i >= 0 ? (NSUInteger)i : self.items.count];
}
@end

@implementation PageDropView
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) [self registerForDraggedTypes:@[ @"io.github.donnadieu.notarc.sidebar-item" ]];
  return self;
}
// 0 right, 1 left, 2 bottom, 3 top: the edge closest to the point (by fraction of width/height).
+ (NSInteger)sideForPoint:(NSPoint)p inSize:(NSSize)s {
  CGFloat fx = s.width > 0 ? p.x / s.width : 0.5, fy = s.height > 0 ? p.y / s.height : 0.5;
  CGFloat dRight = 1 - fx, dLeft = fx, dTop = 1 - fy, dBottom = fy;
  CGFloat m = MIN(MIN(dRight, dLeft), MIN(dTop, dBottom));
  if (m == dRight) return 0;
  if (m == dLeft) return 1;
  return m == dBottom ? 2 : 3;
}
- (NSInteger)sideFor:(id<NSDraggingInfo>)info {
  return [PageDropView sideForPoint:[self convertPoint:info.draggingLocation fromView:nil] inSize:self.bounds.size];
}
- (void)showPreview:(NSInteger)side {
  if (!self.preview) {
    self.preview = [[NSView alloc] initWithFrame:NSZeroRect];
    self.preview.wantsLayer = YES;
    self.preview.layer.backgroundColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.22].CGColor;
    self.preview.layer.borderColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.6].CGColor;
    self.preview.layer.borderWidth = 2;
    self.preview.layer.cornerRadius = 8;
  }
  NSRect b = NSInsetRect(self.bounds, 6, 6), r = b;
  if (side == 0) r = NSMakeRect(NSMidX(b), b.origin.y, b.size.width / 2, b.size.height);
  if (side == 1) r = NSMakeRect(b.origin.x, b.origin.y, b.size.width / 2, b.size.height);
  if (side == 2) r = NSMakeRect(b.origin.x, b.origin.y, b.size.width, b.size.height / 2);
  if (side == 3) r = NSMakeRect(b.origin.x, NSMidY(b), b.size.width, b.size.height / 2);
  self.preview.frame = r;
  [self addSubview:self.preview positioned:NSWindowAbove relativeTo:nil];
}
- (NSDragOperation)draggingEntered:(id<NSDraggingInfo>)info {
  if (![self.owner canDropOnPage:info]) return NSDragOperationNone;
  [self showPreview:[self sideFor:info]];
  return NSDragOperationMove;
}
- (NSDragOperation)draggingUpdated:(id<NSDraggingInfo>)info { return [self draggingEntered:info]; }
- (void)draggingExited:(id<NSDraggingInfo>)info { [self.preview removeFromSuperview]; }
- (void)draggingEnded:(id<NSDraggingInfo>)info { [self.preview removeFromSuperview]; }
- (BOOL)performDragOperation:(id<NSDraggingInfo>)info {
  [self.preview removeFromSuperview];
  return [self.owner dropOnPage:info side:[self sideFor:info]];
}
@end

NSInteger PageDropSide(NSPoint p, NSSize s) { return [PageDropView sideForPoint:p inSize:s]; }

@interface SplitDividerView : NSView
@property(nonatomic, weak) MainWindowController* owner;
@property(nonatomic) NSUInteger index;
@property(nonatomic) BOOL horizontal;
@end

@implementation SplitDividerView
- (void)resetCursorRects {
  [self addCursorRect:self.bounds
               cursor:self.horizontal ? NSCursor.resizeUpDownCursor : NSCursor.resizeLeftRightCursor];
}
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (void)mouseDown:(NSEvent*)event {}
- (void)mouseDragged:(NSEvent*)event {
  NSView* content = self.superview;
  NSPoint p = [content convertPoint:event.locationInWindow fromView:nil];
  NSRect b = content.bounds;
  CGFloat position = self.horizontal ? (b.size.height - p.y) / b.size.height : p.x / b.size.width;
  [self.owner moveDivider:self.index toPosition:position];
}
@end

static BOOL RemoveItem(ArcItem* parent, ArcItem* target);

// Capture Area overlay: dims the page, the dragged rectangle shows clear with a size label.
@interface CaptureAreaView : NSView
@property(nonatomic, copy) void (^finished)(NSRect rect);  // page points, top-left origin; empty = cancelled
@end

@implementation CaptureAreaView {
  NSPoint _start;
  NSRect _sel;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
- (void)drawRect:(NSRect)dirty {
  NSBezierPath* p = [NSBezierPath bezierPathWithRect:self.bounds];
  if (!NSIsEmptyRect(_sel)) [p appendBezierPathWithRect:_sel];
  p.windingRule = NSWindingRuleEvenOdd;
  [[NSColor colorWithWhite:0 alpha:0.35] setFill];
  [p fill];
  if (NSIsEmptyRect(_sel)) {
    NSDictionary* a = @{NSForegroundColorAttributeName : NSColor.whiteColor, NSFontAttributeName : [NSFont systemFontOfSize:15 weight:NSFontWeightMedium]};
    NSString* hint = @"Drag to capture an area. Esc cancels.";
    NSSize s = [hint sizeWithAttributes:a];
    [hint drawAtPoint:NSMakePoint(NSMidX(self.bounds) - s.width / 2, NSMidY(self.bounds) - s.height / 2) withAttributes:a];
    return;
  }
  [[NSColor colorWithWhite:1 alpha:0.9] setStroke];
  NSBezierPath* b = [NSBezierPath bezierPathWithRect:NSInsetRect(_sel, 0.5, 0.5)];
  b.lineWidth = 1;
  [b stroke];
  NSString* size = [NSString stringWithFormat:@"%.0f × %.0f", _sel.size.width, _sel.size.height];
  NSDictionary* a = @{NSForegroundColorAttributeName : NSColor.whiteColor, NSFontAttributeName : [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium]};
  [size drawAtPoint:NSMakePoint(NSMinX(_sel), NSMaxY(_sel) + 4) withAttributes:a];
}
- (void)mouseDown:(NSEvent*)e {
  _start = [self convertPoint:e.locationInWindow fromView:nil];
  _sel = NSZeroRect;
}
- (void)mouseDragged:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  _sel = NSIntersectionRect(NSMakeRect(MIN(p.x, _start.x), MIN(p.y, _start.y), fabs(p.x - _start.x), fabs(p.y - _start.y)), self.bounds);
  self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent*)e { [self finish:(_sel.size.width >= 4 && _sel.size.height >= 4) ? _sel : NSZeroRect]; }
- (void)keyDown:(NSEvent*)e {
  if (e.keyCode == 53) [self finish:NSZeroRect];
  else [super keyDown:e];
}
- (void)cancelOperation:(id)sender { [self finish:NSZeroRect]; }
- (void)finish:(NSRect)r {
  void (^f)(NSRect) = self.finished;
  self.finished = nil;
  if (f) f(r);
}
@end

// Results of DevTools methods (used for page captures: Page.captureScreenshot).
class DevToolsResults : public CefDevToolsMessageObserver {
 public:
  std::map<int, std::function<void(bool, const std::string&)>> pending;
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message_id, bool success, const void* result,
                              size_t result_size) override {
    auto it = pending.find(message_id);
    if (it == pending.end()) return;
    auto cb = it->second;
    pending.erase(it);
    cb(success, std::string(static_cast<const char*>(result), result_size));
  }
  IMPLEMENT_REFCOUNTING(DevToolsResults);
};

// Which window hosts each page (#39). Every window shares one BrowserClient, so its callbacks look the page up
// here; a page moved to another window keeps running and its events follow it.
static NSMapTable<NSNumber*, MainWindowController*>* gBrowserOwners;
static MainWindowController* OwnerOf(int browserId, MainWindowController* fallback) {
  MainWindowController* w = [gBrowserOwners objectForKey:@(browserId)];
  return w ?: fallback;
}
// The first window owns the shared pieces (profile contexts, sidebar save); others are views onto the same
// Spaces, like Arc's StorableWindows (one sidebar, each window with its own Space, tab and split).
static __weak MainWindowController* gMainWindow;
static NSMutableArray<MainWindowController*>* gWindows;
static BOOL gQuitting = NO;  // quitting closes every window, but the other windows should come back next launch

@implementation MainWindowController {
  NSMutableArray<ArcSpace*>* _spaces;
  ArcSpace* _space;  // currently shown Space
  NSPopUpButton* _spacePicker;
  NSOutlineView* _outline;
  NSView* _content;
  CardEdgeView* _cardEdge;
  __weak ArcItem* _lastTidied;
  NSMutableSet<NSString*>* _translateOffered;  // hosts offered a translation this launch (#52)
  NSString* _lastTranslateOffer;
  NSSize _lastCopiedImageSize;  // tests (#70)
  ArcItem* _maximizedPane;       // split pane filling the card (#37)
  NSDictionary* _lastNotification;  // tests (#78)  // for the "Renamed to ..." toast's Undo (#18)  // border and light-mode shadow of the page card (#122)
  id _swipeMonitor;           // two-finger swipe back/forward (#77)
  NSView* _swipeArrow;
  CefRefPtr<BrowserClient> _client;
  std::map<int, CefRefPtr<CefBrowser>> _browsers;
  NSMutableDictionary<NSNumber*, ChromePageHost*>* _chromePages;  // browser id -> Chrome-style page (#66)
  std::map<std::string, CefRefPtr<CefRequestContext>> _contexts;  // profile dir -> context
  std::set<std::string> _readyContexts;
  BOOL _importingFromArc;  // Import Everything from Arc is running
  BOOL _arcKeyFailed;      // ... and macOS didn't give Arc's key this time (don't ask twice)
  NSMutableDictionary<NSString*, NSMutableArray<ArcItem*>*>* _pendingTabs;  // waiting for their context
  ArcItem* _shown;
  BOOL _closing;
  NSPanel* _commandBar;
  NSTableView* _suggestionTable;
  NSScrollView* _suggestionScroll;
  CommandSuggestionList* _suggestionList;
  NSBox* _commandDivider;
  NSTextField* _commandField;
  NSImageView* _commandIcon;
  NSView* _commandScrim;
  NSButton* _navBack;
  NSView* _peekScrim;
  NSBox* _updateBanner;
  NSInteger _restartToUpdateClicks;
  BOOL _sidebarPeeking;      // the hidden sidebar shown floating over the page (pointer at the left edge)
  NSView* _edgeStrip;        // 6 pt strip at the window's left edge while the sidebar is hidden
  HoverTracker* _edgeTracker;
  HoverTracker* _peekTracker;
  NSTrackingArea* _peekArea;
  CALayer* _loadingGlow;     // Arc's glow along the page card's top edge while the shown page loads
  BOOL _pillButtonsForced;
  BOOL _testInactive;
  BOOL _todayHeaderHovered;
  NSButton* _navForward;
  BOOL _commandOpensNewTab;
  BOOL _saveScheduled;
  NSMutableArray<ArchivedTab*>* _archive;
  NSTimer* _archiveTimer;
  ArchiveWindowController* _archiveWindow;
  LibraryPanelView* _library;  // the sidebar's Library panel (Archive), nil until first opened
  BOOL _libraryShown;
  NSButton* _libraryButton;
  __weak NSResponder* _responderBeforeLibrary;
  ArchiveWindowController* _historyWindow;
  HistoryStore* _history;
  BOOL _focusMode;
  CAGradientLayer* _themeGradient;
  CALayer* _themeGrain;  // film grain over the theme (#26)
  NSPopover* _hoverCard;
  BOOL _hoverCardHasThumbnail;
  NSTimer* _thumbTimer;           // tab thumbnails (#65): copy of the shown tab, due 1 s after it settles
  NSUInteger _showGeneration;     // bumped on every tab switch; a copy started before a switch is dropped
  NSDate* _thumbPendingSince;     // a copy is in flight
  NSPanel* _switcher;             // Ctrl+Tab recent-tab switcher
  NSArray<ArcItem*>* _switcherItems;
  NSMutableArray<NSView*>* _switcherTiles;
  NSInteger _switcherIndex;
  NSEventModifierFlags _switcherMods;
  unsigned short _switcherKey;
  id _switcherMonitor;
  id _switcherResignObserver;
  NSTimer* _switcherRevealTimer;
  NSView* _mediaBar;
  NSView* _meetingBar;  // next meeting from Calendar (#56)
  NSTextField* _meetingTitle;
  NSButton* _meetingJoin;
  CalendarEvent* _meeting;
  NSTimer* _meetingTimer;
  NSArray<CalendarEvent*>* _todayEvents;
  NSDate* _calendarTestNow;  // tests: fixed clock
  NSPopover* _favPreview;      // Gmail / Calendar Favorite preview (#57)
  NSTimer* _favPreviewTimer;
  __weak ArcItem* _favPreviewItem;
  id _defaultsObserver;
  NSArray<NSDictionary*>* _lastFavoritePreview;
  NSButton* _callMic;
  NSButton* _callCam;
  NSMutableDictionary<NSNumber*, NSView*>* _crashViews;
  ArcItem* _hungItem;
  NSAlert* _hungAlert;
  NSTextField* _mediaTitle;
  NSButton* _mediaPlay;
  NSButton* _mediaMute;
  NSButton* _mediaPrev;
  NSButton* _mediaNext;
  NSImageView* _mediaArt;
  NSTextField* _mediaSubtitle;
  NSString* _mediaArtLoading;
  ArcItem* _mediaItem;
  NSScrollView* _sidebarScroll;
  NSTimer* _mediaTimer;
  ArcItem* _hoverItem;
  NSTimer* _hoverTimer;
  void (^_themePreview)(void);
  NSPopUpButton* _themePalette;
  NSUndoManager* _undo;
  BOOL _sidebarWasHidden;
  NSPanel* _findBar;
  NSSearchField* _findField;
  NSTextField* _findLabel;
  int _lastFindCount;
  NSMutableArray<ArcItem*>* _splitItems;  // panes of the active split, in order; nil when no split
  BOOL _splitHorizontal;
  BOOL _commandOpensSplit;
  BOOL _commandOpensLittle;
  BOOL _splitBefore;
  BOOL _pendingSplitHorizontal;
  ArcItem* _splitGroup;  // sidebar item of the split being shown
  NSMutableArray<NSView*>* _dividers;
  NSMutableArray<LittleWindowController*>* _littleWindows;
  NSMutableArray<LittleWindowController*>* _incognitoWindows;
  CefRefPtr<CefRequestContext> _incognitoContext;
  BOOL _incognitoReady;
  BOOL _commandOpensIncognito;
  LittleWindowController* _peek;
  NSView* _toast;
  AutofillController* _autofill;  // passwords and autofill (#67)
  NSView* _toolbar;
  NSMutableArray<NSDictionary*>* _sitePrompts;  // queue; first one is showing
  NSAlert* _siteAlert;
  NSPopover* _sitePopover;
  NSString* _siteSettingsOrigin;
  NSTextField* _address;
  NSTimer* _toastTimer;
  NSString* _lastClosedPeekURL;
  NSView* _sidebar;
  SidebarPillView* _addressPill;
  NSButton* _devToolsButton;  // Developer Mode (#68)
  NSMutableDictionary<NSString*, NoteEditorView*>* _noteEditors;  // notes on screen (one per pane), by item ID
  EaselView* _easelView;      // Easel canvas, shown in the page card
  NSScrollView* _easelScroll;
  ArcItem* _easelItem;
  NSMutableSet<NSString*>* _clipsRefreshing;  // live clips being re-rendered (easel folder | link | region)
  CefRefPtr<DevToolsResults> _devtoolsResults;
  std::map<int, CefRefPtr<CefRegistration>> _devtoolsRegs;
  int _devtoolsNextId;
  NSData* _lastCapture;
  NSString* _suggestRequested;               // search suggestions (#31): query last fetched
  NSString* _suggestQuery;                   // query the current _searchSuggestions belong to
  NSArray<NSString*>* _searchSuggestions;
  NSURLSessionDataTask* _suggestTask;
  NSUInteger _suggestToken;
  NSString* _lastCaptureLink;
  NSView* _captureOverlay;
  NSString* _captureDirectory;
  NSButton* _boostButton;   // Arc: Boost indicator in the address pill
  NSButton* _extensionsButton;  // puzzle piece in the address pill (Chrome-style pages only, #66)
  NSInteger _relaunchRequests;
  ExtensionPopup* _extensionPopup;  // the open extension popup bubble, if any (#66)
  NSString* _boostIndicator; // tests: "on" / "off" / "none"
  NSTextField* _addressPillText;
  NSView* _sidebarNav;
  NSView* _spaceBar;        // Arc's bottom bar: archive, Space icons, "+"
  NSStackView* _spaceIcons;
  NSView* _spaceHeader;            // Arc's Space title row: icon + name, "..." menu
  FavoritesGridView* _favGrid;     // Arc's Favorites tiles under the address pill
  BOOL _iconRefreshQueued;
  NSMutableDictionary<NSString*, NSString*>* _profileNames;  // profile folder -> name
  NSTextField* _spaceHeaderTitle;
  NSString* _lastSpaceSlide;   // tests: "left" / "right" / "none"
  NSMutableArray<Boost*>* _boosts;
  NSPanel* _boostPanel;
  Boost* _boostEditing;
  NSMutableDictionary<NSString*, NSView*>* _boostControls;
  BoostColorWheel* _boostWheel;
  int _zapBrowser;
  NSUInteger _cardPops;        // tests
  NSHashTable* _sidebarDirtyFrom;  // windows whose sidebar change other windows haven't picked up yet
  BOOL _sidebarRefreshScheduled;
  BOOL _syncingSidebar;
}

- (instancetype)initWithSpaces:(NSArray<ArcSpace*>*)spaces focusedSpaceID:(NSString*)focusedID {
  NSWindow* window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, 1280, 820)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable |
                          NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.title = @"NotArc";
  [window center];
  if ((self = [super initWithWindow:window])) {
    window.delegate = self;
    _spaces = [spaces mutableCopy];
    _space = spaces.firstObject;
    for (ArcSpace* s in spaces)
      if ([s.spaceID isEqualToString:focusedID]) _space = s;
    [self buildLayout];
  }
  return self;
}

- (void)buildLayout {
  NSView* root = self.window.contentView;
  NSRect bounds = root.bounds;

  // Window frame: one backdrop behind the sidebar and around the page card, tinted by the Space theme.
  NSVisualEffectView* frameView = [[NSVisualEffectView alloc] initWithFrame:bounds];
  frameView.material = NSVisualEffectMaterialSidebar;
  frameView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
  frameView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [root addSubview:frameView];
  NSView* sidebar = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, kSidebarWidth, bounds.size.height)];
  sidebar.autoresizingMask = NSViewHeightSizable;
  _sidebar = sidebar;
  // Space theme tint: a gradient over the whole frame, under every control.
  ThemeBackdropView* backdrop = [[ThemeBackdropView alloc] initWithFrame:bounds];
  __weak MainWindowController* weakOwner = self;
  backdrop.appearanceChanged = ^{ [weakOwner applyTheme]; };
  _themeView = backdrop;
  _themeView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _themeView.wantsLayer = YES;
  _themeGradient = [CAGradientLayer layer];
  _themeGradient.frame = _themeView.bounds;
  _themeGradient.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  _themeGradient.startPoint = CGPointMake(0.5, 1);
  _themeGradient.endPoint = CGPointMake(0.5, 0);
  [_themeView.layer addSublayer:_themeGradient];
  _themeGrain = [CALayer layer];
  _themeGrain.frame = _themeView.bounds;
  _themeGrain.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
  _themeGrain.backgroundColor = GrainPatternColor();
  _themeGrain.opacity = 0;
  [_themeView.layer addSublayer:_themeGrain];
  _themeView.hidden = YES;
  [root addSubview:_themeView];
  [root addSubview:sidebar];

  // Arc's mini player: a dark card above the bottom bar with the artwork (or the site's icon), what's playing and
  // the site on two lines, and back / play-pause / forward; mute shows while the pointer is over the card.
  MediaCardView* card = [[MediaCardView alloc] initWithFrame:NSMakeRect(8, 46, kSidebarWidth - 17, kMediaCardHeight)];
  card.hoverChanged = ^(BOOL inside) { [weakOwner updateMediaBar]; };
  _mediaBar = card;
  _mediaBar.wantsLayer = YES;
  _mediaBar.layer.cornerRadius = 8;
  auto mediaButton = ^NSButton*(NSString* symbol, NSString* label, SEL action, CGFloat size) {
    NSButton* b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:label]
                                     target:self action:action];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightMedium];
    b.toolTip = label;
    return b;
  };
  _mediaArt = [[NSImageView alloc] initWithFrame:NSMakeRect(13, 8, 16, 16)];
  _mediaArt.imageScaling = NSImageScaleProportionallyUpOrDown;
  _mediaArt.wantsLayer = YES;
  _mediaArt.layer.cornerRadius = 6;
  _mediaArt.layer.masksToBounds = YES;
  NSClickGestureRecognizer* goArt = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(mediaBarShowTab:)];
  [_mediaArt addGestureRecognizer:goArt];
  _mediaTitle = [FadingLabel labelWithString:@""];
  _mediaTitle.lineBreakMode = NSLineBreakByClipping;
  _mediaTitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
  _mediaTitle.frame = NSMakeRect(48, 24, 120, 16);
  NSClickGestureRecognizer* go = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(mediaBarShowTab:)];
  [_mediaTitle addGestureRecognizer:go];
  _mediaSubtitle = [FadingLabel labelWithString:@""];
  _mediaSubtitle.lineBreakMode = NSLineBreakByClipping;
  _mediaSubtitle.font = [NSFont systemFontOfSize:11];
  _mediaSubtitle.frame = NSMakeRect(48, 9, 120, 14);
  // Sizes measured from Arc: back / forward 13 pt wide, play 10, speaker 19 with its waves.
  _mediaPrev = mediaButton(@"backward.end.fill", @"Previous", @selector(mediaBarPrevious:), 13);
  _mediaPlay = mediaButton(@"pause.fill", @"Pause", @selector(mediaBarPlay:), 13);
  _mediaNext = mediaButton(@"forward.end.fill", @"Next", @selector(mediaBarNext:), 13);
  _mediaMute = mediaButton(@"speaker.wave.3.fill", @"Mute", @selector(mediaBarMute:), 13);
  // Arc's call controls: in a call, the bar shows microphone and camera toggles instead of play / mute.
  _callCam = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"video.fill" accessibilityDescription:@"Camera"]
                                target:self action:@selector(callBarCamera:)];
  _callCam.bordered = NO;
  _callCam.frame = NSMakeRect(kSidebarWidth - 16 - 56, 5, 24, 24);
  _callMic = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"mic.fill" accessibilityDescription:@"Microphone"]
                                target:self action:@selector(callBarMic:)];
  _callMic.bordered = NO;
  _callMic.frame = NSMakeRect(kSidebarWidth - 16 - 28, 5, 24, 24);
  _callCam.hidden = _callMic.hidden = YES;
  for (NSView* v in @[ _mediaArt, _mediaTitle, _mediaSubtitle, _mediaPrev, _mediaPlay, _mediaNext, _mediaMute, _callCam, _callMic ])
    [_mediaBar addSubview:v];
  _mediaBar.hidden = YES;
  [sidebar addSubview:_mediaBar];
  // Arc's next-meeting bar (#56): title, when, and Join for a video-call link; from the Mac's Calendar.
  // Arc's sidebar cards above the bottom bar (next meeting, update ready): a soft rounded card with an icon, one line
  // and a small capsule button in Arc's updater-button colours (white on light, black on dark).
  _meetingBar = SidebarBannerCard(@"calendar", self, @selector(joinMeeting:), @"Join");
  _meetingTitle = [_meetingBar viewWithTag:1];
  _meetingJoin = [_meetingBar viewWithTag:2];
  _updateBanner = SidebarBannerCard(@"arrow.down.circle.fill", self, @selector(restartToUpdate:), @"Restart");
  _updateBanner.hidden = YES;
  _updateBanner.toolTip = @"Restart NotArc to finish updating; your tabs come back";
  [sidebar addSubview:_updateBanner];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(updateReady:)
                                             name:UpdaterUpdateReadyNotification object:nil];
  _meetingBar.hidden = YES;
  [sidebar addSubview:_meetingBar];

  _spacePicker = [[NSPopUpButton alloc]
      initWithFrame:NSMakeRect(8, bounds.size.height - 120, kSidebarWidth - 16, 26) pullsDown:NO];
  _spacePicker.autoresizingMask = NSViewMinYMargin;
  [self rebuildSpacePicker];
  _spacePicker.target = self;
  _spacePicker.action = @selector(spaceChanged:);
  // The pop-up stays as the Space list model; Arc shows a plain title row instead of a drop-down.
  // Arc's Space title: the name in dim semibold text; "..." shows on hover; right-click opens the Space menu.
  SpaceHeaderView* header = [[SpaceHeaderView alloc] initWithFrame:NSMakeRect(8, bounds.size.height - 234, kSidebarWidth - 17, 34)];
  header.autoresizingMask = NSViewMinYMargin;
  _spaceHeader = header;
  _spaceHeaderTitle = [NSTextField labelWithString:@""];
  _spaceHeaderTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  _spaceHeaderTitle.textColor = [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* ap) {
    BOOL dark = [ap bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    return [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.45];
  }];
  _spaceHeaderTitle.lineBreakMode = NSLineBreakByTruncatingTail;
  _spaceHeaderTitle.frame = NSMakeRect(7, 8, _spaceHeader.bounds.size.width - 44, 18);
  [_spaceHeader addSubview:_spaceHeaderTitle];
  NSButton* more = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"ellipsis" accessibilityDescription:@"Space menu"]
                                      target:self action:@selector(showSpaceMenu:)];
  more.bordered = NO;
  more.toolTip = @"Space options";
  more.contentTintColor = NSColor.secondaryLabelColor;
  more.frame = NSMakeRect(_spaceHeader.bounds.size.width - 30, 4, 26, 26);
  more.alphaValue = 0;
  [_spaceHeader addSubview:more];
  header.reveal = more;
  header.menuProvider = ^NSMenu*{ return [weakOwner spaceMenu]; };
  NSClickGestureRecognizer* rename = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(renameCurrentSpace:)];
  rename.numberOfClicksRequired = 2;  // double-click the name to rename, as in Arc
  [_spaceHeaderTitle addGestureRecognizer:rename];
  [sidebar addSubview:_spaceHeader];
  _favGrid = [[FavoritesGridView alloc] initWithFrame:NSMakeRect(8, bounds.size.height - 90, kSidebarWidth - 17, 0)];
  _favGrid.owner = self;
  _favGrid.autoresizingMask = NSViewMinYMargin;
  [sidebar addSubview:_favGrid];
  [self updateSpaceHeader];

  NSScrollView* scroll = [[SidebarScrollView alloc]
      initWithFrame:NSMakeRect(8, 42, kSidebarWidth - 17, bounds.size.height - 166)];
  scroll.autoresizingMask = NSViewHeightSizable;
  scroll.drawsBackground = NO;
  scroll.verticalScroller = [SidebarScroller new];
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.autohidesScrollers = YES;
  scroll.scrollerStyle = NSScrollerStyleOverlay;
  scroll.automaticallyAdjustsContentInsets = NO;
  _sidebarScroll = scroll;

  _outline = [[SidebarOutlineView alloc] initWithFrame:scroll.bounds];
  NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"item"];
  col.width = kSidebarWidth - 17;
  col.resizingMask = NSTableColumnAutoresizingMask;
  [_outline addTableColumn:col];
  _outline.outlineTableColumn = col;
  _outline.headerView = nil;
  _outline.backgroundColor = NSColor.clearColor;
  _outline.rowHeight = kRowHeight;
  _outline.style = NSTableViewStylePlain;
  _outline.intercellSpacing = NSMakeSize(0, 0);  // rows carry Arc's 5 pt gap themselves (41 pt pitch)
  _outline.indentationPerLevel = 16;  // Arc: folder contents sit 16 pt in
  _outline.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
  _outline.floatsGroupRows = NO;
  _outline.allowsMultipleSelection = YES;
  _outline.dataSource = self;
  _outline.delegate = self;
  _outline.target = self;
  _outline.action = @selector(sidebarClicked:);
  [_outline registerForDraggedTypes:@[ kSidebarItemPasteboardType ]];
  [_outline addTrackingArea:[[NSTrackingArea alloc]
                                initWithRect:NSZeroRect
                                     options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited |
                                             NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                       owner:self
                                    userInfo:nil]];
  [_outline setDraggingSourceOperationMask:NSDragOperationMove forLocal:YES];
  _outline.menu = [[NSMenu alloc] initWithTitle:@"Sidebar"];
  _outline.menu.delegate = self;
  scroll.documentView = _outline;
  [sidebar addSubview:scroll];

  // Sidebar top, as in Arc: window buttons, then sidebar toggle; back, forward, reload at the right; then the
  // 36 pt address pill (8 pt from each side, 46 pt from the top) with copy-link and site-settings buttons.
  // Arc: window buttons and these icons share one line centred 23.5 pt below the top; toggle centred at x 94,
  // back / forward / reload at 183 / 217 / 251.
  _sidebarNav = [[NSView alloc] initWithFrame:NSMakeRect(0, bounds.size.height - 37, kSidebarWidth, 28)];
  _sidebarNav.autoresizingMask = NSViewMinYMargin;
  NSArray* nav = @[ @[ @"sidebar.left", @"toggleSidebar:", @81 ], @[ @"arrow.left", @"goBack:", @170 ],
                    @[ @"arrow.right", @"goForward:", @204 ], @[ @"arrow.clockwise", @"reloadPage:", @238 ] ];
  for (NSArray* n in nav) {
    NSButton* b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:n[0] accessibilityDescription:nil]
                                     target:self action:NSSelectorFromString(n[1])];
    b.bordered = NO;
    b.contentTintColor = SidebarIconColor();
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
    b.frame = NSMakeRect([n[2] doubleValue], 1, 26, 26);
    if ([n[1] isEqual:@"goBack:"]) _navBack = b;
    if ([n[1] isEqual:@"goForward:"]) _navForward = b;
    [_sidebarNav addSubview:b];
  }
  [sidebar addSubview:_sidebarNav];
  _addressPill = [[SidebarPillView alloc] initWithFrame:NSMakeRect(8, bounds.size.height - 82, kSidebarWidth - 17, 36)];
  _addressPill.wantsLayer = YES;
  _addressPill.autoresizingMask = NSViewMinYMargin;
  __weak MainWindowController* weakSelf = self;
  _addressPill.onClick = ^{ [weakSelf openLocation:nil]; };
  _addressPill.hoverChanged = ^{ [weakSelf updatePillButtons]; };
  _addressPillText = [NSTextField labelWithString:@""];
  _addressPillText.font = [NSFont systemFontOfSize:13];
  _addressPillText.textColor = [NSColor colorWithName:nil dynamicProvider:^NSColor*(NSAppearance* ap) {
    BOOL dark = [ap bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]] == NSAppearanceNameDarkAqua;
    return dark ? [NSColor colorWithSRGBRed:0xaa / 255.0 green:0xa8 / 255.0 blue:0xb9 / 255.0 alpha:1]
                : [NSColor colorWithWhite:0 alpha:0.6];
  }];
  _addressPillText.lineBreakMode = NSLineBreakByTruncatingTail;
  _addressPillText.frame = NSMakeRect(12, 9, _addressPill.bounds.size.width - 12 - 60, 18);
  [_addressPill addSubview:_addressPillText];
  NSMutableArray* pillButtons = [@[ @[ @"paintbrush.pointed", @"editBoost:", @"Boost This Site" ], @[ @"link", @"copyCurrentURL:", @"Copy URL" ],
                                    @[ @"slider.horizontal.3", @"showSiteSettings:", @"Site Settings" ] ] mutableCopy];
  // Arc's extension picker sits in the address pill; extensions only run in Chrome-style pages.
  if (ChromePagesEnabled()) [pillButtons addObject:@[ @"puzzlepiece.extension", @"showExtensionPicker:", @"Extensions" ]];
  _addressPillText.frame = NSMakeRect(11, 9, _addressPill.bounds.size.width - 11 - 8 - 26 * (CGFloat)pillButtons.count, 18);
  CGFloat px = _addressPill.bounds.size.width - 6 - 26 * (CGFloat)pillButtons.count;
  for (NSArray* n in pillButtons) {
    NSButton* b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:n[0] accessibilityDescription:n[2]]
                                     target:self action:NSSelectorFromString(n[1])];
    b.bordered = NO;
    b.toolTip = n[2];
    b.contentTintColor = NSColor.secondaryLabelColor;
    b.frame = NSMakeRect(px, 5, 26, 26);
    if ([n[1] isEqualToString:@"editBoost:"]) _boostButton = b;
    if ([n[1] isEqualToString:@"showExtensionPicker:"]) _extensionsButton = b;
    b.tag = 90;  // site buttons: shown while the pointer is over the pill (updatePillButtons)
    [_addressPill addSubview:b];
    px += 26;
  }
  // Developer Mode sites get a Developer Tools button left of the others (hidden otherwise).
  _devToolsButton = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"hammer" accessibilityDescription:@"Developer Tools"]
                                       target:self action:@selector(toggleDevTools:)];
  _devToolsButton.bordered = NO;
  _devToolsButton.toolTip = @"Developer Tools (Developer Mode)";
  _devToolsButton.contentTintColor = NSColor.secondaryLabelColor;
  _devToolsButton.frame = NSMakeRect(_addressPill.bounds.size.width - 6 - 4 * 26, 5, 26, 26);
  _devToolsButton.hidden = YES;
  [_addressPill addSubview:_devToolsButton];
  [sidebar addSubview:_addressPill];

  // Bottom bar, as in Arc: archive (Library) at the left, one icon per Space in the middle, "+" menu at the right.
  _spaceBar = [[NSView alloc] initWithFrame:NSMakeRect(8, 5.5, kSidebarWidth - 17, 30)];  // Arc: icons centred 20.5 pt up
  NSButton* lib = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"archivebox" accessibilityDescription:@"Archive"]
                                     target:self action:@selector(showArchive:)];
  lib.bordered = NO;
  lib.toolTip = @"Archive";
  lib.contentTintColor = SidebarIconColor();
  lib.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightMedium];
  lib.frame = NSMakeRect(2, 2, 26, 26);
  _libraryButton = lib;
  [_spaceBar addSubview:lib];
  NSButton* plus = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New"]
                                      target:self action:@selector(showNewMenu:)];
  plus.bordered = NO;
  plus.toolTip = @"New Tab, Folder or Space";
  plus.contentTintColor = SidebarIconColor();
  plus.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium];
  plus.frame = NSMakeRect(_spaceBar.bounds.size.width - 29, 2, 26, 26);
  [_spaceBar addSubview:plus];
  _spaceIcons = [NSStackView stackViewWithViews:@[]];
  _spaceIcons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _spaceIcons.spacing = 0;
  _spaceIcons.distribution = NSStackViewDistributionGravityAreas;
  _spaceIcons.frame = NSMakeRect(32, 0, _spaceBar.bounds.size.width - 64, 30);
  [_spaceBar addSubview:_spaceIcons];
  [sidebar addSubview:_spaceBar];
  [self rebuildSpaceBar];  // rebuildSpacePicker above ran before the bar existed

  PageDropView* pageDrop = [[PageDropView alloc] initWithFrame:NSMakeRect(kSidebarWidth, 0, bounds.size.width - kSidebarWidth,
                                                                           bounds.size.height)];
  pageDrop.owner = self;
  _content = pageDrop;
  _content.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _content.wantsLayer = YES;
  _content.layer.cornerRadius = kCardRadius;
  _content.layer.masksToBounds = YES;
  _cardEdge = [[CardEdgeView alloc] initWithFrame:_content.frame];
  _cardEdge.wantsLayer = YES;
  _cardEdge.card = _content;
  [root addSubview:_cardEdge];
  [root addSubview:_content];

  _toolbar = [[NSView alloc] initWithFrame:NSMakeRect(kSidebarWidth, bounds.size.height - kToolbarHeight,
                                                      bounds.size.width - kSidebarWidth, kToolbarHeight)];
  _toolbar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
  NSArray* buttons = @[ @[ @"chevron.left", @"goBack:" ], @[ @"chevron.right", @"goForward:" ], @[ @"arrow.clockwise", @"reloadPage:" ] ];
  CGFloat bx = 8;
  for (NSArray* b in buttons) {
    NSButton* btn = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:b[0] accessibilityDescription:nil]
                                       target:self action:NSSelectorFromString(b[1])];
    btn.bordered = NO;
    btn.frame = NSMakeRect(bx, 6, 26, 26);
    btn.tag = 1;  // shifted right of the window buttons when the sidebar is hidden
    [_toolbar addSubview:btn];
    bx += 28;
  }
  _address = [[NSTextField alloc] initWithFrame:NSMakeRect(bx + 6, 7, _toolbar.bounds.size.width - bx - 16, 24)];
  _address.autoresizingMask = NSViewWidthSizable;
  _address.bezelStyle = NSTextFieldRoundedBezel;
  _address.font = [NSFont systemFontOfSize:12];
  _address.lineBreakMode = NSLineBreakByTruncatingMiddle;
  _address.cell.scrollable = YES;
  _address.target = self;
  _address.action = @selector(addressEntered:);
  _address.tag = 1;
  [_toolbar addSubview:_address];
  _toolbar.hidden = YES;
  [root addSubview:_toolbar];
  if (!SettingBool(kSettingShowSpaceHeader)) [self applySpaceHeader:NO];
  [self layoutContentArea];

  [self reloadSidebar];
}

// Sidebar column, top down (Arc): pill 46-82; Favorites grid from 90; Space title 8 below the grid; tabs after it,
// down to the bottom bar (or the media bar above it).
- (void)layoutSidebar {
  CGFloat H = _sidebar.bounds.size.height, w = kSidebarWidth - 17;
  CGFloat gridH = [_favGrid heightForWidth:w];
  _favGrid.hidden = gridH == 0;
  _favGrid.frame = NSMakeRect(8, H - 90 - gridH, w, gridH);
  CGFloat below = gridH ? 90 + gridH : 82;
  _spaceHeader.frame = NSMakeRect(8, H - below - 42, w, 34);
  CGFloat top = _spaceHeader.hidden ? below + 8 : below + 42;
  CGFloat bottom = _mediaBar.hidden ? 42 : 46 + kMediaCardHeight + 4;
  NSRect mf = _meetingBar.frame;
  mf.origin.y = bottom + 2;
  _meetingBar.frame = mf;
  if (!_meetingBar.hidden) bottom += 40;
  NSRect uf = _updateBanner.frame;
  uf.origin.y = bottom + 2;
  _updateBanner.frame = uf;
  if (!_updateBanner.hidden) bottom += 40;
  _sidebarScroll.frame = NSMakeRect(8, bottom, w, MAX(0, H - top - bottom));
  // The Library takes the place of Favorites, the Space title and the tabs, between the address pill and the bars.
  _library.hidden = !_libraryShown;
  if (_libraryShown) {
    _library.frame = NSMakeRect(8, bottom, w, MAX(0, H - 90 - bottom));
    _favGrid.hidden = YES;
  }
  _sidebarScroll.hidden = _libraryShown;
  _spaceHeader.alphaValue = _libraryShown ? 0 : 1;
}

- (void)updateFavoritesGrid {
  NSMutableArray* items = [NSMutableArray array];
  for (ArcItem* f in _space.favorites.children)
    if (f.url.length && !f.isFolder) [items addObject:f];
  _favGrid.items = items;
  [self layoutSidebar];
}

// Arc's default theme when a Space has no colour of its own: deep indigo in dark mode (top #120C39 to #140D40).
- (BOOL)usingDefaultTheme { return _space.themeColors.count == 0 && IsDark(self.window.contentView); }

// Arc lines the window buttons up with the sidebar icons (centres 19.5 / 42.5 / 66, 23.5 pt down).
- (void)positionWindowButtons {
  NSWindow* win = self.window;
  if (win.styleMask & NSWindowStyleMaskFullScreen) return;
  NSButton* close = [win standardWindowButton:NSWindowCloseButton];
  NSView* container = close.superview.superview;
  if (!container) return;
  CGFloat h = [self sidebarCollapsed] && !_sidebarPeeking ? kToolbarHeight : 47;
  NSRect cf = container.frame;
  cf.size.height = h;
  cf.origin.y = win.frame.size.height - h;
  container.frame = cf;
  CGFloat xs[3] = {13, 36, 59};
  NSWindowButton kinds[3] = {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton};
  for (int i = 0; i < 3; ++i) {
    NSButton* b = [win standardWindowButton:kinds[i]];
    NSRect f = b.frame;
    f.origin.x = xs[i] + (_sidebar.hidden ? 0 : 0);
    f.origin.y = round((h - f.size.height) / 2);
    b.frame = f;
  }
}
- (NSRect)windowButtonFrame {  // tests: the close button, in window coordinates
  NSButton* close = [self.window standardWindowButton:NSWindowCloseButton];
  return [close convertRect:close.bounds toView:nil];
}
- (void)windowDidEndLiveResize:(NSNotification*)note { [self positionWindowButtons]; }
- (void)windowDidExitFullScreen:(NSNotification*)note { [self positionWindowButtons]; }
- (void)windowDidBecomeMain:(NSNotification*)note {
  [self positionWindowButtons];
  [self applyWindowActive];
}

- (void)reloadSidebar {
  [_outline reloadData];
  [self updateFavoritesGrid];
  if (!_space) return;
  [_outline expandItem:_space.pinned];
  [_outline expandItem:_space.unpinned];
}

- (void)spaceChanged:(id)sender {
  ArcSpace* picked = _spacePicker.selectedItem.representedObject;
  if (picked) [self switchToSpace:picked];
}

class BlockDeleteCookies : public CefDeleteCookiesCallback {
 public:
  explicit BlockDeleteCookies(void (^done)(int)) : done_([done copy]) {}
  void OnComplete(int n) override {
    void (^done)(int) = done_;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(n); });
  }
 private:
  void (^done_)(int);
  IMPLEMENT_REFCOUNTING(BlockDeleteCookies);
};

// Visits every cookie, collects those matching `match`; when the visit ends, deletes them one by one
// through DeleteCookies (which reports completion) if `remove`, then reports the count on the main queue.
class MatchCookieVisitor : public CefCookieVisitor {
 public:
  MatchCookieVisitor(CefRefPtr<CefCookieManager> mgr, std::function<bool(const CefCookie&)> match, bool remove,
                     void (^done)(NSUInteger))
      : mgr_(mgr), match_(std::move(match)), remove_(remove), done_([done copy]) {}
  ~MatchCookieVisitor() override {
    auto hits = std::make_shared<std::vector<std::pair<std::string, std::string>>>(std::move(hits_));
    void (^done)(NSUInteger) = done_;
    CefRefPtr<CefCookieManager> mgr = mgr_;
    BOOL remove = remove_;
    dispatch_async(dispatch_get_main_queue(), ^{
      NSUInteger n = hits->size();
      if (!remove || hits->empty()) {
        if (done) done(n);
        return;
      }
      dispatch_group_t g = dispatch_group_create();
      for (auto& h : *hits) {
        dispatch_group_enter(g);
        std::string dbgUrl = h.first, dbgName = h.second;
        if (!mgr->DeleteCookies(h.first, h.second, new BlockDeleteCookies(^(int deleted) {
              if (getenv("NOTARC_COOKIE_DEBUG"))
                fprintf(stderr, "COOKIE-DEL %s %s -> %d\n", dbgUrl.c_str(), dbgName.c_str(), deleted);
              dispatch_group_leave(g);
            })))
          dispatch_group_leave(g);
      }
      dispatch_group_notify(g, dispatch_get_main_queue(), ^{
        if (done) done(n);
      });
    });
  }
  bool Visit(const CefCookie& c, int, int, bool&) override {
    if (getenv("NOTARC_COOKIE_DEBUG") && CefString(&c.name).ToString().rfind("nt_", 0) == 0)
      fprintf(stderr, "COOKIE-SEEN %s domain=%s path=%s match=%d\n", CefString(&c.name).ToString().c_str(),
              CefString(&c.domain).ToString().c_str(), CefString(&c.path).ToString().c_str(), (int)match_(c));
    if (match_(c)) {
      std::string d = CefString(&c.domain).ToString();
      if (!d.empty() && d[0] == '.') d = d.substr(1);
      std::string url = (c.secure ? "https://" : "http://") + d + CefString(&c.path).ToString();
      hits_.emplace_back(url, CefString(&c.name).ToString());
    }
    return true;
  }
 private:
  CefRefPtr<CefCookieManager> mgr_;
  std::function<bool(const CefCookie&)> match_;
  bool remove_;
  void (^done_)(NSUInteger);
  std::vector<std::pair<std::string, std::string>> hits_;
  IMPLEMENT_REFCOUNTING(MatchCookieVisitor);
};

class BlockCompletion : public CefCompletionCallback {
 public:
  explicit BlockCompletion(void (^done)(void)) : done_([done copy]) {}
  void OnComplete() override {
    void (^done)(void) = done_;
    if (done) dispatch_async(dispatch_get_main_queue(), done);
  }
 private:
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(BlockCompletion);
};

class BlockSetCookie : public CefSetCookieCallback {
 public:
  explicit BlockSetCookie(void (^done)(void)) : done_([done copy]) {}
  void OnComplete(bool ok) override {
    if (getenv("NOTARC_COOKIE_DEBUG")) fprintf(stderr, "COOKIE-SET ok=%d\n", ok);
    void (^done)(void) = done_;
    if (done) dispatch_async(dispatch_get_main_queue(), done);
  }
 private:
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(BlockSetCookie);
};

static double CookieCreatedUnix(const CefCookie& c) {
  return c.creation.val / 1e6 - 11644473600.0;  // microseconds since 1601 -> seconds since 1970
}

static std::string HostOf(const std::string& url) {
  NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
  return u.host.lowercaseString.UTF8String ?: "";
}

// Cookie domain ".example.com" or "example.com" belongs to host "www.example.com" / "example.com".
static bool CookieBelongsToHost(const CefCookie& c, const std::string& host) {
  std::string d = CefString(&c.domain).ToString();
  if (!d.empty() && d[0] == '.') d = d.substr(1);
  if (d.empty() || host.empty()) return false;
  if (host == d) return true;
  return host.size() > d.size() && host.compare(host.size() - d.size(), d.size(), d) == 0 &&
         host[host.size() - d.size() - 1] == '.';
}

NSString* CleanLinkURL(NSString* url) {
  NSURLComponents* c = [NSURLComponents componentsWithString:url ?: @""];
  if (!c || !c.queryItems.count) return url;
  static NSSet* exact = [NSSet setWithArray:@[
    @"fbclid", @"gclid", @"gclsrc", @"dclid", @"gbraid", @"wbraid", @"msclkid", @"mc_cid", @"mc_eid", @"igshid",
    @"yclid", @"twclid", @"ttclid", @"li_fat_id", @"_hsenc", @"_hsmi", @"mkt_tok", @"vero_id", @"oly_anon_id",
    @"oly_enc_id", @"rb_clickid", @"s_cid", @"ref_src", @"ref_url", @"si", @"__s", @"_ga", @"_gl", @"spm"
  ]];
  NSMutableArray* kept = [NSMutableArray array];
  for (NSURLQueryItem* q in c.queryItems) {
    NSString* n = q.name.lowercaseString;
    if ([n hasPrefix:@"utm_"] || [n hasPrefix:@"pk_"] || [exact containsObject:n]) continue;
    [kept addObject:q];
  }
  if (kept.count == c.queryItems.count) return url;
  c.queryItems = kept.count ? kept : nil;
  return c.string ?: url;
}

// One isolated browser profile per Arc Space (cookies, storage), keyed by Arc's profile name.
- (BOOL)contextIsReady:(NSString*)profile {
  if (gMainWindow && gMainWindow != self) return [gMainWindow contextIsReady:profile];
  return _readyContexts.count(profile.UTF8String) > 0;
}

- (CefRefPtr<CefRequestContext>)contextForSpace:(ArcSpace*)space {
  if (gMainWindow && gMainWindow != self) return [gMainWindow contextForSpace:space];
  std::string key = space.profileDirectory.UTF8String;
  auto it = _contexts.find(key);
  if (it != _contexts.end()) return it->second;
  NSString* support =
      [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:@"NotArc"];
  // Chrome-style CEF only accepts profile dirs that are direct children of root_cache_path.
  NSString* name = [(self.selfTestProfiles ? @"SelfTest Space " : @"Space ") stringByAppendingString:space.profileDirectory];
  NSString* path = [support stringByAppendingPathComponent:name];
  [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
  CefRequestContextSettings settings;
  CefString(&settings.cache_path) = path.UTF8String;
  settings.persist_session_cookies = true;  // session-only logins survive a restart (Arc does the same)
  __weak MainWindowController* weakSelf = self;
  NSString* profile = space.profileDirectory;
  CefRefPtr<CefRequestContext> ctx = CefRequestContext::CreateContext(
      settings, new SpaceContextHandler([weakSelf, profile]() { [weakSelf contextReady:profile]; }));
  _contexts[key] = ctx;
  return ctx;
}

// First time a Space's profile starts: copy that Arc profile's logins (cookies) in, then open tabs.
// A marker file in the profile makes this one-time, so later Arc changes never overwrite ours.
- (void)contextReady:(NSString*)profile {
  CefRefPtr<CefRequestContext> ctx = _contexts[profile.UTF8String];
  NSString* marker = [[NSString stringWithUTF8String:ctx->GetCachePath().ToString().c_str()]
      stringByAppendingPathComponent:@"ArcCookiesImported"];
  if (!self.selfTestProfiles && ![[NSFileManager defaultManager] fileExistsAtPath:marker]) {
    __weak MainWindowController* weakSelf = self;
    [self importArcCookiesForProfile:profile context:ctx done:^(NSUInteger read, int ok) {
      std::fprintf(stderr, "imported %d/%lu Arc cookies into %s\n", ok, (unsigned long)read, profile.UTF8String);
      if (read > 0)
        [[NSString stringWithFormat:@"%d of %lu\n", ok, (unsigned long)read] writeToFile:marker atomically:YES
                                                                                  encoding:NSUTF8StringEncoding error:nil];
      [weakSelf openPendingTabsForProfile:profile];
    }];
    return;
  }
  [self openPendingTabsForProfile:profile];
}

- (void)importArcCookiesForProfile:(NSString*)profile
                           context:(CefRefPtr<CefRequestContext>)ctx
                              done:(void (^)(NSUInteger read, int ok))done {
  // The Keychain read can block for many seconds (securityd / access prompt). Do it and the
  // SQLite decrypt on a background queue; only the CEF calls happen back on the main thread.
  __weak MainWindowController* weakSelf = self;
  NSString* userData = [ArcDataDirectory() stringByAppendingPathComponent:@"User Data"];
  dispatch_async(ArcImportQueue(), ^{
    NSError* error = nil;
    NSData* key = ArcImportKey(&error);
    NSArray<ArcCookie*>* cookies =
        key ? ArcReadCookies(ArcCookieDBPathIn(userData, profile), key, nullptr, &error) : nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!cookies.count && error)
        std::fprintf(stderr, "Arc cookie import skipped for %s: %s\n", profile.UTF8String,
                     error.localizedDescription.UTF8String);
      [weakSelf setArcCookies:cookies context:ctx done:done];
    });
  });
}

// Sets each cookie through the Space's own CEF cookie manager, which stores it encrypted with NotArc's own key.
// A cookie that's already there (same name, domain and path) is replaced by Arc's newer copy.
- (void)setArcCookies:(NSArray<ArcCookie*>*)cookies
              context:(CefRefPtr<CefRequestContext>)ctx
                 done:(void (^)(NSUInteger read, int ok))done {
  CefRefPtr<CefCookieManager> manager = ctx ? ctx->GetCookieManager(nullptr) : nullptr;
  if (!cookies.count || !manager) {
    done(cookies.count, 0);
    return;
  }
  NSUInteger count = cookies.count;
  void (^finish)(NSUInteger, int) = [done copy];
  CefRefPtr<CookieImportCallback> cb = new CookieImportCallback(static_cast<int>(count), [finish, count, manager](int ok) {
    manager->FlushStore(nullptr);
    dispatch_async(dispatch_get_main_queue(), ^{ finish(count, ok); });
  });
  for (ArcCookie* c in cookies) {
    NSString* host = [c.host hasPrefix:@"."] ? [c.host substringFromIndex:1] : c.host;
    NSString* url = [NSString stringWithFormat:@"%@://%@%@", c.secure ? @"https" : @"http", host, c.path.length ? c.path : @"/"];
    CefCookie cookie;
    CefString(&cookie.name) = c.name.UTF8String;
    CefString(&cookie.value) = c.value.UTF8String;
    if ([c.host hasPrefix:@"."]) CefString(&cookie.domain) = c.host.UTF8String;  // else host-only
    CefString(&cookie.path) = (c.path.length ? c.path : @"/").UTF8String;
    cookie.secure = c.secure;
    cookie.httponly = c.httpOnly;
    cookie.has_expires = c.hasExpires;
    cookie.expires.val = c.expiresUTC;
    cookie.creation.val = c.creationUTC;
    cookie.last_access.val = c.lastAccessUTC;
    cookie.same_site = SameSiteFromChromiumDB(c.sameSite);
    cookie.priority = c.priority == 0 ? CEF_COOKIE_PRIORITY_LOW
                                      : (c.priority == 2 ? CEF_COOKIE_PRIORITY_HIGH : CEF_COOKIE_PRIORITY_MEDIUM);
    if (!manager->SetCookie(url.UTF8String, cookie, cb)) cb->OnComplete(false);
  }
}

// Import Everything from Arc: every Space profile's Arc cookies (its logins), copied again even if they came over
// before, so sessions Arc renewed since then work here too. Waits for each Space's profile to start. Reports, per
// profile, what was copied and, in plain words, anything that went wrong.
- (void)importArcCookiesFromUserData:(NSString*)userData key:(NSData*)key done:(void (^)(NSDictionary* report))done {
  void (^finish)(NSDictionary*) = [done copy];
  NSMutableArray<ArcSpace*>* spaces = [NSMutableArray array];
  NSMutableSet* seen = [NSMutableSet set];
  for (ArcSpace* s in _spaces) {
    NSString* p = s.profileDirectory.length ? s.profileDirectory : @"Default";
    if ([seen containsObject:p]) continue;
    [seen addObject:p];
    [spaces addObject:s];
  }
  NSMutableDictionary* report =
      [@{@"read" : @0, @"set" : @0, @"profiles" : @0, @"expired" : @0, @"locked" : @0, @"errors" : [NSMutableArray array]} mutableCopy];
  if (!key) {
    [report[@"errors"] addObject:@"macOS didn't give NotArc Arc's key, so no logins could be copied"];
    finish(report);
    return;
  }
  __weak MainWindowController* weakSelf = self;
  __block void (^step)(NSUInteger);
  void (^next)(NSUInteger) = ^(NSUInteger i) {
    MainWindowController* me = weakSelf;
    if (!me || i >= spaces.count) {
      // Break the step -> block -> step cycle later: clearing it now would free this block (and what it holds)
      // while it is still running.
      dispatch_async(dispatch_get_main_queue(), ^{ step = nil; });
      finish(report);
      return;
    }
    ArcSpace* space = spaces[i];
    NSString* profile = space.profileDirectory.length ? space.profileDirectory : @"Default";
    NSString* label = space.title.length ? space.title : profile;
    CefRefPtr<CefRequestContext> ctx = [me contextForSpace:space];
    __block int waited = 0;
    __block void (^whenReady)(void);
    void (^ready)(void) = ^{
      MainWindowController* me2 = weakSelf;
      if (!me2) return;
      if (![me2 contextIsReady:profile] && waited++ < 120) {  // up to 30 s for the profile to start
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), whenReady);
        return;
      }
      dispatch_async(dispatch_get_main_queue(), ^{ whenReady = nil; });  // same: not while this block runs
      dispatch_async(ArcImportQueue(), ^{
        NSError* error = nil;
        ArcCookieStats st = {0, 0, 0};
        NSArray<ArcCookie*>* cookies = ArcReadCookies(ArcCookieDBPathIn(userData, profile), key, &st, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
          report[@"profiles"] = @([report[@"profiles"] intValue] + 1);
          report[@"expired"] = @([report[@"expired"] unsignedIntegerValue] + st.expired);
          report[@"locked"] = @([report[@"locked"] unsignedIntegerValue] + st.undecryptable);
          if (!cookies.count) {
            if (error) [report[@"errors"] addObject:[NSString stringWithFormat:@"%@: %@", label, error.localizedDescription]];
            if (step) step(i + 1);
            return;
          }
          [weakSelf setArcCookies:cookies context:ctx done:^(NSUInteger read, int ok) {
            report[@"read"] = @([report[@"read"] unsignedIntegerValue] + read);
            report[@"set"] = @([report[@"set"] unsignedIntegerValue] + (NSUInteger)ok);
            if ((NSUInteger)ok < read)
              [report[@"errors"] addObject:[NSString stringWithFormat:@"%@: %lu of %lu logins weren't accepted by NotArc's "
                                                                     @"cookie store", label, (unsigned long)(read - ok),
                                                                     (unsigned long)read]];
            NSString* marker = [[NSString stringWithUTF8String:ctx->GetCachePath().ToString().c_str()]
                stringByAppendingPathComponent:@"ArcCookiesImported"];
            [[NSString stringWithFormat:@"%d of %lu\n", ok, (unsigned long)read] writeToFile:marker atomically:YES
                                                                                    encoding:NSUTF8StringEncoding error:nil];
            if (step) step(i + 1);
          }];
        });
      });
    };
    whenReady = ready;
    if (!ctx) {
      [report[@"errors"] addObject:[NSString stringWithFormat:@"%@: its profile couldn't start", label]];
      step(i + 1);
      return;
    }
    ready();
  };
  step = next;
  next(0);
}

- (void)openPendingTabsForProfile:(NSString*)profile {
  _readyContexts.insert(profile.UTF8String);
  NSArray<ArcItem*>* pending = _pendingTabs[profile];
  [_pendingTabs removeObjectForKey:profile];
  for (ArcItem* item in pending) {
    [self ensureBrowserForItem:item];
    if (item == _shown) [self showItem:item];
  }
}

- (ArcSpace*)spaceOwningItem:(ArcItem*)item {
  if ([_space.allTabs containsObject:item]) return _space;
  for (ArcSpace* s in _spaces)
    if ([s.allTabs containsObject:item]) return s;
  return _space;
}

// Must run after CefInitialize, on the main (CEF UI) thread.
// Two-finger swipe back/forward, as in Arc and Safari: a horizontal trackpad swipe that starts over the page
// tracks with an arrow at the page edge and navigates when released past the threshold. Follows the macOS
// "Swipe between pages" setting. Returns -1 back, 1 forward, 0 not a swipe (tests use this directly).
NSInteger SwipeDirectionForScroll(CGFloat dx, CGFloat dy, BOOL precise, BOOL began) {
  if (!precise || !began) return 0;
  if (fabs(dx) < 2 || fabs(dx) < fabs(dy) * 2) return 0;  // mostly horizontal
  return dx > 0 ? -1 : 1;  // fingers moving right = back (natural scrolling direction of history)
}

// Read on every link from another app (rare), so rule edits apply immediately.
- (LinkRouting*)linkRouting {
  NSString* path = self.linkRoutingPath;
  if (!path) return nil;
  LinkRouting* lr = [LinkRouting loadFrom:path];
  if (!lr) {  // first launch: Arc's rules, read-only
    lr = [LinkRouting fromArcFile:[ArcDataDirectory() stringByAppendingPathComponent:@"StorableLinkRouting.json"]];
    if (!lr) {
      lr = [LinkRouting new];
      lr.rules = @[];
      lr.defaultDestination = SettingBool(kSettingExternalLinksLittle) ? @"little" : @"space";
    }
    [lr saveTo:path];
  }
  return lr;
}

- (NSString*)routeExternalLink:(NSString*)url sourceApp:(NSString*)bundleID {
  LinkRouting* lr = [self linkRouting];
  LinkRule* rule = [lr ruleForURL:url sourceApp:bundleID];
  NSString* to = rule ? rule.destination : (lr.defaultDestination ?: (SettingBool(kSettingExternalLinksLittle) ? @"little" : @"space"));
  NSString* spaceID = rule ? rule.spaceID : lr.defaultSpaceID;
  if ([to isEqualToString:@"little"]) {
    [self openLittleWindow:url];
    return @"little";
  }
  ArcSpace* target = _space;  // "most recent Space" = the one in front
  for (ArcSpace* s in _spaces) if (spaceID && [s.spaceID isEqualToString:spaceID]) target = s;
  if (target != _space) [self switchToSpace:target];
  [self openInNewTab:url];
  return target.title ?: @"";
}

- (NSWindowController*)airTrafficControlEditor {
  static NSMutableDictionary<NSString*, LinkRoutingEditor*>* editors;
  if (!editors) editors = [NSMutableDictionary dictionary];
  NSString* path = self.linkRoutingPath;
  if (!path) return nil;
  [self linkRouting];  // first time: seed from Arc
  NSMutableArray* spaces = [NSMutableArray array];
  for (ArcSpace* s in _spaces) if (s.spaceID.length) [spaces addObject:@[ s.spaceID, s.title ?: @"Space" ]];
  LinkRoutingEditor* e = [[LinkRoutingEditor alloc] initWithPath:path spaces:spaces];  // fresh: Spaces may have changed
  editors[path] = e;
  return e;
}

- (IBAction)showAirTrafficControl:(id)sender {
  NSWindowController* e = [self airTrafficControlEditor];
  [e showWindow:nil];
  [e.window makeKeyAndOrderFront:nil];
}

- (BOOL)swipeNavigationInstalled { return _swipeMonitor != nil; }

- (void)installSwipeNavigation {
  if (_swipeMonitor) return;
  __weak MainWindowController* weakSelf = self;
  _swipeMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskScrollWheel handler:^NSEvent*(NSEvent* e) {
    return [weakSelf handleSwipeScroll:e] ? nil : e;
  }];
}

// Arc: a two-finger swipe across the sidebar switches Spaces (#27): fingers moving left go to the next Space, right
// to the previous one, with the sidebar's slide. Returns NO at either end, like Arc (no wraparound).
- (BOOL)swipeSpacesBy:(NSInteger)step {
  NSInteger i = (NSInteger)[_spaces indexOfObject:_space] + step;
  if (!step || i < 0 || i >= (NSInteger)_spaces.count) return NO;
  [self selectSpaceAtIndex:(NSUInteger)i];
  return YES;
}
- (BOOL)handleSidebarSwipe:(NSEvent*)e {
  if (_sidebar.hidden || !NSPointInRect([_sidebar convertPoint:e.locationInWindow fromView:nil], _sidebar.bounds)) return NO;
  NSInteger dir = SwipeDirectionForScroll(e.scrollingDeltaX, e.scrollingDeltaY, e.hasPreciseScrollingDeltas,
                                          e.phase == NSEventPhaseBegan);
  NSInteger here = (NSInteger)[_spaces indexOfObject:_space], step = dir;  // dir -1 (fingers right) = previous Space
  if (!dir || here + step < 0 || here + step >= (NSInteger)_spaces.count) return NO;
  __block BOOL done = NO;
  [e trackSwipeEventWithOptions:NSEventSwipeTrackingLockDirection
       dampenAmountThresholdMin:dir < 0 ? 0 : -1
                            max:dir < 0 ? 1 : 0
                   usingHandler:^(CGFloat amount, NSEventPhase phase, BOOL complete, BOOL* stop) {
                     if (phase == NSEventPhaseEnded && !done && fabs(amount) >= 0.3) {
                       done = YES;
                       [self swipeSpacesBy:step];
                     }
                   }];
  return YES;
}

- (BOOL)handleSwipeScroll:(NSEvent*)e {
  if (e.window != self.window || !NSEvent.isSwipeTrackingFromScrollEventsEnabled || !_content) return NO;
  if ([self handleSidebarSwipe:e]) return YES;
  if (!NSPointInRect([_content convertPoint:e.locationInWindow fromView:nil], _content.bounds)) return NO;
  NSInteger dir = SwipeDirectionForScroll(e.scrollingDeltaX, e.scrollingDeltaY, e.hasPreciseScrollingDeltas,
                                          e.phase == NSEventPhaseBegan);
  if (!dir || (dir < 0 && ![self canGoBack]) || (dir > 0 && !([self currentBrowser] && [self currentBrowser]->CanGoForward()))) return NO;
  NSView* arrow = [self swipeArrow:dir];
  __block BOOL done = NO;
  [e trackSwipeEventWithOptions:NSEventSwipeTrackingLockDirection
       dampenAmountThresholdMin:dir < 0 ? 0 : -1
                            max:dir < 0 ? 1 : 0
                   usingHandler:^(CGFloat amount, NSEventPhase phase, BOOL complete, BOOL* stop) {
                     CGFloat a = fmin(1, fabs(amount));
                     arrow.alphaValue = a;
                     NSRect f = arrow.frame;
                     f.origin.x = dir < 0 ? -36 + 56 * a : self->_content.bounds.size.width - 20 - 56 * a;
                     arrow.frame = f;
                     if (phase == NSEventPhaseEnded && !done && fabs(amount) >= 0.5) {
                       done = YES;
                       dir < 0 ? [self goBack:nil] : [self goForward:nil];
                     }
                     if (complete) [arrow removeFromSuperview];
                   }];
  return YES;
}

- (NSView*)swipeArrow:(NSInteger)dir {
  [_swipeArrow removeFromSuperview];
  CGFloat s = 36, y = round(NSMidY(_content.bounds) - s / 2);
  NSImageView* v = [[NSImageView alloc] initWithFrame:NSMakeRect(dir < 0 ? -s : _content.bounds.size.width, y, s, s)];
  v.image = [NSImage imageWithSystemSymbolName:dir < 0 ? @"arrow.left" : @"arrow.right" accessibilityDescription:nil];
  v.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightSemibold];
  v.contentTintColor = NSColor.whiteColor;
  v.wantsLayer = YES;
  v.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.55].CGColor;
  v.layer.cornerRadius = s / 2;
  v.alphaValue = 0;
  v.autoresizingMask = NSViewMinYMargin | NSViewMaxYMargin | (dir < 0 ? NSViewMaxXMargin : NSViewMinXMargin);
  [_content addSubview:v positioned:NSWindowAbove relativeTo:nil];
  _swipeArrow = v;
  return v;
}

- (void)createBrowsers {
  gMainWindow = self;
  if (!gWindows) gWindows = [NSMutableArray array];
  if (![gWindows containsObject:self]) [gWindows addObject:self];
  [self installSwipeNavigation];
  __weak MainWindowController* weakSelf = self;
  [self applyCalendarSetting];
  if (!_defaultsObserver)  // Settings checkbox for the meeting bar (#56)
    _defaultsObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil
                                                                         queue:NSOperationQueue.mainQueue
                                                                    usingBlock:^(NSNotification*) {
                                                                      MainWindowController* me = weakSelf;
                                                                      if (me && SettingBool(kSettingCalendar) != (me->_meetingTimer != nil))
                                                                        [me applyCalendarSetting];
                                                                    }];
  _client = new BrowserClient(
      [weakSelf](int browserId, const std::string& title) {
        [OwnerOf(browserId, weakSelf) browser:browserId title:[NSString stringWithUTF8String:title.c_str()] url:nil];
      },
      [weakSelf](int browserId, const std::string& url) {
        [OwnerOf(browserId, weakSelf) browser:browserId title:nil url:[NSString stringWithUTF8String:url.c_str()]];
      });
  _client->set_focus_callback([weakSelf](int browserId) { [OwnerOf(browserId, weakSelf) paneFocused:browserId]; });
  _client->set_link_menu_callback([weakSelf](int browserId, int command, const std::string& url, const std::string& text) {
    NSString* target = [NSString stringWithUTF8String:url.c_str()];
    NSString* sel = [NSString stringWithUTF8String:text.c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{
      [OwnerOf(browserId, weakSelf) handleLinkCommand:command url:target text:sel fromBrowser:browserId];
    });
  });
  _client->set_open_callback([weakSelf](int browserId, const std::string& url, int disposition, bool gesture) -> bool {
    MainWindowController* strong = OwnerOf(browserId, weakSelf);
    if (!strong) return false;
    NSString* target = [NSString stringWithUTF8String:url.c_str()];
    // Decide now (so CEF knows not to open its own window), act after this callback returns.
    BOOL handled = [strong handleOpenURL:target fromBrowser:browserId disposition:disposition userGesture:gesture];
    return handled;
  });
  _client->set_navigation_filter([weakSelf](int browserId, const std::string& url) -> bool {
    MainWindowController* strong = OwnerOf(browserId, weakSelf);
    if (!strong) return false;
    NSString* target = [NSString stringWithUTF8String:url.c_str()];
    if (![strong shouldPeekFromItem:[strong itemForBrowser:browserId] toURL:target]) return false;
    dispatch_async(dispatch_get_main_queue(), ^{ [strong openPeek:target]; });
    return true;
  });
  _client->set_media_callback([weakSelf](int browserId, const std::string& state, const std::string& title) {
    if (getenv("NOTARC_MEDIA_DEBUG") && !title.empty()) std::fprintf(stderr, "MEDIA-DEBUG %d %s %s\n", browserId, state.c_str(), title.c_str());
    [OwnerOf(browserId, weakSelf) browser:browserId mediaState:[NSString stringWithUTF8String:state.c_str()]
                                      info:[NSString stringWithUTF8String:title.c_str()]];
  });
  _mediaTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer*) { [weakSelf pollMediaNow]; }];
  _client->set_renderer_callback([weakSelf](int browserId, int kind, int status) {
    [OwnerOf(browserId, weakSelf) browser:browserId rendererEvent:kind status:status];
  });
  _client->set_favicon_callback([weakSelf](int browserId, const std::string& url) {
    [OwnerOf(browserId, weakSelf) browser:browserId faviconURL:[NSString stringWithUTF8String:url.c_str()]];
  });
  _client->set_loading_callback([weakSelf](int browserId, bool loading) {
    MainWindowController* owner = OwnerOf(browserId, weakSelf);
    dispatch_async(dispatch_get_main_queue(), ^{ [owner browser:browserId loading:loading]; });
  });
  _client->set_load_end_callback([weakSelf](int browserId, const std::string& url) {
    [OwnerOf(browserId, weakSelf) updateNavButtons];
    [OwnerOf(browserId, weakSelf) applyBoostToBrowser:browserId url:[NSString stringWithUTF8String:url.c_str()]];
    [OwnerOf(browserId, weakSelf) applyAdBlockCosmeticsToBrowser:browserId url:[NSString stringWithUTF8String:url.c_str()]];
    [OwnerOf(browserId, weakSelf) installCallHookInBrowser:browserId];
    [OwnerOf(browserId, weakSelf) detectLanguageInBrowser:browserId url:[NSString stringWithUTF8String:url.c_str()]];
    [OwnerOf(browserId, weakSelf) thumbnailAfterLoadOfBrowser:browserId];
  });
  _client->set_notify_callback([weakSelf](int browserId, const std::string& json, const std::string& pageURL) {
    NSString* j = [NSString stringWithUTF8String:json.c_str()], *u = [NSString stringWithUTF8String:pageURL.c_str()];
    dispatch_async(dispatch_get_main_queue(), ^{ [OwnerOf(browserId, weakSelf) browser:browserId notification:j pageURL:u]; });
  });
  _client->set_lang_callback([weakSelf](int browserId, const std::string& lang) {
    [OwnerOf(browserId, weakSelf) browser:browserId pageLanguage:[NSString stringWithUTF8String:lang.c_str()]];
  });
  _client->set_capture_callback([weakSelf](int browserId, bool video, bool audio) {
    [OwnerOf(browserId, weakSelf) browser:browserId captureVideo:video audio:audio];
  });
  _client->set_zap_callback([weakSelf](int browserId, const std::string& selector) {
    [OwnerOf(browserId, weakSelf) handleZapSelector:[NSString stringWithUTF8String:selector.c_str()] browser:browserId];
  });
  _client->set_permission_callback([weakSelf](int browserId, int requestId, const std::string& origin, uint32_t perms) {
    [OwnerOf(browserId, weakSelf) browser:browserId permissionRequest:requestId origin:[NSString stringWithUTF8String:origin.c_str()]
                 bits:perms];
  });
  _client->set_external_callback([weakSelf](int browserId, const std::string& url) {
    [OwnerOf(browserId, weakSelf) browser:browserId externalURL:[NSString stringWithUTF8String:url.c_str()]];
  });
  _client->set_status_callback([weakSelf](int browserId, const std::string& text) {
    [OwnerOf(browserId, weakSelf) maxLinkHovered:[NSString stringWithUTF8String:text.c_str()] ?: @"" browser:browserId];
  });
  _client->set_autofill_callback([weakSelf](int browserId, const std::string& nonce, const std::string& origin,
                                            bool mainFrame, const std::string& json) {
    MainWindowController* owner = OwnerOf(browserId, weakSelf);
    [owner.autofill handleMessage:[NSString stringWithUTF8String:json.c_str()] browser:browserId
                            nonce:[NSString stringWithUTF8String:nonce.c_str()]
                           origin:[NSString stringWithUTF8String:origin.c_str()] mainFrame:mainFrame];
  });
  _client->set_find_callback([weakSelf](int browserId, int count, int active) {
    [OwnerOf(browserId, weakSelf) findResult:count active:active];
  });
  if (self.restoreOpenTabs) {
    NSUInteger n = 0;
    for (ArcSpace* sp in _spaces)
      for (ArcItem* t in sp.allTabs)
        if (t.wasOpen && n < 30) {  // cap: a crash with hundreds of open tabs shouldn't reload them all
          [self ensureBrowserForItem:t];
          ++n;
        }
    _restoredTabCount = n;
  }
  ArcItem* first = [self lastShownInSpace:_space];
  if (first) [self showItem:first];
  [self startAutoArchiveTimer];
}

- (ArcItem*)lastShownInSpace:(ArcSpace*)space {
  for (ArcItem* t in space.allTabs)
    if ([t.itemID isEqualToString:space.shownItemID]) return t;
  return space.allTabs.firstObject;
}

- (NSUInteger)liveTabCount { return _browsers.size(); }

// Web views are created lazily, the first time a tab is opened (Arc does the same).
- (void)adoptBrowser:(int)browserId {
  if (!gBrowserOwners) gBrowserOwners = [NSMapTable strongToWeakObjectsMapTable];
  [gBrowserOwners setObject:self forKey:@(browserId)];
}

- (BOOL)hostsBrowserOfItem:(ArcItem*)item {  // tests
  return item.browserId && OwnerOf(item.browserId, nil) == self && _browsers.count(item.browserId);
}

- (void)ensureBrowserForItem:(ArcItem*)item {
  if (item.noteID || item.easelID) return;  // notes and easels are native, no web view
  if (item.browserId || !item.url.length || !_client || !_content) return;
  ArcSpace* space = [self spaceOwningItem:item];
  CefRefPtr<CefRequestContext> context = [self contextForSpace:space];
  if (![self contextIsReady:space.profileDirectory]) {
    if (gMainWindow && gMainWindow != self) {  // the main window starts profiles; try again shortly
      __weak MainWindowController* weakSelf = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        MainWindowController* me = weakSelf;
        if (!me || !me->_content) return;
        [me ensureBrowserForItem:item];
        if ([[me visiblePanes] containsObject:item]) [me layoutPanes];
      });
      return;
    }
    if (!_pendingTabs) _pendingTabs = [NSMutableDictionary dictionary];
    NSMutableArray* queue = _pendingTabs[space.profileDirectory] ?: [NSMutableArray array];
    if (![queue containsObject:item]) [queue addObject:item];
    _pendingTabs[space.profileDirectory] = queue;
    return;
  }
  if (ChromePagesEnabled()) {
    ChromePageHost* host = [[ChromePageHost alloc] initWithClient:_client url:item.url context:context hostView:_content];
    CefRefPtr<CefBrowser> browser = host.browser;
    if (!browser) {
      std::fprintf(stderr, "failed to create Chrome-style page for %s\n", item.url.UTF8String);
      [host close];
      return;
    }
    if (!_chromePages) _chromePages = [NSMutableDictionary dictionary];
    _chromePages[@(browser->GetIdentifier())] = host;
    item.browserId = browser->GetIdentifier();
    _browsers[item.browserId] = browser;
  [self adoptBrowser:item.browserId];
    return;
  }
  CefWindowInfo info;
  NSRect r = _content.bounds;
  info.SetAsChild(CAST_NSVIEW_TO_CEF_WINDOW_HANDLE(_content),
                  CefRect(0, 0, static_cast<int>(r.size.width), static_cast<int>(r.size.height)));
  CefBrowserSettings settings;
  CefRefPtr<CefBrowser> browser = CefBrowserHost::CreateBrowserSync(
      info, _client, item.url.UTF8String, settings, nullptr, context);
  if (!browser) {
    std::fprintf(stderr, "failed to create browser for %s\n", item.url.UTF8String);
    return;
  }
  NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  view.frame = _content.bounds;
  item.browserId = browser->GetIdentifier();
  _browsers[item.browserId] = browser;
  [self adoptBrowser:item.browserId];
}

// Automatic picture-in-picture (#46): a video playing in the tab you leave pops out; coming back puts it back.
// Runs with a user gesture (DevTools Runtime.evaluate) because the page itself can only open PiP from a click.
static NSString* const kPiPEnterJS =
    @"(()=>{if(document.pictureInPictureElement)return 'already';const v=[...document.querySelectorAll('video')]"
    @".find(x=>!x.paused&&!x.ended&&x.readyState>1&&!x.disablePictureInPicture);if(!v)return 'none';"
    @"return v.requestPictureInPicture().then(()=>'pip',e=>'error:'+e.name);})()";
static NSString* const kPiPExitJS =
    @"(()=>document.pictureInPictureElement?document.exitPictureInPicture().then(()=>'exited',e=>'error:'+e.name):'none')()";

- (void)pictureInPicture:(BOOL)enter item:(ArcItem*)item done:(void (^)(NSString* result))done {
  if (!item.browserId) { if (done) done(@"nobrowser"); return; }
  [self devtools:item method:@"Runtime.evaluate"
          params:@{@"expression" : enter ? kPiPEnterJS : kPiPExitJS, @"userGesture" : @YES, @"awaitPromise" : @YES,
                   @"returnByValue" : @YES}
            done:^(NSDictionary* r) {
              id v = r[@"result"][@"value"];
              NSString* res = [v isKindOfClass:NSString.class] ? v : (r ? @"error" : @"failed");
              if (enter) item.inPictureInPicture = [res isEqualToString:@"pip"] || [res isEqualToString:@"already"];
              else if (![res hasPrefix:@"error"]) item.inPictureInPicture = NO;
              if (done) done(res);
            }];
}

- (void)showItem:(ArcItem*)item {
  if (!item.url.length) return;
  if (item != _shown && _shown.mediaPlaying && SettingBool(kSettingAutoPiP)) [self pictureInPicture:YES item:_shown done:nil];
  if (item.inPictureInPicture && item != _shown) [self pictureInPicture:NO item:item done:nil];
  if (item != _shown && _shown) [self popPageCard];
  _shown.lastActiveAt = [NSDate date];  // the tab we leave was active until now
  BOOL switched = item != _shown;
  _shown = item;
  ArcSpace* owner = [self spaceOwningItem:item];
  // The Space's last-shown tab (restored at launch) follows the main window only; other windows keep their own.
  if (item.itemID && [self isMainWindowController] && ![owner.shownItemID isEqualToString:item.itemID]) {
    owner.shownItemID = item.itemID;
    [self scheduleSave];
  }
  [self updateMediaBar];
  item.lastActiveAt = [NSDate date];
  if (item.liveUnread) {  // opening a new Live Folder entry marks it read (its dot and the folder's count go)
    item.liveUnread = NO;
    [_outline reloadItem:item];
    [_outline reloadItem:[self parentOfItem:item]];
    [self scheduleSave];
  }
  [self ensureBrowserForItem:item];
  [self layoutPanes];
  [self selectSidebarRowFor:item];
  [self updateToolbarAddress];
  if (![self isMainWindowController]) [MainWindowController saveWindowState];
  if (switched) {  // tab thumbnails (#65): only (re)arms a timer here; the copy itself is never on the switch path
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    _showGeneration++;
    [self scheduleThumbnailOfShown];
    TabThumbnailNoteSwitch((CFAbsoluteTimeGetCurrent() - t0) * 1000);
  }
}

- (void)openTabsForSelfTest:(NSUInteger)count {
  NSUInteger opened = 0;
  for (ArcSpace* s in _spaces) {
    NSArray<ArcItem*>* tabs = s.allTabs;
    for (NSUInteger i = 0; i < MIN(count, tabs.count); ++i, ++opened) [self ensureBrowserForItem:tabs[i]];
  }
}

- (ArcItem*)itemForBrowser:(int)browserId {
  for (ArcSpace* s in _spaces)
    for (ArcItem* t in s.allTabs)
      if (t.browserId == browserId) return t;
  return nil;
}

- (void)browser:(int)browserId title:(NSString*)title url:(NSString*)url {
  ArcItem* item = [self itemForBrowser:browserId];
  if (!item) return;
  if (title.length && ![title isEqualToString:item.liveTitle]) {
    item.liveTitle = title;
    if ([self sectionContaining:item] == _space.favorites) [self updateFavoritesGrid];
  }
  if (url.length && !item.pinnedURL.length && [self isPinnedItem:item]) item.pinnedURL = item.url ?: url;
  if (url.length) item.url = url;
  if (url.length && item == _shown) [self updateToolbarAddress];
  if (self.historyPath && !_history) _history = [[HistoryStore alloc] initWithPath:self.historyPath];
  if (url.length) [_history recordURL:url title:title space:[self spaceOwningItem:item].title];
  else if (title.length) [_history updateTitle:title forURL:item.url];
  ArcItem* parent = [self parentOfItem:item];
  [_outline reloadItem:parent.isSplit ? parent : item];
  // My Pull Requests: once its sign-in tab is back on github.com past the login pages, fill the folder.
  if (url.length && parent.liveSignInNeeded && LiveFolderIsGitHubSignedInLanding(url)) {
    parent.liveSignInNeeded = NO;
    [self refreshLiveFolder:parent done:nil];
  }
  [self scheduleSave];
}

- (NSArray<NSDictionary*>*)tabSnapshot {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcSpace* s in _spaces)
    for (ArcItem* t in s.allTabs)
      if (t.browserId)
        [out addObject:@{@"space" : s.title, @"profile" : s.profileDirectory, @"title" : t.displayTitle,
                         @"url" : t.url ?: @""}];
  return out;
}

- (void)closeAllBrowsers {
  [self saveNoteNow];  // the last half second of typing in a note
  [_extensionPopup closeBecause:@"quit"];
  [MainWindowController prepareForQuit];
  _closing = YES;
  for (MainWindowController* w in [gWindows copy])
    if (w != self) [w.window close];  // their pages close too, before the quit check below
  for (LittleWindowController* lw in [_littleWindows copy]) [lw.window close];
  [_peek.window close];
  if (_client) _client->set_quit_when_empty(true);
  EaselCloseClipRenderers();
  if (_browsers.empty()) {
    [self.window close];
    return;
  }
  for (auto& kv : _browsers) kv.second->GetHost()->CloseBrowser(true);
}

#pragma mark NSOutlineView

- (NSArray<ArcItem*>*)childrenOf:(id)item {
  if (!item) {
    if (!_space) return @[];
    return @[ _space.pinned, _space.unpinned ];  // Favorites are the tile grid above, as in Arc
  }
  return ((ArcItem*)item).children;
}

- (NSInteger)outlineView:(NSOutlineView*)ov numberOfChildrenOfItem:(id)item {
  return [self childrenOf:item].count;
}

- (id)outlineView:(NSOutlineView*)ov child:(NSInteger)index ofItem:(id)item {
  return [self childrenOf:item][index];
}

- (BOOL)outlineView:(NSOutlineView*)ov isItemExpandable:(id)item {
  ArcItem* a = item;
  return a.isSection || a.isFolder;  // a split is a single row
}

- (BOOL)outlineView:(NSOutlineView*)ov isGroupItem:(id)item {
  return NO;  // Arc's section headers are plain rows, not floating group rows
}

- (CGFloat)outlineView:(NSOutlineView*)ov heightOfRowByItem:(id)item {
  ArcItem* a = item;
  if (a == _space.unpinned) return kNewTabHeaderHeight;
  if (a.isSection) return kPinnedHeaderHeight;
  return kRowPitch;
}

- (NSTableRowView*)outlineView:(NSOutlineView*)ov rowViewForItem:(id)item {
  SidebarRowView* rv = [ov makeViewWithIdentifier:@"row" owner:self];
  if (!rv) {
    rv = [SidebarRowView new];
    rv.identifier = @"row";
  }
  rv.hovered = NO;
  rv.pressed = NO;
  rv.multi = ov.selectedRowIndexes.count > 1;
  rv.separatorAbove = item == _space.unpinned;  // Arc: always a hairline above "+ New Tab"
  rv.newTabRow = item == _space.unpinned;
  return rv;
}

- (NSString*)sidebarRowStyleForItem:(ArcItem*)item {
  NSInteger row = [_outline rowForItem:item];
  if (row < 0) return @"";
  SidebarRowView* rv = (SidebarRowView*)[_outline rowViewAtRow:row makeIfNecessary:YES];
  return [rv isKindOfClass:SidebarRowView.class] ? [rv styleDescription] : @"";
}
- (void)setSidebarHoverRow:(NSInteger)row {
  [_outline enumerateAvailableRowViewsUsingBlock:^(NSTableRowView* rv, NSInteger r) {
    if (![rv isKindOfClass:SidebarRowView.class]) return;
    SidebarRowView* s = (SidebarRowView*)rv;
    ArcItem* it = [self->_outline itemAtRow:r];
    BOOL h = r == row && (!it.isSection || it == self->_space.unpinned);
    if (s.hovered != h) { s.hovered = h; s.needsDisplay = YES; }
  }];
  BOOL todayHover = row >= 0 && [_outline itemAtRow:row] == _space.unpinned;
  if (todayHover != _todayHeaderHovered) {
    _todayHeaderHovered = todayHover;
    NSInteger hr = [_outline rowForItem:_space.unpinned];
    NSTableCellView* cell = hr >= 0 ? [_outline viewAtColumn:0 row:hr makeIfNecessary:NO] : nil;
    [cell viewWithTag:83].hidden = !todayHover || _space.unpinned.children.count == 0;
  }
}
- (void)pressSidebarItem:(ArcItem*)item down:(BOOL)down {  // tests
  NSInteger row = [_outline rowForItem:item];
  SidebarRowView* rv = row >= 0 ? (SidebarRowView*)[_outline rowViewAtRow:row makeIfNecessary:YES] : nil;
  if ([rv isKindOfClass:SidebarRowView.class]) rv.pressed = down;
}
// Single click on a folder opens or closes it, as in Arc.
- (void)sidebarClicked:(id)sender {
  NSInteger row = _outline.clickedRow;
  ArcItem* a = row >= 0 ? [_outline itemAtRow:row] : nil;
  NSEventModifierFlags mods = NSApp.currentEvent.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagOption |
                                                                  NSEventModifierFlagShift | NSEventModifierFlagControl);
  if (a.url.length && mods == (NSEventModifierFlagCommand | NSEventModifierFlagOption)) {  // Arc: Cmd+Opt+click = Little Arc
    [self openLittleWindow:[self itemCurrentURL:a] ?: a.url];
    return;
  }
  if (a.isFolder) [self toggleFolder:a];
  if (a && a == _space.unpinned) {  // the "+ New Tab" row
    NSPoint p = [_outline convertPoint:NSApp.currentEvent.locationInWindow fromView:nil];
    NSRect rr = [_outline rectOfRow:row];
    if (p.y >= NSMaxY(rr) - kRowPitch) [self newTab:nil];
  }
}
- (void)toggleFolder:(ArcItem*)folder {
  if ([_outline isItemExpanded:folder]) [_outline collapseItem:folder];
  else [_outline expandItem:folder];
  [_outline reloadItem:folder];  // chevron direction
}
- (BOOL)folderExpanded:(ArcItem*)folder { return [_outline isItemExpanded:folder]; }
- (NSString*)folderChevronForItem:(ArcItem*)folder {  // tests: "right" / "down" / ""
  NSInteger row = [_outline rowForItem:folder];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  // Arc shows the folder's state with its own icon (open / closed folder) instead of a chevron.
  if (cell.imageView.image == FolderGlyph(YES)) return @"down";
  if (cell.imageView.image == FolderGlyph(NO)) return @"right";
  return @"";
}
- (BOOL)stockDisclosureShown { return !NSIsEmptyRect([_outline frameOfOutlineCellAtRow:0]); }  // tests
- (void)hoverSidebarItem:(ArcItem*)item { [self setSidebarHoverRow:item ? [_outline rowForItem:item] : -1]; }  // tests

- (BOOL)outlineView:(NSOutlineView*)ov shouldSelectItem:(id)item {
  return ((ArcItem*)item).url.length > 0 || ((ArcItem*)item).isSplit;
}

- (NSView*)outlineView:(NSOutlineView*)ov viewForTableColumn:(NSTableColumn*)col item:(id)item {
  ArcItem* a = item;
  NSTableCellView* cell = [ov makeViewWithIdentifier:@"cell" owner:self];
  if (!cell) {
    cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, col.width, kRowPitch)];
    cell.identifier = @"cell";
    NSImageView* icon = [[NSImageView alloc] initWithFrame:NSMakeRect(10, 12.5, 16, 16)];
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    icon.autoresizingMask = NSViewMaxYMargin;  // pinned to the bottom 41 pt (the "+ New Tab" header is taller)
    [cell addSubview:icon];
    cell.imageView = icon;
    NSTextField* label = [NSTextField labelWithString:@""];
    label.lineBreakMode = NSLineBreakByTruncatingTail;  // Arc 1.169 ends long titles in "..." (Omar's screenshot)
    label.frame = NSMakeRect(37, 11.5, col.width - 45, 18);
    label.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    [cell addSubview:label];
    cell.textField = label;
    NSImageView* chev = [[NSImageView alloc] initWithFrame:NSMakeRect(col.width - 24, 14.5, 12, 12)];
    chev.tag = 77;
    chev.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    chev.contentTintColor = NSColor.tertiaryLabelColor;
    chev.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightSemibold];
    [cell addSubview:chev];
  }
  NSImageView* chev = [cell viewWithTag:77];
  chev.hidden = YES;  // Arc has no chevron: the folder's own icon opens and closes
  if (a.isFolder) {
    BOOL open = [ov isItemExpanded:a];
    chev.image = [NSImage imageWithSystemSymbolName:open ? @"chevron.down" : @"chevron.right"
                           accessibilityDescription:open ? @"Collapse" : @"Expand"];
  }
  // Live Folders (Arc: SidebarItemUnreadBadgeView): a dot on entries that came in since you last looked, and the
  // folder's row counts them. Opening the tab clears it.
  NSImageView* dot = [cell viewWithTag:79];
  if (!dot) {
    dot = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"circle.fill" accessibilityDescription:@"Unread"]];
    dot.tag = 79;
    dot.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:5 weight:NSFontWeightRegular];
    dot.frame = NSMakeRect(1, 17.5, 6, 6);
    dot.autoresizingMask = NSViewMaxXMargin | NSViewMaxYMargin;
    [cell addSubview:dot];
  }
  dot.hidden = !a.liveUnread;
  dot.contentTintColor = NSColor.controlAccentColor;
  NSTextField* count = [cell viewWithTag:80];
  if (!count) {
    count = [NSTextField labelWithString:@""];
    count.tag = 80;
    count.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
    count.alignment = NSTextAlignmentCenter;
    count.textColor = NSColor.whiteColor;
    count.wantsLayer = YES;
    count.layer.cornerRadius = 7;
    count.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [cell addSubview:count];
  }
  NSUInteger unread = a.liveKind ? [self liveUnreadCountOf:a] : 0;
  count.hidden = unread == 0;
  CGFloat countWidth = 0;
  if (unread) {
    count.stringValue = unread > 99 ? @"99+" : [NSString stringWithFormat:@"%lu", (unsigned long)unread];
    countWidth = MAX(16, ceil(count.attributedStringValue.size.width) + 8);
    count.frame = NSMakeRect(cell.bounds.size.width - 28 - countWidth, 13.5, countWidth, 14);
    count.layer.backgroundColor = NSColor.controlAccentColor.CGColor;
  }
  NSString* title = a.displayTitle;
  if (a.isSplit) {
    NSMutableArray* names = [NSMutableArray array];
    for (ArcItem* pane in a.children) [names addObject:pane.displayTitle];
    title = [names componentsJoinedByString:@" | "];
  }
  BOOL newTab = a == _space.unpinned;
  BOOL dark = IsDark(ov);
  BOOL indigo = [self usingDefaultTheme];
  // Arc: tab titles 14 pt medium (lavender on the default dark theme); the "+ New Tab" row is dimmer.
  cell.textField.stringValue = newTab ? @"New Tab" : (a.isSection ? @"" : title);
  cell.textField.editable = a.isFolder;
  cell.textField.delegate = a.isFolder ? self : nil;
  // Arc: folder names are bold.
  cell.textField.font = [NSFont systemFontOfSize:14 weight:a.isFolder && !newTab ? NSFontWeightSemibold : NSFontWeightMedium];
  cell.textField.textColor = newTab ? [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.45]
                                    : (indigo ? ArcDefaultTabText() : NSColor.labelColor);
  // Cells fill the row; the header row's "+ New Tab" sits in its bottom 41 pt.
  NSRect lf = cell.textField.frame;
  lf.origin.x = 37;
  lf.origin.y = 11.5;
  lf.size.width = cell.bounds.size.width - lf.origin.x - 8 - (countWidth ? countWidth + 26 : 0);
  cell.textField.frame = lf;
  NSRect icf = cell.imageView.frame;
  icf.origin.y = 12.5;
  cell.imageView.frame = icf;
  cell.textField.hidden = a.isSection && !newTab;
  RowCloseButton* close = [cell viewWithTag:81];
  if (!close) {
    close = [RowCloseButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"xmark" accessibilityDescription:@"Close Tab"]
                                     target:self action:@selector(rowCloseClicked:)];
    close.tag = 81;
    close.bordered = NO;
    close.imagePosition = NSImageOnly;
    close.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightSemibold];
    close.frame = NSMakeRect(cell.bounds.size.width - 34, 8.5, 24, 24);
    close.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    close.toolTip = @"Close Tab";
    [cell addSubview:close];
  }
  close.applies = !a.isSection && !a.isFolder && !newTab && (a.url.length || a.isSplit || a.noteID || a.easelID);
  close.contentTintColor = indigo ? [ArcDefaultTabText() colorWithAlphaComponent:0.7] : NSColor.secondaryLabelColor;
  close.hidden = YES;
  // Arc keeps the site icon on a tab that plays sound and adds a speaker button at the row's right; a click mutes it.
  NSButton* speaker = [cell viewWithTag:84];
  BOOL audible = !a.isSection && !a.isFolder && !newTab && !a.crashed && (a.mediaPlaying || a.audioMuted);
  if (audible && !speaker) {
    speaker = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill" accessibilityDescription:@"Mute Tab"]
                                 target:self action:@selector(rowSpeakerClicked:)];
    speaker.tag = 84;
    speaker.bordered = NO;
    speaker.imagePosition = NSImageOnly;
    speaker.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightMedium];
    speaker.frame = NSMakeRect(cell.bounds.size.width - 34, 8.5, 24, 24);
    speaker.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [cell addSubview:speaker];
  }
  if (speaker) {
    speaker.hidden = !audible;
    speaker.image = [NSImage imageWithSystemSymbolName:a.audioMuted ? @"speaker.slash.fill" : @"speaker.wave.2.fill"
                              accessibilityDescription:a.audioMuted ? @"Unmute Tab" : @"Mute Tab"];
    speaker.toolTip = a.audioMuted ? @"Unmute Tab" : @"Mute Tab";
    speaker.contentTintColor = indigo ? [ArcDefaultTabText() colorWithAlphaComponent:0.7] : NSColor.secondaryLabelColor;
  }
  if ([cell.superview isKindOfClass:SidebarRowView.class]) [(SidebarRowView*)cell.superview syncCloseButton];
  // Arc's split row: each pane's icon and title side by side, split by a thin slash; the pane on screen is brighter.
  NSView* segs = nil;
  for (NSView* v in cell.subviews)
    if ([v.identifier isEqual:@"splitSegments"]) segs = v;
  if (a.isSplit && a.children.count) {
    if (!segs) {
      segs = [[NSView alloc] initWithFrame:NSZeroRect];
      segs.identifier = @"splitSegments";
      segs.autoresizingMask = NSViewMaxYMargin;
      [cell addSubview:segs];
    }
    for (NSView* v in [segs.subviews copy]) [v removeFromSuperview];
    CGFloat x0 = 10, W = cell.bounds.size.width - x0 - 8, n = a.children.count;
    segs.frame = NSMakeRect(x0, 4, W, 33);
    CGFloat slash = 12, segW = (W - slash * (n - 1)) / n;
    BOOL anyShown = [a.children containsObject:_shown];
    NSColor* text = indigo ? ArcDefaultTabText() : NSColor.labelColor;
    for (NSUInteger k = 0; k < n; ++k) {
      ArcItem* pane = a.children[k];
      CGFloat sx = k * (segW + slash);
      CGFloat alpha = !anyShown || pane == _shown ? 1 : 0.55;
      NSImageView* ic = [NSImageView imageViewWithImage:[self iconImageForItem:pane]];
      ic.imageScaling = NSImageScaleProportionallyUpOrDown;
      ic.frame = NSMakeRect(sx, 8.5, 16, 16);
      ic.alphaValue = alpha;
      [segs addSubview:ic];
      NSTextField* l = [NSTextField labelWithString:pane.displayTitle ?: @""];
      l.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
      l.textColor = text;
      l.lineBreakMode = NSLineBreakByTruncatingTail;
      l.frame = NSMakeRect(sx + 25, 7.5, MAX(10, segW - 27), 18);
      l.alphaValue = alpha;
      [segs addSubview:l];
      if (k + 1 < n) {  // Arc: TabCellSlash, white (black) 30%
        SplitSlashView* s = [[SplitSlashView alloc] initWithFrame:NSMakeRect(sx + segW + 2, 6, slash - 4, 21)];
        [segs addSubview:s];
      }
    }
    segs.hidden = NO;
    cell.textField.hidden = YES;
    cell.imageView.hidden = YES;
  } else {
    segs.hidden = YES;
  }
  // Other windows: "Move to main window" sits at the right of the Today header (Arc: moveToMainWindow).
  NSButton* toMain = [cell viewWithTag:78];
  if (newTab && !toMain) {
    toMain = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"macwindow.and.cursorarrow"
                                                 accessibilityDescription:@"Move to main window"]
                                target:self action:@selector(moveShownToMainWindow:)];
    toMain.tag = 78;
    toMain.bordered = NO;
    toMain.toolTip = @"Move to main window";
    toMain.frame = NSMakeRect(cell.bounds.size.width - 28, 10, 22, 22);
    toMain.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [cell addSubview:toMain];
  }
  toMain.hidden = !newTab || [self isMainWindowController];
  // Arc: hovering the Today divider shows a small "Clear" at its right that archives the Today tabs.
  NSButton* clear = [cell viewWithTag:83];
  if (newTab && !clear) {
    clear = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearToday:)];
    clear.tag = 83;
    clear.bordered = NO;
    clear.image = [NSImage imageWithSystemSymbolName:@"arrow.down" accessibilityDescription:nil];
    clear.imagePosition = NSImageLeading;
    clear.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:9 weight:NSFontWeightSemibold];
    clear.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    clear.toolTip = @"Archive Today's tabs";
    clear.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
    [cell addSubview:clear];
  }
  if (clear) {
    NSColor* dim = [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.45];
    clear.contentTintColor = dim;
    clear.attributedTitle = [[NSAttributedString alloc]
        initWithString:@"Clear"
            attributes:@{NSForegroundColorAttributeName : dim, NSFontAttributeName : [NSFont systemFontOfSize:11 weight:NSFontWeightMedium]}];
    [clear sizeToFit];
    NSRect cf = clear.frame;
    cf.origin = NSMakePoint(cell.bounds.size.width - 8 - cf.size.width, cell.bounds.size.height - 10 - cf.size.height / 2 - 1);
    clear.frame = cf;
    clear.hidden = !newTab || !_todayHeaderHovered || _space.unpinned.children.count == 0;
  }
  if (!toMain.hidden) toMain.contentTintColor = [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.45];
  NSImage* image = nil;
  if (newTab) {
    image = [NSImage imageWithSystemSymbolName:@"plus" accessibilityDescription:@"New Tab"];
    cell.imageView.contentTintColor = [NSColor colorWithWhite:dark ? 1 : 0 alpha:0.45];
  } else if (!a.isSection) {
    NSString* symbol = a.isFolder ? (a.liveKind ? @"dot.radiowaves.up.forward" : nil)
                                  : (a.noteID ? @"note.text" : (a.easelID ? @"scribble.variable" : nil));
    if (a.isSplit) symbol = a.splitHorizontal ? @"rectangle.split.1x2" : @"rectangle.split.2x1";
    if (a.crashed) symbol = @"exclamationmark.triangle";
    image = symbol ? [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil] : [self iconImageForItem:a];
    cell.imageView.contentTintColor = indigo ? [ArcDefaultTabText() colorWithAlphaComponent:0.85] : NSColor.secondaryLabelColor;
    if (a.isFolder && !a.liveKind) {
      BOOL open = [ov isItemExpanded:a];
      image = FolderGlyph(open);
      // Arc tints an open folder with the Space's colour (deeper); a closed one matches the text.
      NSColor* sc = _space.themeColors.count ? ColorFromHex(_space.themeColors.firstObject) : nil;
      if (open && sc) {
        CGFloat hh, ss, bb, aa;
        [[sc colorUsingColorSpace:NSColorSpace.sRGBColorSpace] getHue:&hh saturation:&ss brightness:&bb alpha:&aa];
        cell.imageView.contentTintColor = dark ? [NSColor colorWithHue:hh saturation:MIN(1, ss * 0.6) brightness:MIN(1, bb + 0.45) alpha:1]
                                               : [NSColor colorWithHue:hh saturation:MIN(1, ss * 1.4 + 0.25) brightness:MAX(0.45, bb * 0.8) alpha:1];
      } else {
        cell.imageView.contentTintColor = indigo ? ArcDefaultTabText() : NSColor.labelColor;
      }
    }
  }
  cell.imageView.image = image;
  NSProgressIndicator* spin = nil;
  for (NSView* v in cell.subviews)
    if ([v.identifier isEqual:@"spinner"]) spin = (NSProgressIndicator*)v;
  BOOL loading = !a.isSection && !a.isFolder && (a.loading || (a.isSplit && [a.children indexesOfObjectsPassingTest:^BOOL(ArcItem* c, NSUInteger, BOOL*) {
                                                                return c.loading;
                                                              }].count));
  if (loading && !spin) {
    spin = [[NSProgressIndicator alloc] initWithFrame:cell.imageView.frame];
    spin.style = NSProgressIndicatorStyleSpinning;
    spin.controlSize = NSControlSizeSmall;
    spin.displayedWhenStopped = NO;
    spin.identifier = @"spinner";
    spin.autoresizingMask = NSViewMaxYMargin;
    [cell addSubview:spin];
  }
  spin.frame = cell.imageView.frame;
  spin.hidden = !loading;
  cell.imageView.hidden = loading;
  if (loading) [spin startAnimation:nil];
  else [spin stopAnimation:nil];
  return cell;
}

#pragma mark Site icons

// Chromium's saved icons: this Space's own profile first, then (read-only) the same profile in Arc.
- (NSArray<NSString*>*)faviconDatabasesForSpace:(ArcSpace*)space {
  if (!space.profileDirectory.length) return @[];
  NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"];
  NSString* prefix = self.selfTestProfiles ? @"SelfTest Space " : @"Space ";
  NSString* mine = [[support stringByAppendingPathComponent:[prefix stringByAppendingString:space.profileDirectory]]
      stringByAppendingPathComponent:@"Favicons"];
  NSString* arc = [[[ArcDataDirectory() stringByAppendingPathComponent:@"User Data"]
      stringByAppendingPathComponent:space.profileDirectory] stringByAppendingPathComponent:@"Favicons"];
  return @[ mine, arc ];
}

- (NSImage*)iconImageForItem:(ArcItem*)item {
  NSString* url = item.url.length ? item.url : item.pinnedURL;
  if (item.isSplit) url = item.children.firstObject.url;
  ArcSpace* space = [self spaceOwningItem:item] ?: _space;
  __weak MainWindowController* weakSelf = self;
  NSImage* img = [[FaviconStore shared] iconForURL:url databases:[self faviconDatabasesForSpace:space]
                                            loaded:^{ [weakSelf queueIconRefresh]; }];
  if (img) return img;
  NSImage* globe = [NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil];
  [globe setTemplate:YES];
  return globe;
}

- (void)queueIconRefresh {
  if (_iconRefreshQueued) return;
  _iconRefreshQueued = YES;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
    self->_iconRefreshQueued = NO;
    NSInteger rows = self->_outline.numberOfRows;
    if (rows > 0)
      [self->_outline reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)rows)]
                                columnIndexes:[NSIndexSet indexSetWithIndex:0]];
    self->_favGrid.needsDisplay = YES;
  });
}

- (void)browser:(int)browserId faviconURL:(NSString*)iconURL {
  auto it = _browsers.find(browserId);
  ArcItem* item = [self itemForBrowserId:browserId];
  if (it == _browsers.end() || !item || !iconURL.length) return;
  NSString* page = [self itemCurrentURL:item];
  __weak MainWindowController* weakSelf = self;
  class Done : public CefDownloadImageCallback {
   public:
    explicit Done(void (^cb)(NSData*)) : cb_([cb copy]) {}
    void OnDownloadImageFinished(const CefString&, int, CefRefPtr<CefImage> image) override {
      NSData* png = nil;
      if (image && !image->IsEmpty()) {
        int w = 0, h = 0;
        CefRefPtr<CefBinaryValue> v = image->GetAsPNG(2.0f, true, w, h);
        if (!v) v = image->GetAsPNG(1.0f, true, w, h);
        if (v && v->GetSize()) {
          NSMutableData* d = [NSMutableData dataWithLength:v->GetSize()];
          v->GetData(d.mutableBytes, v->GetSize(), 0);
          png = d;
        }
      }
      void (^cb)(NSData*) = cb_;
      dispatch_async(dispatch_get_main_queue(), ^{ cb(png); });
    }
   private:
    void (^cb_)(NSData*);
    IMPLEMENT_REFCOUNTING(Done);
  };
  it->second->GetHost()->DownloadImage(iconURL.UTF8String, true, 32, false, new Done(^(NSData* png) {
    if (!png) return;
    [[FaviconStore shared] setIconData:png forURL:page];
    if (item.url.length && ![FaviconSiteKey(item.url) isEqualToString:FaviconSiteKey(page)])
      [[FaviconStore shared] setIconData:png forURL:item.url];
    [weakSelf queueIconRefresh];
  }));
}

#pragma mark Favorites grid

- (void)favoriteClicked:(ArcItem*)item {
  if (item.url.length) [self showItem:item];
  _favGrid.needsDisplay = YES;
}
- (BOOL)canDropFavorite:(id<NSDraggingInfo>)info {
  ArcItem* dragged = [self draggedItem:info];
  return dragged && _space.favorites && !dragged.isFolder && !dragged.isSplit && dragged.url.length;
}
- (BOOL)acceptFavoriteDrop:(id<NSDraggingInfo>)info index:(NSUInteger)index {
  if (![self canDropFavorite:info]) return NO;
  ArcItem* dragged = [self draggedItem:info];
  return [self moveItem:dragged toParent:_space.favorites index:(NSInteger)MIN(index, _space.favorites.children.count)];
}
- (NSArray<NSString*>*)favoriteTileTitles {  // tests
  NSMutableArray* out = [NSMutableArray array];
  for (ArcItem* f in _favGrid.items) [out addObject:f.displayTitle ?: @""];
  return out;
}
- (NSRect)favoritesGridFrame { return _favGrid.hidden ? NSZeroRect : [_favGrid convertRect:_favGrid.bounds toView:nil]; }  // tests
- (NSRect)spaceHeaderFrame { return [_spaceHeader convertRect:_spaceHeader.bounds toView:nil]; }  // tests
- (BOOL)defaultThemeShown { return !_themeView.hidden && [self usingDefaultTheme]; }  // tests

#pragma mark Media

static NSString* const kMediaProbeJS =
    @"(function(){var m=[].slice.call(document.querySelectorAll('video,audio'));"
     "var on=m.some(function(e){return !e.paused&&!e.ended&&e.readyState>2&&!e.muted&&e.volume>0;});"
     "var held=m.some(function(e){return e.__notarcPaused;});"
     "var s=navigator.mediaSession,md=s&&s.metadata,h=window.__notarcMSActions||{},art='';"
     "if(md&&md.artwork&&md.artwork.length)art=md.artwork[md.artwork.length-1].src||'';"
     "var meta=JSON.stringify({t:md?md.title:'',a:md?(md.artist||md.album||''):'',art:art,"
     "prev:!!h.previoustrack,next:!!h.nexttrack});"
     "console.log('__notarc_media__:'+(on?'playing':(held?'paused':'none'))+'|'+m.map(function(e){"
     "return [e.paused,e.ended,e.readyState,e.muted,e.volume,e.error&&e.error.code].join(',');}).join(';')+'|'+meta);})()";
// Remembers which media actions the page handles (previous / next track), so the mini player can offer them.
static NSString* const kMediaSessionHookJS =
    @"(()=>{const s=navigator.mediaSession;if(!s||window.__notarcMSHook)return;window.__notarcMSHook=1;"
    @"window.__notarcMSActions={};const o=s.setActionHandler.bind(s);"
    @"s.setActionHandler=(n,f)=>{window.__notarcMSActions[n]=f;return o(n,f);};})()";
// Runs the page's own previous / next track handler; a page without one skips 10 s back or forward instead.
static NSString* MediaActionJS(NSString* action) {
  int seek = [action isEqual:@"nexttrack"] ? 10 : -10;
  return [NSString stringWithFormat:@"(()=>{const f=(window.__notarcMSActions||{})['%@'];if(f){f({action:'%@'});return;}"
                                    @"for(const e of document.querySelectorAll('video,audio'))if(!e.paused)"
                                    @"e.currentTime=Math.max(0,e.currentTime+(%d));})()",
                                    action, action, seek];
}
static NSString* const kMediaPauseJS =
    @"(function(){[].slice.call(document.querySelectorAll('video,audio')).forEach(function(e){"
     "if(!e.paused){e.__notarcPaused=true;e.pause();}});})()";
static NSString* const kMediaResumeJS =
    @"(function(){[].slice.call(document.querySelectorAll('video,audio')).forEach(function(e){"
     "if(e.__notarcPaused){e.__notarcPaused=false;e.play();}});})()";

- (ArcItem*)itemForBrowserId:(int)browserId {
  for (ArcSpace* sp in _spaces)
    for (ArcItem* t in sp.allTabs)
      if (t.browserId == browserId) return t;
  return nil;
}

// Remembers the camera/mic streams a page asks for, so the sidebar's call buttons can turn them off.
static NSString* const kCallHookJS =
    @"(()=>{if(window.__notarcHook)return;window.__notarcHook=1;window.__notarcStreams=[];"
    @"const md=navigator.mediaDevices;if(!md||!md.getUserMedia)return;const g=md.getUserMedia.bind(md);"
    @"md.getUserMedia=c=>g(c).then(s=>{window.__notarcStreams.push(s);return s;});})()";

- (void)installCallHookInBrowser:(int)browserId {
  auto it = _browsers.find(browserId);
  if (it == _browsers.end()) return;
  CefRefPtr<CefFrame> f = it->second->GetMainFrame();
  f->ExecuteJavaScript(kCallHookJS.UTF8String, f->GetURL(), 0);
  f->ExecuteJavaScript(kMediaSessionHookJS.UTF8String, f->GetURL(), 0);
}

- (void)runJS:(NSString*)js inItem:(ArcItem*)item {  // also used by the self-test
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return;
  CefRefPtr<CefFrame> f = it->second->GetMainFrame();
  f->ExecuteJavaScript(js.UTF8String, f->GetURL(), 0);
}

- (void)pollMediaNow {
  for (auto& kv : _browsers) {
    CefRefPtr<CefFrame> f = kv.second->GetMainFrame();
    if (f) f->ExecuteJavaScript(kMediaProbeJS.UTF8String, f->GetURL(), 0);
  }
}

- (void)browser:(int)browserId mediaState:(NSString*)state info:(NSString*)info {
  ArcItem* item = [self itemForBrowserId:browserId];
  if (!item) return;
  BOOL playing = [state isEqualToString:@"playing"], paused = [state isEqualToString:@"paused"];
  NSRange j = [info rangeOfString:@"|{"];
  NSDictionary* meta = j.location == NSNotFound ? nil
      : [NSJSONSerialization JSONObjectWithData:[[info substringFromIndex:j.location + 1] dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0 error:nil];
  if ([meta isKindOfClass:NSDictionary.class]) {
    NSString* (^str)(NSString*) = ^NSString*(NSString* k) {
      id v = meta[k];
      return [v isKindOfClass:NSString.class] && [v length] ? v : nil;
    };
    BOOL changed = ![str(@"t") ?: @"" isEqual:item.mediaTitle ?: @""] || ![str(@"a") ?: @"" isEqual:item.mediaArtist ?: @""] ||
                   ![str(@"art") ?: @"" isEqual:item.mediaArtworkURL ?: @""] || [meta[@"prev"] boolValue] != item.mediaCanPrevious ||
                   [meta[@"next"] boolValue] != item.mediaCanNext;
    item.mediaTitle = str(@"t");
    item.mediaArtist = str(@"a");
    item.mediaArtworkURL = str(@"art");
    item.mediaCanPrevious = [meta[@"prev"] boolValue];
    item.mediaCanNext = [meta[@"next"] boolValue];
    if (changed && item == _mediaItem) [self updateMediaBar];
  }
  if (playing == item.mediaPlaying && paused == item.mediaPaused) return;
  item.mediaPlaying = playing;
  item.mediaPaused = paused;
  if ([_outline rowForItem:item] >= 0) [_outline reloadItem:item];
  [self updateMediaBar];
}

// The page's camera / microphone use changed (CEF reports it); a call tab gets call controls in the sidebar bar.
- (void)browser:(int)browserId captureVideo:(BOOL)video audio:(BOOL)audio {
  ArcItem* item = [self itemForBrowserId:browserId];
  if (!item) return;
  item.usingCamera = video;
  item.usingMic = audio;
  if (!audio) item.micMuted = NO;
  if (!video) item.cameraOff = NO;
  [self updateMediaBar];
}

- (ArcItem*)callItem {
  for (ArcSpace* s in _spaces)
    for (ArcItem* t in s.allTabs)
      if (t.browserId && (t.usingMic || t.usingCamera)) return t;
  return nil;
}

// Turns the page's own tracks on or off, like the mute buttons in Meet or Zoom: the call keeps the devices,
// the other side gets silence / a black frame. Streams are the ones the page asked for (see kCallHookJS).
- (void)setCallTrack:(NSString*)kind enabled:(BOOL)enabled inItem:(ArcItem*)item {
  [self runJS:[NSString stringWithFormat:@"(()=>{for(const s of window.__notarcStreams||[])for(const t of s.get%@Tracks())"
                                          @"t.enabled=%@;})()", kind, enabled ? @"true" : @"false"]
       inItem:item];
}

- (void)toggleCallMic:(ArcItem*)item {
  if (!item.usingMic) return;
  item.micMuted = !item.micMuted;
  [self setCallTrack:@"Audio" enabled:!item.micMuted inItem:item];
  [self updateMediaBar];
}

- (void)toggleCallCamera:(ArcItem*)item {
  if (!item.usingCamera) return;
  item.cameraOff = !item.cameraOff;
  [self setCallTrack:@"Video" enabled:!item.cameraOff inItem:item];
  [self updateMediaBar];
}

#pragma mark Calendar (#56)

// Refreshes once a minute while "Show next meeting" is on. The bar shows from 10 minutes before a meeting until it
// ends (Arc's lead time isn't in its data; 10 minutes is NotArc's call), with Join when the event has a call link.
- (void)applyCalendarSetting {
  BOOL on = SettingBool(kSettingCalendar);
  [_meetingTimer invalidate];
  _meetingTimer = nil;
  if (!on) {
    _todayEvents = nil;
    [self updateMeetingBar];
    return;
  }
  __weak MainWindowController* weakSelf = self;
  void (^refresh)(void) = ^{
    if (weakSelf.selfTestProfiles) return;  // tests feed events directly; never ask macOS for Calendar access
    CalendarLoadToday(^(NSArray<CalendarEvent*>* events, BOOL allowed) {
      MainWindowController* me = weakSelf;
      if (!me) return;
      me->_todayEvents = events;
      [me updateMeetingBar];
    });
  };
  refresh();
  _meetingTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer*) { refresh(); }];
}
- (void)showMeetingForVisualShots {  // --visual-shots only (memory-only settings)
  NSDate* now = [NSDate date];
  CalendarEvent* e = [CalendarEvent new];
  e.title = @"Design review";
  e.start = [now dateByAddingTimeInterval:300];
  e.end = [now dateByAddingTimeInterval:1800];
  e.meetingURL = @"https://meet.google.com/abc-defg-hij";
  SettingSetBool(kSettingCalendar, YES);
  [self setCalendarEventsForTest:@[ e ] now:now];
}
- (void)setCalendarEventsForTest:(NSArray<CalendarEvent*>*)events now:(NSDate*)now {
  _todayEvents = events;
  _calendarTestNow = now;
  [self updateMeetingBar];
}
- (void)updateMeetingBar {
  NSDate* now = _calendarTestNow ?: NSDate.date;
  CalendarEvent* e = SettingBool(kSettingCalendar) ? NextMeeting(_todayEvents, now, 10 * 60) : nil;
  _meeting = e;
  if (e) {
    _meetingTitle.stringValue = [NSString stringWithFormat:@"%@ \u00B7 %@", e.title, MeetingTimeLabel(e, now)];
    _meetingTitle.toolTip = e.title;
    _meetingJoin.hidden = !e.meetingURL.length;
  }
  if (_meetingBar.hidden == !e) return;
  _meetingBar.hidden = !e;
  [self layoutSidebar];
}
- (void)updateReady:(NSNotification*)n {
  NSString* version = n.userInfo[@"version"];
  ((NSTextField*)[_updateBanner viewWithTag:1]).stringValue = [NSString stringWithFormat:@"NotArc %@ is ready", version ?: @""];
  _updateBanner.hidden = NO;
  [self layoutSidebar];
}
- (void)hideUpdateBannerForTest {
  _updateBanner.hidden = YES;
  _restartToUpdateClicks = 0;
  [self layoutSidebar];
}
- (IBAction)restartToUpdate:(id)sender {
  if (self.selfTestProfiles) {  // tests count the click; they never quit
    ++_restartToUpdateClicks;
    return;
  }
  [[Updater shared] installReadyUpdate];
}
- (NSString*)updateBannerState {  // tests (V27)
  NSRect sb = _sidebarScroll.frame;
  return [NSString stringWithFormat:@"shown=%d text=%@ button=%@ belowTabs=%d clicks=%ld", !_updateBanner.hidden,
                                    ((NSTextField*)[_updateBanner viewWithTag:1]).stringValue,
                                    ((NSButton*)[_updateBanner viewWithTag:2]).title,
                                    _updateBanner.hidden || NSMaxY(_updateBanner.frame) <= NSMinY(sb), (long)_restartToUpdateClicks];
}
- (NSString*)meetingBarText { return _meetingBar.hidden ? nil : _meetingTitle.stringValue; }  // tests
- (BOOL)meetingJoinShown { return !_meetingBar.hidden && !_meetingJoin.hidden; }
- (IBAction)joinMeeting:(id)sender {
  NSString* url = _meeting.meetingURL;
  if (!url.length) return;
  // Zoom, Teams and FaceTime links hand over to their apps (the site asks first); Meet and the rest open as a tab.
  [self openInNewTab:url];
}
- (IBAction)toggleCalendar:(id)sender {
  SettingSetBool(kSettingCalendar, !SettingBool(kSettingCalendar));
  [self applyCalendarSetting];
}
- (NSArray<CalendarEvent*>*)todayEvents { return _todayEvents; }

#pragma mark Favorite previews (#57)

// Arc showed a preview when you hovered some Favorites. NotArc does it for Gmail (newest unread emails, from Gmail's
// own feed with the Space's sign-in; click one to open it in a Peek) and for calendar sites (today's events from
// the Mac's Calendar, when that's turned on). Other Favorites just get the unread badge (#20).
NSString* FavoritePreviewKind(NSString* url) {
  NSURL* u = [NSURL URLWithString:url ?: @""];
  NSString* host = u.host.lowercaseString ?: @"", *path = u.path.lowercaseString ?: @"";
  if ([host isEqualToString:@"mail.google.com"]) return @"gmail";
  if ([host isEqualToString:@"calendar.google.com"] || [host isEqualToString:@"calendar.proton.me"] ||
      [host hasSuffix:@"cal.com"] || (([host hasPrefix:@"outlook."] || [host hasSuffix:@".icloud.com"] ||
                                        [host isEqualToString:@"www.icloud.com"]) && [path containsString:@"calendar"]))
    return @"calendar";
  return nil;
}
- (void)favoriteHovered:(ArcItem*)item rect:(NSRect)rect {
  if (item == _favPreviewItem) return;
  _favPreviewItem = item;
  [_favPreviewTimer invalidate];
  [_favPreview close];
  _favPreview = nil;
  NSString* kind = FavoritePreviewKind([self itemCurrentURL:item]);
  if (!kind) return;
  __weak MainWindowController* weakSelf = self;
  _favPreviewTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 repeats:NO block:^(NSTimer*) {
    [weakSelf loadFavoritePreview:item kind:kind rect:rect];
  }];
}
- (void)loadFavoritePreview:(ArcItem*)item kind:(NSString*)kind rect:(NSRect)rect {
  __weak MainWindowController* weakSelf = self;
  if ([kind isEqualToString:@"gmail"]) {
    SpaceFetch([self contextForSpace:_space], kGmailFeedURL, nil, ^(NSInteger status, NSData* body, NSString*) {
      MainWindowController* me = weakSelf;
      if (!me || me->_favPreviewItem != item) return;
      [me showFavoritePreviewRows:[me gmailPreviewRows:status body:body] title:@"Gmail" rect:rect];
    });
    return;
  }
  NSArray* rows = SettingBool(kSettingCalendar) ? [self calendarPreviewRows:_todayEvents now:NSDate.date]
                                                : @[ @{@"text" : @"Turn on \u201CShow my next meeting from Calendar\u201D in Settings to see today\u2019s events here."} ];
  [self showFavoritePreviewRows:rows title:@"Today" rect:rect];
}
- (NSArray<NSDictionary*>*)gmailPreviewRows:(NSInteger)status body:(NSData*)body {
  if (status != 200 || ![[[NSString alloc] initWithData:body ?: NSData.data encoding:NSUTF8StringEncoding] containsString:@"<feed"])
    return @[ @{@"text" : @"Sign in to Gmail in this Space to see your unread email here."} ];
  NSArray* entries = GmailFeedEntries(body);
  if (!entries.count) return @[ @{@"text" : @"No unread email."} ];
  NSMutableArray* rows = [NSMutableArray array];
  for (NSDictionary* e in [entries subarrayWithRange:NSMakeRange(0, MIN(entries.count, (NSUInteger)6))])
    [rows addObject:@{@"text" : [NSString stringWithFormat:@"%@ \u2014 %@", e[@"name"] ?: e[@"email"] ?: @"", e[@"title"] ?: @""],
                      @"url" : e[@"link"] ?: @""}];
  return rows;
}
- (NSArray<NSDictionary*>*)calendarPreviewRows:(NSArray<CalendarEvent*>*)events now:(NSDate*)now {
  NSMutableArray* rows = [NSMutableArray array];
  NSDateFormatter* f = [NSDateFormatter new];
  f.timeStyle = NSDateFormatterShortStyle;
  for (CalendarEvent* e in events) {
    if ([e.end compare:now] != NSOrderedDescending) continue;
    NSString* when = e.allDay ? @"All day" : [f stringFromDate:e.start];
    [rows addObject:@{@"text" : [NSString stringWithFormat:@"%@  %@", when, e.title], @"url" : e.meetingURL ?: @""}];
    if (rows.count == 6) break;
  }
  return rows.count ? rows : @[ @{@"text" : @"Nothing else today."} ];
}
- (void)showFavoritePreviewRows:(NSArray<NSDictionary*>*)rows title:(NSString*)title rect:(NSRect)rect {
  _lastFavoritePreview = rows;
  if (self.selfTestProfiles && !self.window.isVisible) return;
  NSStackView* stack = [NSStackView new];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 4;
  stack.edgeInsets = NSEdgeInsetsMake(10, 12, 10, 12);
  NSTextField* head = [NSTextField labelWithString:title];
  head.font = [NSFont boldSystemFontOfSize:13];
  [stack addArrangedSubview:head];
  for (NSDictionary* r in rows) {
    NSButton* b = [NSButton buttonWithTitle:r[@"text"] target:self action:@selector(favoritePreviewRowClicked:)];
    b.bordered = NO;
    b.alignment = NSTextAlignmentLeft;
    b.font = [NSFont systemFontOfSize:12];
    b.lineBreakMode = NSLineBreakByTruncatingTail;
    b.toolTip = r[@"text"];
    b.identifier = r[@"url"];
    b.enabled = [r[@"url"] length] > 0;
    [b.widthAnchor constraintLessThanOrEqualToConstant:300].active = YES;
    [stack addArrangedSubview:b];
  }
  NSViewController* vc = [NSViewController new];
  vc.view = stack;
  stack.frame = NSMakeRect(0, 0, 324, stack.fittingSize.height);
  _favPreview = [NSPopover new];
  _favPreview.contentViewController = vc;
  _favPreview.behavior = NSPopoverBehaviorTransient;
  _favPreview.animates = NO;
  [_favPreview showRelativeToRect:rect ofView:_favGrid preferredEdge:NSRectEdgeMaxX];
}
- (void)favoritePreviewRowClicked:(NSButton*)sender {
  [_favPreview close];
  if (sender.identifier.length) [self openPeek:sender.identifier];
}
- (NSArray<NSDictionary*>*)lastFavoritePreview { return _lastFavoritePreview; }  // tests

- (BOOL)callControlsShown { return !_mediaBar.hidden && (!_callMic.hidden || !_callCam.hidden); }

- (IBAction)callBarMic:(id)sender { [self toggleCallMic:[self callItem]]; }
- (IBAction)callBarCamera:(id)sender { [self toggleCallCamera:[self callItem]]; }

- (void)updateMediaBar {
  ArcItem* call = [self callItem];
  _callMic.hidden = !call || !call.usingMic;
  _callCam.hidden = !call || !call.usingCamera;
  ArcItem* pick = nil;
  if (!call)
    for (ArcItem* t in _space.allTabs)
      if (t != _shown && t.browserId && (t.mediaPlaying || t.mediaPaused) && (!pick || (t.mediaPlaying && !pick.mediaPlaying)))
        pick = t;
  ArcItem* item = call ?: pick;
  _mediaItem = item;
  BOOL show = item != nil;
  if (show) {
    // Arc's bar: site icon, back, play/pause, forward and the speaker, spread evenly; a call swaps in mic and camera.
    _mediaPlay.hidden = _mediaPrev.hidden = _mediaNext.hidden = _mediaMute.hidden = call != nil;
    if (call) {
      _callMic.image = [NSImage imageWithSystemSymbolName:call.micMuted ? @"mic.slash.fill" : @"mic.fill" accessibilityDescription:nil];
      _callMic.contentTintColor = call.micMuted ? NSColor.systemRedColor : nil;
      _callCam.image = [NSImage imageWithSystemSymbolName:call.cameraOff ? @"video.slash.fill" : @"video.fill" accessibilityDescription:nil];
      _callCam.contentTintColor = call.cameraOff ? NSColor.systemRedColor : nil;
      _callMic.toolTip = call.micMuted ? @"Unmute microphone" : @"Mute microphone";
      _callCam.toolTip = call.cameraOff ? @"Turn camera on" : @"Turn camera off";
    } else {
      _mediaPlay.image = [NSImage imageWithSystemSymbolName:item.mediaPlaying ? @"pause.fill" : @"play.fill"
                                   accessibilityDescription:item.mediaPlaying ? @"Pause" : @"Play"];
      _mediaPlay.toolTip = item.mediaPlaying ? @"Pause" : @"Play";
      _mediaMute.image = [NSImage imageWithSystemSymbolName:item.audioMuted ? @"speaker.slash.fill" : @"speaker.wave.3.fill"
                                   accessibilityDescription:nil];
    }
    NSString* host = [NSURL URLWithString:item.url ?: @""].host ?: @"";
    if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
    _mediaTitle.stringValue = (!call && item.mediaTitle.length) ? item.mediaTitle : MediaBarTitle(item.displayTitle);
    _mediaSubtitle.stringValue = (!call && item.mediaArtist.length) ? item.mediaArtist : host;
    // Arc shows no text in the bar; what's playing is the icon's tooltip.
    _mediaArt.toolTip = _mediaSubtitle.stringValue.length
                            ? [NSString stringWithFormat:@"%@ — %@", _mediaTitle.stringValue, _mediaSubtitle.stringValue]
                            : _mediaTitle.stringValue;
    [self updateMediaArtworkFor:item];
    [self layoutMediaCard];
  }
  if (_mediaBar.hidden == !show) return;
  _mediaBar.hidden = !show;
  [self layoutSidebar];
}

// Arc (Omar's screenshot, 1x): the bar is black ~60% over the Space colour, 8 pt corners; the site icon (16 pt) sits
// 14 pt in and the four controls follow at even 53 pt steps, the speaker last, all in white ~65%.
- (void)layoutMediaCard {
  BOOL dark = IsDark(_sidebar);
  _mediaBar.layer.backgroundColor = (dark ? [NSColor colorWithWhite:0 alpha:0.60] : [NSColor colorWithWhite:1 alpha:0.60]).CGColor;
  NSColor* fg = dark ? [NSColor colorWithSRGBRed:0.667 green:0.667 blue:0.702 alpha:1] : [NSColor colorWithWhite:0 alpha:0.6];
  _mediaTitle.hidden = _mediaSubtitle.hidden = YES;
  CGFloat W = NSWidth(_mediaBar.bounds), first = 21.5, step = (W - 22 - first) / 4;
  _mediaArt.frame = NSMakeRect(first - 8, (kMediaCardHeight - 16) / 2, 16, 16);
  NSArray<NSButton*>* slots = _callMic.hidden && _callCam.hidden ? @[ _mediaPrev, _mediaPlay, _mediaNext, _mediaMute ]
                                                                 : @[ _callMic, _callCam ];
  NSUInteger i = 1;
  for (NSButton* b in slots) {
    if (b.hidden) continue;
    CGFloat cx = slots.count == 4 ? first + step * i : W - 22 - step * (slots.count - i);
    b.frame = NSMakeRect(round(cx - 12), (kMediaCardHeight - 24) / 2, 24, 24);
    if (b != _callMic && b != _callCam) b.contentTintColor = fg;
    ++i;
  }
}

// The page's artwork when it gives one (loaded once, never in hidden test runs), else the site's icon.
- (void)updateMediaArtworkFor:(ArcItem*)item {
  static NSCache<NSString*, NSImage*>* cache = [NSCache new];
  NSString* art = item.mediaArtworkURL;
  NSImage* img = art.length ? [cache objectForKey:art] : nil;
  if (!img && art.length && !self.selfTestProfiles && ![_mediaArtLoading isEqual:art] &&
      ([art hasPrefix:@"https://"] || [art hasPrefix:@"http://"])) {
    _mediaArtLoading = art;
    __weak MainWindowController* weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithURL:[NSURL URLWithString:art]
                               completionHandler:^(NSData* data, NSURLResponse*, NSError*) {
                                 NSImage* got = data.length ? [[NSImage alloc] initWithData:data] : nil;
                                 dispatch_async(dispatch_get_main_queue(), ^{
                                   if (got) [cache setObject:got forKey:art];
                                   [weakSelf updateMediaBar];
                                 });
                               }] resume];
  }
  _mediaArt.image = img ?: [self iconImageForItem:item];
  _mediaArt.imageScaling = NSImageScaleProportionallyUpOrDown;
  _mediaArt.layer.cornerRadius = img ? 3 : 0;
}

- (NSString*)mediaCardDescription {  // tests (visual parity V3)
  return [NSString stringWithFormat:@"h=%.0f title=%@ subtitle=%@ prev=%d play=%d next=%d mute=%d art=%d tip=%@ text=%d",
                                    NSHeight(_mediaBar.frame), _mediaTitle.stringValue, _mediaSubtitle.stringValue,
                                    !_mediaPrev.hidden, !_mediaPlay.hidden, !_mediaNext.hidden, !_mediaMute.hidden,
                                    _mediaArt.image != nil, _mediaArt.toolTip, !_mediaTitle.hidden];
}
- (void)setMediaCardHoveredForTest:(BOOL)hovered {
  ((MediaCardView*)_mediaBar).inside = hovered;
  [self updateMediaBar];
}

- (ArcItem*)mediaBarItem { return _mediaBar.hidden ? nil : _mediaItem; }

- (void)toggleMuteItem:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return;
  item.audioMuted = !item.audioMuted;
  it->second->GetHost()->SetAudioMuted(item.audioMuted);
  if ([_outline rowForItem:item] >= 0) [_outline reloadItem:item];
  [self updateMediaBar];
}

- (void)togglePlayItem:(ArcItem*)item {
  [self runJS:item.mediaPlaying ? kMediaPauseJS : kMediaResumeJS inItem:item];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [self pollMediaNow]; });
}

- (IBAction)toggleMuteCurrentTab:(id)sender { if (_shown) [self toggleMuteItem:_shown]; }
- (void)rowSpeakerClicked:(NSButton*)sender {
  NSInteger row = [_outline rowForView:sender];
  ArcItem* item = row >= 0 ? [_outline itemAtRow:row] : nil;
  if (item) [self toggleMuteItem:item];
}
- (NSString*)speakerStateForItem:(ArcItem*)item {  // tests (V26)
  NSInteger row = [_outline rowForItem:item];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  NSButton* s = [cell viewWithTag:84];
  return [NSString stringWithFormat:@"speaker=%d muted=%d", s && !s.hidden, [s.toolTip isEqual:@"Unmute Tab"]];
}
- (void)mediaBarPlay:(id)sender { if (_mediaItem) [self togglePlayItem:_mediaItem]; }
- (void)mediaBarMute:(id)sender { if (_mediaItem) [self toggleMuteItem:_mediaItem]; }
- (void)mediaBarPrevious:(id)sender { if (_mediaItem) [self runJS:MediaActionJS(@"previoustrack") inItem:_mediaItem]; }
- (void)mediaBarNext:(id)sender { if (_mediaItem) [self runJS:MediaActionJS(@"nexttrack") inItem:_mediaItem]; }
- (void)mediaBarShowTab:(id)sender { if (_mediaItem) [self showItem:_mediaItem]; }
- (void)menuToggleMute:(NSMenuItem*)sender { [self toggleMuteItem:sender.representedObject]; }
- (void)menuTogglePlay:(NSMenuItem*)sender { [self togglePlayItem:sender.representedObject]; }

#pragma mark Crashed and frozen pages

// The view standing for a page in NotArc's layout: the page's own view, or a Chrome-style page's placeholder.
- (NSView*)pageViewForBrowser:(CefRefPtr<CefBrowser>)browser {
  if (!browser) return nil;
  ChromePageHost* host = _chromePages[@(browser->GetIdentifier())];
  if (host) return host.placeholder;
  return CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
}

- (NSView*)webViewForItem:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  return it == _browsers.end() ? nil : [self pageViewForBrowser:it->second];
}

- (void)browser:(int)browserId rendererEvent:(int)kind status:(int)status {
  ArcItem* item = [self itemForBrowserId:browserId];
  if (!item) return;
  if (kind == 1) {
    [self showHungSheetFor:item];
    return;
  }
  if (item == _hungItem) [self dismissHungSheet];
  if (kind == 0) [self showCrashedViewFor:item status:status];
}

// ---- Site prompts ---------------------------------------------------------------------------------
static NSArray<NSArray*>* PermissionNames() {
  return @[
    @[ @(CEF_PERMISSION_TYPE_CAMERA_STREAM), @"camera", @"use your camera" ],
    @[ @(CEF_PERMISSION_TYPE_MIC_STREAM), @"microphone", @"use your microphone" ],
    @[ @(CEF_PERMISSION_TYPE_GEOLOCATION), @"location", @"know your location" ],
    @[ @(CEF_PERMISSION_TYPE_NOTIFICATIONS), @"notifications", @"show notifications" ],
    @[ @(CEF_PERMISSION_TYPE_CLIPBOARD), @"clipboard", @"see text and images you copy" ],
    @[ @(CEF_PERMISSION_TYPE_MIDI_SYSEX), @"midi", @"control your MIDI devices" ],
    @[ @(CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS), @"downloads", @"download multiple files" ],
    @[ @(CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT), @"windows", @"manage windows on your displays" ],
    @[ @(CEF_PERMISSION_TYPE_LOCAL_FONTS), @"fonts", @"use the fonts on your Mac" ],
    @[ @(CEF_PERMISSION_TYPE_IDLE_DETECTION), @"idle", @"know when you're using your Mac" ],
    @[ @(CEF_PERMISSION_TYPE_STORAGE_ACCESS), @"storage", @"use its cookies on other sites" ],
    @[ @(CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS), @"storage", @"use its cookies on other sites" ],
    @[ @(CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER), @"drm", @"play protected content" ],
    @[ @(CEF_PERMISSION_TYPE_KEYBOARD_LOCK), @"keyboard", @"capture keyboard shortcuts" ],
    @[ @(CEF_PERMISSION_TYPE_POINTER_LOCK), @"pointer", @"lock your pointer" ],
    @[ @(CEF_PERMISSION_TYPE_LOCAL_NETWORK), @"network", @"reach devices on your local network" ],
    @[ @(CEF_PERMISSION_TYPE_SENSORS), @"sensors", @"use motion sensors" ],
  ];
}

static NSString* OriginKey(NSString* origin) {
  NSURL* u = [NSURL URLWithString:origin];
  if (!u.host.length) return origin ?: @"";
  return u.port ? [NSString stringWithFormat:@"%@://%@:%@", u.scheme, u.host, u.port] : [NSString stringWithFormat:@"%@://%@", u.scheme, u.host];
}

- (NSDictionary*)sitePermissionsForOrigin:(NSString*)origin {
  return SettingObject(kSettingSitePermissions)[OriginKey(origin)] ?: @{};
}

- (void)rememberSite:(NSString*)origin names:(NSArray<NSString*>*)names allow:(BOOL)allow {
  NSMutableDictionary* all = [SettingObject(kSettingSitePermissions) mutableCopy] ?: [NSMutableDictionary dictionary];
  NSMutableDictionary* site = [all[OriginKey(origin)] mutableCopy] ?: [NSMutableDictionary dictionary];
  for (NSString* n in names) site[n] = @(allow);
  all[OriginKey(origin)] = site;
  SettingSetObject(kSettingSitePermissions, all);
}

- (void)browser:(int)browserId permissionRequest:(int)requestId origin:(NSString*)origin bits:(uint32_t)bits {
  NSMutableArray* names = [NSMutableArray array], *phrases = [NSMutableArray array];
  for (NSArray* p in PermissionNames())
    if ((bits & [p[0] unsignedIntValue]) && ![names containsObject:p[1]]) {
      [names addObject:p[1]];
      [phrases addObject:p[2]];
    }
  if (!names.count) {  // something we don't know how to describe: refuse quietly, like Chrome's default
    _client->ResolvePermission(requestId, false);
    return;
  }
  // Remembered answers: any remembered "no" refuses, all remembered "yes" allows.
  NSDictionary* saved = [self sitePermissionsForOrigin:origin];
  BOOL allKnown = YES;
  for (NSString* n in names) {
    if (saved[n] && ![saved[n] boolValue]) {
      _client->ResolvePermission(requestId, false);
      return;
    }
    if (!saved[n]) allKnown = NO;
  }
  if (allKnown) {
    _client->ResolvePermission(requestId, true);
    return;
  }
  NSString* list = phrases.count == 1 ? phrases[0]
                 : [[[phrases subarrayWithRange:NSMakeRange(0, phrases.count - 1)] componentsJoinedByString:@", "]
                       stringByAppendingFormat:@" and %@", phrases.lastObject];
  [self queueSitePrompt:@{ @"type" : @"permission", @"id" : @(requestId), @"origin" : origin ?: @"", @"names" : names,
                           @"title" : [NSString stringWithFormat:@"%@ wants to %@", [NSURL URLWithString:origin].host ?: origin, list],
                           @"allow" : @"Allow", @"deny" : @"Don't Allow" }];
}

- (void)browser:(int)browserId externalURL:(NSString*)url {
  NSURL* u = [NSURL URLWithString:url];
  NSURL* app = u ? [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:u] : nil;
  if (!app) return;  // nothing on this Mac opens it; Chromium shows nothing either
  ArcItem* item = [self itemForBrowserId:browserId];
  NSString* origin = item.url.length ? OriginKey(item.url) : @"";
  NSString* name = [@"open:" stringByAppendingString:u.scheme.lowercaseString ?: @""];
  NSNumber* saved = [self sitePermissionsForOrigin:origin][name];
  if (saved) {
    if (saved.boolValue) [NSWorkspace.sharedWorkspace openURL:u];
    return;
  }
  NSString* appName = [NSFileManager.defaultManager displayNameAtPath:app.path].stringByDeletingPathExtension;
  NSString* host = [NSURL URLWithString:origin].host;
  [self queueSitePrompt:@{ @"type" : @"external", @"url" : url, @"origin" : origin, @"names" : @[ name ],
                           @"title" : [NSString stringWithFormat:@"Open %@?", appName],
                           @"detail" : host.length ? [NSString stringWithFormat:@"%@ wants to open this link in %@.", host, appName]
                                                   : [NSString stringWithFormat:@"This link opens in %@.", appName],
                           @"allow" : [@"Open " stringByAppendingString:appName], @"deny" : @"Cancel" }];
}

- (void)queueSitePrompt:(NSDictionary*)prompt {
  if (!_sitePrompts) _sitePrompts = [NSMutableArray array];
  [_sitePrompts addObject:prompt];
  if (_sitePrompts.count == 1) [self showNextSitePrompt];
}

- (void)showNextSitePrompt {
  NSDictionary* p = _sitePrompts.firstObject;
  if (!p || _siteAlert) return;
  if (_hungAlert || self.window.attachedSheet) {  // wait for the other sheet
    __weak MainWindowController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ [weakSelf showNextSitePrompt]; });
    return;
  }
  NSAlert* a = [NSAlert new];
  a.messageText = p[@"title"];
  if (p[@"detail"]) a.informativeText = p[@"detail"];
  [a addButtonWithTitle:p[@"allow"]];
  [a addButtonWithTitle:p[@"deny"]];
  a.showsSuppressionButton = YES;
  a.suppressionButton.title = @"Remember for this site";
  _siteAlert = a;
  __weak MainWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    MainWindowController* me = weakSelf;
    if (!me || me->_siteAlert != a) return;
    [me finishSitePrompt:r == NSAlertFirstButtonReturn remember:a.suppressionButton.state == NSControlStateValueOn];
  }];
}

- (void)finishSitePrompt:(BOOL)allow remember:(BOOL)remember {
  NSDictionary* p = _sitePrompts.firstObject;
  _siteAlert = nil;
  if (!p) return;
  [_sitePrompts removeObjectAtIndex:0];
  if (remember) [self rememberSite:p[@"origin"] names:p[@"names"] allow:allow];
  if ([p[@"type"] isEqualToString:@"permission"]) _client->ResolvePermission([p[@"id"] intValue], allow);
  else if (allow) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:p[@"url"]]];
  [self showNextSitePrompt];
}

- (NSString*)pendingSitePrompt {
  NSDictionary* p = _siteAlert ? _sitePrompts.firstObject : nil;
  return p ? [NSString stringWithFormat:@"%@:%@", [p[@"names"] componentsJoinedByString:@","], p[@"origin"]] : nil;
}

- (void)answerSitePrompt:(BOOL)allow remember:(BOOL)remember {
  NSAlert* a = _siteAlert;
  if (!a) return;
  _siteAlert = nil;  // completion handler sees a stale alert and does nothing
  [self.window endSheet:a.window];
  _siteAlert = a;
  [self finishSitePrompt:allow remember:remember];
}

- (IBAction)resetSitePermissions:(id)sender {
  // item.url is the committed address (a pending mailto:/app link never replaces it).
  NSString* origin = _shown.url.length ? OriginKey(_shown.url) : nil;
  if (!origin.length) return;
  NSMutableDictionary* all = [SettingObject(kSettingSitePermissions) mutableCopy];
  [all removeObjectForKey:origin];
  SettingSetObject(kSettingSitePermissions, all ?: @{});
  // Chromium also keeps its own copy of granted permissions in the Space's profile; clear that too.
  auto it = _browsers.find(_shown.browserId);
  if (it == _browsers.end()) return;
  CefRefPtr<CefRequestContext> ctx = it->second->GetHost()->GetRequestContext();
  CefString o([origin stringByAppendingString:@"/"].UTF8String);
  for (cef_content_setting_types_t type :
       {CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS, CEF_CONTENT_SETTING_TYPE_GEOLOCATION, CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC,
        CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA, CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE})
    ctx->SetContentSetting(o, o, type, CEF_CONTENT_SETTING_VALUE_DEFAULT);
}

static NSArray<NSArray*>* SiteSettingRows() {
  return @[
    @[ @"camera", @"Camera", @(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA) ],
    @[ @"microphone", @"Microphone", @(CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC) ],
    @[ @"location", @"Location", @(CEF_CONTENT_SETTING_TYPE_GEOLOCATION) ],
    @[ @"notifications", @"Notifications", @(CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS) ],
    @[ @"clipboard", @"Clipboard", @(CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE) ],
  ];
}

- (void)setSitePermission:(NSString*)name value:(NSNumber*)allow forOrigin:(NSString*)origin {
  NSString* key = OriginKey(origin);
  NSMutableDictionary* all = [SettingObject(kSettingSitePermissions) mutableCopy] ?: [NSMutableDictionary dictionary];
  NSMutableDictionary* site = [all[key] mutableCopy] ?: [NSMutableDictionary dictionary];
  if (allow) site[name] = allow;
  else [site removeObjectForKey:name];
  if (site.count) all[key] = site;
  else [all removeObjectForKey:key];
  SettingSetObject(kSettingSitePermissions, all);
  // Keep Chromium's own stored answer in step, so an earlier grant can't bypass a new Block.
  auto it = _browsers.find(_shown.browserId);
  if (it == _browsers.end()) return;
  for (NSArray* r in SiteSettingRows())
    if ([r[0] isEqualToString:name]) {
      CefString o([key stringByAppendingString:@"/"].UTF8String);
      it->second->GetHost()->GetRequestContext()->SetContentSetting(
          o, o, (cef_content_setting_types_t)[r[2] intValue],
          !allow ? CEF_CONTENT_SETTING_VALUE_DEFAULT : (allow.boolValue ? CEF_CONTENT_SETTING_VALUE_ALLOW : CEF_CONTENT_SETTING_VALUE_BLOCK));
    }
}

- (BOOL)siteSettingsShown { return _sitePopover.isShown; }

- (NSArray<NSString*>*)siteSettingsRows {
  if (!_siteSettingsOrigin) return @[];
  NSDictionary* saved = [self sitePermissionsForOrigin:_siteSettingsOrigin];
  NSMutableArray* out = [NSMutableArray array];
  for (NSArray* r in SiteSettingRows()) {
    NSNumber* v = saved[r[0]];
    [out addObject:[NSString stringWithFormat:@"%@=%@", r[0], !v ? @"ask" : (v.boolValue ? @"allow" : @"block")]];
  }
  [out addObject:[NSString stringWithFormat:@"secure=%d", [_siteSettingsOrigin hasPrefix:@"https://"]]];
  return out;
}

- (IBAction)showSiteSettings:(id)sender {
  if (_sitePopover.isShown) {
    [_sitePopover close];
    return;
  }
  NSString* url = _shown.url;
  NSURL* u = url.length ? [NSURL URLWithString:url] : nil;
  if (!u.host.length) {
    NSBeep();
    return;
  }
  _siteSettingsOrigin = OriginKey(url);
  BOOL secure = [u.scheme isEqualToString:@"https"];
  NSTextField* host = [NSTextField labelWithString:[u.host hasPrefix:@"www."] ? [u.host substringFromIndex:4] : u.host];
  host.font = [NSFont boldSystemFontOfSize:14];
  NSImageView* lock = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:secure ? @"lock.fill" : @"exclamationmark.triangle"
                                                             accessibilityDescription:nil]];
  lock.contentTintColor = secure ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor;
  NSTextField* sec = [NSTextField labelWithString:secure ? @"Connection is secure" : @"Connection is not secure"];
  sec.textColor = NSColor.secondaryLabelColor;
  sec.font = [NSFont systemFontOfSize:11];
  NSMutableArray* views = [NSMutableArray arrayWithObjects:host, [NSStackView stackViewWithViews:@[ lock, sec ]], nil];
  NSDictionary* saved = [self sitePermissionsForOrigin:_siteSettingsOrigin];
  for (NSArray* r in SiteSettingRows()) {
    NSTextField* label = [NSTextField labelWithString:r[1]];
    [label.widthAnchor constraintEqualToConstant:110].active = YES;
    NSPopUpButton* pop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [pop addItemsWithTitles:@[ @"Ask", @"Allow", @"Block" ]];
    NSNumber* v = saved[r[0]];
    [pop selectItemAtIndex:!v ? 0 : (v.boolValue ? 1 : 2)];
    pop.identifier = r[0];
    pop.target = self;
    pop.action = @selector(sitePermissionChosen:);
    [views addObject:[NSStackView stackViewWithViews:@[ label, pop ]]];
  }
  if (SettingBool(kSettingBlockAds)) {
    NSButton* ads = [NSButton checkboxWithTitle:@"Block Ads & Trackers" target:self action:@selector(siteAdBlockToggled:)];
    ads.state = [self adBlockingOnForHost:u.host] ? NSControlStateValueOn : NSControlStateValueOff;
    NSButton* manage = [NSButton buttonWithTitle:@"Manage Ad Blockers..." target:self action:@selector(showManageAdBlockers:)];
    manage.controlSize = NSControlSizeSmall;
    [views addObject:[NSStackView stackViewWithViews:@[ ads, manage ]]];
  }
  if ([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"]) {
    NSButton* dev = [NSButton checkboxWithTitle:@"Developer Mode" target:self action:@selector(siteDeveloperModeToggled:)];
    dev.state = DeveloperModeOnForHost(u.host) ? NSControlStateValueOn : NSControlStateValueOff;
    dev.toolTip = @"Full address with port in the sidebar, never archived, Developer Tools in the address pill";
    [views addObject:dev];
  }
  NSButton* clear = [NSButton buttonWithTitle:@"Clear Cookies and Refresh" target:self action:@selector(siteSettingsClearCookies:)];
  NSButton* reset = [NSButton buttonWithTitle:@"Reset Permissions" target:self action:@selector(siteSettingsReset:)];
  [views addObject:[NSStackView stackViewWithViews:@[ clear, reset ]]];
  NSStackView* stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  stack.edgeInsets = NSEdgeInsetsMake(14, 16, 14, 16);
  NSViewController* vc = [NSViewController new];
  vc.view = stack;
  stack.frame = NSMakeRect(0, 0, stack.fittingSize.width, stack.fittingSize.height);
  _sitePopover = [NSPopover new];
  _sitePopover.behavior = NSPopoverBehaviorTransient;
  _sitePopover.contentViewController = vc;
  // Anchor: the address field when the toolbar is shown, else the top-left of the page.
  NSView* anchor = _toolbar.hidden ? _content : _address;
  NSRect r = _toolbar.hidden ? NSMakeRect(8, NSMaxY(_content.bounds) - 4, 1, 1) : NSMakeRect(8, 0, 20, _address.bounds.size.height);
  [_sitePopover showRelativeToRect:r ofView:anchor preferredEdge:_toolbar.hidden ? NSRectEdgeMinY : NSRectEdgeMaxY];
}

- (IBAction)showManageAdBlockers:(id)sender {
  [_sitePopover close];
  [ManageAdBlockersWindowController.shared showWindow:sender];
}

// Cosmetic filter-list rules (#53): a style sheet that hides matching elements, injected on page load like Boosts.
static std::string JSStringLiteral(const std::string& s) {
  std::string out = "\"";
  out.reserve(s.size() + 16);
  for (char c : s) {
    switch (c) {
      case '\\': out += "\\\\"; break;
      case '"': out += "\\\""; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '<': out += "\\x3c"; break;
      default:
        if ((unsigned char)c < 0x20) out += ' ';
        else out += c;
    }
  }
  out += "\"";
  return out;
}

- (void)applyAdBlockCosmeticsToBrowser:(int)browserId url:(NSString*)url {
  auto it = _browsers.find(browserId);
  if (it == _browsers.end()) return;
  std::string css = content_blocker::CosmeticCSS(url.UTF8String ?: "");
  static NSMutableSet* styled;  // browsers whose page got a style sheet, so a turned-off list also cleans up
  if (!styled) styled = [NSMutableSet set];
  if (css.empty() && ![styled containsObject:@(browserId)]) return;
  if (css.empty()) [styled removeObject:@(browserId)];
  else [styled addObject:@(browserId)];
  std::string js = "(function(){var id='__notarc_adblock__';var s=document.getElementById(id);var css=" +
                   JSStringLiteral(css) +
                   ";if(!css){if(s)s.remove();return;}if(!s){s=document.createElement('style');s.id=id;"
                   "(document.head||document.documentElement).appendChild(s);}s.textContent=css;})();";
  CefRefPtr<CefFrame> f = it->second->GetMainFrame();
  f->ExecuteJavaScript(js, f->GetURL(), 0);
}

static NSString* AdBlockSiteKey(NSString* host) {
  NSString* h = host.lowercaseString;
  return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

- (BOOL)adBlockingOnForHost:(NSString*)host {
  if (!host.length) return SettingBool(kSettingBlockAds);
  NSString* key = AdBlockSiteKey(host);
  for (NSString* e in SettingObject(kSettingAdBlockExceptions))
    if ([key isEqualToString:e] || [key hasSuffix:[@"." stringByAppendingString:e]]) return NO;
  return SettingBool(kSettingBlockAds);
}

- (void)setAdBlocking:(BOOL)on forHost:(NSString*)host {
  if (!host.length) return;
  NSString* key = AdBlockSiteKey(host);
  NSMutableArray* list = [SettingObject(kSettingAdBlockExceptions) mutableCopy] ?: [NSMutableArray array];
  [list removeObject:key];
  if (!on) [list addObject:key];
  SettingSetObject(kSettingAdBlockExceptions, list);
  ApplyContentBlockerSettings();
}

- (void)siteAdBlockToggled:(NSButton*)sender {
  NSString* host = [NSURL URLWithString:_siteSettingsOrigin].host;
  [self setAdBlocking:sender.state == NSControlStateValueOn forHost:host];
  if (auto b = [self currentBrowser]) b->Reload();  // Arc reloaded so the change shows
}

- (void)siteDeveloperModeToggled:(NSButton*)sender {
  SetDeveloperMode(sender.state == NSControlStateValueOn, [NSURL URLWithString:_siteSettingsOrigin].host);
}

- (void)sitePermissionChosen:(NSPopUpButton*)pop {
  NSInteger i = pop.indexOfSelectedItem;
  [self setSitePermission:pop.identifier value:i == 0 ? nil : @(i == 1) forOrigin:_siteSettingsOrigin];
}

- (void)siteSettingsClearCookies:(id)sender {
  [_sitePopover close];
  [self clearCookiesAndRefresh:nil];
}

- (void)siteSettingsReset:(id)sender {
  [_sitePopover close];
  [self resetSitePermissions:nil];
}

- (void)showCrashedViewFor:(ArcItem*)item status:(int)status {
  item.crashed = YES;
  item.mediaPlaying = item.mediaPaused = NO;
  NSView* web = [self webViewForItem:item];
  if (!web) return;
  if (!_crashViews) _crashViews = [NSMutableDictionary dictionary];
  [_crashViews[@(item.browserId)] removeFromSuperview];
  // Arc's sad tab: the page card turns plain with one centred drawing, a single line, and "Reload" as a link in it.
  NSBox* v = [[NSBox alloc] initWithFrame:web.bounds];  // a box's fill follows light / dark as it changes
  v.boxType = NSBoxCustom;
  v.borderWidth = 0;
  v.contentViewMargins = NSZeroSize;
  v.fillColor = NSColor.textBackgroundColor;
  v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSImageView* icon = [NSImageView imageViewWithImage:SadPageGlyph()];
  icon.contentTintColor = NSColor.tertiaryLabelColor;
  icon.identifier = @"sadGlyph";
  [icon.widthAnchor constraintEqualToConstant:72].active = YES;
  [icon.heightAnchor constraintEqualToConstant:80].active = YES;
  // 2 = killed, 3 = crashed, 4 = out of memory (cef_termination_status_t).
  NSString* why = status == 4 ? @"This page ran out of memory." : (status == 2 ? @"This page was stopped." : @"This page stopped working.");
  NSTextField* line = [NSTextField labelWithString:why];
  line.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
  line.textColor = NSColor.secondaryLabelColor;
  line.identifier = @"sadLine";
  NSButton* reload = [NSButton buttonWithTitle:@"Reload" target:self action:@selector(crashReloadClicked:)];
  reload.bordered = NO;
  reload.attributedTitle = [[NSAttributedString alloc]
      initWithString:@"Reload"
          attributes:@{NSForegroundColorAttributeName : NSColor.linkColor,
                       NSFontAttributeName : [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold]}];
  reload.keyEquivalent = @"\r";
  reload.tag = item.browserId;
  reload.identifier = @"sadReload";
  NSStackView* row = [NSStackView stackViewWithViews:@[ line, reload ]];
  row.spacing = 4;
  NSStackView* stack = [NSStackView stackViewWithViews:@[ icon, row ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.spacing = 18;
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [v.contentView addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.centerXAnchor constraintEqualToAnchor:v.contentView.centerXAnchor],
    [stack.centerYAnchor constraintEqualToAnchor:v.contentView.centerYAnchor constant:-20]
  ]];
  [web addSubview:v positioned:NSWindowAbove relativeTo:nil];
  _crashViews[@(item.browserId)] = v;
  if ([_outline rowForItem:item] >= 0) [_outline reloadItem:item];
}

- (NSString*)crashViewStyleForItem:(ArcItem*)item {  // tests (V10)
  NSView* v = _crashViews[@(item.browserId)];
  if (!v) return @"none";
  __block int glyph = 0, line = 0, link = 0;
  __block void (^walk)(NSView*) = nil;
  void (^w)(NSView*) = ^(NSView* x) {
    if ([x.identifier isEqual:@"sadGlyph"]) glyph = 1;
    if ([x.identifier isEqual:@"sadLine"]) line = 1;
    if ([x.identifier isEqual:@"sadReload"] && !((NSButton*)x).bordered) link = 1;
    for (NSView* s in x.subviews) walk(s);
  };
  walk = w;
  walk(v);
  walk = nil;
  return [NSString stringWithFormat:@"glyph=%d line=%d link=%d", glyph, line, link];
}
- (void)crashReloadClicked:(NSButton*)sender {
  ArcItem* item = [self itemForBrowserId:(int)sender.tag];
  if (item) [self reloadCrashedItem:item];
}

- (void)reloadCrashedItem:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return;
  [_crashViews[@(item.browserId)] removeFromSuperview];
  [_crashViews removeObjectForKey:@(item.browserId)];
  item.crashed = NO;
  NSString* url = [self itemCurrentURL:item];
  it->second->GetMainFrame()->LoadURL((url.length ? url : item.url).UTF8String);
  if ([_outline rowForItem:item] >= 0) [_outline reloadItem:item];
}

- (void)loadURL:(NSString*)url inItem:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it != _browsers.end()) it->second->GetMainFrame()->LoadURL(url.UTF8String);
}

- (void)sendKeyToItem:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return;
  it->second->GetHost()->SetFocus(true);
  CefKeyEvent e;
  e.type = KEYEVENT_RAWKEYDOWN;
  e.windows_key_code = 0x41;
  e.native_key_code = 0;
  it->second->GetHost()->SendKeyEvent(e);
  e.type = KEYEVENT_CHAR;
  e.character = e.unmodified_character = 'a';
  it->second->GetHost()->SendKeyEvent(e);
  e.type = KEYEVENT_KEYUP;
  it->second->GetHost()->SendKeyEvent(e);
  // Key events need a focused window; clicks reach the page (and the hang monitor) without one.
  CefMouseEvent m;
  m.x = 40;
  m.y = 40;
  it->second->GetHost()->SendMouseClickEvent(m, MBT_LEFT, false, 1);
  it->second->GetHost()->SendMouseClickEvent(m, MBT_LEFT, true, 1);
}

- (ArcItem*)hungItem { return _hungItem; }

- (void)showHungSheetFor:(ArcItem*)item {
  if (_hungAlert) return;
  _hungItem = item;
  NSAlert* a = [NSAlert new];
  a.messageText = @"Page Unresponsive";
  a.informativeText = [NSString stringWithFormat:@"\"%@\" isn't responding. You can wait for it or exit the page.",
                                                 item.displayTitle ?: item.url ?: @"This page"];
  [a addButtonWithTitle:@"Wait"];
  [a addButtonWithTitle:@"Exit Page"];
  _hungAlert = a;
  int browserId = item.browserId;
  __weak MainWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    MainWindowController* me = weakSelf;
    if (!me || me->_hungAlert != a) return;
    me->_hungAlert = nil;
    me->_hungItem = nil;
    if (r == NSAlertFirstButtonReturn || r == NSAlertSecondButtonReturn)
      me->_client->ResolveHung(browserId, r == NSAlertSecondButtonReturn);
  }];
}

- (void)dismissHungSheet {
  NSAlert* a = _hungAlert;
  _hungAlert = nil;
  _hungItem = nil;
  if (a) [self.window endSheet:a.window returnCode:NSModalResponseAbort];
}

// Self-test hook: press a button of the open Wait/Exit sheet.
- (void)answerHungSheet:(BOOL)exitPage {
  if (!_hungAlert) return;
  NSAlert* a = _hungAlert;
  [self.window endSheet:a.window returnCode:exitPage ? NSAlertSecondButtonReturn : NSAlertFirstButtonReturn];
}

#pragma mark Hover cards

static NSString* RelativeAgo(NSDate* d) {
  if (!d) return nil;
  NSRelativeDateTimeFormatter* f = [NSRelativeDateTimeFormatter new];
  f.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleFull;
  return [f localizedStringForDate:d relativeToDate:[NSDate date]];
}

- (void)mouseMoved:(NSEvent*)event {
  [self refreshThumbnailOfShownIfOlderThan:2];  // hover cards may be next: keep the shown tab's picture fresh
  NSPoint p = [_outline convertPoint:event.locationInWindow fromView:nil];
  NSInteger row = [_outline rowAtPoint:p];
  [self setSidebarHoverRow:row];
  ArcItem* item = row >= 0 ? [_outline itemAtRow:row] : nil;
  if (!item.url.length || item.isSection) item = nil;
  if (item == _hoverItem) return;
  _hoverItem = item;
  [_hoverTimer invalidate];
  _hoverTimer = nil;
  if (_hoverCard.shown) [self hideHoverCard];
  if (!item) return;
  __weak MainWindowController* weakSelf = self;
  _hoverTimer = [NSTimer scheduledTimerWithTimeInterval:0.7 repeats:NO block:^(NSTimer* t) {
    MainWindowController* me = weakSelf;
    if (me && me->_hoverItem == item) [me showHoverCardForItem:item];
  }];
}

- (void)mouseExited:(NSEvent*)event {
  [self setSidebarHoverRow:-1];
  _hoverItem = nil;
  [_hoverTimer invalidate];
  _hoverTimer = nil;
  [self hideHoverCard];
}

- (BOOL)hoverCardShown { return _hoverCard.shown; }
- (BOOL)hoverCardHasThumbnail { return _hoverCard != nil && _hoverCardHasThumbnail; }
- (NSString*)hoverCardStyle {  // tests (V34): banner edge to edge, a link row
  NSView* root = _hoverCard.contentViewController.view;
  __block NSView* banner = nil;
  __block NSView* link = nil;
  __block void (^walk)(NSView*);
  void (^w)(NSView*) = ^(NSView* v) {
    if ([v.identifier isEqual:@"hoverBanner"]) banner = v;
    if ([v.identifier isEqual:@"hoverLink"]) link = v;
    for (NSView* s in v.subviews) walk(s);
  };
  walk = w;
  if (root) walk(root);
  walk = nil;
  [root layoutSubtreeIfNeeded];
  BOOL edge = banner && fabs(banner.frame.size.width - root.bounds.size.width) <= 1 &&
              fabs(NSMaxY(banner.frame) - root.bounds.size.height) <= 1;
  return [NSString stringWithFormat:@"banner=%d edge=%d link=%d", banner != nil, edge, link != nil];
}

- (void)hideHoverCard {
  [_hoverCard close];
  _hoverCard = nil;
}

- (NSArray<NSString*>*)showHoverCardForItem:(ArcItem*)item {
  [self hideHoverCard];
  NSInteger row = [_outline rowForItem:item];
  if (row < 0 || !item.url.length) return nil;
  NSString* url = [self itemCurrentURL:item];
  NSURL* u = [NSURL URLWithString:url];
  NSString* host = u.host ?: url;
  if ([host hasPrefix:@"www."]) host = [host substringFromIndex:4];
  NSMutableArray<NSString*>* lines = [NSMutableArray arrayWithObjects:item.displayTitle ?: host, host, nil];
  NSString* state = item.browserId ? @"Open" : @"Asleep";
  if (item == _shown) state = @"Showing now";
  NSString* ago = RelativeAgo(item.lastActiveAt);
  [lines addObject:ago ? [NSString stringWithFormat:@"%@ · last used %@", state, ago] : state];
  if (item.pinnedURL.length && ![item.pinnedURL isEqualToString:url])
    [lines addObject:[@"Pinned at " stringByAppendingString:item.pinnedURL]];
  [lines addObject:url];

  // Arc's hover card: the page's picture edge to edge on top, then the title and a link row (site icon + domain).
  const CGFloat W = 300;
  NSStackView* stack = [NSStackView new];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 4;
  stack.edgeInsets = NSEdgeInsetsMake(0, 0, 12, 0);
  // The page as it looked when last on screen (#65); never for the tab you're looking at.
  _hoverCardHasThumbnail = NO;
  if (item.thumbnail && item != _shown) {
    NSImageView* iv = [NSImageView imageViewWithImage:item.thumbnail];
    iv.imageScaling = NSImageScaleAxesIndependently;
    iv.identifier = @"hoverBanner";
    NSSize s = item.thumbnail.size;
    CGFloat h = round(MIN(W * 0.56, s.width > 0 ? W * s.height / s.width : 160));
    [iv.widthAnchor constraintEqualToConstant:W].active = YES;
    [iv.heightAnchor constraintEqualToConstant:h].active = YES;
    [stack addArrangedSubview:iv];
    [stack setCustomSpacing:10 afterView:iv];
    _hoverCardHasThumbnail = YES;
  } else {
    stack.edgeInsets = NSEdgeInsetsMake(12, 0, 12, 0);
  }
  auto padded = ^NSView*(NSView* v) {  // text rows sit 14 pt in from the card's edges
    NSView* box = [NSView new];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
      [v.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:14],
      [v.trailingAnchor constraintLessThanOrEqualToAnchor:box.trailingAnchor constant:-14],
      [v.topAnchor constraintEqualToAnchor:box.topAnchor], [v.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
      [box.widthAnchor constraintEqualToConstant:W]
    ]];
    return box;
  };
  NSTextField* title = [NSTextField wrappingLabelWithString:lines[0]];
  title.preferredMaxLayoutWidth = W - 28;
  title.maximumNumberOfLines = 2;
  title.lineBreakMode = NSLineBreakByTruncatingTail;
  title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  title.textColor = NSColor.labelColor;
  [stack addArrangedSubview:padded(title)];
  NSImageView* fav = [NSImageView imageViewWithImage:[self iconImageForItem:item] ?: [NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil]];
  fav.imageScaling = NSImageScaleProportionallyUpOrDown;
  [fav.widthAnchor constraintEqualToConstant:14].active = YES;
  [fav.heightAnchor constraintEqualToConstant:14].active = YES;
  NSTextField* link = [NSTextField labelWithString:host];
  link.font = [NSFont systemFontOfSize:12];
  link.textColor = NSColor.secondaryLabelColor;
  link.lineBreakMode = NSLineBreakByTruncatingTail;
  NSStackView* linkRow = [NSStackView stackViewWithViews:@[ fav, link ]];
  linkRow.spacing = 6;
  linkRow.identifier = @"hoverLink";
  [stack addArrangedSubview:padded(linkRow)];
  NSTextField* when = [NSTextField labelWithString:lines[2]];
  when.font = [NSFont systemFontOfSize:11];
  when.textColor = NSColor.tertiaryLabelColor;
  [stack addArrangedSubview:padded(when)];
  NSViewController* vc = [NSViewController new];
  vc.view = stack;
  stack.frame = NSMakeRect(0, 0, W, stack.fittingSize.height);
  _hoverCard = [NSPopover new];
  _hoverCard.contentViewController = vc;
  _hoverCard.behavior = NSPopoverBehaviorApplicationDefined;
  _hoverCard.animates = NO;
  [_hoverCard showRelativeToRect:[_outline rectOfRow:row] ofView:_outline preferredEdge:NSRectEdgeMaxX];
  return lines;
}

- (void)outlineViewSelectionDidChange:(NSNotification*)notification {
  BOOL multi = _outline.selectedRowIndexes.count > 1;
  [_outline enumerateAvailableRowViewsUsingBlock:^(NSTableRowView* rv, NSInteger r) {
    if ([rv isKindOfClass:SidebarRowView.class] && ((SidebarRowView*)rv).multi != multi) {
      ((SidebarRowView*)rv).multi = multi;
      rv.needsDisplay = YES;
    }
  }];
  [self hideHoverCard];
  if (_syncingSidebar) return;  // redrawing for another window's change: never switch tabs here
  if (_outline.selectedRowIndexes.count > 1) return;  // multi-select only marks rows; it doesn't switch tabs
  ArcItem* item = [_outline itemAtRow:_outline.selectedRow];
  if (item.isSplit) {
    if ([item.children containsObject:_shown]) return;
    // Reopen the pane that was focused last.
    ArcItem* pane = item.children.firstObject;
    for (ArcItem* c in item.children)
      if (c.lastActiveAt && (!pane.lastActiveAt || [c.lastActiveAt compare:pane.lastActiveAt] == NSOrderedDescending))
        pane = c;
    if (pane) [self showItem:pane];
    return;
  }
  if (item && item != _shown) [self showItem:item];
}

- (void)selectSidebarRowFor:(ArcItem*)item {
  NSInteger row = [_outline rowForItem:item];
  ArcItem* parent = [self parentOfItem:item];
  if (row < 0 && parent.isSplit) row = [_outline rowForItem:parent];
  if (row >= 0 && row != _outline.selectedRow)
    [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
  if (row < 0 && _outline.selectedRow >= 0) [_outline deselectAll:nil];  // e.g. a Favorite is on screen
  _favGrid.needsDisplay = YES;
}

#pragma mark Persistence

// Coalesce bursts of changes (page titles arrive several times per load) into one write.
- (void)scheduleSave { [self scheduleSaveFrom:self]; }

- (void)scheduleSaveFrom:(MainWindowController*)origin {
  if (gMainWindow && gMainWindow != self) {  // one writer: the main window saves the shared sidebar
    [gMainWindow scheduleSaveFrom:origin];
    return;
  }
  if (gWindows.count > 1) {
    if (!_sidebarDirtyFrom) _sidebarDirtyFrom = [NSHashTable weakObjectsHashTable];
    [_sidebarDirtyFrom addObject:origin];
    if (!_sidebarRefreshScheduled) {
      _sidebarRefreshScheduled = YES;
      __weak MainWindowController* weakMain = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
        [weakMain refreshOtherWindows];
      });
    }
  }
  if (!self.storePath || _saveScheduled) return;
  _saveScheduled = YES;
  __weak MainWindowController* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [weakSelf saveSidebarNow];
  });
}

// Another window changed the shared sidebar: redraw ours. A window that made the change already redrew itself.
- (void)refreshOtherWindows {
  _sidebarRefreshScheduled = NO;
  NSArray* origins = _sidebarDirtyFrom.allObjects;
  [_sidebarDirtyFrom removeAllObjects];
  for (MainWindowController* w in [gWindows copy]) {
    if (origins.count == 1 && origins.firstObject == w) continue;
    [w sidebarModelChanged];
  }
}

- (void)sidebarModelChanged {
  if (!_content) return;
  if (_space && ![_spaces containsObject:_space]) {  // our Space was deleted elsewhere
    _space = nil;
    _shown = nil;
    [self rebuildSpacePicker];
    if (_spaces.count) [self switchToSpace:_spaces.firstObject];
    return;
  }
  _syncingSidebar = YES;
  [self reloadSidebar];
  if (_spacePicker.numberOfItems != (NSInteger)_spaces.count) [self rebuildSpacePicker];
  [self selectSidebarRowFor:_shown];
  _syncingSidebar = NO;
}

- (BOOL)sidebarShowsItem:(ArcItem*)item { return item && [_outline rowForItem:item] >= 0; }  // tests

- (void)saveSidebarNow {
  if (gMainWindow && gMainWindow != self) {
    [gMainWindow saveSidebarNow];
    return;
  }
  _saveScheduled = NO;
  if (!self.storePath) return;
  NSError* error = nil;
  if (!SidebarStoreSave(_spaces, _space.spaceID, self.storePath, &error))
    std::fprintf(stderr, "sidebar save failed: %s\n", error.localizedDescription.UTF8String);
}

#pragma mark Browser basics

- (CefRefPtr<CefBrowser>)currentBrowser {
  auto it = _browsers.find(_shown.browserId);
  return it == _browsers.end() ? nullptr : it->second;
}

- (IBAction)goBack:(id)sender { if (auto b = [self currentBrowser]) b->GoBack(); }
- (IBAction)goForward:(id)sender { if (auto b = [self currentBrowser]) b->GoForward(); }
- (IBAction)reloadPage:(id)sender { if (auto b = [self currentBrowser]) b->Reload(); }
- (IBAction)hardReload:(id)sender { if (auto b = [self currentBrowser]) b->ReloadIgnoreCache(); }
- (BOOL)hasLiveBrowser { return [self currentBrowser] != nullptr; }
- (void)startDownload:(NSString*)url {
  auto b = [self currentBrowser];
  if (b) b->GetHost()->StartDownload(url.UTF8String);
}

- (BOOL)isLoading { auto b = [self currentBrowser]; return b && b->IsLoading(); }
- (BOOL)canGoBack { auto b = [self currentBrowser]; return b && b->CanGoBack(); }
- (NSString*)currentURL {
  auto b = [self currentBrowser];
  return b ? [NSString stringWithUTF8String:b->GetMainFrame()->GetURL().ToString().c_str()] : _shown.url;
}

// Chromium zoom levels: 0 = 100%, each step is a factor of 1.2.
- (void)stepZoom:(double)delta {
  auto b = [self currentBrowser];
  if (!b) return;
  double level = delta == 0 ? 0 : b->GetHost()->GetZoomLevel() + delta;
  b->GetHost()->SetZoomLevel(MAX(-7.6, MIN(9.0, level)));
}
- (IBAction)zoomIn:(id)sender { [self stepZoom:0.5]; }
- (IBAction)zoomOut:(id)sender { [self stepZoom:-0.5]; }
- (IBAction)actualSize:(id)sender { [self stepZoom:0]; }
- (double)currentZoomLevel { auto b = [self currentBrowser]; return b ? b->GetHost()->GetZoomLevel() : 0; }

// Arc's find bar: a small rounded floating bar at the page card's top-right: field, match count, up / down
// arrows and a close button.
- (IBAction)findInPage:(id)sender {
  if (!_findBar) {
    _findBar = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 360, 40)
                                          styleMask:NSWindowStyleMaskBorderless
                                            backing:NSBackingStoreBuffered
                                              defer:NO];
    _findBar.backgroundColor = NSColor.clearColor;
    _findBar.opaque = NO;
    _findBar.hasShadow = YES;
    NSView* card = [[CommandCardView alloc] initWithFrame:NSMakeRect(0, 0, 360, 40)];
    card.wantsLayer = YES;
    card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_findBar.contentView addSubview:card];
    NSImageView* glass = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil]];
    glass.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:12 weight:NSFontWeightMedium];
    glass.contentTintColor = NSColor.secondaryLabelColor;
    glass.frame = NSMakeRect(12, 12, 16, 16);
    [_findBar.contentView addSubview:glass];
    _findField = [[NSSearchField alloc] initWithFrame:NSMakeRect(32, 10, 188, 20)];
    _findField.placeholderString = @"Find in page";
    _findField.delegate = (id<NSSearchFieldDelegate>)self;
    _findField.sendsSearchStringImmediately = YES;
    _findField.bezeled = NO;
    _findField.drawsBackground = NO;
    _findField.focusRingType = NSFocusRingTypeNone;
    _findField.font = [NSFont systemFontOfSize:13];
    ((NSSearchFieldCell*)_findField.cell).searchButtonCell = nil;  // NotArc draws its own glass; the bar has its own X
    ((NSSearchFieldCell*)_findField.cell).cancelButtonCell = nil;
    [_findBar.contentView addSubview:_findField];
    _findLabel = [NSTextField labelWithString:@""];
    _findLabel.frame = NSMakeRect(222, 12, 66, 16);
    _findLabel.alignment = NSTextAlignmentRight;
    _findLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    _findLabel.textColor = NSColor.secondaryLabelColor;
    [_findBar.contentView addSubview:_findLabel];
    CGFloat x = 292;
    for (NSArray* d in @[ @[ @"chevron.up", @"findPrevious:", @"Previous" ], @[ @"chevron.down", @"findNext:", @"Next" ],
                          @[ @"xmark", @"closeFindBar:", @"Close" ] ]) {
      NSButton* b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:d[0] accessibilityDescription:d[2]]
                                       target:self action:NSSelectorFromString(d[1])];
      b.bordered = NO;
      b.toolTip = d[2];
      b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:11 weight:NSFontWeightSemibold];
      b.contentTintColor = NSColor.secondaryLabelColor;
      b.frame = NSMakeRect(x, 8, 22, 24);
      b.tag = 91;
      [_findBar.contentView addSubview:b];
      x += 22;
    }
  }
  NSRect card = [self.window convertRectToScreen:[_content convertRect:_content.bounds toView:nil]];
  [_findBar setFrameOrigin:NSMakePoint(NSMaxX(card) - 360 - 10, NSMaxY(card) - 40 - 10)];
  [self.window addChildWindow:_findBar ordered:NSWindowAbove];
  [_findBar makeKeyAndOrderFront:nil];
  [_findBar makeFirstResponder:_findField];
}
- (IBAction)closeFindBar:(id)sender { [self hideFindBar]; }
- (NSString*)findBarStyle {  // tests (V35)
  NSUInteger buttons = 0;
  for (NSView* v in _findBar.contentView.subviews)
    if (v.tag == 91) ++buttons;
  NSRect card = [self.window convertRectToScreen:[_content convertRect:_content.bounds toView:nil]];
  BOOL corner = fabs(NSMaxX(_findBar.frame) - (NSMaxX(card) - 10)) <= 1 && fabs(NSMaxY(_findBar.frame) - (NSMaxY(card) - 10)) <= 1;
  return [NSString stringWithFormat:@"buttons=%lu card=%d corner=%d", (unsigned long)buttons,
                                    [_findBar.contentView.subviews.firstObject isKindOfClass:CommandCardView.class], corner];
}

- (void)hideFindBar {
  if (auto b = [self currentBrowser]) b->GetHost()->StopFinding(true);
  [self.window removeChildWindow:_findBar];
  [_findBar orderOut:nil];
  [self.window makeKeyWindow];
}

- (void)findText:(NSString*)text forward:(BOOL)forward {
  auto b = [self currentBrowser];
  if (!b) return;
  if (!text.length) {
    b->GetHost()->StopFinding(true);
    _findLabel.stringValue = @"";
    return;
  }
  b->GetHost()->Find(text.UTF8String, forward, false, true);
}

- (IBAction)findNext:(id)sender { [self findText:_findField.stringValue forward:YES]; }
- (IBAction)findPrevious:(id)sender { [self findText:_findField.stringValue forward:NO]; }

- (void)findResult:(int)count active:(int)active {
  _lastFindCount = count;
  _findLabel.stringValue = count ? [NSString stringWithFormat:@"%d of %d", active, count] : @"No matches";
}

- (int)lastFindCount { return _lastFindCount; }

- (IBAction)toggleDevTools:(id)sender {
  auto b = [self currentBrowser];
  if (!b) return;
  if (b->GetHost()->HasDevTools()) {
    b->GetHost()->CloseDevTools();
    return;
  }
  CefWindowInfo info;
  CefBrowserSettings settings;
  b->GetHost()->ShowDevTools(info, nullptr, settings, CefPoint());
}

// Arc offers to translate a page that's in another language (its address bar's translatePrompt). NotArc asks the
// page for its declared language once it has loaded (the shown tab only) and offers a one-tap Translate toast, once
// per site per launch. Translating still goes through Google's web translator, only when chosen.
// Web notifications (#78): shown in Notification Center when the site is allowed (NotArc's own Site Settings answer);
// clicking one brings NotArc forward on that tab. Test runs count them instead of posting.
- (BOOL)browser:(int)browserId notification:(NSString*)json pageURL:(NSString*)pageURL {
  NSDictionary* n = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  NSURL* u = [NSURL URLWithString:pageURL ?: @""];
  if (![n isKindOfClass:NSDictionary.class] || !u.host.length) return NO;
  NSString* origin = u.port ? [NSString stringWithFormat:@"%@://%@:%@", u.scheme, u.host, u.port]
                            : [NSString stringWithFormat:@"%@://%@", u.scheme, u.host];
  if (![[self sitePermissionsForOrigin:origin][@"notifications"] boolValue]) return NO;
  ArcItem* item = [self itemForBrowser:browserId];
  NSString* title = [n[@"title"] description].length ? [n[@"title"] description] : u.host;
  _lastNotification = @{ @"title" : title, @"body" : [n[@"body"] description] ?: @"", @"origin" : origin };
  if (self.selfTestProfiles) return YES;
  PostWebNotification(title, [n[@"body"] description] ?: @"", u.host, [n[@"tag"] description] ?: @"", item.itemID ?: @"");
  return YES;
}
- (NSDictionary*)lastNotification { return _lastNotification; }  // tests
- (void)showItemWithID:(NSString*)itemID {
  for (ArcSpace* sp in _spaces)
    for (ArcItem* section in [self sectionsOfSpace:sp]) {
      ArcItem* found = [self itemWithID:itemID under:section];
      if (!found) continue;
      if (sp != _space) [self switchToSpace:sp];
      [self showItem:found];
      if (!self.selfTestProfiles) [self.window makeKeyAndOrderFront:nil];
      return;
    }
}

- (void)detectLanguageInBrowser:(int)browserId url:(NSString*)url {
  if (!SettingBool(kSettingTranslateOffer) || ![url hasPrefix:@"http"] || [url containsString:@".translate.goog"]) return;
  ArcItem* item = [self itemForBrowser:browserId];
  if (!item || item != _shown) return;
  auto it = _browsers.find(browserId);
  if (it == _browsers.end()) return;
  it->second->GetMainFrame()->ExecuteJavaScript(
      "console.log('__notarc_lang__:'+((document.documentElement&&document.documentElement.lang)||''))", "", 0);
}
- (void)browser:(int)browserId pageLanguage:(NSString*)lang {
  ArcItem* item = [self itemForBrowser:browserId];
  NSString* offer = TranslateOfferFor(lang, NSLocale.preferredLanguages);
  NSString* host = [NSURL URLWithString:[self itemCurrentURL:item] ?: @""].host;
  if (!item || item != _shown || !offer || !host.length) return;
  if (!_translateOffered) _translateOffered = [NSMutableSet set];
  if ([_translateOffered containsObject:host]) return;
  [_translateOffered addObject:host];
  _lastTranslateOffer = offer;
  NSString* name = [NSLocale.currentLocale localizedStringForLanguageCode:offer] ?: offer;
  [self showToast:[NSString stringWithFormat:@"This page is in %@.", name] action:@"Translate" selector:@selector(translatePage:)];
}
- (NSString*)lastTranslateOffer { return _lastTranslateOffer; }  // tests
- (NSSize)lastCopiedImageSize { return _lastCopiedImageSize; }  // tests

// Developer Mode (#68): Arc's "Turn on/off Developer Mode for this site".
- (IBAction)toggleDeveloperMode:(id)sender {
  NSURL* u = [NSURL URLWithString:[self currentURL] ?: @""];
  if (!u.host.length) {
    NSBeep();
    return;
  }
  SetDeveloperMode(!DeveloperModeOnForHost(u.host), u.host);
}
- (IBAction)resetDeveloperModeSites:(id)sender { ResetDeveloperModeHosts(); }
- (BOOL)devToolsButtonShown { return _devToolsButton && !_devToolsButton.hidden; }

+ (MainWindowController*)mainController { return gMainWindow; }
+ (void)settingsDidChange {
  for (MainWindowController* w in [gWindows copy]) {
    [w applyColorScheme];
    [w applySpaceHeader:SettingBool(kSettingShowSpaceHeader)];
    [w layoutContentArea];  // toolbar on/off, and the pill
  }
}

- (IBAction)translatePage:(id)sender {
  NSString* url = [self currentURL];
  if (!url.length || !_shown) return;
  NSString* original = OriginalURLForTranslated(url);
  NSString* target = original ?: TranslateURLFor(url, PreferredTranslateLanguage());
  if (!target) { NSBeep(); return; }
  [self loadURL:target inItem:_shown];
}

- (IBAction)copyCurrentURL:(id)sender {
  NSString* url = [self currentURL];
  if (!url.length) return;
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:url forType:NSPasteboardTypeString];
}

- (IBAction)copyCurrentURLAsMarkdown:(id)sender {
  NSString* url = [self currentURL];
  if (!url.length) return;
  NSString* title = [_shown.displayTitle stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"[%@](%@)", title, url]
                                    forType:NSPasteboardTypeString];
}

#pragma mark Split view

static const CGFloat kPaneGap = 6;

// Panes on screen: the whole split if the shown tab belongs to it, otherwise just that tab.
- (NSArray<ArcItem*>*)visiblePanes {
  if (_shown && [_splitItems containsObject:_shown]) return _splitItems;
  return _shown ? @[ _shown ] : @[];
}

- (NSArray<NSValue*>*)framesForPaneCount:(NSUInteger)n {
  NSMutableArray* frames = [NSMutableArray array];
  NSRect b = _content.bounds;
  if (n == 0) return frames;
  CGFloat gap = n > 1 ? kPaneGap : 0;
  CGFloat total = (_splitHorizontal ? b.size.height : b.size.width) - gap * (n - 1);
  NSArray<NSNumber*>* fractions = n > 1 && _splitGroup.splitFractions.count == n ? _splitGroup.splitFractions : nil;
  CGFloat each = floor(total / n);
  CGFloat offset = 0;
  for (NSUInteger i = 0; i < n; ++i) {
    CGFloat size = fractions ? floor(total * fractions[i].doubleValue) : each;
    if (i == n - 1) size = MAX(0, (_splitHorizontal ? b.size.height : b.size.width) - offset);  // absorb rounding
    // Horizontal splits stack top to bottom; AppKit's origin is bottom-left.
    NSRect r = _splitHorizontal ? NSMakeRect(0, b.size.height - offset - size, b.size.width, size)
                                : NSMakeRect(offset, 0, size, b.size.height);
    [frames addObject:[NSValue valueWithRect:r]];
    offset += size + gap;
  }
  return frames;
}

// The split on screen is the split item that contains the shown tab.
- (void)syncSplitState {
  ArcItem* parent = _shown ? [self parentOfItem:_shown] : nil;
  if (parent.isSplit && parent.children.count > 1) {
    _splitGroup = parent;
    _splitItems = parent.children;
    _splitHorizontal = parent.splitHorizontal;
  } else {
    _splitGroup = nil;
    _splitItems = nil;
  }
}

- (ArcItem*)splitGroupOfShown { return _splitGroup; }
- (NSUInteger)dividerCount {
  NSUInteger n = 0;
  for (NSView* d in _dividers) n += !d.hidden;
  return n;
}

- (void)layoutDividers:(NSArray<NSValue*>*)frames {
  for (NSView* d in _dividers) [d removeFromSuperview];
  _dividers = [NSMutableArray array];
  for (NSUInteger i = 0; i + 1 < frames.count; ++i) {
    NSRect a = frames[i].rectValue, b = frames[i + 1].rectValue;
    NSRect r = _splitHorizontal ? NSMakeRect(0, NSMaxY(b), _content.bounds.size.width, NSMinY(a) - NSMaxY(b))
                                : NSMakeRect(NSMaxX(a), 0, NSMinX(b) - NSMaxX(a), _content.bounds.size.height);
    SplitDividerView* d = [[SplitDividerView alloc] initWithFrame:r];
    d.owner = self;
    d.index = i;
    d.horizontal = _splitHorizontal;
    [_content addSubview:d positioned:NSWindowAbove relativeTo:nil];
    [_dividers addObject:d];
  }
}

// Moves the boundary between pane index and index+1; each pane keeps at least 10%.
- (void)moveDivider:(NSUInteger)index toPosition:(CGFloat)position {
  NSUInteger n = _splitItems.count;
  if (!_splitGroup || index + 1 >= n) return;
  NSMutableArray<NSNumber*>* f = [NSMutableArray array];
  if (_splitGroup.splitFractions.count == n) [f addObjectsFromArray:_splitGroup.splitFractions];
  else for (NSUInteger i = 0; i < n; ++i) [f addObject:@(1.0 / n)];
  double before = 0;
  for (NSUInteger i = 0; i < index; ++i) before += f[i].doubleValue;
  double pair = f[index].doubleValue + f[index + 1].doubleValue;
  double left = MIN(MAX(position - before, 0.1), pair - 0.1);
  if (pair < 0.2) return;
  f[index] = @(left);
  f[index + 1] = @(pair - left);
  _splitGroup.splitFractions = f;
  [self layoutPanes];
  [self scheduleSave];
}

- (void)layoutPanes {
  [self syncSplitState];
  NSArray<ArcItem*>* panes = [self visiblePanes];
  for (ArcItem* pane in panes) {
    [self claimBrowserOfItem:pane];  // a tab is on screen in one window at a time; its page moves here
    [self ensureBrowserForItem:pane];
  }
  NSArray<NSValue*>* frames = [self framesForPaneCount:panes.count];
  if (_maximizedPane && (panes.count < 2 || ![panes containsObject:_maximizedPane] || _maximizedPane != _shown))
    _maximizedPane = nil;  // left the split, or focused another pane
  ArcItem* maxi = _maximizedPane;
  for (auto& kv : _browsers) {
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; i < panes.count; ++i)
      if (panes[i].browserId == kv.first) index = i;
    NSView* view = [self pageViewForBrowser:kv.second];
    BOOL visible = index != NSNotFound && (!maxi || panes[index] == maxi);
    if (visible) {
      view.frame = maxi ? _content.bounds : frames[index].rectValue;
      // A single pane follows the window; split panes are re-laid out on resize.
      view.autoresizingMask = panes.count == 1 || maxi ? (NSViewWidthSizable | NSViewHeightSizable) : NSViewNotSizable;
    }
    view.hidden = !visible;
    kv.second->GetHost()->WasHidden(!visible);
  }
  [self layoutDividers:panes.count > 1 && !maxi ? frames : @[]];
  // A maximized pane (#37) fills the card; a note in it gets the whole card too.
  if (maxi && [panes indexOfObject:maxi] != NSNotFound)
    [self layoutNoteEditorsForPanes:@[ maxi ] frames:@[ [NSValue valueWithRect:_content.bounds] ]];
  else
    [self layoutNoteEditorsForPanes:panes frames:frames];
  [self layoutEasel];
}

// MARK: Easels (Arc: easel). A canvas of page captures and text boxes, saved locally per easel.
- (NSString*)easelsDirectory {
  NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"];
  return [support stringByAppendingPathComponent:self.selfTestProfiles ? @"SelfTestEasels" : @"Easels"];
}
- (void)layoutEasel {
  ArcItem* e = _shown.easelID ? _shown : nil;
  if (e != _easelItem) {
    [_easelView save];
    _easelItem = e;
    if (e) {
      if (!_easelScroll) {
        _easelScroll = [[NSScrollView alloc] initWithFrame:_content.bounds];
        _easelScroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _easelScroll.hasVerticalScroller = YES;
        _easelScroll.hasHorizontalScroller = YES;
        _easelScroll.autohidesScrollers = YES;
        _easelView = [[EaselView alloc] initWithFrame:_easelScroll.bounds];
        _easelView.delegate = (id<EaselViewDelegate>)self;
        _easelScroll.documentView = _easelView;
        // The tool bar floats over the top of the canvas; content starts below it and scrolls under it.
        _easelScroll.automaticallyAdjustsContentInsets = NO;
        _easelScroll.contentInsets = NSEdgeInsetsMake(56, 0, 0, 0);
      }
      [_easelView loadFromDirectory:[[self easelsDirectory] stringByAppendingPathComponent:e.easelID]];
      // Opening an easel refreshes its live clips (off-screen, asynchronously; only easels that have clips).
      [self refreshLiveClips:NO];
    }
  }
  _easelScroll.hidden = !e;
  NSView* bar = _easelView ? _easelView.toolbar : nil;
  bar.hidden = !e;
  if (e) {
    _easelScroll.frame = _content.bounds;
    [_content addSubview:_easelScroll positioned:NSWindowAbove relativeTo:nil];
    [_content addSubview:bar positioned:NSWindowAbove relativeTo:_easelScroll];
    NSRect b = _content.bounds;
    bar.frameOrigin = NSMakePoint(round(NSMidX(b) - bar.frame.size.width / 2),
                                  _content.isFlipped ? 12 : NSMaxY(b) - bar.frame.size.height - 12);
    bar.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | (_content.isFlipped ? NSViewMaxYMargin : NSViewMinYMargin);
    [_easelView updateSize];
  }
}

// Live web clips (#49). A clip keeps its page address, the dragged region, the page size and scroll position. Its
// picture is re-rendered in a hidden off-screen browser in the Space's profile (so signed-in pages work), never by
// touching the user's tabs. Opening an easel refreshes clips older than a minute; File > Refresh Live Clips forces it.
static NSString* ClipKey(NSString* dir, EaselObject* o) {
  return [NSString stringWithFormat:@"%@|%@|%@", dir, o.link, NSStringFromRect(o.region)];
}
- (NSUInteger)refreshLiveClips:(BOOL)force {
  if (!_easelItem || !_easelView || !_space) return 0;
  NSString* dir = _easelView.directory;
  if (!_clipsRefreshing) _clipsRefreshing = [NSMutableSet set];
  CefRefPtr<CefRequestContext> ctx = [self contextForSpace:_space];
  CGFloat scale = self.window.backingScaleFactor ?: 2;
  NSUInteger started = 0;
  for (EaselObject* o in _easelView.liveClips) {
    if (!force && o.refreshedAt && -o.refreshedAt.timeIntervalSinceNow < 60) continue;
    NSString* key = ClipKey(dir, o);
    if ([_clipsRefreshing containsObject:key]) continue;
    [_clipsRefreshing addObject:key];
    started++;
    __weak MainWindowController* weakSelf = self;
    EaselRenderClip(ctx, o.link, o.viewport, o.scroll, o.region, scale, ^(NSData* png) {
      MainWindowController* me = weakSelf;
      if (!me) return;
      [me->_clipsRefreshing removeObject:key];
      me.clipRefreshesFinished++;
      if (!png || ![me->_easelView.directory isEqualToString:dir]) return;  // failed, or another easel is open now
      for (EaselObject* cur in me->_easelView.liveClips)
        if ([ClipKey(dir, cur) isEqualToString:key]) [me->_easelView replaceImageOf:cur png:png];
    });
  }
  return started;
}
- (IBAction)refreshLiveClipsFromMenu:(id)sender {
  if (![self refreshLiveClips:YES] && !_easelView.liveClips.count) NSBeep();
}
- (void)easelDidChange:(EaselView*)easel {
  // An easel is named from its first text box, like a note from its first line.
  NSString* t = nil;
  for (EaselObject* o in easel.objects)
    if ([o.kind isEqualToString:@"text"] && o.text.length) { t = o.text; break; }
  if (_easelItem && !(t == _easelItem.liveTitle || [t isEqualToString:_easelItem.liveTitle])) {
    _easelItem.liveTitle = t;
    [_outline reloadItem:_easelItem];
    [self scheduleSave];
  }
}
- (void)easel:(EaselView*)easel openLink:(NSString*)url { [self openInNewTab:url]; }
- (ArcItem*)createEaselWithID:(NSString*)easelID {
  if (!_space) return nil;
  ArcItem* n = [ArcItem new];
  n.itemID = NSUUID.UUID.UUIDString;
  n.easelID = easelID ?: NSUUID.UUID.UUIDString;
  n.url = [@"notarc://easel/" stringByAppendingString:n.easelID];
  n.children = [NSMutableArray array];
  n.lastActiveAt = [NSDate date];
  [_space.unpinned.children insertObject:n atIndex:0];
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  [self showItem:n];
  if (easelID) [self easelDidChange:_easelView];  // reopened: title from its first text box
  return n;
}
- (IBAction)newEasel:(id)sender { [self createEaselWithID:nil]; }

// Arc's history, per profile, into NotArc's History (Cmd+Y), tagged with the Space that uses that profile.
// Read-only on Arc's side; history isn't encrypted, so no Keychain access.
- (NSUInteger)importArcHistory {
  HistoryStore* store = [self historyStore];
  if (!store) return 0;
  NSMutableArray<ArchivedTab*>* all = [NSMutableArray array];
  NSMutableSet* done = [NSMutableSet set];
  for (ArcSpace* s in _spaces) {
    NSString* p = s.profileDirectory.length ? s.profileDirectory : @"Default";
    if ([done containsObject:p]) continue;
    [done addObject:p];
    NSError* error = nil;
    NSArray* visits = ArcReadHistory(self.arcHistoryOverride[p] ?: ArcHistoryDBPath(p), s.title, 20000, &error);
    if (visits) [all addObjectsFromArray:visits];
    else if (error) std::fprintf(stderr, "Arc history import skipped for %s: %s\n", p.UTF8String, error.localizedDescription.UTF8String);
  }
  return [store mergeVisits:all];
}

- (NSArray*)importArcExtensionsInto:(NSString*)destination fromArcUserData:(NSString*)userData {
  NSMutableArray* profiles = [NSMutableArray array];
  for (ArcSpace* s in _spaces) {
    NSString* p = s.profileDirectory.length ? s.profileDirectory : @"Default";
    if (![profiles containsObject:p]) [profiles addObject:p];
  }
  return ArcCopyExtensions(userData, profiles, destination);
}

// --- Chrome extensions (#66): picker, Install Extension..., on/off and Remove ---
static BOOL gExtensionsChanged = NO;  // installs, removals and on/off since launch wait for a relaunch

- (NSString*)extensionsDirectory {
  return self.extensionsDirectoryOverride ?: NotArcExtensionsDirectory(self.selfTestProfiles);
}

- (NSMutableArray<NSString*>*)disabledExtensionIDs {
  id a = SettingObject(kDisabledExtensionsKey);
  return [a isKindOfClass:NSArray.class] ? [a mutableCopy] : [NSMutableArray array];
}

// Each Space's Chromium profile folder: extensions installed by Chromium itself (the Web Store's own button) live there.
- (NSArray<NSString*>*)chromeProfileFolders {
  if (self.extensionsDirectoryOverride) return @[];
  NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"];
  NSString* p = _space.profileDirectory;
  if (!p.length) return @[];
  return @[ [support stringByAppendingPathComponent:[(self.selfTestProfiles ? @"SelfTest Space " : @"Space ") stringByAppendingString:p]] ];
}

- (NSArray<NotArcExtension*>*)installedExtensions {
  return InstalledExtensions([self extensionsDirectory], [self chromeProfileFolders],
                             [NSSet setWithArray:[self disabledExtensionIDs]]);
}

- (BOOL)extensionPickerButtonShown { return _extensionsButton && !_extensionsButton.hidden; }
- (NSInteger)relaunchRequestsForTest { return _relaunchRequests; }

- (NSMenuItem*)pickerItem:(NSString*)title action:(SEL)action object:(id)object {
  NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  mi.target = self;
  mi.representedObject = object;
  return mi;
}

- (NSMenu*)extensionPickerMenuForURL:(NSString*)url {
  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"Extensions"];
  menu.autoenablesItems = NO;
  NSString* pageID = ExtensionIDFromInput(url ?: @"");
  if (pageID) [menu addItem:[self pickerItem:@"Add This Extension to NotArc" action:@selector(installExtensionFromPage:) object:pageID]];
  if (gExtensionsChanged)
    [menu addItem:[self pickerItem:@"Relaunch NotArc to Apply Changes" action:@selector(relaunchToApplyExtensions:) object:nil]];
  if (menu.numberOfItems) [menu addItem:NSMenuItem.separatorItem];
  NSArray<NotArcExtension*>* list = [self installedExtensions];
  for (NotArcExtension* x in list) {
    NSString* title = x.enabled ? x.name : [x.name stringByAppendingString:@" (off)"];
    NSMenuItem* row = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    row.representedObject = x;
    NSImage* icon = x.iconPath ? [[NSImage alloc] initWithContentsOfFile:x.iconPath] : nil;
    if (!icon) icon = [NSImage imageWithSystemSymbolName:@"puzzlepiece.extension" accessibilityDescription:nil];
    icon.size = NSMakeSize(16, 16);
    row.image = icon;
    NSMenu* sub = [[NSMenu alloc] initWithTitle:x.name];
    sub.autoenablesItems = NO;
    if (x.popupPage) [sub addItem:[self pickerItem:@"Open" action:@selector(openExtensionPopup:) object:x]];
    if (x.optionsPage) [sub addItem:[self pickerItem:@"Options" action:@selector(openExtensionOptions:) object:x]];
    for (NSMenuItem* mi in sub.itemArray) mi.enabled = x.enabled && ChromePagesEnabled();
    if (sub.numberOfItems) [sub addItem:NSMenuItem.separatorItem];
    if (x.managedByNotArc) {
      [sub addItem:[self pickerItem:x.enabled ? @"Turn Off" : @"Turn On" action:@selector(toggleExtension:) object:x]];
      [sub addItem:[self pickerItem:@"Update from Chrome Web Store" action:@selector(updateExtension:) object:x]];
      [sub addItem:[self pickerItem:@"Remove..." action:@selector(removeExtension:) object:x]];
    } else {  // installed by Chromium itself: on/off and Remove live on its Extensions page
      NSMenuItem* manage = [self pickerItem:@"Manage on Extensions Page" action:@selector(manageChromeExtension:) object:x];
      manage.enabled = ChromePagesEnabled();
      [sub addItem:manage];
    }
    row.submenu = sub;
    [menu addItem:row];
  }
  if (!list.count) {
    NSMenuItem* none = [[NSMenuItem alloc] initWithTitle:@"No extensions yet" action:nil keyEquivalent:@""];
    none.enabled = NO;
    [menu addItem:none];
  }
  [menu addItem:NSMenuItem.separatorItem];
  [menu addItem:[self pickerItem:@"Install Extension..." action:@selector(installExtension:) object:nil]];
  [menu addItem:[self pickerItem:@"Chrome Web Store" action:@selector(openChromeWebStore:) object:nil]];
  NSMenuItem* manage = [self pickerItem:@"Manage Extensions" action:@selector(manageExtensions:) object:nil];
  manage.enabled = ChromePagesEnabled();
  [menu addItem:manage];
  return menu;
}

- (IBAction)showExtensionPicker:(id)sender {
  NSMenu* menu = [self extensionPickerMenuForURL:[self currentURL]];
  NSView* anchor = _extensionsButton ?: _addressPill;
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, NSHeight(anchor.bounds) + 4) inView:anchor];
}

- (void)openExtensionPage:(NSString*)page of:(NotArcExtension*)x {
  if (!page.length || !x.extensionID) return;
  NSString* rel = [page hasPrefix:@"/"] ? [page substringFromIndex:1] : page;
  [self openInNewTab:[NSString stringWithFormat:@"chrome-extension://%@/%@", x.extensionID, rel]];
}
// An extension's popup shows in a bubble under the picker button (CEF has no extension toolbar of its own).
- (IBAction)openExtensionPopup:(NSMenuItem*)sender { [self showPopupOfExtension:sender.representedObject]; }

- (ExtensionPopup*)extensionPopup { return _extensionPopup.isOpen ? _extensionPopup : nil; }
- (NSView*)extensionPopupAnchor {
  return _extensionsButton && !_extensionsButton.isHiddenOrHasHiddenAncestor ? _extensionsButton : _addressPill;
}

- (ExtensionPopup*)showPopupOfExtension:(NotArcExtension*)x {
  [_extensionPopup closeBecause:@"replaced"];
  _extensionPopup = nil;
  if (!x.popupPage.length || !x.extensionID || !_space) return nil;
  if (![self contextIsReady:_space.profileDirectory]) return nil;
  NSString* rel = [x.popupPage hasPrefix:@"/"] ? [x.popupPage substringFromIndex:1] : x.popupPage;
  NSString* url = [NSString stringWithFormat:@"chrome-extension://%@/%@", x.extensionID, rel];
  ExtensionPopup* popup = [[ExtensionPopup alloc] initWithURL:url
                                                       context:[self contextForSpace:_space]
                                                        parent:self.window
                                                        anchor:[self extensionPopupAnchor]
                                                        hidden:self.selfTestProfiles];
  if (!popup) {  // couldn't make a Chrome-style page: show it the old way, in a tab
    [self openExtensionPage:x.popupPage of:x];
    return nil;
  }
  __weak MainWindowController* weakSelf = self;
  __weak ExtensionPopup* weakPopup = popup;
  popup.openURL = ^(NSString* link) {
    [weakPopup closeBecause:@"link"];
    [weakSelf openInNewTab:link];
  };
  popup.onClose = ^{
    MainWindowController* me = weakSelf;
    if (me && me->_extensionPopup == weakPopup) me->_extensionPopup = nil;
  };
  _extensionPopup = popup;
  return popup;
}
- (IBAction)openExtensionOptions:(NSMenuItem*)sender { [self openExtensionPage:((NotArcExtension*)sender.representedObject).optionsPage of:sender.representedObject]; }
- (IBAction)manageExtensions:(id)sender { [self openInNewTab:@"chrome://extensions"]; }
- (IBAction)manageChromeExtension:(NSMenuItem*)sender {
  [self openInNewTab:[@"chrome://extensions/?id=" stringByAppendingString:((NotArcExtension*)sender.representedObject).extensionID]];
}
- (IBAction)openChromeWebStore:(id)sender { [self openInNewTab:@"https://chromewebstore.google.com/"]; }

- (BOOL)setExtension:(NSString*)extensionID enabled:(BOOL)enabled {
  if (!extensionID.length) return NO;
  NSMutableArray* off = [self disabledExtensionIDs];
  [off removeObject:extensionID];
  if (!enabled) [off addObject:extensionID];
  SettingSetObject(kDisabledExtensionsKey, off);
  gExtensionsChanged = YES;
  return YES;
}
- (IBAction)toggleExtension:(NSMenuItem*)sender {
  NotArcExtension* x = sender.representedObject;
  [self setExtension:x.extensionID enabled:!x.enabled];
  [self offerRelaunchForExtensions:[NSString stringWithFormat:x.enabled ? @"%@ is turned off." : @"%@ is turned on.", x.name]];
}

- (BOOL)removeExtensionWithID:(NSString*)extensionID {
  if (!RemoveExtensionFolder([self extensionsDirectory], extensionID)) return NO;
  NSMutableArray* off = [self disabledExtensionIDs];
  [off removeObject:extensionID];
  SettingSetObject(kDisabledExtensionsKey, off);
  gExtensionsChanged = YES;
  return YES;
}
- (IBAction)removeExtension:(NSMenuItem*)sender {
  NotArcExtension* x = sender.representedObject;
  NSAlert* a = [NSAlert new];
  a.messageText = [NSString stringWithFormat:@"Remove %@?", x.name];
  a.informativeText = @"It's deleted from NotArc and stops when NotArc relaunches.";
  [a addButtonWithTitle:@"Remove"];
  [a addButtonWithTitle:@"Cancel"];
  __weak MainWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSAlertFirstButtonReturn && [weakSelf removeExtensionWithID:x.extensionID])
      dispatch_async(dispatch_get_main_queue(), ^{
        [weakSelf offerRelaunchForExtensions:[NSString stringWithFormat:@"%@ is removed.", x.name]];
      });
  }];
}

- (void)installExtensionFromInput:(NSString*)input done:(void (^)(NSString* name, NSError* error))done {
  NSString* extID = ExtensionIDFromInput(input ?: @"");
  if (!extID) {
    done(nil, [NSError errorWithDomain:@"NotArcExtensions" code:2 userInfo:@{
      NSLocalizedDescriptionKey : @"Paste a link to an extension's Chrome Web Store page, or its 32-letter ID."}]);
    return;
  }
  __weak MainWindowController* weakSelf = self;
  InstallExtensionFromWebStore(extID, [self extensionsDirectory], ^(NSString* installedID, NSString* name, NSError* error) {
    if (name) {
      [weakSelf setExtension:installedID enabled:YES];  // a reinstall turns it back on
      [weakSelf turnOnChromePagesForExtensions];
    }
    done(name, error);
  });
}

- (void)reportExtensionInstall:(NSString*)name error:(NSError*)error {
  if (!name) {
    NSAlert* a = [NSAlert new];
    a.messageText = @"Couldn't install the extension";
    a.informativeText = error.localizedDescription ?: @"";
    [a beginSheetModalForWindow:self.window completionHandler:nil];
    return;
  }
  [self offerRelaunchForExtensions:[NSString stringWithFormat:@"%@ is installed.", name]];
}

// CEF loads extensions only at startup, so every change offers a relaunch, in the usual toast. With Chrome-style
// pages turned off for next time, there's nothing a relaunch would run, so the toast just says so.
- (void)offerRelaunchForExtensions:(NSString*)message {
  if (!SettingBool(kSettingChromePages)) {
    [self showToast:[message stringByAppendingString:@" Extensions need Chrome-style pages (Settings > Advanced)."]
            buttons:@[] target:self duration:8];
    return;
  }
  [self showToast:[message stringByAppendingString:@" Relaunch to apply."]
          buttons:@[ @[ @"Relaunch Now", @"relaunchToApplyExtensions:" ] ]
           target:self
           duration:15];
}

- (NSButton*)toastButtonTitled:(NSString*)title {  // tests
  for (NSView* v in _toast.subviews)
    if ([v isKindOfClass:NSButton.class] && [((NSButton*)v).title isEqualToString:title]) return (NSButton*)v;
  return nil;
}

- (IBAction)relaunchToApplyExtensions:(id)sender {
  ++_relaunchRequests;
  if (self.selfTestProfiles) return;  // tests count the request; they never quit or reopen anything
  [self hideToast];
  NSUInteger active = [DownloadManager shared].inProgressCount;
  if (active) {  // ask before quitting cancels them; once asked, the relaunch can't be called off halfway
    NSAlert* a = [NSAlert new];
    a.messageText = active == 1 ? @"A download is in progress." : [NSString stringWithFormat:@"%lu downloads are in progress.", (unsigned long)active];
    a.informativeText = @"Relaunching NotArc will cancel them.";
    [a addButtonWithTitle:@"Relaunch"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
  }
  [[Updater shared] relaunch];  // the updater's path: reopen once this copy has quit (tabs come back)
}

// Extensions only run in Chrome-style pages, so installing or importing one turns them on (for the next launch).
- (BOOL)turnOnChromePagesForExtensions {
  if (SettingBool(kSettingChromePages)) return NO;
  SettingSetBool(kSettingChromePages, YES);
  return YES;
}

- (NSString*)chromePagesNeededText:(NSString*)verb {
  return [NSString stringWithFormat:@"Extensions need Chrome-style pages, which are off (Settings > Advanced). %@ turns "
                                    @"them on; they start the next time NotArc opens.", verb];
}

- (IBAction)installExtensionFromPage:(NSMenuItem*)sender {
  __weak MainWindowController* weakSelf = self;
  [self installExtensionFromInput:sender.representedObject done:^(NSString* name, NSError* error) {
    [weakSelf reportExtensionInstall:name error:error];
  }];
}
- (IBAction)updateExtension:(NSMenuItem*)sender {  // same as a fresh install: the Web Store's current version
  __weak MainWindowController* weakSelf = self;
  [self installExtensionFromInput:((NotArcExtension*)sender.representedObject).extensionID done:^(NSString* name, NSError* error) {
    [weakSelf reportExtensionInstall:name error:error];
  }];
}

- (IBAction)installExtension:(id)sender {
  NSAlert* a = [NSAlert new];
  a.messageText = @"Install Extension";
  a.informativeText = @"Paste a Chrome Web Store link or an extension ID. NotArc downloads the extension from the "
                      @"Chrome Web Store and checks its signature before installing it.";
  NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 340, 24)];
  field.placeholderString = @"https://chromewebstore.google.com/detail/...";
  NSString* here = [self currentURL];
  if (ExtensionIDFromInput(here ?: @"")) field.stringValue = here;
  a.accessoryView = field;
  if (!SettingBool(kSettingChromePages))  // one sheet: the link, why, and the switch in the button
    a.informativeText = [a.informativeText stringByAppendingFormat:@"\n\n%@", [self chromePagesNeededText:@"Installing"]];
  [a addButtonWithTitle:SettingBool(kSettingChromePages) ? @"Install" : @"Turn On and Install"];
  [a addButtonWithTitle:@"Cancel"];
  a.window.initialFirstResponder = field;
  __weak MainWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    NSString* text = field.stringValue;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weakSelf installExtensionFromInput:text done:^(NSString* name, NSError* error) {
        [weakSelf reportExtensionInstall:name error:error];
      }];
    });
  }];
}

// File > Import Extensions from Arc. Copying any turns Chrome-style pages on, since that's where they run.
- (NSArray<ArcExtensionCopy*>*)importArcExtensionsTurningOnPagesInto:(NSString*)destination fromArcUserData:(NSString*)userData {
  NSArray<ArcExtensionCopy*>* copies = [self importArcExtensionsInto:destination fromArcUserData:userData];
  BOOL any = NO;
  for (ArcExtensionCopy* c in copies) if (!c.skippedMV2) any = YES;
  if (any) {
    [self turnOnChromePagesForExtensions];
    gExtensionsChanged = YES;
  }
  return copies;
}

- (IBAction)importArcExtensionsFromMenu:(id)sender {
  if (!SettingBool(kSettingChromePages)) {
    NSAlert* ask = [NSAlert new];
    ask.messageText = @"Import Extensions from Arc";
    ask.informativeText = [self chromePagesNeededText:@"Importing"];
    [ask addButtonWithTitle:@"Turn On and Import"];
    [ask addButtonWithTitle:@"Cancel"];
    __weak MainWindowController* weakSelf = self;
    [ask beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
      if (r == NSAlertFirstButtonReturn) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf importArcExtensionsNow]; });
    }];
    return;
  }
  [self importArcExtensionsNow];
}

- (void)importArcExtensionsNow {
  NSArray<ArcExtensionCopy*>* copies =
      [self importArcExtensionsTurningOnPagesInto:NotArcExtensionsDirectory(NO)
                                  fromArcUserData:[ArcDataDirectory() stringByAppendingPathComponent:@"User Data"]];
  NSMutableArray* names = [NSMutableArray array], *skipped = [NSMutableArray array];
  for (ArcExtensionCopy* c in copies) [(c.skippedMV2 ? skipped : names) addObject:c.name];
  NSAlert* a = [NSAlert new];
  a.messageText = names.count ? [NSString stringWithFormat:@"%lu extensions copied from Arc", (unsigned long)names.count]
                              : @"No extensions to copy";
  NSMutableString* info = [NSMutableString stringWithString:[names componentsJoinedByString:@", "]];
  if (skipped.count)
    [info appendFormat:@"\n\nNot supported by current Chromium: %@ (try uBlock Origin Lite).", [skipped componentsJoinedByString:@", "]];
  if (names.count) [info appendString:@"\n\nThey load when NotArc relaunches. Password managers need one sign-in."];
  a.informativeText = info;
  __weak MainWindowController* weakSelf = self;
  NSUInteger count = names.count;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse) {
    if (count) [weakSelf offerRelaunchForExtensions:count == 1 ? @"1 extension copied from Arc." :
                         [NSString stringWithFormat:@"%lu extensions copied from Arc.", (unsigned long)count]];
  }];
}

- (NSDictionary<NSString*, NSNumber*>*)importEverythingFromArcInto:(NSString*)extensionsDir userData:(NSString*)userData {
  NSUInteger history = [self importArcHistory];
  NSUInteger copied = 0, skipped = 0;
  for (ArcExtensionCopy* c in [self importArcExtensionsInto:extensionsDir fromArcUserData:userData])
    c.skippedMV2 ? ++skipped : ++copied;
  NSDictionary* pw = [self importArcPasswordsFromUserData:userData];
  NSMutableDictionary* out = [@{@"history" : @(history), @"extensions" : @(copied), @"skipped" : @(skipped),
                                @"passwords" : pw[@"passwords"] ?: @(-1), @"addresses" : pw[@"addresses"] ?: @0,
                                @"cards" : pw[@"cards"] ?: @0, @"existing" : pw[@"existing"] ?: @0,
                                @"locked" : pw[@"undecryptable"] ?: @0} mutableCopy];
  if (pw[@"error"]) out[@"passwordError"] = pw[@"error"];
  return out;
}

NSString* const kArcImportCompletedKey = @"arcImportCompleted";
NSString* const kArcImportDeclinedKey = @"arcImportNotNow";

// The words shown after Import Everything from Arc (tests read them too).
NSString* ArcImportSummary(NSDictionary* n, NSDictionary* cookies) {
  NSMutableArray* lines = [NSMutableArray arrayWithObject:@"Spaces, tabs, pinned tabs and Favorites: imported"];
  NSUInteger set = [cookies[@"set"] unsignedIntegerValue];
  if (cookies) {
    [lines addObject:set ? [NSString stringWithFormat:@"Logins (cookies): %lu copied into %@ %@", (unsigned long)set,
                                                     cookies[@"profiles"],
                                                     [cookies[@"profiles"] intValue] == 1 ? @"profile" : @"profiles"]
                         : @"Logins (cookies): none copied"];
  }
  [lines addObject:[NSString stringWithFormat:@"History: %@ visits added", n[@"history"]]];
  [lines addObject:[NSString stringWithFormat:@"Extensions: %@ copied%@", n[@"extensions"],
                                              [n[@"skipped"] intValue] ? [NSString stringWithFormat:@" (%@ too old for current Chromium)", n[@"skipped"]] : @""]];
  if (n[@"passwordError"]) {
    [lines addObject:[NSString stringWithFormat:@"Saved passwords, addresses and cards: not copied. %@", n[@"passwordError"]]];
  } else {
    NSString* already = [n[@"existing"] intValue] ? [NSString stringWithFormat:@" (%@ already here)", n[@"existing"]] : @"";
    [lines addObject:[NSString stringWithFormat:@"Saved passwords: %@ added%@", n[@"passwords"], already]];
    [lines addObject:[NSString stringWithFormat:@"Addresses and cards: %@ and %@ added", n[@"addresses"], n[@"cards"]]];
    if ([n[@"locked"] intValue])
      [lines addObject:[NSString stringWithFormat:@"%@ saved passwords or cards couldn't be unlocked with Arc's key", n[@"locked"]]];
  }
  for (NSString* e in cookies[@"errors"]) [lines addObject:e];
  if (set) [lines addObject:@"\nA few sites may still ask you to sign in again: some tie a sign-in to the browser it was made in."];
  return [lines componentsJoinedByString:@"\n"];
}

- (IBAction)importEverythingFromArcMenu:(id)sender {
  if (_importingFromArc) return;
  _importingFromArc = YES;
  NSString* userData = [ArcDataDirectory() stringByAppendingPathComponent:@"User Data"];
  __weak MainWindowController* weakSelf = self;
  // One Keychain read for passwords and cookies, off the main thread (macOS may ask once).
  dispatch_async(ArcImportQueue(), ^{
    NSError* keyError = nil;
    NSData* key = ArcImportKey(&keyError);
    dispatch_async(dispatch_get_main_queue(), ^{
      MainWindowController* me = weakSelf;
      if (!me) return;
      me.arcSafeStorageKeyOverride = key;
      me->_arcKeyFailed = key == nil;
      NSMutableDictionary* n = [[me importEverythingFromArcInto:NotArcExtensionsDirectory(NO) userData:userData] mutableCopy];
      me.arcSafeStorageKeyOverride = nil;
      me->_arcKeyFailed = NO;
      if (!key)
        n[@"passwordError"] = [NSString stringWithFormat:@"macOS didn't give NotArc Arc's key (%@).",
                                                         keyError.localizedDescription ?: @"no answer"];
      [me importArcCookiesFromUserData:userData key:key done:^(NSDictionary* cookies) {
        MainWindowController* me2 = weakSelf;
        if (!me2) return;
        me2->_importingFromArc = NO;
        [NSUserDefaults.standardUserDefaults setObject:[NSDate date] forKey:kArcImportCompletedKey];
        NSAlert* a = [NSAlert new];
        a.messageText = key ? @"Everything from Arc is here" : @"Some things couldn't come over from Arc";
        a.informativeText = ArcImportSummary(n, cookies);
        [a beginSheetModalForWindow:me2.window completionHandler:^(NSModalResponse r) {
          dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf offerDefaultBrowserIfFirstLaunch]; });
        }];
      }];
    });
  });
}

// Arc acceptance: one button the first time NotArc opens, then you keep working like you never moved.
// Arc's onboarding step: asked once, after the import question; macOS then shows its own confirmation.
- (void)offerDefaultBrowserIfFirstLaunch {
  NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
  if ([d boolForKey:@"defaultBrowserOffered"] || NotArcIsDefaultBrowser() || self.window.attachedSheet) return;
  [d setBool:YES forKey:@"defaultBrowserOffered"];
  NSAlert* a = [NSAlert new];
  a.messageText = @"Make NotArc your default browser?";
  a.informativeText = @"Links you click in other apps will open here, routed by your Air Traffic Control rules. "
                      @"You can change this later in Settings.";
  [a addButtonWithTitle:@"Make Default"];
  [a addButtonWithTitle:@"Not Now"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSAlertFirstButtonReturn) MakeNotArcDefaultBrowser(nil);
  }];
}

// Shown at launch while Arc's data is there and its import hasn't been run or turned down yet. Old builds set
// "arcImportOffered" without the person ever importing (test and dev launches did too), so that key is ignored.
BOOL ArcImportOfferDue(NSDictionary* prefs, BOOL arcDataExists) {
  return arcDataExists && !prefs[kArcImportCompletedKey] && ![prefs[kArcImportDeclinedKey] boolValue];
}

- (void)offerArcImportIfFirstLaunch {
  NSUserDefaults* d = NSUserDefaults.standardUserDefaults;
  NSMutableDictionary* prefs = [NSMutableDictionary dictionary];
  prefs[kArcImportCompletedKey] = [d objectForKey:kArcImportCompletedKey];  // nil leaves it out
  prefs[kArcImportDeclinedKey] = @([d boolForKey:kArcImportDeclinedKey]);
  BOOL arc = [NSFileManager.defaultManager fileExistsAtPath:[ArcDataDirectory() stringByAppendingPathComponent:@"User Data"]];
  if (!ArcImportOfferDue(prefs, arc)) {
    [self offerDefaultBrowserIfFirstLaunch];
    return;
  }
  if (self.window.attachedSheet || !self.window.visible) {  // another sheet first, or the window isn't up yet
    __weak MainWindowController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      [weakSelf offerArcImportIfFirstLaunch];
    });
    return;
  }
  NSAlert* a = [NSAlert new];
  a.messageText = @"Bring everything over from Arc?";
  a.informativeText = @"Your Spaces and tabs are already here. This adds your logins, so you stay signed in to your "
                      @"sites, plus your history, extensions, saved passwords, addresses and cards. macOS asks once "
                      @"to let NotArc read Arc's key. Arc itself isn't changed. You can do this later from File > "
                      @"Import Everything from Arc, or in Settings > Profiles.";
  [a addButtonWithTitle:@"Import Everything"];
  [a addButtonWithTitle:@"Not Now"];
  __weak MainWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSAlertFirstButtonReturn) {
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf importEverythingFromArcMenu:nil]; });
    } else {
      [NSUserDefaults.standardUserDefaults setBool:YES forKey:kArcImportDeclinedKey];
      dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf offerDefaultBrowserIfFirstLaunch]; });
    }
  }];
}

- (IBAction)importArcHistoryFromMenu:(id)sender {
  NSUInteger n = [self importArcHistory];
  NSAlert* a = [NSAlert new];
  a.messageText = n ? @"History imported from Arc" : @"No new history to import";
  a.informativeText = n ? [NSString stringWithFormat:@"%lu visits added. Open History with Cmd+Y.", (unsigned long)n]
                        : @"Everything from Arc is already here.";
  [a beginSheetModalForWindow:self.window completionHandler:nil];
}
- (IBAction)addEaselText:(id)sender {
  if (!_easelItem) { NSBeep(); return; }
  EaselObject* o = [_easelView addText:@"" at:NSMakePoint(-1, -1)];
  (void)o;
  for (NSView* v in _easelView.subviews)
    for (NSView* sub in v.subviews)
      if ([sub isKindOfClass:NSTextField.class] && [(NSTextField*)sub stringValue].length == 0) [self.window makeFirstResponder:sub];
}
// The most recently used easel in this Space, for captures (Arc adds captures to an easel).
- (ArcItem*)recentEasel {
  ArcItem* best = nil;
  NSMutableArray* stack = [NSMutableArray arrayWithObjects:_space.pinned ?: [ArcItem new], _space.unpinned ?: [ArcItem new], nil];
  while (stack.count) {
    ArcItem* it = stack.lastObject;
    [stack removeLastObject];
    if (it.easelID && (!best || [it.lastActiveAt compare:best.lastActiveAt ?: NSDate.distantPast] == NSOrderedDescending)) best = it;
    if (it.children) [stack addObjectsFromArray:it.children];
  }
  return best;
}
// Page capture (Arc: Capture, Cmd+Shift+2): the visible page as a PNG, added to the most recent easel.
- (void)capturePage:(ArcItem*)page done:(void (^)(NSData* png))done {
  auto it = _browsers.find(page.browserId);
  if (it == _browsers.end()) { if (done) done(nil); return; }
  CefRefPtr<CefBrowser> b = it->second;
  if (!_devtoolsResults) _devtoolsResults = new DevToolsResults();
  if (!_devtoolsRegs.count(page.browserId)) _devtoolsRegs[page.browserId] = b->GetHost()->AddDevToolsMessageObserver(_devtoolsResults);
  int mid = 100000 + (++_devtoolsNextId);
  void (^cb)(NSData*) = [done copy];
  _devtoolsResults->pending[mid] = [cb](bool ok, const std::string& json) {
    NSData* png = nil;
    if (ok) {
      NSData* d = [NSData dataWithBytes:json.data() length:json.size()];
      NSDictionary* r = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
      if ([r isKindOfClass:NSDictionary.class] && [r[@"data"] isKindOfClass:NSString.class])
        png = [[NSData alloc] initWithBase64EncodedString:r[@"data"] options:0];
    }
    if (cb) cb(png);
  };
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  params->SetString("format", "png");
  b->GetHost()->ExecuteDevToolsMethod(mid, "Page.captureScreenshot", params);
}
static CefRefPtr<CefDictionaryValue> CefDict(NSDictionary* d) {
  CefRefPtr<CefDictionaryValue> v = CefDictionaryValue::Create();
  for (NSString* k in d) {
    id o = d[k];
    if ([o isKindOfClass:NSDictionary.class]) v->SetDictionary(k.UTF8String, CefDict(o));
    else if ([o isKindOfClass:NSString.class]) v->SetString(k.UTF8String, [o UTF8String]);
    else if (o == (id)kCFBooleanTrue || o == (id)kCFBooleanFalse) v->SetBool(k.UTF8String, [o boolValue]);
    else if ([o isKindOfClass:NSNumber.class]) v->SetDouble(k.UTF8String, [o doubleValue]);
  }
  return v;
}

// Any DevTools method on a tab; the result object (or nil on failure) comes back on the main thread.
- (void)devtools:(ArcItem*)page method:(NSString*)method params:(NSDictionary*)params done:(void (^)(NSDictionary*))done {
  auto it = _browsers.find(page.browserId);
  if (it == _browsers.end()) { if (done) done(nil); return; }
  CefRefPtr<CefBrowser> b = it->second;
  if (!_devtoolsResults) _devtoolsResults = new DevToolsResults();
  if (!_devtoolsRegs.count(page.browserId)) _devtoolsRegs[page.browserId] = b->GetHost()->AddDevToolsMessageObserver(_devtoolsResults);
  int mid = 100000 + (++_devtoolsNextId);
  void (^cb)(NSDictionary*) = [done copy];
  _devtoolsResults->pending[mid] = [cb](bool ok, const std::string& json) {
    NSDictionary* r = nil;
    if (ok) {
      id o = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:json.data() length:json.size()] options:0 error:nil];
      if ([o isKindOfClass:NSDictionary.class]) r = o;
    }
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(r); });
  };
  b->GetHost()->ExecuteDevToolsMethod(mid, method.UTF8String, params.count ? CefDict(params) : nullptr);
}

static NSData* PNGFrom(NSDictionary* r) {
  return [r[@"data"] isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:r[@"data"] options:0] : nil;
}

static NSBitmapImageRep* RepFrom(NSData* png) { return png ? [NSBitmapImageRep imageRepWithData:png] : nil; }

// Crop a capture of the visible page to a rect given in page-view points (top-left origin).
static NSData* CropPNG(NSData* png, NSRect r, NSSize viewSize) {
  NSBitmapImageRep* rep = RepFrom(png);
  if (!rep || viewSize.width <= 0) return nil;
  CGFloat s = rep.pixelsWide / viewSize.width;
  CGRect px = CGRectIntegral(CGRectMake(r.origin.x * s, r.origin.y * s, r.size.width * s, r.size.height * s));
  px = CGRectIntersection(px, CGRectMake(0, 0, rep.pixelsWide, rep.pixelsHigh));
  if (CGRectIsEmpty(px)) return nil;
  CGImageRef c = CGImageCreateWithImageInRect(rep.CGImage, px);
  NSBitmapImageRep* out = [[NSBitmapImageRep alloc] initWithCGImage:c];
  CGImageRelease(c);
  return [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

// Portrait mode: the capture on a padded background in the Space's colour, rounded and with a soft shadow.
static NSData* PortraitPNG(NSData* png, NSColor* bg) {
  NSBitmapImageRep* rep = RepFrom(png);
  if (!rep) return nil;
  CGFloat w = rep.pixelsWide, h = rep.pixelsHigh, pad = MAX(w, h) * 0.08, radius = MIN(w, h) * 0.02;
  NSBitmapImageRep* out = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)(w + 2 * pad)
      pixelsHigh:(NSInteger)(h + 2 * pad) bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
      colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
  [NSGraphicsContext saveGraphicsState];
  NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:out];
  NSRect all = NSMakeRect(0, 0, w + 2 * pad, h + 2 * pad);
  NSGradient* g = [[NSGradient alloc] initWithStartingColor:[bg blendedColorWithFraction:0.25 ofColor:NSColor.whiteColor]
                                                endingColor:[bg blendedColorWithFraction:0.2 ofColor:NSColor.blackColor]];
  [g drawInRect:all angle:-45];
  NSRect card = NSMakeRect(pad, pad, w, h);
  NSShadow* sh = [NSShadow new];
  sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
  sh.shadowBlurRadius = pad * 0.35;
  sh.shadowOffset = NSMakeSize(0, -pad * 0.08);
  [NSGraphicsContext saveGraphicsState];
  [sh set];
  NSBezierPath* path = [NSBezierPath bezierPathWithRoundedRect:card xRadius:radius yRadius:radius];
  [NSColor.whiteColor setFill];
  [path fill];
  [NSGraphicsContext restoreGraphicsState];
  [path addClip];
  [rep drawInRect:card];
  [NSGraphicsContext restoreGraphicsState];
  return [out representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

- (NSColor*)captureBackgroundColor {
  NSString* hex = _space.themeColors.firstObject;
  if (hex.length >= 7) {
    unsigned v = 0;
    [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&v];
    return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
  }
  return [NSColor colorWithSRGBRed:0x60 / 255.0 green:0x4f / 255.0 blue:0xd6 / 255.0 alpha:1];
}

// mode: "visible", "full", "portrait" or "area" (rect in page points, top-left origin).
- (void)capture:(NSString*)mode rect:(NSRect)rect done:(void (^)(NSData* png))done {
  ArcItem* page = _shown;
  if (!page || page.noteID || page.easelID || !page.browserId) { if (done) done(nil); return; }
  NSSize viewSize = [self webViewForItem:page].bounds.size;
  NSColor* bg = [self captureBackgroundColor];
  if ([mode isEqualToString:@"full"]) {
    __weak MainWindowController* weakSelf = self;
    [self devtools:page method:@"Page.getLayoutMetrics" params:nil done:^(NSDictionary* m) {
      NSDictionary* size = m[@"cssContentSize"] ?: m[@"contentSize"];
      double w = [size[@"width"] doubleValue], h = MIN([size[@"height"] doubleValue], 16384.0);
      if (!weakSelf || w <= 0 || h <= 0) { if (done) done(nil); return; }
      [weakSelf devtools:page method:@"Page.captureScreenshot"
                  params:@{@"format" : @"png", @"captureBeyondViewport" : @YES,
                           @"clip" : @{@"x" : @0, @"y" : @0, @"width" : @(w), @"height" : @(h), @"scale" : @1}}
                    done:^(NSDictionary* r) { if (done) done(PNGFrom(r)); }];
    }];
    return;
  }
  [self devtools:page method:@"Page.captureScreenshot" params:@{@"format" : @"png"} done:^(NSDictionary* r) {
    NSData* png = PNGFrom(r);
    if ([mode isEqualToString:@"area"]) png = CropPNG(png, rect, viewSize);
    else if ([mode isEqualToString:@"portrait"]) png = PortraitPNG(png, bg);
    if (done) done(png);
  }];
}

- (NSString*)captureDirectory {
  if (_captureDirectory) return _captureDirectory;
  return [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES).firstObject ?: NSHomeDirectory()
      stringByAppendingPathComponent:@""];
}

// Copies the capture, saves it as a PNG, and offers Add to Easel (Arc's capture actions).
- (NSString*)deliverCapture:(NSData*)png {
  if (!png) { NSBeep(); return nil; }
  _lastCapture = png;
  _lastCaptureLink = [self itemCurrentURL:_shown];
  NSPasteboard* pb = _captureDirectory ? [NSPasteboard pasteboardWithName:@"io.github.donnadieu.notarc.selftest"]
                                       : NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setData:png forType:NSPasteboardTypePNG];
  NSDateFormatter* f = [NSDateFormatter new];
  f.dateFormat = @"yyyy-MM-dd 'at' HH.mm.ss";
  NSString* dir = self.captureDirectory;
  NSString* base = [NSString stringWithFormat:@"NotArc Capture %@", [f stringFromDate:NSDate.date]];
  NSString* path = [dir stringByAppendingPathComponent:[base stringByAppendingPathExtension:@"png"]];
  for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:path]; n++)
    path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.png", base, n]];
  if (![png writeToFile:path atomically:YES]) path = nil;
  PlaySoundEffect(NotArcSoundCapture);  // Arc played a shutter sound on capture
  if (!_captureDirectory)
    [self showToast:path ? @"Capture copied and saved to Downloads" : @"Capture copied" action:@"Add to Easel"
           selector:@selector(addLastCaptureToEasel:)];
  return path;
}

- (IBAction)addLastCaptureToEasel:(id)sender {
  if (!_lastCapture) return;
  ArcItem* easel = [self recentEasel];
  if (easel) [self showItem:easel]; else [self createEaselWithID:nil];
  [_easelView addImagePNG:_lastCapture link:_lastCaptureLink];
}

- (void)captureMode:(NSString*)mode {
  __weak MainWindowController* weakSelf = self;
  [self capture:mode rect:NSZeroRect done:^(NSData* png) { [weakSelf deliverCapture:png]; }];
}
- (IBAction)captureVisiblePage:(id)sender { [self captureMode:@"visible"]; }
- (IBAction)captureFullPage:(id)sender { [self captureMode:@"full"]; }
- (IBAction)capturePortrait:(id)sender { [self captureMode:@"portrait"]; }

// Capture Area: drag a rectangle over the page; Esc or a click without dragging cancels.
- (IBAction)captureArea:(id)sender {
  NSView* web = [self webViewForItem:_shown];
  if (!web || _shown.noteID || _shown.easelID) { NSBeep(); return; }
  [_captureOverlay removeFromSuperview];
  CaptureAreaView* o = [[CaptureAreaView alloc] initWithFrame:_content.frame];
  __weak MainWindowController* weakSelf = self;
  __weak CaptureAreaView* weakO = o;
  o.finished = ^(NSRect r) {
    MainWindowController* me = weakSelf;
    [weakO removeFromSuperview];
    if (!me || NSIsEmptyRect(r)) return;
    // Let the overlay leave the screen before capturing; the page renders itself, so it never shows anyway.
    [me capture:@"area" rect:r done:^(NSData* png) { [weakSelf deliverCapture:png]; }];
  };
  [_content.superview addSubview:o positioned:NSWindowAbove relativeTo:nil];
  _captureOverlay = o;
  [self.window makeFirstResponder:o];
}

- (IBAction)captureToEasel:(id)sender {
  ArcItem* page = _shown;
  if (!page || page.noteID || page.easelID) { NSBeep(); return; }
  NSString* link = [self itemCurrentURL:page];
  __weak MainWindowController* weakSelf = self;
  [self capturePage:page done:^(NSData* png) {
    MainWindowController* me = weakSelf;
    if (!me || !png) { NSBeep(); return; }
    ArcItem* easel = [me recentEasel];
    if (easel) [me showItem:easel]; else easel = [me createEaselWithID:nil];
    [me->_easelView addImagePNG:png link:link];
    if (!me.selfTestProfiles) [me showToast:@"Captured to Easel" action:nil selector:nil];
  }];
}
- (EaselObject*)addPNGToRecentEasel:(NSData*)png link:(NSString*)link {
  if (!png) { NSBeep(); return nil; }
  ArcItem* easel = [self recentEasel];
  if (easel) [self showItem:easel]; else [self createEaselWithID:nil];
  EaselObject* o = [_easelView addImagePNG:png link:link];
  if (o && !self.selfTestProfiles) [self showToast:@"Captured to Easel" action:nil selector:nil];
  return o;
}
- (BOOL)canCaptureShownPage { return _shown && !_shown.noteID && !_shown.easelID && _shown.browserId && [self webViewForItem:_shown]; }

// Drag a rectangle over the page (the Capture Area overlay), then do something with it.
- (void)pickAreaThen:(void (^)(NSRect r))then {
  if (![self canCaptureShownPage]) { NSBeep(); return; }
  [_captureOverlay removeFromSuperview];
  CaptureAreaView* o = [[CaptureAreaView alloc] initWithFrame:_content.frame];
  __weak CaptureAreaView* weakO = o;
  void (^next)(NSRect) = [then copy];
  o.finished = ^(NSRect r) {
    [weakO removeFromSuperview];
    if (!NSIsEmptyRect(r)) next(r);
  };
  [_content.superview addSubview:o positioned:NSWindowAbove relativeTo:nil];
  _captureOverlay = o;
  [self.window makeFirstResponder:o];
}
// File > Capture Area to Easel / Capture Full Page to Easel: the Capture (#48) pictures, straight into an easel.
- (IBAction)captureAreaToEasel:(id)sender {
  __weak MainWindowController* weakSelf = self;
  [self pickAreaThen:^(NSRect r) { [weakSelf captureToEaselMode:@"area" rect:r done:nil]; }];
}
- (IBAction)captureFullPageToEasel:(id)sender { [self captureToEaselMode:@"full" rect:NSZeroRect done:nil]; }
- (void)captureToEaselMode:(NSString*)mode rect:(NSRect)r done:(void (^)(EaselObject*))done {
  if (![self canCaptureShownPage]) { NSBeep(); if (done) done(nil); return; }
  NSString* link = [self itemCurrentURL:_shown];
  __weak MainWindowController* weakSelf = self;
  [self capture:mode rect:r done:^(NSData* png) {
    EaselObject* o = [weakSelf addPNGToRecentEasel:png link:link];
    if (done) done(o);
  }];
}
// File > Add Live Clip to Easel: drag over part of a page; the clip keeps the address and region and refreshes later.
- (IBAction)liveClipToEasel:(id)sender {
  __weak MainWindowController* weakSelf = self;
  [self pickAreaThen:^(NSRect r) { [weakSelf liveClipArea:r done:nil]; }];
}
- (void)liveClipArea:(NSRect)r done:(void (^)(EaselObject*))done {
  ArcItem* page = _shown;
  NSString* link = [self itemCurrentURL:page];
  NSView* web = [self webViewForItem:page];
  if (![self canCaptureShownPage] || !link.length || !web) { NSBeep(); if (done) done(nil); return; }
  NSSize viewport = web.bounds.size;
  NSRect region = NSIntersectionRect(r, NSMakeRect(0, 0, viewport.width, viewport.height));
  __weak MainWindowController* weakSelf = self;
  [self capture:@"area" rect:region done:^(NSData* png) {
    MainWindowController* me = weakSelf;
    if (!me || !png) { NSBeep(); if (done) done(nil); return; }
    // Where the page was scrolled to, so a refresh shows the same part of it.
    [me devtools:page method:@"Page.getLayoutMetrics" params:nil done:^(NSDictionary* m) {
      MainWindowController* me2 = weakSelf;
      if (!me2) { if (done) done(nil); return; }
      NSDictionary* vv = m[@"cssVisualViewport"] ?: m[@"visualViewport"];
      NSPoint scroll = NSMakePoint(MAX(0, [vv[@"pageX"] doubleValue]), MAX(0, [vv[@"pageY"] doubleValue]));
      ArcItem* easel = [me2 recentEasel];
      if (easel) [me2 showItem:easel]; else [me2 createEaselWithID:nil];
      EaselObject* o = [me2->_easelView addClipPNG:png link:link region:region viewport:viewport scroll:scroll];
      if (!o) NSBeep();
      else if (!me2.selfTestProfiles) [me2 showToast:@"Live clip added to Easel" action:nil selector:nil];
      if (done) done(o);
    }];
  }];
}

// Tests.
- (EaselView*)easelView { return _easelScroll.hidden ? nil : _easelView; }
- (void)captureShownPageToEasel:(void (^)(BOOL))done {
  ArcItem* page = _shown;
  NSString* link = [self itemCurrentURL:page];
  [self capturePage:page done:^(NSData* png) {
    ArcItem* easel = [self recentEasel];
    if (easel) [self showItem:easel]; else [self createEaselWithID:nil];
    BOOL ok = [self->_easelView addImagePNG:png link:link] != nil;
    if (done) done(ok);
  }];
}

// MARK: Notes (Arc: NoteDocument). Rich text in the page card (or a split pane), saved as RTF next to the sidebar file.
- (NSString*)notesDirectory {
  NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"];
  return [support stringByAppendingPathComponent:self.selfTestProfiles ? @"SelfTestNotes" : @"Notes"];
}
- (NSString*)notePathFor:(ArcItem*)note { return [[self notesDirectory] stringByAppendingPathComponent:[note.noteID stringByAppendingString:@".rtf"]]; }
- (NSAttributedString*)loadNote:(ArcItem*)note { return NoteLoadRTF([self notePathFor:note]); }
- (void)saveNoteNow {
  for (NoteEditorView* e in _noteEditors.allValues) [e save];
}
// The editor of the focused pane when it's a note.
- (NoteEditorView*)focusedNoteEditor { return _shown.noteID ? _noteEditors[_shown.itemID] : nil; }
- (NoteEditorView*)noteEditorForItem:(ArcItem*)note {
  NoteEditorView* e = note.itemID ? _noteEditors[note.itemID] : nil;
  return e.superview && !e.hidden ? e : nil;
}
// Every note among the visible panes gets its own editor in its pane's frame; notes that left the screen are saved.
- (void)layoutNoteEditorsForPanes:(NSArray<ArcItem*>*)panes frames:(NSArray<NSValue*>*)frames {
  if (!_noteEditors) _noteEditors = [NSMutableDictionary dictionary];
  NoteEditorView* focusedBefore = [self focusedNoteEditor];
  NSMutableSet<NSString*>* onScreen = [NSMutableSet set];
  for (NSUInteger i = 0; i < panes.count && i < frames.count; ++i) {
    ArcItem* note = panes[i];
    if (!note.noteID || !note.itemID) continue;
    NoteEditorView* e = _noteEditors[note.itemID];
    if (!e) {
      e = [[NoteEditorView alloc] initWithFrame:frames[i].rectValue];
      e.delegate = self;
      e.item = note;
      e.path = [self notePathFor:note];
      [e load];
      _noteEditors[note.itemID] = e;
    }
    e.frame = frames[i].rectValue;
    e.autoresizingMask = panes.count == 1 ? (NSViewWidthSizable | NSViewHeightSizable) : NSViewNotSizable;
    e.hidden = NO;
    [_content addSubview:e positioned:NSWindowAbove relativeTo:nil];
    [onScreen addObject:note.itemID];
  }
  for (NSString* key in _noteEditors.allKeys) {
    if ([onScreen containsObject:key]) continue;
    NoteEditorView* e = _noteEditors[key];
    [e save];
    [e removeFromSuperview];
    [_noteEditors removeObjectForKey:key];
  }
  NoteEditorView* focused = [self focusedNoteEditor];
  if (focused && focused != focusedBefore && !self.selfTestProfiles) [self.window makeFirstResponder:focused.textView];
}
- (void)noteEditorDidChange:(NoteEditorView*)editor {
  ArcItem* note = editor.item;
  // The first line is the note's title in the sidebar, as in Arc.
  NSString* t = editor.title;
  if (![t isEqualToString:note.liveTitle] && !(t == nil && note.liveTitle == nil)) {
    note.liveTitle = t;
    ArcItem* parent = [self parentOfItem:note];
    [_outline reloadItem:parent.isSplit ? parent : note];
    [self scheduleSave];
  }
}
// Clicking into a note pane of a split focuses that pane, like clicking into a page.
- (void)noteEditorDidFocus:(NoteEditorView*)editor {
  ArcItem* item = editor.item;
  if (!item || item == _shown || ![_splitItems containsObject:item]) return;
  _shown.lastActiveAt = [NSDate date];
  _shown = item;
  item.lastActiveAt = [NSDate date];
  [self syncSplitState];
  [self selectSidebarRowFor:item];
  [self updateToolbarAddress];
}
- (void)noteEditor:(NoteEditorView*)editor openLink:(NSString*)url { [self openInNewTab:url]; }

- (ArcItem*)makeNoteItemWithID:(NSString*)noteID {
  ArcItem* n = [ArcItem new];
  n.itemID = NSUUID.UUID.UUIDString;
  n.noteID = noteID ?: NSUUID.UUID.UUIDString;
  n.url = [@"notarc://note/" stringByAppendingString:n.noteID];
  n.children = [NSMutableArray array];
  n.lastActiveAt = [NSDate date];
  if (noteID) {  // reopened from the archive: title from its first line
    NSString* s = [self loadNote:n].string;
    NSString* first = [[s componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] firstObject];
    if (first.length) n.liveTitle = first;
  }
  return n;
}
- (ArcItem*)createNoteWithID:(NSString*)noteID {
  if (!_space) return nil;
  ArcItem* n = [self makeNoteItemWithID:noteID];
  [_space.unpinned.children insertObject:n atIndex:0];  // Arc puts new notes at the top of Today
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  [self showItem:n];
  return n;
}
- (IBAction)newNote:(id)sender { [self createNoteWithID:nil]; }
// Arc: newNoteInSplitView. A new note opens as a pane beside the focused page (or note).
- (IBAction)newNoteInSplitView:(id)sender {
  if (!_space) return;
  if (!_shown) { [self createNoteWithID:nil]; return; }
  ArcItem* n = [self makeNoteItemWithID:nil];
  if (![self placeInSplit:n horizontal:NO before:NO]) [self createNoteWithID:nil];
}

// Markdown export (File > Export Note as Markdown..., Copy Note as Markdown).
// The note to export: the focused pane if it's a note, else a note beside it in the split.
- (ArcItem*)noteForExport {
  if (_shown.noteID) return _shown;
  for (ArcItem* pane in [self visiblePanes])
    if (pane.noteID) return pane;
  return nil;
}
- (NSString*)markdownForNote:(ArcItem*)note {
  NoteEditorView* e = note.itemID ? _noteEditors[note.itemID] : nil;
  return e ? e.markdown : NoteMarkdown([self loadNote:note]);
}
- (BOOL)exportNote:(ArcItem*)note toPath:(NSString*)path {
  NSString* md = note ? [self markdownForNote:note] : nil;
  return md && [md writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
- (IBAction)exportNoteAsMarkdown:(id)sender {
  ArcItem* note = [self noteForExport];
  if (!note) { NSBeep(); return; }
  NSSavePanel* panel = [NSSavePanel savePanel];
  UTType* md = [UTType typeWithFilenameExtension:@"md"];
  if (md) panel.allowedContentTypes = @[ md ];
  NSString* name = [[note.displayTitle ?: @"Note" componentsSeparatedByCharactersInSet:
                        [NSCharacterSet characterSetWithCharactersInString:@"/:\\"]] componentsJoinedByString:@"-"];
  panel.nameFieldStringValue = [(name.length ? name : @"Note") stringByAppendingPathExtension:@"md"];
  [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSModalResponseOK && ![self exportNote:note toPath:panel.URL.path]) NSBeep();
  }];
}
- (IBAction)copyNoteAsMarkdown:(id)sender {
  ArcItem* note = [self noteForExport];
  if (!note) { NSBeep(); return; }
  NSString* md = [self markdownForNote:note];
  NSPasteboard* pb = [self copyPasteboard];
  [pb clearContents];
  [pb setString:md forType:NSPasteboardTypeString];
  [pb setString:md forType:@"net.daringfireball.markdown"];
}

// Tests.
- (void)typeInNote:(NSString*)text {
  NSTextView* tv = [self focusedNoteEditor].textView;
  if (!tv) return;
  [tv setSelectedRange:NSMakeRange(tv.string.length, 0)];
  [tv insertText:text replacementRange:tv.selectedRange];
}
- (NSString*)noteEditorText { return [self focusedNoteEditor].textView.string; }
- (NSString*)savedNoteText:(ArcItem*)note { [self saveNoteNow]; return [self loadNote:note].string; }
- (NSAttributedString*)savedNote:(ArcItem*)note { [self saveNoteNow]; return [self loadNote:note]; }
- (BOOL)noteRangeIsBold:(ArcItem*)note range:(NSRange)r {  // tests: reads the saved file
  NSAttributedString* a = [self loadNote:note];
  if (NSMaxRange(r) > a.length) return NO;
  NSFont* f = [a attribute:NSFontAttributeName atIndex:r.location effectiveRange:nil];
  return (f.fontDescriptor.symbolicTraits & NSFontDescriptorTraitBold) != 0;
}
- (void)makeNoteRangeBold:(NSRange)r {  // tests: what Format > Bold does to a selection
  NSTextView* tv = [self focusedNoteEditor].textView;
  if (NSMaxRange(r) > tv.textStorage.length) return;
  NSFont* f = [tv.textStorage attribute:NSFontAttributeName atIndex:r.location effectiveRange:nil] ?: [NSFont systemFontOfSize:15];
  NSFont* b = [[NSFontManager sharedFontManager] convertFont:f toHaveTrait:NSBoldFontMask];
  [tv shouldChangeTextInRange:r replacementString:nil];
  [tv.textStorage addAttribute:NSFontAttributeName value:b range:r];
  [tv didChangeText];
}

- (NSArray<NSValue*>*)paneFrames {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcItem* pane in [self visiblePanes]) {
    auto it = _browsers.find(pane.browserId);
    if (it == _browsers.end()) continue;
    [out addObject:[NSValue valueWithRect:[self pageViewForBrowser:it->second].frame]];
  }
  return out;
}

- (void)windowDidResize:(NSNotification*)note {
  [self positionWindowButtons];
  if (_splitItems.count > 1) [self layoutPanes];
}

// Wraps the tab in a split item at its place in the sidebar (Favorites can't hold splits).
- (ArcItem*)ensureSplitGroupFor:(ArcItem*)item {
  ArcItem* parent = [self parentOfItem:item];
  if (parent.isSplit) return parent;
  if (!parent || parent == _space.favorites) return nil;
  ArcItem* group = [ArcItem new];
  group.itemID = NSUUID.UUID.UUIDString;
  group.isSplit = YES;
  group.children = [NSMutableArray arrayWithObject:item];
  parent.children[[parent.children indexOfObject:item]] = group;
  return group;
}

// Takes a tab out of its split. keep: put it back in the sidebar right after the split (Arc's
// "Separate from Split View"); otherwise the caller removes it. A split left with one tab dissolves.
- (void)detachFromSplit:(ArcItem*)item keep:(BOOL)keep {
  ArcItem* group = [self parentOfItem:item];
  if (!group.isSplit) return;
  ArcItem* holder = [self parentOfItem:group];
  NSUInteger at = [holder.children indexOfObject:group];
  [group.children removeObject:item];
  group.splitFractions = nil;
  if (keep && holder) [holder.children insertObject:item atIndex:at + 1];
  if (group.children.count < 2 && holder) {
    if (group.children.count == 1) holder.children[at] = group.children.firstObject;
    else [holder.children removeObjectAtIndex:at];
  }
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self syncSplitState];
  [self scheduleSave];
}

- (void)paneFocused:(int)browserId {
  ArcItem* item = [self itemForBrowser:browserId];
  if (!item || item == _shown || ![_splitItems containsObject:item]) return;
  _shown.lastActiveAt = [NSDate date];
  _shown = item;
  item.lastActiveAt = [NSDate date];
  [self syncSplitState];
  [self selectSidebarRowFor:item];
}

- (void)beginSplit:(BOOL)horizontal {
  if (!_shown || _splitItems.count >= 4) {
    NSBeep();
    return;
  }
  _commandOpensLittle = NO;
  _splitBefore = NO;
  _pendingSplitHorizontal = horizontal;
  _commandOpensSplit = YES;
  [self showCommandBarForNewTab:YES];
}

- (IBAction)addVerticalSplit:(id)sender { [self beginSplit:NO]; }
- (IBAction)addHorizontalSplit:(id)sender { [self beginSplit:YES]; }

// The new pane is a normal Today tab placed next to the focused pane, like Arc.
- (void)openInSplit:(NSString*)input horizontal:(BOOL)horizontal {
  [self openInSplit:input horizontal:horizontal before:NO];
}

// The new pane is a normal Today tab placed beside the focused pane (after it for right/bottom, before it
// for left/top). The direction sets the layout of the whole split.
- (void)openInSplit:(NSString*)input horizontal:(BOOL)horizontal before:(BOOL)before {
  if ([input hasPrefix:@"notarc://note/"]) {  // a note: the existing one moves into the split, else it's reopened
    NSString* nid = [input substringFromIndex:@"notarc://note/".length];
    if (!nid.length || [nid rangeOfString:@"/"].location != NSNotFound) return;
    ArcItem* note = [self tabWithURLPrefix:input];
    [self placeInSplit:note ?: [self makeNoteItemWithID:nid] horizontal:horizontal before:before];
    return;
  }
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space || !_shown) return;
  ArcItem* tab = [ArcItem new];
  tab.itemID = NSUUID.UUID.UUIDString;
  tab.url = url;
  tab.children = [NSMutableArray array];
  [self placeInSplit:tab horizontal:horizontal before:before];
}

// Puts a pane beside the focused one: a new tab or note, or an existing item that moves out of its old place.
- (BOOL)placeInSplit:(ArcItem*)item horizontal:(BOOL)horizontal before:(BOOL)before {
  if (!item || !_space || !_shown || item == _shown) return NO;
  [self syncSplitState];
  if ([_splitItems containsObject:item]) {
    [self showItem:item];
    return YES;
  }
  if (_splitItems.count >= 4) return NO;
  ArcItem* group = [self ensureSplitGroupFor:_shown];
  if (!group) {
    NSBeep();
    return NO;
  }
  ArcItem* old = [self parentOfItem:item];
  if (old.isSplit) [self detachFromSplit:item keep:NO];
  else if (old) [old.children removeObject:item];
  group.splitHorizontal = horizontal;
  group.splitFractions = nil;
  NSUInteger at = [group.children indexOfObject:_shown] + (before ? 0 : 1);
  [group.children insertObject:item atIndex:at];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  [self showItem:item];
  return YES;
}

- (NSUInteger)indexOfShownInSplit { return [_splitItems indexOfObject:_shown]; }

// Drag to split (#37): a tab dragged from the sidebar onto the page joins the shown page in a split, on the side it was
// dropped (0 right, 1 left, 2 bottom, 3 top). The tab moves into the split (Arc combines them); a Favorite stays a
// Favorite and its page opens in the new pane instead.
- (BOOL)canDropOnPage:(id<NSDraggingInfo>)info {
  ArcItem* item = [self draggedItem:info];
  return item && _shown && item != _shown && item.url.length && !item.isFolder && !item.isSplit && !_shown.noteID &&
         !_shown.easelID && ![_splitItems containsObject:item] && _splitItems.count < 4;
}
- (BOOL)dropOnPage:(id<NSDraggingInfo>)info side:(NSInteger)side {
  if (![self canDropOnPage:info]) return NO;
  return [self splitShownWithItem:[self draggedItem:info] side:side];
}
- (BOOL)splitShownWithItem:(ArcItem*)item side:(NSInteger)side {
  if (!item || !_shown || item == _shown || !item.url.length || item.isFolder || item.isSplit) return NO;
  [self syncSplitState];
  if ([_splitItems containsObject:item] || _splitItems.count >= 4) return NO;
  BOOL horizontal = side >= 2, before = side == 1 || side == 3;
  if ([self sectionContaining:item] == _space.favorites) {
    [self openInSplit:[self itemCurrentURL:item] ?: item.url horizontal:horizontal before:before];
    return YES;
  }
  ArcItem* group = [self ensureSplitGroupFor:_shown];
  if (!group) return NO;
  if ([self parentOfItem:item].isSplit) [self detachFromSplit:item keep:YES];
  BOOL removed = NO;
  for (ArcItem* section in [self sectionsOfSpace:_space]) removed = removed || RemoveItem(section, item);
  if (!removed) return NO;
  group.splitHorizontal = horizontal;
  group.splitFractions = nil;
  NSUInteger at = [group.children indexOfObject:_shown] + (before ? 0 : 1);
  [group.children insertObject:item atIndex:MIN(at, group.children.count)];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  [self showItem:item];
  return YES;
}

// Arc's split pane "Maximize": the focused pane fills the page card for a while; the split stays as it is. Toggling
// again, focusing another pane or leaving the split restores it.
- (IBAction)toggleMaximizePane:(id)sender {
  [self syncSplitState];
  _maximizedPane = _maximizedPane || _splitItems.count < 2 ? nil : _shown;
  [self layoutPanes];
}
- (ArcItem*)maximizedPane { return _maximizedPane; }  // tests
- (ArcItem*)parentOfItemForTest:(ArcItem*)item { return [self parentOfItem:item]; }
- (NSRect)frameOfPaneItem:(ArcItem*)item {  // tests: where a pane's page is, or zero if hidden
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return NSZeroRect;
  NSView* v = [self pageViewForBrowser:it->second];
  return v.hidden ? NSZeroRect : v.frame;
}

- (IBAction)addLeftSplit:(id)sender {
  [self beginSplit:NO];
  _splitBefore = YES;
}
- (IBAction)addTopSplit:(id)sender {
  [self beginSplit:YES];
  _splitBefore = YES;
}
- (IBAction)flipSplitLayout:(id)sender {
  if (!_splitGroup) return;
  _splitGroup.splitHorizontal = !_splitGroup.splitHorizontal;
  [_outline reloadItem:_splitGroup];
  [self layoutPanes];
  [self scheduleSave];
}

// Removes the focused pane from the split; its tab stays in the sidebar.
- (IBAction)closeSplitPane:(id)sender {
  if (![_splitItems containsObject:_shown]) return;
  NSUInteger index = [_splitItems indexOfObject:_shown];
  NSArray<ArcItem*>* rest = [_splitItems filteredArrayUsingPredicate:
      [NSPredicate predicateWithBlock:^BOOL(ArcItem* t, NSDictionary*) { return t != self->_shown; }]];
  ArcItem* next = rest[MIN(index, rest.count - 1)];
  [self detachFromSplit:_shown keep:YES];
  [self showItem:next];
}

- (IBAction)focusNextPane:(id)sender {
  if (![_splitItems containsObject:_shown]) return;
  NSUInteger index = ([_splitItems indexOfObject:_shown] + 1) % _splitItems.count;
  [self showItem:_splitItems[index]];
  if (auto b = [self currentBrowser]) b->GetHost()->SetFocus(true);
}

// Arc: "Switch to previous Split View" (the adjacent pane, wrapping around).
- (IBAction)focusPreviousPane:(id)sender {
  if (![_splitItems containsObject:_shown]) return;
  NSUInteger n = _splitItems.count;
  NSUInteger index = ([_splitItems indexOfObject:_shown] + n - 1) % n;
  [self showItem:_splitItems[index]];
  if (auto b = [self currentBrowser]) b->GetHost()->SetFocus(true);
}

// Arc: "Share Split View" copied an arc.net link to the whole split. Arc's link service is gone, so NotArc copies
// every pane's address (one per line as text, plus a Markdown list) so the split can be shared and reopened.
- (NSPasteboard*)copyPasteboard {
  return self.selfTestProfiles ? [NSPasteboard pasteboardWithName:@"io.github.donnadieu.notarc.selftest"]
                               : NSPasteboard.generalPasteboard;
}

- (NSArray<ArcItem*>*)visiblePanesForTest { return [self visiblePanes]; }

- (NSString*)splitViewShareText {
  if (![_splitItems containsObject:_shown]) return nil;
  NSMutableArray* lines = [NSMutableArray array];
  for (ArcItem* pane in _splitItems) {
    NSString* url = [self itemCurrentURL:pane];
    if (url.length) [lines addObject:url];
  }
  return lines.count ? [lines componentsJoinedByString:@"\n"] : nil;
}

- (IBAction)shareSplitView:(id)sender {
  NSString* text = [self splitViewShareText];
  if (!text) { NSBeep(); return; }
  NSMutableArray* md = [NSMutableArray array];
  for (ArcItem* pane in _splitItems) {
    NSString* url = [self itemCurrentURL:pane];
    if (!url.length) continue;
    NSString* title = [pane.displayTitle stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
    [md addObject:[NSString stringWithFormat:@"- [%@](%@)", title, url]];
  }
  NSPasteboard* pb = [self copyPasteboard];
  [pb clearContents];
  [pb setString:text forType:NSPasteboardTypeString];
  [pb setString:[md componentsJoinedByString:@"\n"] forType:@"net.daringfireball.markdown"];
}

// Opening shared links: several addresses at once (one per line) become one split, like the one that was shared.
- (BOOL)openSplitFromText:(NSString*)text {
  NSMutableArray<NSString*>* urls = [NSMutableArray array];
  for (NSString* line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    NSString* t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ([t hasPrefix:@"http://"] || [t hasPrefix:@"https://"]) [urls addObject:t];
  }
  if (urls.count < 2 || urls.count > 4) return NO;  // Arc splits hold up to four panes
  [self openInNewTab:urls.firstObject];
  for (NSUInteger i = 1; i < urls.count; ++i) [self openInSplit:urls[i] horizontal:NO];
  return YES;
}

#pragma mark Little Window

- (void)openLittleWindow:(NSString*)input {
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space) return;
  ArcSpace* space = _space;
  CefRefPtr<CefRequestContext> context = [self contextForSpace:space];
  __weak MainWindowController* weakSelf = self;
  if (![self contextIsReady:space.profileDirectory]) {
    // The Space's profile is still starting (e.g. a link arrived at launch); try again shortly.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
      [weakSelf openLittleWindow:url];
    });
    return;
  }
  LittleWindowController* little = [[LittleWindowController alloc] initWithURL:url
      context:context
      onMove:^(NSString* movedURL) { [weakSelf openInNewTab:movedURL]; }
      onClose:^(LittleWindowController* lw, NSString* closedURL, NSString* title, BOOL moved) {
        [weakSelf littleWindowClosed:lw url:closedURL title:title moved:moved space:space];
      }];
  NSMutableArray* names = [NSMutableArray array];
  for (ArcSpace* sp in _spaces) [names addObject:sp.title ?: @"Space"];
  little.spaceNames = names;
  little.onMoveToSpace = ^(NSString* movedURL, NSUInteger i) {
    MainWindowController* me = weakSelf;
    if (!me || i >= me->_spaces.count) return;
    if (me->_spaces[i] != me->_space) [me switchToSpace:me->_spaces[i]];
    [me openInNewTab:movedURL];
  };
  if (!_littleWindows) _littleWindows = [NSMutableArray array];
  [_littleWindows addObject:little];
  BOOL dark = [space.colorScheme isEqual:@"dark"] || (![space.colorScheme isEqual:@"light"] && IsDark(self.window.contentView));
  NSColor* tint = space.themeColors.count ? ColorFromHex(space.themeColors.firstObject) : nil;
  if (!tint) tint = dark ? ColorFromHex(@"#120C39") : [NSColor colorWithSRGBRed:0.93 green:0.92 blue:0.97 alpha:1];
  [little applySpaceTint:tint dark:dark];
  [little showWindow:nil];
}
- (NSString*)littleWindowStyle {  // tests (V38): the newest Little Window
  return [(LittleWindowController*)_littleWindows.lastObject littleStyleDescription] ?: @"none";
}

// A Little Window that's closed without being moved still lands in the Archive, like Arc.
- (void)littleWindowClosed:(LittleWindowController*)little
                       url:(NSString*)url
                     title:(NSString*)title
                     moved:(BOOL)moved
                     space:(ArcSpace*)space {
  [_littleWindows removeObject:little];
  if (moved || !url.length || [url isEqualToString:@"about:blank"]) return;
  ArchivedTab* t = [ArchivedTab new];
  t.url = url;
  t.title = title ?: url;
  t.spaceID = space.spaceID;
  t.reason = @"littleWindow";
  t.archivedAt = [NSDate date];
  [[self archive] addObject:t];
  if (self.archivePath) ArchiveStoreSave(_archive, self.archivePath);
}

- (BOOL)addImportedBookmarks:(ArcItem*)folder {
  if (!folder || !_space.pinned) return NO;
  [_space.pinned.children addObject:folder];
  [_outline reloadItem:_space.pinned reloadChildren:YES];
  [_outline expandItem:folder];
  [self scheduleSave];
  return YES;
}

- (NSUInteger)importHistoryFromFile:(NSString*)db browser:(NSString*)name {
  NSUInteger n = [self importHistoryFromFile:db browser:name kind:@"chromium"];
  return n == NSNotFound ? 0 : n;
}

- (NSUInteger)importHistoryFromFile:(NSString*)db browser:(NSString*)name kind:(NSString*)kind {
  HistoryStore* store = [self historyStore];
  if (!store || !db.length) return NSNotFound;
  NSError* error = nil;
  // Chromium-family browsers keep history in the same database format as Arc; Firefox and Safari have their own.
  NSArray* visits = [kind isEqualToString:@"firefox"] ? FirefoxReadHistory(db, name, 20000, &error)
                    : [kind isEqualToString:@"safari"] ? SafariReadHistory(db, name, 20000, &error)
                                                       : ArcReadHistory(db, name, 20000, &error);
  if (!visits) {
    if (error) std::fprintf(stderr, "History import skipped: %s\n", error.localizedDescription.UTF8String);
    return NSNotFound;
  }
  return [store mergeVisits:visits];
}

- (IBAction)importHistoryFromMenu:(id)sender {
  NSArray* sources = DetectedHistorySources();
  NSAlert* a = [NSAlert new];
  a.messageText = @"Import History";
  if (!sources.count) {
    a.informativeText = @"No browser history was found on this Mac.";
    [a beginSheetModalForWindow:self.window completionHandler:nil];
    return;
  }
  a.informativeText = @"Visits are added to NotArc's History (Cmd+Y) and command bar. The other browser isn't changed.";
  for (NSArray* s in sources)
    if ([s[2] isEqualToString:@"safari"] && ![NSFileManager.defaultManager isReadableFileAtPath:s[1]]) {
      a.informativeText = [a.informativeText stringByAppendingString:@" Safari needs Full Disk Access for NotArc."];
      break;
    }
  NSPopUpButton* from = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 26) pullsDown:NO];
  for (NSArray* s in sources) {
    [from addItemWithTitle:s[0]];
    from.lastItem.representedObject = s;
  }
  a.accessoryView = from;
  [a addButtonWithTitle:@"Import"];
  [a addButtonWithTitle:@"Cancel"];
  __weak MainWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    NSArray* src = from.selectedItem.representedObject;
    dispatch_async(dispatch_get_main_queue(), ^{
      MainWindowController* me = weakSelf;
      if (!me || !src) return;
      NSUInteger n = [me importHistoryFromFile:src[1] browser:src[0] kind:src[2]];
      NSAlert* done = [NSAlert new];
      if (n == NSNotFound) {
        done.messageText = [NSString stringWithFormat:@"Couldn't read %@ history", src[0]];
        if ([src[2] isEqualToString:@"safari"])
          done.informativeText = @"macOS protects Safari's history. To import it, give NotArc Full Disk Access in System "
                                 @"Settings > Privacy & Security, then try again.";
      } else {
        done.messageText = n ? [NSString stringWithFormat:@"%lu visits imported", (unsigned long)n] : @"No new history to import";
      }
      [done beginSheetModalForWindow:me.window completionHandler:nil];
    });
  }];
}

- (IBAction)importBookmarksFromMenu:(id)sender {
  NSAlert* a = [NSAlert new];
  a.messageText = @"Import Bookmarks";
  a.informativeText = @"Bookmarks go into a folder in this Space's Pinned tabs. From Safari or Firefox, export a "
                      @"bookmarks HTML file there (Safari: File > Export > Bookmarks) and choose it here.";
  NSPopUpButton* from = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 300, 26) pullsDown:NO];
  for (NSArray* s in DetectedBookmarkSources()) {
    [from addItemWithTitle:s[0]];
    from.lastItem.representedObject = s;
  }
  [from addItemWithTitle:@"Bookmarks HTML file..."];
  a.accessoryView = from;
  [a addButtonWithTitle:@"Import"];
  [a addButtonWithTitle:@"Cancel"];
  __weak MainWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    NSArray* src = from.selectedItem.representedObject;
    dispatch_async(dispatch_get_main_queue(), ^{
      MainWindowController* me = weakSelf;
      if (!me) return;
      NSUInteger n = 0;
      ArcItem* folder = nil;
      if (src) {
        folder = BookmarksFromChromiumFile(src[1], [@"Bookmarks from " stringByAppendingString:src[0]], &n);
      } else {
        NSOpenPanel* p = [NSOpenPanel openPanel];
        p.allowedContentTypes = @[ UTTypeHTML ];
        if ([p runModal] != NSModalResponseOK) return;
        folder = BookmarksFromHTMLFile(p.URL.path, @"Imported Bookmarks", &n);
      }
      NSAlert* done = [NSAlert new];
      done.messageText = folder && n ? [NSString stringWithFormat:@"%lu bookmarks imported", (unsigned long)n]
                                     : @"No bookmarks found";
      if (folder && n) [me addImportedBookmarks:folder];
      [done beginSheetModalForWindow:me.window completionHandler:nil];
    });
  }];
}

- (BOOL)scriptItem:(ArcItem*)item command:(NSString*)command {
  if (!item) return NO;
  auto it = _browsers.find(item.browserId);
  CefRefPtr<CefBrowser> b = it == _browsers.end() ? nullptr : it->second;
  if ([command isEqualToString:@"loading"]) return b && b->IsLoading();
  if ([command isEqualToString:@"select"]) { [self showItem:item]; return YES; }
  if ([command isEqualToString:@"close"]) {
    if (_shown != item) [self showItem:item];
    [self closeCurrentTab];
    return YES;
  }
  if (!b) return NO;
  if ([command isEqualToString:@"back"]) b->GoBack();
  else if ([command isEqualToString:@"forward"]) b->GoForward();
  else if ([command isEqualToString:@"reload"]) b->Reload();
  else if ([command isEqualToString:@"stop"]) b->StopLoad();
  return YES;
}

- (IBAction)newIncognitoWindow:(id)sender {
  _commandOpensSplit = NO;
  _commandOpensLittle = NO;
  _commandOpensIncognito = YES;
  [self showCommandBarForNewTab:YES];
}

- (void)openIncognitoWindow:(NSString*)input {
  NSString* url = ResolveCommandBarInput(input.length ? input : @"about:blank");
  if (!url) return;
  __weak MainWindowController* weakSelf = self;
  if (!_incognitoContext) {
    CefRequestContextSettings settings;  // empty cache_path = in memory only
    _incognitoReady = NO;
    _incognitoContext = CefRequestContext::CreateContext(settings, new SpaceContextHandler([weakSelf]() {
      MainWindowController* me = weakSelf;
      if (me) me->_incognitoReady = YES;
    }));
  }
  if (!_incognitoReady) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10), dispatch_get_main_queue(), ^{
      [weakSelf openIncognitoWindow:url];
    });
    return;
  }
  LittleWindowController* w = [[LittleWindowController alloc] initWithURL:url context:_incognitoContext onMove:nil
      onClose:^(LittleWindowController* lw, NSString*, NSString*, BOOL) {
        MainWindowController* me = weakSelf;
        if (!me) return;
        [me->_incognitoWindows removeObject:lw];
        if (!me->_incognitoWindows.count) {  // last one closed: forget everything
          me->_incognitoContext = nullptr;
          me->_incognitoReady = NO;
        }
      }];
  [w makeIncognito];
  if (!_incognitoWindows) _incognitoWindows = [NSMutableArray array];
  [_incognitoWindows addObject:w];
  if (!self.window.isVisible || self.window.alphaValue < 0.02) {  // hidden test runs stay hidden
    w.window.alphaValue = 0.01;
    [w.window orderBack:nil];
  } else {
    [w showWindow:nil];
  }
}

- (NSUInteger)incognitoWindowCount { return _incognitoWindows.count; }

- (BOOL)incognitoContextIsOnDisk {
  return _incognitoContext && !_incognitoContext->GetCachePath().ToString().empty();
}

- (IBAction)newLittleWindow:(id)sender {
  _commandOpensIncognito = NO;
  _commandOpensSplit = NO;
  _commandOpensLittle = YES;
  [self showCommandBarForNewTab:YES];
}

- (NSUInteger)littleWindowCount { return _littleWindows.count; }
// Arc's "Show Little Arc Windows" / "Close Little Arc Windows" (Window menu).
- (IBAction)closeAllLittleWindows:(id)sender {
  for (LittleWindowController* lw in [_littleWindows copy]) [lw.window close];
}
- (IBAction)showAllLittleWindows:(id)sender {
  for (LittleWindowController* lw in _littleWindows)
    if (self.selfTestProfiles) [lw.window orderBack:nil];
    else [lw.window makeKeyAndOrderFront:nil];
}

- (NSUInteger)archiveIdleLittleWindowsAt:(NSDate*)now {
  double hours = SettingDouble(kSettingLittleArchiveHours);
  if (hours <= 0) return 0;
  NSUInteger closed = 0;
  for (LittleWindowController* lw in [_littleWindows copy]) {
    if (lw.window.isKeyWindow || !lw.lastUsedAt) continue;
    if ([now timeIntervalSinceDate:lw.lastUsedAt] < hours * 3600) continue;
    [lw.window close];  // closing without moving archives the page
    ++closed;
  }
  return closed;
}

- (void)setLittleWindowLastUsed:(NSDate*)date index:(NSUInteger)index {
  if (index < _littleWindows.count) _littleWindows[index].lastUsedAt = date;
}
- (void)moveLittleWindow:(NSUInteger)index toSpaceAtIndex:(NSUInteger)spaceIndex {
  if (index < _littleWindows.count) [_littleWindows[index] openInSpaceAtIndex:spaceIndex];
}
- (void)moveLittleWindowToMain:(NSUInteger)index {
  if (index < _littleWindows.count) [_littleWindows[index] openInMainWindow:nil];
}
- (void)closeLittleWindow:(NSUInteger)index {
  if (index < _littleWindows.count) [_littleWindows[index].window close];
}

// Arc: "Open Little Arc when clicking on links with <modifier> held". NotArc's modifier is Cmd+Option (Cmd-click alone
// opens a background tab, Shift-click a Peek, Option-click downloads), the same keys that open a sidebar tab in a
// Little Window. Read from the keys held at the moment of the click.
BOOL OpensLittleWindowForClick(NSEventModifierFlags mods, BOOL gesture) {
  NSEventModifierFlags m = mods & (NSEventModifierFlagCommand | NSEventModifierFlagOption | NSEventModifierFlagShift |
                                   NSEventModifierFlagControl);
  return gesture && m == (NSEventModifierFlagCommand | NSEventModifierFlagOption) && SettingBool(kSettingLittleModifierClick);
}

- (BOOL)handleOpenURL:(NSString*)url fromBrowser:(int)browserId disposition:(int)disposition userGesture:(BOOL)gesture {
  if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) return NO;
  if (![self itemForBrowser:browserId]) return NO;  // e.g. from a Peek or Little Window: let CEF handle it
  __weak MainWindowController* weakSelf = self;
  NSEventModifierFlags mods = self.testClickModifiers ?: NSEvent.modifierFlags;
  if (OpensLittleWindowForClick(mods, gesture)) {
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openLittleWindow:url]; });
    return YES;
  }
  if (disposition == CEF_WOD_NEW_WINDOW && gesture && !_peek && SettingBool(kSettingPeekShiftClick)) {
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openPeek:url]; });
    return YES;
  }
  BOOL background = disposition == CEF_WOD_NEW_BACKGROUND_TAB;
  dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf openInNewTab:url background:background]; });
  return YES;
}

#pragma mark Peek

// "mail.google.com" and "docs.google.com" count as the same site; good enough without a public suffix list.
static NSString* SiteOf(NSString* url) {
  NSString* host = [NSURL URLWithString:url].host.lowercaseString;
  NSArray<NSString*>* parts = [host componentsSeparatedByString:@"."];
  if (parts.count < 2) return host;
  NSString* last2 = [[parts subarrayWithRange:NSMakeRange(parts.count - 2, 2)] componentsJoinedByString:@"."];
  // co.uk, com.au and similar: keep three labels.
  if (parts.count >= 3 && parts[parts.count - 2].length <= 3 && parts.lastObject.length == 2)
    return [[parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)] componentsJoinedByString:@"."];
  return last2;
}

- (BOOL)shouldPeekFromItem:(ArcItem*)item toURL:(NSString*)url {
  if (!item || !url.length || _peek || !SettingBool(kSettingPeekPinnedLinks)) return NO;
  if (![url hasPrefix:@"http://"] && ![url hasPrefix:@"https://"]) return NO;
  ArcSpace* space = [self spaceOwningItem:item];
  BOOL pinnedOrFavorite = Contains(space.pinned, item) || Contains(space.favorites, item);
  if (!pinnedOrFavorite) return NO;
  auto it = _browsers.find(item.browserId);
  NSString* current = it != _browsers.end()
                          ? [NSString stringWithUTF8String:it->second->GetMainFrame()->GetURL().ToString().c_str()]
                          : item.url;
  NSString* from = SiteOf(current), *to = SiteOf(url);
  return from.length && to.length && ![from isEqualToString:to];
}

// Email peeking (#44), Arc's "Peek Email": the newest unread email from the site you're on (sign-in codes, magic
// links), read from Gmail with this Space's Gmail sign-in. A code is copied; otherwise the email opens in a Peek.
- (IBAction)peekEmail:(id)sender {
  NSString* host = [NSURL URLWithString:[self itemCurrentURL:_shown] ?: @""].host;
  if (!host.length) return;
  [self showToast:[NSString stringWithFormat:@"Checking for emails from %@", host] action:nil selector:nil];
  __weak MainWindowController* weakSelf = self;
  SpaceFetch([self contextForSpace:_space], kGmailFeedURL, nil, ^(NSInteger status, NSData* body, NSString* finalURL) {
    [weakSelf finishPeekEmail:host status:status body:body];
  });
}
- (NSString*)finishPeekEmail:(NSString*)host status:(NSInteger)status body:(NSData*)body {  // returns what happened (tests)
  if (status != 200 || ![[[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding] containsString:@"<feed"]) {
    [self showToast:@"Make sure you're signed in to Gmail in this Space." action:nil selector:nil];
    return @"signedOut";
  }
  NSDictionary* e = EmailPeekMatch(GmailFeedEntries(body), host, NSDate.date, 30 * 60);
  if (!e) {
    [self showToast:[NSString stringWithFormat:@"No new email from %@ in the last 30 minutes", host] action:nil selector:nil];
    return @"none";
  }
  NSString* code = AuthCodeInText([NSString stringWithFormat:@"%@ %@", e[@"title"] ?: @"", e[@"summary"] ?: @""]);
  if (code) {
    NSPasteboard* pb = [self copyPasteboard];
    [pb clearContents];
    [pb setString:code forType:NSPasteboardTypeString];
    [self showToast:[NSString stringWithFormat:@"Code from %@ copied: %@", host, code] action:nil selector:nil];
    return [@"code:" stringByAppendingString:code];
  }
  if ([e[@"link"] length]) [self openPeek:e[@"link"]];
  return [@"peek:" stringByAppendingString:e[@"link"] ?: @""];
}

- (void)openPeek:(NSString*)url {
  if (_peek || !_space) return;
  __weak MainWindowController* weakSelf = self;
  _peek = [[LittleWindowController alloc] initWithURL:url
      context:[self contextForSpace:_space]
      onMove:^(NSString* movedURL) { [weakSelf openInNewTab:movedURL]; }
      onClose:^(LittleWindowController*, NSString* closedURL, NSString*, BOOL moved) {
        [weakSelf peekClosed:closedURL moved:moved];
      }];
  // Arc: the Peek card sits over the page card, a little inset, with the page dimmed behind it.
  NSRect card = [self.window convertRectToScreen:[_content convertRect:_content.bounds toView:nil]];
  NSRect area = NSMakeRect(NSMinX(card) + card.size.width * 0.05, NSMinY(card) + card.size.height * 0.04,
                           card.size.width * 0.90, card.size.height * 0.96 - 8);
  [self showPeekScrim:YES];
  [_peek presentAsPeekOver:self.window inRect:area];
  [self hideToast];
}
- (void)showPeekScrim:(BOOL)show {
  if (!show) {
    [_peekScrim removeFromSuperview];
    return;
  }
  if (!_peekScrim) {
    _peekScrim = [[NSView alloc] initWithFrame:NSZeroRect];
    _peekScrim.wantsLayer = YES;
    _peekScrim.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.35].CGColor;
    _peekScrim.layer.cornerRadius = kCardRadius;
  }
  _peekScrim.frame = _content.frame;
  [self.window.contentView addSubview:_peekScrim positioned:NSWindowAbove relativeTo:_content];
}
- (NSString*)peekStyle {  // tests (V39)
  return [NSString stringWithFormat:@"%@ scrim=%d", [_peek peekStyleDescription] ?: @"none", _peekScrim.superview != nil];
}

- (void)peekClosed:(NSString*)url moved:(BOOL)moved {
  _peek = nil;
  [self showPeekScrim:NO];
  if (moved || _closing || !url.length || [url isEqualToString:@"about:blank"]) return;
  _lastClosedPeekURL = [url copy];
  __weak MainWindowController* weakSelf = self;
  [[self sidebarUndoManager] registerUndoWithTarget:self handler:^(id) { [weakSelf reopenClosedPeek:nil]; }];
  [[self sidebarUndoManager] setActionName:@"Close Peek"];
  [self showToast:@"Peek closed" action:@"Undo" selector:@selector(reopenClosedPeek:)];
}

- (NSString*)lastClosedPeekURL { return _lastClosedPeekURL; }
- (BOOL)peekToastShown { return _toast != nil; }

- (IBAction)reopenClosedPeek:(id)sender {
  NSString* url = _lastClosedPeekURL;
  [self hideToast];
  if (!url.length || _peek) return;
  _lastClosedPeekURL = nil;
  [self openPeek:url];
}

// Small toast at the bottom centre of the page area with one action button.
- (void)showToast:(NSString*)text action:(NSString*)action selector:(SEL)selector {
  [self showToast:text buttons:action.length ? @[ @[ action, NSStringFromSelector(selector) ] ] : @[] target:self duration:6];
}

- (void)showToast:(NSString*)text buttons:(NSArray<NSArray<NSString*>*>*)buttons target:(id)target
         duration:(NSTimeInterval)duration {
  [self hideToast];
  // Arc's toast: a dark capsule with an icon, the message, and plain-text actions after a thin divider.
  NSTextField* label = [NSTextField labelWithString:text];
  label.textColor = NSColor.whiteColor;
  label.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  NSString* symbol = [text hasPrefix:@"Copied"] ? @"checkmark.circle.fill"
                     : [text.lowercaseString containsString:@"closed"] || [text.lowercaseString containsString:@"archiv"] ? @"archivebox.fill"
                                                                                                                         : @"info.circle.fill";
  NSImageView* icon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:nil]];
  icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
  icon.contentTintColor = [NSColor colorWithWhite:1 alpha:0.75];
  NSMutableArray* views = [NSMutableArray arrayWithObjects:icon, label, nil];
  for (NSArray<NSString*>* b in buttons) {
    NSBox* sep = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 1, 16)];
    sep.boxType = NSBoxCustom;
    sep.borderWidth = 0;
    sep.fillColor = [NSColor colorWithWhite:1 alpha:0.2];
    [sep.widthAnchor constraintEqualToConstant:1].active = YES;
    [sep.heightAnchor constraintEqualToConstant:16].active = YES;
    [views addObject:sep];
    NSButton* button = [NSButton buttonWithTitle:b[0] target:target action:NSSelectorFromString(b[1])];
    button.bordered = NO;
    button.attributedTitle = [[NSAttributedString alloc]
        initWithString:b[0]
            attributes:@{NSForegroundColorAttributeName : [NSColor colorWithSRGBRed:0.55 green:0.68 blue:1 alpha:1],
                         NSFontAttributeName : [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]}];
    [views addObject:button];
  }
  NSStackView* stack = [NSStackView stackViewWithViews:views];
  stack.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 14);
  stack.spacing = 8;
  stack.wantsLayer = YES;
  stack.shadow = [NSShadow new];
  stack.layer.shadowColor = NSColor.blackColor.CGColor;
  stack.layer.shadowOpacity = 0.3;
  stack.layer.shadowRadius = 10;
  stack.layer.shadowOffset = CGSizeMake(0, -3);
  // Arc's toasts are dark in both appearances.
  stack.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  stack.layer.backgroundColor = [NSColor colorWithSRGBRed:0.11 green:0.11 blue:0.13 alpha:0.96].CGColor;
  NSSize sz = stack.fittingSize;
  stack.layer.cornerRadius = sz.height / 2;
  NSRect c = _content.frame;
  stack.frame = NSMakeRect(NSMidX(c) - sz.width / 2, NSMinY(c) + 20, sz.width, sz.height);
  stack.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMaxYMargin;
  [self.window.contentView addSubview:stack positioned:NSWindowAbove relativeTo:nil];
  _toast = stack;
  _toastText = [text copy];
  __weak MainWindowController* weakSelf = self;
  _toastTimer = [NSTimer scheduledTimerWithTimeInterval:duration repeats:NO block:^(NSTimer*) { [weakSelf hideToast]; }];
}

- (void)hideToast {
  [_toastTimer invalidate];
  _toastTimer = nil;
  [_toast removeFromSuperview];
  _toast = nil;
  _toastText = nil;
}

#pragma mark Passwords and autofill (#67)

- (AutofillController*)autofill {
  if (!_autofill) {
    _autofill = [[AutofillController alloc] initWithHost:self];
    _autofill.recordMenusOnly = self.selfTestProfiles;  // hidden runs never pop a menu
  }
  return _autofill;
}

- (BOOL)autofillRun:(NSString*)js nonce:(NSString*)nonce {
  return _client && _client->AutofillRun(nonce.UTF8String, js.UTF8String);
}

- (void)autofillRunAllFrames:(NSString*)js browser:(int)browserId {
  if (_client) _client->AutofillRunAllFrames(browserId, js.UTF8String);
}

- (NSView*)viewForBrowserId:(int)browserId {
  CefRefPtr<CefBrowser> b = _client ? _client->BrowserById(browserId) : nullptr;
  return b ? (__bridge NSView*)b->GetHost()->GetWindowHandle() : nil;
}

- (IBAction)fillPassword:(id)sender {
  if (_shown.browserId) [self.autofill fillPasswordInBrowser:_shown.browserId];
}

- (IBAction)showPasswords:(id)sender {
  PasswordsWindowController* pw = [PasswordsWindowController shared];
  __weak MainWindowController* weakSelf = self;
  pw.pasteboardProvider = ^NSPasteboard* { return [weakSelf copyPasteboard] ?: NSPasteboard.generalPasteboard; };
  if ([sender isKindOfClass:NSMenuItem.class] && [(NSMenuItem*)sender menu] != NSApp.mainMenu &&
      [(NSMenuItem*)sender action] == @selector(showPasswords:) && [(NSMenuItem*)sender tag] > 0)
    pw.section = [(NSMenuItem*)sender tag];  // from the fill menu: Addresses or Cards
  if (self.selfTestProfiles) [pw reload];  // hidden runs never show it
  else [pw showWindow:nil];
}

- (IBAction)importPasswordsFromMenu:(id)sender { [self.autofill importPasswordsFromMenu]; }

// Saved passwords, addresses and cards from each Space's Arc profile ("Login Data", "Web Data"), with Arc's own
// key ("Arc Safe Storage", the item cookie import already reads). nil when the key isn't available.
- (NSDictionary*)importArcPasswordsFromUserData:(NSString*)userData {
  NSData* key = self.arcSafeStorageKeyOverride;
  NSString* keyError = nil;
  if (!key && !self.selfTestProfiles && !_arcKeyFailed) {  // tests never read the real Keychain
    __block NSError* error = nil;
    __block NSData* read = nil;
    dispatch_sync(ArcImportQueue(), ^{ read = ArcImportKey(&error); });
    key = read;
    if (!key) keyError = error.localizedDescription;
  }
  if (!key) return @{@"error" : [NSString stringWithFormat:@"macOS didn't give NotArc Arc's key%@.",
                                                         keyError ? [NSString stringWithFormat:@" (%@)", keyError] : @""]};
  PasswordStore* store = [PasswordStore shared];
  if (![store unlockIfNeeded])
    return @{@"error" : @"NotArc's own password vault is locked: macOS didn't let NotArc read its \"NotArc Safe "
                        @"Storage\" Keychain item."};
  NSUInteger passwords = 0, addresses = 0, cards = 0, existing = 0, bad = 0, found = 0;
  NSMutableSet* done = [NSMutableSet set];
  for (ArcSpace* s in _spaces) {
    NSString* p = s.profileDirectory.length ? s.profileDirectory : @"Default";
    if ([done containsObject:p]) continue;
    [done addObject:p];
    NSDictionary* n = [store importChromiumProfile:[userData stringByAppendingPathComponent:p] key:key
                                            source:[NSString stringWithFormat:@"Arc (%@)", s.title ?: p]];
    if (!n) continue;  // no Login Data / Web Data in that profile
    ++found;
    passwords += [n[@"passwords"] unsignedIntegerValue];
    addresses += [n[@"addresses"] unsignedIntegerValue];
    cards += [n[@"cards"] unsignedIntegerValue];
    existing += [n[@"existing"] unsignedIntegerValue];
    bad += [n[@"undecryptable"] unsignedIntegerValue];
  }
  NSMutableDictionary* out = [@{@"passwords" : @(passwords), @"addresses" : @(addresses), @"cards" : @(cards),
                                @"existing" : @(existing), @"undecryptable" : @(bad)} mutableCopy];
  if (!found && done.count) out[@"error"] = @"Arc's password files weren't found in its profile folders.";
  return out;
}
- (BOOL)isPeeking { return _peek != nil; }
- (void)promotePeekToTab { [_peek openInMainWindow:nil]; }
- (void)closePeek { [_peek.window close]; }

#pragma mark Spaces

static ArcItem* NewSection(NSString* title) {
  ArcItem* section = [ArcItem new];
  section.isSection = YES;
  section.title = title;
  section.children = [NSMutableArray array];
  return section;
}

// One button per Space: its emoji, or a dot (filled for the current Space) when it has none, as in Arc.
- (void)rebuildSpaceBar {
  for (NSView* v in [_spaceIcons.views copy]) [_spaceIcons removeView:v];
  NSUInteger i = 0;
  for (ArcSpace* sp in _spaces) {
    BOOL current = sp == _space;
    NSButton* b;
    if (sp.iconEmoji.length) {
      b = [NSButton buttonWithTitle:sp.iconEmoji target:self action:@selector(spaceIconClicked:)];
      b.font = [NSFont systemFontOfSize:current ? 15 : 13];
      b.alphaValue = current ? 1 : 0.55;
    } else {
      // Arc: filled 8 pt dots for every Space; the current one is brighter.
      b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:@"circle.fill" accessibilityDescription:sp.title]
                             target:self action:@selector(spaceIconClicked:)];
      b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:7 weight:NSFontWeightRegular];
      b.contentTintColor = SpaceDotColor(current);
    }
    b.bordered = NO;
    b.tag = (NSInteger)i++;
    b.toolTip = sp.title ?: @"Space";
    [b.widthAnchor constraintEqualToConstant:24].active = YES;
    [_spaceIcons addView:b inGravity:NSStackViewGravityCenter];
  }
  // Arc hides the switcher when there's only one Space. Dots are 34 pt apart, centred in the bar.
  _spaceIcons.hidden = _spaces.count < 2;
  _spaceIcons.spacing = 10;
  _spaceIcons.alignment = NSLayoutAttributeCenterY;
  CGFloat sw = _spaces.count * 24 + (_spaces.count ? (_spaces.count - 1) * 10 : 0);
  _spaceIcons.frame = NSMakeRect(round((_spaceBar.bounds.size.width - sw) / 2), 0, sw, 30);
  for (NSView* v in _spaceIcons.views) [v.heightAnchor constraintEqualToConstant:30].active = YES;
}
- (void)spaceIconClicked:(NSButton*)sender { [self selectSpaceAtIndex:(NSUInteger)sender.tag]; }
- (NSArray<NSString*>*)spaceBarIcons {  // tests: "*Title" for the current Space
  NSMutableArray* out = [NSMutableArray array];
  for (NSButton* b in _spaceIcons.views)
    [out addObject:[NSString stringWithFormat:@"%@%@", b.tag == (NSInteger)[_spaces indexOfObject:_space] ? @"*" : @"", b.toolTip]];
  return out;
}
- (void)clickSpaceBarIcon:(NSUInteger)index {  // tests
  if (index < _spaceIcons.views.count) [(NSButton*)_spaceIcons.views[index] performClick:nil];
}
// + menu > New Live Folder: a feed or repository, your own GitHub pull requests, or a YouTube channel.
- (NSMenuItem*)newLiveFolderMenuItem {
  NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:@"New Live Folder" action:nil keyEquivalent:@""];
  NSMenu* sub = [[NSMenu alloc] initWithTitle:@"New Live Folder"];
  [sub addItemWithTitle:@"GitHub: My Pull Requests" action:@selector(newMyPullRequestsFolder:) keyEquivalent:@""].target = self;
  [sub addItemWithTitle:@"YouTube Channel..." action:@selector(newYouTubeLiveFolder:) keyEquivalent:@""].target = self;
  [sub addItemWithTitle:@"Feed or GitHub Repository..." action:@selector(newLiveFolder:) keyEquivalent:@""].target = self;
  item.submenu = sub;
  return item;
}
// Arc's + menu: a native menu with an icon on every row (tab, split right / below, folder, easel, note, boost,
// space), in that order, opening upward from the button.
- (NSMenu*)newItemMenu {
  NSMenu* m = [[NSMenu alloc] initWithTitle:@"New"];
  NSArray* rows = @[
    @[ @"New Tab", @"newTab:", @"plus.square" ], @[ @"New Split View", @"addVerticalSplit:", @"rectangle.split.2x1" ],
    @[ @"New Split View Below", @"addHorizontalSplit:", @"rectangle.split.1x2" ], @[ @"-" ],
    @[ @"New Folder", @"newFolder:", @"folder" ], @[ @"New Easel", @"newEasel:", @"scribble.variable" ],
    @[ @"New Note", @"newNote:", @"note.text" ], @[ @"New Boost", @"editBoost:", @"paintbrush.pointed" ], @[ @"LIVE" ], @[ @"-" ],
    @[ @"New Space...", @"newSpace:", @"square.on.square" ], @[ @"New Profile...", @"newProfileForSpace:", @"person.crop.circle.badge.plus" ]
  ];
  for (NSArray* r in rows) {
    if ([r[0] isEqual:@"-"]) {
      [m addItem:NSMenuItem.separatorItem];
      continue;
    }
    if ([r[0] isEqual:@"LIVE"]) {
      NSMenuItem* live = [self newLiveFolderMenuItem];
      live.image = [NSImage imageWithSystemSymbolName:@"dot.radiowaves.up.forward" accessibilityDescription:nil];
      [m addItem:live];
      continue;
    }
    NSMenuItem* it = [m addItemWithTitle:r[0] action:NSSelectorFromString(r[1]) keyEquivalent:@""];
    it.target = self;
    it.image = [NSImage imageWithSystemSymbolName:r[2] accessibilityDescription:nil];
  }
  return m;
}
- (IBAction)showNewMenu:(NSButton*)sender {
  NSMenu* m = [self newItemMenu];
  [m popUpMenuPositioningItem:m.itemArray.lastObject atLocation:NSMakePoint(0, sender.bounds.size.height + 4) inView:sender];
}

- (void)updateSpaceHeader {
  NSString* name = _space.title ?: @"Space";
  _spaceHeaderTitle.stringValue = _space.iconEmoji.length ? [NSString stringWithFormat:@"%@  %@", _space.iconEmoji, name] : name;
}
- (NSString*)spaceHeaderText { return _spaceHeaderTitle.stringValue; }  // tests
- (NSMenu*)spaceMenu {
  NSMenu* m = [[NSMenu alloc] initWithTitle:@"Space"];
  for (NSArray* e in @[ @[ @"Rename Space...", @"renameCurrentSpace:" ], @[ @"Edit Theme Color...", @"editThemeColor:" ],
                        @[ @"Change Space Icon...", @"changeSpaceIcon:" ], @[ @"-", @"" ], @[ @"New Space...", @"newSpace:" ],
                        @[ @"Delete Space...", @"deleteCurrentSpace:" ] ]) {
    if ([e[0] isEqualToString:@"-"]) { [m addItem:NSMenuItem.separatorItem]; continue; }
    [m addItemWithTitle:e[0] action:NSSelectorFromString(e[1]) keyEquivalent:@""].target = self;
    if ([e[1] isEqualToString:@"changeSpaceIcon:"]) {
      NSMenuItem* ap = [m addItemWithTitle:@"Appearance" action:nil keyEquivalent:@""];
      ap.submenu = [[NSMenu alloc] initWithTitle:@"Appearance"];
      for (NSArray* o in @[ @[ @"Default (Settings)", @"auto" ], @[ @"Light", @"light" ], @[ @"Dark", @"dark" ] ]) {
        NSMenuItem* i = [ap.submenu addItemWithTitle:o[0] action:@selector(setSpaceAppearance:) keyEquivalent:@""];
        i.target = self;
        i.representedObject = o[1];
        NSString* cur = _space.colorScheme ?: @"auto";
        i.state = [cur isEqualToString:o[1]] ? NSControlStateValueOn : NSControlStateValueOff;
      }
      [m addItem:[self profileMenuItem]];
    }
  }
  return m;
}

#pragma mark Profiles

- (NSString*)profilesPath {
  if (!self.storePath) return nil;
  return [[self.storePath stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:self.selfTestProfiles ? @"SelfTestProfiles.json" : @"Profiles.json"];
}

- (NSMutableDictionary<NSString*, NSString*>*)profileNames {
  if (_profileNames) return _profileNames;
  _profileNames = [NSMutableDictionary dictionary];
  NSString* path = [self profilesPath];
  NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
  NSDictionary* saved = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if ([saved isKindOfClass:NSDictionary.class]) {
    for (NSString* k in saved)
      if ([saved[k] isKindOfClass:NSString.class]) _profileNames[k] = saved[k];
  } else {
    // First launch: Arc's own profile names (Local State, read-only).
    NSData* ls = [NSData dataWithContentsOfFile:[[ArcDataDirectory() stringByAppendingPathComponent:@"User Data"]
                                                    stringByAppendingPathComponent:@"Local State"]];
    NSDictionary* root = ls ? [NSJSONSerialization JSONObjectWithData:ls options:0 error:nil] : nil;
    NSDictionary* cache = [root isKindOfClass:NSDictionary.class] ? root[@"profile"][@"info_cache"] : nil;
    if ([cache isKindOfClass:NSDictionary.class])
      for (NSString* dir in cache) {
        NSString* name = [cache[dir] isKindOfClass:NSDictionary.class] ? cache[dir][@"name"] : nil;
        if ([name isKindOfClass:NSString.class] && name.length && ![name hasPrefix:@"__"]) _profileNames[dir] = name;
      }
  }
  for (ArcSpace* s in _spaces)  // every profile a Space uses has a name
    if (s.profileDirectory.length && !_profileNames[s.profileDirectory])
      _profileNames[s.profileDirectory] = [s.profileDirectory isEqualToString:@"Default"] ? @"Default" : (s.title ?: s.profileDirectory);
  return _profileNames;
}

- (void)saveProfiles {
  NSString* path = [self profilesPath];
  if (!path) return;
  NSData* data = [NSJSONSerialization dataWithJSONObject:[self profileNames]
                                                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                   error:nil];
  [data writeToFile:path atomically:YES];
}

// Profiles used by a Space first (in Space order), then the rest by name.
- (NSArray<NSString*>*)profileDirectories {
  NSMutableArray* out = [NSMutableArray array];
  for (ArcSpace* s in _spaces)
    if (s.profileDirectory.length && ![out containsObject:s.profileDirectory]) [out addObject:s.profileDirectory];
  NSDictionary* names = [self profileNames];
  NSMutableArray* rest = [NSMutableArray array];
  for (NSString* k in names) if (![out containsObject:k]) [rest addObject:k];
  [rest sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
    return [names[a] localizedCaseInsensitiveCompare:names[b]];
  }];
  [out addObjectsFromArray:rest];
  return out;
}

- (NSString*)nameOfProfile:(NSString*)dir { return [self profileNames][dir] ?: dir; }

- (NSString*)createProfileNamed:(NSString*)name {
  NSMutableDictionary* names = [self profileNames];
  NSString* dir;
  for (NSUInteger n = 1;; ++n) {  // never collides with Arc's "Profile N" folders
    dir = [NSString stringWithFormat:@"NotArc Profile %lu", (unsigned long)n];
    if (!names[dir]) break;
  }
  names[dir] = name.length ? name : @"New Profile";
  [self saveProfiles];
  return dir;
}

- (void)renameProfile:(NSString*)dir to:(NSString*)name {
  if (!dir.length || !name.length) return;
  [self profileNames][dir] = name;
  [self saveProfiles];
}

// Moving a Space to another profile: its pages reload signed in as that profile, and it shows that profile's
// Favorites, as in Arc.
- (void)assignSpace:(ArcSpace*)space toProfile:(NSString*)dir {
  if (!space || !dir.length || [space.profileDirectory isEqualToString:dir]) return;
  BOOL current = space == _space;
  ArcItem* shown = current ? _shown : nil;
  NSArray<ArcItem*>* tabs = [self tabsIn:@[ space.pinned, space.unpinned ]];
  for (ArcItem* t in tabs) if (t.browserId) [self unloadItem:t];
  if (space.favorites) {
    BOOL shared = NO;
    for (ArcSpace* s in _spaces) if (s != space && s.favorites == space.favorites) shared = YES;
    if (!shared) for (ArcItem* t in [self tabsIn:@[ space.favorites ]]) if (t.browserId) [self unloadItem:t];
  }
  space.profileDirectory = dir;
  ArcItem* fav = nil;
  for (ArcSpace* s in _spaces) if (s != space && [s.profileDirectory isEqualToString:dir] && s.favorites) fav = s.favorites;
  space.favorites = fav ?: NewSection(@"Favorites");
  if (![self profileNames][dir]) {
    [self profileNames][dir] = dir;
    [self saveProfiles];
  }
  if (current) {
    [self reloadSidebar];
    if (shown && [tabs containsObject:shown]) {
      _shown = nil;
      [self showItem:shown];
    }
  }
  [self scheduleSave];
}

- (IBAction)assignProfileFromMenu:(NSMenuItem*)sender { [self assignSpace:_space toProfile:sender.representedObject]; }

- (IBAction)newProfileForSpace:(id)sender {
  NSString* name = [self askForSpaceName:@"New Profile" initial:@""];
  if (name.length) [self assignSpace:_space toProfile:[self createProfileNamed:name]];
}

- (IBAction)renameCurrentProfile:(id)sender {
  NSString* dir = _space.profileDirectory;
  NSString* name = [self askForSpaceName:@"Rename Profile" initial:[self nameOfProfile:dir]];
  if (name.length) [self renameProfile:dir to:name];
}

// Space menu > Profile: pick the Space's profile, or make / rename one (Arc: "Edit Space profile").
- (NSMenuItem*)profileMenuItem {
  NSMenuItem* top = [[NSMenuItem alloc] initWithTitle:@"Profile" action:nil keyEquivalent:@""];
  top.submenu = [[NSMenu alloc] initWithTitle:@"Profile"];
  for (NSString* dir in [self profileDirectories]) {
    NSMenuItem* i = [top.submenu addItemWithTitle:[self nameOfProfile:dir] action:@selector(assignProfileFromMenu:) keyEquivalent:@""];
    i.target = self;
    i.representedObject = dir;
    i.state = [dir isEqualToString:_space.profileDirectory] ? NSControlStateValueOn : NSControlStateValueOff;
  }
  [top.submenu addItem:NSMenuItem.separatorItem];
  [top.submenu addItemWithTitle:@"New Profile..." action:@selector(newProfileForSpace:) keyEquivalent:@""].target = self;
  [top.submenu addItemWithTitle:@"Rename Profile..." action:@selector(renameCurrentProfile:) keyEquivalent:@""].target = self;
  return top;
}

- (NSArray<NSString*>*)spaceMenuTitles {  // tests
  NSMutableArray* out = [NSMutableArray array];
  for (NSMenuItem* i in [self spaceMenu].itemArray) if (!i.isSeparatorItem) [out addObject:i.title];
  return out;
}
- (IBAction)showSpaceMenu:(NSButton*)sender {
  [[self spaceMenu] popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, sender.bounds.size.height + 4) inView:sender];
}

- (void)rebuildSpacePicker {
  [self applyTheme];
  [self rebuildSpaceBar];
  [self updateSpaceHeader];
  [_spacePicker removeAllItems];
  for (ArcSpace* s in _spaces) {
    [_spacePicker addItemWithTitle:s.iconEmoji.length ? [NSString stringWithFormat:@"%@  %@", s.iconEmoji, s.title ?: @"Space"]
                                                    : (s.title ?: @"Space")];
    _spacePicker.lastItem.representedObject = s;  // titles may repeat
  }
  if (_space) [_spacePicker selectItemAtIndex:[_spaces indexOfObject:_space]];
}

// Arc lets each Space follow the system or force Light/Dark. Every Arc colour in NotArc is resolved from the view's
// effective appearance, so setting the window's appearance switches the sidebar, rows, pills and command bar together.
- (void)applyColorScheme {
  NSString* cs = _space.colorScheme ?: DefaultSpaceAppearance();  // Settings > Appearance for Spaces that didn't choose
  NSAppearance* ap = [cs isEqualToString:@"light"]  ? [NSAppearance appearanceNamed:NSAppearanceNameAqua]
                     : [cs isEqualToString:@"dark"] ? [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]
                                                    : nil;
  if (self.window.appearance != ap && ![self.window.appearance.name isEqualToString:ap.name]) {
    self.window.appearance = ap;
    _commandBar.appearance = ap;
    _boostPanel.appearance = ap;
    [_outline enumerateAvailableRowViewsUsingBlock:^(NSTableRowView* rv, NSInteger r) { rv.needsDisplay = YES; }];
    _cardEdge.needsDisplay = YES;
  }
}
- (void)setColorScheme:(NSString*)scheme forSpace:(ArcSpace*)space {
  space.colorScheme = [scheme isEqualToString:@"light"] || [scheme isEqualToString:@"dark"] ? scheme : nil;
  if (space == _space) [self applyColorScheme];
  [self scheduleSave];
}
- (IBAction)setSpaceAppearance:(NSMenuItem*)sender { [self setColorScheme:sender.representedObject forSpace:_space]; }
- (BOOL)sidebarIsDark { return IsDark(_sidebarScroll); }  // tests
- (BOOL)sidebarScrollerIsOverlay {  // tests: no track, even after the system asks for the legacy (always shown) style
  _sidebarScroll.scrollerStyle = NSScrollerStyleLegacy;
  return _sidebarScroll.scrollerStyle == NSScrollerStyleOverlay && _sidebarScroll.autohidesScrollers &&
         !_sidebarScroll.hasHorizontalScroller && NSWidth(_outline.frame) <= NSWidth(_sidebarScroll.contentView.bounds);
}

- (void)applyTheme {
  [self applyColorScheme];
  NSMutableArray* cg = [NSMutableArray array];
  for (NSString* hex in _space.themeColors)
    if (NSColor* c = ColorFromHex(hex)) [cg addObject:(id)c.CGColor];
  BOOL fallback = cg.count == 0 && [self usingDefaultTheme];
  if (fallback) {  // Arc's default dark Space
    [cg addObject:(id)ColorFromHex(@"#120C39").CGColor];
    [cg addObject:(id)ColorFromHex(@"#140D40").CGColor];
  }
  _themeView.hidden = cg.count == 0;
  [_outline reloadDataForRowIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, (NSUInteger)_outline.numberOfRows)]
                      columnIndexes:[NSIndexSet indexSetWithIndex:0]];  // tab text colour follows the theme
  if (!cg.count) return;
  if (cg.count == 1) [cg addObject:cg[0]];
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  _themeGradient.colors = cg;
  _themeGradient.opacity = fallback ? 1 : (float)MAX(0.1, MIN(1.0, _space.themeIntensity ?: 0.5));
  _themeGrain.opacity = fallback ? 0 : (float)(MAX(0.0, MIN(1.0, _space.themeGrain)) * kMaxGrainOpacity);
  [CATransaction commit];
}

- (void)setTheme:(NSArray<NSString*>*)colors intensity:(double)intensity forSpace:(ArcSpace*)space {
  space.themeColors = colors.count ? [colors subarrayWithRange:NSMakeRange(0, MIN(colors.count, (NSUInteger)2))] : nil;
  space.themeIntensity = intensity;
  if (space == _space) [self applyTheme];
  [self scheduleSave];
}

- (void)setIcon:(NSString*)emoji forSpace:(ArcSpace*)space {
  NSString* e = [emoji stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (e.length) e = [e substringWithRange:[e rangeOfComposedCharacterSequenceAtIndex:0]];  // one emoji/character
  space.iconEmoji = e.length ? e : nil;
  [self rebuildSpacePicker];
  [self scheduleSave];
}

// Theme editor: preset palettes or two custom colours, plus intensity. Changes preview live; Cancel reverts.
// MARK: Boosts (Arc: per-site colour, font, text size, case, zaps, custom CSS/JS). Stored in Boosts.json.
- (NSMutableArray<Boost*>*)boostList {
  if (!_boosts) _boosts = BoostStoreLoad(BoostStorePath(self.selfTestProfiles));
  return _boosts;
}
- (Boost*)boostForURL:(NSString*)url {
  Boost* best = nil;
  for (Boost* b in [self boostList])
    if ([b matchesURL:url] && (!best || b.host.length > best.host.length)) best = b;  // most specific host wins
  return best;
}
- (void)saveBoosts { BoostStoreSave([self boostList], BoostStorePath(self.selfTestProfiles)); }
- (void)applyBoostToBrowser:(int)browserId url:(NSString*)url {
  auto it = _browsers.find(browserId);
  if (it == _browsers.end()) return;
  Boost* b = [self boostForURL:url];
  static NSMutableSet* boosted;  // browsers that had a Boost, so removing one also cleans the page
  if (!boosted) boosted = [NSMutableSet set];
  if (!b && ![boosted containsObject:@(browserId)]) return;
  if (b) [boosted addObject:@(browserId)]; else [boosted removeObject:@(browserId)];
  CefRefPtr<CefFrame> f = it->second->GetMainFrame();
  f->ExecuteJavaScript(BoostApplyScript(b).UTF8String, f->GetURL(), 0);
}
- (void)applyBoostsEverywhere {
  for (auto& kv : _browsers) [self applyBoostToBrowser:kv.first url:[NSString stringWithUTF8String:kv.second->GetMainFrame()->GetURL().ToString().c_str()]];
  [self updateBoostIndicator];
}
- (Boost*)boostForCurrentSiteCreate:(BOOL)create {
  NSString* url = [self currentURL];
  NSString* host = BoostHostForURL(url);
  if (!host) return nil;
  for (Boost* b in [self boostList]) if ([b.host isEqualToString:host]) return b;
  if (!create) return [self boostForURL:url];
  Boost* b = [Boost new];
  b.host = host;
  [[self boostList] addObject:b];
  [self saveBoosts];
  return b;
}
- (void)boostChanged {
  [self saveBoosts];
  [self applyBoostsEverywhere];
}
// Like Arc: the Boost button is filled and tinted when this site has an active Boost.
- (void)updateBoostIndicator {
  Boost* b = _shown ? [self boostForURL:[self itemCurrentURL:_shown]] : nil;
  BOOL on = b && b.enabled;
  _boostButton.image = [NSImage imageWithSystemSymbolName:on ? @"paintbrush.pointed.fill" : @"paintbrush.pointed"
                                 accessibilityDescription:@"Boost This Site"];
  _boostButton.contentTintColor = on ? (b.hue >= 0 ? [NSColor colorWithHue:fmod(b.hue, 360) / 360 saturation:0.75 brightness:0.95 alpha:1]
                                                    : NSColor.controlAccentColor)
                                     : NSColor.secondaryLabelColor;
  _boostButton.toolTip = on ? @"Boost on: edit Boost" : (b ? @"Boost off: edit Boost" : @"Boost This Site");
  _boostIndicator = on ? @"on" : (b ? @"off" : @"none");
  [self updatePillButtons];
}
// Arc's address pill shows only the site until the pointer is over it; then copy link, site controls (and Boost,
// extensions) appear at its right. A site with a Boost on keeps its Boost button showing.
- (void)updatePillButtons {
  BOOL hover = ((SidebarPillView*)_addressPill).hovered || _pillButtonsForced;
  BOOL boostOn = [_boostIndicator isEqual:@"on"];
  for (NSView* v in _addressPill.subviews)
    if (v.tag == 90) v.alphaValue = hover || (v == _boostButton && boostOn) ? 1 : 0;
}
- (NSString*)pillButtonState {  // tests: how many site buttons show, out of how many
  NSUInteger shown = 0, all = 0;
  for (NSView* v in _addressPill.subviews)
    if (v.tag == 90) {
      ++all;
      if (v.alphaValue > 0.5) ++shown;
    }
  return [NSString stringWithFormat:@"%lu/%lu", (unsigned long)shown, (unsigned long)all];
}
- (void)setPillHoveredForTest:(BOOL)hovered {
  _pillButtonsForced = hovered;
  [self updatePillButtons];
}
- (NSString*)boostIndicatorState { return _boostIndicator ?: @"none"; }  // tests
// Arc's shuffle: a random colour and font for the site.
- (IBAction)shuffleBoost:(id)sender {
  Boost* b = _boostEditing ?: [self boostForCurrentSiteCreate:YES];
  if (!b) { NSBeep(); return; }
  NSArray* fonts = @[ @"Georgia", @"Helvetica Neue", @"Avenir Next", @"Menlo", @"Futura", @"Arial Rounded MT Bold", @"Gill Sans" ];
  double old = b.hue;
  do { b.hue = arc4random_uniform(360); } while (fabs(b.hue - old) < 30);
  b.saturation = 0.6 + arc4random_uniform(41) / 100.0;
  b.colorStrength = 0.5 + arc4random_uniform(40) / 100.0;
  b.font = fonts[arc4random_uniform((uint32_t)fonts.count)];
  b.enabled = YES;
  [self boostChanged];
  [self refreshBoostPanel];
}

// Tests / scripting.
- (Boost*)setBoostForHost:(NSString*)host configure:(void (^)(Boost*))configure {
  Boost* b = nil;
  for (Boost* x in [self boostList]) if ([x.host isEqualToString:host]) b = x;
  if (!b) { b = [Boost new]; b.host = host; [[self boostList] addObject:b]; }
  if (configure) configure(b);
  [self boostChanged];
  return b;
}
- (void)deleteBoostForHost:(NSString*)host {
  NSMutableArray* list = [self boostList];
  for (Boost* b in [list copy]) if ([b.host isEqualToString:host]) [list removeObject:b];
  [self boostChanged];
}
- (NSUInteger)savedBoostCount { return BoostStoreLoad(BoostStorePath(self.selfTestProfiles)).count; }

- (IBAction)zapElements:(id)sender {
  auto it = _browsers.find(_shown.browserId);
  if (!_shown || it == _browsers.end() || !BoostHostForURL([self currentURL])) { NSBeep(); return; }
  _zapBrowser = _shown.browserId;
  CefRefPtr<CefFrame> f = it->second->GetMainFrame();
  f->ExecuteJavaScript(BoostZapModeScript().UTF8String, f->GetURL(), 0);
  [self showToast:@"Click an element to zap it, Option-click to zap all like it. Esc cancels." action:nil selector:nil];
}
- (void)handleZapSelector:(NSString*)selector browser:(int)browserId {
  if (!selector.length) return;  // cancelled
  ArcItem* item = [self itemForBrowserId:browserId];
  NSString* host = BoostHostForURL(item.url);
  if (!host) return;
  Boost* b = nil;
  for (Boost* x in [self boostList]) if ([x.host isEqualToString:host]) b = x;
  if (!b) { b = [Boost new]; b.host = host; [[self boostList] addObject:b]; }
  b.enabled = YES;
  if (![b.zaps containsObject:selector]) [b.zaps addObject:selector];
  [self boostChanged];
  [self refreshBoostPanel];
}
- (IBAction)toggleBoost:(id)sender {
  Boost* b = [self boostForCurrentSiteCreate:NO];
  if (!b) { NSBeep(); return; }
  b.enabled = !b.enabled;
  [self boostChanged];
  [self refreshBoostPanel];
}

// Editor: a floating panel, live preview on every change, like Arc's Boost editor shelf.
- (IBAction)editBoost:(id)sender {
  Boost* b = [self boostForCurrentSiteCreate:YES];
  if (!b) { NSBeep(); return; }
  _boostEditing = b;
  if (!_boostPanel) [self buildBoostPanel];
  [self refreshBoostPanel];
  NSRect wf = self.window.frame;
  [_boostPanel setFrameTopLeftPoint:NSMakePoint(NSMaxX(wf) - _boostPanel.frame.size.width - 24, NSMaxY(wf) - 60)];
  if (!self.selfTestProfiles) [_boostPanel orderFront:nil];
}
// Arc's Boost editor look: a compact rounded card (no title bar) with a header (name, Shuffle, menu, on/off),
// the colour wheel and Intensity slider on top, then font tiles, then text size, case, Zap and Code tiles.
// Colours come from NotArc's Arc palette and follow the window's light/dark appearance.
static NSArray<NSArray<NSString*>*>* BoostFontChoices() {
  // value ("" = the page's own font), short name
  return @[ @[ @"", @"Page" ], @[ @"-apple-system", @"System" ], @[ @"Georgia", @"Georgia" ], @[ @"Helvetica Neue", @"Helvetica" ],
            @[ @"Avenir Next", @"Avenir" ], @[ @"Menlo", @"Menlo" ], @[ @"Times New Roman", @"Times" ], @[ @"Futura", @"Futura" ],
            @[ @"Gill Sans", @"Gill Sans" ], @[ @"Arial Rounded MT Bold", @"Rounded" ] ];
}
static NSArray<NSNumber*>* BoostZoomSteps() { return @[ @0.8, @0.9, @1.0, @1.1, @1.25, @1.5, @1.75 ]; }
- (void)buildBoostPanel {
  const CGFloat W = 280, M = 12, H = 462;
  _boostControls = [NSMutableDictionary dictionary];
  _boostPanel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, W, H)
                                           styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                     NSWindowStyleMaskFullSizeContentView
                                             backing:NSBackingStoreBuffered defer:YES];
  _boostPanel.titlebarAppearsTransparent = YES;
  _boostPanel.titleVisibility = NSWindowTitleHidden;
  for (NSWindowButton wb : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton})
    [_boostPanel standardWindowButton:wb].hidden = YES;
  _boostPanel.movableByWindowBackground = YES;
  _boostPanel.backgroundColor = NSColor.clearColor;
  _boostPanel.opaque = NO;
  _boostPanel.hasShadow = YES;
  _boostPanel.floatingPanel = YES;
  _boostPanel.releasedWhenClosed = NO;
  _boostPanel.hidesOnDeactivate = YES;
  NSVisualEffectView* card = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
  card.material = NSVisualEffectMaterialPopover;
  card.state = NSVisualEffectStateActive;
  card.wantsLayer = YES;
  card.layer.cornerRadius = 14;
  card.layer.masksToBounds = YES;
  card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [_boostPanel.contentView addSubview:card];
  NSView* v = card;
  CGFloat y = H - 10;

  // Header: the site's name, Shuffle, a menu (original colours, delete), the on/off switch and close.
  y -= 28;
  NSView* header = [[NSView alloc] initWithFrame:NSMakeRect(M, y, W - 2 * M, 28)];
  header.identifier = @"header";
  [v addSubview:header];
  NSTextField* title = [NSTextField labelWithString:@""];
  title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  title.textColor = [NSColor.labelColor colorWithAlphaComponent:0.85];
  title.lineBreakMode = NSLineBreakByTruncatingTail;
  title.frame = NSMakeRect(2, 5, header.bounds.size.width - 136, 18);
  [header addSubview:title];
  _boostControls[@"title"] = title;
  NSButton* (^corner)(NSString*, NSString*, SEL) = ^NSButton*(NSString* sym, NSString* tip, SEL sel) {
    NSButton* bt = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:sym accessibilityDescription:tip] target:self action:sel];
    bt.bordered = NO;
    bt.toolTip = tip;
    bt.contentTintColor = NSColor.secondaryLabelColor;
    return bt;
  };
  NSButton* shuffle = corner(@"shuffle", @"Shuffle", @selector(shuffleBoost:));
  shuffle.frame = NSMakeRect(header.bounds.size.width - 130, 2, 26, 24);
  [header addSubview:shuffle];
  NSButton* more = corner(@"ellipsis.circle", @"More", @selector(showBoostMenu:));
  more.frame = NSMakeRect(header.bounds.size.width - 102, 2, 26, 24);
  [header addSubview:more];
  NSSwitch* on = [[NSSwitch alloc] initWithFrame:NSMakeRect(header.bounds.size.width - 72, 3, 40, 22)];
  on.controlSize = NSControlSizeSmall;
  on.target = self;
  on.action = @selector(boostControlChanged:);
  on.toolTip = @"Turn this Boost on or off";
  [header addSubview:on];
  _boostControls[@"enabled"] = on;
  NSButton* close = corner(@"xmark.circle.fill", @"Close", @selector(closeBoostPanel:));
  close.frame = NSMakeRect(header.bounds.size.width - 26, 2, 26, 24);
  [header addSubview:close];

  // Colour: the wheel (hue around, saturation toward the centre) and the Intensity slider.
  y -= 8 + 216 + 4 + 22;
  NSView* color = [[NSView alloc] initWithFrame:NSMakeRect(M, y, W - 2 * M, 216 + 4 + 22)];
  color.identifier = @"color";
  [v addSubview:color];
  BoostColorWheel* wheel = [[BoostColorWheel alloc] initWithFrame:NSMakeRect((color.bounds.size.width - 216) / 2, 26, 216, 216)];
  __weak MainWindowController* weakSelf = self;
  wheel.onChange = ^(BoostColorWheel* w, BOOL final) { [weakSelf boostWheelChanged:w final:final]; };
  [color addSubview:wheel];
  _boostWheel = wheel;
  NSButton* reset = corner(@"arrow.counterclockwise", @"Original colours", @selector(resetBoostColor:));
  reset.frame = NSMakeRect(0, 0, 24, 22);
  [color addSubview:reset];
  NSImageView* dim = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"sun.min" accessibilityDescription:nil]];
  dim.frame = NSMakeRect(30, 2, 18, 18);
  dim.contentTintColor = NSColor.tertiaryLabelColor;
  [color addSubview:dim];
  NSSlider* strength = [NSSlider sliderWithValue:0.6 minValue:0.1 maxValue:1 target:self action:@selector(boostControlChanged:)];
  strength.frame = NSMakeRect(52, 0, color.bounds.size.width - 52 - 26, 22);
  strength.continuous = YES;
  strength.controlSize = NSControlSizeSmall;
  strength.toolTip = @"Intensity";
  [color addSubview:strength];
  _boostControls[@"strength"] = strength;
  NSImageView* bright = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:nil]];
  bright.frame = NSMakeRect(color.bounds.size.width - 20, 2, 18, 18);
  bright.contentTintColor = NSColor.tertiaryLabelColor;
  [color addSubview:bright];

  // Fonts: two rows of sample tiles.
  y -= 12 + 84;
  NSView* fonts = [[NSView alloc] initWithFrame:NSMakeRect(M, y, W - 2 * M, 84)];
  fonts.identifier = @"font";
  [v addSubview:fonts];
  NSArray* choices = BoostFontChoices();
  CGFloat tw = (fonts.bounds.size.width - 4 * 4) / 5;
  for (NSUInteger i = 0; i < choices.count; i++) {
    NSString* family = choices[i][0];
    BoostTile* t = [[BoostTile alloc] initWithFrame:NSMakeRect((i % 5) * (tw + 4), i < 5 ? 44 : 0, tw, 40)];
    t.title = @"Aa";
    NSFont* f = family.length && ![family hasPrefix:@"-"] ? [NSFont fontWithName:family size:16] : nil;
    t.titleFont = f ?: [NSFont systemFontOfSize:16 weight:i == 0 ? NSFontWeightRegular : NSFontWeightMedium];
    t.subtitle = choices[i][1];
    t.value = family;
    t.toolTip = i == 0 ? @"The page's own font" : choices[i][0];
    t.target = self;
    t.action = @selector(boostFontPicked:);
    [fonts addSubview:t];
    _boostControls[[@"font:" stringByAppendingString:choices[i][1]]] = t;
  }

  // Text size, case, Zap, Code.
  y -= 8 + 58;
  CGFloat qw = (W - 2 * M - 3 * 4) / 4;
  BoostTile* size = [[BoostTile alloc] initWithFrame:NSMakeRect(M, y, qw, 58)];
  size.identifier = @"size";
  size.subtitle = @"100%";
  size.toolTip = @"Change text size";
  [v addSubview:size];
  _boostControls[@"zoom"] = size;
  // A small A and a big A step the text size down and up; the percentage shows underneath.
  NSButton* smaller = corner(@"textformat.size.smaller", @"Smaller text", @selector(boostZoomStep:));
  smaller.tag = -1;
  smaller.frame = NSMakeRect(qw / 2 - 26, 22, 24, 26);
  [size addSubview:smaller];
  NSButton* bigger = corner(@"textformat.size.larger", @"Bigger text", @selector(boostZoomStep:));
  bigger.tag = 1;
  bigger.frame = NSMakeRect(qw / 2 + 2, 22, 24, 26);
  [size addSubview:bigger];
  for (NSButton* bt in @[ smaller, bigger ]) {
    bt.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium];
    bt.contentTintColor = [NSColor.labelColor colorWithAlphaComponent:0.8];
  }
  BoostTile* tcase = [[BoostTile alloc] initWithFrame:NSMakeRect(M + (qw + 4), y, qw, 58)];
  tcase.identifier = @"case";
  tcase.titleFont = [NSFont systemFontOfSize:16 weight:NSFontWeightMedium];
  tcase.toolTip = @"Change text case";
  tcase.target = self;
  tcase.action = @selector(boostCaseCycled:);
  [v addSubview:tcase];
  _boostControls[@"case"] = tcase;
  BoostTile* zap = [[BoostTile alloc] initWithFrame:NSMakeRect(M + 2 * (qw + 4), y, qw, 58)];
  zap.identifier = @"zap";
  zap.symbolName = @"bolt.fill";
  zap.toolTip = @"Zap: click an element on the page to hide it (Option-click hides all like it)";
  zap.target = self;
  zap.action = @selector(boostZapTile:);
  [v addSubview:zap];
  _boostControls[@"zap"] = zap;
  BoostTile* code = [[BoostTile alloc] initWithFrame:NSMakeRect(M + 3 * (qw + 4), y, qw, 58)];
  code.identifier = @"code";
  code.symbolName = @"chevron.left.forwardslash.chevron.right";
  code.toolTip = @"Custom CSS and JavaScript for this site";
  code.target = self;
  code.action = @selector(boostCodeTile:);
  [v addSubview:code];
  _boostControls[@"code"] = code;
}
- (void)refreshBoostPanel {
  if (!_boostPanel || !_boostEditing) return;
  Boost* b = _boostEditing;
  _boostPanel.title = [NSString stringWithFormat:@"Boost: %@", b.host];
  ((NSTextField*)_boostControls[@"title"]).stringValue = b.host ?: @"";
  ((NSSwitch*)_boostControls[@"enabled"]).state = b.enabled ? NSControlStateValueOn : NSControlStateValueOff;
  [_boostWheel setHue:MAX(0, b.hue) saturation:b.saturation];
  _boostWheel.hasColor = b.hue >= 0;
  _boostWheel.intensity = b.colorStrength;
  ((NSSlider*)_boostControls[@"strength"]).doubleValue = b.colorStrength;
  for (NSArray* c in BoostFontChoices()) {
    BoostTile* t = (BoostTile*)_boostControls[[@"font:" stringByAppendingString:c[1]]];
    t.selected = [c[0] length] ? [b.font isEqualToString:c[0]] : b.font.length == 0;
  }
  BoostTile* size = (BoostTile*)_boostControls[@"zoom"];
  size.subtitle = [NSString stringWithFormat:@"%.0f%%", (b.textZoom > 0 ? b.textZoom : 1) * 100];
  BoostTile* tcase = (BoostTile*)_boostControls[@"case"];
  NSString* tt = b.textTransform;
  tcase.title = [tt isEqualToString:@"uppercase"] ? @"AA" : [tt isEqualToString:@"lowercase"] ? @"aa" : [tt isEqualToString:@"capitalize"] ? @"Aa Bb" : @"Aa";
  tcase.subtitle = [tt isEqualToString:@"uppercase"] ? @"Upper" : [tt isEqualToString:@"lowercase"] ? @"Lower" : [tt isEqualToString:@"capitalize"] ? @"Title" : @"Case";
  tcase.selected = tt.length > 0;
  BoostTile* zap = (BoostTile*)_boostControls[@"zap"];
  zap.subtitle = b.zaps.count ? [NSString stringWithFormat:@"%lu Zapped", (unsigned long)b.zaps.count] : @"Zap";
  BoostTile* code = (BoostTile*)_boostControls[@"code"];
  code.subtitle = b.css.length && b.js.length ? @"CSS + JS" : b.css.length ? @"CSS" : b.js.length ? @"JS" : @"Code";
  code.selected = b.css.length || b.js.length;
}
- (void)boostControlChanged:(id)sender {
  Boost* b = _boostEditing;
  if (!b) return;
  b.enabled = ((NSSwitch*)_boostControls[@"enabled"]).state == NSControlStateValueOn;
  b.colorStrength = ((NSSlider*)_boostControls[@"strength"]).doubleValue;
  _boostWheel.intensity = b.colorStrength;
  // While the slider is being dragged, only preview; save when it's let go.
  if (sender == _boostControls[@"strength"] && NSApp.currentEvent.type == NSEventTypeLeftMouseDragged) [self applyBoostsEverywhere];
  else [self boostChanged];
}
// Dragging the wheel previews live on the page; letting go (or a programmatic pick) saves.
- (void)boostWheelChanged:(BoostColorWheel*)wheel final:(BOOL)final {
  Boost* b = _boostEditing;
  if (!b) return;
  b.hue = wheel.hue;
  b.saturation = wheel.saturation;
  b.enabled = YES;
  ((NSSwitch*)_boostControls[@"enabled"]).state = NSControlStateValueOn;
  if (final) [self boostChanged]; else [self applyBoostsEverywhere];
}
- (IBAction)resetBoostColor:(id)sender {
  if (!_boostEditing) return;
  _boostEditing.hue = -1;
  [self boostChanged];
  [self refreshBoostPanel];
}
- (void)boostFontPicked:(BoostTile*)tile {
  if (!_boostEditing) return;
  _boostEditing.font = tile.value.length ? tile.value : nil;
  _boostEditing.enabled = YES;
  [self boostChanged];
  [self refreshBoostPanel];
}
- (void)boostZoomStep:(NSButton*)sender {
  Boost* b = _boostEditing;
  if (!b) return;
  NSArray* steps = BoostZoomSteps();
  NSUInteger i = 0;
  double best = 1e9;
  for (NSUInteger k = 0; k < steps.count; k++)
    if (fabs([steps[k] doubleValue] - b.textZoom) < best) best = fabs([steps[k] doubleValue] - b.textZoom), i = k;
  NSInteger n = MAX(0, MIN((NSInteger)steps.count - 1, (NSInteger)i + sender.tag));
  b.textZoom = [steps[(NSUInteger)n] doubleValue];
  [self boostChanged];
  [self refreshBoostPanel];
}
- (void)boostCaseCycled:(id)sender {
  Boost* b = _boostEditing;
  if (!b) return;
  NSArray* order = @[ @"", @"uppercase", @"lowercase", @"capitalize" ];
  NSUInteger i = [order indexOfObject:b.textTransform ?: @""];
  NSString* next = order[(i == NSNotFound ? 0 : i + 1) % order.count];
  b.textTransform = next.length ? next : nil;
  [self boostChanged];
  [self refreshBoostPanel];
}
- (void)popUpBoostMenu:(NSMenu*)menu from:(NSView*)view {
  if (self.selfTestProfiles) return;  // never block a test run on a menu
  [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, -4) inView:view];
}
- (void)boostZapTile:(BoostTile*)tile {
  if (!_boostEditing.zaps.count) { [self zapElements:tile]; return; }
  NSMenu* m = [NSMenu new];
  [m addItemWithTitle:@"Zap an Element" action:@selector(zapElements:) keyEquivalent:@""].target = self;
  [m addItemWithTitle:[NSString stringWithFormat:@"Clear Zaps (%lu)", (unsigned long)_boostEditing.zaps.count]
               action:@selector(clearZaps:) keyEquivalent:@""].target = self;
  [self popUpBoostMenu:m from:tile];
}
- (void)boostCodeTile:(BoostTile*)tile {
  NSMenu* m = [NSMenu new];
  [m addItemWithTitle:@"Edit CSS…" action:@selector(editBoostCSS:) keyEquivalent:@""].target = self;
  [m addItemWithTitle:@"Edit JavaScript…" action:@selector(editBoostJS:) keyEquivalent:@""].target = self;
  [self popUpBoostMenu:m from:tile];
}
- (void)showBoostMenu:(NSButton*)sender {
  NSMenu* m = [NSMenu new];
  [m addItemWithTitle:@"Shuffle" action:@selector(shuffleBoost:) keyEquivalent:@""].target = self;
  [m addItemWithTitle:@"Original Colours" action:@selector(resetBoostColor:) keyEquivalent:@""].target = self;
  [m addItem:NSMenuItem.separatorItem];
  [m addItemWithTitle:@"Delete Boost" action:@selector(deleteCurrentBoost:) keyEquivalent:@""].target = self;
  [self popUpBoostMenu:m from:sender];
}
- (IBAction)closeBoostPanel:(id)sender { [_boostPanel orderOut:nil]; }
// Tests.
- (BoostColorWheel*)boostColorWheel { return _boostWheel; }
- (Boost*)boostBeingEdited { return _boostEditing; }
- (void)setBoostIntensity:(double)value {
  ((NSSlider*)_boostControls[@"strength"]).doubleValue = value;
  [self boostControlChanged:_boostControls[@"strength"]];
}
- (BOOL)pickBoostFontTile:(NSString*)name {
  BoostTile* t = (BoostTile*)_boostControls[[@"font:" stringByAppendingString:name]];
  if (![t isKindOfClass:BoostTile.class]) return NO;
  [self boostFontPicked:t];
  return YES;
}
// The editor's sections, top to bottom then left to right (identifiers: header, color, font, size, case, zap, code).
- (NSArray<NSString*>*)boostPanelSections {
  NSMutableArray<NSView*>* found = [NSMutableArray array];
  NSMutableArray<NSView*>* stack = [NSMutableArray arrayWithObject:_boostPanel.contentView ?: [NSView new]];
  while (stack.count) {
    NSView* x = stack.lastObject;
    [stack removeLastObject];
    if (x.identifier.length && ![x.identifier hasPrefix:@"_"] && x != _boostPanel.contentView) [found addObject:x];
    [stack addObjectsFromArray:x.subviews];
  }
  [found sortUsingComparator:^NSComparisonResult(NSView* p, NSView* q) {
    NSRect a = [p convertRect:p.bounds toView:nil], c = [q convertRect:q.bounds toView:nil];
    if (fabs(NSMaxY(a) - NSMaxY(c)) > 1) return NSMaxY(a) > NSMaxY(c) ? NSOrderedAscending : NSOrderedDescending;
    return NSMinX(a) < NSMinX(c) ? NSOrderedAscending : NSOrderedDescending;
  }];
  NSMutableArray* ids = [NSMutableArray array];
  for (NSView* x in found) [ids addObject:x.identifier];
  return ids;
}
- (IBAction)clearZaps:(id)sender {
  [_boostEditing.zaps removeAllObjects];
  [self boostChanged];
  [self refreshBoostPanel];
}
- (void)editBoostCode:(BOOL)js {
  Boost* b = _boostEditing ?: [self boostForCurrentSiteCreate:YES];
  if (!b) return;
  NSAlert* a = [NSAlert new];
  a.messageText = js ? [NSString stringWithFormat:@"JavaScript for %@", b.host] : [NSString stringWithFormat:@"CSS for %@", b.host];
  a.informativeText = js ? @"Runs on every page of this site after it loads." : @"Added to every page of this site.";
  NSScrollView* sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 420, 220)];
  sv.hasVerticalScroller = YES;
  NSTextView* tv = [[NSTextView alloc] initWithFrame:sv.bounds];
  tv.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];
  tv.automaticQuoteSubstitutionEnabled = NO;
  tv.automaticDashSubstitutionEnabled = NO;
  tv.string = (js ? b.js : b.css) ?: @"";
  sv.documentView = tv;
  a.accessoryView = sv;
  [a addButtonWithTitle:@"Save"];
  [a addButtonWithTitle:@"Cancel"];
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    if (js) b.js = tv.string; else b.css = tv.string;
    b.enabled = YES;
    [self boostChanged];
    [self refreshBoostPanel];
  }];
}
- (IBAction)editBoostCSS:(id)sender { [self editBoostCode:NO]; }
- (IBAction)editBoostJS:(id)sender { [self editBoostCode:YES]; }
- (IBAction)deleteCurrentBoost:(id)sender {
  Boost* b = _boostEditing ?: [self boostForCurrentSiteCreate:NO];
  if (!b) return;
  [[self boostList] removeObject:b];
  _boostEditing = nil;
  [_boostPanel orderOut:nil];
  [self boostChanged];
}

- (void)setThemeGrain:(double)grain forSpace:(ArcSpace*)space {
  space.themeGrain = MAX(0.0, MIN(1.0, grain));
  if (space == _space) [self applyTheme];
  [self scheduleSave];
}
- (float)themeGrainOpacity { return _themeView.hidden ? 0 : _themeGrain.opacity; }  // tests

- (IBAction)editThemeColor:(id)sender {
  ArcSpace* space = _space;
  if (!space) return;
  NSArray* oldColors = space.themeColors;
  double oldIntensity = space.themeIntensity;
  double oldGrain = space.themeGrain;
  NSArray* presets = @[
    @[ @"None", @[] ], @[ @"Lavender", @[ @"#B9A8FF", @"#8B7CF6" ] ], @[ @"Ocean", @[ @"#5EC8F2", @"#2F6FDE" ] ],
    @[ @"Mint", @[ @"#9BF0C9", @"#3BB58A" ] ], @[ @"Peach", @[ @"#FFC3A0", @"#FF7A7A" ] ],
    @[ @"Sunset", @[ @"#FFB347", @"#E84A7F" ] ], @[ @"Forest", @[ @"#7FB77E", @"#2E5E3E" ] ],
    @[ @"Graphite", @[ @"#8E8E93", @"#3A3A3C" ] ], @[ @"Rose", @[ @"#FFB3C7", @"#D9468F" ] ],
    @[ @"Custom", @[] ]
  ];
  NSAlert* a = [NSAlert new];
  a.messageText = [NSString stringWithFormat:@"Edit Theme Color: %@", space.title ?: @"Space"];
  NSView* box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 96)];
  NSTextField* grainLabel = [NSTextField labelWithString:@"Grain"];
  grainLabel.frame = NSMakeRect(0, 6, 70, 20);
  NSSlider* grain = [NSSlider sliderWithValue:oldGrain minValue:0 maxValue:1 target:self action:@selector(themeControlChanged:)];
  grain.frame = NSMakeRect(74, 4, 212, 24);
  grain.continuous = YES;
  [box addSubview:grainLabel];
  [box addSubview:grain];
  NSPopUpButton* palette = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 68, 180, 26) pullsDown:NO];
  for (NSArray* p in presets) [palette addItemWithTitle:p[0]];
  NSColorWell* top = [[NSColorWell alloc] initWithFrame:NSMakeRect(190, 68, 44, 26)];
  NSColorWell* bottom = [[NSColorWell alloc] initWithFrame:NSMakeRect(242, 68, 44, 26)];
  top.color = ColorFromHex(oldColors.firstObject) ?: [NSColor colorWithSRGBRed:0.73 green:0.66 blue:1 alpha:1];
  bottom.color = ColorFromHex(oldColors.lastObject) ?: top.color;
  NSTextField* label = [NSTextField labelWithString:@"Intensity"];
  label.frame = NSMakeRect(0, 36, 70, 20);
  NSSlider* intensity = [NSSlider sliderWithValue:(oldColors.count ? oldIntensity : 0.5) minValue:0.1 maxValue:1 target:nil action:nil];
  intensity.frame = NSMakeRect(74, 34, 212, 24);
  NSInteger sel = oldColors.count ? presets.count - 1 : 0;
  for (NSUInteger i = 1; i + 1 < presets.count; ++i)
    if ([presets[i][1] isEqualToArray:oldColors ?: @[]]) sel = i;
  [palette selectItemAtIndex:sel];
  for (NSView* v in @[ palette, top, bottom, label, intensity ]) [box addSubview:v];
  a.accessoryView = box;
  [a addButtonWithTitle:@"Done"];
  [a addButtonWithTitle:@"Cancel"];
  __weak MainWindowController* weakSelf = self;
  __block BOOL fromPreset = NO;
  void (^preview)(void) = ^{
    NSInteger i = palette.indexOfSelectedItem;
    NSArray* colors = presets[i][1];
    if (i == (NSInteger)presets.count - 1) colors = @[ HexFromColor(top.color) ?: @"#B9A8FF", HexFromColor(bottom.color) ?: @"#8B7CF6" ];
    else if (colors.count && !fromPreset) {
      fromPreset = YES;
      top.color = ColorFromHex(colors[0]);
      bottom.color = ColorFromHex(colors[1]);
      fromPreset = NO;
    }
    [weakSelf setTheme:colors intensity:intensity.doubleValue forSpace:space];
    [weakSelf setThemeGrain:grain.doubleValue forSpace:space];
  };
  _themePreview = [preview copy];
  palette.target = self;
  palette.action = @selector(themeControlChanged:);
  intensity.target = self;
  intensity.action = @selector(themeControlChanged:);
  intensity.continuous = YES;
  for (NSColorWell* w in @[ top, bottom ]) {
    w.target = self;
    w.action = @selector(themeWellChanged:);
  }
  _themePalette = palette;
  if ([a runModal] != NSAlertFirstButtonReturn) {
    [self setTheme:oldColors intensity:oldIntensity forSpace:space];
    [self setThemeGrain:oldGrain forSpace:space];
  }
  _themePreview = nil;
  _themePalette = nil;
  [NSColorPanel.sharedColorPanel orderOut:nil];
}

- (void)themeControlChanged:(id)sender { if (_themePreview) _themePreview(); }
- (void)themeWellChanged:(id)sender {
  [_themePalette selectItemAtIndex:_themePalette.numberOfItems - 1];  // touching a colour = Custom
  if (_themePreview) _themePreview();
}

- (IBAction)changeSpaceIcon:(id)sender {
  ArcSpace* space = _space;
  if (!space) return;
  NSAlert* a = [NSAlert new];
  a.messageText = @"Change Space Icon";
  a.informativeText = @"Type or paste an emoji (Ctrl+Cmd+Space opens the emoji picker). Leave empty for no icon.";
  NSTextField* f = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 80, 28)];
  f.font = [NSFont systemFontOfSize:18];
  f.stringValue = space.iconEmoji ?: @"";
  a.accessoryView = f;
  a.window.initialFirstResponder = f;
  [a addButtonWithTitle:@"Done"];
  [a addButtonWithTitle:@"Cancel"];
  if ([a runModal] == NSAlertFirstButtonReturn) [self setIcon:f.stringValue forSpace:space];
}

// Arc slides the sidebar sideways when switching Spaces (next Space comes in from the right), and the page card
// "pops" (a quick scale-in) when its contents change. Both are skipped when Reduce Motion is on.
static BOOL ReduceMotion() { return NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion; }
- (void)slideSidebarFromRight:(BOOL)fromRight {
  _lastSpaceSlide = ReduceMotion() ? @"none" : (fromRight ? @"right" : @"left");
  if (ReduceMotion()) return;
  _sidebarScroll.wantsLayer = YES;
  CATransition* t = [CATransition animation];
  t.type = kCATransitionPush;
  t.subtype = fromRight ? kCATransitionFromRight : kCATransitionFromLeft;
  t.duration = 0.22;
  t.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
  [_sidebarScroll.layer addAnimation:t forKey:@"spaceSlide"];
  [_spaceHeader.layer ?: (_spaceHeader.wantsLayer = YES, _spaceHeader.layer) addAnimation:[t copy] forKey:@"spaceSlide"];
}
- (void)popPageCard {
  if (ReduceMotion() || _sidebar.hidden) return;
  ++_cardPops;
  CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"opacity"];
  a.fromValue = @0.85;
  a.toValue = @1.0;
  a.duration = 0.18;
  [_content.layer addAnimation:a forKey:@"pop"];
  CASpringAnimation* sc = [CASpringAnimation animationWithKeyPath:@"transform.scale"];
  sc.fromValue = @0.985;
  sc.toValue = @1.0;
  sc.damping = 18;
  sc.stiffness = 300;
  sc.duration = sc.settlingDuration;
  [_content.layer addAnimation:sc forKey:@"popScale"];
}
- (NSString*)lastSpaceSlide { return _lastSpaceSlide ?: @""; }
- (NSUInteger)cardPopCount { return _cardPops; }

- (void)switchToSpace:(ArcSpace*)space {
  [self hideLibrary];
  _todayHeaderHovered = NO;  // the Library closes when you pick a Space, as with Back
  if (!space || space == _space) return;
  [_extensionPopup closeBecause:@"space"];  // the popup runs in the old Space's profile
  NSUInteger from = _space ? [_spaces indexOfObject:_space] : 0, to = [_spaces indexOfObject:space];
  [self slideSidebarFromRight:to > from];
  _space = space;
  _splitItems = nil;
  [_spacePicker selectItemAtIndex:[_spaces indexOfObject:space]];
  [self reloadSidebar];
  [self applyTheme];
  [self rebuildSpaceBar];
  [self updateSpaceHeader];
  [self scheduleSave];
  ArcItem* first = [self lastShownInSpace:_space];
  if (first) [self showItem:first];
  else {
    _shown = nil;
    [self layoutPanes];
  }
}

- (void)selectSpaceAtIndex:(NSUInteger)index {
  if (index < _spaces.count) [self switchToSpace:_spaces[index]];
}

- (NSArray<ArcSpace*>*)spaces { return _spaces; }
- (ArcSpace*)currentSpace { return _space; }

// A new Space shares the current Space's profile, so it starts signed in to the same accounts
// (and shows the same Favorites), like Arc's default.
- (ArcSpace*)createSpaceNamed:(NSString*)name {
  ArcSpace* space = [ArcSpace new];
  space.spaceID = NSUUID.UUID.UUIDString;
  space.title = name.length ? name : @"New Space";
  space.profileDirectory = _space.profileDirectory ?: @"Default";
  space.pinned = NewSection(@"Pinned");
  space.unpinned = NewSection(@"Today");
  for (ArcSpace* s in _spaces)
    if ([s.profileDirectory isEqualToString:space.profileDirectory] && s.favorites) space.favorites = s.favorites;
  NSUInteger at = _space ? [_spaces indexOfObject:_space] + 1 : _spaces.count;
  [_spaces insertObject:space atIndex:at];
  [self rebuildSpacePicker];
  [self switchToSpace:space];
  [self scheduleSave];
  return space;
}

- (void)renameSpace:(ArcSpace*)space to:(NSString*)name {
  if (!space || !name.length) return;
  space.title = name;
  [self rebuildSpacePicker];
  [self scheduleSave];
}

// Deleting a Space archives its Today and Pinned tabs (nothing is lost) and closes their web views.
- (BOOL)deleteSpace:(ArcSpace*)space {
  if (!space || _spaces.count < 2) return NO;
  NSUInteger index = [_spaces indexOfObject:space];
  if (index == NSNotFound) return NO;
  NSMutableArray<ArcItem*>* owned = [NSMutableArray array];
  NSMutableArray<ArcItem*>* stack = [NSMutableArray arrayWithObjects:space.pinned, space.unpinned, nil];
  while (stack.count) {
    ArcItem* item = stack.lastObject;
    [stack removeLastObject];
    if (item.url.length) [owned addObject:item];
    [stack addObjectsFromArray:item.children];
  }
  for (ArcItem* item in owned) {
    [self archiveItem:item space:space reason:@"spaceDeleted"];
    [self unloadItem:item];
  }
  [_spaces removeObjectAtIndex:index];
  if (space == _space) {
    _space = nil;
    _shown = nil;
    [self rebuildSpacePicker];
    [self switchToSpace:_spaces[MIN(index, _spaces.count - 1)]];
  } else {
    [self rebuildSpacePicker];
  }
  [self scheduleSave];
  return YES;
}

- (void)moveSpace:(ArcSpace*)space by:(NSInteger)delta {
  NSInteger from = [_spaces indexOfObject:space];
  NSInteger to = from + delta;
  if (from == NSNotFound || to < 0 || to >= (NSInteger)_spaces.count) return;
  [_spaces removeObjectAtIndex:from];
  [_spaces insertObject:space atIndex:to];
  [self rebuildSpacePicker];
  [self scheduleSave];
}

- (NSString*)askForSpaceName:(NSString*)message initial:(NSString*)initial {
  NSAlert* alert = [NSAlert new];
  alert.messageText = message;
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
  field.stringValue = initial ?: @"";
  alert.accessoryView = field;
  alert.window.initialFirstResponder = field;
  if ([alert runModal] != NSAlertFirstButtonReturn) return nil;
  return [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

- (IBAction)newSpace:(id)sender {
  NSString* name = [self askForSpaceName:@"New Space" initial:@""];
  if (name) [self createSpaceNamed:name];
}

- (IBAction)renameCurrentSpace:(id)sender {
  NSString* name = [self askForSpaceName:@"Rename Space" initial:_space.title];
  if (name.length) [self renameSpace:_space to:name];
}

- (IBAction)deleteCurrentSpace:(id)sender {
  if (_spaces.count < 2) {
    NSBeep();
    return;
  }
  NSAlert* alert = [NSAlert new];
  alert.messageText = [NSString stringWithFormat:@"Delete \u201c%@\u201d?", _space.title];
  alert.informativeText = @"Its tabs move to the Archive, so you can reopen them later.";
  [alert addButtonWithTitle:@"Delete"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.buttons.firstObject.hasDestructiveAction = YES;
  if ([alert runModal] == NSAlertFirstButtonReturn) [self deleteSpace:_space];
}

- (IBAction)moveSpaceUp:(id)sender { [self moveSpace:_space by:-1]; }
- (IBAction)moveSpaceDown:(id)sender { [self moveSpace:_space by:1]; }
- (IBAction)nextSpace:(id)sender {
  if (_spaces.count) [self selectSpaceAtIndex:([_spaces indexOfObject:_space] + 1) % _spaces.count];
}
- (IBAction)previousSpace:(id)sender {
  if (_spaces.count) [self selectSpaceAtIndex:([_spaces indexOfObject:_space] + _spaces.count - 1) % _spaces.count];
}
- (IBAction)selectSpaceFromMenu:(NSMenuItem*)sender { [self selectSpaceAtIndex:sender.tag]; }

#pragma mark Arc shortcuts

- (IBAction)toggleSidebar:(id)sender {
  if (_sidebarPeeking) [self endSidebarPeek];
  _sidebar.hidden = !_sidebar.hidden;
  [self layoutContentArea];
  [self positionWindowButtons];
  [self updateEdgeStrip];
}
// The sidebar takes no room: hidden, or only floating over the page.
- (BOOL)sidebarCollapsed { return _sidebar.hidden || _sidebarPeeking; }

// Arc: with the sidebar hidden, moving the pointer to the window's left edge slides it in as a floating panel over
// the page (rounded, with a shadow, in the Space's colour); moving away slides it out again.
- (void)updateEdgeStrip {
  NSView* root = self.window.contentView;
  BOOL want = _sidebar.hidden && !_sidebarPeeking && !_focusMode;
  if (!_edgeStrip) {
    _edgeStrip = [[NSView alloc] initWithFrame:NSZeroRect];
    _edgeStrip.autoresizingMask = NSViewHeightSizable;
    _edgeTracker = [HoverTracker new];
    __weak MainWindowController* weakSelf = self;
    _edgeTracker.entered = ^{ [weakSelf beginSidebarPeek]; };
    [_edgeStrip addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                            options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow |
                                                                    NSTrackingInVisibleRect
                                                              owner:_edgeTracker
                                                           userInfo:nil]];
  }
  _edgeStrip.frame = NSMakeRect(0, 0, 6, root.bounds.size.height);
  if (want && _edgeStrip.superview != root) [root addSubview:_edgeStrip positioned:NSWindowAbove relativeTo:nil];
  if (!want) [_edgeStrip removeFromSuperview];
}
- (void)beginSidebarPeek {
  if (!_sidebar.hidden || _sidebarPeeking || _focusMode) return;
  _sidebarPeeking = YES;
  [_edgeStrip removeFromSuperview];
  NSView* root = self.window.contentView;
  CGFloat H = root.bounds.size.height;
  [_sidebar removeFromSuperview];
  [root addSubview:_sidebar positioned:NSWindowAbove relativeTo:nil];  // above the page card
  _sidebar.wantsLayer = YES;
  _sidebar.frame = NSMakeRect(6, 6, kSidebarWidth, H - 12);
  NSColor* bg = _space.themeColors.count ? ColorFromHex(_space.themeColors.firstObject) : nil;
  if (!bg) bg = IsDark(root) ? ColorFromHex(@"#120C39") : [NSColor colorWithSRGBRed:0.93 green:0.92 blue:0.97 alpha:1];
  _sidebar.layer.backgroundColor = bg.CGColor;
  _sidebar.layer.cornerRadius = 10;
  _sidebar.layer.borderWidth = 1;
  _sidebar.layer.borderColor = [NSColor colorWithWhite:IsDark(root) ? 1 : 0 alpha:0.10].CGColor;
  _sidebar.shadow = [NSShadow new];
  _sidebar.layer.shadowColor = NSColor.blackColor.CGColor;
  _sidebar.layer.shadowOpacity = 0.35;
  _sidebar.layer.shadowRadius = 18;
  _sidebar.layer.shadowOffset = CGSizeMake(0, -4);
  _sidebar.layer.masksToBounds = NO;
  _sidebar.hidden = NO;
  [self layoutSidebar];
  [self positionWindowButtons];
  if (!ReduceMotion()) {
    CABasicAnimation* slide = [CABasicAnimation animationWithKeyPath:@"transform.translation.x"];
    slide.fromValue = @(-(kSidebarWidth + 12));
    slide.toValue = @0;
    slide.duration = 0.22;
    slide.timingFunction = [CAMediaTimingFunction functionWithControlPoints:0.2 :0.9 :0.3 :1];
    [_sidebar.layer addAnimation:slide forKey:@"peekIn"];
  }
  if (!_peekTracker) {
    _peekTracker = [HoverTracker new];
    __weak MainWindowController* weakSelf = self;
    _peekTracker.exited = ^{
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        MainWindowController* me = weakSelf;
        if (!me || !me->_sidebarPeeking) return;
        NSPoint p = [me->_sidebar convertPoint:me.window.mouseLocationOutsideOfEventStream fromView:nil];
        if (!NSPointInRect(p, NSInsetRect(me->_sidebar.bounds, -8, -8)) && !me->_commandBar.isVisible) [me endSidebarPeek];
      });
    };
  }
  if (_peekArea) [_sidebar removeTrackingArea:_peekArea];
  _peekArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                             owner:_peekTracker
                                          userInfo:nil];
  [_sidebar addTrackingArea:_peekArea];
}
- (void)endSidebarPeek {
  if (!_sidebarPeeking) return;
  _sidebarPeeking = NO;
  if (_peekArea) [_sidebar removeTrackingArea:_peekArea];
  _peekArea = nil;
  _sidebar.hidden = YES;
  _sidebar.layer.backgroundColor = nil;
  _sidebar.layer.cornerRadius = 0;
  _sidebar.layer.borderWidth = 0;
  _sidebar.layer.shadowOpacity = 0;
  _sidebar.shadow = nil;
  _sidebar.frame = NSMakeRect(0, 0, kSidebarWidth, self.window.contentView.bounds.size.height);
  [self layoutSidebar];
  [self positionWindowButtons];
  [self updateEdgeStrip];
}
- (NSString*)sidebarPeekState {  // tests (V23)
  return [NSString stringWithFormat:@"peeking=%d strip=%d floating=%d radius=%.0f shadow=%.2f cardFull=%d", _sidebarPeeking,
                                    _edgeStrip.superview != nil, _sidebarPeeking && !_sidebar.hidden, _sidebar.layer.cornerRadius,
                                    _sidebar.layer.shadowOpacity, NSMinX(_content.frame) == 0];
}
- (void)beginSidebarPeekForTest { [self beginSidebarPeek]; }
- (void)endSidebarPeekForTest { [self endSidebarPeek]; }

// Page area = window minus the sidebar (if shown) minus the toolbar (if shown).
- (void)layoutContentArea {
  NSRect b = self.window.contentView.bounds;
  CGFloat x = [self sidebarCollapsed] ? 0 : kSidebarWidth;
  BOOL bar = SettingBool(kSettingShowToolbar) && !_focusMode;
  _toolbar.hidden = !bar;
  CGFloat top = bar ? kToolbarHeight : 0;
  _toolbar.frame = NSMakeRect(x, b.size.height - kToolbarHeight, b.size.width - x, kToolbarHeight);
  // With no sidebar the window buttons sit over the toolbar's left end.
  CGFloat shift = [self sidebarCollapsed] ? 72 : 0;
  CGFloat bx = 8 + shift;
  for (NSView* v in _toolbar.subviews) {
    if (v == _address) continue;
    NSRect f = v.frame;
    f.origin.x = bx;
    v.frame = f;
    bx += 28;
  }
  _address.frame = NSMakeRect(bx + 6, 7, _toolbar.bounds.size.width - bx - 16, 24);
  // Card insets; with no sidebar (and in focus mode) the page fills the window, as in Arc.
  BOOL card = ![self sidebarCollapsed];
  [self updateEdgeStrip];
  CGFloat left = card ? 0 : 0, right = card ? kCardInsetSide : 0, bottom = card ? kCardInsetBottom : 0;
  CGFloat topInset = card && !bar ? kCardInsetTop : 0;
  _content.layer.cornerRadius = card ? kCardRadius : 0;
  _content.frame = NSMakeRect(x + left, bottom, b.size.width - x - left - right, b.size.height - top - topInset - bottom);
  _cardEdge.frame = _content.frame;
  _cardEdge.hidden = !card;
  _cardEdge.needsDisplay = YES;
  [self updateToolbarAddress];
  [self layoutPanes];
}

- (IBAction)toggleToolbar:(id)sender {
  SettingSetBool(kSettingShowToolbar, !SettingBool(kSettingShowToolbar));
  [self layoutContentArea];
}
- (BOOL)toolbarShown { return !_toolbar.hidden; }
- (NSString*)toolbarAddress { return _address.stringValue; }

- (NSString*)sidebarAddressText { return _addressPillText.stringValue; }
- (NSRect)sidebarAddressFrame { return [_addressPill convertRect:_addressPill.bounds toView:nil]; }

// Arc shows just the site (host without "www.") in the sidebar pill; the full address is in the command bar.
// Developer Mode (#68): the full address with its port, and a Developer Tools button in the pill.
- (void)updateSidebarAddress {
  NSString* url = _shown ? ([self itemCurrentURL:_shown] ?: @"") : @"";
  NSString* host = SidebarAddressTextForURL(url);
  BOOL dev = _shown && !_shown.noteID && !_shown.easelID && DeveloperModeOnForURL(url);
  if (_devToolsButton.hidden == dev) {
    _devToolsButton.hidden = !dev;
    NSRect f = _addressPillText.frame;
    f.size.width = _addressPill.bounds.size.width - 11 - 86 - (dev ? 26 : 0);
    _addressPillText.frame = f;
  }
  if (_shown.noteID) host = @"Note";
  if (_shown.easelID) host = @"Easel";
  _addressPillText.stringValue = host ?: @"";
  _addressPill.toolTip = url;
  [self updateBoostIndicator];
  [self updateNavButtons];
  [self updateLoadingGlow];
}
// Arc: a loading tab shows a small spinner where its icon was, and a soft glow runs along the top of the page card
// while the shown page loads.
- (void)browser:(int)browserId loading:(BOOL)loading {
  ArcItem* item = [self itemForBrowserId:browserId];
  if (!item || item.loading == loading) return;
  item.loading = loading;
  NSInteger row = [_outline rowForItem:item];
  if (row >= 0) [_outline reloadItem:item];
  ArcItem* group = [self parentOfItem:item];
  if (group.isSplit && [_outline rowForItem:group] >= 0) [_outline reloadItem:group];
  [self updateNavButtons];
  [self updateLoadingGlow];
}
- (void)updateLoadingGlow {
  BOOL on = _shown.loading && !_sidebarPeeking;
  if (!_loadingGlow) {
    CAGradientLayer* g = [CAGradientLayer layer];
    g.startPoint = CGPointMake(0, 0.5);
    g.endPoint = CGPointMake(1, 0.5);
    g.locations = @[ @0, @0.5, @1 ];
    _loadingGlow = g;
  }
  CAGradientLayer* g = (CAGradientLayer*)_loadingGlow;
  if (!on) {
    [g removeAllAnimations];
    [g removeFromSuperlayer];
    return;
  }
  NSColor* tint = _space.themeColors.count ? ColorFromHex(_space.themeColors.firstObject) : nil;
  if (!tint) tint = [NSColor colorWithSRGBRed:0.333 green:0.522 blue:1 alpha:1];  // Arc's accent
  g.colors = @[ (id)[tint colorWithAlphaComponent:0].CGColor, (id)[tint colorWithAlphaComponent:0.9].CGColor,
                (id)[tint colorWithAlphaComponent:0].CGColor ];
  _cardEdge.wantsLayer = YES;
  CGFloat W = NSWidth(_cardEdge.bounds), H = NSHeight(_cardEdge.bounds);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  g.frame = CGRectMake(0, H - 2.5, W * 0.4, 2.5);
  g.cornerRadius = 1.25;
  [CATransaction commit];
  if (g.superlayer != _cardEdge.layer) [_cardEdge.layer addSublayer:g];
  if (![g animationForKey:@"sweep"] && !ReduceMotion()) {
    CABasicAnimation* a = [CABasicAnimation animationWithKeyPath:@"position.x"];
    a.fromValue = @(-W * 0.2);
    a.toValue = @(W * 1.2);
    a.duration = 1.4;
    a.repeatCount = HUGE_VALF;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [g addAnimation:a forKey:@"sweep"];
  }
}
- (NSString*)splitRowStateForItem:(ArcItem*)split {  // tests (V19): segments, slashes, the dimmed pane count
  NSInteger row = [_outline rowForItem:split];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  NSView* segs = nil;
  for (NSView* v in cell.subviews)
    if ([v.identifier isEqual:@"splitSegments"]) segs = v;
  NSUInteger labels = 0, slashes = 0, dim = 0;
  for (NSView* v in segs.subviews) {
    if ([v isKindOfClass:SplitSlashView.class]) ++slashes;
    else if ([v isKindOfClass:NSTextField.class]) {
      ++labels;
      if (v.alphaValue < 0.9) ++dim;
    }
  }
  return [NSString stringWithFormat:@"segments=%lu slashes=%lu dim=%lu single=%d", (unsigned long)labels, (unsigned long)slashes,
                                    (unsigned long)dim, segs && !segs.hidden && cell.textField.hidden];
}
- (NSString*)folderRowStateForItem:(ArcItem*)folder {  // tests (V18)
  NSInteger row = [_outline rowForItem:folder];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  BOOL open = [_outline isItemExpanded:folder];
  NSFont* f = cell.textField.font;
  BOOL bold = f && [f isEqual:[NSFont systemFontOfSize:f.pointSize weight:NSFontWeightSemibold]];
  NSInteger childRow = open && folder.children.count ? [_outline rowForItem:folder.children.firstObject] : -1;
  CGFloat indent = childRow >= 0 ? NSMinX([_outline frameOfCellAtColumn:0 row:childRow]) - NSMinX([_outline frameOfCellAtColumn:0 row:row]) : -1;
  return [NSString stringWithFormat:@"glyph=%d chevron=%d bold=%d indent=%.0f", cell.imageView.image == FolderGlyph(open),
                                    ![cell viewWithTag:77].hidden, bold, indent];
}
- (NSString*)todayClearState {  // tests (V17): "hidden/shown" before and while the Today header is hovered
  NSInteger hr = [_outline rowForItem:_space.unpinned];
  NSTableCellView* cell = hr >= 0 ? [_outline viewAtColumn:0 row:hr makeIfNecessary:YES] : nil;
  NSButton* c = [cell viewWithTag:83];
  BOOL before = c && !c.hidden;
  [self setSidebarHoverRow:hr];
  BOOL during = c && !c.hidden && c.action == @selector(clearToday:) && NSMaxX(c.frame) <= NSWidth(cell.bounds);
  [self setSidebarHoverRow:-1];
  return [NSString stringWithFormat:@"before=%d during=%d after=%d", before, during, c && !c.hidden];
}
- (NSString*)loadingIndicatorStateForItem:(ArcItem*)item {  // tests (V9)
  NSInteger row = [_outline rowForItem:item];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  NSProgressIndicator* spin = nil;
  for (NSView* v in cell.subviews)
    if ([v.identifier isEqual:@"spinner"]) spin = (NSProgressIndicator*)v;
  return [NSString stringWithFormat:@"spinner=%d icon=%d glow=%d", spin && !spin.hidden, !cell.imageView.hidden,
                                    _loadingGlow.superlayer != nil];
}
- (void)setItem:(ArcItem*)item loadingForTest:(BOOL)loading {
  item.loading = !loading;
  [self browser:item.browserId loading:loading];
  if (!item.browserId) {
    item.loading = loading;
    [_outline reloadItem:item];
    [self updateLoadingGlow];
  }
}

// Arc dims back / forward when there's nowhere to go (white ~25% against ~60%).
- (void)updateNavButtons {
  BOOL back = [self canGoBack], fwd = [self currentBrowser] && [self currentBrowser]->CanGoForward();
  for (NSButton* b in @[ _navBack ?: [NSNull null], _navForward ?: [NSNull null] ]) {
    if (![b isKindOfClass:NSButton.class]) continue;
    BOOL on = b == _navBack ? back : fwd;
    b.enabled = on;
    b.contentTintColor = on ? SidebarIconColor() : SidebarIconDimColor();
  }
}
- (BOOL)spaceDotsAreArcStyle {  // tests: every dot filled, the current one brighter
  NSUInteger cur = [_spaces indexOfObject:_space];
  __block BOOL ok = YES;
  [self.window.effectiveAppearance performAsCurrentDrawingAppearance:^{
    for (NSButton* b in self->_spaceIcons.views) {
      if (!b.image) continue;  // an emoji Space
      CGFloat alpha = [b.contentTintColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace].alphaComponent;
      if ((NSUInteger)b.tag == cur ? alpha < 0.4 : alpha > 0.25) ok = NO;
    }
  }];
  return ok;
}
- (NSString*)navButtonState {  // tests
  return [NSString stringWithFormat:@"back=%d forward=%d", _navBack.enabled, _navForward.enabled];
}

- (void)updateToolbarAddress {
  [self updateSidebarAddress];
  if (_toolbar.hidden || _address.currentEditor) return;  // don't overwrite what the user is typing
  _address.stringValue = _shown ? ([self itemCurrentURL:_shown] ?: @"") : @"";
}

- (void)addressEntered:(NSTextField*)sender { [self submitToolbarAddress:sender.stringValue]; }
- (void)submitToolbarAddress:(NSString*)text {
  NSString* url = ResolveCommandBarInput(text);
  if (!url.length) return;
  [self.window makeFirstResponder:nil];
  if (_shown) [self loadURL:url inItem:_shown];
  else [self openInNewTab:url];
  _address.stringValue = url;
}

- (IBAction)toggleSpaceHeader:(id)sender {
  BOOL show = !SettingBool(kSettingShowSpaceHeader);
  SettingSetBool(kSettingShowSpaceHeader, show);
  [self applySpaceHeader:show];
}
- (BOOL)spaceHeaderShown { return !_spaceHeader.hidden; }
- (void)applySpaceHeader:(BOOL)show {
  if (_spaceHeader.hidden == !show) return;
  _spaceHeader.hidden = !show;
  [self layoutSidebar];
}


- (BOOL)sidebarHidden { return [self sidebarCollapsed]; }
- (NSRect)pageCardFrame { return _content.frame; }
- (CGFloat)pageCardRadius { return _content.layer.cornerRadius; }
- (NSString*)pageCardEdgeStyle {  // tests: "border=<alpha> shadow=<opacity>" after the window has drawn
  CGFloat a = _content.layer.borderWidth > 0 ? CGColorGetAlpha(_content.layer.borderColor) : 0;
  [_cardEdge displayIfNeeded];
  return [NSString stringWithFormat:@"border=%.2f shadow=%.2f", a, _cardEdge.hidden ? 0 : _cardEdge.layer.shadowOpacity];
}
- (NSString*)pageCardEdgeDebug {
  return [NSString stringWithFormat:@"hidden=%d dark=%d radius=%.0f layerShadow=%.2f super=%d", _cardEdge.hidden, IsDark(_cardEdge),
                                    _content.layer.cornerRadius, _cardEdge.layer.shadowOpacity, _cardEdge.superview != nil];
}

- (IBAction)toggleFocusMode:(id)sender {
  if (_sidebarPeeking) [self endSidebarPeek];
  _focusMode = !_focusMode;
  if (_focusMode) {
    _sidebarWasHidden = _sidebar.hidden;
    if (!_sidebar.hidden) [self toggleSidebar:nil];
  } else if (_sidebar.hidden && !_sidebarWasHidden) {
    [self toggleSidebar:nil];
  }
  for (NSWindowButton b : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton})
    [self.window standardWindowButton:b].hidden = _focusMode;
  [self layoutContentArea];
}
- (ArcItem*)shownItem { return _shown; }

- (void)selectTabAtIndex:(NSUInteger)index {
  NSArray<ArcItem*>* tabs = _space.allTabs;
  if (index == 8 && tabs.count) index = tabs.count - 1;  // Cmd+9 = last item, as in Arc and Chrome
  if (index < tabs.count) [self showItem:tabs[index]];
}

- (IBAction)switchToRecentTab:(id)sender {
  // From the keyboard with Ctrl (or the user's own modifier) still held: open the switcher, as in Arc. Releasing
  // the modifier switches; a quick press-and-release ends up on the same tab as before, without the panel.
  NSEvent* e = NSApp.currentEvent;
  NSEventModifierFlags held = e.type == NSEventTypeKeyDown
                                  ? e.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagCommand | NSEventModifierFlagOption)
                                  : 0;
  if (sender && held && (NSEvent.modifierFlags & held) == held) {
    _switcherKey = e.keyCode;
    [self openTabSwitcherHolding:held];
    return;
  }
  ArcItem* best = nil;
  for (ArcItem* t in _space.allTabs) {
    if (t == _shown || !t.lastActiveAt) continue;
    if (!best || [t.lastActiveAt compare:best.lastActiveAt] == NSOrderedDescending) best = t;
  }
  if (best) [self showItem:best];
}

#pragma mark Tab thumbnails (#65)

// Items holding a picture, oldest copy first (weak: closed tabs drop out). Main thread only. Keeps memory bounded
// however many tabs are open: past kTabThumbnailMax pictures, the oldest are thrown away.
static void RememberThumbnailOf(ArcItem* item) {
  static NSPointerArray* order = [NSPointerArray weakObjectsPointerArray];
  for (NSUInteger i = order.count; i-- > 0;)
    if ([order pointerAtIndex:i] == (__bridge void*)item || ![order pointerAtIndex:i]) [order removePointerAtIndex:i];
  [order addPointer:(__bridge void*)item];
  while (order.count > kTabThumbnailMax) {
    ArcItem* oldest = (__bridge ArcItem*)[order pointerAtIndex:0];
    oldest.thumbnail = nil;
    [order removePointerAtIndex:0];
  }
}

// The picture is copied from NotArc's own window by ScreenCaptureKit, asynchronously (tab_thumbnails.mm): the main
// thread only starts the copy. Copies happen 1 s after a tab comes on screen or finishes loading (each switch or load
// restarts the wait, so flipping through tabs copies nothing), when the pointer moves over the sidebar (a hover card
// may follow) and when the Ctrl+Tab switcher opens, at most once every 2 s for the same tab.
- (void)scheduleThumbnailOfShown {
  if (!TabThumbnailsAvailable()) return;
  [_thumbTimer invalidate];
  __weak MainWindowController* weakSelf = self;
  _thumbTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:NO block:^(NSTimer*) {
    MainWindowController* me = weakSelf;
    if (!me) return;
    me->_thumbTimer = nil;
    [me takeThumbnailOf:me->_shown];
  }];
}

- (void)thumbnailAfterLoadOfBrowser:(int)browserId {
  if (_shown && _shown.browserId == browserId) [self scheduleThumbnailOfShown];
}

- (void)refreshThumbnailOfShownIfOlderThan:(NSTimeInterval)age {
  if (!_shown || _thumbTimer) return;  // a copy is already due
  if (_shown.thumbnailTaken && -_shown.thumbnailTaken.timeIntervalSinceNow < age) return;
  [self takeThumbnailOf:_shown];
}

- (void)takeThumbnailOf:(ArcItem*)item {
  if (!TabThumbnailsAvailable() || !item || item != _shown) return;
  if (_thumbPendingSince && -_thumbPendingSince.timeIntervalSinceNow < 5) return;  // one copy at a time
  if (!item.browserId || item.noteID || item.easelID || item.crashed) return;
  NSView* web = [self webViewForItem:item];
  NSWindow* win = web.window;
  if (!win || win != self.window || web.isHiddenOrHasHiddenAncestor || !win.isVisible || win.isMiniaturized || NSApp.isHidden ||
      !(win.occlusionState & NSWindowOcclusionStateVisible))
    return;
  if (web.bounds.size.width < 50 || web.bounds.size.height < 50) return;
  // The top of the page, 4:3, 480 pixels wide (sharp enough for a 280 pt card; about 20-40 KB as JPEG).
  NSRect inWin = [web convertRect:web.bounds toView:nil];
  CGFloat h = MIN(inWin.size.height, inWin.size.width * 0.75);
  NSRect top = NSMakeRect(inWin.origin.x, NSMaxY(inWin) - h, inWin.size.width, h);
  NSUInteger gen = _showGeneration;
  _thumbPendingSince = [NSDate date];
  item.thumbnailTaken = _thumbPendingSince;
  __weak MainWindowController* weakSelf = self;
  __weak ArcItem* weakItem = item;
  TabThumbnailCapture(win, top, 480, ^(NSImage* image) {
    MainWindowController* me = weakSelf;
    if (!me) return;
    me->_thumbPendingSince = nil;
    ArcItem* it = weakItem;
    // A tab switch while the copy was being made may have put another page in the picture: drop it.
    if (!image || !it || me->_showGeneration != gen) return;
    it.thumbnail = image;
    RememberThumbnailOf(it);
    [me updateTabSwitcherTileFor:it];
  });
}

#pragma mark Recent-tab switcher (Ctrl+Tab)

static const CGFloat kSwitcherTileW = 168, kSwitcherThumbH = 126, kSwitcherGap = 10, kSwitcherPad = 14;

// Tabs of this Space, the shown one first, then most recently used first.
- (NSArray<ArcItem*>*)recentTabsForSwitcherMax:(NSUInteger)max {
  ArcItem* shown = _shown;
  NSMutableArray<ArcItem*>* tabs = [NSMutableArray array];
  for (ArcItem* t in _space.allTabs)
    if (t.url.length && (t == shown || t.lastActiveAt)) [tabs addObject:t];
  [tabs sortUsingComparator:^NSComparisonResult(ArcItem* a, ArcItem* b) {
    if (a == shown) return NSOrderedAscending;
    if (b == shown) return NSOrderedDescending;
    return [b.lastActiveAt compare:a.lastActiveAt];
  }];
  if (tabs.count > max) [tabs removeObjectsInRange:NSMakeRange(max, tabs.count - max)];
  return tabs;
}

- (void)fillSwitcherTile:(NSView*)tile item:(ArcItem*)item {
  NSImageView* iv = (NSImageView*)[tile viewWithTag:1];
  if (item.thumbnail) {
    iv.image = item.thumbnail;
    iv.imageScaling = NSImageScaleProportionallyUpOrDown;
    iv.identifier = @"thumbnail";
  } else {  // no picture yet (never shown since launch): the site's icon
    iv.image = [self iconImageForItem:item];
    iv.imageScaling = NSImageScaleNone;
    iv.identifier = @"icon";
  }
}

- (void)openTabSwitcherHolding:(NSEventModifierFlags)mods {
  if (_switcher) {
    [self stepTabSwitcher:1];
    return;
  }
  CGFloat avail = _content.bounds.size.width - 2 * kSwitcherPad;
  NSUInteger fit = (NSUInteger)MAX(2.0, floor((avail + kSwitcherGap) / (kSwitcherTileW + kSwitcherGap)));
  NSArray<ArcItem*>* items = [self recentTabsForSwitcherMax:MIN((NSUInteger)8, fit)];
  if (items.count < 2) return;  // nothing to switch to
  [self hideHoverCard];
  [self refreshThumbnailOfShownIfOlderThan:1];  // the panel is its own window, so it never shows up in the copy
  _switcherItems = items;
  _switcherMods = mods;
  CGFloat w = items.count * kSwitcherTileW + (items.count - 1) * kSwitcherGap + 2 * kSwitcherPad;
  CGFloat h = kSwitcherThumbH + 30 + 2 * kSwitcherPad;
  _switcher = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, w, h)
                                         styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
  _switcher.backgroundColor = NSColor.clearColor;
  _switcher.opaque = NO;
  _switcher.hasShadow = YES;
  if (self.selfTestProfiles) {  // hidden test runs: never on screen, never clickable
    _switcher.alphaValue = 0.01;
    _switcher.ignoresMouseEvents = YES;
  }
  NSVisualEffectView* card = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, w, h)];
  card.material = NSVisualEffectMaterialHUDWindow;
  _switcher.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];  // always the dark HUD, as in Arc
  card.state = NSVisualEffectStateActive;
  card.wantsLayer = YES;
  card.layer.cornerRadius = 14;
  card.layer.masksToBounds = YES;
  _switcher.contentView = card;
  _switcherTiles = [NSMutableArray array];
  for (NSUInteger i = 0; i < items.count; ++i) {
    NSView* tile = [[NSView alloc] initWithFrame:NSMakeRect(kSwitcherPad + i * (kSwitcherTileW + kSwitcherGap), kSwitcherPad - 4,
                                                            kSwitcherTileW, kSwitcherThumbH + 34)];
    tile.wantsLayer = YES;
    tile.layer.cornerRadius = 10;
    NSImageView* iv = [[NSImageView alloc] initWithFrame:NSMakeRect(6, 30, kSwitcherTileW - 12, kSwitcherThumbH - 2)];
    iv.tag = 1;
    iv.wantsLayer = YES;
    iv.layer.cornerRadius = 6;
    iv.layer.masksToBounds = YES;
    iv.layer.backgroundColor = [NSColor.labelColor colorWithAlphaComponent:0.06].CGColor;
    // each picture floats with a small shadow (a holder carries it; the image itself is clipped to its corners)
    NSView* holder = [[NSView alloc] initWithFrame:iv.frame];
    holder.wantsLayer = YES;
    holder.layer.shadowColor = NSColor.blackColor.CGColor;
    holder.layer.shadowOpacity = 0.35;
    holder.layer.shadowRadius = 6;
    holder.layer.shadowOffset = CGSizeMake(0, -2);
    CGPathRef sp = CGPathCreateWithRoundedRect(CGRectMake(0, 0, iv.frame.size.width, iv.frame.size.height), 6, 6, NULL);
    holder.layer.shadowPath = sp;
    CGPathRelease(sp);
    holder.identifier = @"switcherShadow";
    [tile addSubview:holder];
    [tile addSubview:iv];
    // under each picture: the site's icon and the title, centred, in white (the panel is always the dark HUD)
    NSTextField* title = [NSTextField labelWithString:items[i].displayTitle ?: items[i].url];
    title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    title.textColor = [NSColor colorWithWhite:1 alpha:0.9];
    title.lineBreakMode = NSLineBreakByTruncatingTail;
    NSImageView* fav = [NSImageView imageViewWithImage:[self iconImageForItem:items[i]] ?: [NSImage imageWithSystemSymbolName:@"globe" accessibilityDescription:nil]];
    fav.imageScaling = NSImageScaleProportionallyUpOrDown;
    fav.frame = NSMakeRect(0, 0, 14, 14);
    fav.identifier = @"switcherIcon";
    CGFloat tw = MIN(ceil(title.fittingSize.width), kSwitcherTileW - 12 - 20);
    CGFloat x0 = round((kSwitcherTileW - (14 + 6 + tw)) / 2);
    fav.frame = NSMakeRect(x0, 8, 14, 14);
    title.frame = NSMakeRect(x0 + 20, 6, tw, 18);
    [tile addSubview:fav];
    [tile addSubview:title];
    [self fillSwitcherTile:tile item:items[i]];
    NSClickGestureRecognizer* click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(switcherTileClicked:)];
    [tile addGestureRecognizer:click];
    [card addSubview:tile];
    [_switcherTiles addObject:tile];
  }
  _switcherIndex = 1;
  [self updateSwitcherSelection];
  NSRect c = [self.window convertRectToScreen:[_content convertRect:_content.bounds toView:nil]];
  [_switcher setFrameOrigin:NSMakePoint(round(NSMidX(c) - w / 2), round(NSMidY(c) - h / 2))];
  if (!mods) {
    [self revealTabSwitcher];
    return;
  }
  __weak MainWindowController* weakSelf = self;
  _switcherMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown | NSEventMaskFlagsChanged | NSEventMaskLeftMouseDown
                                                            handler:^NSEvent*(NSEvent* ev) {
    MainWindowController* me = weakSelf;
    if (!me || !me->_switcher) return ev;
    if (ev.type == NSEventTypeFlagsChanged) {
      if ((ev.modifierFlags & me->_switcherMods) != me->_switcherMods) [me commitTabSwitcher];  // let go: switch
      return ev;
    }
    if (ev.type == NSEventTypeLeftMouseDown) {
      if (ev.window != me->_switcher) [me cancelTabSwitcher];
      return ev;
    }
    BOOL back = (ev.modifierFlags & NSEventModifierFlagShift) != 0;
    switch (ev.keyCode) {
      case 53: [me cancelTabSwitcher]; break;                               // Esc
      case 36: case 76: [me commitTabSwitcher]; break;                      // Return, Enter
      case 123: case 126: [me stepTabSwitcher:-1]; break;                   // Left, Up
      case 124: case 125: [me stepTabSwitcher:1]; break;                    // Right, Down
      default:
        if (ev.keyCode == 48 || ev.keyCode == me->_switcherKey) [me stepTabSwitcher:back ? -1 : 1];  // Tab again
        break;
    }
    return nil;  // keys never reach the page while the switcher is up
  }];
  _switcherResignObserver = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidResignActiveNotification
                                                                            object:nil
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification*) { [weakSelf cancelTabSwitcher]; }];
  // A quick press-and-release switches without the panel ever flashing up.
  _switcherRevealTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:NO block:^(NSTimer*) {
    MainWindowController* me = weakSelf;
    if (!me || !me->_switcher) return;
    me->_switcherRevealTimer = nil;
    if ((NSEvent.modifierFlags & me->_switcherMods) != me->_switcherMods) [me commitTabSwitcher];  // release we missed
    else [me revealTabSwitcher];
  }];
}

- (void)revealTabSwitcher {
  if (!_switcher || _switcher.parentWindow) return;
  [self.window addChildWindow:_switcher ordered:NSWindowAbove];
  [_switcher orderFront:nil];
}

- (void)updateSwitcherSelection {
  for (NSUInteger i = 0; i < _switcherTiles.count; ++i) {
    CALayer* l = _switcherTiles[i].layer;
    BOOL on = (NSInteger)i == _switcherIndex;
    // Arc's switcher (like the macOS app switcher): the chosen item sits on a soft light rounded plate, no accent.
    l.backgroundColor = on ? [NSColor colorWithWhite:1 alpha:0.16].CGColor : NSColor.clearColor.CGColor;
    l.borderWidth = 0;
  }
}

- (NSString*)tabSwitcherStyle {  // tests (V33)
  NSUInteger shadows = 0, icons = 0;
  for (NSView* t in _switcherTiles)
    for (NSView* v in t.subviews) {
      if ([v.identifier isEqual:@"switcherShadow"]) ++shadows;
      if ([v.identifier isEqual:@"switcherIcon"]) ++icons;
    }
  BOOL neutral = NO;
  if (_switcherIndex >= 0 && (NSUInteger)_switcherIndex < _switcherTiles.count) {
    CALayer* l = _switcherTiles[_switcherIndex].layer;
    neutral = l.borderWidth == 0 && l.backgroundColor != nil;
  }
  return [NSString stringWithFormat:@"tiles=%lu shadows=%lu icons=%lu neutral=%d", (unsigned long)_switcherTiles.count,
                                    (unsigned long)shadows, (unsigned long)icons, neutral];
}
- (void)updateTabSwitcherTileFor:(ArcItem*)item {
  NSUInteger i = [_switcherItems indexOfObjectIdenticalTo:item];
  if (_switcher && i != NSNotFound) [self fillSwitcherTile:_switcherTiles[i] item:item];
}

- (void)stepTabSwitcher:(NSInteger)delta {
  if (!_switcher) return;
  NSInteger n = (NSInteger)_switcherItems.count;
  _switcherIndex = ((_switcherIndex + delta) % n + n) % n;
  [self updateSwitcherSelection];
}

- (void)switcherTileClicked:(NSClickGestureRecognizer*)g {
  NSUInteger i = [_switcherTiles indexOfObjectIdenticalTo:g.view];
  if (i == NSNotFound) return;
  _switcherIndex = (NSInteger)i;
  [self commitTabSwitcher];
}

- (void)closeTabSwitcher {
  if (_switcherMonitor) [NSEvent removeMonitor:_switcherMonitor];
  _switcherMonitor = nil;
  if (_switcherResignObserver) [NSNotificationCenter.defaultCenter removeObserver:_switcherResignObserver];
  _switcherResignObserver = nil;
  [_switcherRevealTimer invalidate];
  _switcherRevealTimer = nil;
  if (_switcher.parentWindow) [self.window removeChildWindow:_switcher];
  [_switcher orderOut:nil];
  _switcher = nil;
  _switcherItems = nil;
  _switcherTiles = nil;
}

- (void)commitTabSwitcher {
  if (!_switcher) return;
  ArcItem* pick = _switcherIndex >= 0 && _switcherIndex < (NSInteger)_switcherItems.count ? _switcherItems[_switcherIndex] : nil;
  [self closeTabSwitcher];
  if (pick && pick != _shown && [_space.allTabs containsObject:pick]) [self showItem:pick];
}

- (void)cancelTabSwitcher { [self closeTabSwitcher]; }

- (BOOL)tabSwitcherShown { return _switcher != nil && _switcher.isVisible; }
- (NSArray<ArcItem*>*)tabSwitcherItems { return _switcherItems; }
- (ArcItem*)tabSwitcherSelection {
  return _switcher && _switcherIndex < (NSInteger)_switcherItems.count ? _switcherItems[_switcherIndex] : nil;
}
- (BOOL)tabSwitcherShowsThumbnailFor:(ArcItem*)item {
  NSUInteger i = [_switcherItems indexOfObjectIdenticalTo:item];
  if (!_switcher || i == NSNotFound) return NO;
  NSImageView* iv = (NSImageView*)[_switcherTiles[i] viewWithTag:1];
  return [iv.identifier isEqualToString:@"thumbnail"] && iv.image == item.thumbnail;
}

- (IBAction)pasteAndGo:(id)sender {
  NSString* text = [[NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (text.length) [self openInNewTab:text];
}

- (IBAction)printPage:(id)sender {
  if (auto b = [self currentBrowser]) b->GetHost()->Print();
}
- (IBAction)selectTabFromMenu:(NSMenuItem*)sender { [self selectTabAtIndex:sender.tag]; }

- (void)stepTab:(NSInteger)delta {
  NSArray<ArcItem*>* tabs = _space.allTabs;
  if (!tabs.count) return;
  NSInteger i = _shown ? (NSInteger)[tabs indexOfObject:_shown] : -1;
  if (i == NSNotFound) i = -1;
  i = (i + delta + (NSInteger)tabs.count) % (NSInteger)tabs.count;
  [self showItem:tabs[i]];
}
- (IBAction)nextTab:(id)sender { [self stepTab:1]; }
- (IBAction)previousTab:(id)sender { [self stepTab:-1]; }

// Archives every Today tab in the current Space (Arc: "Clear unpinned tabs").
- (IBAction)clearToday:(id)sender {
  for (ArcItem* item in [_space.unpinned.children copy]) {
    if (item.isFolder) continue;
    if (item.isSplit) {
      for (ArcItem* pane in item.children) {
        [self archiveItem:pane space:_space reason:@"manual"];
        [self unloadItem:pane];
        if (pane == _shown) _shown = nil;
      }
      [_space.unpinned.children removeObject:item];
      continue;
    }
    [self archiveItem:item space:_space reason:@"manual"];
    [self unloadItem:item];
    [_space.unpinned.children removeObject:item];
    if (item == _shown) _shown = nil;
  }
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  if (!_shown) {
    ArcItem* first = _space.allTabs.firstObject;
    if (first) [self showItem:first];
    else [self layoutPanes];
  }
}

- (IBAction)focusPaneFromMenu:(NSMenuItem*)sender {
  if (![_splitItems containsObject:_shown] || (NSUInteger)sender.tag >= _splitItems.count) return;
  [self showItem:_splitItems[sender.tag]];
  if (auto b = [self currentBrowser]) b->GetHost()->SetFocus(true);
}

// Arc closes Peek when you click outside it.
- (void)windowDidBecomeKey:(NSNotification*)note {
  if (note.object == self.window && _peek) [_peek.window close];
}
// Arc dims the sidebar's text and icons while its window isn't the active one; the Space colour stays.
- (void)windowDidResignMain:(NSNotification*)note { [self applyWindowActive]; }
- (void)applyWindowActive {
  BOOL active = self.window.isMainWindow || (self.selfTestProfiles && !_testInactive);
  CGFloat a = active ? 1 : 0.55;
  for (NSView* v in @[ _sidebarNav ?: [NSNull null], _addressPill ?: [NSNull null], _favGrid ?: [NSNull null],
                       _spaceHeader ?: [NSNull null], _sidebarScroll ?: [NSNull null], _spaceBar ?: [NSNull null],
                       _mediaBar ?: [NSNull null], _library ?: [NSNull null] ])
    if ([v isKindOfClass:NSView.class]) v.alphaValue = a;
}
- (BOOL)sidebarDimmedForTest:(BOOL)inactive {  // tests (V8): returns whether the sidebar dimmed
  _testInactive = inactive;
  [self applyWindowActive];
  BOOL dimmed = _sidebarScroll.alphaValue < 0.9 && _addressPill.alphaValue < 0.9 && _spaceBar.alphaValue < 0.9;
  return dimmed;
}

#pragma mark Context menus

- (void)handleLinkCommand:(int)command url:(NSString*)url fromBrowser:(int)browserId {
  [self handleLinkCommand:command url:url text:nil fromBrowser:browserId];
}
// Right-click actions on links, images, the page and selected text (#70).
- (void)handleLinkCommand:(int)command url:(NSString*)url text:(NSString*)text fromBrowser:(int)browserId {
  if (command == BrowserClient::kSelectionSearch) {
    NSString* q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    q = [q stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    q = [[q stringByReplacingOccurrencesOfString:@"&" withString:@"%26"] stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    if (q.length) [self openInNewTab:SearchURLForQuery(q)];
    return;
  }
  if (!url.length) return;
  ArcItem* from = [self itemForBrowser:browserId];
  NSPasteboard* pb = [self copyPasteboard];
  switch (command) {
    case BrowserClient::kImageOpen: [self openInNewTab:url]; return;
    case BrowserClient::kImageCopyAddress:
    case BrowserClient::kPageCopyURL:
      [pb clearContents];
      [pb setString:url forType:NSPasteboardTypeString];
      return;
    case BrowserClient::kPageCopyMarkdown: {
      NSString* title = [(from.displayTitle ?: url) stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
      [pb clearContents];
      [pb setString:[NSString stringWithFormat:@"[%@](%@)", title, url] forType:NSPasteboardTypeString];
      return;
    }
    case BrowserClient::kImageSave: {
      auto it = _browsers.find(browserId);
      if (it != _browsers.end()) it->second->GetHost()->StartDownload(url.UTF8String);
      return;
    }
    case BrowserClient::kImageCopy: {
      auto it = _browsers.find(browserId);
      CefRefPtr<CefRequestContext> ctx = it != _browsers.end() ? it->second->GetHost()->GetRequestContext() : nullptr;
      __weak MainWindowController* weakSelf = self;
      void (^got)(NSInteger, NSData*, NSString*) = ^(NSInteger status, NSData* body, NSString*) {
        NSImage* img = status == 200 && body.length ? [[NSImage alloc] initWithData:body] : nil;
        MainWindowController* me = weakSelf;
        if (!img || !me) { NSBeep(); return; }
        NSPasteboard* p = [me copyPasteboard];
        [p clearContents];
        [p writeObjects:@[ img ]];
        me->_lastCopiedImageSize = img.size;
      };
      if ([url hasPrefix:@"data:"]) {  // inline images: no request needed
        NSData* d = [NSData dataWithContentsOfURL:[NSURL URLWithString:url]];
        got(d ? 200 : 0, d, url);
      } else {
        SpaceFetch(ctx, url, nil, got);
      }
      return;
    }
    case BrowserClient::kPageCapture:
      if (from && from != _shown) [self showItem:from];
      [self captureVisiblePage:nil];
      return;
    case BrowserClient::kPageTranslate:
      if (from && from != _shown) [self showItem:from];
      [self translatePage:nil];
      return;
    case BrowserClient::kPageBoost:
      if (from && from != _shown) [self showItem:from];
      [self editBoost:nil];
      return;
  }
  switch (command) {
    case BrowserClient::kLinkNewTab: [self openInNewTab:url]; break;
    case BrowserClient::kLinkBackgroundTab: [self openInNewTab:url background:YES]; break;
    case BrowserClient::kLinkSplit: {
      ArcItem* from = [self itemForBrowser:browserId];
      if (from && from != _shown) [self showItem:from];
      [self openInSplit:url horizontal:NO before:NO];
      break;
    }
    case BrowserClient::kLinkPeek: [self openPeek:url]; break;
    case BrowserClient::kLinkLittle: [self openLittleWindow:url]; break;
    case BrowserClient::kLinkCopyMarkdown: {
      [NSPasteboard.generalPasteboard clearContents];
      [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"[%@](%@)", url, url]
                                        forType:NSPasteboardTypeString];
      break;
    }
  }
}

- (void)menuNeedsUpdate:(NSMenu*)menu {
  if (menu != _outline.menu) return;
  [menu removeAllItems];
  ArcItem* item = _outline.clickedRow >= 0 ? [_outline itemAtRow:_outline.clickedRow] : nil;
  NSArray<ArcItem*>* selected = [self selectedSidebarItems];
  NSMenu* built = item && selected.count > 1 && [selected containsObject:item] ? [self sidebarMenuForItems:selected]
                  : (item ? [self sidebarMenuForItem:item] : nil);
  for (NSMenuItem* mi in [built.itemArray copy]) {
    [built removeItem:mi];
    [menu addItem:mi];
  }
}

#pragma mark Multi-select

- (NSArray<ArcItem*>*)selectedSidebarItems {
  NSMutableArray<ArcItem*>* out = [NSMutableArray array];
  [_outline.selectedRowIndexes enumerateIndexesUsingBlock:^(NSUInteger row, BOOL*) {
    ArcItem* it = [_outline itemAtRow:row];
    if (it && !it.isSection) [out addObject:it];
  }];
  return out;
}

- (void)selectSidebarItems:(NSArray<ArcItem*>*)items {
  NSMutableIndexSet* rows = [NSMutableIndexSet indexSet];
  for (ArcItem* it in items) {
    NSInteger r = [_outline rowForItem:it];
    if (r >= 0) [rows addIndex:r];
  }
  [_outline selectRowIndexes:rows byExtendingSelection:NO];
}

// Tabs inside selected folders/splits count too, once each.
- (NSArray<ArcItem*>*)tabsIn:(NSArray<ArcItem*>*)items {
  NSMutableOrderedSet<ArcItem*>* tabs = [NSMutableOrderedSet orderedSet];
  NSMutableArray* stack = [items.reverseObjectEnumerator.allObjects mutableCopy];
  while (stack.count) {
    ArcItem* t = stack.lastObject;
    [stack removeLastObject];
    if (t.url.length) [tabs addObject:t];
    [stack addObjectsFromArray:t.children.reverseObjectEnumerator.allObjects];
  }
  return tabs.array;
}

- (NSString*)linksForItems:(NSArray<ArcItem*>*)items markdown:(BOOL)markdown {
  NSMutableArray* lines = [NSMutableArray array];
  for (ArcItem* t in [self tabsIn:items]) {
    NSString* url = [self itemCurrentURL:t];
    if (!markdown) [lines addObject:url];
    else
      [lines addObject:[NSString stringWithFormat:@"- [%@](%@)",
                        [t.displayTitle ?: url stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"], url]];
  }
  return [lines componentsJoinedByString:@"\n"];
}

- (void)archiveItems:(NSArray<ArcItem*>*)items {
  for (ArcItem* item in [self tabsIn:items]) {
    BOOL isToday = Contains(_space.unpinned, item);
    if ([self parentOfItem:item].isSplit) [self detachFromSplit:item keep:!isToday];
    if (isToday) [self archiveItem:item space:_space reason:@"manual"];
    [self unloadItem:item];
    if (!isToday && item.pinnedURL.length) {
      item.url = item.pinnedURL;
      item.liveTitle = nil;
    }
    if (isToday) RemoveItem(_space.unpinned, item);
    if (item == _shown) _shown = nil;
  }
  // Folders left empty in Today go too (Today folders only exist when imported from Arc).
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  if (!_shown) {
    ArcItem* next = nil;
    for (ArcItem* t in _space.allTabs)
      if (!next && t.browserId) next = t;
    if (next) [self showItem:next];
    else [_outline deselectAll:nil];
  } else {
    [self selectSidebarRowFor:_shown];
  }
}

- (ArcItem*)newFolderWithItems:(NSArray<ArcItem*>*)items {
  if (!items.count || !_space) return nil;
  ArcItem* folder = [ArcItem new];
  folder.itemID = NSUUID.UUID.UUIDString;
  folder.title = @"New Folder";
  folder.isFolder = YES;
  folder.children = [NSMutableArray array];
  // Put it where the first pinned item sits, else at the end of Pinned.
  ArcItem* parent = _space.pinned;
  NSUInteger index = _space.pinned.children.count;
  for (ArcItem* it in items) {
    ArcItem* p = [self parentOfItem:it];
    if ([self sectionContaining:it] == _space.pinned && (p.isSection || p.isFolder)) {
      parent = p;
      index = [p.children indexOfObject:it];
      break;
    }
  }
  [parent.children insertObject:folder atIndex:index];
  for (ArcItem* it in items) {
    if (it == folder || Contains(it, folder)) continue;
    BOOL wasToday = Contains(_space.unpinned, it);
    if ([self parentOfItem:it].isSplit) continue;  // panes move with their split
    if ([self moveItem:it toParent:folder index:folder.children.count] && wasToday) [self markPinnedURLs:it];
  }
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [_outline expandItem:folder];
  [self scheduleSave];
  return folder;
}

- (ArcItem*)newNestedFolderIn:(ArcItem*)parent {
  if (!parent.isFolder) return nil;
  ArcItem* folder = [ArcItem new];
  folder.itemID = NSUUID.UUID.UUIDString;
  folder.title = @"New Folder";
  folder.isFolder = YES;
  folder.children = [NSMutableArray array];
  [parent.children insertObject:folder atIndex:0];
  [_outline reloadItem:parent reloadChildren:YES];
  [_outline expandItem:parent];
  [_outline expandItem:folder];
  [self scheduleSave];
  return folder;
}
- (void)menuNewNestedFolder:(NSMenuItem*)sender {
  ArcItem* folder = [self newNestedFolderIn:sender.representedObject];
  NSInteger row = [_outline rowForItem:folder];
  if (row >= 0) [_outline editColumn:0 row:row withEvent:nil select:YES];
}

- (NSMenu*)sidebarMenuForItems:(NSArray<ArcItem*>*)items {
  NSMenu* m = [[NSMenu alloc] initWithTitle:@"Sidebar"];
  NSUInteger n = [self tabsIn:items].count;
  NSMenuItem* (^add)(NSString*, SEL) = ^NSMenuItem*(NSString* title, SEL action) {
    NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
    mi.target = self;
    mi.representedObject = items;
    [m addItem:mi];
    return mi;
  };
  NSString* tabs = n == 1 ? @"1 Tab" : [NSString stringWithFormat:@"%lu Tabs", (unsigned long)n];
  add([@"Copy Links to " stringByAppendingString:tabs], @selector(bulkCopyLinks:));
  add(@"Copy Links as Markdown", @selector(bulkCopyMarkdown:));
  [m addItem:[NSMenuItem separatorItem]];
  add([NSString stringWithFormat:@"New Folder with %lu Items", (unsigned long)items.count], @selector(bulkNewFolder:));
  BOOL anyToday = NO, anyPinned = NO;
  for (ArcItem* it in items) {
    if ([self sectionContaining:it] == _space.unpinned) anyToday = YES;
    else anyPinned = YES;
  }
  if (anyToday) add(@"Pin Selected", @selector(bulkPin:));
  if (anyPinned) add(@"Unpin Selected", @selector(bulkUnpin:));
  if (_spaces.count > 1) {
    NSMenuItem* move = [[NSMenuItem alloc] initWithTitle:@"Move to" action:nil keyEquivalent:@""];
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Move to"];
    for (ArcSpace* sp in _spaces) {
      if (sp == _space) continue;
      for (int pinned = 0; pinned < 2; ++pinned) {
        NSMenuItem* mi = [[NSMenuItem alloc]
            initWithTitle:[NSString stringWithFormat:@"%@ in %@", pinned ? @"Pinned" : @"Today", sp.title]
                   action:@selector(bulkMoveToSpace:)
            keyEquivalent:@""];
        mi.target = self;
        mi.representedObject = @[ items, sp, @(pinned) ];
        [sub addItem:mi];
      }
    }
    move.submenu = sub;
    [m addItem:move];
  }
  [m addItem:[NSMenuItem separatorItem]];
  add([(anyPinned && !anyToday ? @"Close " : @"Archive ") stringByAppendingString:tabs], @selector(bulkArchive:));
  return m;
}

- (void)bulkCopyLinks:(NSMenuItem*)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[self linksForItems:sender.representedObject markdown:NO]
                                    forType:NSPasteboardTypeString];
}
- (void)bulkCopyMarkdown:(NSMenuItem*)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[self linksForItems:sender.representedObject markdown:YES]
                                    forType:NSPasteboardTypeString];
}
- (void)bulkNewFolder:(NSMenuItem*)sender {
  ArcItem* folder = [self newFolderWithItems:sender.representedObject];
  NSInteger row = [_outline rowForItem:folder];
  if (row >= 0) [_outline editColumn:0 row:row withEvent:nil select:YES];
}
- (void)bulkPin:(NSMenuItem*)sender {
  for (ArcItem* it in sender.representedObject)
    if ([self sectionContaining:it] == _space.unpinned && ![self parentOfItem:it].isSplit &&
        [self moveItem:it toParent:_space.pinned index:_space.pinned.children.count])
      [self markPinnedURLs:it];
}
- (void)bulkUnpin:(NSMenuItem*)sender {
  NSUInteger i = 0;
  for (ArcItem* it in sender.representedObject)
    if ([self sectionContaining:it] == _space.pinned && ![self parentOfItem:it].isSplit &&
        [self moveItem:it toParent:_space.unpinned index:i++])
      [self clearPinnedURLs:it];
}
- (void)bulkMoveToSpace:(NSMenuItem*)sender {
  NSArray* args = sender.representedObject;
  for (ArcItem* it in args[0]) [self moveItem:it toSpace:args[1] pinned:[args[2] boolValue]];
}
- (void)bulkArchive:(NSMenuItem*)sender { [self archiveItems:sender.representedObject]; }

- (NSMenuItem*)menuItem:(NSString*)title action:(SEL)action item:(ArcItem*)item {
  NSMenuItem* mi = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:@""];
  mi.target = self;
  mi.representedObject = item;
  return mi;
}

- (void)menuToggleUnreadBadge:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  item.hideUnreadBadge = !item.hideUnreadBadge;
  [self updateFavoritesGrid];
  [self scheduleSave];
}

- (NSMenu*)sidebarMenuForItem:(ArcItem*)item {
  NSMenu* m = [[NSMenu alloc] initWithTitle:@"Sidebar"];
  if (!item || item.isSection) return m;
  ArcItem* section = [self sectionContaining:item];
  BOOL isToday = section == _space.unpinned, isPinned = section == _space.pinned;
  BOOL isTab = item.url.length > 0;
  if (isTab || item.isSplit) [m addItem:[self menuItem:@"Open" action:@selector(menuOpen:) item:item]];
  if (isTab) {
    [m addItem:[self menuItem:@"Open in Split View" action:@selector(menuOpenInSplit:) item:item]];
    [m addItem:[self menuItem:@"Open in Little Window" action:@selector(menuOpenLittle:) item:item]];
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self menuItem:@"Copy URL" action:@selector(menuCopyURL:) item:item]];
    [m addItem:[self menuItem:@"Copy URL as Markdown" action:@selector(menuCopyMarkdown:) item:item]];
    [m addItem:[self menuItem:@"Copy Clean Link" action:@selector(menuCopyClean:) item:item]];
    if (item.browserId) {
      [m addItem:[self menuItem:item.audioMuted ? @"Unmute Tab" : @"Mute Tab" action:@selector(menuToggleMute:) item:item]];
      if (item.mediaPlaying || item.mediaPaused)
        [m addItem:[self menuItem:item.mediaPlaying ? @"Pause Media" : @"Play Media" action:@selector(menuTogglePlay:) item:item]];
    }
  }
  [m addItem:[NSMenuItem separatorItem]];
  if (isTab || item.isFolder) [m addItem:[self menuItem:@"Rename..." action:@selector(menuRename:) item:item]];
  if (isTab && item.renamed && item.liveTitle.length)
    [m addItem:[self menuItem:@"Use Page Title" action:@selector(menuUsePageTitle:) item:item]];
  else if (isTab && (MaxTidyTitlesUseModel() || ![[self ruleTidyTitleOfItem:item] isEqualToString:item.displayTitle]))
    [m addItem:[self menuItem:@"Tidy Title" action:@selector(menuTidyTitle:) item:item]];
  if (isTab && section == _space.favorites) {
    [m addItem:[self menuItem:@"Remove from Favorites" action:@selector(menuRemoveFromFavorites:) item:item]];
    [m addItem:[self menuItem:@"Move to Pinned" action:@selector(menuFavoriteToPinned:) item:item]];
    NSMenuItem* u = [self menuItem:@"Show Unread Badge" action:@selector(menuToggleUnreadBadge:) item:item];
    u.state = item.hideUnreadBadge ? NSControlStateValueOff : NSControlStateValueOn;
    [m addItem:u];
  }
  if (item.liveKind) [m addItem:[self menuItem:@"Refresh Live Folder" action:@selector(menuRefreshLive:) item:item]];
  if ([self parentOfItem:item].liveKind)  // Arc: liveFolderChildItemManuallyDeleted
    [m addItem:[self menuItem:@"Remove from Live Folder" action:@selector(menuDismissLive:) item:item]];
  if (item.isFolder && !item.liveKind) [m addItem:[self menuItem:@"New Nested Folder" action:@selector(menuNewNestedFolder:) item:item]];
  if (isTab || (!item.url.length && !item.isSection && !item.isSplit))
    [m addItem:[self menuItem:@"Duplicate" action:@selector(menuDuplicate:) item:item]];
  if (isToday) [m addItem:[self menuItem:@"Pin" action:@selector(menuTogglePin:) item:item]];
  if (isPinned && [_space.pinned.children containsObject:item])
    [m addItem:[self menuItem:@"Unpin" action:@selector(menuTogglePin:) item:item]];
  if (!isToday && item.pinnedURL.length) {
    [m addItem:[self menuItem:@"Reset to Pinned URL" action:@selector(menuResetPinned:) item:item]];
    [m addItem:[self menuItem:@"Replace Pinned URL with Current" action:@selector(menuReplacePinned:) item:item]];
  }
  BOOL canFavorite = isTab && !item.isSplit && (isToday || isPinned) && _space.favorites && ![self parentOfItem:item].isSplit;
  if ((isToday || isPinned) && (_spaces.count > 1 || canFavorite)) {
    NSMenuItem* move = [[NSMenuItem alloc] initWithTitle:@"Move to" action:nil keyEquivalent:@""];
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Move to"];
    if (canFavorite) {
      [sub addItem:[self menuItem:@"Favorites" action:@selector(menuMoveToFavorites:) item:item]];
      if (_spaces.count > 1) [sub addItem:[NSMenuItem separatorItem]];
    }
    for (ArcSpace* sp in _spaces) {
      if (sp == _space) continue;
      for (int pinned = 0; pinned < 2; ++pinned) {
        NSMenuItem* mi = [self menuItem:[NSString stringWithFormat:@"%@ in %@", pinned ? @"Pinned" : @"Today", sp.title]
                                 action:@selector(menuMoveToSpace:) item:item];
        mi.representedObject = @[ item, sp, @(pinned) ];
        [sub addItem:mi];
      }
    }
    move.submenu = sub;
    [m addItem:move];
  }
  if (isTab) {
    [m addItem:[self menuItem:@"Move to New Window" action:@selector(menuMoveToNewWindow:) item:item]];
    if (gMainWindow && gMainWindow != self)
      [m addItem:[self menuItem:@"Move to Main Window" action:@selector(menuMoveToMainWindow:) item:item]];
  }
  if (isToday && [_space.unpinned.children containsObject:item]) {
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self menuItem:@"Archive Other Tabs" action:@selector(menuArchiveOthers:) item:item]];
    [m addItem:[self menuItem:@"Archive Tabs Above" action:@selector(menuArchiveAbove:) item:item]];
    [m addItem:[self menuItem:@"Archive Tabs Below" action:@selector(menuArchiveBelow:) item:item]];
  }
  if (isTab) {
    [m addItem:[NSMenuItem separatorItem]];
    [m addItem:[self menuItem:isToday ? @"Archive Tab" : @"Close and Keep Pinned" action:@selector(menuClose:) item:item]];
  }
  return m;
}

- (void)menuOpen:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  [self showItem:item.isSplit ? item.children.firstObject : item];
}
- (void)menuOpenInSplit:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  if (!_shown || item == _shown) return;
  if (item.noteID) [self placeInSplit:item horizontal:NO before:NO];  // a note is one document: it moves
  else [self openInSplit:item.url horizontal:NO before:NO];
}
- (void)menuOpenLittle:(NSMenuItem*)sender { [self openLittleWindow:((ArcItem*)sender.representedObject).url]; }
- (void)menuCopyURL:(NSMenuItem*)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:((ArcItem*)sender.representedObject).url forType:NSPasteboardTypeString];
}
- (void)menuCopyClean:(NSMenuItem*)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:CleanLinkURL(((ArcItem*)sender.representedObject).url)
                                    forType:NSPasteboardTypeString];
}
- (IBAction)copyCleanLink:(id)sender {
  if (!_shown) return;
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:CleanLinkURL([self itemCurrentURL:_shown]) forType:NSPasteboardTypeString];
}
- (void)menuCopyMarkdown:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  NSString* title = [item.displayTitle stringByReplacingOccurrencesOfString:@"]" withString:@"\\]"];
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:[NSString stringWithFormat:@"[%@](%@)", title, item.url]
                                    forType:NSPasteboardTypeString];
}
- (void)menuRename:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  NSString* name = [self askForSpaceName:@"Rename" initial:item.displayTitle];
  if (name.length) [self renameItem:item to:name];
}
- (void)menuDuplicate:(NSMenuItem*)sender { [self duplicateItem:sender.representedObject]; }
- (void)menuTogglePin:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  if ([self sectionContaining:item] == _space.unpinned) {
    [self moveItem:item toParent:_space.pinned index:_space.pinned.children.count];
    [self markPinnedURLs:item];
  } else {
    [self moveItem:item toParent:_space.unpinned index:0];
    [self clearPinnedURLs:item];
  }
}
- (void)menuMoveToSpace:(NSMenuItem*)sender {
  NSArray* args = sender.representedObject;
  [self moveItem:args[0] toSpace:args[1] pinned:[args[2] boolValue]];
}
- (void)menuArchiveOthers:(NSMenuItem*)sender { [self archiveTodayTabsRelativeTo:sender.representedObject mode:0]; }
- (void)menuArchiveAbove:(NSMenuItem*)sender { [self archiveTodayTabsRelativeTo:sender.representedObject mode:1]; }
- (void)menuArchiveBelow:(NSMenuItem*)sender { [self archiveTodayTabsRelativeTo:sender.representedObject mode:2]; }
- (void)menuResetPinned:(NSMenuItem*)sender { [self resetPinnedItem:sender.representedObject]; }
- (void)menuReplacePinned:(NSMenuItem*)sender { [self replacePinnedURLWithCurrent:sender.representedObject]; }
- (void)menuClose:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  if (item != _shown) [self showItem:item];
  [self closeCurrentTab];
}

// A user rename overrides the page title in the sidebar (Arc: "Rename Current Tab").
- (void)renameItem:(ArcItem*)item to:(NSString*)title {
  if (!item || !title.length) return;
  item.title = title;
  item.renamed = YES;
  [_outline reloadItem:item];
  [self scheduleSave];
}

- (ArcItem*)deepCopyItem:(ArcItem*)item {
  ArcItem* copy = [ArcItem new];
  copy.itemID = NSUUID.UUID.UUIDString;
  copy.url = item.url.length ? [self itemCurrentURL:item] : nil;
  copy.liveTitle = item.liveTitle;
  copy.renamed = item.renamed;
  copy.title = item.title;
  copy.isSplit = item.isSplit;
  copy.children = [NSMutableArray array];
  for (ArcItem* c in item.children) [copy.children addObject:[self deepCopyItem:c]];
  return copy;
}

// The copy goes right below the original in Today (a pinned tab's copy goes to the top of Today).
// A folder's copy goes right below the folder in the same section, named "<name> copy".
- (ArcItem*)duplicateItem:(ArcItem*)item {
  if (!_space) return nil;
  BOOL isFolder = !item.url.length && !item.isSection && !item.isSplit;
  if (isFolder) {
    ArcItem* copy = [self deepCopyItem:item];
    copy.title = [NSString stringWithFormat:@"%@ copy", item.displayTitle ?: @"Folder"];
    ArcItem* parent = [self parentOfItem:item];
    if (!parent) return nil;
    [parent.children insertObject:copy atIndex:[parent.children indexOfObject:item] + 1];
    [_outline reloadData];
    for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
    [_outline expandItem:copy];
    [self scheduleSave];
    return copy;
  }
  if (!item.url.length) return nil;
  ArcItem* copy = [ArcItem new];
  copy.itemID = NSUUID.UUID.UUIDString;
  copy.url = [self itemCurrentURL:item];
  copy.liveTitle = item.liveTitle;
  copy.renamed = item.renamed;
  copy.title = item.title;
  copy.children = [NSMutableArray array];
  ArcItem* parent = [self parentOfItem:item];
  if (parent.isSplit) {
    item = parent;
    parent = [self parentOfItem:parent];
  }
  if ([self sectionContaining:item] == _space.unpinned && parent)
    [parent.children insertObject:copy atIndex:[parent.children indexOfObject:item] + 1];
  else
    [_space.unpinned.children insertObject:copy atIndex:0];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  [self showItem:copy];
  return copy;
}

- (NSString*)itemCurrentURL:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return item.url;
  std::string url = it->second->GetMainFrame()->GetURL().ToString();
  return url.empty() ? item.url : [NSString stringWithUTF8String:url.c_str()];
}

- (NSUInteger)archiveTodayTabsRelativeTo:(ArcItem*)item mode:(int)mode {
  NSMutableArray<ArcItem*>* today = _space.unpinned.children;
  NSUInteger index = [today indexOfObject:item];
  if (index == NSNotFound) return 0;
  NSMutableArray<ArcItem*>* victims = [NSMutableArray array];
  for (NSUInteger i = 0; i < today.count; ++i) {
    ArcItem* t = today[i];
    if (t == item || t.isFolder) continue;
    if ((mode == 1 && i > index) || (mode == 2 && i < index)) continue;
    [victims addObject:t];
  }
  for (ArcItem* t in victims) {
    NSArray<ArcItem*>* tabs = t.isSplit ? [t.children copy] : @[ t ];
    for (ArcItem* tab in tabs) {
      [self archiveItem:tab space:_space reason:@"manual"];
      [self unloadItem:tab];
    }
    [today removeObject:t];
  }
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  if (![_space.allTabs containsObject:_shown]) {
    _shown = nil;
    [self showItem:item.isSplit ? item.children.firstObject : item];
  } else {
    [self layoutPanes];
  }
  return victims.count;
}

// Moving to another Space changes the profile, so the tab reloads there (Arc does the same).
- (BOOL)moveItem:(ArcItem*)item toSpace:(ArcSpace*)space pinned:(BOOL)pinned {
  if (!item || !space || space == _space || item.isSection) return NO;
  ArcItem* parent = [self parentOfItem:item];
  if (parent.isSplit) [self detachFromSplit:item keep:YES];
  BOOL removed = NO;
  for (ArcItem* section in [self sectionsOfSpace:_space]) removed = removed || RemoveItem(section, item);
  if (!removed) return NO;
  NSMutableArray<ArcItem*>* stack = [NSMutableArray arrayWithObject:item];
  while (stack.count) {
    ArcItem* t = stack.lastObject;
    [stack removeLastObject];
    if (t == _shown) _shown = nil;
    [self unloadItem:t];
    [stack addObjectsFromArray:t.children];
  }
  ArcItem* target = pinned ? space.pinned : space.unpinned;
  [target.children insertObject:item atIndex:pinned ? target.children.count : 0];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  if (!_shown) {
    ArcItem* first = _space.allTabs.firstObject;
    if (first) [self showItem:first];
    else [self layoutPanes];
  }
  return YES;
}

#pragma mark Command bar and tab actions

- (void)showCommandBarForNewTab:(BOOL)newTab {
  _commandOpensNewTab = newTab;
  if (!_commandBar) {
    _commandBar = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 640, 52)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskFullSizeContentView
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    _commandBar.titlebarAppearsTransparent = YES;
    _commandBar.titleVisibility = NSWindowTitleHidden;
    _commandBar.movable = NO;
    _commandBar.backgroundColor = NSColor.clearColor;
    _commandBar.opaque = NO;
    _commandBar.hasShadow = YES;
    // Arc's command bar: a large opaque card floating over the page, with a hairline under the input row.
    CommandCardView* card = [[CommandCardView alloc] initWithFrame:NSMakeRect(0, 0, 640, 60)];
    card.wantsLayer = YES;
    card.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [_commandBar.contentView addSubview:card];
    _commandDivider = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 640, 1)];
    _commandDivider.boxType = NSBoxCustom;
    _commandDivider.borderWidth = 0;
    _commandDivider.fillColor = [NSColor.labelColor colorWithAlphaComponent:0.10];
    [_commandBar.contentView addSubview:_commandDivider];
    _commandIcon = [NSImageView imageViewWithImage:[NSImage imageWithSystemSymbolName:@"magnifyingglass" accessibilityDescription:nil]];
    _commandIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightMedium];
    _commandIcon.contentTintColor = [NSColor.labelColor colorWithAlphaComponent:0.33];
    [_commandBar.contentView addSubview:_commandIcon];
    _commandField = [[NSTextField alloc] initWithFrame:NSMakeRect(48, 17, 576, 26)];
    _commandField.font = [NSFont systemFontOfSize:20];
    _commandField.bezeled = NO;
    _commandField.focusRingType = NSFocusRingTypeNone;
    _commandField.drawsBackground = NO;
    _commandField.delegate = self;
    [_commandBar.contentView addSubview:_commandField];
    _suggestionList = [CommandSuggestionList new];
    __weak MainWindowController* weakCmd = self;
    _suggestionList.iconForSuggestion = ^NSImage*(NSDictionary* s) {
      MainWindowController* me = weakCmd;
      ArcItem* item = [s[@"item"] isKindOfClass:ArcItem.class] ? s[@"item"] : nil;
      NSString* url = [s[@"url"] isKindOfClass:NSString.class] ? s[@"url"] : nil;
      if (!me || (!item && !url.length)) return nil;
      if (!item) {
        item = [ArcItem new];
        item.url = url;
      }
      NSImage* img = [me iconImageForItem:item];
      return img.isTemplate ? nil : img;  // no saved icon: the row keeps its kind symbol
    };
    _suggestionTable = [[NSTableView alloc] initWithFrame:NSMakeRect(0, 0, 640, 0)];
    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:@"s"];
    col.width = 620;
    [_suggestionTable addTableColumn:col];
    _suggestionTable.headerView = nil;
    _suggestionTable.rowHeight = kSuggestionRow - 2;
    _suggestionTable.backgroundColor = NSColor.clearColor;
    _suggestionTable.style = NSTableViewStylePlain;
    _suggestionTable.intercellSpacing = NSMakeSize(0, 2);
    _suggestionTable.dataSource = _suggestionList;
    _suggestionTable.delegate = _suggestionList;
    _suggestionTable.target = self;
    _suggestionTable.action = @selector(suggestionClicked:);
    _suggestionTable.refusesFirstResponder = YES;
    _suggestionScroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 640, 0)];
    _suggestionScroll.documentView = _suggestionTable;
    _suggestionScroll.drawsBackground = NO;
    [_commandBar.contentView addSubview:_suggestionScroll];
  }
  _commandField.placeholderString = @"Search or Enter URL...";
  _commandField.stringValue = (!newTab && _shown.url) ? _shown.url : @"";
  [self refreshSuggestions];
  [self.window addChildWindow:_commandBar ordered:NSWindowAbove];
  [_commandBar makeKeyAndOrderFront:nil];
  [_commandBar makeFirstResponder:_commandField];
  [_commandField selectText:nil];
}

// Lays the panel out for the current suggestions: field on top, list below, top edge fixed.
- (NSString*)commandBarStyle {  // tests
  NSColor* c = [CommandSelectedColor() colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  NSTableRowView* rv = _suggestionTable.numberOfRows ? [_suggestionTable rowViewAtRow:0 makeIfNecessary:YES] : nil;
  NSTableCellView* first = _suggestionTable.numberOfRows ? [_suggestionTable viewAtColumn:0 row:0 makeIfNecessary:YES] : nil;
  NSTextField* hint = [first viewWithTag:3];
  NSRect bf = _commandBar.frame, wf = self.window.frame;
  BOOL centred = _commandOpensNewTab ? fabs(NSMidX(bf) - NSMidX(wf)) <= 1 && NSMaxY(wf) - NSMaxY(bf) >= 80
                                     : fabs(NSMinX(bf) - NSMinX(wf) - 4) <= 1 && fabs(NSMaxY(wf) - NSMaxY(bf) - 42) <= 1;
  NSView* card = _commandBar.contentView.subviews.firstObject;
  return [NSString stringWithFormat:@"sel=%02X%02X%02X rowClass=%@ divider=%d placeholder=%@ cell=%@ width=%.0f font=%.0f card=%@ "
                                    @"row=%.0f hint=%@ scrim=%d centred=%d",
                                    (int)lround(c.redComponent * 255), (int)lround(c.greenComponent * 255),
                                    (int)lround(c.blueComponent * 255), NSStringFromClass(rv.class), !_commandDivider.hidden,
                                    _commandField.placeholderString, NSStringFromClass(first.class), NSWidth(bf),
                                    _commandField.font.pointSize, NSStringFromClass(card.class), kSuggestionRow,
                                    hint.stringValue.length ? hint.stringValue : @"-", _commandScrim && !_commandScrim.hidden, centred];
}
// Search suggestions (#31): the engine's own suggestions for what is typed, fetched shortly after typing stops.
// Not sent from Incognito, for URLs being typed, or when turned off in Settings.
- (void)fetchSearchSuggestions:(NSString*)text {
  NSString* q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if ([q isEqualToString:_suggestRequested]) return;
  _suggestRequested = q;
  [_suggestTask cancel];
  _suggestTask = nil;
  NSUInteger token = ++_suggestToken;
  BOOL urlish = [q containsString:@"://"] || ([q containsString:@"."] && ![q containsString:@" "] && q.length > 3 &&
                                              [q rangeOfString:@"." options:NSBackwardsSearch].location < q.length - 1 &&
                                              [q componentsSeparatedByString:@"."].lastObject.length <= 6);
  if (!q.length || urlish || _commandOpensIncognito || !SettingBool(kSettingSearchSuggestions)) {
    _searchSuggestions = nil;
    _suggestQuery = nil;
    return;
  }
  __weak MainWindowController* weakSelf = self;
  void (^apply)(NSArray<NSString*>*) = ^(NSArray<NSString*>* list) {
    MainWindowController* me = weakSelf;
    if (!me || token != me->_suggestToken) return;
    me->_searchSuggestions = list;
    me->_suggestQuery = q;
    if (me->_commandBar.isVisible) [me refreshSuggestions];
  };
  if (self.searchSuggestionStub || self.selfTestProfiles) {  // tests never touch the network
    dispatch_async(dispatch_get_main_queue(), ^{ apply(weakSelf.searchSuggestionStub[q.lowercaseString] ?: @[]); });
    return;
  }
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    MainWindowController* me = weakSelf;
    if (!me || token != me->_suggestToken) return;
    NSString* enc = [q stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet];
    enc = [enc stringByReplacingOccurrencesOfString:@"&" withString:@"%26"];
    enc = [enc stringByReplacingOccurrencesOfString:@"+" withString:@"%2B"];
    NSURL* url = [NSURL URLWithString:SuggestURLForQuery(enc)];
    if (!url) return;
    static NSURLSession* session;
    if (!session) {
      NSURLSessionConfiguration* c = NSURLSessionConfiguration.ephemeralSessionConfiguration;  // no cookies sent
      c.timeoutIntervalForRequest = 4;
      session = [NSURLSession sessionWithConfiguration:c];
    }
    me->_suggestTask = [session dataTaskWithURL:url completionHandler:^(NSData* d, NSURLResponse* r, NSError* e) {
      NSArray* list = e ? @[] : ParseSearchSuggestions(d);
      dispatch_async(dispatch_get_main_queue(), ^{ apply(list); });
    }];
    [me->_suggestTask resume];
  });
}

// Tests: what the command bar would list for this text once suggestions for it have arrived.
- (void)commandSuggestionsAfterFetch:(NSString*)text done:(void (^)(NSArray<NSDictionary*>*))done {
  [self fetchSearchSuggestions:text];
  __weak MainWindowController* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    done([weakSelf commandSuggestionsFor:text] ?: @[]);
  });
}

- (void)refreshSuggestions {
  [self fetchSearchSuggestions:_commandField.stringValue];
  _suggestionList.items = [self commandSuggestionsFor:_commandField.stringValue];
  [_suggestionTable reloadData];
  if (_suggestionList.items.count) [_suggestionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
  // Arc: centred over the window, about a fifth of the way down; up to 680 pt wide; 60 pt input row with a 20 pt
  // font, then 40 pt rows with 8 pt of padding.
  CGFloat listH = _suggestionList.items.count * kSuggestionRow + (_suggestionList.items.count ? 16 : 0);
  CGFloat h = 64 + listH;
  NSRect f = self.window.frame;
  // Arc (measured from its own videos): about two thirds of the window wide, top a quarter of the way down.
  CGFloat W = round(MIN(780, MAX(480, f.size.width * 0.65)));
  CGFloat top = NSMaxY(f) - MAX(80, round(f.size.height * 0.26));
  if (top - h < NSMinY(f) + 20) top = MIN(NSMaxY(f) - 60, NSMinY(f) + 20 + h);
  CGFloat left = round(NSMidX(f) - W / 2);
  // Arc: Cmd+L (and clicking the address) opens the bar in place, its top-left on the address pill's, reaching
  // out over the page; only a new tab (Cmd+T) gets the big centred bar.
  BOOL inPlace = !_commandOpensNewTab && ![self sidebarCollapsed];
  if (inPlace) {
    NSRect pill = [self.window convertRectToScreen:[_addressPill convertRect:_addressPill.bounds toView:nil]];
    W = round(MIN(640, f.size.width - 16));
    left = NSMinX(pill) - 4;
    top = NSMaxY(pill) + 4;
  }
  [_commandBar setFrame:NSMakeRect(left, top - h, W, h) display:YES];
  _commandIcon.frame = NSMakeRect(18, h - 42, 20, 20);
  _commandIcon.contentTintColor = [NSColor colorWithWhite:IsDark(_commandBar.contentView) ? 1 : 0 alpha:0.33];
  _commandField.frame = NSMakeRect(48, h - 45, W - 48 - 16, 26);
  _suggestionScroll.frame = NSMakeRect(8, 8, W - 16, MAX(0, listH - 16));
  _suggestionTable.tableColumns.firstObject.width = W - 16;
  _suggestionScroll.hidden = listH == 0;
  _commandDivider.frame = NSMakeRect(0, h - 64, W, 1);
  if (inPlace) _commandScrim.hidden = YES;
  else [self updateCommandScrim];
  _commandDivider.hidden = listH == 0;
}

static NSString* HostOf(NSString* url) {
  NSString* h = [NSURL URLWithString:url].host ?: @"";
  return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

// Match score: 0 = no match. Title/host prefix beats a substring anywhere.
static double MatchScore(NSString* q, NSString* title, NSString* url) {
  if (!q.length) return 1;
  NSString* t = title.lowercaseString ?: @"", *u = url.lowercaseString ?: @"", *h = HostOf(url).lowercaseString;
  if ([h hasPrefix:q]) return 6;
  if ([t hasPrefix:q]) return 5;
  if ([t rangeOfString:[@" " stringByAppendingString:q]].location != NSNotFound) return 4;
  if ([t containsString:q]) return 3;
  if ([u containsString:q]) return 2;
  return 0;
}

- (void)collectMenuActions:(NSMenu*)menu query:(NSString*)q into:(NSMutableArray*)out {
  for (NSMenuItem* mi in menu.itemArray) {
    if (mi.submenu) {
      [self collectMenuActions:mi.submenu query:q into:out];
      continue;
    }
    if (mi.isSeparatorItem || !mi.action || !mi.title.length || mi.hidden) continue;
    if (mi.action == @selector(newTab:) || mi.action == @selector(openLocation:)) continue;  // we're already here
    double m = MatchScore(q, mi.title, nil);
    if (m <= 0) continue;
    [out addObject:@{ @"kind" : @"action", @"title" : mi.title, @"subtitle" : menu.title ?: @"",
                      @"key" : [@"action:" stringByAppendingString:NSStringFromSelector(mi.action)], @"item" : mi,
                      @"score" : @(m + 0.5) }];
  }
}

- (NSArray<NSDictionary*>*)commandSuggestionsFor:(NSString*)text {
  NSString* q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
  NSDictionary* picks = SettingObject(kSettingCommandPicks);
  BOOL urlOnly = _commandOpensSplit || _commandOpensLittle || _commandOpensIncognito;
  NSMutableArray<NSDictionary*>* out = [NSMutableArray array];
  NSMutableSet<NSString*>* seenURLs = [NSMutableSet set];
  if (!_history && self.historyPath) _history = [[HistoryStore alloc] initWithPath:self.historyPath];

  if (!q.length) {
    // Empty field: most visited sites.
    NSCountedSet* hosts = [NSCountedSet set];
    NSMutableDictionary* lastURL = [NSMutableDictionary dictionary];
    for (ArchivedTab* v in _history.visits) {
      NSString* h = HostOf(v.url);
      if (!h.length) continue;
      [hosts addObject:h];
      lastURL[h] = [NSString stringWithFormat:@"https://%@/", [NSURL URLWithString:v.url].host];
    }
    NSArray* top = [hosts.allObjects sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
      NSUInteger ca = [hosts countForObject:a], cb = [hosts countForObject:b];
      return ca == cb ? [a compare:b] : (ca > cb ? NSOrderedAscending : NSOrderedDescending);
    }];
    for (NSString* h in top) {
      if (out.count >= 6) break;
      [out addObject:@{ @"kind" : @"site", @"title" : h, @"subtitle" : @"", @"key" : [@"site:" stringByAppendingString:h],
                        @"url" : lastURL[h] }];
    }
    return out;
  }

  NSMutableArray<NSDictionary*>* ranked = [NSMutableArray array];
  if (!urlOnly) {
    for (ArcSpace* sp in _spaces) {
      for (ArcItem* t in [self tabsIn:[self sectionsOfSpace:sp]]) {
        NSString* url = t.url;
        double m = MatchScore(q, t.displayTitle, url);
        if (m <= 0 || t == _shown) continue;
        [seenURLs addObject:url ?: @""];
        double bonus = (t.browserId ? 1.5 : 1.0) + (sp == _space ? 0.3 : 0);
        [ranked addObject:@{ @"kind" : @"tab", @"title" : t.displayTitle ?: url, @"subtitle" :
                               sp == _space ? HostOf(url) : [NSString stringWithFormat:@"%@ · %@", HostOf(url), sp.title],
                             @"key" : [@"tab:" stringByAppendingString:t.itemID ?: url], @"item" : t, @"space" : sp,
                             @"score" : @(m + bonus) }];
      }
      double m = MatchScore(q, sp.title, nil);
      if (m > 0 && sp != _space)
        [ranked addObject:@{ @"kind" : @"space", @"title" : sp.iconEmoji.length ? [NSString stringWithFormat:@"%@ %@", sp.iconEmoji, sp.title] : sp.title,
                             @"subtitle" : @"Switch Space", @"key" : [@"space:" stringByAppendingString:sp.spaceID ?: sp.title],
                             @"space" : sp, @"score" : @(m + 1.2) }];
    }
    [self collectMenuActions:NSApp.mainMenu query:q into:ranked];
  }
  NSUInteger scanned = 0;
  for (ArchivedTab* v in _history.visits.reverseObjectEnumerator) {
    if (++scanned > 5000) break;
    if ([seenURLs containsObject:v.url]) continue;
    double m = MatchScore(q, v.title, v.url);
    if (m <= 0) continue;
    [seenURLs addObject:v.url];
    [ranked addObject:@{ @"kind" : @"history", @"title" : v.title.length ? v.title : v.url, @"subtitle" : HostOf(v.url),
                         @"key" : [@"url:" stringByAppendingString:v.url], @"url" : v.url, @"score" : @(m) }];
  }
  // Learned ranking: every earlier pick of the same suggestion adds weight (capped).
  NSArray* sorted = [ranked sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    double sa = [a[@"score"] doubleValue] + MIN(10, [picks[a[@"key"]] doubleValue]) * 1.5;
    double sb = [b[@"score"] doubleValue] + MIN(10, [picks[b[@"key"]] doubleValue]) * 1.5;
    return sa == sb ? NSOrderedSame : (sa > sb ? NSOrderedAscending : NSOrderedDescending);
  }];
  NSString* resolved = ResolveCommandBarInput(text) ?: text;
  BOOL looksURL = ![resolved containsString:@"?q="] && ![resolved containsString:@"search?"];
  [out addObject:@{ @"kind" : @"go", @"title" : text, @"subtitle" : looksURL ? resolved : @"Search", @"key" : @"go", @"text" : text }];
  NSString* typed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  if (_searchSuggestions.count && [_suggestQuery isEqualToString:typed]) {
    NSUInteger added = 0;
    for (NSString* s in _searchSuggestions) {
      if (added >= 3) break;
      if ([s.lowercaseString isEqualToString:q]) continue;
      [out addObject:@{ @"kind" : @"search", @"title" : s, @"subtitle" : @"Search", @"key" : @"go", @"text" : s }];
      ++added;
    }
  }
  for (NSDictionary* d in sorted) {
    if (out.count >= kMaxSuggestions) break;
    [out addObject:d];
  }
  // Max (#58): "Ask ChatGPT" for typed questions, last so it never pushes tabs or history down.
  if (!urlOnly)
    if (NSDictionary* ask = [self maxChatGPTSuggestionFor:text]) [out addObject:ask];
  return out;
}

- (void)suggestionClicked:(id)sender {
  NSInteger row = _suggestionTable.clickedRow;
  if (row >= 0 && row < (NSInteger)_suggestionList.items.count) [self performCommandSuggestion:_suggestionList.items[row]];
}

- (void)performCommandSuggestion:(NSDictionary*)s {
  NSString* kind = s[@"kind"];
  if (![kind isEqualToString:@"go"]) {
    NSMutableDictionary* picks = [SettingObject(kSettingCommandPicks) mutableCopy] ?: [NSMutableDictionary dictionary];
    picks[s[@"key"]] = @([picks[s[@"key"]] integerValue] + 1);
    if (picks.count > 500) [picks removeAllObjects];  // keep it small; ranking simply relearns
    SettingSetObject(kSettingCommandPicks, picks);
  }
  BOOL split = _commandOpensSplit, little = _commandOpensLittle, newTab = _commandOpensNewTab;
  BOOL incognito = _commandOpensIncognito;
  _commandOpensSplit = NO;
  _commandOpensLittle = NO;
  _commandOpensIncognito = NO;
  if (_commandBar.isVisible) [self hideCommandBar];
  if ([kind isEqualToString:@"tab"]) {
    ArcSpace* sp = s[@"space"];
    if (sp != _space) [self switchToSpace:sp];
    [self showItem:s[@"item"]];
  } else if ([kind isEqualToString:@"space"]) {
    [self switchToSpace:s[@"space"]];
  } else if ([kind isEqualToString:@"chatgpt"]) {
    [self openInNewTab:s[@"url"]];  // always a new tab, in this Space's own chatgpt.com sign-in
  } else if ([kind isEqualToString:@"action"]) {
    NSMenuItem* mi = s[@"item"];
    [NSApp sendAction:mi.action to:mi.target from:mi];
  } else {
    NSString* target = s[@"url"] ?: s[@"text"];
    if (incognito) [self openIncognitoWindow:target];
    else if (little) [self openLittleWindow:target];
    else if (split) [self openInSplit:target horizontal:_pendingSplitHorizontal before:_splitBefore];
    else if (newTab) [self openInNewTab:target];
    else [self navigateCurrentTab:target];
  }
}

// Arc dims the whole window in the Space's colour while the command bar is open, and fills the selected row with
// that colour, a shade deeper (Arc blue on the default theme).
- (NSColor*)commandSpaceColor {
  NSColor* c = _space.themeColors.count ? ColorFromHex(_space.themeColors.firstObject) : nil;
  return [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
}
- (void)updateCommandScrim {
  NSView* root = self.window.contentView;
  if (!_commandScrim) {
    _commandScrim = [[NSView alloc] initWithFrame:root.bounds];
    _commandScrim.wantsLayer = YES;
    _commandScrim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // A click anywhere outside the bar closes it, as in Arc.
    [_commandScrim addGestureRecognizer:[[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(hideCommandBar)]];
  }
  NSColor* sc = [self commandSpaceColor];
  BOOL dark = IsDark(root);
  NSColor* tint = sc ?: (dark ? ColorFromHex(@"#120C39") : [NSColor colorWithWhite:0.9 alpha:1]);
  _commandScrim.layer.backgroundColor = [tint colorWithAlphaComponent:dark ? 0.55 : 0.5].CGColor;
  _commandScrim.frame = root.bounds;
  if (_commandScrim.superview != root) [root addSubview:_commandScrim positioned:NSWindowAbove relativeTo:nil];
  _commandScrim.hidden = NO;
  if (sc) {
    CGFloat hh, ss, bb, aa;
    [sc getHue:&hh saturation:&ss brightness:&bb alpha:&aa];
    gCommandPillColor = [NSColor colorWithHue:hh saturation:MIN(1, ss * 1.15 + 0.1) brightness:MAX(0.25, bb * 0.72) alpha:1];
  } else {
    gCommandPillColor = nil;
  }
}
- (void)hideCommandBar {
  _commandScrim.hidden = YES;
  [self.window removeChildWindow:_commandBar];
  [_commandBar orderOut:nil];
  [self.window makeKeyWindow];
}

- (BOOL)control:(NSControl*)control textView:(NSTextView*)textView doCommandBySelector:(SEL)command {
  if (control == _findField) {
    if (command == @selector(insertNewline:)) {
      BOOL shift = (NSApp.currentEvent.modifierFlags & NSEventModifierFlagShift) != 0;
      [self findText:_findField.stringValue forward:!shift];
      return YES;
    }
    if (command == @selector(cancelOperation:)) {
      [self hideFindBar];
      return YES;
    }
    return NO;
  }
  if (command == @selector(moveDown:) || command == @selector(moveUp:)) {
    NSInteger n = (NSInteger)_suggestionList.items.count;
    if (!n) return YES;
    NSInteger r = _suggestionTable.selectedRow + (command == @selector(moveDown:) ? 1 : -1);
    r = (r + n) % n;
    [_suggestionTable selectRowIndexes:[NSIndexSet indexSetWithIndex:r] byExtendingSelection:NO];
    [_suggestionTable scrollRowToVisible:r];
    return YES;
  }
  if (command == @selector(insertNewline:) && _suggestionTable.selectedRow >= 0 &&
      _suggestionTable.selectedRow < (NSInteger)_suggestionList.items.count &&
      ![_suggestionList.items[_suggestionTable.selectedRow][@"kind"] isEqualToString:@"go"]) {
    [self performCommandSuggestion:_suggestionList.items[_suggestionTable.selectedRow]];
    return YES;
  }
  if (command == @selector(insertNewline:)) {
    NSString* text = _commandField.stringValue;
    [self hideCommandBar];
    if (!_commandOpensIncognito && !_commandOpensLittle && [text containsString:@"\n"] && [self openSplitFromText:text]) {
      _commandOpensSplit = NO;  // a pasted shared split: one split with all its pages
      return YES;
    }
    if (_commandOpensIncognito) [self openIncognitoWindow:text];
    else if (_commandOpensLittle) [self openLittleWindow:text];
    else if (_commandOpensSplit) [self openInSplit:text horizontal:_pendingSplitHorizontal before:_splitBefore];
    else if (_commandOpensNewTab) [self openInNewTab:text];
    else [self navigateCurrentTab:text];
    _commandOpensSplit = NO;
    _commandOpensLittle = NO;
    _commandOpensIncognito = NO;
    return YES;
  }
  if (command == @selector(cancelOperation:)) {
    _commandOpensSplit = NO;
    _commandOpensLittle = NO;
    _commandOpensIncognito = NO;
    [self hideCommandBar];
    return YES;
  }
  return NO;
}

- (IBAction)newTab:(id)sender {
  _commandOpensSplit = NO;
  _commandOpensLittle = NO;
  _commandOpensIncognito = NO;
  [self showCommandBarForNewTab:YES];
}
- (IBAction)openLocation:(id)sender { [self showCommandBarForNewTab:NO]; }
- (IBAction)closeTab:(id)sender { [self closeCurrentTab]; }

- (void)openInNewTab:(NSString*)input background:(BOOL)background {
  if (!background) {
    [self openInNewTab:input];
    return;
  }
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space) return;
  ArcItem* tab = [ArcItem new];
  tab.itemID = NSUUID.UUID.UUIDString;
  tab.url = url;
  tab.children = [NSMutableArray array];
  tab.lastActiveAt = [NSDate date];
  [_space.unpinned.children insertObject:tab atIndex:0];
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];  // the web view is created when the tab is first shown
}

// Arc puts new tabs at the top of the current Space's Today section.
- (void)openInNewTab:(NSString*)input {
  if ([input hasPrefix:@"notarc://easel/"]) {  // an easel reopened from the archive
    NSString* eid = [input substringFromIndex:@"notarc://easel/".length];
    if (eid.length && [eid rangeOfString:@"/"].location == NSNotFound) [self createEaselWithID:eid];
    return;
  }
  if ([input hasPrefix:@"notarc://note/"]) {  // a note reopened from the archive
    [self createNoteWithID:[input substringFromIndex:@"notarc://note/".length]];
    return;
  }
  NSString* url = ResolveCommandBarInput(input);
  if (!url || !_space) return;
  ArcItem* tab = [ArcItem new];
  tab.itemID = NSUUID.UUID.UUIDString;
  tab.url = url;
  tab.children = [NSMutableArray array];
  [_space.unpinned.children insertObject:tab atIndex:0];
  [_outline reloadItem:_space.unpinned reloadChildren:YES];
  [self scheduleSave];
  [self showItem:tab];
}

- (void)navigateCurrentTab:(NSString*)input {
  NSString* url = ResolveCommandBarInput(input);
  if (!url) return;
  if (!_shown) {
    [self openInNewTab:input];
    return;
  }
  auto it = _browsers.find(_shown.browserId);
  if (it == _browsers.end()) {
    // The tab's web view isn't created yet (its Space profile is still starting): load the new
    // address when it is, instead of dropping it.
    _shown.url = url;
    [self ensureBrowserForItem:_shown];
    [self scheduleSave];
    return;
  }
  it->second->GetMainFrame()->LoadURL(url.UTF8String);
}

static BOOL RemoveItem(ArcItem* parent, ArcItem* target) {
  if ([parent.children containsObject:target]) {
    [parent.children removeObject:target];
    return YES;
  }
  for (ArcItem* child in parent.children)
    if (RemoveItem(child, target)) return YES;
  return NO;
}

- (void)unloadItem:(ArcItem*)item {
  auto it = _browsers.find(item.browserId);
  if (it != _browsers.end()) {
    ChromePageHost* host = _chromePages[@(it->first)];
    if (host) {
      [host close];
      [_chromePages removeObjectForKey:@(it->first)];
    } else {
      NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(it->second->GetHost()->GetWindowHandle());
      it->second->GetHost()->CloseBrowser(true);
      [view removeFromSuperview];  // child browsers are torn down when their view goes away
    }
    [gBrowserOwners removeObjectForKey:@(it->first)];
    _browsers.erase(it);
  }
  item.browserId = 0;
}

- (void)archiveItem:(ArcItem*)item space:(ArcSpace*)space reason:(NSString*)reason {
  if (!item.url.length) return;
  ArchivedTab* t = [ArchivedTab new];
  t.url = item.url;
  t.title = item.displayTitle;
  t.spaceID = space.spaceID;
  t.reason = reason;
  t.archivedAt = [NSDate date];
  [[self archive] addObject:t];
  if (self.archivePath) ArchiveStoreSave(_archive, self.archivePath);
}

- (NSMutableArray<ArchivedTab*>*)archive {
  if (!_archive) _archive = self.archivePath ? ArchiveStoreLoad(self.archivePath) : [NSMutableArray array];
  return _archive;
}

- (NSArray*)archivedTabs { return [self archive]; }

- (NSUndoManager*)sidebarUndoManager {
  if (!_undo) _undo = [NSUndoManager new];
  return _undo;
}
- (NSUndoManager*)windowWillReturnUndoManager:(NSWindow*)window { return [self sidebarUndoManager]; }
- (IBAction)undoCloseTab:(id)sender {
  if ([[self sidebarUndoManager].undoActionName isEqualToString:@"Close Tab"]) [[self sidebarUndoManager] undo];
}

// Undo of closing a Today tab: put it back where it was and take it out of the Archive.
- (void)restoreClosedItem:(ArcItem*)item parent:(ArcItem*)parent index:(NSUInteger)index
                    space:(ArcSpace*)space archived:(ArchivedTab*)archived {
  if (archived && [[self archive] containsObject:archived]) {
    [_archive removeObject:archived];
    if (self.archivePath) ArchiveStoreSave(_archive, self.archivePath);
  }
  if (space != _space && [_spaces containsObject:space]) [self switchToSpace:space];
  if (!Contains(space.unpinned, parent) && parent != space.unpinned) parent = space.unpinned;
  if (!Contains(space.unpinned, item))
    [parent.children insertObject:item atIndex:MIN(index, parent.children.count)];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
  [self showItem:item];
  __weak MainWindowController* weakSelf = self;
  [[self sidebarUndoManager] registerUndoWithTarget:self handler:^(id target) {
    MainWindowController* me = weakSelf;
    if (!me) return;
    [me showItem:item];
    [me closeCurrentTab];
  }];
  [[self sidebarUndoManager] setActionName:@"Close Tab"];
}

- (void)closeCurrentTab { [self closeSidebarTab:_shown]; }
- (void)rowCloseClicked:(NSButton*)sender {
  NSInteger row = [_outline rowForView:sender];
  ArcItem* item = row >= 0 ? [_outline itemAtRow:row] : nil;
  if (item.isSplit && item == [self splitGroupOfShown]) item = _shown;  // the split row closes its shown pane
  else if (item.isSplit) item = item.children.firstObject;
  if (item) [self closeSidebarTab:item];
}
- (NSString*)tabRowAccessoriesForItem:(ArcItem*)item {  // tests (visual parity V2)
  NSInteger row = [_outline rowForItem:item];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  RowCloseButton* b = [cell viewWithTag:81];
  NSTextField* l = cell.textField;
  BOOL ellipsis = l.lineBreakMode == NSLineBreakByTruncatingTail;
  BOOL roomForClose = b && (b.hidden || NSMaxX(l.frame) <= NSMinX(b.frame));
  return [NSString stringWithFormat:@"close=%d ellipsis=%d room=%d", b && !b.hidden, ellipsis, roomForClose];
}
- (void)reloadSidebarItemForTest:(ArcItem*)item { [_outline reloadItem:item]; }
- (BOOL)pressCloseButtonOfItem:(ArcItem*)item {  // tests
  NSInteger row = [_outline rowForItem:item];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  RowCloseButton* b = [cell viewWithTag:81];
  if (!b.applies) return NO;
  [self rowCloseClicked:b];
  return YES;
}

// Closes one tab: the shown one (then the next open tab is shown) or any other row's close button (the shown tab
// stays). Today tabs are archived and removed; pinned tabs and Favorites are unloaded and keep their place.
- (void)closeSidebarTab:(ArcItem*)item {
  if (!item) return;
  BOOL wasShown = item == _shown;
  NSArray<ArcItem*>* tabs = _space.allTabs;
  NSUInteger index = [tabs indexOfObject:item];
  BOOL isToday = Contains(_space.unpinned, item);
  ArcItem* undoParent = nil;
  NSUInteger undoIndex = 0;
  if (isToday && ![self parentOfItem:item].isSplit) {
    undoParent = [self parentOfItem:item];
    undoIndex = [undoParent.children indexOfObject:item];
  }
  NSUInteger archiveCountBefore = [self archive].count;
  // A closed pinned pane stays pinned (unloaded) next to its split; a Today pane is archived.
  if ([self parentOfItem:item].isSplit) [self detachFromSplit:item keep:!isToday];
  if (isToday) [self archiveItem:item space:_space reason:@"manual"];  // Arc archives closed Today tabs
  ArchivedTab* archived = [self archive].count > archiveCountBefore ? _archive.lastObject : nil;
  [self unloadItem:item];
  if (undoParent) {
    ArcSpace* space = _space;
    __weak MainWindowController* weakSelf = self;
    [[self sidebarUndoManager] registerUndoWithTarget:self handler:^(id target) {
      [weakSelf restoreClosedItem:item parent:undoParent index:undoIndex space:space archived:archived];
    }];
    [[self sidebarUndoManager] setActionName:@"Close Tab"];
  }
  // Close and Keep Pinned: the tab stays and reopens at its saved URL.
  if (!isToday && item.pinnedURL.length) {
    item.url = item.pinnedURL;
    item.liveTitle = nil;
  }
  // Pinned tabs and Favorites stay in the sidebar (Arc just unloads them); Today tabs are removed.
  if (RemoveItem(_space.unpinned, item)) [_outline reloadItem:_space.unpinned reloadChildren:YES];
  else [_outline reloadItem:item];
  [self scheduleSave];
  if (!wasShown) {
    NSInteger row = _shown ? [_outline rowForItem:_shown] : -1;
    BOOL syncing = _syncingSidebar;
    _syncingSidebar = YES;  // only the highlight moves back; the shown tab doesn't change
    if (row >= 0) [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    else [_outline deselectAll:nil];
    _syncingSidebar = syncing;
    return;
  }
  _shown = nil;
  NSArray<ArcItem*>* remaining = _space.allTabs;
  ArcItem* next = nil;
  for (NSUInteger i = MIN(index, remaining.count); i < remaining.count && !next; ++i)
    if (remaining[i].browserId) next = remaining[i];
  for (ArcItem* t in remaining)
    if (!next && t.browserId) next = t;
  if (next) [self showItem:next];
  else [_outline deselectAll:nil];
}

#pragma mark Sidebar organisation

static ArcItem* ParentOf(ArcItem* root, ArcItem* target) {
  for (ArcItem* child in root.children) {
    if (child == target) return root;
    ArcItem* found = ParentOf(child, target);
    if (found) return found;
  }
  return nil;
}

static BOOL Contains(ArcItem* root, ArcItem* target) {
  if (root == target) return YES;
  for (ArcItem* child in root.children)
    if (Contains(child, target)) return YES;
  return NO;
}

- (NSArray<ArcItem*>*)sectionsOfSpace:(ArcSpace*)space {
  NSMutableArray* out = [NSMutableArray array];
  if (space.favorites) [out addObject:space.favorites];
  if (space.pinned) [out addObject:space.pinned];
  if (space.unpinned) [out addObject:space.unpinned];
  return out;
}

- (ArcItem*)parentOfItem:(ArcItem*)item {
  for (ArcItem* section in [self sectionsOfSpace:_space]) {
    ArcItem* parent = ParentOf(section, item);
    if (parent) return parent;
  }
  return nil;
}

- (ArcItem*)sectionContaining:(ArcItem*)item {
  for (ArcItem* section in [self sectionsOfSpace:_space])
    if (Contains(section, item)) return section;
  return nil;
}

- (ArcItem*)currentPinnedSection { return _space.pinned; }

- (BOOL)moveItem:(ArcItem*)item toParent:(ArcItem*)parent index:(NSInteger)index {
  if (!item || !parent || item.isSection) return NO;
  if (!(parent.isSection || parent.isFolder)) return NO;
  if (parent.liveKind) return NO;  // a Live Folder's tabs come from its feed
  if (Contains(item, parent)) return NO;  // a folder can't go inside itself
  ArcItem* oldParent = [self parentOfItem:item];
  if (!oldParent || ![self sectionContaining:parent]) return NO;  // both must be in the current Space
  NSInteger oldIndex = [oldParent.children indexOfObject:item];
  [oldParent.children removeObjectAtIndex:oldIndex];
  if (oldParent == parent && index > oldIndex) index -= 1;  // removal shifted the target slot
  index = MAX(0, MIN(index, (NSInteger)parent.children.count));
  [parent.children insertObject:item atIndex:index];
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  if (parent.isFolder) [_outline expandItem:parent];
  if (_shown) [self selectSidebarRowFor:_shown];
  [self scheduleSave];
  return YES;
}

#pragma mark Live Folders

static const NSUInteger kLiveFolderMaxItems = 25;
static const NSTimeInterval kLiveFolderRefreshInterval = 15 * 60;
static NSString* const kSpaceStartingError = @"The Space is still starting";

- (ArcItem*)createLiveFolderKind:(NSString*)kind source:(NSString*)source title:(NSString*)title {
  if (!_space || !kind.length || !source.length) return nil;
  ArcItem* f = [self createFolderNamed:title.length ? title : source];
  f.liveKind = kind;
  f.liveSource = source;
  f.liveDismissed = [NSMutableArray array];
  [_outline reloadItem:f];
  [self refreshLiveFolder:f done:nil];
  return f;
}
- (NSString*)askLiveFolderSource:(NSString*)message info:(NSString*)info placeholder:(NSString*)placeholder value:(NSString*)value {
  NSAlert* alert = [NSAlert new];
  alert.messageText = message;
  alert.informativeText = info;
  [alert addButtonWithTitle:@"Create"];
  [alert addButtonWithTitle:@"Cancel"];
  NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
  field.placeholderString = placeholder;
  if (value.length) field.stringValue = value;
  alert.accessoryView = field;
  alert.window.initialFirstResponder = field;
  return [alert runModal] == NSAlertFirstButtonReturn ? field.stringValue : nil;
}
- (IBAction)newLiveFolder:(id)sender {
  NSString* cur = _shown && !_shown.noteID && !_shown.easelID ? [self itemCurrentURL:_shown] : nil;
  NSString* input = [self askLiveFolderSource:@"New Live Folder"
                                         info:@"Enter a feed address (RSS or Atom), a GitHub repository like github.com/owner/repo for "
                                               "its open pull requests (add /issues for its issues instead), or a YouTube channel. "
                                               "The folder keeps itself up to date."
                                  placeholder:@"github.com/owner/repo or https://example.com/feed.xml"
                                        value:[cur hasPrefix:@"https://github.com/"] ? cur : nil];
  if (input) [self createLiveFolderFromInput:input done:nil];
}
- (IBAction)newYouTubeLiveFolder:(id)sender {
  NSString* cur = _shown && !_shown.noteID && !_shown.easelID ? [self itemCurrentURL:_shown] : nil;
  NSString* input = [self askLiveFolderSource:@"New YouTube Live Folder"
                                         info:@"Enter a YouTube channel's address or @handle. Its newest videos show up in the "
                                               "folder (from YouTube's public channel feed)."
                                  placeholder:@"youtube.com/@channel"
                                        value:[[NSURL URLWithString:cur ?: @""].host.lowercaseString hasSuffix:@"youtube.com"] ? cur : nil];
  if (input) [self createLiveFolderFromInput:input done:nil];
}
- (IBAction)newMyPullRequestsFolder:(id)sender { [self createMyPullRequestsFolder]; }
// Your open pull requests and the ones waiting for your review, read from github.com with this Space's own sign-in.
// One per Space: asking again shows the existing folder and refreshes it.
- (ArcItem*)createMyPullRequestsFolder {
  if (!_space) return nil;
  NSMutableArray<ArcItem*>* mine = [NSMutableArray array];
  [self collectLiveFolders:_space.pinned into:mine];
  [self collectLiveFolders:_space.unpinned into:mine];
  for (ArcItem* f in mine)
    if ([f.liveKind isEqualToString:@"github-mine"]) {
      [_outline expandItem:f];
      [self refreshLiveFolder:f done:nil];
      return f;
    }
  return [self createLiveFolderKind:@"github-mine" source:@"@me" title:@"My Pull Requests"];
}
// Creates a Live Folder from what the user typed. YouTube addresses are read once to find the channel id.
- (void)createLiveFolderFromInput:(NSString*)input done:(void (^)(ArcItem* folder))done {
  NSDictionary* src = LiveFolderSourceFromInput(input, NO);
  if (!src) {
    if (!self.selfTestProfiles) NSBeep();
    if (done) done(nil);
    return;
  }
  NSString* kind = src[@"kind"], *source = src[@"source"];
  if ([kind isEqualToString:@"youtube"]) {
    NSString* page = src[@"resolve"] ?: [@"https://www.youtube.com/channel/" stringByAppendingString:source];
    __weak MainWindowController* weakSelf = self;
    LiveFolderResolveYouTube(page, ^(NSString* channelID, NSString* name, NSString* error) {
      MainWindowController* me = weakSelf;
      NSString* cid = channelID ?: source;  // a /channel/ address still works if its page couldn't be read
      if (!me || !cid) {
        if (me && !me.selfTestProfiles) {
          NSAlert* a = [NSAlert new];
          a.messageText = @"Couldn't find that YouTube channel";
          a.informativeText = error ?: @"";
          [a runModal];
        }
        if (done) done(nil);
        return;
      }
      ArcItem* f = [me createLiveFolderKind:@"youtube" source:cid title:name.length ? name : @"YouTube"];
      if (done) done(f);
    });
    return;
  }
  NSString* title = [kind isEqualToString:@"feed"] ? ([NSURL URLWithString:source].host ?: source)
                    : [NSString stringWithFormat:@"%@ %@", source.lastPathComponent,
                                                 [kind isEqualToString:@"github-prs"] ? @"Pull Requests" : @"Issues"];
  ArcItem* f = [self createLiveFolderKind:kind source:source title:title];
  if (done) done(f);
}
- (void)menuRefreshLive:(NSMenuItem*)mi { [self refreshLiveFolder:mi.representedObject done:nil]; }
- (void)menuDismissLive:(NSMenuItem*)mi {
  BOOL wasShown = mi.representedObject == _shown;
  [self dismissLiveFolderTab:mi.representedObject];
  if (wasShown) [self layoutPanes];
}
- (void)collectLiveFolders:(ArcItem*)item into:(NSMutableArray*)out {
  if (item.liveKind) [out addObject:item];
  for (ArcItem* c in item.children) [self collectLiveFolders:c into:out];
}
- (void)refreshStaleLiveFolders {
  NSMutableArray* all = [NSMutableArray array];
  for (ArcSpace* sp in _spaces) {
    [self collectLiveFolders:sp.pinned into:all];
    [self collectLiveFolders:sp.unpinned into:all];
  }
  for (ArcItem* f in all)
    if (!f.liveRefreshedAt || -f.liveRefreshedAt.timeIntervalSinceNow > kLiveFolderRefreshInterval) [self refreshLiveFolder:f done:nil];
}
// Merge fetched entries into the folder: keep tabs still in the feed (and their pages), add new ones in feed
// order, drop ones that left the feed. Entries the user closed are remembered and not added back.
- (void)applyLiveEntries:(NSArray<LiveFolderEntry*>*)entries toFolder:(ArcItem*)f {
  NSMutableDictionary<NSString*, ArcItem*>* existing = [NSMutableDictionary dictionary];
  for (ArcItem* c in f.children) {
    NSString* key = c.pinnedURL ?: c.url;
    if (key) existing[key] = c;
  }
  NSMutableArray<ArcItem*>* next = [NSMutableArray array];
  NSMutableSet* seen = [NSMutableSet set];
  for (LiveFolderEntry* e in entries) {
    if ([seen containsObject:e.url] || [f.liveDismissed containsObject:e.url]) continue;
    [seen addObject:e.url];
    ArcItem* c = existing[e.url];
    if (!c) {
      c = [ArcItem new];
      c.itemID = NSUUID.UUID.UUIDString;
      c.url = e.url;
      c.pinnedURL = e.url;  // like a pinned tab: closing it returns it to the feed's address
      c.children = [NSMutableArray array];
      // Arc: new entries come in unread once the folder has been filled (not the first fill, not status entries).
      c.liveUnread = f.liveFilled && ![e.url isEqualToString:kLiveFolderGitHubSignInURL] &&
                     ![e.url isEqualToString:kLiveFolderGitHubNoneURL];
    }
    c.title = e.title;
    [next addObject:c];
  }
  for (ArcItem* c in f.children)
    if (![next containsObject:c]) {
      if (c == _shown) continue;  // never pull the page you're reading out from under you
      [self unloadItem:c];
    }
  for (ArcItem* c in f.children)
    if (c == _shown && ![next containsObject:c]) [next addObject:c];
  // Dismissed entries that left the feed don't need remembering.
  NSMutableSet* inFeed = [NSMutableSet set];
  for (LiveFolderEntry* e in entries) [inFeed addObject:e.url];
  [f.liveDismissed filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSString* u, NSDictionary*) { return [inFeed containsObject:u]; }]];
  f.children = next;
}
- (void)refreshLiveFolder:(ArcItem*)f done:(void (^)(BOOL ok))done {
  if (!f.liveKind) { if (done) done(NO); return; }
  __weak MainWindowController* weakSelf = self;
  f.liveRefreshedAt = [NSDate date];  // also throttles retries after an error
  void (^finish)(NSArray<LiveFolderEntry*>*, NSString*) = ^(NSArray<LiveFolderEntry*>* entries, NSString* error) {
    MainWindowController* me = weakSelf;
    if (!me) return;
    f.liveError = error;
    if (entries) [me applyLiveEntries:entries toFolder:f];
    if (entries && !f.liveSignInNeeded) f.liveFilled = YES;
    if ([me spaceOwningItem:f] == me->_space) {
      [me->_outline reloadItem:f reloadChildren:YES];
      if (me->_shown) [me selectSidebarRowFor:me->_shown];
    }
    [me scheduleSave];
    if (done) done(entries != nil);
  };
  if ([f.liveKind isEqualToString:@"github-mine"]) {
    [self fetchMyPullRequestsForFolder:f done:^(NSArray<LiveFolderEntry*>* entries, BOOL signedIn, NSString* error) {
      // Empty states: a sign-in entry while the Space isn't signed in to GitHub, else "No open pull requests".
      NSArray<LiveFolderEntry*>* shown = entries;
      if (entries && (!signedIn || !entries.count)) {
        LiveFolderEntry* e = [LiveFolderEntry new];
        e.url = signedIn ? kLiveFolderGitHubNoneURL : kLiveFolderGitHubSignInURL;
        e.title = signedIn ? @"No open pull requests" : @"Sign in to GitHub to see your pull requests";
        shown = @[ e ];
      }
      f.liveSignInNeeded = entries && !signedIn;
      if (!entries && [error isEqualToString:kSpaceStartingError]) f.liveRefreshedAt = nil;  // retry on the next tick
      finish(shown, error ?: (f.liveSignInNeeded ? @"Not signed in to GitHub" : nil));
    }];
    return;
  }
  LiveFolderFetch(f.liveKind, f.liveSource, kLiveFolderMaxItems, finish);
}
// Reads a page with a Space's own cookies (its sign-ins), like a tab in that Space would. Main queue callback.
- (void)fetchPage:(NSString*)url withCookiesOfSpace:(ArcSpace*)space
             done:(void (^)(NSString* html, NSString* error))done {
  if (LiveFolderTestPagesActive() || self.selfTestProfiles) {  // self-tests: local files only, never the network
    NSData* data = LiveFolderTestPage(url);
    NSString* html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    dispatch_async(dispatch_get_main_queue(), ^{ done(html, html ? nil : @"No network in self-tests"); });
    return;
  }
  CefRefPtr<CefRequestContext> ctx = space ? [self contextForSpace:space] : nullptr;
  if (!ctx || ![self contextIsReady:space.profileDirectory]) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(nil, kSpaceStartingError); });
    return;
  }
  class PageFetch : public CefURLRequestClient {
   public:
    explicit PageFetch(void (^b)(NSString*, NSString*)) : b_([b copy]), data_([NSMutableData data]) {}
    void OnRequestComplete(CefRefPtr<CefURLRequest> request) override {
      CefRefPtr<CefResponse> resp = request->GetResponse();
      int status = resp ? resp->GetStatus() : 0;
      BOOL ok = request->GetRequestStatus() == UR_SUCCESS && status > 0 && status < 400;
      NSString* html = ok ? [[NSString alloc] initWithData:data_ encoding:NSUTF8StringEncoding] : nil;
      NSString* err = ok ? nil
                         : (status >= 400 ? [NSString stringWithFormat:@"GitHub answered %d", status]
                                          : @"Couldn't reach GitHub");
      void (^b)(NSString*, NSString*) = b_;
      dispatch_async(dispatch_get_main_queue(), ^{ b(html, err); });
    }
    void OnUploadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
    void OnDownloadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
    void OnDownloadData(CefRefPtr<CefURLRequest>, const void* data, size_t len) override {
      if (data_.length < 16 * 1024 * 1024) [data_ appendBytes:data length:len];
    }
    bool GetAuthCredentials(bool, const CefString&, int, const CefString&, const CefString&,
                            CefRefPtr<CefAuthCallback>) override { return false; }
   private:
    void (^b_)(NSString*, NSString*);
    NSMutableData* data_;
    IMPLEMENT_REFCOUNTING(PageFetch);
  };
  CefRefPtr<CefRequest> req = CefRequest::Create();
  req->SetURL(url.UTF8String);
  req->SetMethod("GET");
  req->SetFlags(UR_FLAG_ALLOW_STORED_CREDENTIALS | UR_FLAG_SKIP_CACHE);
  req->SetFirstPartyForCookies(url.UTF8String);  // a top-level visit, so the site's own (SameSite) cookies go along
  CefRequest::HeaderMap headers;
  headers.insert(std::make_pair("Accept", "text/html,application/xhtml+xml"));
  req->SetHeaderMap(headers);
  CefURLRequest::Create(req, new PageFetch(done), ctx);
}
// "github-mine": GitHub's search pages for your open pull requests, then the ones waiting for your review.
- (void)fetchMyPullRequestsForFolder:(ArcItem*)f
                                done:(void (^)(NSArray<LiveFolderEntry*>* entries, BOOL signedIn, NSString* error))done {
  ArcSpace* space = [self spaceOwningItem:f] ?: _space;
  NSArray<NSString*>* urls = LiveFolderGitHubMineURLs();
  __weak MainWindowController* weakSelf = self;
  [self fetchPage:urls[0] withCookiesOfSpace:space done:^(NSString* html, NSString* error) {
    BOOL signedIn = NO;
    NSArray<LiveFolderEntry*>* mine = LiveFolderParseGitHubHTML(html, kLiveFolderMaxItems, NO, &signedIn);
    if (!mine) { done(nil, NO, error ?: @"Couldn't read GitHub's page"); return; }
    if (!signedIn || !weakSelf) { done(@[], signedIn, nil); return; }
    [weakSelf fetchPage:urls[1] withCookiesOfSpace:space done:^(NSString* html2, NSString* error2) {
      BOOL signedIn2 = NO;
      NSArray<LiveFolderEntry*>* review = LiveFolderParseGitHubHTML(html2, kLiveFolderMaxItems, YES, &signedIn2) ?: @[];
      NSMutableArray<LiveFolderEntry*>* all = [mine mutableCopy];
      NSMutableSet* seen = [NSMutableSet set];
      for (LiveFolderEntry* e in mine) [seen addObject:e.url];
      for (LiveFolderEntry* e in review)
        if (![seen containsObject:e.url] && all.count < kLiveFolderMaxItems) { [seen addObject:e.url]; [all addObject:e]; }
      done(all, YES, nil);
    }];
  }];
}
// Tests: "dot" on an unread Live Folder tab, the unread count on a Live Folder's row, else "".
- (NSString*)liveBadgeForItem:(ArcItem*)item {
  NSInteger row = [_outline rowForItem:item];
  NSTableCellView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  NSImageView* dot = [cell viewWithTag:79];
  NSTextField* count = [cell viewWithTag:80];
  if (dot && !dot.hidden) return @"dot";
  if (count && !count.hidden) return count.stringValue;
  return @"";
}
- (NSUInteger)liveUnreadCountOf:(ArcItem*)folder {
  NSUInteger n = 0;
  for (ArcItem* c in folder.children) n += c.liveUnread ? 1 : 0;
  return n;
}
// Tests: write a cookie into the current Space's profile and flush it to disk; read cookie names for a URL.
- (void)setTestCookie:(NSString*)name value:(NSString*)value url:(NSString*)url session:(BOOL)session done:(void (^)(BOOL))done {
  CefRefPtr<CefRequestContext> ctx = [self contextForSpace:_space];
  auto mgr = ctx ? ctx->GetCookieManager(nullptr) : nullptr;
  if (!mgr) { if (done) done(NO); return; }
  CefCookie c;
  CefString(&c.name) = name.UTF8String;
  CefString(&c.value) = value.UTF8String;
  CefString(&c.path) = "/";
  c.secure = true;
  c.has_expires = !session;
  if (!session) {
    CefTime t;
    t.SetDoubleT([NSDate dateWithTimeIntervalSinceNow:86400 * 30].timeIntervalSince1970);
    cef_time_to_basetime(&t, &c.expires);
  }
  void (^cb)(BOOL) = [done copy];
  class SetCB : public CefSetCookieCallback {
   public:
    explicit SetCB(CefRefPtr<CefCookieManager> m, void (^b)(BOOL)) : m_(m), b_(b) {}
    void OnComplete(bool ok) override {
      m_->FlushStore(nullptr);
      void (^b)(BOOL) = b_;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (b) b(ok); });
    }
   private:
    CefRefPtr<CefCookieManager> m_;
    void (^b_)(BOOL);
    IMPLEMENT_REFCOUNTING(SetCB);
  };
  if (!mgr->SetCookie(url.UTF8String, c, new SetCB(mgr, cb)) && cb) cb(NO);
}
// Tests: every cookie (HttpOnly included) the current Space would send to `url`, with its fields.
- (void)testCookieDetailsForURL:(NSString*)url done:(void (^)(NSArray<NSDictionary*>*))done {
  CefRefPtr<CefRequestContext> ctx = [self contextForSpace:_space];
  auto mgr = ctx ? ctx->GetCookieManager(nullptr) : nullptr;
  if (!mgr) { done(@[]); return; }
  class DetailVisitor : public CefCookieVisitor {
   public:
    explicit DetailVisitor(void (^b)(NSArray*)) : b_(b), out_([NSMutableArray array]) {}
    ~DetailVisitor() override {
      NSArray* n = [out_ copy];
      void (^b)(NSArray*) = b_;
      dispatch_async(dispatch_get_main_queue(), ^{ b(n); });
    }
    bool Visit(const CefCookie& c, int, int, bool&) override {
      auto str = [](const cef_string_t& v) { return [NSString stringWithUTF8String:CefString(&v).ToString().c_str()]; };
      [out_ addObject:@{@"name" : str(c.name), @"value" : str(c.value), @"domain" : str(c.domain), @"path" : str(c.path),
                        @"secure" : @(c.secure != 0), @"httponly" : @(c.httponly != 0), @"samesite" : @((int)c.same_site),
                        @"hasExpires" : @(c.has_expires != 0), @"expires" : @(c.expires.val)}];
      return true;
    }
   private:
    void (^b_)(NSArray*);
    NSMutableArray* out_;
    IMPLEMENT_REFCOUNTING(DetailVisitor);
  };
  if (!mgr->VisitUrlCookies(url.UTF8String, true, new DetailVisitor([done copy]))) done(@[]);
}

// Tests: removes every cookie the current Space holds for `url`, then calls back.
- (void)testDeleteCookiesForURL:(NSString*)url done:(void (^)(void))done {
  CefRefPtr<CefRequestContext> ctx = [self contextForSpace:_space];
  auto mgr = ctx ? ctx->GetCookieManager(nullptr) : nullptr;
  if (!mgr) { done(); return; }
  class Deleted : public CefDeleteCookiesCallback {
   public:
    explicit Deleted(void (^b)(void)) : b_(b) {}
    void OnComplete(int) override {
      void (^b)(void) = b_;
      dispatch_async(dispatch_get_main_queue(), ^{ b(); });
    }
   private:
    void (^b_)(void);
    IMPLEMENT_REFCOUNTING(Deleted);
  };
  if (!mgr->DeleteCookies(url.UTF8String, "", new Deleted([done copy]))) done();
}

- (void)testCookieNamesForURL:(NSString*)url done:(void (^)(NSArray<NSString*>*))done {
  CefRefPtr<CefRequestContext> ctx = [self contextForSpace:_space];
  auto mgr = ctx ? ctx->GetCookieManager(nullptr) : nullptr;
  if (!mgr) { done(@[]); return; }
  class NameVisitor : public CefCookieVisitor {
   public:
    explicit NameVisitor(void (^b)(NSArray*)) : b_(b), names_([NSMutableArray array]) {}
    ~NameVisitor() override {
      NSArray* n = [names_ copy];
      void (^b)(NSArray*) = b_;
      dispatch_async(dispatch_get_main_queue(), ^{ b(n); });
    }
    bool Visit(const CefCookie& c, int, int, bool&) override {
      [names_ addObject:[NSString stringWithUTF8String:CefString(&c.name).ToString().c_str()]];
      return true;
    }
   private:
    void (^b_)(NSArray*);
    NSMutableArray* names_;
    IMPLEMENT_REFCOUNTING(NameVisitor);
  };
  if (!mgr->VisitUrlCookies(url.UTF8String, false, new NameVisitor([done copy]))) done(@[]);
}

// Renders the sidebar (theme backdrop included) to a PNG, for comparing with Arc screenshots.
- (BOOL)writeSidebarSnapshot:(NSString*)path {
  NSView* root = self.window.contentView;
  NSRect r = NSMakeRect(0, 0, kSidebarWidth, root.bounds.size.height);
  NSBitmapImageRep* rep = [root bitmapImageRepForCachingDisplayInRect:r];
  [root cacheDisplayInRect:r toBitmapImageRep:rep];
  NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  return [png writeToFile:path atomically:YES];
}

// Removes an item (and its tabs) from the current Space without archiving (tests and Live Folder cleanup).
- (void)deleteSidebarItem:(ArcItem*)item {
  if (!item || item.isSection) return;
  for (ArcItem* t in [self tabsIn:@[ item ]]) {
    if (t == _shown) _shown = nil;
    [self unloadItem:t];
  }
  for (ArcItem* section in [self sectionsOfSpace:_space])
    if (RemoveItem(section, item)) break;
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  [self scheduleSave];
}
// Closing a Live Folder tab removes it and keeps it from coming back on the next refresh.
- (BOOL)dismissLiveFolderTab:(ArcItem*)item {
  ArcItem* parent = [self parentOfItem:item];
  if (!parent.liveKind) return NO;
  NSString* key = item.pinnedURL ?: item.url;
  if (key && ![parent.liveDismissed containsObject:key]) [parent.liveDismissed addObject:key];
  [self unloadItem:item];
  [parent.children removeObject:item];
  if (item == _shown) _shown = nil;
  [_outline reloadItem:parent reloadChildren:YES];
  [self scheduleSave];
  return YES;
}

- (ArcItem*)createFolderNamed:(NSString*)name {
  if (!_space) return nil;
  ArcItem* folder = [ArcItem new];
  folder.itemID = NSUUID.UUID.UUIDString;
  folder.title = name.length ? name : @"New Folder";
  folder.isFolder = YES;
  folder.children = [NSMutableArray array];
  [_space.pinned.children insertObject:folder atIndex:0];
  [_outline reloadItem:_space.pinned reloadChildren:YES];
  [_outline expandItem:folder];
  [self scheduleSave];
  return folder;
}

- (IBAction)newFolder:(id)sender {
  ArcItem* folder = [self createFolderNamed:@"New Folder"];
  NSInteger row = [_outline rowForItem:folder];
  if (row >= 0) [_outline editColumn:0 row:row withEvent:nil select:YES];
}

// Arc's Cmd+D: Today tab -> bottom of Pinned; pinned tab (or one in a pinned folder) -> top of Today.
- (IBAction)togglePin:(id)sender {
  ArcItem* item = _splitGroup ?: _shown;  // pinning a split pins the whole split
  if (!item) return;
  ArcItem* section = [self sectionContaining:item];
  if (section == _space.unpinned) {
    [self moveItem:item toParent:_space.pinned index:_space.pinned.children.count];
    [self markPinnedURLs:item];  // also tidies the title (#18; with Max's on-device model when it's on, #58)
  } else if (section == _space.pinned) {
    [self moveItem:item toParent:_space.unpinned index:0];
    [self clearPinnedURLs:item];
  }
}

// Arc's "Move to Top Apps" / "Remove from Top Apps" (#13), named Favorites in NotArc as in Arc's newer builds. A tab
// moved into Favorites keeps its address as the Favorite's home (like pinning); taking it out puts it at the top of
// Today. Folders and splits can't be Favorites (the grid holds single tabs), the same rule as dragging onto the grid.
- (BOOL)moveItemToFavorites:(ArcItem*)item {
  if (!item || !_space.favorites || !item.url.length || item.isFolder || item.isSplit) return NO;
  if ([self sectionContaining:item] == _space.favorites) return NO;
  if ([self parentOfItem:item].isSplit) [self detachFromSplit:item keep:YES];
  if (![self moveItem:item toParent:_space.favorites index:(NSInteger)_space.favorites.children.count]) return NO;
  [self markPinnedURLs:item];
  [self updateFavoritesGrid];
  return YES;
}
- (BOOL)removeItemFromFavorites:(ArcItem*)item pinned:(BOOL)pinned {
  if (!item || [self sectionContaining:item] != _space.favorites) return NO;
  ArcItem* target = pinned ? _space.pinned : _space.unpinned;
  if (![self moveItem:item toParent:target index:pinned ? (NSInteger)target.children.count : 0]) return NO;
  if (!pinned) [self clearPinnedURLs:item];
  [self updateFavoritesGrid];
  return YES;
}
- (IBAction)toggleFavorite:(id)sender {
  ArcItem* item = _shown;
  if ([self sectionContaining:item] == _space.favorites) [self removeItemFromFavorites:item pinned:NO];
  else [self moveItemToFavorites:item];
}
- (void)menuMoveToFavorites:(NSMenuItem*)sender { [self moveItemToFavorites:sender.representedObject]; }
- (void)menuRemoveFromFavorites:(NSMenuItem*)sender { [self removeItemFromFavorites:sender.representedObject pinned:NO]; }
- (void)menuFavoriteToPinned:(NSMenuItem*)sender { [self removeItemFromFavorites:sender.representedObject pinned:YES]; }

- (void)markPinnedURLs:(ArcItem*)item {
  if (item.url.length) item.pinnedURL = [self itemCurrentURL:item];
  if (item.url.length && !item.renamed && SettingBool(kSettingTidyTitles)) [self tidyTitleOfItem:item announce:YES];
  for (ArcItem* c in item.children) [self markPinnedURLs:c];
}

// Tidy tab titles (#18): pinning renames a tab to the short name TidyTabTitle finds; the toast and the tab menu's
// "Use Page Title" undo it. With Max's on-device model on (#58) the model names the tab instead (a moment later) and
// TidyTabTitle is the fallback when it gives nothing usable. Returns YES if the name changed (or the model was asked).
- (BOOL)tidyTitleOfItem:(ArcItem*)item announce:(BOOL)announce {
  if (MaxTidyTitlesUseModel()) {
    [self tidyTitleOfItem:item announce:announce done:nil];
    return YES;
  }
  return [self applyTidyTitle:[self ruleTidyTitleOfItem:item] toItem:item announce:announce];
}
- (NSString*)ruleTidyTitleOfItem:(ArcItem*)item {
  return TidyTabTitle(item.displayTitle, [NSURL URLWithString:[self itemCurrentURL:item] ?: item.url ?: @""].host);
}
- (BOOL)applyTidyTitle:(NSString*)tidy toItem:(ArcItem*)item announce:(BOOL)announce {
  NSString* current = item.displayTitle;
  if (!item || !tidy.length || [tidy isEqualToString:current]) return NO;
  NSString* oldTitle = item.title;
  BOOL oldRenamed = item.renamed;
  item.title = tidy;
  item.renamed = YES;
  [_outline reloadItem:item];
  [self scheduleSave];
  _lastTidied = item;
  __weak MainWindowController* weakSelf = self;
  [[self sidebarUndoManager] registerUndoWithTarget:self handler:^(id target) {
    item.title = oldTitle;
    item.renamed = oldRenamed;
    [weakSelf reloadSidebar];
    [weakSelf scheduleSave];
  }];
  [[self sidebarUndoManager] setActionName:@"Tidy Tab Title"];
  if (announce && !self.selfTestProfiles)
    [self showToast:[NSString stringWithFormat:@"Renamed to \u201C%@\u201D", tidy] action:@"Undo" selector:@selector(undoLastTidy:)];
  return YES;
}
- (void)undoLastTidy:(id)sender { [self usePageTitleOfItem:_lastTidied]; }
- (void)usePageTitleOfItem:(ArcItem*)item {
  if (!item.renamed) return;
  item.renamed = NO;
  item.title = nil;
  [_outline reloadItem:item];
  [self scheduleSave];
}
- (void)menuTidyTitle:(NSMenuItem*)sender { [self tidyTitleOfItem:sender.representedObject announce:NO]; }
- (void)menuUsePageTitle:(NSMenuItem*)sender { [self usePageTitleOfItem:sender.representedObject]; }
- (void)clearPinnedURLs:(ArcItem*)item {
  item.pinnedURL = nil;
  for (ArcItem* c in item.children) [self clearPinnedURLs:c];
}

- (BOOL)isPinnedItem:(ArcItem*)item {
  ArcItem* section = [self sectionContaining:item];
  return section && section != _space.unpinned;
}

- (void)resetPinnedItem:(ArcItem*)item {
  if (!item.pinnedURL.length) return;
  item.url = item.pinnedURL;
  item.liveTitle = nil;
  auto it = _browsers.find(item.browserId);
  if (it != _browsers.end()) it->second->GetMainFrame()->LoadURL(item.pinnedURL.UTF8String);
  [_outline reloadItem:item];
  [self scheduleSave];
}

- (void)replacePinnedURLWithCurrent:(ArcItem*)item {
  if (![self isPinnedItem:item] || !item.url.length) return;
  item.pinnedURL = [self itemCurrentURL:item];
  [self scheduleSave];
}

- (NSUInteger)resetPinnedTabsInSpace {
  NSUInteger n = 0;
  for (ArcItem* t in _space.allTabs) {
    if (![self isPinnedItem:t] || !t.pinnedURL.length) continue;
    if ([[self itemCurrentURL:t] isEqualToString:t.pinnedURL] && [t.url isEqualToString:t.pinnedURL]) continue;
    if (t == _shown) {
      [self resetPinnedItem:t];
    } else {
      [self unloadItem:t];
      t.url = t.pinnedURL;
      t.liveTitle = nil;
    }
    ++n;
  }
  [_outline reloadData];
  for (ArcItem* section in [self sectionsOfSpace:_space]) [_outline expandItem:section];
  if (_shown) [self selectSidebarRowFor:_shown];
  [self scheduleSave];
  return n;
}

- (IBAction)resetPinnedTab:(id)sender { if (_shown) [self resetPinnedItem:_shown]; }
- (IBAction)replacePinnedURL:(id)sender { if (_shown) [self replacePinnedURLWithCurrent:_shown]; }
- (IBAction)resetAllPinnedTabs:(id)sender { [self resetPinnedTabsInSpace]; }

- (BOOL)validateMenuItem:(NSMenuItem*)mi {
  BOOL maxHandled = NO;
  BOOL maxOK = [self maxValidateMenuItem:mi handled:&maxHandled];  // Arc Max items (#58, #59)
  if (maxHandled) return maxOK;
  // chrome:// and chrome-extension:// pages only open in Chrome-style pages.
  if (mi.action == @selector(manageExtensions:) || mi.action == @selector(openExtensionPopup:) ||
      mi.action == @selector(openExtensionOptions:) || mi.action == @selector(manageChromeExtension:))
    return ChromePagesEnabled();
  if (mi.action == @selector(translatePage:)) {
    NSString* url = [self currentURL];
    BOOL translated = url && OriginalURLForTranslated(url);
    mi.title = translated ? @"Show Original" : @"Translate Page";
    return translated || (url && TranslateURLFor(url, @"en"));
  }
  if (mi.action == @selector(toggleDeveloperMode:)) {
    NSString* url = [self currentURL];
    mi.title = DeveloperModeOnForURL(url) ? @"Turn Off Developer Mode for This Site" : @"Turn On Developer Mode for This Site";
    NSURL* u = url.length ? [NSURL URLWithString:url] : nil;
    return u.host.length && ([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"]);
  }
  if (mi.action == @selector(toggleToolbar:)) mi.title = SettingBool(kSettingShowToolbar) ? @"Hide Toolbar" : @"Show Toolbar";
  if (mi.action == @selector(toggleSpaceHeader:))
    mi.title = SettingBool(kSettingShowSpaceHeader) ? @"Hide Space Header" : @"Show Space Header";
  if (mi.action == @selector(resetPinnedTab:) || mi.action == @selector(replacePinnedURL:))
    return _shown && [self isPinnedItem:_shown] && _shown.pinnedURL.length;
  if (mi.action == @selector(exportNoteAsMarkdown:) || mi.action == @selector(copyNoteAsMarkdown:))
    return [self noteForExport] != nil;
  if (mi.action == @selector(newNoteInSplitView:)) return _space != nil && _splitItems.count < 4;
  if (mi.action == @selector(fillPassword:)) return _shown.browserId != 0 && [_shown.url hasPrefix:@"http"];
  if (mi.action == @selector(captureAreaToEasel:) || mi.action == @selector(captureFullPageToEasel:) ||
      mi.action == @selector(liveClipToEasel:))
    return [self canCaptureShownPage];
  if (mi.action == @selector(refreshLiveClipsFromMenu:)) return _easelItem && _easelView.liveClips.count > 0;
  return YES;
}

- (ArcItem*)tabWithURLPrefix:(NSString*)prefix {
  for (ArcItem* t in _space.allTabs)
    if ([t.url hasPrefix:prefix]) return t;
  return nil;
}

// Folder renames from the sidebar (double-click / New Folder).
- (void)controlTextDidChange:(NSNotification*)note {
  if (note.object == _findField) [self findText:_findField.stringValue forward:YES];
  if (note.object == _commandField) [self refreshSuggestions];
}

- (void)controlTextDidEndEditing:(NSNotification*)note {
  NSTextField* field = note.object;
  if (field == _commandField || field == _findField) return;
  NSInteger row = [_outline rowForView:field];
  ArcItem* item = row >= 0 ? [_outline itemAtRow:row] : nil;
  if (!item || item.isSection || !field.stringValue.length) return;
  item.title = field.stringValue;
  [self scheduleSave];
}

#pragma mark Drag and drop

- (id<NSPasteboardWriting>)outlineView:(NSOutlineView*)ov pasteboardWriterForItem:(id)item {
  ArcItem* a = item;
  if (a.isSection || !a.itemID) return nil;
  NSPasteboardItem* pb = [NSPasteboardItem new];
  [pb setString:a.itemID forType:kSidebarItemPasteboardType];
  return pb;
}

- (ArcItem*)itemWithID:(NSString*)itemID under:(ArcItem*)root {
  if ([root.itemID isEqualToString:itemID]) return root;
  for (ArcItem* child in root.children) {
    ArcItem* found = [self itemWithID:itemID under:child];
    if (found) return found;
  }
  return nil;
}

- (ArcItem*)draggedItem:(id<NSDraggingInfo>)info {
  NSString* itemID = [info.draggingPasteboard stringForType:kSidebarItemPasteboardType];
  if (!itemID) return nil;
  for (ArcItem* section in [self sectionsOfSpace:_space]) {
    ArcItem* found = [self itemWithID:itemID under:section];
    if (found) return found;
  }
  return nil;
}

- (NSDragOperation)outlineView:(NSOutlineView*)ov
                  validateDrop:(id<NSDraggingInfo>)info
                  proposedItem:(id)item
            proposedChildIndex:(NSInteger)index {
  ArcItem* dragged = [self draggedItem:info];
  ArcItem* target = item;
  if (!dragged || !target) return NSDragOperationNone;
  if (!(target.isSection || target.isFolder)) {
    // Dropped onto a tab: insert just after it in its parent.
    ArcItem* parent = [self parentOfItem:target];
    if (!parent) return NSDragOperationNone;
    [ov setDropItem:parent dropChildIndex:[parent.children indexOfObject:target] + 1];
    target = parent;
  }
  if (Contains(dragged, target)) return NSDragOperationNone;
  return NSDragOperationMove;
}

- (BOOL)outlineView:(NSOutlineView*)ov acceptDrop:(id<NSDraggingInfo>)info item:(id)item childIndex:(NSInteger)index {
  ArcItem* dragged = [self draggedItem:info];
  ArcItem* target = item;
  if (!dragged || !target) return NO;
  if (index == NSOutlineViewDropOnItemIndex) index = target.children.count;
  BOOL moved = [self moveItem:dragged toParent:target index:index];
  if (moved) ReorderHaptic();  // Arc: haptic feedback when reordering tabs
  return moved;
}

#pragma mark Auto-archive

// Today tabs inactive longer than the threshold are archived (12 hours by default, the same
// default Arc users are used to).
// Pinned tabs, Favorites and the tab on screen are never auto-archived.
- (NSUInteger)runAutoArchiveWithThreshold:(NSTimeInterval)threshold now:(NSDate*)now {
  if (threshold <= 0) return 0;
  NSUInteger archived = 0;
  for (ArcSpace* space in _spaces) {
    for (ArcItem* item in [space.unpinned.children copy]) {
      if (item == _shown || [_splitItems containsObject:item] || item.isFolder || !item.url.length) continue;
      if ([self itemKeptFromAutoArchive:item]) continue;
      if (!item.lastActiveAt) item.lastActiveAt = now;  // unknown age: start the clock now
      if ([now timeIntervalSinceDate:item.lastActiveAt] < threshold) continue;
      [self archiveItem:item space:space reason:@"auto"];
      [self unloadItem:item];
      [space.unpinned.children removeObject:item];
      ++archived;
    }
  }
  if (archived) {
    [_outline reloadData];
    [self reloadSidebar];
    [self scheduleSave];
  }
  return archived;
}

// Developer Mode sites (#68) stay put, like Pinned tabs.
- (BOOL)itemKeptFromAutoArchive:(ArcItem*)item { return DeveloperModeOnForURL([self itemCurrentURL:item]); }

- (void)startAutoArchiveTimer {
  __weak MainWindowController* weakSelf = self;
  _archiveTimer = [NSTimer scheduledTimerWithTimeInterval:60 repeats:YES block:^(NSTimer* t) {
    [weakSelf runAutoArchiveWithThreshold:AutoArchiveThreshold() now:[NSDate date]];
    [weakSelf archiveIdleLittleWindowsAt:[NSDate date]];
    [weakSelf refreshStaleLiveFolders];
  }];
}

- (IBAction)reopenLastArchived:(id)sender {
  ArchivedTab* last = [self archive].lastObject;
  if (last) [self reopenArchivedTab:last];
}

// Reopening removes the entry from the archive and restores the tab at the top of its Space's Today.
- (void)reopenArchivedTab:(ArchivedTab*)tab {
  if (![[self archive] containsObject:tab]) return;
  [_archive removeObject:tab];
  if (self.archivePath) ArchiveStoreSave(_archive, self.archivePath);
  for (ArcSpace* s in _spaces)
    if ([s.spaceID isEqualToString:tab.spaceID] && s != _space) {
      _space = s;
      _splitItems = nil;
      [_spacePicker selectItemAtIndex:[_spaces indexOfObject:s]];
      [self reloadSidebar];
      [self applyTheme];
    }
  [self openInNewTab:tab.url];
  [_library reload];
}

// Arc: the Library button opens Archive inside the sidebar, in place of the Space's tabs; again closes it.
- (IBAction)showArchive:(id)sender {
  if (_libraryShown && sender == _libraryButton) {
    [self hideLibrary];
    return;
  }
  [self libraryPanel];
  [_library setQuery:@""];
  _libraryShown = YES;
  [self layoutSidebar];
  [self applyLibraryColors];
  _responderBeforeLibrary = self.window.firstResponder;
  [_library focusSearch];
}
- (LibraryPanelView*)libraryPanel {
  if (_library) return _library;
  __weak MainWindowController* weakSelf = self;
  _library = [[LibraryPanelView alloc] initWithFrame:NSMakeRect(8, 42, kSidebarWidth - 17, 300)];
  _library.archiveProvider = ^NSArray<ArchivedTab*>* { return [weakSelf archivedTabs]; };
  _library.reopen = ^(ArchivedTab* tab) {
    [weakSelf reopenArchivedTab:tab];
    [weakSelf hideLibrary];
  };
  _library.back = ^{ [weakSelf hideLibrary]; };
  _library.iconForURL = ^NSImage*(NSString* url) {
    MainWindowController* s = weakSelf;
    if (!s) return nil;
    ArcItem* probe = [ArcItem new];
    probe.url = url;
    return [s iconImageForItem:probe];
  };
  _library.hidden = YES;
  [_sidebar addSubview:_library];
  return _library;
}
- (void)applyLibraryColors {
  BOOL dark = IsDark(_sidebar);
  _library.textColor = [self usingDefaultTheme] && dark ? ArcDefaultTabText() : NSColor.labelColor;
  _libraryButton.contentTintColor = _libraryShown ? (_library.textColor ?: NSColor.labelColor) : SidebarIconColor();
}
- (void)hideLibrary {
  if (!_libraryShown) return;
  _libraryShown = NO;
  NSResponder* r = self.window.firstResponder;
  if ([r isKindOfClass:NSView.class] && [(NSView*)r isDescendantOf:_library])
    [self.window makeFirstResponder:_responderBeforeLibrary];
  else if ([r isKindOfClass:NSTextView.class] && [(NSTextView*)r delegate] && [[(NSTextView*)r delegate] isKindOfClass:NSView.class] &&
           [(NSView*)[(NSTextView*)r delegate] isDescendantOf:_library])
    [self.window makeFirstResponder:_responderBeforeLibrary];
  _responderBeforeLibrary = nil;
  [self layoutSidebar];
  [self updateFavoritesGrid];
  [self applyLibraryColors];
}
- (BOOL)libraryShown { return _libraryShown; }  // tests
- (BOOL)libraryInSidebar {  // tests: shown inside the sidebar, and no Archive window was made
  return _libraryShown && [_library isDescendantOf:_sidebar] && !_library.hidden && NSHeight(_library.frame) > 100 &&
         _sidebarScroll.hidden && _archiveWindow == nil;
}
- (NSString*)libraryStyle { return [[self libraryPanel] styleDescription]; }  // tests
- (NSArray<NSString*>*)libraryGroupTitles { return [[self libraryPanel] groupTitles]; }  // tests

- (HistoryStore*)historyStore {
  if (!_history && self.historyPath) _history = [[HistoryStore alloc] initWithPath:self.historyPath];
  return _history;
}

- (NSArray<ArchivedTab*>*)historyVisits { return [self historyStore].visits ?: @[]; }

- (IBAction)showHistory:(id)sender {
  if (!_historyWindow) {
    __weak MainWindowController* weakSelf = self;
    _historyWindow = [[ArchiveWindowController alloc]
        initWithProvider:^NSArray<ArchivedTab*>* { return [weakSelf historyVisits]; }
                  reopen:^(ArchivedTab* visit) { [weakSelf openInNewTab:visit.url]; }];
    _historyWindow.baseTitle = @"History";
    [_historyWindow setPlaceholder:@"Search history" dateHeader:@"Visited" reasonHeader:@"Space"];
  }
  [_historyWindow reload];
  [_historyWindow showWindow:nil];
}

- (std::vector<CefRefPtr<CefRequestContext>>)allContexts {
  if (gMainWindow && gMainWindow != self) return [gMainWindow allContexts];
  std::vector<CefRefPtr<CefRequestContext>> out;
  for (auto& kv : _contexts) out.push_back(kv.second);
  if (auto g = CefRequestContext::GetGlobalContext()) out.push_back(g);
  return out;
}

- (void)clearBrowsingDataSince:(NSDate*)since history:(BOOL)history cookies:(BOOL)cookies cache:(BOOL)cache
                          done:(void (^)(NSUInteger, NSUInteger))done {
  NSUInteger historyRemoved = 0;
  if (history) {
    historyRemoved = since ? [[self historyStore] clearSince:since] : [self historyStore].visits.count;
    if (!since) [[self historyStore] clear];
    [_historyWindow reload];
  }
  auto contexts = [self allContexts];
  dispatch_group_t group = dispatch_group_create();
  __block NSUInteger cookiesRemoved = 0;
  double sinceUnix = since ? since.timeIntervalSince1970 : 0;
  for (auto& ctx : contexts) {
    if (cookies) {
      if (auto mgr = ctx->GetCookieManager(nullptr)) {
        dispatch_group_enter(group);
        BOOL started = mgr->VisitAllCookies(new MatchCookieVisitor(mgr,
            [sinceUnix](const CefCookie& c) { return sinceUnix == 0 || CookieCreatedUnix(c) >= sinceUnix - 1; }, true,
            ^(NSUInteger n) {
              cookiesRemoved += n;
              dispatch_group_leave(group);
            }));
        if (!started) dispatch_group_leave(group);
      }
    }
    if (cache) {
      dispatch_group_enter(group);
      ctx->ClearHttpCache(new BlockCompletion(^{ dispatch_group_leave(group); }));
    }
  }
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    if (done) done(historyRemoved, cookiesRemoved);
  });
}

- (IBAction)clearBrowsingData:(id)sender {
  NSAlert* a = [NSAlert new];
  a.messageText = @"Clear Browsing Data";
  a.informativeText = @"Applies to every Space. Your tabs, Spaces and Archive are not affected.";
  NSView* box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, 110)];
  NSPopUpButton* range = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 82, 220, 26) pullsDown:NO];
  NSArray* titles = @[ @"Last hour", @"Last 24 hours", @"Last 7 days", @"Last 4 weeks", @"All time" ];
  NSArray* secs = @[ @3600, @86400, @604800, @2419200, @0 ];
  [range addItemsWithTitles:titles];
  for (NSUInteger i = 0; i < titles.count; ++i) [range itemAtIndex:i].tag = [secs[i] integerValue];
  [range selectItemAtIndex:4];
  NSButton* hist = [NSButton checkboxWithTitle:@"Browsing history" target:nil action:nil];
  NSButton* cook = [NSButton checkboxWithTitle:@"Cookies (signs you out of sites)" target:nil action:nil];
  NSButton* cach = [NSButton checkboxWithTitle:@"Cached images and files (all time)" target:nil action:nil];
  hist.frame = NSMakeRect(0, 56, 300, 20);
  cook.frame = NSMakeRect(0, 30, 300, 20);
  cach.frame = NSMakeRect(0, 4, 300, 20);
  hist.state = NSControlStateValueOn;
  cach.state = NSControlStateValueOn;
  for (NSView* v in @[ range, hist, cook, cach ]) [box addSubview:v];
  a.accessoryView = box;
  [a addButtonWithTitle:@"Clear Data"];
  [a addButtonWithTitle:@"Cancel"];
  if ([a runModal] != NSAlertFirstButtonReturn) return;
  NSInteger s = range.selectedItem.tag;
  [self clearBrowsingDataSince:s ? [NSDate dateWithTimeIntervalSinceNow:-s] : nil
                       history:hist.state == NSControlStateValueOn
                       cookies:cook.state == NSControlStateValueOn
                         cache:cach.state == NSControlStateValueOn
                          done:nil];
}

- (void)clearCookiesAndRefreshWithDone:(void (^)(NSUInteger))done {
  CefRefPtr<CefBrowser> b = [self currentBrowser];
  if (!b) {
    if (done) done(0);
    return;
  }
  std::string url = b->GetMainFrame()->GetURL().ToString();
  std::string host = HostOf(url);
  if (getenv("NOTARC_COOKIE_DEBUG"))
    fprintf(stderr, "COOKIE-CLEARSITE url=%s shown=%s\n", url.c_str(), _shown.url.UTF8String ?: "-");
  NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
  if (host.empty() || !([u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"https"])) {
    if (done) done(0);
    return;
  }
  // Site storage (localStorage, IndexedDB, service workers, cache storage) for this origin.
  CefRefPtr<CefDictionaryValue> params = CefDictionaryValue::Create();
  NSString* origin = [NSString stringWithFormat:@"%@://%@%@", u.scheme, u.host, u.port ? [NSString stringWithFormat:@":%@", u.port] : @""];
  params->SetString("origin", origin.UTF8String);
  params->SetString("storageTypes", "local_storage,indexeddb,websql,cache_storage,service_workers,file_systems,shader_cache");
  b->GetHost()->ExecuteDevToolsMethod(0, "Storage.clearDataForOrigin", params);
  auto mgr = b->GetHost()->GetRequestContext()->GetCookieManager(nullptr);
  void (^finish)(NSUInteger) = ^(NSUInteger n) {
    b->Reload();
    if (done) done(n);
  };
  if (!mgr || !mgr->VisitAllCookies(new MatchCookieVisitor(mgr,
                  [host](const CefCookie& c) { return CookieBelongsToHost(c, host); }, true, finish)))
    finish(0);
}

- (IBAction)clearCookiesAndRefresh:(id)sender { [self clearCookiesAndRefreshWithDone:nil]; }

- (void)selfTestSetCookie:(NSString*)url name:(NSString*)name done:(void (^)(void))done {
  CefRefPtr<CefBrowser> b = [self currentBrowser];
  auto mgr = b ? b->GetHost()->GetRequestContext()->GetCookieManager(nullptr) : nullptr;
  if (!mgr) return done();
  CefCookie c;
  CefString(&c.name) = name.UTF8String;
  CefString(&c.value) = "1";
  CefString(&c.path) = "/";
  c.secure = [url hasPrefix:@"https"];
  c.has_expires = true;
  c.expires.val = (int64_t)(([NSDate dateWithTimeIntervalSinceNow:3600].timeIntervalSince1970 + 11644473600.0) * 1e6);
  if (!mgr->SetCookie(url.UTF8String, c, new BlockSetCookie(done))) done();
}

- (void)selfTestCountCookiesNamed:(NSString*)name done:(void (^)(NSUInteger))done {
  CefRefPtr<CefBrowser> b = [self currentBrowser];
  auto mgr = b ? b->GetHost()->GetRequestContext()->GetCookieManager(nullptr) : nullptr;
  std::string n = name.UTF8String;
  if (!mgr || !mgr->VisitAllCookies(new MatchCookieVisitor(mgr,
                  [n](const CefCookie& c) { return CefString(&c.name).ToString() == n; }, false, done)))
    done(0);
}

- (IBAction)clearHistory:(id)sender {
  if (sender) {
    NSAlert* a = [NSAlert new];
    a.messageText = @"Clear all browsing history?";
    a.informativeText = @"Your tabs, Spaces and Archive are not affected.";
    [a addButtonWithTitle:@"Clear History"];
    [a addButtonWithTitle:@"Cancel"];
    if ([a runModal] != NSAlertFirstButtonReturn) return;
  }
  [[self historyStore] clear];
  [_historyWindow reload];
}

- (NSUInteger)historyWindowCountForQuery:(NSString*)query {
  [self showHistory:nil];
  [_historyWindow setQuery:query];
  return _historyWindow.visibleCount;
}

- (NSUInteger)archiveWindowCountForQuery:(NSString*)query {  // tests: the Library's Archive list, without showing it
  [[self libraryPanel] setQuery:query];
  return _library.visibleCount;
}

#pragma mark Windows (#39)

+ (NSUInteger)openWindowCount { return MAX(gWindows.count, (NSUInteger)1); }
- (BOOL)isMainWindowController { return !gMainWindow || gMainWindow == self; }

- (instancetype)initSecondaryFrom:(MainWindowController*)main space:(ArcSpace*)space {
  if ((self = [self initWithSpaces:main->_spaces focusedSpaceID:space.spaceID])) {
    _spaces = main->_spaces;  // the same Spaces, not a copy
    _space = space ?: main->_space;
    self.selfTestProfiles = main.selfTestProfiles;
    self.archivePath = main.archivePath;
    self.historyPath = main.historyPath;
    self.linkRoutingPath = main.linkRoutingPath;
    _client = main->_client;
    _history = [main historyStore];
    _archive = [main archive];
    _boosts = [main boostList];
    if (self.selfTestProfiles) {  // hidden runs: never on screen, never clickable
      self.window.alphaValue = 0.01;
      self.window.ignoresMouseEvents = YES;
    }
    NSRect f = main.window.frame;
    [self.window setFrame:NSOffsetRect(f, 28, -28) display:NO];
    [self rebuildSpacePicker];
    [self reloadSidebar];
    [gWindows addObject:self];
    [self showWindow:nil];
    [self installSwipeNavigation];
    __weak MainWindowController* weakSelf = self;
    _mediaTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer*) { [weakSelf pollMediaNow]; }];
  }
  return self;
}

- (MainWindowController*)openNewWindowShowing:(ArcItem*)item {
  MainWindowController* main = gMainWindow ?: self;
  ArcSpace* space = item ? [self spaceOwningItem:item] : _space;  // Arc: a new window inherits the Space
  MainWindowController* w = [[MainWindowController alloc] initSecondaryFrom:main space:space];
  if (item) [w showItem:item];
  return w;
}

- (IBAction)newWindow:(id)sender {
  MainWindowController* w = [self openNewWindowShowing:nil];
  if (!self.selfTestProfiles) [w showCommandBarForNewTab:YES];
}

- (void)menuMoveToNewWindow:(NSMenuItem*)sender {
  ArcItem* item = sender.representedObject;
  if (item.url.length) [self openNewWindowShowing:item];
}

- (void)moveItemToMainWindow:(ArcItem*)item {
  MainWindowController* main = gMainWindow;
  if (!main || main == self || !item.url.length) return;
  ArcSpace* sp = [self spaceOwningItem:item];
  if (sp != main->_space) [main switchToSpace:sp];
  [main showItem:item];
  if (!self.selfTestProfiles) [main.window makeKeyAndOrderFront:nil];
}

- (IBAction)moveShownToMainWindow:(id)sender { [self moveItemToMainWindow:_shown]; }

- (BOOL)moveToMainButtonShown {  // tests
  NSInteger row = [_outline rowForItem:_space.unpinned];
  NSView* cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:YES] : nil;
  NSButton* b = [cell viewWithTag:78];
  return b && !b.hidden;
}

- (void)menuMoveToMainWindow:(NSMenuItem*)sender { [self moveItemToMainWindow:sender.representedObject]; }

// The page itself moves (Arc: reassignWebContent): same browser, nothing reloads.
- (void)claimBrowserOfItem:(ArcItem*)item {
  if (!item.browserId) return;
  MainWindowController* owner = OwnerOf(item.browserId, nil);
  if (!owner || owner == self) return;
  [owner giveBrowserOfItem:item to:self];
}

- (void)giveBrowserOfItem:(ArcItem*)item to:(MainWindowController*)dest {
  auto it = _browsers.find(item.browserId);
  if (it == _browsers.end()) return;
  CefRefPtr<CefBrowser> browser = it->second;
  ChromePageHost* host = _chromePages[@(it->first)];
  _browsers.erase(it);
  if (host) {  // Chrome-style page: its page window follows the placeholder into the other window
    [_chromePages removeObjectForKey:@(browser->GetIdentifier())];
    [dest acceptChromePage:host browser:browser];
  } else {
    [dest acceptBrowser:browser];
  }
  [self lostItem:item];
}

- (void)acceptChromePage:(ChromePageHost*)host browser:(CefRefPtr<CefBrowser>)browser {
  NSView* ph = host.placeholder;
  [_content addSubview:ph];  // viewDidMoveToWindow re-attaches the page window to this window
  ph.frame = _content.bounds;
  ph.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  if (!_chromePages) _chromePages = [NSMutableDictionary dictionary];
  _chromePages[@(browser->GetIdentifier())] = host;
  _browsers[browser->GetIdentifier()] = browser;
  [self adoptBrowser:browser->GetIdentifier()];
  [host syncFrame];
}

- (BOOL)chromePageOfItem:(ArcItem*)item isInWindow:(NSWindow*)win {  // tests
  ChromePageHost* host = _chromePages[@(item.browserId)];
  return host && host.placeholder.window == win && (!host.pageWindow.isVisible || host.pageWindow.parentWindow == win);
}

- (void)acceptBrowser:(CefRefPtr<CefBrowser>)browser {
  NSView* view = CAST_CEF_WINDOW_HANDLE_TO_NSVIEW(browser->GetHost()->GetWindowHandle());
  [_content addSubview:view];  // reparent directly; the view is never without a window in between
  view.frame = _content.bounds;
  view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _browsers[browser->GetIdentifier()] = browser;
  [self adoptBrowser:browser->GetIdentifier()];
}

// A tab this window showed went to another window: show the next tab that isn't on screen elsewhere.
- (void)lostItem:(ArcItem*)item {
  if (_shown != item && ![_splitItems containsObject:item]) {
    [self layoutPanes];
    return;
  }
  _shown = nil;
  _splitItems = nil;
  ArcItem* next = nil;
  for (ArcItem* t in _space.allTabs) {
    if (t == item || !t.url.length || t.noteID || t.easelID) continue;
    MainWindowController* o = t.browserId ? OwnerOf(t.browserId, nil) : nil;
    if (o && o != self) continue;
    next = t;
    break;
  }
  if (next) {
    [self showItem:next];
  } else {
    [self layoutPanes];
    [self selectSidebarRowFor:nil];
    [self updateToolbarAddress];
  }
}

- (void)closeSecondaryWindow {
  [gWindows removeObject:self];
  [MainWindowController saveWindowState];  // closed by hand: it doesn't come back (skipped while quitting)
  [_mediaTimer invalidate];
  _mediaTimer = nil;
  for (LittleWindowController* lw in [_littleWindows copy]) [lw.window close];
  [_peek.window close];
  if (_swipeMonitor) [NSEvent removeMonitor:_swipeMonitor];
  _swipeMonitor = nil;
  std::vector<int> ids;
  for (auto& kv : _browsers) ids.push_back(kv.first);
  for (int bid : ids) {  // its tabs stay in the sidebar; their pages close and reload when shown again
    ArcItem* item = [self itemForBrowser:bid];
    if (item) [self unloadItem:item];
  }
  _browsers.clear();
  [_content removeFromSuperview];
  _content = nil;
  [gMainWindow refreshOtherWindows];
}

// Other windows come back after a restart (Arc: StorableWindows). Saved as Windows.json next to the sidebar:
// each window's Space, shown tab and frame. The main window is the sidebar's own focused Space.
+ (NSString*)windowStatePath {
  MainWindowController* main = gMainWindow;
  if (!main.storePath) return nil;
  return [main.storePath.stringByDeletingLastPathComponent
      stringByAppendingPathComponent:main.selfTestProfiles ? @"SelfTestWindows.json" : @"Windows.json"];
}

+ (NSArray<NSDictionary*>*)windowStateList {
  NSMutableArray* out = [NSMutableArray array];
  for (MainWindowController* w in gWindows) {
    if (w == gMainWindow || !w->_space.spaceID) continue;
    NSMutableDictionary* d = [NSMutableDictionary dictionary];
    d[@"space"] = w->_space.spaceID;
    if (w->_shown.itemID) d[@"item"] = w->_shown.itemID;
    d[@"frame"] = NSStringFromRect(w.window.frame);
    [out addObject:d];
  }
  return out;
}

+ (void)saveWindowState {
  if (gQuitting) return;
  NSString* path = [self windowStatePath];
  if (!path) return;
  NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"version" : @1, @"windows" : [self windowStateList]}
                                                 options:NSJSONWritingPrettyPrinted error:nil];
  [data writeToFile:path atomically:YES];
}

+ (void)prepareForQuit {
  if (gQuitting) return;
  [self saveWindowState];  // frames as they are now
  gQuitting = YES;
}

+ (NSUInteger)savedWindowCount {  // tests
  NSString* path = [self windowStatePath];
  NSDictionary* d = path ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:path] ?: [NSData data]
                                                           options:0 error:nil] : nil;
  return [d isKindOfClass:NSDictionary.class] ? [d[@"windows"] count] : 0;
}

- (NSArray<MainWindowController*>*)restoreWindowsFromList:(NSArray<NSDictionary*>*)list {
  NSMutableArray* opened = [NSMutableArray array];
  MainWindowController* main = gMainWindow ?: self;
  for (NSDictionary* d in list) {
    if (![d isKindOfClass:NSDictionary.class]) continue;
    ArcSpace* space = nil;
    for (ArcSpace* s in main->_spaces)
      if ([s.spaceID isEqualToString:d[@"space"]]) space = s;
    if (!space) continue;  // the Space was deleted since
    ArcItem* item = nil;
    for (ArcItem* t in space.allTabs)
      if ([t.itemID isEqualToString:d[@"item"]]) item = t;
    MainWindowController* w = [[MainWindowController alloc] initSecondaryFrom:main space:space];
    NSRect f = [d[@"frame"] isKindOfClass:NSString.class] ? NSRectFromString(d[@"frame"]) : NSZeroRect;
    if (f.size.width >= 400 && f.size.height >= 300) [w.window setFrame:f display:NO];
    // A tab already on screen in the main window stays there.
    if (item.url.length && item != main->_shown && ![main->_splitItems containsObject:item]) [w showItem:item];
    [opened addObject:w];
  }
  return opened;
}

- (void)restoreSavedWindows {
  NSString* path = [MainWindowController windowStatePath];
  NSData* data = path ? [NSData dataWithContentsOfFile:path] : nil;
  NSDictionary* d = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![d isKindOfClass:NSDictionary.class] || ![d[@"windows"] isKindOfClass:NSArray.class]) return;
  [self restoreWindowsFromList:d[@"windows"]];
  [self.window makeKeyAndOrderFront:nil];  // the main window stays in front
}

#pragma mark NSWindowDelegate

- (BOOL)windowShouldClose:(NSWindow*)sender {
  if (gMainWindow && gMainWindow != self) return YES;  // another window: its tabs stay in the shared sidebar
  if (_closing || _browsers.empty() || !_client || _client->open_browser_count() == 0) return YES;
  [self closeAllBrowsers];
  return NO;
}

// CEF destroys a child browser when its host NSView goes away. Removing the content
// view on window close is what actually tears the browsers down (DoClose returns false).
- (void)windowWillClose:(NSNotification*)notification {
  if (notification.object != self.window) return;  // the Archive window closing is not a quit
  [self closeTabSwitcher];
  [_thumbTimer invalidate];
  _thumbTimer = nil;
  if (gMainWindow && gMainWindow != self) {
    [self closeSecondaryWindow];
    return;
  }
  for (MainWindowController* w in [gWindows copy])
    if (w != self) [w.window close];
  for (LittleWindowController* lw in [_littleWindows copy]) [lw.window close];
  [_peek.window close];
  [_archiveTimer invalidate];
  [_archiveWindow close];
  [self saveSidebarNow];
  [_content removeFromSuperview];
  _content = nil;
  if (_swipeMonitor) [NSEvent removeMonitor:_swipeMonitor];
  _swipeMonitor = nil;
  _browsers.clear();
  if (!_client || _client->open_browser_count() == 0) CefQuitMessageLoop();
}

@end
