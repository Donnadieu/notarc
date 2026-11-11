#import "app/easel.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const CGFloat kPad = 10;     // room around a drawing for its stroke and arrowhead
static const CGFloat kStroke = 3;   // drawing line width
static const CGFloat kHandle = 10;  // resize handle size

static NSArray<NSString*>* DrawingKinds() { return @[ @"arrow", @"rect", @"ellipse", @"pen" ]; }

static BOOL IsHex(id s) {
  if (![s isKindOfClass:NSString.class] || [s length] != 7 || ![s hasPrefix:@"#"]) return NO;
  return [[s substringFromIndex:1] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
                                                                @"0123456789abcdefABCDEF"] invertedSet]].location == NSNotFound;
}

@implementation EaselObject
- (BOOL)isDrawing { return [DrawingKinds() containsObject:self.kind]; }
- (BOOL)isPicture { return [self.kind isEqualToString:@"image"] || [self.kind isEqualToString:@"clip"]; }
- (NSDictionary*)dictionary {
  NSMutableDictionary* d = [@{@"kind" : self.kind ?: @"text", @"frame" : NSStringFromRect(self.frame)} mutableCopy];
  if (self.text) d[@"text"] = self.text;
  if (self.image) d[@"image"] = self.image;
  if (self.link) d[@"link"] = self.link;
  if (self.color) d[@"color"] = self.color;
  if (self.points.count) {
    NSMutableArray* a = [NSMutableArray arrayWithCapacity:self.points.count];
    for (NSValue* v in self.points) {
      NSPoint p = v.pointValue;
      [a addObject:@[ @(round(p.x * 10000) / 10000), @(round(p.y * 10000) / 10000) ]];
    }
    d[@"points"] = a;
  }
  if ([self.kind isEqualToString:@"clip"]) {
    d[@"region"] = NSStringFromRect(self.region);
    d[@"viewport"] = NSStringFromSize(self.viewport);
    d[@"scroll"] = NSStringFromPoint(self.scroll);
    if (self.refreshedAt) d[@"refreshedAt"] = @(self.refreshedAt.timeIntervalSince1970);
  }
  return d;
}
+ (EaselObject*)fromDictionary:(NSDictionary*)d {
  if (![d isKindOfClass:NSDictionary.class]) return nil;
  EaselObject* o = [EaselObject new];
  NSString* kind = [d[@"kind"] isKindOfClass:NSString.class] ? d[@"kind"] : @"text";
  o.kind = [@[ @"text", @"image", @"clip" ] containsObject:kind] || [DrawingKinds() containsObject:kind] ? kind : @"text";
  o.frame = [d[@"frame"] isKindOfClass:NSString.class] ? NSRectFromString(d[@"frame"]) : NSMakeRect(40, 40, 240, 40);
  if ([d[@"text"] isKindOfClass:NSString.class]) o.text = d[@"text"];
  if ([d[@"image"] isKindOfClass:NSString.class]) o.image = [d[@"image"] lastPathComponent];  // never a path
  if ([d[@"link"] isKindOfClass:NSString.class]) o.link = d[@"link"];
  if (IsHex(d[@"color"])) o.color = d[@"color"];
  if ([d[@"points"] isKindOfClass:NSArray.class]) {
    NSMutableArray* pts = [NSMutableArray array];
    for (id p in d[@"points"]) {
      if (![p isKindOfClass:NSArray.class] || [p count] != 2 || ![p[0] isKindOfClass:NSNumber.class] ||
          ![p[1] isKindOfClass:NSNumber.class])
        continue;
      [pts addObject:[NSValue valueWithPoint:NSMakePoint(MIN(1, MAX(0, [p[0] doubleValue])), MIN(1, MAX(0, [p[1] doubleValue])))]];
      if (pts.count >= 5000) break;
    }
    o.points = pts;
  }
  if ([d[@"region"] isKindOfClass:NSString.class]) o.region = NSRectFromString(d[@"region"]);
  if ([d[@"viewport"] isKindOfClass:NSString.class]) o.viewport = NSSizeFromString(d[@"viewport"]);
  if ([d[@"scroll"] isKindOfClass:NSString.class]) o.scroll = NSPointFromString(d[@"scroll"]);
  if ([d[@"refreshedAt"] isKindOfClass:NSNumber.class])
    o.refreshedAt = [NSDate dateWithTimeIntervalSince1970:[d[@"refreshedAt"] doubleValue]];
  return o;
}
@end

