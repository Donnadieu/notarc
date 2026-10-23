// CEF client shared by every web view in the window.
#pragma once

#include <functional>
#include <string>

#include "include/cef_client.h"

class BrowserClient : public CefClient,
                      public CefDisplayHandler,
                      public CefLifeSpanHandler,
                      public CefLoadHandler {
 public:
  using TitleCallback = std::function<void(int browser_id, const std::string& title)>;
  using UrlCallback = std::function<void(int browser_id, const std::string& url)>;

  BrowserClient(TitleCallback on_title, UrlCallback on_url);

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override;
  void OnAddressChange(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       const CefString& url) override;
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;
  // Returning false lets CEF close the parent NSWindow, which would quit the app when one tab
  // closes. For single-tab closes we return true and remove the tab's view ourselves.
  bool DoClose(CefRefPtr<CefBrowser> browser) override;
  void OnLoadError(CefRefPtr<CefBrowser> browser,
                   CefRefPtr<CefFrame> frame,
                   ErrorCode error_code,
                   const CefString& error_text,
                   const CefString& failed_url) override;

  int open_browser_count() const { return open_browsers_; }
  // Closing individual tabs must not quit the app; only quit once the window is shutting down.
  void set_quit_when_empty(bool quit) { quit_when_empty_ = quit; }

 private:
  TitleCallback on_title_;
  UrlCallback on_url_;
  int open_browsers_ = 0;
  bool quit_when_empty_ = false;

  IMPLEMENT_REFCOUNTING(BrowserClient);
};
