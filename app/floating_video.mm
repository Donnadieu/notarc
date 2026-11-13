// Arc's floating video (V75-V77). See floating_video.h.
#import "app/floating_video.h"

const CGFloat kFloatingVideoWidth = 222;
const CGFloat kFloatingVideoRadius = 6;
const NSPoint kFloatingVideoOffset = {20, 98};
const CGFloat kFloatingVideoMinWidth = 200;
const CGFloat kFloatingVideoMaxWidth = 640;

// Measured from Omar's Arc 1.169 screenshot of the hovered float (1x): 28 pt rounded-square buttons 10 pt in from
// the corners, the site centred between them, a 36 pt pause/play in the middle and a 4 pt bar 10 pt above the bottom.
static const CGFloat kButton = 28, kInset = 10, kBarHeight = 4;
// Chromium 156 always draws the site's icon and name at the top-left of its PiP window; Arc's float shows only the
// video. Chromium's window is made this much taller above and below, so it letterboxes the video into the middle with
// the name in the top bar, and only the middle (the video) is let through.
static const CGFloat kHiddenBar = 34;

NSWindow* FindPictureInPictureWindow(NSArray<NSWindow*>* windows, NSSet<NSWindow*>* before) {
  for (NSWindow* w in windows) {
    if ([before containsObject:w] || !w.isVisible) continue;
    // Chromium's views window: floating the first time; shown again for the next video at its parent's level.
    NSString* cls = NSStringFromClass(w.class);
    if ([cls hasPrefix:@"NativeWidgetMacFrameless"] || ([cls hasPrefix:@"NativeWidgetMac"] && w.level >= NSFloatingWindowLevel))
      return w;
  }
  return nil;
}

// A button that works on the first click although the controls window never becomes key.
@interface FloatButton : NSButton
@end
@implementation FloatButton
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
@end

// Arc's progress bar: a white capsule over a dimmer track; click or drag to seek.
@interface FloatProgressView : NSView
@property(nonatomic) double fraction;
@property(nonatomic, copy) void (^seek)(double fraction);
@end
@implementation FloatProgressView
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (void)drawRect:(NSRect)dirty {
  NSRect b = self.bounds;
  CGFloat r = NSHeight(b) / 2;
  [[NSColor colorWithWhite:1 alpha:0.35] setFill];
  [[NSBezierPath bezierPathWithRoundedRect:b xRadius:r yRadius:r] fill];
  NSRect f = b;
  f.size.width = MAX(NSHeight(b), round(NSWidth(b) * MIN(1, MAX(0, self.fraction))));
  [NSColor.whiteColor setFill];
  [[NSBezierPath bezierPathWithRoundedRect:f xRadius:r yRadius:r] fill];
}
- (void)seekTo:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  double f = MIN(1, MAX(0, p.x / MAX(1, NSWidth(self.bounds))));
  self.fraction = f;
  self.needsDisplay = YES;
  if (self.seek) self.seek(f);
}
- (void)mouseDown:(NSEvent*)e { [self seekTo:e]; }
- (void)mouseDragged:(NSEvent*)e { [self seekTo:e]; }
@end

// Covers the video: hover shows the controls; dragging an edge or corner resizes the float (Arc), dragging anywhere
// else moves it.
enum FloatEdges { kEdgeLeft = 1, kEdgeRight = 2, kEdgeBottom = 4, kEdgeTop = 8 };
static const CGFloat kResizeBand = 8;  // how far in from the edge a press resizes
@interface FloatControlsView : NSView
@property(nonatomic, weak) FloatingVideo* owner;
@property(nonatomic) NSPoint dragStart;
@property(nonatomic) NSPoint originAtDragStart;
@property(nonatomic) NSRect frameAtDragStart;
@property(nonatomic) int edges;  // what the press is resizing (0: it moves the float)
- (int)edgesAtPoint:(NSPoint)p;
- (NSCursor*)cursorAtPoint:(NSPoint)p;
@end