// The outline of a drawing inside its view's bounds (flipped): rectangle, ellipse, arrow with head, or pen stroke.
static CGPathRef CreateDrawingPath(EaselObject* o, NSRect bounds) {
  CGMutablePathRef p = CGPathCreateMutable();
  NSRect in = NSMakeRect(NSMinX(bounds) + kPad, NSMinY(bounds) + kPad, MAX(0, bounds.size.width - 2 * kPad),
                         MAX(0, bounds.size.height - 2 * kPad));
  if ([o.kind isEqualToString:@"rect"]) {
    CGPathAddRect(p, NULL, in);
  } else if ([o.kind isEqualToString:@"ellipse"]) {
    CGPathAddEllipseInRect(p, NULL, in);
  } else if (o.points.count) {
    NSPoint last = NSZeroPoint, prev = NSZeroPoint;
    for (NSUInteger i = 0; i < o.points.count; i++) {
      NSPoint n = o.points[i].pointValue;
      NSPoint q = NSMakePoint(NSMinX(in) + n.x * in.size.width, NSMinY(in) + n.y * in.size.height);
      if (i == 0) CGPathMoveToPoint(p, NULL, q.x, q.y);
      else CGPathAddLineToPoint(p, NULL, q.x, q.y);
      prev = last;
      last = q;
    }
    if ([o.kind isEqualToString:@"arrow"] && o.points.count >= 2 && !NSEqualPoints(prev, last)) {
      CGFloat a = atan2(last.y - prev.y, last.x - prev.x), len = 14;
      for (int i = 0; i < 2; i++) {
        CGFloat side = i ? 1.0 : -1.0;
        CGPathMoveToPoint(p, NULL, last.x, last.y);
        CGPathAddLineToPoint(p, NULL, last.x - len * cos(a + side * M_PI / 6), last.y - len * sin(a + side * M_PI / 6));
      }
    }
  }
  return p;
}

@interface EaselItemView : NSView
@property(nonatomic, strong) EaselObject* object;
@property(nonatomic, weak) EaselView* canvas;
@property(nonatomic) BOOL selected;
@property(nonatomic, strong) NSImageView* imageView;
@property(nonatomic, strong) NSTextField* textField;
@property(nonatomic, strong) NSArray<NSView*>* handles;
@end

@interface EaselView ()
- (void)itemClicked:(EaselItemView*)v event:(NSEvent*)e;
- (void)itemDragged:(EaselItemView*)v by:(NSSize)d;
- (void)itemDragEnded:(EaselItemView*)v;
- (void)textChanged:(EaselItemView*)v;
@end

// A corner handle of the selected item; dragging it resizes the item (pictures keep their shape).
@interface EaselHandleView : NSView
@property(nonatomic) int corner;
@property(nonatomic, weak) EaselItemView* item;
@end
@implementation EaselHandleView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1.5, 1.5) xRadius:2 yRadius:2];
  [NSColor.whiteColor setFill];
  [p fill];
  [NSColor.controlAccentColor setStroke];
  p.lineWidth = 1.5;
  [p stroke];
}
- (void)mouseDown:(NSEvent*)e {}
- (void)mouseDragged:(NSEvent*)e {
  EaselView* c = self.item.canvas;
  [c resizeObject:self.item.object corner:self.corner to:[c convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseUp:(NSEvent*)e { [self.item.canvas itemDragEnded:self.item]; }
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.crosshairCursor]; }
- (NSString*)accessibilityLabel { return @"Resize"; }
@end

// One object on the canvas: draws a card (image or text) or a drawing, selection ring and handles, drag to move.
@implementation EaselItemView {
  NSPoint _dragStart;
  BOOL _dragged;
}
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
  if (self.object.isDrawing) {
    CGContextRef c = NSGraphicsContext.currentContext.CGContext;
    CGPathRef path = CreateDrawingPath(self.object, self.bounds);
    CGContextAddPath(c, path);
    CGContextSetStrokeColorWithColor(c, [EaselView colorFromHex:self.object.color].CGColor);
    CGContextSetLineWidth(c, kStroke);
    CGContextSetLineCap(c, kCGLineCapRound);
    CGContextSetLineJoin(c, kCGLineJoinRound);
    CGContextStrokePath(c);
    CGPathRelease(path);
    if (self.selected) {
      NSBezierPath* ring = [NSBezierPath bezierPathWithRect:NSInsetRect(self.bounds, kHandle / 2, kHandle / 2)];
      CGFloat dash[] = {4, 3};
      [ring setLineDash:dash count:2 phase:0];
      [NSColor.controlAccentColor setStroke];
      [ring stroke];
    }
    return;
  }
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:8 yRadius:8];
  if (self.object.isPicture) {
    [[NSColor colorWithWhite:0 alpha:0.08] setFill];
    [p fill];
  }
  if (self.selected) {
    [NSColor.controlAccentColor setStroke];
    p.lineWidth = 2;
    [p stroke];
  }
}
// Drawings are only hit near their line, so a capture under an arrow can still be clicked.
- (NSView*)hitTest:(NSPoint)point {
  NSView* v = [super hitTest:point];
  if (v != self || !self.object.isDrawing) return v;
  NSPoint l = [self convertPoint:point fromView:self.superview];
  CGPathRef path = CreateDrawingPath(self.object, self.bounds);
  CGPathRef wide = CGPathCreateCopyByStrokingPath(path, NULL, kStroke + 12, kCGLineCapRound, kCGLineJoinRound, 10);
  BOOL in = CGPathContainsPoint(wide, NULL, l, false);
  CGPathRelease(wide);
  CGPathRelease(path);
  return in ? self : nil;
}
- (void)setSelected:(BOOL)s {
  _selected = s;
  for (NSView* h in self.handles) h.hidden = !s;
  [self setNeedsDisplay:YES];
}
- (void)mouseDown:(NSEvent*)e {
  _dragStart = [self.superview convertPoint:e.locationInWindow fromView:nil];
  _dragged = NO;
  [self.canvas itemClicked:self event:e];
}
- (void)mouseDragged:(NSEvent*)e {
  NSPoint p = [self.superview convertPoint:e.locationInWindow fromView:nil];
  NSSize d = NSMakeSize(p.x - _dragStart.x, p.y - _dragStart.y);
  _dragStart = p;
  _dragged = YES;
  [self.canvas itemDragged:self by:d];
}
- (void)mouseUp:(NSEvent*)e {
  if (_dragged) [self.canvas itemDragEnded:self];
}
- (void)resetCursorRects {
  if ([self.canvas.tool isEqualToString:@"select"]) [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor];
}
- (void)layoutHandles {
  NSSize s = self.bounds.size;
  for (EaselHandleView* h in self.handles) {
    BOOL left = h.corner == 0 || h.corner == 2, top = h.corner == 0 || h.corner == 1;
    h.frame = NSMakeRect(left ? 0 : s.width - kHandle, top ? 0 : s.height - kHandle, kHandle, kHandle);
  }
}
- (void)setFrameSize:(NSSize)s {
  [super setFrameSize:s];
  [self layoutHandles];
}
@end

