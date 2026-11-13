#include "app/browser_client.h"
#import "app/downloads.h"
#import "app/arc_max.h"
#include "app/content_blocker.h"
#import "app/autofill.h"

#include <atomic>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <iterator>
#include <mutex>

#include "include/cef_app.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/base/cef_callback.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_stream_resource_handler.h"

BrowserClient::BrowserClient(TitleCallback on_title, UrlCallback on_url)
    : on_title_(std::move(on_title)), on_url_(std::move(on_url)) {}

void BrowserClient::OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) {
  CEF_REQUIRE_UI_THREAD();
  if (on_title_) on_title_(browser->GetIdentifier(), title.ToString());
}

void BrowserClient::OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& icon_urls) {
  CEF_REQUIRE_UI_THREAD();
  if (on_favicon_ && !icon_urls.empty()) on_favicon_(browser->GetIdentifier(), icon_urls.front().ToString());
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
  browsers_[browser->GetIdentifier()] = browser;
}

void BrowserClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  int id = browser->GetIdentifier();
  browsers_.erase(id);
  for (auto it = autofill_frames_.begin(); it != autofill_frames_.end();)
    it = it->second.browser_id == id ? autofill_frames_.erase(it) : std::next(it);
  std::string prefix = std::to_string(id) + "/";
  for (auto it = autofill_nonces_.begin(); it != autofill_nonces_.end();)
    it = it->first.compare(0, prefix.size(), prefix) == 0 ? autofill_nonces_.erase(it) : std::next(it);
  if (--open_browsers_ == 0 && quit_when_empty_) CefQuitMessageLoop();
}

CefResourceRequestHandler::ReturnValue BrowserClient::OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                                                             CefRefPtr<CefFrame> frame,
                                                                             CefRefPtr<CefRequest> request,
                                                                             CefRefPtr<CefCallback> callback) {
  if (!content_blocker::Enabled()) return RV_CONTINUE;
  bool main_frame = request->GetResourceType() == RT_MAIN_FRAME;
  std::string page = request->GetFirstPartyForCookies().ToString();
  if (page.empty() && frame) page = frame->GetURL().ToString();
  const char* type = "other";  // filter-list resource types ($script, $image, ...)
  switch (request->GetResourceType()) {
    case RT_SCRIPT: case RT_WORKER: case RT_SHARED_WORKER: case RT_SERVICE_WORKER: type = "script"; break;
    case RT_IMAGE: case RT_FAVICON: type = "image"; break;
    case RT_STYLESHEET: type = "stylesheet"; break;
    case RT_SUB_FRAME: type = "subdocument"; break;
    case RT_FONT_RESOURCE: type = "font"; break;
    case RT_MEDIA: type = "media"; break;
    case RT_XHR: type = "xmlhttprequest"; break;
    case RT_PING: case RT_CSP_REPORT: type = "ping"; break;
    case RT_OBJECT: case RT_PLUGIN_RESOURCE: type = "object"; break;
    default: break;
  }
  return content_blocker::ShouldBlock(request->GetURL().ToString(), page, main_frame, type) ? RV_CANCEL : RV_CONTINUE;
}

namespace {
std::mutex g_test_responses_lock;
std::map<std::string, std::string>* g_test_responses = nullptr;  // url prefix -> html (self-tests only)
}  // namespace

void BrowserClient::SetTestResponse(const std::string& url_prefix, const std::string& html) {
  std::lock_guard<std::mutex> lock(g_test_responses_lock);
  if (!g_test_responses) g_test_responses = new std::map<std::string, std::string>();
  if (html.empty()) g_test_responses->erase(url_prefix);
  else (*g_test_responses)[url_prefix] = html;
}

