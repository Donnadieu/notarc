// Easels: a free-form canvas of page captures, live web clips, text and drawings shown in the page card (Arc: easel,
// easelCapture, easelImage, easelLink, easelArrow, easelRectangle, easelCircle, easelFreehand). Each easel is saved
// locally as Easels/<id>/easel.json plus PNGs.
#import <Cocoa/Cocoa.h>

@interface EaselObject : NSObject
// "text", "image", "clip" (live web clip), "arrow", "rect", "ellipse", "pen"
@property(nonatomic, copy) NSString* kind;
@property(nonatomic) NSRect frame;           // canvas coordinates (flipped, top-left origin)
@property(nonatomic, copy) NSString* text;   // text objects
@property(nonatomic, copy) NSString* image;  // image file name inside the easel folder (images and clips)
@property(nonatomic, copy) NSString* link;   // source page of a capture or clip (Arc: easelWebCardLink)
@property(nonatomic, copy) NSString* color;  // "#RRGGBB" for drawings and text; nil = default
// Arrow (2) and pen (N) points, each 0..1 across the drawing's inner box, so resizing scales the drawing.
@property(nonatomic, copy) NSArray<NSValue*>* points;
// Live clips: the dragged region (page points, top-left origin, relative to the visible page), the size the page had,
// where it was scrolled to (CSS px) and when the picture was last refreshed.
@property(nonatomic) NSRect region;
@property(nonatomic) NSSize viewport;
@property(nonatomic) NSPoint scroll;
@property(nonatomic, strong) NSDate* refreshedAt;
- (BOOL)isDrawing;
- (BOOL)isPicture;  // image or clip
@end

@class EaselView;
@protocol EaselViewDelegate <NSObject>
- (void)easelDidChange:(EaselView*)easel;
- (void)easel:(EaselView*)easel openLink:(NSString*)url;
@end

@interface EaselView : NSView <NSTextFieldDelegate>
@property(nonatomic, weak) id<EaselViewDelegate> delegate;
@property(nonatomic, copy, readonly) NSString* directory;
@property(nonatomic, readonly) NSMutableArray<EaselObject*>* objects;
@property(nonatomic, copy) NSString* title;
// Tool: "select", "text", "arrow", "rect", "ellipse", "pen". Drawing tools stay on until Esc or another tool.
@property(nonatomic, copy) NSString* tool;
// Colour for new drawings and text; choosing one also recolours the selected object.
@property(nonatomic, copy) NSString* color;
@property(nonatomic, readonly) NSView* toolbar;  // tools and colours, placed over the canvas by the window
+ (NSArray<NSString*>*)palette;
+ (NSColor*)colorFromHex:(NSString*)hex;
- (void)loadFromDirectory:(NSString*)dir;
- (BOOL)save;
- (EaselObject*)addText:(NSString*)text at:(NSPoint)p;
- (EaselObject*)addImagePNG:(NSData*)png link:(NSString*)link;
- (EaselObject*)addClipPNG:(NSData*)png link:(NSString*)link region:(NSRect)region viewport:(NSSize)viewport
                    scroll:(NSPoint)scroll;
- (BOOL)replaceImageOf:(EaselObject*)o png:(NSData*)png;  // a refreshed clip picture
- (NSArray<EaselObject*>*)liveClips;
// Drawings from canvas points: arrow = start, end; rect/ellipse = two corners; pen = the stroke.
- (EaselObject*)addDrawing:(NSString*)kind points:(NSArray<NSValue*>*)canvasPoints;
- (void)deleteSelected;
- (void)selectObject:(EaselObject*)o;
- (EaselObject*)selectedObject;
- (void)moveObject:(EaselObject*)o by:(NSSize)d;  // tests / dragging
- (void)resizeObject:(EaselObject*)o corner:(int)corner to:(NSPoint)p;  // corner 0 TL, 1 TR, 2 BL, 3 BR
- (void)updateSize;
// Tests: a real mouse drag (down, drags, up) dispatched to whatever view is under `from`, as AppKit would.
- (void)testDragFrom:(NSPoint)from to:(NSPoint)to steps:(int)steps;
- (NSView*)viewForObject:(EaselObject*)o;
@end