// A colour in the easel toolbar.
@interface EaselSwatch : NSView
@property(nonatomic, copy) NSString* hex;
@property(nonatomic, weak) EaselView* canvas;
@property(nonatomic) BOOL chosen;
@end
@implementation EaselSwatch
- (void)drawRect:(NSRect)r {
  NSRect b = NSInsetRect(self.bounds, 3, 3);
  [[EaselView colorFromHex:self.hex] setFill];
  [[NSBezierPath bezierPathWithOvalInRect:b] fill];
  if (self.chosen) {
    NSBezierPath* ring = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(self.bounds, 0.75, 0.75)];
    ring.lineWidth = 1.5;
    [NSColor.labelColor setStroke];
    [ring stroke];
  }
}
- (void)mouseDown:(NSEvent*)e { self.canvas.color = self.hex; }
- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityButtonRole; }
- (NSString*)accessibilityLabel { return [@"Colour " stringByAppendingString:self.hex]; }
- (BOOL)accessibilityPerformPress {
  self.canvas.color = self.hex;
  return YES;
}
@end

@implementation EaselView {
  NSMutableArray<EaselObject*>* _objects;
  NSMutableArray<EaselItemView*>* _views;
  EaselObject* _selected;
  NSString* _directory;
  NSView* _toolbar;
  NSSegmentedControl* _tools;
  NSMutableArray<EaselSwatch*>* _swatches;
  EaselObject* _drawing;  // being drawn right now
  NSMutableArray<NSValue*>* _drawPoints;
}
+ (NSArray<NSString*>*)palette {
  return @[ @"#1F2328", @"#8B8D98", @"#E5484D", @"#E93D82", @"#8E4EC6", @"#0090FF", @"#30A46C", @"#FFB224" ];
}
+ (NSArray<NSString*>*)toolNames { return @[ @"select", @"text", @"arrow", @"rect", @"ellipse", @"pen" ]; }
+ (NSColor*)colorFromHex:(NSString*)hex {
  if (!IsHex(hex)) return NSColor.labelColor;
  unsigned v = 0;
  [[NSScanner scannerWithString:[hex substringFromIndex:1]] scanHexInt:&v];
  return [NSColor colorWithSRGBRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:1];
}
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    _objects = [NSMutableArray array];
    _views = [NSMutableArray array];
    _tool = @"select";
    _color = [EaselView palette][2];
    self.wantsLayer = YES;
  }
  return self;
}
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (NSMutableArray<EaselObject*>*)objects { return _objects; }
- (NSString*)directory { return _directory; }

// Dotted canvas like Arc's easel background.
- (void)drawRect:(NSRect)r {
  [NSColor.textBackgroundColor setFill];
  NSRectFill(r);
  [[NSColor colorWithWhite:0.5 alpha:0.25] setFill];
  for (CGFloat x = floor(NSMinX(r) / 24) * 24; x < NSMaxX(r); x += 24)
    for (CGFloat y = floor(NSMinY(r) / 24) * 24; y < NSMaxY(r); y += 24)
      NSRectFill(NSMakeRect(x, y, 1.5, 1.5));
}