@interface FloatingVideo ()
@property(nonatomic) BOOL dragged;
- (void)controlsViewMoved:(NSPoint)delta;
- (void)resizeFrom:(NSRect)start edges:(int)edges dx:(CGFloat)dx dy:(CGFloat)dy;
- (void)resizeEnded;
@end

// Where the pointer is on screen for this event (also for events made by tests, which don't move the real pointer).
static NSPoint ScreenPoint(NSEvent* e) {
  return e.window ? [e.window convertPointToScreen:e.locationInWindow] : [NSEvent mouseLocation];
}

@implementation FloatControlsView
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }
- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                                                             NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
}
- (void)mouseEntered:(NSEvent*)e { self.owner.hovered = YES; }
- (void)mouseExited:(NSEvent*)e { self.owner.hovered = NO; }
- (int)edgesAtPoint:(NSPoint)p {
  NSRect b = self.bounds;
  int edges = 0;
  if (p.x < kResizeBand) edges |= kEdgeLeft;
  else if (p.x > NSWidth(b) - kResizeBand) edges |= kEdgeRight;
  if (p.y < kResizeBand) edges |= kEdgeBottom;
  else if (p.y > NSHeight(b) - kResizeBand) edges |= kEdgeTop;
  return NSPointInRect(p, b) ? edges : 0;
}
- (NSCursor*)cursorAtPoint:(NSPoint)p {
  int e = [self edgesAtPoint:p];
  if (!e) return nil;
  BOOL h = e & (kEdgeLeft | kEdgeRight), v = e & (kEdgeTop | kEdgeBottom);
  if (h && v) {
    if (@available(macOS 15.0, *)) {
      NSCursorFrameResizePosition pos = (NSCursorFrameResizePosition)((e & kEdgeTop ? NSCursorFrameResizePositionTop : NSCursorFrameResizePositionBottom) |
                                        (e & kEdgeLeft ? NSCursorFrameResizePositionLeft : NSCursorFrameResizePositionRight));
      return [NSCursor frameResizeCursorFromPosition:pos inDirections:NSCursorFrameResizeDirectionsAll];
    }
    return NSCursor.crosshairCursor;
  }
  return h ? NSCursor.resizeLeftRightCursor : NSCursor.resizeUpDownCursor;
}
- (void)resetCursorRects {
  NSRect b = self.bounds;
  CGFloat W = NSWidth(b), H = NSHeight(b), k = kResizeBand;
  NSRect rects[] = {NSMakeRect(0, 0, k, k), NSMakeRect(W - k, 0, k, k), NSMakeRect(0, H - k, k, k), NSMakeRect(W - k, H - k, k, k),
                    NSMakeRect(k, 0, W - 2 * k, k), NSMakeRect(k, H - k, W - 2 * k, k), NSMakeRect(0, k, k, H - 2 * k),
                    NSMakeRect(W - k, k, k, H - 2 * k)};
  for (NSRect r : rects) {
    NSCursor* c = [self cursorAtPoint:NSMakePoint(NSMidX(r), NSMidY(r))];
    if (c) [self addCursorRect:r cursor:c];
  }
}
- (void)mouseDown:(NSEvent*)e {
  self.dragStart = ScreenPoint(e);
  self.edges = [self edgesAtPoint:[self convertPoint:e.locationInWindow fromView:nil]];
  self.frameAtDragStart = self.owner.visibleFrame;
  // Where the video shows (Chromium's window is taller): starting from Chromium's origin made it jump on every drag.
  self.originAtDragStart = self.owner.visibleFrame.origin;
}
- (void)mouseDragged:(NSEvent*)e {
  NSPoint now = ScreenPoint(e);
  CGFloat dx = now.x - self.dragStart.x, dy = now.y - self.dragStart.y;
  if (self.edges) [self.owner resizeFrom:self.frameAtDragStart edges:self.edges dx:dx dy:dy];
  else [self.owner controlsViewMoved:NSMakePoint(self.originAtDragStart.x + dx, self.originAtDragStart.y + dy)];
}
- (void)mouseUp:(NSEvent*)e {
  if (!self.edges) return;
  [self mouseDragged:e];
  self.edges = 0;
  [self.owner resizeEnded];
}
@end

