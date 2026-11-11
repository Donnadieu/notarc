// Arc-style dialogs (visual parity V60): a rounded card centred over the dimmed window, title and message in Arc's
// popover colours, and Arc's button faces (blue primary, red destructive, quiet neutral). A drop-in for the parts
// of NSAlert NotArc uses: the same properties, button order and NSAlertFirstButtonReturn + n results.
#import <Cocoa/Cocoa.h>

@interface ArcAlert : NSObject
@property(nonatomic, copy) NSString* messageText;
@property(nonatomic, copy) NSString* informativeText;
@property(nonatomic, strong) NSView* accessoryView;
// The card's own panel: set initialFirstResponder on it before showing, as with NSAlert.
@property(nonatomic, readonly) NSPanel* window;
@property(nonatomic, readonly) NSArray<NSButton*>* buttons;
// First button: Return (rightmost). A button titled Cancel: Esc. Set hasDestructiveAction on a button for red.
- (NSButton*)addButtonWithTitle:(NSString*)title;
// Shows the card over `window` (which dims and stops taking clicks) and calls back with the button pressed.
- (void)beginSheetModalForWindow:(NSWindow*)window completionHandler:(void (^)(NSModalResponse returnCode))handler;
// Blocks until a button is pressed; over the key window when there is one.
- (NSModalResponse)runModal;
// Closes the card as if `response` was chosen (NSModalResponseAbort for "gone").
- (void)dismissWithResponse:(NSModalResponse)response;
@property(nonatomic, readonly) BOOL isShown;
// Tests: "card=1 child=1 scrim=1 radius=16 primary=1 destructive=1 neutral=1 returnKey=1 escKey=1".
- (NSString*)lookDescription;
@end

// YES while an ArcAlert card is up over `window` (the dialog equivalent of window.attachedSheet).
BOOL ArcAlertShownOn(NSWindow* window);