// MARK: Toolbar: Select, Text, Arrow, Rectangle, Ellipse, Pen, then the colours.
- (NSView*)toolbar {
  if (_toolbar) return _toolbar;
  NSArray* symbols = @[ @"cursorarrow", @"textformat", @"arrow.up.right", @"rectangle", @"circle", @"scribble" ];
  NSArray* names = @[ @"Select (V)", @"Text (T)", @"Arrow (A)", @"Rectangle (R)", @"Ellipse (O)", @"Pen (P)" ];
  NSMutableArray* images = [NSMutableArray array];
  for (NSUInteger i = 0; i < symbols.count; i++)
    [images addObject:[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:names[i]] ?: [NSImage new]];
  _tools = [NSSegmentedControl segmentedControlWithImages:images trackingMode:NSSegmentSwitchTrackingSelectOne
                                                   target:self action:@selector(toolPicked:)];
  _tools.segmentStyle = NSSegmentStyleSeparated;
  for (NSUInteger i = 0; i < names.count; i++) [_tools setToolTip:names[i] forSegment:i];
  _tools.selectedSegment = [[EaselView toolNames] indexOfObject:_tool];
  [_tools sizeToFit];
  NSVisualEffectView* bar = [NSVisualEffectView new];
  bar.material = NSVisualEffectMaterialPopover;
  bar.state = NSVisualEffectStateActive;
  bar.wantsLayer = YES;
  bar.layer.cornerRadius = 12;
  bar.layer.borderWidth = 0.5;
  bar.layer.borderColor = [NSColor colorWithWhite:0.5 alpha:0.25].CGColor;
  bar.shadow = [NSShadow new];
  bar.identifier = @"easelToolbar";
  CGFloat h = MAX(34, _tools.frame.size.height + 10), x = 6;
  _tools.frameOrigin = NSMakePoint(x, round((h - _tools.frame.size.height) / 2));
  [bar addSubview:_tools];
  x += _tools.frame.size.width + 6;
  // Arc's easel bar also adds a picture from a file and captures part of a page straight onto the canvas.
  for (NSArray* a in @[ @[ @"photo", @"Add Image...", @"addImageFromFile:" ], @[ @"camera.viewfinder", @"Capture", @"captureIntoEasel:" ] ]) {
    NSButton* b = [NSButton buttonWithImage:[NSImage imageWithSystemSymbolName:a[0] accessibilityDescription:a[1]]
                                     target:self action:NSSelectorFromString(a[2])];
    b.bordered = NO;
    b.toolTip = a[1];
    b.identifier = @"easelExtraTool";
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium];
    b.contentTintColor = NSColor.secondaryLabelColor;
    b.frame = NSMakeRect(x, round((h - 24) / 2), 28, 24);
    [bar addSubview:b];
    x += 30;
  }
  NSBox* sep = [[NSBox alloc] initWithFrame:NSMakeRect(x + 2, round((h - 18) / 2), 1, 18)];
  sep.boxType = NSBoxSeparator;
  [bar addSubview:sep];
  x += 10;
  _swatches = [NSMutableArray array];
  for (NSString* hex in [EaselView palette]) {
    EaselSwatch* s = [[EaselSwatch alloc] initWithFrame:NSMakeRect(x, round((h - 22) / 2), 22, 22)];
    s.hex = hex;
    s.canvas = self;
    s.chosen = [hex isEqualToString:_color];
    s.toolTip = @"Colour";
    [bar addSubview:s];
    [_swatches addObject:s];
    x += 24;
  }
  bar.frame = NSMakeRect(0, 0, x + 4, h);
  bar.toolTip = nil;
  _toolbar = bar;
  return bar;
}
- (IBAction)addImageFromFile:(id)sender {
  NSOpenPanel* op = [NSOpenPanel openPanel];
  op.allowedContentTypes = @[ UTTypeImage ];
  op.allowsMultipleSelection = NO;
  __weak EaselView* weakSelf = self;
  [op beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSModalResponseOK || !op.URL) return;
    NSImage* img = [[NSImage alloc] initWithContentsOfURL:op.URL];
    NSBitmapImageRep* rep = img ? [NSBitmapImageRep imageRepWithData:img.TIFFRepresentation] : nil;
    NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (png) [weakSelf addImagePNG:png link:nil];
  }];
}
- (IBAction)captureIntoEasel:(id)sender {
  if ([self.delegate respondsToSelector:@selector(easelWantsCapture:)]) [self.delegate easelWantsCapture:self];
}
- (NSUInteger)extraToolCount {  // tests (V43)
  NSUInteger n = 0;
  for (NSView* v in _toolbar.subviews) n += [v.identifier isEqual:@"easelExtraTool"];
  return n;
}
- (void)toolPicked:(NSSegmentedControl*)s {
  NSArray* t = [EaselView toolNames];
  if (s.selectedSegment >= 0 && s.selectedSegment < (NSInteger)t.count) self.tool = t[s.selectedSegment];
}
- (void)setTool:(NSString*)tool {
  if (![[EaselView toolNames] containsObject:tool]) tool = @"select";
  _tool = [tool copy];
  _tools.selectedSegment = [[EaselView toolNames] indexOfObject:_tool];
  if (![tool isEqualToString:@"select"] && [self.window.firstResponder isKindOfClass:NSText.class])
    [self.window makeFirstResponder:self];  // end text editing before drawing
  [self.window invalidateCursorRectsForView:self];
  for (NSView* v in _views) [self.window invalidateCursorRectsForView:v];
}
- (void)setColor:(NSString*)color {
  if (!IsHex(color)) return;
  _color = [color copy];
  for (EaselSwatch* s in _swatches) {
    s.chosen = [s.hex isEqualToString:color];
    [s setNeedsDisplay:YES];
  }
  EaselObject* o = _selected;
  if (o && (o.isDrawing || [o.kind isEqualToString:@"text"])) {
    o.color = color;
    EaselItemView* v = [self viewFor:o];
    if (v.textField) v.textField.textColor = [EaselView colorFromHex:color];
    [v setNeedsDisplay:YES];
    [self changed];
  }
}
- (BOOL)isDrawingTool { return [DrawingKinds() containsObject:_tool]; }
- (void)resetCursorRects {
  if (![_tool isEqualToString:@"select"]) [self addCursorRect:self.visibleRect cursor:NSCursor.crosshairCursor];
}
// With a drawing or text tool, the whole canvas (items included) takes the mouse.
- (NSView*)hitTest:(NSPoint)p {
  if (![_tool isEqualToString:@"select"]) return NSPointInRect([self convertPoint:p fromView:self.superview], self.bounds) ? self : nil;
  return [super hitTest:p];
}

