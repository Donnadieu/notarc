#import "app/arc_alert.h"

#import <QuartzCore/QuartzCore.h>

@interface ArcAlert (Build)
- (void)buildForAppearance:(NSAppearance*)appearance;  // also used by the render harness
@end

// Arc 1.169 colour values (asset catalogue, RGBA 0-1): PopoverBackground, PopoverBorder, PopoverTitle, PopoverMessage,
// PrimaryButton*, DestructiveButton*, NeutralButton*. Numbers only; drawn by NotArc.
static NSColor* RGBA(double r, double g, double b, double a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }
static BOOL DarkAppearance(NSAppearance* a) {
  return [[a bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]]
      isEqualToString:NSAppearanceNameDarkAqua];
}

static const CGFloat kCardRadius = 16;
static const CGFloat kCardPadding = 24;
static const CGFloat kButtonHeight = 30;
static const CGFloat kButtonRadius = 8;

typedef NS_ENUM(NSInteger, ArcButtonStyle) { ArcButtonPrimary, ArcButtonDestructive, ArcButtonNeutral };

@interface ArcDialogButton : NSButton
@property(nonatomic) ArcButtonStyle arcStyle;
@property(nonatomic) BOOL hovered;
@end

@implementation ArcDialogButton
- (instancetype)initWithFrame:(NSRect)f {
  if ((self = [super initWithFrame:f])) {
    self.bordered = NO;
    self.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
  }
  return self;
}
- (void)updateTrackingAreas {
  for (NSTrackingArea* t in self.trackingAreas) [self removeTrackingArea:t];
  [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways |
                                                             NSTrackingInVisibleRect
                                                       owner:self
                                                    userInfo:nil]];
  [super updateTrackingAreas];
}
- (void)mouseEntered:(NSEvent*)e { self.hovered = YES; self.needsDisplay = YES; }
- (void)mouseExited:(NSEvent*)e { self.hovered = NO; self.needsDisplay = YES; }
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
- (NSColor*)faceColor {
  BOOL dark = DarkAppearance(self.effectiveAppearance), down = self.cell.isHighlighted;
  switch (self.arcStyle) {
    case ArcButtonPrimary:
      return down ? RGBA(0.16, 0.19, 0.83, 1) : self.hovered ? RGBA(0.173, 0.2, 0.886, 1) : RGBA(0.192, 0.224, 0.984, 1);
    case ArcButtonDestructive:
      return down ? RGBA(0.816, 0.184, 0.067, 1) : self.hovered ? RGBA(0.867, 0.192, 0.071, 1) : RGBA(0.961, 0.216, 0.078, 1);
    case ArcButtonNeutral:
      if (dark) return down ? RGBA(0.169, 0.165, 0.349, 1) : self.hovered ? RGBA(0.271, 0.267, 0.451, 1) : RGBA(0.188, 0.184, 0.388, 1);
      return down ? RGBA(0.898, 0.898, 0.898, 1) : self.hovered ? RGBA(0.949, 0.949, 0.949, 1) : RGBA(1, 1, 1, 1);
  }
}
- (NSColor*)textColor {
  if (self.arcStyle != ArcButtonNeutral) return NSColor.whiteColor;
  return DarkAppearance(self.effectiveAppearance) ? RGBA(1, 1, 1, 0.9) : RGBA(0.09, 0.09, 0.09, 1);
}
- (void)drawRect:(NSRect)dirty {
  BOOL dark = DarkAppearance(self.effectiveAppearance);
  NSRect r = NSInsetRect(self.bounds, 0.5, 1);
  r.origin.y += 0.5;
  // Arc's button shadow is a hard 1 pt edge under the face (light neutral, red destructive).
  NSColor* shadow = self.arcStyle == ArcButtonDestructive ? RGBA(0.706, 0.145, 0.039, 0.3)
                    : self.arcStyle == ArcButtonNeutral && !dark ? RGBA(0.886, 0.886, 0.886, 1)
                                                                  : nil;
  if (shadow) {
    [shadow setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSOffsetRect(r, 0, self.isFlipped ? 1 : -1) xRadius:kButtonRadius yRadius:kButtonRadius] fill];
  }
  NSBezierPath* face = [NSBezierPath bezierPathWithRoundedRect:r xRadius:kButtonRadius yRadius:kButtonRadius];
  [self.faceColor setFill];
  [face fill];
  NSColor* border = self.arcStyle == ArcButtonNeutral ? (dark ? RGBA(0.388, 0.384, 0.682, 1) : RGBA(0.859, 0.859, 0.859, 1))
                    : self.arcStyle == ArcButtonPrimary && dark ? RGBA(1, 1, 1, 0.2)
                                                                  : nil;
  if (border) {
    [border setStroke];
    NSBezierPath* edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 0.5, 0.5) xRadius:kButtonRadius - 0.5 yRadius:kButtonRadius - 0.5];
    edge.lineWidth = 1;
    [edge stroke];
  }
  NSDictionary* attrs = @{ NSFontAttributeName : self.font, NSForegroundColorAttributeName : self.textColor };
  NSSize ts = [self.title sizeWithAttributes:attrs];
  [self.title drawAtPoint:NSMakePoint(round(NSMidX(r) - ts.width / 2), round(NSMidY(r) - ts.height / 2)) withAttributes:attrs];
}
@end

