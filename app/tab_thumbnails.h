// Tab thumbnails (#65): a small picture of a page, copied from NotArc's own window by ScreenCaptureKit.
//
// Asynchronous on purpose. Copying the window synchronously (CGWindowListCreateImage) held the main thread for
// 10-110 ms per picture and made timing-sensitive self-tests fail at random; DevTools screenshots stop Chromium
// reporting frozen pages. Here the main thread only starts the request (well under a millisecond); the window
// server makes the copy, and scaling plus JPEG encoding run on a background queue.
//
// Needs macOS 14.4: an app may copy its own windows there without the Screen Recording permission. Earlier
// systems get no thumbnails (TabThumbnailsAvailable() is NO).
#pragma once
#import <AppKit/AppKit.h>

BOOL TabThumbnailsAvailable(void);

// Copies `rectInWindow` (window coordinates, points, AppKit's bottom-left origin) of `window`, scaled to
// `pixelWidth` pixels wide. `done` runs on the main queue with nil on failure. Kept in memory only, as JPEG.
void TabThumbnailCapture(NSWindow* window, NSRect rectInWindow, CGFloat pixelWidth, void (^done)(NSImage* image));

// Timing for tests and the PR: main-thread time spent starting each request (kickoff) and handing the picture
// over (deliver), and the time until the picture arrived (latency, off the main thread).
struct TabThumbnailStats {
  long started = 0, finished = 0, failed = 0;
  double maxKickoffMs = 0, totalKickoffMs = 0, maxDeliverMs = 0, maxLatencyMs = 0, totalLatencyMs = 0;
  long switches = 0;            // tab switches seen by the thumbnail code
  double maxSwitchHookMs = 0;   // the most main-thread time the thumbnail code added to one tab switch
};
TabThumbnailStats TabThumbnailStatsGet(void);
void TabThumbnailNoteSwitch(double hookMs);

// Memory cap: at most this many pictures are kept (across all windows); the oldest are dropped first. About
// 30 KB each as JPEG, under 0.7 MB each once drawn.
static const NSUInteger kTabThumbnailMax = 40;
