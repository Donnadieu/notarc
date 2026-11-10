// Live web clips on easels (#49). A clip keeps its source URL and the region that was dragged over the page; to
// refresh it, the page is loaded again in a short-lived hidden off-screen browser (no window, no DevTools, never one
// of the user's tabs) at the size the page had, scrolled to where it was, and the region is cropped from its pixels.
#pragma once
#import <Cocoa/Cocoa.h>

#include "include/cef_request_context.h"

// Renders `url` at `viewport` (points), scrolled to `scroll` (CSS px), and returns the PNG of `region` (points,
// top-left origin, relative to the viewport) at `scale` pixels per point. `done` runs on the main thread with nil if
// the page didn't load within the timeout. Everything runs on the main (CEF UI) thread except the PNG encoding.
void EaselRenderClip(CefRefPtr<CefRequestContext> context, NSString* url, NSSize viewport, NSPoint scroll, NSRect region,
                     CGFloat scale, void (^done)(NSData* png));

// Closes every clip browser still loading (on quit).
void EaselCloseClipRenderers();

// Tests: clip browsers alive right now, and renders started since launch.
NSInteger EaselClipRenderersActive();
NSInteger EaselClipRendersStarted();
