#import "app/easel.h"

@implementation EaselObject
- (NSDictionary*)dictionary {
  NSMutableDictionary* d = [@{@"kind" : self.kind ?: @"text", @"frame" : NSStringFromRect(self.frame)} mutableCopy];
  if (self.text) d[@"text"] = self.text;
  if (self.image) d[@"image"] = self.image;
  if (self.link) d[@"link"] = self.link;
  return d;
}
+ (EaselObject*)fromDictionary:(NSDictionary*)d {
  if (![d isKindOfClass:NSDictionary.class]) return nil;
  EaselObject* o = [EaselObject new];
  o.kind = [d[@"kind"] isKindOfClass:NSString.class] ? d[@"kind"] : @"text";
  o.frame = [d[@"frame"] isKindOfClass:NSString.class] ? NSRectFromString(d[@"frame"]) : NSMakeRect(40, 40, 240, 40);
  if ([d[@"text"] isKindOfClass:NSString.class]) o.text = d[@"text"];
  if ([d[@"image"] isKindOfClass:NSString.class]) o.image = [d[@"image"] lastPathComponent];  // never a path
  if ([d[@"link"] isKindOfClass:NSString.class]) o.link = d[@"link"];
  return o;
}
@end

// One object on the canvas: draws a card (image or text), selection ring, drag to move.
@interface EaselItemView : NSView
@property(nonatomic, strong) EaselObject* object;
@property(nonatomic, weak) EaselView* canvas;
@property(nonatomic) BOOL selected;
@property(nonatomic, strong) NSImageView* imageView;
@property(nonatomic, strong) NSTextField* textField;
@end

@interface EaselView ()
- (void)itemClicked:(EaselItemView*)v event:(NSEvent*)e;
- (void)itemDragged:(EaselItemView*)v by:(NSSize)d;
- (void)itemDragEnded:(EaselItemView*)v;
- (void)textChanged:(EaselItemView*)v;
@end

@implementation EaselItemView {
  NSPoint _dragStart;
  BOOL _dragged;
}
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)r {
  NSBezierPath* p = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:8 yRadius:8];
  if ([self.object.kind isEqualToString:@"image"]) {
    [[NSColor colorWithWhite:0 alpha:0.08] setFill];
    [p fill];
  }
  if (self.selected) {
    [NSColor.controlAccentColor setStroke];
    p.lineWidth = 2;
    [p stroke];
  }
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
- (void)resetCursorRects { [self addCursorRect:self.bounds cursor:NSCursor.openHandCursor]; }
@end

@implementation EaselView {
  NSMutableArray<EaselObject*>* _objects;
  NSMutableArray<EaselItemView*>* _views;
  EaselObject* _selected;
  NSString* _directory;
}
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    _objects = [NSMutableArray array];
    _views = [NSMutableArray array];
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

- (void)loadFromDirectory:(NSString*)dir {
  _directory = [dir copy];
  [_objects removeAllObjects];
  _selected = nil;
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
- (EaselItemView*)addViewFor:(EaselObject*)o {
  EaselItemView* v = [[EaselItemView alloc] initWithFrame:o.frame];
  v.object = o;
  v.canvas = self;
  v.selected = o == _selected;
  if ([o.kind isEqualToString:@"image"]) {
    NSImage* img = [[NSImage alloc] initWithContentsOfFile:[_directory stringByAppendingPathComponent:o.image ?: @""]];
    v.imageView = [[NSImageView alloc] initWithFrame:NSInsetRect(v.bounds, 4, 4)];
    v.imageView.image = img;
    v.imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    v.imageView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    v.imageView.wantsLayer = YES;
    v.imageView.layer.cornerRadius = 6;
    v.imageView.layer.masksToBounds = YES;
    // Clicks go to the card (select/drag), not the image view.
    v.imageView.enabled = NO;
    [v addSubview:v.imageView];
    v.toolTip = o.link.length ? [@"Double-click to open " stringByAppendingString:o.link] : nil;
  } else {
    v.textField = [NSTextField textFieldWithString:o.text ?: @""];
    v.textField.frame = NSInsetRect(v.bounds, 6, 6);
    v.textField.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    v.textField.bordered = NO;
    v.textField.drawsBackground = NO;
    v.textField.font = [NSFont systemFontOfSize:18 weight:NSFontWeightMedium];
    v.textField.delegate = self;
    v.textField.placeholderString = @"Text";
    [v addSubview:v.textField];
  }
  [self addSubview:v];
  [_views addObject:v];
  return v;
}
- (EaselItemView*)viewFor:(EaselObject*)o {
  for (EaselItemView* v in _views) if (v.object == o) return v;
  return nil;
}

- (NSPoint)nextFreePoint {
  CGFloat y = 40;
  for (EaselObject* o in _objects) y = MAX(y, NSMaxY(o.frame) + 24);
  return NSMakePoint(40, y);
}
- (EaselObject*)addText:(NSString*)text at:(NSPoint)p {
  EaselObject* o = [EaselObject new];
  o.kind = @"text";
  o.text = text ?: @"";
  if (p.x < 0) p = [self nextFreePoint];
  o.frame = NSMakeRect(p.x, p.y, 320, 44);
  [_objects addObject:o];
  [self addViewFor:o];
  [self selectObject:o];
  [self updateSize];
  [self changed];
  return o;
}
- (EaselObject*)addImagePNG:(NSData*)png link:(NSString*)link {
  if (!png.length || !_directory) return nil;
  [[NSFileManager defaultManager] createDirectoryAtPath:_directory withIntermediateDirectories:YES attributes:nil error:nil];
  NSString* name = [NSUUID.UUID.UUIDString stringByAppendingString:@".png"];
  if (![png writeToFile:[_directory stringByAppendingPathComponent:name] atomically:YES]) return nil;
  NSImage* img = [[NSImage alloc] initWithData:png];
  NSSize s = img.size;
  if (s.width <= 0 || s.height <= 0) s = NSMakeSize(480, 300);
  CGFloat scale = MIN(1.0, 480.0 / s.width);  // Arc drops captures in at a readable card size
  EaselObject* o = [EaselObject new];
  o.kind = @"image";
  o.image = name;
  o.link = link;
  NSPoint p = [self nextFreePoint];
  o.frame = NSMakeRect(p.x, p.y, round(s.width * scale) + 8, round(s.height * scale) + 8);
  [_objects addObject:o];
  [self addViewFor:o];
  [self selectObject:o];
  [self updateSize];
  [self changed];
  return o;
}
- (void)selectObject:(EaselObject*)o {
  _selected = o;
  for (EaselItemView* v in _views) {
    v.selected = v.object == o;
    [v setNeedsDisplay:YES];
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
- (void)moveObject:(EaselObject*)o by:(NSSize)d {
  NSRect f = o.frame;
  f.origin.x = MAX(0, f.origin.x + d.width);
  f.origin.y = MAX(0, f.origin.y + d.height);
  o.frame = f;
  [self viewFor:o].frame = f;
}

// Mouse: click on empty canvas deselects; double-click adds a text box there (as in Arc).
- (void)mouseDown:(NSEvent*)e {
  [self.window makeFirstResponder:self];
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  if (e.clickCount == 2) {
    EaselObject* o = [self addText:@"" at:NSMakePoint(p.x, p.y - 22)];
    [self.window makeFirstResponder:[self viewFor:o].textField];
    return;
  }
  [self selectObject:nil];
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
  if ((c == NSDeleteCharacter || c == NSDeleteFunctionKey) && _selected) {
    [self deleteSelected];
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
@end
