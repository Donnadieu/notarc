// Extension popups as bubbles (#66): an extension's action popup (manifest action.default_popup) shown in a small
// borderless panel under the extension picker button, the way Chrome and Arc show it, instead of in a tab.
//
// The page is a Chrome-style CEF browser (extensions only run in Chrome style) in the Space's own request context,
// hosted with ChromePageHost inside NotArc's own panel. The bubble sizes itself to the page (Chromium's auto-resize,
// with a script measurement as a fallback), clamped to Chrome's popup limits, and closes on a click outside, Esc,
// the window moving, resizing or losing focus to another window, NotArc going to the background, or the page
// calling window.close().
#pragma once

#import <Cocoa/Cocoa.h>

#include "include/cef_request_context.h"

extern const NSSize kExtensionPopupMinSize;  // 25 x 25, Chrome's limits
extern const NSSize kExtensionPopupMaxSize;  // 800 x 600
NSSize ExtensionPopupClampSize(NSSize size);
// Where the bubble goes (screen coordinates): just under `anchor`, left edges lined up, moved and shrunk to stay
// inside `bounds` (the window's frame) with a small margin.
NSRect ExtensionPopupFrame(NSRect anchor, NSSize size, NSRect bounds);

@interface ExtensionPopup : NSObject
// `hidden`: self-test runs; the panel and page take the parent's (1%) alpha and never take clicks or focus.
- (instancetype)initWithURL:(NSString*)url
                    context:(CefRefPtr<CefRequestContext>)context
                     parent:(NSWindow*)parent
                     anchor:(NSView*)anchor
                     hidden:(BOOL)hidden;
@property(nonatomic, readonly) NSString* url;        // the popup page asked for
@property(nonatomic, readonly) NSString* loadedURL;  // main frame URL once it finished loading
@property(nonatomic, readonly) NSString* title;
@property(nonatomic, readonly) BOOL loadFailed;
@property(nonatomic, readonly) NSSize pageSize;      // what the page asked for (before clamping); zero until known
@property(nonatomic, readonly) NSString* sizedBy;    // "autoresize" or "script"; nil until sized
@property(nonatomic, readonly) NSPanel* panel;
@property(nonatomic, readonly) NSWindow* pageWindow;
@property(nonatomic, readonly) BOOL isOpen;
@property(nonatomic, readonly) NSString* closeReason;  // "esc", "click", "window", "script", "replaced", ...
@property(nonatomic, copy) void (^openURL)(NSString* url);  // links and windows the popup opens become NotArc tabs
@property(nonatomic, copy) void (^onClose)(void);
- (void)closeBecause:(NSString*)reason;
- (NSEvent*)handleLocalEvent:(NSEvent*)event;  // the event monitor (nil = consumed); tests feed events through it
- (void)runJS:(NSString*)js;
@end
