#include "app/browser_client.h"
#import "app/downloads.h"

#include <cstdio>

#include "include/cef_app.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/base/cef_callback.h"
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

void BrowserClient::OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count,
                                 const CefRect& selection_rect, int active_match_ordinal, bool final_update) {
  CEF_REQUIRE_UI_THREAD();
  if (final_update && on_find_) on_find_(browser->GetIdentifier(), count, active_match_ordinal);
}

void BrowserClient::OnGotFocus(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  if (on_focus_) on_focus_(browser->GetIdentifier());
}

bool BrowserClient::OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request, bool user_gesture, bool is_redirect) {
  CEF_REQUIRE_UI_THREAD();
  if (!navigation_filter_ || !user_gesture || is_redirect || !frame->IsMain()) return false;
  return navigation_filter_(browser->GetIdentifier(), request->GetURL().ToString());
}

static bool IsTabOrWindowDisposition(cef_window_open_disposition_t d) {
  return d == CEF_WOD_NEW_FOREGROUND_TAB || d == CEF_WOD_NEW_BACKGROUND_TAB || d == CEF_WOD_NEW_WINDOW;
}

bool BrowserClient::OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                     const CefString& target_url, WindowOpenDisposition target_disposition,
                                     bool user_gesture) {
  CEF_REQUIRE_UI_THREAD();
  if (!on_open_ || !IsTabOrWindowDisposition(target_disposition)) return false;
  return on_open_(browser->GetIdentifier(), target_url.ToString(), target_disposition, user_gesture);
}

bool BrowserClient::OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                                  const CefString& target_url, const CefString& target_frame_name,
                                  WindowOpenDisposition target_disposition, bool user_gesture,
                                  const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                                  CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                                  CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) {
  CEF_REQUIRE_UI_THREAD();
  if (!on_open_ || !IsTabOrWindowDisposition(target_disposition)) return false;  // NEW_POPUP stays a popup
  return on_open_(browser->GetIdentifier(), target_url.ToString(), target_disposition, user_gesture);
}

void BrowserClient::OnBeforeContextMenu(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                        CefRefPtr<CefContextMenuParams> params, CefRefPtr<CefMenuModel> model) {
  CEF_REQUIRE_UI_THREAD();
  if (!on_link_menu_ || params->GetLinkUrl().empty()) return;
  static const char* kTitles[kLinkCount] = {"Open Link in New Tab",   "Open Link in Background Tab",
                                            "Open Link in Split View", "Open Link in Peek",
                                            "Open Link in Little Window", "Copy Link as Markdown"};
  int at = 0;
  for (int i = 0; i < kLinkCount; ++i) model->InsertItemAt(at++, MENU_ID_USER_FIRST + i, kTitles[i]);
  model->InsertSeparatorAt(at);
}

bool BrowserClient::OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                         CefRefPtr<CefContextMenuParams> params, int command_id,
                                         EventFlags event_flags) {
  CEF_REQUIRE_UI_THREAD();
  int command = command_id - MENU_ID_USER_FIRST;
  if (!on_link_menu_ || command < 0 || command >= kLinkCount) return false;
  on_link_menu_(browser->GetIdentifier(), command, params->GetLinkUrl().ToString(),
                params->GetSelectionText().ToString());
  return true;
}

bool BrowserClient::OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                                     const CefString& suggested_name, CefRefPtr<CefBeforeDownloadCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  callback->Continue(DownloadsDestination(suggested_name.ToString()), false);
  return true;
}

void BrowserClient::OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> download_item,
                                      CefRefPtr<CefDownloadItemCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  DownloadsUpdated(download_item, callback);
}

void BrowserClient::OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) {
  if (frame->IsMain() && on_load_end_) on_load_end_(browser->GetIdentifier(), frame->GetURL().ToString());
}