- (void)loadFromDirectory:(NSString*)dir {
  _directory = [dir copy];
  [_objects removeAllObjects];
  _selected = nil;
  _drawing = nil;
  self.title = nil;
  NSData* data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"easel.json"]];
  NSDictionary* root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if ([root isKindOfClass:NSDictionary.class]) {
    if ([root[@"title"] isKindOfClass:NSString.class]) self.title = root[@"title"];
    if ([root[@"objects"] isKindOfClass:NSArray.class])
      for (NSDictionary* d in root[@"objects"]) {
        EaselObject* o = [EaselObject fromDictionary:d];
        if (o) [_objects addObject:o];
      }
  }
  self.tool = @"select";
  [self rebuild];
}
- (BOOL)save {
  if (!_directory) return NO;
  [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSMutableArray* arr = [NSMutableArray array];
  for (EaselObject* o in _objects) [arr addObject:[o dictionary]];
  NSMutableDictionary* root = [@{@"version" : @1, @"objects" : arr} mutableCopy];
  if (self.title) root[@"title"] = self.title;
  NSData* d = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
  return [d writeToFile:[_directory stringByAppendingPathComponent:@"easel.json"] atomically:YES];
}
- (void)changed {
  [self save];
  [self.delegate easelDidChange:self];
}

- (void)rebuild {
  for (NSView* v in _views) [v removeFromSuperview];
  [_views removeAllObjects];
  for (EaselObject* o in _objects) [self addViewFor:o];
  [self updateSize];
}
- (void)updateSize {
  NSRect u = NSZeroRect;
  for (EaselObject* o in _objects) u = NSUnionRect(u, o.frame);
  NSSize visible = self.enclosingScrollView ? self.enclosingScrollView.contentSize : self.frame.size;
  [self setFrameSize:NSMakeSize(MAX(visible.width, NSMaxX(u) + 80), MAX(visible.height, NSMaxY(u) + 80))];
}
- (NSString*)clipTip:(EaselObject*)o {
  if (!o.link.length) return nil;
  if (![o.kind isEqualToString:@"clip"]) return [@"Double-click to open " stringByAppendingString:o.link];
  return [NSString stringWithFormat:@"Live clip of %@. It refreshes when you open this easel (File > Refresh Live Clips "
                                    @"to do it now). Double-click to open the page.", o.link];
}
- (EaselItemView*)addViewFor:(EaselObject*)o {
  EaselItemView* v = [[EaselItemView alloc] initWithFrame:o.frame];
  v.object = o;
  v.canvas = self;
  if (o.isPicture) {
    NSData* png = [NSData dataWithContentsOfFile:[_directory stringByAppendingPathComponent:o.image ?: @""]];
    v.imageView = [[NSImageView alloc] initWithFrame:NSInsetRect(v.bounds, 4, 4)];
    v.imageView.image = png ? [[NSImage alloc] initWithData:png] : nil;
    v.imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    v.imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    v.imageView.wantsLayer = YES;
    v.imageView.layer.cornerRadius = 6;
    v.imageView.layer.masksToBounds = YES;
    // Clicks go to the card (select/drag), not the image view.
    v.imageView.enabled = NO;
    [v addSubview:v.imageView];
    if ([o.kind isEqualToString:@"clip"]) {
      NSTextField* badge = [NSTextField labelWithString:@"Live"];
      badge.font = [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold];
      badge.textColor = NSColor.whiteColor;
      badge.alignment = NSTextAlignmentCenter;
      badge.wantsLayer = YES;
      badge.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.55].CGColor;
      badge.layer.cornerRadius = 4;
      badge.frame = NSMakeRect(10, 10, 34, 16);
      [v addSubview:badge];
    }
    v.toolTip = [self clipTip:o];
  } else if (!o.isDrawing) {
    v.textField = [NSTextField textFieldWithString:o.text ?: @""];
    v.textField.frame = NSInsetRect(v.bounds, 6, 6);
    v.textField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    v.textField.bordered = NO;
    v.textField.drawsBackground = NO;
    v.textField.font = [NSFont systemFontOfSize:18 weight:NSFontWeightMedium];
    if (o.color) v.textField.textColor = [EaselView colorFromHex:o.color];
    v.textField.delegate = self;
    v.textField.placeholderString = @"Text";
    [v addSubview:v.textField];
  }
  NSMutableArray* handles = [NSMutableArray array];
  for (int c = 0; c < 4; c++) {
    EaselHandleView* h = [[EaselHandleView alloc] initWithFrame:NSMakeRect(0, 0, kHandle, kHandle)];
    h.corner = c;
    h.item = v;
    [v addSubview:h];
    [handles addObject:h];
  }
  v.handles = handles;
  [v layoutHandles];
  v.selected = o == _selected;
  [self addSubview:v];
  [_views addObject:v];
  return v;
}
- (EaselItemView*)viewFor:(EaselObject*)o {
  for (EaselItemView* v in _views) if (v.object == o) return v;
  return nil;
}
- (NSView*)viewForObject:(EaselObject*)o { return [self viewFor:o]; }

