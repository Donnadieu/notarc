// Chrome-style pages (#66): Chrome extensions, the password manager and autofill only exist in CEF's Chrome
// style, which needs CEF's Views framework, and CEF allows one Chrome-style page per CEF window. So each page gets
// its own borderless CEF window, attached to the NotArc window as a child window and kept exactly over a
// placeholder view that NotArc lays out like any other view (page card, split panes).
#pragma once

#import <Cocoa/Cocoa.h>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_request_context.h"

BOOL ChromePagesEnabled(void);  // user default "chromePages" or --chrome-pages; off by default for now

@interface ChromePageHost : NSObject
- (instancetype)initWithClient:(CefRefPtr<CefClient>)client
                           url:(NSString*)url
                       context:(CefRefPtr<CefRequestContext>)context
                     hostView:(NSView*)hostView;
@property(nonatomic, readonly) NSView* placeholder;  // stands where the page is; its frame drives the page window
@property(nonatomic, readonly) NSWindow* pageWindow;
- (CefRefPtr<CefBrowser>)browser;  // null if the page couldn't be created
- (void)syncFrame;                 // placeholder moved, resized, hidden or shown
- (void)close;
@end