@implementation FloatingVideo {
  NSWindow* _video;
  NSPanel* _controls;
  FloatControlsView* _view;
  NSView* _chrome;  // everything that shows on hover
  FloatButton *_back, *_minimize, *_close, *_play;
  NSTextField* _siteLabel;
  FloatProgressView* _bar;
  CGFloat _aspect;  // height / width of the video, from Chromium's first frame
  BOOL _applying;
  NSRect _visibleFrame;  // where the video shows (Chromium's window is taller, see kHiddenBar)
  id _resizeObserver;
}

- (instancetype)initWithVideoWindow:(NSWindow*)window {
  if (!(self = [super init])) return nil;
  _video = window;
  _width = kFloatingVideoWidth;
  _aspect = NSWidth(window.frame) > 0 ? NSHeight(window.frame) / NSWidth(window.frame) : 9.0 / 16;
  // Only the video shows, with Arc's corners (a rounded mask on Chromium's content); NotArc's controls take the pointer.
  window.opaque = NO;
  window.backgroundColor = NSColor.clearColor;
  window.contentView.wantsLayer = YES;
  window.hasShadow = YES;
  window.ignoresMouseEvents = YES;

  _visibleFrame = window.frame;
  _controls = [[NSPanel alloc] initWithContentRect:window.frame
                                         styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
  _controls.opaque = NO;
  _controls.backgroundColor = NSColor.clearColor;
  _controls.hasShadow = NO;
  _controls.level = window.level;
  _controls.releasedWhenClosed = NO;
  _controls.acceptsMouseMovedEvents = YES;
  _controls.becomesKeyOnlyIfNeeded = YES;
  _controls.collectionBehavior = window.collectionBehavior;

  _view = [[FloatControlsView alloc] initWithFrame:NSMakeRect(0, 0, NSWidth(window.frame), NSHeight(window.frame))];
  _view.owner = self;
  _view.wantsLayer = YES;
  _view.layer.cornerRadius = kFloatingVideoRadius;
  _view.layer.masksToBounds = YES;
  _view.layer.borderWidth = 1;  // Arc's dark hairline around the video
  _view.layer.borderColor = [NSColor colorWithWhite:0 alpha:0.5].CGColor;
  _view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _controls.contentView = _view;

  _chrome = [[NSView alloc] initWithFrame:_view.bounds];
  _chrome.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _chrome.wantsLayer = YES;
  _chrome.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.3].CGColor;  // the video dims under the controls
  _chrome.alphaValue = 0;
  [_view addSubview:_chrome];

  __weak FloatingVideo* weakSelf = self;
  auto button = ^FloatButton*(NSString* symbol, NSString* tip, CGFloat size, BOOL tile) {
    FloatButton* b = [FloatButton buttonWithImage:[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip]
                                           target:nil action:nil];
    b.bordered = NO;
    b.imagePosition = NSImageOnly;
    b.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:size weight:NSFontWeightSemibold];
    b.contentTintColor = NSColor.whiteColor;
    b.toolTip = tip;
    b.wantsLayer = YES;
    if (tile) {
      b.layer.backgroundColor = [NSColor colorWithWhite:1 alpha:0.18].CGColor;
      b.layer.cornerRadius = 6;
    }
    [self->_chrome addSubview:b];
    return b;
  };
  _siteLabel = [NSTextField labelWithString:@""];  // under the buttons
  [_chrome addSubview:_siteLabel];
  _back = button(@"arrow.up.left", @"Back to Tab", 12, YES);
  _minimize = button(@"arrow.down.right.and.arrow.up.left", @"Minimize", 11, YES);
  _close = button(@"xmark", @"Close", 12, YES);
  _play = button(@"pause.fill", @"Pause", 34, NO);
  for (FloatButton* b in @[ _back, _minimize, _close, _play ]) {
    b.target = self;
    b.action = @selector(buttonClicked:);
  }
  _siteLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  _siteLabel.textColor = NSColor.whiteColor;
  _siteLabel.alignment = NSTextAlignmentCenter;
  _siteLabel.lineBreakMode = NSLineBreakByTruncatingTail;
  NSShadow* shadow = [NSShadow new];
  shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.5];
  shadow.shadowBlurRadius = 3;
  _siteLabel.shadow = shadow;
  _bar = [[FloatProgressView alloc] initWithFrame:NSZeroRect];
  _bar.seek = ^(double f) {
    FloatingVideo* s = weakSelf;
    if (s.onAction) s.onAction(@"seek", f);
  };
  [_chrome addSubview:_bar];
  _progress = -1;
  [self layoutControls];

  _resizeObserver = [NSNotificationCenter.defaultCenter
      addObserverForName:NSWindowDidResizeNotification
                  object:window
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification*) {
                FloatingVideo* s = weakSelf;
                if (!s || s->_applying) return;
                // Chromium resized its window (the video's own size changed): keep Arc's width at the new shape.
                NSRect f = s->_video.frame;  // Chromium sizes its window to the video's shape
                if (NSWidth(f) > 0) s->_aspect = NSHeight(f) / NSWidth(f);
                if (s->_video.parentWindow) [s placeOver:s->_video.parentWindow];
              }];
  return self;
}

