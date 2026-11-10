#include "app/content_blocker.h"

#include <atomic>
#include <cctype>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

#import <Foundation/Foundation.h>

namespace content_blocker {
namespace {

// Well-known ad, ad-exchange and tracking hosts, written for NotArc (no third-party list is copied).
const char* const kHosts[] = {
    "2o7.net",
    "33across.com",
    "3lift.com",
    "adcolony.com",
    "adform.net",
    "adfox.ru",
    "adgrx.com",
    "adhese.com",
    "adition.com",
    "adlightning.com",
    "adnxs.com",
    "adroll.com",
    "ads-twitter.com",
    "ads.linkedin.com",
    "ads.pinterest.com",
    "ads.reddit.com",
    "ads.tiktok.com",
    "ads.yahoo.com",
    "adsafeprotected.com",
    "adservice.google.com",
    "adsrvr.org",
    "adsterra.com",
    "adtechus.com",
    "advertising.com",
    "agkn.com",
    "amazon-adsystem.com",
    "amplitude.com",
    "an.yandex.ru",
    "analytics.google.com",
    "analytics.tiktok.com",
    "analytics.twitter.com",
    "analytics.yahoo.com",
    "app-measurement.com",
    "applovin.com",
    "appnexus.com",
    "bat.bing.com",
    "bluekai.com",
    "branch.io",
    "casalemedia.com",
    "chartbeat.com",
    "chartbeat.net",
    "chartboost.com",
    "clarity.ms",
    "clean.gg",
    "clickadu.com",
    "clicky.com",
    "confiant-integrations.net",
    "connect.facebook.net",
    "contentsquare.net",
    "contextweb.com",
    "crazyegg.com",
    "criteo.com",
    "criteo.net",
    "crwdcntrl.net",
    "ct.pinterest.com",
    "decibelinsight.net",
    "demdex.net",
    "districtm.io",
    "doubleclick.net",
    "doubleverify.com",
    "emxdgt.com",
    "events.redditmedia.com",
    "everesttech.net",
    "exelator.com",
    "exoclick.com",
    "eyeota.net",
    "facebook.net",
    "flashtalking.com",
    "fullstory.com",
    "getclicky.com",
    "glassboxdigital.io",
    "google-analytics.com",
    "googleadservices.com",
    "googlesyndication.com",
    "googletagmanager.com",
    "googletagservices.com",
    "gumgum.com",
    "heap.io",
    "heapanalytics.com",
    "hilltopads.net",
    "histats.com",
    "hotjar.com",
    "hotjar.io",
    "hs-analytics.net",
    "hs-banner.com",
    "id5-sync.com",
    "improvedigital.com",
    "indexww.com",
    "inmobi.com",
    "innovid.com",
    "inspectlet.com",
    "juicyads.com",
    "kargo.com",
    "kissmetrics.com",
    "krxd.net",
    "liadm.com",
    "lijit.com",
    "lotame.com",
    "luckyorange.com",
    "mathtag.com",
    "mc.yandex.ru",
    "media.net",
    "mgid.com",
    "mixpanel.com",
    "moatads.com",
    "mouseflow.com",
    "nativo.com",
    "newrelic.com",
    "nr-data.net",
    "omtrdc.net",
    "onetag-sys.com",
    "openx.net",
    "optimizely.com",
    "outbrain.com",
    "pagead2.googlesyndication.com",
    "permutive.app",
    "permutive.com",
    "popads.net",
    "popcash.net",
    "propellerads.com",
    "pubmatic.com",
    "px.ads.linkedin.com",
    "quantcount.com",
    "quantserve.com",
    "quantummetric.com",
    "revcontent.com",
    "richaudience.com",
    "rlcdn.com",
    "rubiconproject.com",
    "scorecardresearch.com",
    "segment.com",
    "segment.io",
    "serving-sys.com",
    "sessioncam.com",
    "sharethrough.com",
    "sizmek.com",
    "smaato.net",
    "smartadserver.com",
    "smilewanted.com",
    "snap.licdn.com",
    "sovrn.com",
    "spotxchange.com",
    "springserve.com",
    "statcounter.com",
    "static.ads-twitter.com",
    "stickyadstv.com",
    "taboola.com",
    "tapad.com",
    "teads.tv",
    "trafficjunky.net",
    "tremorhub.com",
    "triplelift.com",
    "undertone.com",
    "unityads.unity3d.com",
    "usabilla.com",
    "vungle.com",
    "woopra.com",
    "yandexadexchange.net",
    "yieldlab.net",
    "yieldmo.com",
    "zedo.com",
    "zemanta.com",
    "zeotap.com"
};

std::atomic<bool> g_enabled{false};
std::atomic<bool> g_builtin{true};
std::mutex g_mutex;
std::vector<std::string> g_exceptions;

const std::unordered_set<std::string>& Listed() {
  static const auto* set = new std::unordered_set<std::string>(std::begin(kHosts), std::end(kHosts));
  return *set;
}

std::string HostOf(const std::string& url) {
  @autoreleasepool {
    NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
    return u.host ? std::string(u.host.lowercaseString.UTF8String) : std::string();
  }
}

bool SameOrSubdomain(const std::string& host, const std::string& base) {
  if (base.empty() || host.size() < base.size()) return false;
  if (host == base) return true;
  return host.size() > base.size() && host.compare(host.size() - base.size(), base.size(), base) == 0 &&
         host[host.size() - base.size() - 1] == '.';
}

// "news.example.co.uk" -> "example.co.uk"; good enough to tell first-party from third-party requests.
std::string SiteOf(const std::string& host) {
  size_t last = host.rfind('.');
  if (last == std::string::npos || last == 0) return host;
  size_t second = host.rfind('.', last - 1);
  if (second == std::string::npos) return host;
  std::string tail = host.substr(second + 1);
  static const char* kTwoPart[] = {"co.uk", "com.au", "co.jp", "com.br", "co.in", "co.nz", "com.mx", "co.za", "com.tr"};
  for (const char* t : kTwoPart)
    if (tail == t) {
      size_t third = second == 0 ? std::string::npos : host.rfind('.', second - 1);
      return third == std::string::npos ? host : host.substr(third + 1);
    }
  return tail;
}

// Calls f(suffix) for "a.b.c", "b.c", "c" until f returns true.
template <typename F>
bool AnySuffix(const std::string& host, F f) {
  size_t pos = 0;
  while (pos < host.size()) {
    if (f(host.substr(pos))) return true;
    size_t dot = host.find('.', pos);
    if (dot == std::string::npos) break;
    pos = dot + 1;
  }
  return false;
}

bool IsHttp(const std::string& url) {
  return url.compare(0, 7, "http://") == 0 || url.compare(0, 8, "https://") == 0;
}

// MARK: filter lists (Adblock Plus subset)

enum : uint32_t {
  kScript = 1 << 0, kImage = 1 << 1, kStylesheet = 1 << 2, kSubdocument = 1 << 3, kFont = 1 << 4, kMedia = 1 << 5,
  kXhr = 1 << 6, kPing = 1 << 7, kObject = 1 << 8, kWebsocket = 1 << 9, kOther = 1 << 10, kAllTypes = (1 << 11) - 1,
};

uint32_t TypeBit(const std::string& name) {
  static const std::pair<const char*, uint32_t> kTypes[] = {
      {"script", kScript}, {"image", kImage}, {"stylesheet", kStylesheet}, {"css", kStylesheet},
      {"subdocument", kSubdocument}, {"frame", kSubdocument}, {"font", kFont}, {"media", kMedia},
      {"xmlhttprequest", kXhr}, {"xhr", kXhr}, {"ping", kPing}, {"beacon", kPing}, {"object", kObject},
      {"object-subrequest", kObject}, {"websocket", kWebsocket}, {"other", kOther}, {"all", kAllTypes},
  };
  for (const auto& t : kTypes)
    if (name == t.first) return t.second;
  return 0;
}

struct NetRule {
  uint32_t types = kAllTypes;
  bool third_party_only = false;
  bool important = false;
  bool page_document = false;   // "@@...$document": the whole page is exempt
  bool page_elemhide = false;   // "@@...$elemhide": no cosmetic hiding on the page
  bool page_generichide = false;  // "@@...$generichide": no generic cosmetic hiding on the page
  std::vector<std::string> domains, not_domains;  // $domain=
};

struct HideRule {
  std::string selector;
  std::vector<std::string> not_domains;  // "~a.com##sel" or "b.com,~a.b.com##sel"
};

struct Engine {
  std::unordered_map<std::string, std::vector<NetRule>> block, allow;  // keyed by the rule's host
  std::vector<std::string> generic;                                      // "##sel" (after "#@#sel" removals)
  std::vector<HideRule> generic_except;                                  // "~a.com##sel"
  std::unordered_map<std::string, std::vector<HideRule>> specific;       // "a.com##sel"
  std::unordered_map<std::string, std::unordered_set<std::string>> unhide;  // "a.com#@#sel"
  std::string generic_css;                                               // cached CSS for `generic`
  size_t rules = 0;
};

std::shared_ptr<const Engine> g_engine;  // guarded by g_mutex

std::string Trim(const std::string& s) {
  size_t a = s.find_first_not_of(" \t\r\n");
  if (a == std::string::npos) return "";
  size_t b = s.find_last_not_of(" \t\r\n");
  return s.substr(a, b - a + 1);
}

std::string Lower(std::string s) {
  for (auto& c : s) c = (char)std::tolower((unsigned char)c);
  return s;
}

std::vector<std::string> Split(const std::string& s, char sep) {
  std::vector<std::string> out;
  size_t start = 0;
  while (true) {
    size_t p = s.find(sep, start);
    out.push_back(s.substr(start, p == std::string::npos ? std::string::npos : p - start));
    if (p == std::string::npos) break;
    start = p + 1;
  }
  return out;
}

bool ValidHost(const std::string& h) {
  if (h.empty() || h.find('.') == std::string::npos || h.front() == '.' || h.back() == '.') return false;
  for (char c : h)
    if (!(std::isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_')) return false;
  return true;
}

// Domain lists: "a.com|~b.com" ($domain=) or "a.com,~b.com" (cosmetic). Wildcard entries ("google.*") aren't
// supported: returns false so the rule is skipped.
bool ParseDomains(const std::string& list, char sep, std::vector<std::string>* yes, std::vector<std::string>* no) {
  for (std::string d : Split(list, sep)) {
    d = Lower(Trim(d));
    if (d.empty()) continue;
    bool neg = d[0] == '~';
    if (neg) d = d.substr(1);
    if (!ValidHost(d)) return false;
    (neg ? no : yes)->push_back(d);
  }
  return true;
}

// "||host^$options" or "@@||host^$options". Returns false for anything outside the subset.
bool ParseNetwork(std::string line, Engine* e) {
  bool allow = line.compare(0, 2, "@@") == 0;
  if (allow) line = line.substr(2);
  if (line.compare(0, 2, "||") != 0) return false;
  std::string options;
  size_t dollar = line.find('$');
  if (dollar != std::string::npos) {
    options = line.substr(dollar + 1);
    line = line.substr(0, dollar);
  }
  std::string host = line.substr(2);
  if (!host.empty() && host.back() == '|') host.pop_back();
  if (!host.empty() && host.back() == '^') host.pop_back();
  host = Lower(host);
  if (!ValidHost(host)) return false;  // paths, wildcards and partial hosts are outside the subset
  NetRule r;
  uint32_t include = 0, exclude = 0;
  for (std::string o : Split(options, ',')) {
    o = Lower(Trim(o));
    if (o.empty() || o == "match-case") continue;
    bool neg = o[0] == '~';
    std::string name = neg ? o.substr(1) : o;
    if (name == "third-party" || name == "3p") {
      if (neg) return false;  // first-party-only rules never apply: same-site requests are never blocked
      r.third_party_only = true;
    } else if (name == "first-party" || name == "1p") {
      return false;
    } else if (name.compare(0, 7, "domain=") == 0) {
      if (neg || !ParseDomains(name.substr(7), '|', &r.domains, &r.not_domains)) return false;
    } else if (name == "important" && !neg && !allow) {
      r.important = true;
    } else if (allow && !neg && (name == "document" || name == "doc")) {
      r.page_document = true;
    } else if (allow && !neg && (name == "elemhide" || name == "ehide")) {
      r.page_elemhide = true;
    } else if (allow && !neg && (name == "generichide" || name == "ghide")) {
      r.page_generichide = true;
    } else if (uint32_t bit = TypeBit(name)) {
      (neg ? exclude : include) |= bit;
    } else {
      return false;  // popup, csp, redirect, removeparam, ...: not supported, so the rule is skipped
    }
  }
  if (include) r.types = include;
  r.types &= ~exclude;
  bool page_only = r.page_document || r.page_elemhide || r.page_generichide;
  if (!r.types && !page_only) return false;
  if (page_only && !include) r.types = 0;  // "@@||x^$document" exempts pages, not requests
  (allow ? e->allow : e->block)[host].push_back(std::move(r));
  return true;
}

bool UnsupportedSelector(const std::string& s) {
  if (s.empty() || s.find('{') != std::string::npos || s.find('}') != std::string::npos ||
      s.find("</") != std::string::npos || s.compare(0, 4, "+js(") == 0)
    return true;
  static const char* kProcedural[] = {":-abp-", ":has-text(", ":contains(", ":xpath(", ":upward(", ":remove(", ":style(",
                                      ":matches-css", ":min-text-length(", ":watch-attr(", ":nth-ancestor(", ":others(",
                                      ":if(", ":if-not(", ":matches-path(", ":matches-attr(", ":matches-prop(",
                                      ":remove-attr(", ":remove-class(", ":shadow(", ":spath(", ":matches-media("};
  for (const char* p : kProcedural)
    if (s.find(p) != std::string::npos) return true;
  return false;
}

// "##sel", "a.com,b.com##sel", "~a.com##sel", "#@#sel", "a.com#@#sel".
bool ParseCosmetic(const std::string& line, Engine* e, std::unordered_set<std::string>* generic_unhide,
                   std::unordered_set<std::string>* generic_seen) {
  size_t at = line.find("#@#");
  bool unhide = at != std::string::npos;
  size_t hash = unhide ? at : line.find("##");
  if (hash == std::string::npos) return false;
  std::string domains = line.substr(0, hash);
  std::string sel = Trim(line.substr(hash + (unhide ? 3 : 2)));
  if (domains.find('#') != std::string::npos || UnsupportedSelector(sel)) return false;  // #?#, #$#, #%# ...
  std::vector<std::string> yes, no;
  if (!ParseDomains(domains, ',', &yes, &no)) return false;
  if (unhide) {
    if (yes.empty() && no.empty()) generic_unhide->insert(sel);
    for (const auto& d : yes) e->unhide[d].insert(sel);
    return true;
  }
  if (!yes.empty()) {
    for (const auto& d : yes) e->specific[d].push_back({sel, no});
  } else if (!no.empty()) {
    e->generic_except.push_back({sel, no});
  } else if (generic_seen->insert(sel).second) {
    e->generic.push_back(sel);
  }
  return true;
}

size_t ParseInto(const std::string& text, Engine* e, std::unordered_set<std::string>* generic_unhide,
                 std::unordered_set<std::string>* generic_seen) {
  size_t count = 0, start = 0;
  while (start < text.size()) {
    size_t nl = text.find('\n', start);
    std::string line = Trim(text.substr(start, nl == std::string::npos ? std::string::npos : nl - start));
    start = nl == std::string::npos ? text.size() : nl + 1;
    if (line.empty() || line[0] == '!' || line[0] == '[') continue;  // comments and the [Adblock Plus] header
    bool ok = (line.find("##") != std::string::npos || line.find("#@#") != std::string::npos)
                  ? ParseCosmetic(line, e, generic_unhide, generic_seen)
                  : ParseNetwork(line, e);
    if (ok) ++count;
  }
  return count;
}

void AppendHideRule(std::string* css, const std::string& sel) {
  // One rule per selector, so a selector this Chromium doesn't understand only drops itself.
  css->append(sel);
  css->append("{display:none!important}\n");
}

bool DomainMatches(const std::string& page_host, const std::vector<std::string>& list) {
  for (const auto& d : list)
    if (SameOrSubdomain(page_host, d)) return true;
  return false;
}

bool RuleApplies(const NetRule& r, uint32_t type, const std::string& page_host, bool third_party) {
  if (!(r.types & type)) return false;
  if (r.third_party_only && !third_party) return false;
  if (!r.domains.empty() && !DomainMatches(page_host, r.domains)) return false;
  if (!r.not_domains.empty() && DomainMatches(page_host, r.not_domains)) return false;
  return true;
}

// The first rule in `map` for `host` (or a parent domain) that applies, or nullptr.
const NetRule* Match(const std::unordered_map<std::string, std::vector<NetRule>>& map, const std::string& host,
                     uint32_t type, const std::string& page_host, bool third_party) {
  const NetRule* found = nullptr;
  if (map.empty()) return nullptr;
  AnySuffix(host, [&](const std::string& h) {
    auto it = map.find(h);
    if (it == map.end()) return false;
    for (const auto& r : it->second)
      if (RuleApplies(r, type, page_host, third_party)) {
        found = &r;
        return true;
      }
    return false;
  });
  return found;
}

// Page-level "@@||host^$document/$elemhide/$generichide" for the page host.
bool PageExempt(const Engine& e, const std::string& page_host, bool NetRule::*flag) {
  if (e.allow.empty()) return false;
  return AnySuffix(page_host, [&](const std::string& h) {
    auto it = e.allow.find(h);
    if (it == e.allow.end()) return false;
    for (const auto& r : it->second)
      if (r.*flag && (r.domains.empty() || DomainMatches(page_host, r.domains))) return true;
    return false;
  });
}

std::shared_ptr<const Engine> CurrentEngine() {
  std::lock_guard<std::mutex> lock(g_mutex);
  return g_engine;
}

bool UserException(const std::string& page_host) {
  std::lock_guard<std::mutex> lock(g_mutex);
  for (const auto& e : g_exceptions)
    if (SameOrSubdomain(page_host, e)) return true;
  return false;
}

}  // namespace

void SetEnabled(bool enabled) { g_enabled = enabled; }
bool Enabled() { return g_enabled; }
void SetBuiltInEnabled(bool enabled) { g_builtin = enabled; }
bool BuiltInEnabled() { return g_builtin; }

void SetExceptions(const std::vector<std::string>& hosts) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_exceptions = hosts;
}

bool IsListedHost(const std::string& host) {
  const auto& listed = Listed();
  return AnySuffix(host, [&](const std::string& h) { return listed.count(h) > 0; });
}

size_t ListSize() { return Listed().size(); }

bool ShouldBlock(const std::string& url, const std::string& page_url, bool main_frame, const char* type) {
  if (!g_enabled || main_frame) return false;
  bool ws = url.compare(0, 5, "ws://") == 0 || url.compare(0, 6, "wss://") == 0;
  if (!IsHttp(url) && !ws) return false;
  std::string host = HostOf(url);
  if (host.empty()) return false;
  std::string page = HostOf(page_url);
  bool third_party = page.empty() || SiteOf(page) != SiteOf(host);
  if (!third_party) return false;  // a site's own requests are first-party
  if (!page.empty() && UserException(page)) return false;
  uint32_t bit = ws ? kWebsocket : TypeBit(type ? type : "other");
  if (!bit || bit == kAllTypes) bit = kOther;
  std::shared_ptr<const Engine> e = CurrentEngine();
  if (e && !page.empty() && PageExempt(*e, page, &NetRule::page_document)) return false;
  const NetRule* rule = e ? Match(e->block, host, bit, page, third_party) : nullptr;
  bool blocked = rule || (g_builtin && IsListedHost(host));
  if (!blocked) return false;
  if (rule && rule->important) return true;
  return !(e && Match(e->allow, host, bit, page, third_party));
}

size_t CountSupportedRules(const std::string& text) {
  Engine scratch;
  std::unordered_set<std::string> unhide, seen;
  return ParseInto(text, &scratch, &unhide, &seen);
}

void SetFilterListTexts(const std::vector<std::string>& texts, std::vector<size_t>* counts) {
  auto e = std::make_shared<Engine>();
  std::unordered_set<std::string> generic_unhide, seen;
  for (const auto& t : texts) {
    size_t n = ParseInto(t, e.get(), &generic_unhide, &seen);
    e->rules += n;
    if (counts) counts->push_back(n);
  }
  if (!generic_unhide.empty()) {
    std::vector<std::string> kept;
    for (auto& s : e->generic)
      if (!generic_unhide.count(s)) kept.push_back(std::move(s));
    e->generic.swap(kept);
  }
  for (const auto& s : e->generic) AppendHideRule(&e->generic_css, s);
  std::shared_ptr<const Engine> done = texts.empty() ? nullptr : std::move(e);
  std::lock_guard<std::mutex> lock(g_mutex);
  g_engine = std::move(done);
}

size_t FilterRuleCount() {
  auto e = CurrentEngine();
  return e ? e->rules : 0;
}

std::string ListTitle(const std::string& text) {
  size_t start = 0;
  for (int i = 0; i < 40 && start < text.size(); ++i) {  // headers sit at the top
    size_t nl = text.find('\n', start);
    std::string line = Trim(text.substr(start, nl == std::string::npos ? std::string::npos : nl - start));
    start = nl == std::string::npos ? text.size() : nl + 1;
    if (line.compare(0, 8, "! Title:") == 0) return Trim(line.substr(8));
  }
  return "";
}

std::string CosmeticCSS(const std::string& page_url) {
  if (!g_enabled || !IsHttp(page_url)) return "";
  std::shared_ptr<const Engine> e = CurrentEngine();
  if (!e) return "";
  std::string host = HostOf(page_url);
  if (host.empty() || UserException(host)) return "";
  if (PageExempt(*e, host, &NetRule::page_document) || PageExempt(*e, host, &NetRule::page_elemhide)) return "";
  std::unordered_set<std::string> unhide;  // "a.com#@#sel" for this page
  AnySuffix(host, [&](const std::string& h) {
    auto it = e->unhide.find(h);
    if (it != e->unhide.end()) unhide.insert(it->second.begin(), it->second.end());
    return false;
  });
  std::string css;
  if (!PageExempt(*e, host, &NetRule::page_generichide)) {
    if (unhide.empty()) {
      css = e->generic_css;
    } else {
      for (const auto& s : e->generic)
        if (!unhide.count(s)) AppendHideRule(&css, s);
    }
    for (const auto& r : e->generic_except)
      if (!DomainMatches(host, r.not_domains) && !unhide.count(r.selector)) AppendHideRule(&css, r.selector);
  }
  AnySuffix(host, [&](const std::string& h) {
    auto it = e->specific.find(h);
    if (it == e->specific.end()) return false;
    for (const auto& r : it->second)
      if (!unhide.count(r.selector) && !DomainMatches(host, r.not_domains)) AppendHideRule(&css, r.selector);
    return false;
  });
  return css;
}

}  // namespace content_blocker
