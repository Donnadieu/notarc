// Arc's Space theme picker (visual parity V52), drawn by NotArc: a popover with light / dark / automatic at the top,
// a dotted colour pad with up to three draggable colour dots (one dot = a colour, two or three = a gradient), + and -
// to add or remove a dot (no dots = the default theme), a wave slider for intensity, a dial for grain, and pages of
// preset swatches (gradients, brand, pastel, muted, greys). Every change applies at once, as in Arc.
#import <Cocoa/Cocoa.h>

@interface ThemePickerController : NSViewController
- (instancetype)initWithColors:(NSArray<NSString*>*)colors
                     intensity:(double)intensity
                         grain:(double)grain
                        scheme:(NSString*)scheme;  // "auto", "light" or "dark"
// colors: 0-3 "#RRGGBB" in dot order; empty = the default theme.
@property(nonatomic, copy) void (^themeChanged)(NSArray<NSString*>* colors, double intensity, double grain);
@property(nonatomic, copy) void (^schemeChanged)(NSString* scheme);
@property(nonatomic, readonly) NSArray<NSString*>* colors;
@property(nonatomic, readonly) double intensity;
@property(nonatomic, readonly) double grain;
@property(nonatomic, readonly) NSString* scheme;
// Tests drive the same paths as the controls.
- (void)addDot;
- (void)removeDot;
- (void)moveDot:(NSUInteger)index toUnitPoint:(NSPoint)p;  // (0,0) bottom-left of the pad, (1,1) top-right
- (void)pickPreset:(NSUInteger)index onPage:(NSUInteger)page;
- (void)chooseScheme:(NSString*)scheme;
- (void)setIntensityValue:(double)v;
- (void)setGrainValue:(double)v;
- (NSUInteger)presetPageCount;
- (NSString*)lookDescription;  // "pad=1 dots=N modes=3 wave=1 dial=1 swatches=9 pages=5 plusMinus=1"
@end

// The pad's colour at a unit point: across = hue, up = lighter and softer, down = deeper.
NSColor* ThemePadColor(NSPoint unit);
NSPoint ThemePadPointForColor(NSColor* color);
