// Boost colour wheel: NotArc's own take on Arc's Boost colour picker. Hue runs around the ring, saturation grows
// from the centre (no colour) to the rim (full colour). A draggable puck shows the pick. Drawn in code, no images.
#pragma once

#import <Cocoa/Cocoa.h>

// Pure mapping for a point inside a wheel rect (both in the same coordinates, y up). Hue is the angle from the
// 3 o'clock direction, counter-clockwise, 0-360; saturation is the distance from the centre over the radius,
// clamped to 0-1. Returns NO (and leaves hue/sat untouched) when the rect is empty.
BOOL BoostWheelPick(NSPoint p, NSRect wheel, double* hue, double* saturation);
// The point inside `wheel` for a hue and saturation (inverse of BoostWheelPick).
NSPoint BoostWheelPoint(double hue, double saturation, NSRect wheel);

// A rounded tool tile for the Boost editor (font samples, text size, case, Zap, Code), filled with NotArc's Arc
// colours for light and dark; selected tiles use Arc's blue. Clicking sends the control's action.
@interface BoostTile : NSControl
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* subtitle;
@property(nonatomic, strong) NSFont* titleFont;
@property(nonatomic, copy) NSString* symbolName;  // SF Symbol shown instead of the title
@property(nonatomic) BOOL selected;
@property(nonatomic, copy) NSString* value;       // what the tile stands for (e.g. a font family)
@end

@interface BoostColorWheel : NSView
@property(nonatomic, readonly) double hue;         // 0-360
@property(nonatomic, readonly) double saturation;  // 0-1
@property(nonatomic) BOOL hasColor;                // NO: no tint picked; the puck rests dimmed in the centre
@property(nonatomic) double intensity;             // 0-1, only changes how strong the puck's colour looks
// Called on every pick; `final` is YES on mouse up (and for programmatic picks), so callers can save once.
@property(nonatomic, copy) void (^onChange)(BoostColorWheel* wheel, BOOL final);
- (void)setHue:(double)hue saturation:(double)saturation;  // no callback
- (NSRect)wheelRect;                                       // the disc, in view coordinates
- (NSPoint)pointForHue:(double)hue saturation:(double)saturation;
// Same as clicking at `p` (view coordinates): picks, sets hasColor, calls onChange(final = YES).
- (void)pickPoint:(NSPoint)p;
@end