- (NSPoint)nextFreePoint {
  CGFloat y = 40;
  for (EaselObject* o in _objects) y = MAX(y, NSMaxY(o.frame) + 24);
  return NSMakePoint(40, y);
}
- (void)insert:(EaselObject*)o {
  [_objects addObject:o];
  [self addViewFor:o];
  [self selectObject:o];
  [self updateSize];
  [self changed];
}
- (EaselObject*)addText:(NSString*)text at:(NSPoint)p {
  EaselObject* o = [EaselObject new];
  o.kind = @"text";
  o.text = text ?: @"";
  if (p.x < 0) p = [self nextFreePoint];
  o.frame = NSMakeRect(p.x, p.y, 320, 44);
  [self insert:o];
  return o;
}
- (NSString*)writePNG:(NSData*)png {
  if (!png.length || !_directory) return nil;
  [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* name = [NSUUID.UUID.UUIDString stringByAppendingString:@".png"];
  return [png writeToFile:[_directory stringByAppendingPathComponent:name] atomically:YES] ? name : nil;
}
// Captures drop in at a readable card size, as in Arc.
- (EaselObject*)addPicture:(NSData*)png kind:(NSString*)kind link:(NSString*)link size:(NSSize)s {
  NSString* name = [self writePNG:png];
  if (!name) return nil;
  if (s.width <= 0 || s.height <= 0) s = NSMakeSize(480, 300);
  CGFloat scale = MIN(1.0, 480.0 / s.width);
  EaselObject* o = [EaselObject new];
  o.kind = kind;
  o.image = name;
  o.link = link;
  NSPoint p = [self nextFreePoint];
  o.frame = NSMakeRect(p.x, p.y, round(s.width * scale) + 8, round(s.height * scale) + 8);
  return o;
}
- (EaselObject*)addImagePNG:(NSData*)png link:(NSString*)link {
  EaselObject* o = [self addPicture:png kind:@"image" link:link size:[[NSImage alloc] initWithData:png].size];
  if (o) [self insert:o];
  return o;
}
- (EaselObject*)addClipPNG:(NSData*)png link:(NSString*)link region:(NSRect)region viewport:(NSSize)viewport
                    scroll:(NSPoint)scroll {
  if (!link.length || NSIsEmptyRect(region)) return nil;
  EaselObject* o = [self addPicture:png kind:@"clip" link:link size:region.size];
  if (!o) return nil;
  o.region = region;
  o.viewport = viewport;
  o.scroll = scroll;
  o.refreshedAt = [NSDate date];
  [self insert:o];
  return o;
}
- (BOOL)replaceImageOf:(EaselObject*)o png:(NSData*)png {
  if (![_objects containsObject:o]) return NO;
  NSString* name = [self writePNG:png];
  if (!name) return NO;
  if (o.image) [[NSFileManager defaultManager] removeItemAtPath:[_directory stringByAppendingPathComponent:o.image] error:nil];
  o.image = name;
  o.refreshedAt = [NSDate date];
  [self viewFor:o].imageView.image = [[NSImage alloc] initWithData:png];
  [self save];
  return YES;
}
- (NSArray<EaselObject*>*)liveClips {
  return [_objects filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"kind == 'clip'"]];
}

