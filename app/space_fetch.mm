#import "app/space_fetch.h"

#include "include/cef_urlrequest.h"
#include "include/wrapper/cef_helpers.h"

namespace {

class FetchClient : public CefURLRequestClient {
 public:
  explicit FetchClient(void (^done)(NSInteger, NSData*, NSString*)) : done_([done copy]), body_([NSMutableData data]) {}
  void OnRequestComplete(CefRefPtr<CefURLRequest> request) override {
    CefRefPtr<CefResponse> r = request->GetResponse();
    NSInteger status = r ? r->GetStatus() : 0;
    if (request->GetRequestStatus() != UR_SUCCESS) status = 0;
    NSString* finalURL = r ? [NSString stringWithUTF8String:r->GetURL().ToString().c_str()] : nil;
    NSData* body = [body_ copy];
    auto done = done_;
    dispatch_async(dispatch_get_main_queue(), ^{ done(status, body, finalURL); });
  }
  void OnUploadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
  void OnDownloadProgress(CefRefPtr<CefURLRequest>, int64_t, int64_t) override {}
  void OnDownloadData(CefRefPtr<CefURLRequest>, const void* data, size_t length) override {
    if (body_.length < 8 * 1024 * 1024) [body_ appendBytes:data length:length];  // 8 MB cap
  }
  bool GetAuthCredentials(bool, const CefString&, int, const CefString&, const CefString&,
                          CefRefPtr<CefAuthCallback>) override {
    return false;
  }

 private:
  void (^done_)(NSInteger, NSData*, NSString*);
  NSMutableData* body_;
  IMPLEMENT_REFCOUNTING(FetchClient);
};

}  // namespace

void SpaceFetch(CefRefPtr<CefRequestContext> context, NSString* url, NSDictionary<NSString*, NSString*>* headers,
                void (^done)(NSInteger status, NSData* body, NSString* finalURL)) {
  if (!context || !url.length) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(0, nil, nil); });
    return;
  }
  CefRefPtr<CefRequest> req = CefRequest::Create();
  req->SetURL(url.UTF8String);
  req->SetMethod("GET");
  CefRequest::HeaderMap map;
  for (NSString* k in headers) map.insert({k.UTF8String, headers[k].UTF8String});
  if (!map.empty()) req->SetHeaderMap(map);
  // Send the Space's cookies, as the site's own page would; nothing is stored back.
  req->SetFlags(UR_FLAG_ALLOW_STORED_CREDENTIALS | UR_FLAG_NO_RETRY_ON_5XX);
  CefURLRequest::Create(req, new FetchClient(done), context);
}
