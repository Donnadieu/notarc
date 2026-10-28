#include "app/content_blocker.h"

#include <atomic>
#include <mutex>
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
std::mutex g_mutex;
std::vector<std::string> g_exceptions;

const std::unordered_set<std::string>& Listed() {
  static const auto* set = new std::unordered_set<std::string>(std::begin(kHosts), std::end(kHosts));
  return *set;
}

std::string HostOf(const std::string& url) {
  NSURL* u = [NSURL URLWithString:[NSString stringWithUTF8String:url.c_str()]];
  return u.host ? std::string(u.host.lowercaseString.UTF8String) : std::string();
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

}  // namespace

void SetEnabled(bool enabled) { g_enabled = enabled; }
bool Enabled() { return g_enabled; }

void SetExceptions(const std::vector<std::string>& hosts) {
  std::lock_guard<std::mutex> lock(g_mutex);
  g_exceptions = hosts;
}

bool IsListedHost(const std::string& host) {
  const auto& listed = Listed();
  std::string h = host;
  while (!h.empty()) {
    if (listed.count(h)) return true;
    size_t dot = h.find('.');
    if (dot == std::string::npos) break;
    h = h.substr(dot + 1);
  }
  return false;
}

size_t ListSize() { return Listed().size(); }

bool ShouldBlock(const std::string& url, const std::string& page_url, bool main_frame) {
  if (!g_enabled || main_frame) return false;
  if (url.compare(0, 4, "http") != 0 && url.compare(0, 2, "ws") != 0) return false;
  std::string host = HostOf(url);
  if (host.empty() || !IsListedHost(host)) return false;
  std::string page = HostOf(page_url);
  if (!page.empty()) {
    if (SiteOf(page) == SiteOf(host)) return false;  // a site's own requests are first-party
    std::lock_guard<std::mutex> lock(g_mutex);
    for (const auto& e : g_exceptions)
      if (SameOrSubdomain(page, e)) return false;
  }
  return true;
}

}  // namespace content_blocker