CefRefPtr<CefResourceHandler> BrowserClient::GetResourceHandler(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>,
                                                                CefRefPtr<CefRequest> request) {
  std::string body, type = "text/html";
  {
    std::lock_guard<std::mutex> lock(g_test_responses_lock);
    if (!g_test_responses || g_test_responses->empty()) return nullptr;
    std::string url = request->GetURL().ToString();
    for (auto& [prefix, html] : *g_test_responses)
      if (url.rfind(prefix, 0) == 0) {
        body = html;
        auto ends = [&](const char* ext) {
          size_t n = strlen(ext);
          return prefix.size() >= n && prefix.compare(prefix.size() - n, n, ext) == 0;
        };
        type = ends(".webm") ? "video/webm" : ends(".png") ? "image/png" : ends(".js") ? "text/javascript" : "text/html";  // media checks (V75-V80)
      }
  }
  if (body.empty()) return nullptr;
  CefRefPtr<CefStreamReader> stream = CefStreamReader::CreateForData(body.data(), body.size());  // copies
  return new CefStreamResourceHandler(type, stream);
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
  if (!on_link_menu_) return;
  bool image = params->GetMediaType() == CM_MEDIATYPE_IMAGE && !params->GetSourceUrl().empty();
  bool editable = (params->GetTypeFlags() & CM_TYPEFLAG_EDITABLE) != 0;
  auto items = MenuItemsFor(!params->GetLinkUrl().empty(), image, !params->GetSelectionText().empty(), editable,
                            params->GetSelectionText().ToString());
  if (items.empty()) return;
  int at = 0;
  for (auto& [command, title] : items) {
    if (command < 0) model->InsertSeparatorAt(at++);
    else model->InsertItemAt(at++, MENU_ID_USER_FIRST + command, title);
  }
  model->InsertSeparatorAt(at);
}

std::vector<std::pair<int, std::string>> BrowserClient::MenuItemsFor(bool link, bool image, bool selection, bool editable,
                                                                    const std::string& selectionText) {
  std::vector<std::pair<int, std::string>> out;
  auto sep = [&] { if (!out.empty() && out.back().first >= 0) out.push_back({-1, ""}); };
  if (link) {
    out.push_back({kLinkNewTab, "Open Link in New Tab"});
    out.push_back({kLinkBackgroundTab, "Open Link in Background Tab"});
    out.push_back({kLinkSplit, "Open Link in Split View"});
    out.push_back({kLinkPeek, "Open Link in Peek"});
    out.push_back({kLinkLittle, "Open Link in Little Window"});
    out.push_back({kLinkCopyMarkdown, "Copy Link as Markdown"});
  }
  if (image) {
    sep();
    out.push_back({kImageOpen, "Open Image in New Tab"});
    out.push_back({kImageSave, "Save Image to Downloads"});
    out.push_back({kImageCopy, "Copy Image"});
    out.push_back({kImageCopyAddress, "Copy Image Address"});
  }
  if (selection && !editable) {
    sep();
    std::string shown = selectionText.size() > 24 ? selectionText.substr(0, 22) + "\u2026" : selectionText;
    for (auto& c : shown) if (c == '\n' || c == '\t') c = ' ';
    out.push_back({kSelectionSearch, "Search for \u201C" + shown + "\u201D"});
  }
  if (!link && !image && !selection && !editable) {
    out.push_back({kPageCopyURL, "Copy Page URL"});
    out.push_back({kPageCopyMarkdown, "Copy Page URL as Markdown"});
    out.push_back({kPageCapture, "Capture Page"});
    out.push_back({kPageTranslate, "Translate Page"});
    out.push_back({kPageBoost, "Boost This Site..."});
  }
  return out;
}