// MARK: Drawings. The frame is the points' box plus padding; arrow and pen points are stored relative to that box.
- (void)shape:(EaselObject*)o fromPoints:(NSArray<NSValue*>*)pts {
  CGFloat x0 = CGFLOAT_MAX, y0 = CGFLOAT_MAX, x1 = -CGFLOAT_MAX, y1 = -CGFLOAT_MAX;
  for (NSValue* v in pts) {
    NSPoint p = v.pointValue;
    x0 = MIN(x0, p.x), y0 = MIN(y0, p.y), x1 = MAX(x1, p.x), y1 = MAX(y1, p.y);
  }
  if (!pts.count) x0 = y0 = x1 = y1 = 0;
  NSRect box = NSMakeRect(x0, y0, x1 - x0, y1 - y0);
  o.frame = NSMakeRect(box.origin.x - kPad, box.origin.y - kPad, box.size.width + 2 * kPad, box.size.height + 2 * kPad);
  if ([o.kind isEqualToString:@"arrow"] || [o.kind isEqualToString:@"pen"]) {
    NSMutableArray* n = [NSMutableArray arrayWithCapacity:pts.count];
    for (NSValue* v in pts) {
      NSPoint p = v.pointValue;
      [n addObject:[NSValue valueWithPoint:NSMakePoint(box.size.width > 0 ? (p.x - x0) / box.size.width : 0.5,
                                                       box.size.height > 0 ? (p.y - y0) / box.size.height : 0.5)]];
    }
    o.points = n;
  } else {
    o.points = nil;
  }
}
- (EaselObject*)addDrawing:(NSString*)kind points:(NSArray<NSValue*>*)canvasPoints {
  if (![DrawingKinds() containsObject:kind] || canvasPoints.count < 2) return nil;
  EaselObject* o = [EaselObject new];
  o.kind = kind;
  o.color = _color;
  [self shape:o fromPoints:canvasPoints];
  [self insert:o];
  return o;
}
- (NSPoint)clampToCanvas:(NSPoint)p { return NSMakePoint(MAX(kPad, p.x), MAX(kPad, p.y)); }
- (NSArray<NSValue*>*)currentDrawPoints:(NSPoint)p {
  if ([_drawing.kind isEqualToString:@"pen"]) {
    NSPoint last = _drawPoints.lastObject.pointValue;
    if (hypot(p.x - last.x, p.y - last.y) >= 1.5 && _drawPoints.count < 5000) [_drawPoints addObject:[NSValue valueWithPoint:p]];
    return _drawPoints;
  }
  return @[ _drawPoints.firstObject, [NSValue valueWithPoint:p] ];
}
- (void)updateDrawingTo:(NSPoint)p {
  [self shape:_drawing fromPoints:[self currentDrawPoints:[self clampToCanvas:p]]];
  EaselItemView* v = [self viewFor:_drawing];
  v.frame = _drawing.frame;
  [v setNeedsDisplay:YES];
}

- (void)selectObject:(EaselObject*)o {
  _selected = o;
  for (EaselItemView* v in _views) v.selected = v.object == o;
  // Picking a coloured object shows its colour as the current one.
  if (o.color) {
    _color = [o.color copy];
    for (EaselSwatch* s in _swatches) {
      s.chosen = [s.hex isEqualToString:_color];
      [s setNeedsDisplay:YES];
    }
  }
}
- (EaselObject*)selectedObject { return _selected; }
- (void)deleteSelected {
  if (!_selected) return;
  EaselItemView* v = [self viewFor:_selected];
  [v removeFromSuperview];
  if (v) [_views removeObject:v];
  if (_selected.image) [[NSFileManager defaultManager] removeItemAtPath:[_directory stringByAppendingPathComponent:_selected.image] error:nil];
  [_objects removeObject:_selected];
  _selected = nil;
  [self changed];
}
- (IBAction)delete:(id)sender { [self deleteSelected]; }
- (void)moveObject:(EaselObject*)o by:(NSSize)d {
  NSRect f = o.frame;
  f.origin.x = MAX(0, f.origin.x + d.width);
  f.origin.y = MAX(0, f.origin.y + d.height);
  o.frame = f;
  [self viewFor:o].frame = f;
}
// Drag a corner: the opposite corner stays put; pictures keep their proportions; nothing shrinks below a usable size.
- (void)resizeObject:(EaselObject*)o corner:(int)corner to:(NSPoint)p {
  NSRect f = o.frame;
  CGFloat minSize = o.isDrawing ? 2 * kPad + 8 : 40;
  BOOL left = corner == 0 || corner == 2, top = corner == 0 || corner == 1;
  CGFloat ax = left ? NSMaxX(f) : NSMinX(f), ay = top ? NSMaxY(f) : NSMinY(f);
  CGFloat w = MAX(minSize, left ? ax - p.x : p.x - ax), h = MAX(minSize, top ? ay - p.y : p.y - ay);
  if (o.isPicture && f.size.width > 0 && f.size.height > 0) {
    CGFloat aspect = f.size.width / f.size.height;
    if (w / aspect >= h) h = w / aspect;
    else w = h * aspect;
  }
  w = round(w), h = round(h);
  NSRect nf = NSMakeRect(left ? ax - w : ax, top ? ay - h : ay, w, h);  // the anchor corner stays exactly where it was
  if (NSMinX(nf) < 0 || NSMinY(nf) < 0) return;
  o.frame = nf;
  EaselItemView* v = [self viewFor:o];
  v.frame = nf;
  [v setNeedsDisplay:YES];
}