- (NSWindow*)videoWindow { return _video; }
- (NSWindow*)controlsWindow { return _controls; }

- (void)layoutControls {
  NSRect b = _view.bounds;
  CGFloat W = NSWidth(b), H = NSHeight(b);
  _back.frame = NSMakeRect(kInset, H - kInset - kButton, kButton, kButton);
  _close.frame = NSMakeRect(W - kInset - kButton, H - kInset - kButton, kButton, kButton);
  _minimize.frame = NSMakeRect(NSMinX(_close.frame) - 6 - kButton, NSMinY(_close.frame), kButton, kButton);
  CGFloat labelX = NSMaxX(_back.frame) + 4;  // centred on the float; Arc lets it run under the minimize tile
  _siteLabel.frame = NSMakeRect(labelX, NSMidY(_back.frame) - 9, NSMinX(_close.frame) - 4 - labelX, 18);
  _play.frame = NSMakeRect(round((W - 48) / 2), round((H - 48) / 2), 48, 48);
  _bar.frame = NSMakeRect(kInset, kInset, W - 2 * kInset, kBarHeight);
}

- (void)placeOver:(NSWindow*)parent {
  if (!parent || !_video) return;
  _applying = YES;
  NSPoint origin = self.dragged ? _visibleFrame.origin
                                : NSMakePoint(NSMinX(parent.frame) + kFloatingVideoOffset.x, NSMinY(parent.frame) + kFloatingVideoOffset.y);
  CGFloat w = [self clampedWidth:_width onScreen:parent.screen];
  [self showAt:[self keptOnScreen:NSMakeRect(origin.x, origin.y, w, round(w * _aspect)) screen:parent.screen]];
  if (_video.parentWindow != parent) [parent addChildWindow:_video ordered:NSWindowAbove];
  [self syncControls];
  _applying = NO;
}

// Arc's limits, and never bigger than the screen.
- (CGFloat)clampedWidth:(CGFloat)w onScreen:(NSScreen*)screen {
  CGFloat maxW = kFloatingVideoMaxWidth;
  if (screen) maxW = MIN(maxW, MIN(NSWidth(screen.visibleFrame), NSHeight(screen.visibleFrame) / MAX(0.1, _aspect)));
  return round(MIN(MAX(kFloatingVideoMinWidth, maxW), MAX(kFloatingVideoMinWidth, w)));
}
- (NSRect)keptOnScreen:(NSRect)r screen:(NSScreen*)screen {
  if (!screen) return r;
  NSRect vis = screen.visibleFrame;
  r.origin.x = MIN(MAX(NSMinX(r), NSMinX(vis)), NSMaxX(vis) - NSWidth(r));
  r.origin.y = MIN(MAX(NSMinY(r), NSMinY(vis)), NSMaxY(vis) - NSHeight(r));
  return r;
}
- (void)showAt:(NSRect)visible {
  _visibleFrame = visible;
  _width = NSWidth(visible);
  NSRect target = NSInsetRect(_visibleFrame, 0, -kHiddenBar);
  if (!NSEqualRects(target, _video.frame)) [_video setFrame:target display:YES];
  [self maskVideo];
}