bool BrowserClient::OnContextMenuCommand(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                         CefRefPtr<CefContextMenuParams> params, int command_id,
                                         EventFlags event_flags) {
  CEF_REQUIRE_UI_THREAD();
  int command = command_id - MENU_ID_USER_FIRST;
  if (!on_link_menu_ || command < 0 || command >= kLinkCount) return false;
  std::string url = command <= kLinkCopyMarkdown ? params->GetLinkUrl().ToString()
                    : command <= kImageSave      ? params->GetSourceUrl().ToString()
                                                 : params->GetPageUrl().ToString();
  on_link_menu_(browser->GetIdentifier(), command, url, params->GetSelectionText().ToString());
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

// CEF's Alloy pages have no notification service, so a page's notifications would vanish. This shim (run as each
// http(s) document starts) keeps the page's own Notification API and permission flow, and also reports each
// notification to NotArc, which shows it in Notification Center if the site is allowed.
const char* BrowserClient::NotificationShimJS() {
  return "(function(){if(window.__notarcNotify)return;window.__notarcNotify=1;var N=window.Notification;if(!N)return;"
         "function send(t,o){o=o||{};try{console.log('__notarc_notify__:'+JSON.stringify({title:String(t||''),"
         "body:String(o.body||''),tag:String(o.tag||'')}));}catch(e){}}"
         "function S(t,o){send(t,o);this.title=String(t||'');o=o||{};this.body=o.body||'';this.tag=o.tag||'';"
         "this.data=o.data;this.onclick=null;this.onclose=null;this.onerror=null;this.onshow=null;var s=this;"
         "setTimeout(function(){if(typeof s.onshow==='function')try{s.onshow();}catch(e){}},0);}"
         "S.prototype.close=function(){};S.prototype.addEventListener=function(){};"
         "S.prototype.removeEventListener=function(){};S.prototype.dispatchEvent=function(){return true;};"
         "Object.defineProperty(S,'permission',{get:function(){return N.permission;}});"
         "S.requestPermission=function(){return N.requestPermission.apply(N,arguments);};S.maxActions=0;"
         "window.Notification=S;var R=window.ServiceWorkerRegistration;"
         "if(R&&R.prototype.showNotification){R.prototype.showNotification=function(t,o){send(t,o);return Promise.resolve();};}"
         "})();";
}

void BrowserClient::OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) {
  CEF_REQUIRE_UI_THREAD();
  std::string url = frame->GetURL().ToString();
  if (url.rfind("http://", 0) == 0 || url.rfind("https://", 0) == 0) frame->ExecuteJavaScript(NotificationShimJS(), url, 0);
  InjectAutofillShim(browser, frame);
}

void BrowserClient::OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) {
  if (frame->IsMain() && on_load_end_) on_load_end_(browser->GetIdentifier(), frame->GetURL().ToString());
  InjectAutofillShim(browser, frame);  // no-op if OnLoadStart's copy is already running in this document
}

static bool g_autofill_allow_file = false;
void BrowserClient::SetAutofillAllowFileURLs(bool allow) { g_autofill_allow_file = allow; }

// "https://Example.com:8443/path" -> "https://example.com:8443"; "" for anything that isn't a web page.
static std::string AutofillOrigin(const std::string& url) {
  size_t colon = url.find("://");
  if (colon == std::string::npos) return "";
  std::string scheme = url.substr(0, colon);
  for (auto& c : scheme) c = static_cast<char>(tolower(c));
  if (scheme == "file") return g_autofill_allow_file ? "file://" : "";
  if (scheme != "http" && scheme != "https") return "";
  size_t start = colon + 3, end = url.find_first_of("/?#", start);
  std::string host = url.substr(start, end == std::string::npos ? std::string::npos : end - start);
  size_t at = host.rfind('@');
  if (at != std::string::npos) host = host.substr(at + 1);
  for (auto& c : host) c = static_cast<char>(tolower(c));
  if ((scheme == "https" && host.size() > 4 && host.compare(host.size() - 4, 4, ":443") == 0) ||
      (scheme == "http" && host.size() > 3 && host.compare(host.size() - 3, 3, ":80") == 0))
    host = host.substr(0, host.rfind(':'));
  return host.empty() ? "" : scheme + "://" + host;
}

void BrowserClient::InjectAutofillShim(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame) {
  if (!browser || !frame || !frame->IsValid()) return;
  std::string url = frame->GetURL().ToString();
  std::string origin = AutofillOrigin(url);
  if (origin.empty()) return;
  int id = browser->GetIdentifier();
  std::string frame_id = frame->GetIdentifier().ToString();
  std::string key = std::to_string(id) + "/" + frame_id + "/" + origin;
  std::string nonce;
  auto found = autofill_nonces_.find(key);
  if (found != autofill_nonces_.end()) {
    nonce = found->second;
  } else {
    if (autofill_frames_.size() > 20000) {  // frames of long-lived tabs; start over rather than grow forever
      autofill_frames_.clear();
      autofill_nonces_.clear();
    }
    char buf[33];
    std::snprintf(buf, sizeof(buf), "%08x%08x%08x%08x", arc4random(), arc4random(), arc4random(), arc4random());
    nonce = buf;
    autofill_nonces_[key] = nonce;
    autofill_frames_[nonce] = AutofillFrame{id, frame_id, origin, frame->IsMain()};
  }
  frame->ExecuteJavaScript(AutofillShimScript(nonce), url, 0);
}

