// NotArc's first-launch welcome (visual parity V56) and its import screen (V57), drawn by NotArc in Arc's manner:
// a full-window welcome with a soft blue and pink glow, four short steps (pinning, Spaces, split view, the command
// bar), then "bring your browser with you": a grid of browser cards, a progress step and a done step.
// Pure AppKit; the window controller does the real importing through the blocks.
#import <Cocoa/Cocoa.h>

@interface WelcomeView : NSView
// Browser cards: @{ @"name": @"Arc", @"kind": @"arc" | @"chromium" | @"safari", @"id": <anything> }.
@property(nonatomic, copy) NSArray<NSDictionary*>* browsers;
// Called when the person picks a browser and presses Import; call done(summary, ok) when finished.
@property(nonatomic, copy) void (^importChosen)(NSDictionary* browser, void (^done)(NSString* summary, BOOL ok));
// The last button: makeDefault = the "Make NotArc my default browser" switch.
@property(nonatomic, copy) void (^finished)(BOOL makeDefault);
// "welcome", "pin", "spaces", "split", "commandbar", "import", "progress", "done".
@property(nonatomic, readonly) NSString* page;
- (void)showPage:(NSString*)page;
- (void)next;  // the page's main button
- (void)back;
- (void)chooseBrowserAtIndex:(NSUInteger)index;  // tests: as clicking a card
- (void)skipImport;                              // "Start Fresh"
- (NSString*)lookDescription;  // "glow=1 title=<text> primary=<button> cards=N picture=0|1"
+ (NSArray<NSString*>*)pageOrder;
@end