// Arc's float resize: the size follows the pointer, keeping the video's shape and the corner (or edge) across from
// the one being dragged, within Arc's limits and the screen.
- (void)resizeFrom:(NSRect)start edges:(int)edges dx:(CGFloat)dx dy:(CGFloat)dy {
  CGFloat w = NSWidth(start);
  CGFloat byX = edges & kEdgeRight ? NSWidth(start) + dx : edges & kEdgeLeft ? NSWidth(start) - dx : 0;
  CGFloat byY = edges & kEdgeTop ? (NSHeight(start) + dy) / _aspect : edges & kEdgeBottom ? (NSHeight(start) - dy) / _aspect : 0;
  if (byX && byY) w = fabs(byX - NSWidth(start)) >= fabs(byY - NSWidth(start)) ? byX : byY;
  else w = byX ?: byY ?: w;
  NSScreen* screen = _video.parentWindow ? _video.parentWindow.screen : _video.screen;
  w = [self clampedWidth:w onScreen:screen];
  CGFloat h = round(w * _aspect);
  NSRect r = NSMakeRect(edges & kEdgeLeft ? NSMaxX(start) - w : NSMinX(start), edges & kEdgeBottom ? NSMaxY(start) - h : NSMinY(start), w, h);
  r = [self keptOnScreen:r screen:screen];
  if (!NSEqualPoints(r.origin, start.origin)) self.dragged = YES;  // it no longer sits at Arc's spot
  _applying = YES;
  [self showAt:r];
  [self syncControls];
  _applying = NO;
}
- (void)resizeEnded {
  if (self.onResized) self.onResized(_width);
}
- (BOOL)showsResizeCursors {  // tests: the corners and edges have resize cursors, the middle none
  NSRect b = _view.bounds;
  return [_view cursorAtPoint:NSMakePoint(NSMaxX(b) - 2, NSMaxY(b) - 2)] != nil &&
         [_view cursorAtPoint:NSMakePoint(1, NSMidY(b))] == NSCursor.resizeLeftRightCursor &&
         [_view cursorAtPoint:NSMakePoint(NSMidX(b), NSMidY(b))] == nil;
}

- (void)maskVideo {
  CALayer* layer = _video.contentView.layer;
  if (!layer) return;
  NSRect b = _video.contentView.bounds;
  NSRect shown = NSMakeRect(0, kHiddenBar, NSWidth(b), MAX(0, NSHeight(b) - 2 * kHiddenBar));
  CAShapeLayer* mask = [layer.mask isKindOfClass:CAShapeLayer.class] ? (CAShapeLayer*)layer.mask : [CAShapeLayer layer];
  mask.frame = NSRectToCGRect(b);
  CGPathRef path = CGPathCreateWithRoundedRect(NSRectToCGRect(shown), kFloatingVideoRadius, kFloatingVideoRadius, NULL);
  mask.path = path;
  CGPathRelease(path);
  layer.mask = mask;
  [_video invalidateShadow];
}

- (CGFloat)cornerRadius {
  CAShapeLayer* mask = (CAShapeLayer*)_video.contentView.layer.mask;
  if (![mask isKindOfClass:CAShapeLayer.class] || !mask.path) return 0;
  return kFloatingVideoRadius;  // the mask is a rounded rect of that radius
}

- (BOOL)hidesChromiumBar {
  NSRect f = _video.frame;
  return NSMaxY(f) - NSMaxY(_visibleFrame) >= kHiddenBar - 0.5 && NSMinY(_visibleFrame) - NSMinY(f) >= kHiddenBar - 0.5 &&
         [_video.contentView.layer.mask isKindOfClass:CAShapeLayer.class];
}