bool BrowserClient::AutofillRun(const std::string& nonce, const std::string& js) {
  auto it = autofill_frames_.find(nonce);
  if (it == autofill_frames_.end()) return false;
  CefRefPtr<CefBrowser> browser = BrowserById(it->second.browser_id);
  CefRefPtr<CefFrame> frame = browser ? browser->GetFrameByIdentifier(it->second.frame_id) : nullptr;
  if (!frame || !frame->IsValid() || AutofillOrigin(frame->GetURL().ToString()) != it->second.origin) return false;
  frame->ExecuteJavaScript(js, frame->GetURL(), 0);
  return true;
}

void BrowserClient::AutofillRunAllFrames(int browser_id, const std::string& js) {
  CefRefPtr<CefBrowser> browser = BrowserById(browser_id);
  if (!browser) return;
  std::vector<CefString> ids;
  browser->GetFrameIdentifiers(ids);
  for (const CefString& fid : ids) {
    CefRefPtr<CefFrame> f = browser->GetFrameByIdentifier(fid);
    if (f && f->IsValid() && !AutofillOrigin(f->GetURL().ToString()).empty()) f->ExecuteJavaScript(js, f->GetURL(), 0);
  }
}

CefRefPtr<CefBrowser> BrowserClient::BrowserById(int browser_id) {
  auto it = browsers_.find(browser_id);
  return it == browsers_.end() ? nullptr : it->second;
}