// The dimmed window under the card: swallows clicks so the window behaves as with a sheet.
@interface ArcAlertScrim : NSView
@end
@implementation ArcAlertScrim
- (NSView*)hitTest:(NSPoint)p { return NSPointInRect([self convertPoint:p fromView:self.superview], self.bounds) ? self : nil; }
- (void)mouseDown:(NSEvent*)e {}
- (void)rightMouseDown:(NSEvent*)e {}
- (void)scrollWheel:(NSEvent*)e {}
- (BOOL)acceptsFirstMouse:(NSEvent*)e { return YES; }
@end

// The card: rounded, Arc's popover colours, a soft shadow inside the transparent panel.
@interface ArcAlertCardView : NSView
@property(nonatomic) NSRect cardRect;
@end
@implementation ArcAlertCardView
- (void)drawRect:(NSRect)dirty {
  BOOL dark = DarkAppearance(self.effectiveAppearance);
  NSBezierPath* card = [NSBezierPath bezierPathWithRoundedRect:self.cardRect xRadius:kCardRadius yRadius:kCardRadius];
  NSColor* fill = dark ? RGBA(0.082, 0.11, 0.188, 1) : RGBA(0.98, 0.984, 1, 1);
  [NSGraphicsContext saveGraphicsState];
  NSShadow* sh = [NSShadow new];
  sh.shadowColor = [NSColor colorWithWhite:0 alpha:dark ? 0.5 : 0.22];
  sh.shadowBlurRadius = 22;
  sh.shadowOffset = NSMakeSize(0, -8);
  [sh set];
  [fill setFill];
  [card fill];
  [NSGraphicsContext restoreGraphicsState];
  [(dark ? RGBA(0.827, 0.808, 0.929, 0.2) : RGBA(0, 0, 0, 0.08)) setStroke];
  NSBezierPath* edge = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.cardRect, 0.5, 0.5) xRadius:kCardRadius - 0.5 yRadius:kCardRadius - 0.5];
  edge.lineWidth = 1;
  [edge stroke];
}
- (void)viewDidChangeEffectiveAppearance { self.needsDisplay = YES; }
@end

@interface ArcAlertPanel : NSPanel
@end
@implementation ArcAlertPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }
- (void)cancelOperation:(id)sender {
  for (NSButton* b in [(id)self.delegate buttons])
    if ([b.keyEquivalent isEqualToString:@"\e"]) return [b performClick:nil];
}
@end

static NSMapTable<NSWindow*, ArcAlert*>* Shown() {
  static NSMapTable* t;
  if (!t) t = [NSMapTable weakToStrongObjectsMapTable];
  return t;
}
BOOL ArcAlertShownOn(NSWindow* window) { return window && [Shown() objectForKey:window] != nil; }
static NSMutableSet* Live() {  // shown cards stay alive until answered, as NSAlert does
  static NSMutableSet* s;
  if (!s) s = [NSMutableSet set];
  return s;
}

@interface ArcAlert () <NSWindowDelegate>
@end

@implementation ArcAlert {
  ArcAlertPanel* _panel;
  NSMutableArray<NSButton*>* _buttons;
  NSView* _card;
  ArcAlertScrim* _scrim;
  __weak NSWindow* _parent;
  void (^_handler)(NSModalResponse);
  BOOL _modal;
  BOOL _shown;
}

- (instancetype)init {
  if ((self = [super init])) {
    _buttons = [NSMutableArray array];
    _panel = [[ArcAlertPanel alloc] initWithContentRect:NSMakeRect(0, 0, 400, 160)
                                              styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                backing:NSBackingStoreBuffered
                                                  defer:YES];
    _panel.styleMask = NSWindowStyleMaskBorderless;  // a normal key window (text fields work), no title bar
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = NO;  // the card draws its own soft shadow around the rounded shape
    _panel.releasedWhenClosed = NO;
    _panel.hidesOnDeactivate = NO;
    _panel.delegate = self;
    _panel.animationBehavior = NSWindowAnimationBehaviorNone;
  }
  return self;
}

