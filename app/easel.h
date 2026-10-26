// Easels: a free-form canvas of page captures, text and links shown in the page card (Arc: easel,
// easelCapture, easelImage, easelLink). Each easel is saved locally as Easels/<id>/easel.json plus PNGs.
#import <Cocoa/Cocoa.h>

@interface EaselObject : NSObject
@property(nonatomic, copy) NSString* kind;   // "text", "image"
@property(nonatomic) NSRect frame;           // canvas coordinates (flipped, top-left origin)
@property(nonatomic, copy) NSString* text;   // text objects
@property(nonatomic, copy) NSString* image;  // image file name inside the easel folder
@property(nonatomic, copy) NSString* link;   // source page of a capture (Arc: easelWebCardLink)
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
- (void)loadFromDirectory:(NSString*)dir;
- (BOOL)save;
- (EaselObject*)addText:(NSString*)text at:(NSPoint)p;
- (EaselObject*)addImagePNG:(NSData*)png link:(NSString*)link;
- (void)deleteSelected;
- (void)selectObject:(EaselObject*)o;
- (EaselObject*)selectedObject;
- (void)moveObject:(EaselObject*)o by:(NSSize)d;  // tests / dragging
- (void)updateSize;
@end
