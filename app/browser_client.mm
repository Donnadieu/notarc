#include "app/browser_client.h"

#include <cstdio>

#include "include/cef_app.h"
#include "include/wrapper/cef_helpers.h"

BrowserClient::BrowserClient(TitleCallback on_title, UrlCallback on_url)
    : on_title_(std::move(on_title)), on_url_(std::move(on_url)) {}

void BrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  CEF_REQUIRE_UI_THREAD();
  if (on_title_) on_title_(browser->GetIdentifier(), title.ToString());
}

void BrowserClient::OnAddressChange(CefRefPtr<CefBrowser> browser,
                                    CefRefPtr<CefFrame> frame,
                                    const CefString& url) {
  CEF_REQUIRE_UI_THREAD();
  if (frame->IsMain() && on_url_) on_url_(browser->GetIdentifier(), url.ToString());
}

void BrowserClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  ++open_browsers_;
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (--open_browsers_ == 0 && quit_when_empty_) CefQuitMessageLoop();
}

bool BrowserClient::DoClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  return !quit_when_empty_;
}

void BrowserClient::OnLoadError(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                ErrorCode error_code,
                                const CefString& error_text,
                                const CefString& failed_url) {
  CEF_REQUIRE_UI_THREAD();
  if (error_code == ERR_ABORTED) return;
  std::fprintf(stderr, "load error %d %s for %s\n", static_cast<int>(error_code),
               error_text.ToString().c_str(), failed_url.ToString().c_str());
}
