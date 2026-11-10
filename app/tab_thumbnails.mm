// Tab thumbnails (#65). See tab_thumbnails.h for why this is asynchronous and uses ScreenCaptureKit.
#import "tab_thumbnails.h"

#import <ImageIO/ImageIO.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <vector>

static TabThumbnailStats gStats;  // main thread only

BOOL TabThumbnailsAvailable(void) {
  if (@available(macOS 14.4, *)) return YES;
  return NO;
}

TabThumbnailStats TabThumbnailStatsGet(void) { return gStats; }

void TabThumbnailNoteSwitch(double hookMs) {
  gStats.switches++;
  gStats.maxSwitchHookMs = MAX(gStats.maxSwitchHookMs, hookMs);
}

// Opaque JPEG of `img`. Pages are opaque, but the hidden self-test window is 1% opaque, so the copy comes back
// premultiplied with tiny values: undo the premultiplication first so the picture keeps the page's colours.
static NSData* OpaqueJPEG(CGImageRef img) {
  size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
  if (!w || !h) return nil;
  std::vector<uint8_t> px(w * h * 4);
  CGColorSpaceRef rgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, rgb, kCGImageAlphaPremultipliedLast);
  if (!ctx) {
    CGColorSpaceRelease(rgb);
    return nil;
  }
  CGContextSetBlendMode(ctx, kCGBlendModeCopy);
  CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
  for (size_t i = 0; i < px.size(); i += 4) {
    unsigned a = px[i + 3];
    if (a && a < 255)
      for (int c = 0; c < 3; ++c) px[i + c] = (uint8_t)MIN(255u, (px[i + c] * 255u + a / 2) / a);
    px[i + 3] = 255;
  }
  CGImageRef flat = CGBitmapContextCreateImage(ctx);
  CGContextRelease(ctx);
  CGColorSpaceRelease(rgb);
  if (!flat) return nil;
  NSMutableData* out = [NSMutableData data];
  CGImageDestinationRef dest =
      CGImageDestinationCreateWithData((__bridge CFMutableDataRef)out, (__bridge CFStringRef)UTTypeJPEG.identifier, 1, nil);
  if (dest) {
    CGImageDestinationAddImage(dest, flat, (__bridge CFDictionaryRef) @{(id)kCGImageDestinationLossyCompressionQuality : @0.75});
    if (!CGImageDestinationFinalize(dest)) out = nil;
    CFRelease(dest);
  }
  CGImageRelease(flat);
  return out.length ? out : nil;
}

void TabThumbnailCapture(NSWindow* window, NSRect rectInWindow, CGFloat pixelWidth, void (^done)(NSImage* image)) {
  void (^finish)(NSImage*, CFAbsoluteTime) = ^(NSImage* image, CFAbsoluteTime started) {
    double ms = (CFAbsoluteTimeGetCurrent() - started) * 1000;
    if (image) {
      gStats.finished++;
      gStats.totalLatencyMs += ms;
      gStats.maxLatencyMs = MAX(gStats.maxLatencyMs, ms);
    } else {
      gStats.failed++;
    }
    CFAbsoluteTime d0 = CFAbsoluteTimeGetCurrent();
    done(image);
    gStats.maxDeliverMs = MAX(gStats.maxDeliverMs, (CFAbsoluteTimeGetCurrent() - d0) * 1000);
  };
  if (@available(macOS 14.4, *)) {
    CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
    if (!window || NSIsEmptyRect(rectInWindow) || pixelWidth < 1) {
      done(nil);
      return;
    }
    CGWindowID wid = (CGWindowID)window.windowNumber;
    // ScreenCaptureKit wants the part of the window in points from its top-left corner.
    CGRect source = CGRectMake(rectInWindow.origin.x, window.frame.size.height - NSMaxY(rectInWindow), rectInWindow.size.width,
                               rectInWindow.size.height);
    size_t outW = (size_t)pixelWidth, outH = (size_t)MAX(1.0, round(pixelWidth * source.size.height / source.size.width));
    gStats.started++;
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent* content, NSError*) {
      SCWindow* mine = nil;
      for (SCWindow* w in content.windows)
        if (w.windowID == wid) mine = w;
      if (!mine) {
        dispatch_async(dispatch_get_main_queue(), ^{ finish(nil, t0); });
        return;
      }
      SCContentFilter* filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:mine];
      SCStreamConfiguration* config = [SCStreamConfiguration new];
      config.sourceRect = source;
      config.width = outW;
      config.height = outH;
      config.showsCursor = NO;
      config.ignoreShadowsSingleWindow = YES;
      [SCScreenshotManager captureImageWithFilter:filter configuration:config completionHandler:^(CGImageRef img, NSError*) {
        NSData* jpeg = img ? OpaqueJPEG(img) : nil;  // on ScreenCaptureKit's queue, never the main thread
        NSImage* image = jpeg ? [[NSImage alloc] initWithData:jpeg] : nil;  // decoded lazily, when first drawn
        dispatch_async(dispatch_get_main_queue(), ^{ finish(image, t0); });
      }];
    }];
    double kickoff = (CFAbsoluteTimeGetCurrent() - t0) * 1000;
    gStats.totalKickoffMs += kickoff;
    gStats.maxKickoffMs = MAX(gStats.maxKickoffMs, kickoff);
    return;
  }
  done(nil);
}