bool BrowserClient::OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t, const CefString& message,
                                     const CefString&, int) {
  static const std::string kPrefix = "__notarc_media__:";
  static const std::string kZap = "__notarc_zap__:";
  std::string m = message.ToString();
  if (m.compare(0, kZap.size(), kZap) == 0) {
    if (on_zap_) on_zap_(browser->GetIdentifier(), m.substr(kZap.size()));
    return true;
  }
  if (m.compare(0, kPrefix.size(), kPrefix) != 0) return false;
  std::string rest = m.substr(kPrefix.size());
  size_t bar = rest.find('|');
  std::string state = rest.substr(0, bar);
  std::string title = bar == std::string::npos ? "" : rest.substr(bar + 1);
  if (on_media_) on_media_(browser->GetIdentifier(), state, title);
  return true;
}

void BrowserClient::OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status, int,
                                              const CefString&) {
  CEF_REQUIRE_UI_THREAD();
  hung_.erase(browser->GetIdentifier());
  if (on_renderer_) on_renderer_(browser->GetIdentifier(), 0, static_cast<int>(status));
}

bool BrowserClient::OnRenderProcessUnresponsive(CefRefPtr<CefBrowser> browser,
                                                CefRefPtr<CefUnresponsiveProcessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!on_renderer_) return false;
  hung_[browser->GetIdentifier()] = callback;
  on_renderer_(browser->GetIdentifier(), 1, 0);
  return true;
}

void BrowserClient::OnRenderProcessResponsive(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  hung_.erase(browser->GetIdentifier());
  if (on_renderer_) on_renderer_(browser->GetIdentifier(), 2, 0);
}

void BrowserClient::ResolveHung(int browser_id, bool kill) {
  auto it = hung_.find(browser_id);
  if (it == hung_.end()) return;
  CefRefPtr<CefUnresponsiveProcessCallback> cb = it->second;
  hung_.erase(it);
  if (kill) cb->Terminate();
  else cb->Wait();
}

bool BrowserClient::OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                                   const CefString& origin, uint32_t requested,
                                                   CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!on_permission_) return false;
  uint32_t perms = 0;
  if (requested & (CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE))
    perms |= CEF_PERMISSION_TYPE_CAMERA_STREAM;
  if (requested & (CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE))
    perms |= CEF_PERMISSION_TYPE_MIC_STREAM;
  int id = next_permission_id_++;
  PendingPermission p;
  p.media = callback;
  p.media_bits = requested;
  pending_permissions_[id] = p;
  on_permission_(browser->GetIdentifier(), id, origin.ToString(), perms);
  return true;
}

bool BrowserClient::OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt_id, const CefString& origin,
                                           uint32_t requested, CefRefPtr<CefPermissionPromptCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (!on_permission_) return false;
  int id = next_permission_id_++;
  PendingPermission p;
  p.prompt = callback;
  p.prompt_id = prompt_id;
  pending_permissions_[id] = p;
  on_permission_(browser->GetIdentifier(), id, origin.ToString(), requested);
  return true;
}

void BrowserClient::OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t prompt_id, cef_permission_request_result_t) {
  CEF_REQUIRE_UI_THREAD();
  for (auto it = pending_permissions_.begin(); it != pending_permissions_.end(); ++it)
    if (it->second.prompt && it->second.prompt_id == prompt_id) {
      pending_permissions_.erase(it);  // Chromium gave up on it (page closed or navigated)
      return;
    }
}

void BrowserClient::ResolvePermission(int request_id, bool allow) {
  auto it = pending_permissions_.find(request_id);
  if (it == pending_permissions_.end()) return;
  PendingPermission p = it->second;
  pending_permissions_.erase(it);
  if (p.media) {
    if (allow) p.media->Continue(p.media_bits);
    else p.media->Cancel();
  } else if (p.prompt) {
    p.prompt->Continue(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
  }
}

void BrowserClient::OnProtocolExecution(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, CefRefPtr<CefRequest> request,
                                        bool& allow_os_execution) {
  allow_os_execution = false;  // NotArc asks first and opens it itself
  if (!browser || !on_external_) return;
  int id = browser->GetIdentifier();
  std::string url = request->GetURL().ToString();
  ExternalCallback cb = on_external_;
  CefPostTask(TID_UI, base::BindOnce([](ExternalCallback cb, int id, std::string url) { cb(id, url); }, cb, id, url));
}