bool BrowserClient::OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t, const CefString& message,
                                     const CefString& source, int) {
  static const std::string kPrefix = "__notarc_media__:";
  static const std::string kNotify = "__notarc_notify__:";
  static const std::string kZap = "__notarc_zap__:";
  static const std::string kLang = "__notarc_lang__:";
  static const std::string kAutofill = "__notarc_af__:";
  std::string m = message.ToString();
  if (m.compare(0, kAutofill.size(), kAutofill) == 0) {  // never logged: may carry a password being saved
    size_t sep = m.find(':', kAutofill.size());
    if (sep == std::string::npos) return true;
    std::string nonce = m.substr(kAutofill.size(), sep - kAutofill.size());
    auto it = autofill_frames_.find(nonce);
    if (it != autofill_frames_.end() && it->second.browser_id == browser->GetIdentifier() && on_autofill_)
      on_autofill_(browser->GetIdentifier(), nonce, it->second.origin, it->second.main_frame, m.substr(sep + 1));
    return true;
  }
  if (m.compare(0, kNotify.size(), kNotify) == 0) {
    if (on_notify_) on_notify_(browser->GetIdentifier(), m.substr(kNotify.size()), source.ToString());
    return true;
  }
  if (m.compare(0, kLang.size(), kLang) == 0) {
    if (on_lang_) on_lang_(browser->GetIdentifier(), m.substr(kLang.size()));
    return true;
  }
  // Max page scripts (#58, #59) reply as "__notarc_max__:<nonce>:..." lines.
  if (m.compare(0, 15, "__notarc_max__:") == 0) {
    if (NSString* line = [NSString stringWithUTF8String:m.c_str()]) MaxHandleConsoleMessage(line);
    return true;
  }
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

static std::mutex g_perm_log_lock;
static std::string* g_perm_log_path = nullptr;
void BrowserClient::SetPermissionLogPath(const std::string& path) {
  std::lock_guard<std::mutex> lock(g_perm_log_lock);
  delete g_perm_log_path;
  g_perm_log_path = path.empty() ? nullptr : new std::string(path);
}
void BrowserClient::LogPermission(const char* fmt, ...) {
  std::lock_guard<std::mutex> lock(g_perm_log_lock);
  if (!g_perm_log_path) return;
  FILE* f = std::fopen(g_perm_log_path->c_str(), "a");
  if (!f) return;
  if (std::ftell(f) > 512 * 1024) {  // keep it small: start over, the old one kept once
    std::fclose(f);
    std::rename(g_perm_log_path->c_str(), (*g_perm_log_path + ".old").c_str());
    f = std::fopen(g_perm_log_path->c_str(), "a");
    if (!f) return;
  }
  time_t now = time(nullptr);
  char stamp[32];
  strftime(stamp, sizeof stamp, "%Y-%m-%d %H:%M:%S", localtime(&now));
  std::fprintf(f, "%s ", stamp);
  va_list args;
  va_start(args, fmt);
  std::vfprintf(f, fmt, args);
  va_end(args);
  std::fputc('\n', f);
  std::fclose(f);  // written now: a crash right after must not lose it
}

static std::atomic<bool> g_refuse_device_media{false};
void BrowserClient::SetRefuseDeviceMediaForTest(bool refuse) { g_refuse_device_media = refuse; }

bool BrowserClient::OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
                                                   const CefString& origin, uint32_t requested,
                                                   CefRefPtr<CefMediaAccessCallback> callback) {
  CEF_REQUIRE_UI_THREAD();
  if (g_refuse_device_media) {
    LogPermission("media refused (test) requested=%u origin=%s", requested, origin.ToString().c_str());
    callback->Cancel();
    return true;
  }
  if (!on_permission_) return false;
  uint32_t perms = 0;
  if (requested & (CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE))
    perms |= CEF_PERMISSION_TYPE_CAMERA_STREAM;
  if (requested & (CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE | CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE))
    perms |= CEF_PERMISSION_TYPE_MIC_STREAM;
  int id = next_permission_id_++;
  LogPermission("media id=%d browser=%d requested=%u origin=%s", id, browser->GetIdentifier(), requested, origin.ToString().c_str());
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
  LogPermission("prompt id=%d prompt=%llu browser=%d requested=%u origin=%s", id, (unsigned long long)prompt_id,
                browser->GetIdentifier(), requested, origin.ToString().c_str());
  if (getenv("NOTARC_PROMPT_DEBUG"))
    std::fprintf(stderr, "PROMPT-SHOW browser=%d prompt=%llu id=%d bits=%u origin=%s\n", browser->GetIdentifier(),
                 (unsigned long long)prompt_id, id, requested, origin.ToString().c_str());
  PendingPermission p;
  p.prompt = callback;
  p.prompt_id = prompt_id;
  pending_permissions_[id] = p;
  on_permission_(browser->GetIdentifier(), id, origin.ToString(), requested);
  return true;
}

void BrowserClient::OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t prompt_id, cef_permission_request_result_t result) {
  CEF_REQUIRE_UI_THREAD();
  LogPermission("dismissed prompt=%llu result=%d", (unsigned long long)prompt_id, result);
  if (getenv("NOTARC_PROMPT_DEBUG")) std::fprintf(stderr, "PROMPT-DISMISS prompt=%llu result=%d\n", (unsigned long long)prompt_id, result);
  for (auto it = pending_permissions_.begin(); it != pending_permissions_.end(); ++it)
    if (it->second.prompt && it->second.prompt_id == prompt_id) {
      pending_permissions_.erase(it);  // Chromium gave up on it (page closed or navigated)
      return;
    }
}

void BrowserClient::ResolvePermission(int request_id, bool allow) {
  auto it = pending_permissions_.find(request_id);
  if (it == pending_permissions_.end()) {
    LogPermission("answer id=%d %s: no longer pending", request_id, allow ? "allow" : "deny");
    return;
  }
  PendingPermission p = it->second;
  pending_permissions_.erase(it);
  LogPermission("answer id=%d prompt=%llu %s %s", request_id, (unsigned long long)p.prompt_id, allow ? "allow" : "deny",
                p.media ? "media" : "prompt");
  if (getenv("NOTARC_PROMPT_DEBUG"))
    std::fprintf(stderr, "PROMPT-ANSWER id=%d prompt=%llu allow=%d media=%d\n", request_id, (unsigned long long)p.prompt_id, allow,
                 p.media != nullptr);
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
