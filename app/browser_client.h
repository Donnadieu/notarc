// CEF client shared by every web view in the window.
#pragma once

#include <string>
#include <utility>
#include <vector>
#include <functional>
#include <map>
#include <string>

#include "include/cef_client.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_download_handler.h"
#include "include/cef_find_handler.h"
#include "include/cef_focus_handler.h"
#include "include/cef_permission_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_request_handler.h"

class BrowserClient : public CefClient,
                      public CefDisplayHandler,
                      public CefLifeSpanHandler,
                      public CefLoadHandler,
                      public CefFindHandler,
                      public CefFocusHandler,
                      public CefRequestHandler,
                      public CefContextMenuHandler,
                      public CefDownloadHandler,
                      public CefPermissionHandler,
                      public CefResourceRequestHandler {
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
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }

  // NotArc's own bit (above CEF's permission types) for a screen-sharing request (getDisplayMedia).
  static constexpr uint32_t kScreenSharePermission = 1u << 31;
  // Site permissions (camera, mic, location, notifications, ...). The UI answers with ResolvePermission.
  // request_id is ours; `permissions` uses CEF_PERMISSION_TYPE_* bits (media requests are mapped onto
  // CAMERA_STREAM / MIC_STREAM, screen sharing onto kScreenSharePermission). Called on the UI thread.
  using PermissionCallback =
      std::function<void(int browser_id, int request_id, const std::string& origin, uint32_t permissions)>;
  void set_permission_callback(PermissionCallback cb) { on_permission_ = std::move(cb); }
  void ResolvePermission(int request_id, bool allow);
  // A local log of site requests and NotArc's answers (SiteRequests.log next to the sidebar), one line each, written at
  // once: after Omar's Nov 13 crash inside Chromium's PermissionRequest::PermissionGranted, the next one names the request.
  static void SetPermissionLogPath(const std::string& path);
  // Self-test with the Mac's real camera/mic status (no fake devices): refuse every device request, so nothing opens.
  static void SetRefuseDeviceMediaForTest(bool refuse);
  static void LogPermission(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
  bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                      const CefString& requesting_origin, uint32_t requested_permissions,
                                      CefRefPtr<CefMediaAccessCallback> callback) override;
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString& requesting_origin,
                              uint32_t requested_permissions, CefRefPtr<CefPermissionPromptCallback> callback) override;
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id,
                                 cef_permission_request_result_t result) override;

  // Links to other apps (mailto:, zoommtg:, ...). Chromium never opens them itself; the UI asks first.
  // Camera/microphone in use by a page (Arc's call controls, #47).
  using CaptureCallback = std::function<void(int browser_id, bool video, bool audio)>;
  void set_capture_callback(CaptureCallback cb) { on_capture_ = std::move(cb); }
  void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool has_video_access, bool has_audio_access) override {
    if (on_capture_) on_capture_(browser->GetIdentifier(), has_video_access, has_audio_access);
  }
  using ExternalCallback = std::function<void(int browser_id, const std::string& url)>;
  void set_external_callback(ExternalCallback cb) { on_external_ = std::move(cb); }
  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                                 CefRefPtr<CefRequest>, bool, bool, const CefString&,
                                                                 bool&) override {
    return this;
  }
  // Self-tests only: pages whose URL starts with `url_prefix` get `html` instead of going to the network
  // (empty html removes the stub). Never set outside tests.
  static void SetTestResponse(const std::string& url_prefix, const std::string& html);
  CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                                   CefRefPtr<CefRequest> request) override;
  void OnProtocolExecution(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                           bool& allow_os_execution) override;
  // Built-in ad & tracker blocking (#53): cancels third-party requests to listed hosts.
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override;
  // Downloads save straight into the download folder (no Save dialog), tracked by DownloadManager.
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                        const CefString& suggested_name, CefRefPtr<CefBeforeDownloadCallback> callback) override;
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                         CefRefPtr<CefDownloadItemCallback> callback) override;

  // Right-clicking a link adds NotArc's link actions on top of Chromium's menu.
  // Image, page and selection actions (#70) share the same callback: `url` is the image's or page's address, `text` the
  // selected text.
  enum LinkCommand {
    kLinkNewTab = 0, kLinkBackgroundTab, kLinkSplit, kLinkPeek, kLinkLittle, kLinkCopyMarkdown,
    kImageOpen, kImageCopy, kImageCopyAddress, kImageSave,
    kPageCopyURL, kPageCopyMarkdown, kPageCapture, kPageTranslate, kPageBoost,
    kSelectionSearch,
    kLinkCount
  };
  // What NotArc adds to Chromium's menu for a right-click (pure, for tests): command ids and titles, in order.
  static std::vector<std::pair<int, std::string>> MenuItemsFor(bool link, bool image, bool selection, bool editable,
                                                              const std::string& selectionText);
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
  // The link under the pointer (Chromium's status bubble text; empty when the pointer leaves it). Used by Max's
  // 5-second previews (#58).
  using StatusCallback = std::function<void(int browser_id, const std::string& text)>;
  void set_status_callback(StatusCallback cb) { on_status_ = std::move(cb); }
  void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString& value) override {
    if (on_status_) on_status_(browser->GetIdentifier(), value.ToString());
  }
  // The page's icon changed (first URL the page offers); the window downloads it for the sidebar.
  using FaviconCallback = std::function<void(int browser_id, const std::string& icon_url)>;
  void set_favicon_callback(FaviconCallback cb) { on_favicon_ = std::move(cb); }
  void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& icon_urls) override;
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
  // Boosts: "__notarc_zap__:<selector>" console lines, and main-frame load end (to apply Boosts).
  using ZapCallback = std::function<void(int browser_id, const std::string& selector)>;
  void set_zap_callback(ZapCallback cb) { on_zap_ = std::move(cb); }
  // Web notifications (#78): a page's `new Notification(...)` / `registration.showNotification(...)`, as JSON
  // {title, body, tag}, with the page's URL.
  using NotifyCallback = std::function<void(int browser_id, const std::string& json, const std::string& page_url)>;
  void set_notify_callback(NotifyCallback cb) { on_notify_ = std::move(cb); }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition_type) override;
  static const char* NotificationShimJS();
  using LangCallback = std::function<void(int browser_id, const std::string& lang)>;  // page language (#52)
  void set_lang_callback(LangCallback cb) { on_lang_ = std::move(cb); }
  using LoadEndCallback = std::function<void(int browser_id, const std::string& url)>;
  void set_load_end_callback(LoadEndCallback cb) { on_load_end_ = std::move(cb); }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override;
  // The page started or stopped loading (spinner in the sidebar row, glow on the page card; back / forward state).
  using LoadingCallback = std::function<void(int browser_id, bool loading)>;
  void set_loading_callback(LoadingCallback cb) { on_loading_ = std::move(cb); }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override {
    if (on_loading_) on_loading_(browser->GetIdentifier(), isLoading);
  }

  // Passwords and autofill (#67). Every http(s) document gets a small script (see autofill.mm) that reports login
  // submissions and clicks into login / address / card fields as "__notarc_af__:<nonce>:<json>" console lines.
  // The nonce is made here per frame, so a message is only trusted for the frame (and origin) it was given to;
  // unknown nonces are dropped. Fills go back to that same frame with AutofillRun, only if it still shows that origin.
  using AutofillCallback = std::function<void(int browser_id, const std::string& nonce, const std::string& origin,
                                              bool main_frame, const std::string& json)>;
  void set_autofill_callback(AutofillCallback cb) { on_autofill_ = std::move(cb); }
  bool AutofillRun(const std::string& nonce, const std::string& js);
  // Runs js in every frame of a tab that has the autofill script (Fill Password from the menu).
  void AutofillRunAllFrames(int browser_id, const std::string& js);
  CefRefPtr<CefBrowser> BrowserById(int browser_id);
  // Self-test only: also give file:// pages the script (the login fixture is a local file).
  static void SetAutofillAllowFileURLs(bool allow);
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString& message,
                        const CefString& source, int line) override;

  // Renderer health: kind 0 = the page's process crashed or was killed, 1 = it stopped responding,
  // 2 = it recovered. While a page is unresponsive, ResolveHung(id, kill) ends the wait.
  using RendererCallback = std::function<void(int browser_id, int kind, int status)>;
  void set_renderer_callback(RendererCallback cb) { on_renderer_ = std::move(cb); }
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int error_code,
                                 const CefString& error_string) override;
  bool OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefUnresponsiveProcessCallback> callback) override;
  void OnRenderProcessResponsive(CefRefPtr<CefBrowser> browser) override;
  void ResolveHung(int browser_id, bool kill);

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
  ZapCallback on_zap_;
  LoadEndCallback on_load_end_;
  LoadingCallback on_loading_;
  LangCallback on_lang_;
  NotifyCallback on_notify_;
  FaviconCallback on_favicon_;
  StatusCallback on_status_;
  RendererCallback on_renderer_;
  std::map<int, CefRefPtr<CefUnresponsiveProcessCallback>> hung_;
  PermissionCallback on_permission_;
  ExternalCallback on_external_;
  CaptureCallback on_capture_;
  AutofillCallback on_autofill_;
  struct AutofillFrame {
    int browser_id = 0;
    std::string frame_id;
    std::string origin;
    bool main_frame = false;
  };
  std::map<std::string, AutofillFrame> autofill_frames_;   // nonce -> frame
  std::map<std::string, std::string> autofill_nonces_;     // "<browser>/<frame>/<origin>" -> nonce
  std::map<int, CefRefPtr<CefBrowser>> browsers_;
  void InjectAutofillShim(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame);
  struct PendingPermission {
    CefRefPtr<CefMediaAccessCallback> media;
    uint32_t media_bits = 0;
    CefRefPtr<CefPermissionPromptCallback> prompt;
    uint64_t prompt_id = 0;
    uint32_t prompt_bits = 0;
    int browser_id = 0;
    std::string origin;
  };
  std::map<int, PendingPermission> pending_permissions_;
  // A prompt NotArc just allowed, per browser, until the next run-loop turn. Chromium answers Allow synchronously, and
  // for Meet's <usermedia> button it can then show the SAME, already granted requests again (its "ask macOS" step):
  // allowing that second prompt makes Chromium grant a request twice and crash (CHECK in
  // PermissionRequest::PermissionGranted). Such a re-shown prompt is ignored instead; the page keeps its grant.
  struct JustAllowed {
    std::string origin;
    uint32_t bits = 0;
    int gen = 0;
  };
  std::map<int, JustAllowed> just_allowed_;
  int just_allowed_gen_ = 0;
  int next_permission_id_ = 1;
  int open_browsers_ = 0;
  bool quit_when_empty_ = false;

  IMPLEMENT_REFCOUNTING(BrowserClient);
};
