#include "app/browser_client.h"
#import "app/downloads.h"

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
