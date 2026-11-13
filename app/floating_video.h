// Arc's floating video (visual parity V75-V77). When you leave a tab whose video is playing, Chromium opens its own
// picture-in-picture window; NotArc makes it Arc's size (222 pt wide, 6 pt corners), parks it over the sidebar's
// bottom-left, and covers it with Arc's hover controls in a see-through window of its own (so the pointer reaches
// NotArc's controls, never Chromium's): back to the tab, the site, play/pause, minimize, close and a progress bar.
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>

extern const CGFloat kFloatingVideoWidth;   // 222 pt (Omar's Arc screenshot, 1x)
extern const CGFloat kFloatingVideoRadius;  // 6 pt
extern const NSPoint kFloatingVideoOffset;  // from the window's bottom-left corner: (20, 98)
extern const CGFloat kFloatingVideoMinWidth;  // resizing by its edges and corners stays within these
extern const CGFloat kFloatingVideoMaxWidth;

// Chromium's picture-in-picture window among `windows` that isn't in `before` (nil if it hasn't appeared yet).
NSWindow* FindPictureInPictureWindow(NSArray<NSWindow*>* windows, NSSet<NSWindow*>* before);

@interface FloatingVideo : NSObject
- (instancetype)initWithVideoWindow:(NSWindow*)window;
@property(nonatomic, readonly) NSWindow* videoWindow;     // Chromium's
@property(nonatomic, readonly) NSWindow* controlsWindow;  // NotArc's, a child of the video window
@property(nonatomic, copy) NSString* site;
@property(nonatomic) BOOL playing;
@property(nonatomic) double progress;  // 0-1; negative hides the bar (live streams, unknown length)
// "back", "playpause", "minimize", "close", or "seek" with the fraction as value.
@property(nonatomic, copy) void (^onAction)(NSString* action, double value);
- (void)placeOver:(NSWindow*)parent;  // Arc's size and spot (keeps a spot the user dragged it to)
@property(nonatomic) CGFloat width;  // what shows of the video, in points (the user resizes it by its edges)
@property(nonatomic, copy) void (^onResized)(CGFloat width);  // a resize by the pointer ended
@property(nonatomic, readonly) NSRect visibleFrame;   // the video on screen (Chromium's window is taller)
@property(nonatomic, readonly) CGFloat cornerRadius;  // tests
@property(nonatomic, readonly) BOOL hidesChromiumBar;  // tests: Chromium's own site name is outside what shows
@property(nonatomic) BOOL hovered;
- (NSString*)stateDescription;  // tests: "... resizeCursor=1 fits=1" (every control inside the video, none overlapping)
- (void)press:(NSString*)name;  // tests: as if that control was clicked
- (void)close;                  // drops the controls; Chromium closes its own window when the page leaves PiP
@end
