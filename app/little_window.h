// Little Window: a small, separate browser window for quick looks, like Arc's Little Arc.
// Links opened from other apps land here instead of cluttering the sidebar. "Open in NotArc"
// moves the page into the current Space's Today section; closing without moving archives it.
#pragma once

#import <Cocoa/Cocoa.h>

#include "include/cef_request_context.h"

@class LittleWindowController;

// moved = YES when the page was moved into the main window (so it shouldn't be archived).
typedef void (^LittleWindowClosed)(LittleWindowController* little, NSString* url, NSString* title, BOOL moved);
typedef void (^LittleWindowMove)(NSString* url);
typedef void (^LittleWindowMoveToSpace)(NSString* url, NSUInteger spaceIndex);

@interface LittleWindowController : NSWindowController <NSWindowDelegate>
- (instancetype)initWithURL:(NSString*)url
                    context:(CefRefPtr<CefRequestContext>)context
                     onMove:(LittleWindowMove)onMove
                    onClose:(LittleWindowClosed)onClose;
- (IBAction)openInMainWindow:(id)sender;
// "Move to Space" menu next to the Open button: one entry per Space name; picking one calls onMoveToSpace.
@property(nonatomic, copy) NSArray<NSString*>* spaceNames;
@property(nonatomic, copy) LittleWindowMoveToSpace onMoveToSpace;
- (void)openInSpaceAtIndex:(NSUInteger)index;
// Peek: shown as an overlay attached to `parent`, button reads "Open as Tab", Esc closes it.
- (void)presentAsPeekOver:(NSWindow*)parent;
@property(nonatomic, readonly) NSString* currentURL;
@property(nonatomic, readonly) NSString* pageTitle;
@property(nonatomic, strong) NSDate* lastUsedAt;  // last time the window was focused; drives idle archiving
@end
