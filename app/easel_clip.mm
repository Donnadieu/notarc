#import "app/easel_clip.h"

#include <set>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"
#include "include/cef_load_handler.h"
#include "include/cef_render_handler.h"

namespace {

class ClipRenderer;
std::set<ClipRenderer*>& Renderers() {
  static std::set<ClipRenderer*> s;
  return s;
}
NSInteger gStarted = 0;

// How long the page gets after it stops loading (late layout, web fonts) and in total.
constexpr double kSettleSeconds = 0.8;
constexpr double kTimeoutSeconds = 25;

class ClipRenderer : public CefClient, public CefRenderHandler, public CefLifeSpanHandler, public CefLoadHandler {
 public:
  ClipRenderer(NSSize viewport, NSPoint scroll, NSRect region, CGFloat scale, void (^done)(NSData*))
      : viewport_(viewport), scroll_(scroll), region_(region), scale_(scale), done_([done copy]) {}

  CefRefPtr<CefRenderHandler> GetRenderHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  void GetViewRect(CefRefPtr<CefBrowser>, CefRect& rect) override {
    rect = CefRect(0, 0, (int)viewport_.width, (int)viewport_.height);
  }
  bool GetScreenInfo(CefRefPtr<CefBrowser>, CefScreenInfo& info) override {
    info.device_scale_factor = (float)scale_;
    info.depth = 24;
    info.depth_per_component = 8;
    info.rect = info.available_rect = CefRect(0, 0, (int)viewport_.width, (int)viewport_.height);
    return true;
  }
  void OnPaint(CefRefPtr<CefBrowser>, PaintElementType type, const RectList&, const void* buffer, int width,
               int height) override {
    if (type != PET_VIEW || !want_ || finished_ || !buffer) return;
    // Crop the region (BGRA, top-left origin) out of the frame; encode off the main thread.
    CGFloat sx = width / MAX(1.0, viewport_.width), sy = height / MAX(1.0, viewport_.height);
    CGRect px = CGRectIntegral(CGRectMake(region_.origin.x * sx, region_.origin.y * sy, region_.size.width * sx,
                                          region_.size.height * sy));
    px = CGRectIntersection(px, CGRectMake(0, 0, width, height));
    if (CGRectIsEmpty(px)) { Finish(nil); return; }
    size_t cw = (size_t)px.size.width, ch = (size_t)px.size.height, x0 = (size_t)px.origin.x, y0 = (size_t)px.origin.y;
    NSMutableData* pixels = [NSMutableData dataWithLength:cw * ch * 4];
    const uint8_t* src = static_cast<const uint8_t*>(buffer);
    for (size_t y = 0; y < ch; y++)
      memcpy((uint8_t*)pixels.mutableBytes + y * cw * 4, src + ((y0 + y) * (size_t)width + x0) * 4, cw * 4);
    finished_ = true;
    void (^done)(NSData*) = done_;
    done_ = nil;
    CGFloat scale = scale_;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
      CGImageRef img = CGImageCreate(cw, ch, 8, 32, cw * 4, cs,
                                     (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | (CGBitmapInfo)kCGBitmapByteOrder32Little, dp, NULL, false,
                                     kCGRenderingIntentDefault);
      NSBitmapImageRep* rep = img ? [[NSBitmapImageRep alloc] initWithCGImage:img] : nil;
      rep.size = NSMakeSize(cw / scale, ch / scale);
      NSData* png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
      if (img) CGImageRelease(img);
      CGDataProviderRelease(dp);
      CGColorSpaceRelease(cs);
      dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(png); });
    });
    Close();
  }

  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int, const CefString&, const CefString&,
                     WindowOpenDisposition, bool, const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
                     CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    return true;  // a clip never opens windows
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> b) override {
    browser_ = b;
    b->GetHost()->SetAudioMuted(true);
    if (finished_) Close();
  }
  void OnBeforeClose(CefRefPtr<CefBrowser>) override {
    browser_ = nullptr;
    if (Renderers().erase(this)) Release();
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> b, bool isLoading, bool, bool) override {
    int g = ++generation_;
    if (isLoading || finished_) return;
    if (scroll_.x > 0 || scroll_.y > 0)
      b->GetMainFrame()->ExecuteJavaScript(
          [NSString stringWithFormat:@"window.scrollTo(%g,%g)", scroll_.x, scroll_.y].UTF8String, "", 0);
    CefRefPtr<ClipRenderer> self(this);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSettleSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      if (self->generation_ != g || self->finished_ || !self->browser_) return;
      self->want_ = true;
      self->browser_->GetHost()->Invalidate(PET_VIEW);
    });
  }
  void OnLoadError(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, ErrorCode code, const CefString&,
                   const CefString&) override {
    if (frame->IsMain() && code != ERR_ABORTED) Finish(nil);
  }

  void StartTimeout() {
    CefRefPtr<ClipRenderer> self(this);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kTimeoutSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(),
                   ^{ self->Finish(nil); });
  }
  void Finish(NSData* png) {
    if (finished_) return;
    finished_ = true;
    void (^done)(NSData*) = done_;
    done_ = nil;
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(png); });
    Close();
  }
  void Close() {
    if (browser_ && !closing_) {
      closing_ = true;
      browser_->GetHost()->CloseBrowser(true);
    }
  }

 private:
  NSSize viewport_;
  NSPoint scroll_;
  NSRect region_;
  CGFloat scale_;
  void (^done_)(NSData*);
  CefRefPtr<CefBrowser> browser_;
  bool want_ = false, finished_ = false, closing_ = false;
  int generation_ = 0;
  IMPLEMENT_REFCOUNTING(ClipRenderer);
};

}  // namespace

void EaselRenderClip(CefRefPtr<CefRequestContext> context, NSString* url, NSSize viewport, NSPoint scroll, NSRect region,
                     CGFloat scale, void (^done)(NSData* png)) {
  NSURL* u = url.length ? [NSURL URLWithString:url] : nil;
  NSString* scheme = u.scheme.lowercaseString;
  // Only web pages (and local files, for tests) are re-rendered; never javascript:, data: or app pages.
  if (!u || !([scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"file"]) ||
      viewport.width < 50 || viewport.height < 50 || NSIsEmptyRect(region)) {
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
    return;
  }
  viewport = NSMakeSize(MIN(viewport.width, 4096), MIN(viewport.height, 4096));
  ClipRenderer* r = new ClipRenderer(viewport, scroll, region, MAX(1.0, MIN(scale, 3.0)), done);
  r->AddRef();
  Renderers().insert(r);
  gStarted++;
  CefWindowInfo info;
  info.SetAsWindowless(nullptr);
  CefBrowserSettings settings;
  settings.windowless_frame_rate = 10;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  if (!CefBrowserHost::CreateBrowser(info, r, url.UTF8String, settings, nullptr, context)) {
    r->Finish(nil);
    if (Renderers().erase(r)) r->Release();
    return;
  }
  r->StartTimeout();
}

void EaselCloseClipRenderers() {
  for (ClipRenderer* r : std::set<ClipRenderer*>(Renderers())) r->Finish(nil);
}

NSInteger EaselClipRenderersActive() { return (NSInteger)Renderers().size(); }
NSInteger EaselClipRendersStarted() { return gStarted; }