- (NSPanel*)window { return _panel; }
- (NSArray<NSButton*>*)buttons { return _buttons; }
- (BOOL)isShown { return _shown; }

- (NSButton*)addButtonWithTitle:(NSString*)title {
  ArcDialogButton* b = [[ArcDialogButton alloc] initWithFrame:NSZeroRect];
  b.title = title ?: @"";
  b.tag = NSAlertFirstButtonReturn + (NSInteger)_buttons.count;
  b.target = self;
  b.action = @selector(buttonPressed:);
  if (_buttons.count == 0) b.keyEquivalent = @"\r";
  else if ([title isEqualToString:@"Cancel"]) b.keyEquivalent = @"\e";
  else if ([title isEqualToString:@"Don't Save"]) {
    b.keyEquivalent = @"d";
    b.keyEquivalentModifierMask = NSEventModifierFlagCommand;
  }
  [_buttons addObject:b];
  return b;
}

static NSTextField* Label(NSString* s, NSFont* font, NSColor* color, CGFloat width) {
  NSTextField* f = [NSTextField wrappingLabelWithString:s];
  f.font = font;
  f.textColor = color;
  f.selectable = NO;
  f.preferredMaxLayoutWidth = width;
  NSSize fit = [f.cell cellSizeForBounds:NSMakeRect(0, 0, width, 10000)];
  f.frame = NSMakeRect(0, 0, width, ceil(fit.height));
  return f;
}

// Lays the card out bottom-up in the panel for the given appearance; returns the card size.
- (void)buildForAppearance:(NSAppearance*)appearance {
  BOOL dark = DarkAppearance(appearance);
  _panel.appearance = appearance;
  if (!_buttons.count) [self addButtonWithTitle:@"OK"];
  for (NSUInteger i = 0; i < _buttons.count; ++i) {
    ArcDialogButton* b = (ArcDialogButton*)_buttons[i];
    b.arcStyle = b.hasDestructiveAction ? ArcButtonDestructive : i == 0 ? ArcButtonPrimary : ArcButtonNeutral;
  }
  CGFloat buttonsWidth = 0;
  for (NSButton* b in _buttons) {
    CGFloat w = MAX(76, ceil([b.title sizeWithAttributes:@{ NSFontAttributeName : b.font }].width) + 32);
    b.frame = NSMakeRect(0, 0, w, kButtonHeight);
    buttonsWidth += w + 8;
  }
  CGFloat inner = MAX(MAX(292, buttonsWidth - 8), NSWidth(_accessoryView.frame));
  inner = MIN(inner, 472);
  NSColor* titleColor = dark ? RGBA(1, 1, 1, 1) : RGBA(0.094, 0.106, 0.122, 1);
  NSColor* messageColor = dark ? RGBA(0.933, 0.933, 0.965, 0.75) : RGBA(0.024, 0.055, 0.169, 0.75);
  NSTextField* title = Label(_messageText ?: @"", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], titleColor, inner);
  NSTextField* message = _informativeText.length
                             ? Label(_informativeText, [NSFont systemFontOfSize:13], messageColor, inner)
                             : nil;
  title.identifier = @"arcAlertTitle";
  message.identifier = @"arcAlertMessage";

  CGFloat y = kCardPadding;
  // Buttons: first (primary) at the right, the rest to its left, as in NSAlert and Arc.
  CGFloat x = kCardPadding + inner;
  for (NSButton* b in _buttons) {
    x -= NSWidth(b.frame);
    [b setFrameOrigin:NSMakePoint(x, y)];
    x -= 8;
  }
  y += kButtonHeight + 20;
  if (_accessoryView) {
    [_accessoryView setFrameOrigin:NSMakePoint(kCardPadding, y)];
    y += NSHeight(_accessoryView.frame) + 14;
  }
  if (message) {
    [message setFrameOrigin:NSMakePoint(kCardPadding, y)];
    y += NSHeight(message.frame) + 6;
  }
  [title setFrameOrigin:NSMakePoint(kCardPadding, y)];
  y += NSHeight(title.frame) + kCardPadding;

  const CGFloat shadowPad = 30;  // room for the card's shadow inside the transparent panel
  NSSize card = NSMakeSize(inner + 2 * kCardPadding, y);
  ArcAlertCardView* root = [[ArcAlertCardView alloc] initWithFrame:NSMakeRect(0, 0, card.width + 2 * shadowPad, card.height + 2 * shadowPad)];
  root.cardRect = NSMakeRect(shadowPad, shadowPad, card.width, card.height);
  _card = [[NSView alloc] initWithFrame:root.cardRect];
  _card.identifier = @"arcAlertCard";
  [root addSubview:_card];
  for (NSView* v in @[ title ]) [_card addSubview:v];
  if (message) [_card addSubview:message];
  if (_accessoryView) [_card addSubview:_accessoryView];
  for (NSButton* b in _buttons) [_card addSubview:b];
  [_panel setFrame:[_panel frameRectForContentRect:NSMakeRect(_panel.frame.origin.x, _panel.frame.origin.y, NSWidth(root.frame), NSHeight(root.frame))]
           display:NO];
  _panel.contentView = root;
}