// Mouse: with Select, a click on empty canvas deselects and a double-click adds a text box there (as in Arc). With
// Text, a click adds a text box; with a drawing tool, a drag draws.
- (void)mouseDown:(NSEvent*)e {
  [self.window makeFirstResponder:self];
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  if ([_tool isEqualToString:@"text"] || ([_tool isEqualToString:@"select"] && e.clickCount == 2)) {
    EaselObject* o = [self addText:@"" at:NSMakePoint(p.x, MAX(0, p.y - 22))];
    if (o.color == nil && ![_tool isEqualToString:@"select"]) {
      o.color = _color;
      [self viewFor:o].textField.textColor = [EaselView colorFromHex:_color];
    }
    self.tool = @"select";
    [self.window makeFirstResponder:[self viewFor:o].textField];
    return;
  }
  if (self.isDrawingTool) {
    p = [self clampToCanvas:p];
    _drawPoints = [NSMutableArray arrayWithObject:[NSValue valueWithPoint:p]];
    _drawing = [EaselObject new];
    _drawing.kind = _tool;
    _drawing.color = _color;
    [self shape:_drawing fromPoints:@[ _drawPoints[0], _drawPoints[0] ]];
    [_objects addObject:_drawing];
    [self addViewFor:_drawing];
    return;
  }
  [self selectObject:nil];
}
- (void)mouseDragged:(NSEvent*)e {
  if (_drawing) [self updateDrawingTo:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseUp:(NSEvent*)e {
  if (!_drawing) return;
  EaselObject* o = _drawing;
  [self updateDrawingTo:[self convertPoint:e.locationInWindow fromView:nil]];
  _drawing = nil;
  NSSize s = NSMakeSize(o.frame.size.width - 2 * kPad, o.frame.size.height - 2 * kPad);
  if (MAX(s.width, s.height) < 4) {  // a click, not a drawing
    EaselItemView* v = [self viewFor:o];
    [v removeFromSuperview];
    if (v) [_views removeObject:v];
    [_objects removeObject:o];
    return;
  }
  [self selectObject:o];
  [self updateSize];
  [self changed];
}
- (void)itemClicked:(EaselItemView*)v event:(NSEvent*)e {
  [self selectObject:v.object];
  if (v.textField) {
    [self.window makeFirstResponder:v.textField];
  } else {
    [self.window makeFirstResponder:self];
    if (e.clickCount == 2 && v.object.link.length) [self.delegate easel:self openLink:v.object.link];
  }
}
- (void)itemDragged:(EaselItemView*)v by:(NSSize)d { [self moveObject:v.object by:d]; }
- (void)itemDragEnded:(EaselItemView*)v {
  [self updateSize];
  [self changed];
}
- (void)keyDown:(NSEvent*)e {
  unichar c = e.charactersIgnoringModifiers.length ? [e.charactersIgnoringModifiers characterAtIndex:0] : 0;
  if ((c == NSDeleteCharacter || c == NSDeleteFunctionKey || c == NSBackspaceCharacter) && _selected) {
    [self deleteSelected];
    return;
  }
  if (e.keyCode == 53) {  // Esc: back to Select
    self.tool = @"select";
    return;
  }
  NSUInteger mods = e.modifierFlags & (NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption);
  NSDictionary* keys = @{@"v" : @"select", @"t" : @"text", @"a" : @"arrow", @"r" : @"rect", @"o" : @"ellipse", @"p" : @"pen"};
  NSString* tool = mods ? nil : keys[e.charactersIgnoringModifiers.lowercaseString ?: @""];
  if (tool) {
    self.tool = tool;
    return;
  }
  [super keyDown:e];
}
- (void)controlTextDidChange:(NSNotification*)n {
  for (EaselItemView* v in _views)
    if (v.textField == n.object) {
      v.object.text = v.textField.stringValue;
      [self textChanged:v];
    }
}
- (void)textChanged:(EaselItemView*)v { [self changed]; }
- (void)controlTextDidEndEditing:(NSNotification*)n {
  // Empty text boxes disappear when you leave them, like Arc.
  for (EaselItemView* v in [_views copy])
    if (v.textField == n.object && v.textField.stringValue.length == 0) {
      [self selectObject:v.object];
      [self deleteSelected];
    }
}

// MARK: Tests
- (void)testDragFrom:(NSPoint)from to:(NSPoint)to steps:(int)steps {
  NSView* target = [self hitTest:[self.superview convertPoint:from fromView:self]];
  if (!target) return;
  NSEvent* (^ev)(NSEventType, NSPoint) = ^(NSEventType t, NSPoint p) {
    return [NSEvent mouseEventWithType:t location:[self convertPoint:p toView:nil] modifierFlags:0 timestamp:0
                          windowNumber:self.window.windowNumber context:nil eventNumber:0 clickCount:1 pressure:1];
  };
  [target mouseDown:ev(NSEventTypeLeftMouseDown, from)];
  steps = MAX(1, steps);
  for (int i = 1; i <= steps; i++) {
    CGFloat t = (CGFloat)i / steps;
    // A gentle wave, so pen strokes aren't straight lines.
    NSPoint p = NSMakePoint(from.x + (to.x - from.x) * t, from.y + (to.y - from.y) * t + (i < steps ? 12 * sin(t * M_PI) : 0));
    [target mouseDragged:ev(NSEventTypeLeftMouseDragged, p)];
  }
  [target mouseUp:ev(NSEventTypeLeftMouseUp, to)];
}
@end
