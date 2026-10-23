// CEF client shared by every web view in the window.
#pragma once

#include <functional>
#include <string>

#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_request_handler.h"

class BrowserClient : public CefClient,
                      public CefDisplayHandler,
                      public CefLifeSpanHandler,
                      public CefLoadHandler,
                      public CefFindHandler,
                      public CefFocusHandler,
                      public CefRequestHandler,
                      public CefContextMenuHandler,
                      public CefDownloadHandler {
 public:
  using TitleCallback = std::function<void(int browser_id, const std::string& title)>;
  using UrlCallback = std::function<void(int browser_id, const std::string& url)>;

  BrowserClient(TitleCallback on_title, UrlCallback on_url);

  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
  CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  // Downloads save straight into the download folder (no Save dialog), tracked by DownloadManager.
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name, CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

  // Right-clicking a link adds NotArc's link actions on top of Chromium's menu.
  enum LinkCommand { kLinkNewTab = 0, kLinkBackgroundTab, kLinkSplit, kLinkPeek, kLinkLittle, kLinkCopyMarkdown, kLinkCount };
  using LinkMenuCallback = std::function<void(int browser_id, int command, const std::string& url, const std::string& text)>;
  void set_link_menu_callback(LinkMenuCallback cb) { on_link_menu_ = std::move(cb); }
  void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                           CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model) override;
  bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                            CefRefPtr<CefContextMenuParams> params, int command_id, EventFlags event_flags) override;

  // Asked before a user-initiated main-frame navigation; returning true cancels it (the window
  // shows the link somewhere else instead, e.g. Peek).
  using NavigationFilter = std::function<bool(int browser_id, const std::string& url)>;
  void set_navigation_filter(NavigationFilter f) { navigation_filter_ = std::move(f); }
  // Links that ask for a new tab or window (Cmd-click, Shift-click, target=_blank). Returning true means the
  // window handled it, so CEF doesn't open its own native window. Real popups (window.open with a size,
  // e.g. sign-in dialogs) are not routed here.
  using OpenCallback = std::function<bool(int browser_id, const std::string& url, int disposition, bool user_gesture)>;
  void set_open_callback(OpenCallback cb) { on_open_ = std::move(cb); }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& target_url,
                        WindowOpenDisposition target_disposition, bool user_gesture) override;
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                     const CefString& target_url, const CefString& target_frame_name,
                     WindowOpenDisposition target_disposition, bool user_gesture,
                     const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo, CefRefPtr<CefClient>& client,
                     CefBrowserSettings& settings, CefRefPtr<CefDictionaryValue>& extra_info,
                     bool* no_javascript_access) override;
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                      bool user_gesture, bool is_redirect) override;

  // Fires when a web view takes keyboard focus (e.g. the user clicks a split view pane).
  using FocusCallback = std::function<void(int browser_id)>;
  void set_focus_callback(FocusCallback cb) { on_focus_ = std::move(cb); }
  void OnGotFocus(CefRefPtr<CefBrowser> browser) override;

  using FindCallback = std::function<void(int browser_id, int count, int active)>;
  void set_find_callback(FindCallback cb) { on_find_ = std::move(cb); }
  void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect& selection_rect,
                    int active_match_ordinal, bool final_update) override;

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

  // Pages report media state with console.log("__notarc_media__:<state>"); those lines are swallowed and
  // passed here instead (state: "playing", "paused" or "none").
  using MediaCallback = std::function<void(int browser_id, const std::string& state, const std::string& title)>;
  void set_media_callback(MediaCallback cb) { on_media_ = std::move(cb); }
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString& message,
                        const CefString& source, int line) override;

  int open_browser_count() const { return open_browsers_; }
  // Closing individual tabs must not quit the app; only quit once the window is shutting down.
  void set_quit_when_empty(bool quit) { quit_when_empty_ = quit; }

 private:
  TitleCallback on_title_;
  UrlCallback on_url_;
  FindCallback on_find_;
  FocusCallback on_focus_;
  NavigationFilter navigation_filter_;
  OpenCallback on_open_;
  LinkMenuCallback on_link_menu_;
  MediaCallback on_media_;
  int open_browsers_ = 0;
  bool quit_when_empty_ = false;

  IMPLEMENT_REFCOUNTING(BrowserClient);
};