- (void)presentOver:(NSWindow*)parent {
  NSAppearance* appearance = parent ? parent.effectiveAppearance : NSApp.effectiveAppearance;
  [self buildForAppearance:appearance];
  NSRect area = parent ? parent.frame : (NSScreen.mainScreen ?: NSScreen.screens.firstObject).visibleFrame;
  NSSize s = _panel.frame.size;
  // A little above the middle, where Arc's dialogs sit.
  [_panel setFrameOrigin:NSMakePoint(round(NSMidX(area) - s.width / 2), round(NSMinY(area) + NSHeight(area) * 0.56 - s.height / 2))];
  if (parent) {
    _parent = parent;
    _panel.alphaValue = parent.alphaValue;  // hidden self-test windows stay hidden
    _scrim = [[ArcAlertScrim alloc] initWithFrame:parent.contentView.bounds];
    _scrim.identifier = @"arcAlertScrim";
    _scrim.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrim.wantsLayer = YES;
    _scrim.layer.backgroundColor = [NSColor colorWithWhite:0 alpha:0.28].CGColor;
    _scrim.alphaValue = 0;
    [parent.contentView addSubview:_scrim positioned:NSWindowAbove relativeTo:nil];
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext* c) {
      c.duration = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion ? 0 : 0.15;
      self->_scrim.animator.alphaValue = 1;
    }];
    [parent addChildWindow:_panel ordered:NSWindowAbove];
    [Shown() setObject:self forKey:parent];
  }
  _shown = YES;
  [Live() addObject:self];
  [_panel makeKeyAndOrderFront:nil];
  if (_panel.initialFirstResponder) [_panel makeFirstResponder:_panel.initialFirstResponder];
}

- (void)beginSheetModalForWindow:(NSWindow*)window completionHandler:(void (^)(NSModalResponse))handler {
  _handler = [handler copy];
  _modal = NO;
  [self presentOver:window];
}

- (NSModalResponse)runModal {
  NSWindow* parent = NSApp.keyWindow ?: NSApp.mainWindow;
  if ([parent isKindOfClass:ArcAlertPanel.class]) parent = parent.parentWindow;
  _modal = YES;
  [self presentOver:parent.visible ? parent : nil];
  NSModalResponse r = [NSApp runModalForWindow:_panel];
  return r;
}

- (void)buttonPressed:(NSButton*)sender { [self dismissWithResponse:sender.tag]; }

- (void)dismissWithResponse:(NSModalResponse)response {
  if (!_shown) return;
  _shown = NO;
  NSWindow* parent = _parent;
  if (parent) {
    [parent removeChildWindow:_panel];
    if ([Shown() objectForKey:parent] == self) [Shown() removeObjectForKey:parent];
  }
  [_scrim removeFromSuperview];
  _scrim = nil;
  [_panel orderOut:nil];
  if (parent.visible) [parent makeKeyWindow];
  if (_modal) {
    _modal = NO;
    [NSApp stopModalWithCode:response];
    [Live() removeObject:self];
    return;
  }
  void (^h)(NSModalResponse) = _handler;
  _handler = nil;
  ArcAlert* keep = self;  // the handler may drop the last reference
  [Live() removeObject:self];
  if (h) h(response);
  (void)keep;
}

- (NSString*)lookDescription {
  BOOL primary = NO, destructive = NO, neutral = NO, returnKey = NO, escKey = NO;
  for (NSButton* b in _buttons) {
    ArcDialogButton* ab = (ArcDialogButton*)b;
    primary |= ab.arcStyle == ArcButtonPrimary;
    destructive |= ab.arcStyle == ArcButtonDestructive;
    neutral |= ab.arcStyle == ArcButtonNeutral;
    returnKey |= [b.keyEquivalent isEqualToString:@"\r"];
    escKey |= [b.keyEquivalent isEqualToString:@"\e"];
  }
  return [NSString stringWithFormat:@"card=%d child=%d scrim=%d radius=%.0f primary=%d destructive=%d neutral=%d returnKey=%d escKey=%d",
                                    _card != nil && !_panel.opaque, _panel.parentWindow != nil && _panel.parentWindow == _parent,
                                    _scrim.superview != nil, kCardRadius, primary, destructive, neutral, returnKey, escKey];
}
@end