- (void)syncControls {
  if (!NSEqualRects(_controls.frame, _visibleFrame)) [_controls setFrame:_visibleFrame display:YES];
  if (_controls.parentWindow != _video) [_video addChildWindow:_controls ordered:NSWindowAbove];
  [self layoutControls];
  [_controls invalidateCursorRectsForView:_view];
}

- (void)controlsViewMoved:(NSPoint)origin {
  self.dragged = YES;  // Arc keeps a float where you put it
  _applying = YES;
  _visibleFrame.origin = origin;
  [_video setFrameOrigin:NSMakePoint(origin.x, origin.y - kHiddenBar)];  // the controls window follows (a child)
  _applying = NO;
}

- (void)setSite:(NSString*)site {
  _site = [site copy];
  _siteLabel.stringValue = site ?: @"";
}

- (void)setPlaying:(BOOL)playing {
  _playing = playing;
  _play.image = [NSImage imageWithSystemSymbolName:playing ? @"pause.fill" : @"play.fill"
                          accessibilityDescription:playing ? @"Pause" : @"Play"];
  _play.toolTip = playing ? @"Pause" : @"Play";
}

- (void)setProgress:(double)progress {
  _progress = progress;
  _bar.hidden = progress < 0;
  _bar.fraction = MAX(0, progress);
  _bar.needsDisplay = YES;
}

- (void)setHovered:(BOOL)hovered {
  _hovered = hovered;
  _chrome.alphaValue = hovered ? 1 : 0;
}

- (void)buttonClicked:(NSButton*)sender {
  NSString* name = sender == _back ? @"back" : sender == _minimize ? @"minimize" : sender == _close ? @"close" : @"playpause";
  [self press:name];
}

- (void)press:(NSString*)name {
  if ([name isEqualToString:@"playpause"]) self.playing = !self.playing;  // shows at once; the page confirms later
  void (^action)(NSString*, double) = self.onAction;
  // After the click returns: closing the float releases this object and its buttons.
  if (action) dispatch_async(dispatch_get_main_queue(), ^{ action(name, 0); });
}

- (NSString*)stateDescription {
  BOOL on = _hovered && _chrome.alphaValue > 0.5;
  auto shown = [&](NSView* v) { return (int)(on && !v.hidden && NSContainsRect(_view.bounds, v.frame)); };
  NSView* cv = _controls.contentView;
  NSPoint centre = [cv convertPoint:NSMakePoint(NSMidX(cv.bounds), NSMidY(cv.bounds) + 30) toView:cv.superview];
  BOOL hit = _controls.parentWindow == _video && NSEqualRects(_controls.frame, _visibleFrame) && _video.ignoresMouseEvents &&
             [cv hitTest:centre] != nil;
  // Every control inside the video and none on top of another (the site name may run under minimize, as in Arc).
  NSArray<NSView*>* parts = @[ _back, _minimize, _close, _play, _bar ];
  BOOL fits = NSWidth(_siteLabel.frame) > 20;
  for (NSUInteger i = 0; i < parts.count; ++i) {
    fits &= NSContainsRect(_view.bounds, parts[i].frame);
    for (NSUInteger j = i + 1; j < parts.count; ++j) fits &= !NSIntersectsRect(parts[i].frame, parts[j].frame);
  }
  return [NSString stringWithFormat:@"hover=%d back=%d site=%@ play=%d minimize=%d close=%d progress=%d hit=%d resizeCursor=%d "
                                    @"fits=%d", on, shown(_back), on ? _siteLabel.stringValue : @"", shown(_play),
                                    shown(_minimize), shown(_close), shown(_bar) && _bar.fraction > 0, hit,
                                    [self showsResizeCursors], fits];
}

- (void)close {
  if (_resizeObserver) [NSNotificationCenter.defaultCenter removeObserver:_resizeObserver];
  _resizeObserver = nil;
  [_video removeChildWindow:_controls];
  [_controls orderOut:nil];
  [_controls close];
  if (_video.parentWindow) [_video.parentWindow removeChildWindow:_video];
  _video = nil;
}

- (void)dealloc {
  if (_resizeObserver) [NSNotificationCenter.defaultCenter removeObserver:_resizeObserver];
}
@end
