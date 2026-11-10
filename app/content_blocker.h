// Ad and tracker blocking (#53): Settings > Block ads & trackers, with a per-site exception in Site Settings.
// Requests from a page to a known ad or tracking host are cancelled before they load. Pages themselves (the main
// frame) and requests to the page's own site are never blocked.
// Two sources of rules: NotArc's own built-in host list, and filter lists the user subscribes to (Manage Ad
// Blockers...). Lists use a common subset of Adblock Plus syntax: "||host^" network rules with $third-party,
// $domain= and resource-type options, "@@" exceptions, and "##selector" / "domain##selector" cosmetic rules.
// Every function is thread-safe: the request filter runs off the main thread.
#pragma once

#include <string>
#include <vector>

namespace content_blocker {

void SetEnabled(bool enabled);
bool Enabled();
// NotArc's built-in host list (on by default; only used while blocking is on).
void SetBuiltInEnabled(bool enabled);
bool BuiltInEnabled();
// Hosts (e.g. "example.com") where blocking is turned off; matches subdomains too.
void SetExceptions(const std::vector<std::string>& hosts);
// url: the request; page_url: the page that asked for it (first party); main_frame: a page navigation.
// type: the Adblock Plus resource type ("script", "image", "stylesheet", "subdocument", "xmlhttprequest", "font",
// "media", "object", "ping", "websocket", "other"); nullptr = "other".
bool ShouldBlock(const std::string& url, const std::string& page_url, bool main_frame, const char* type = nullptr);
// True when `host` is on the built-in block list (exact host or a subdomain of a listed one).
bool IsListedHost(const std::string& host);
size_t ListSize();

// Subscribed filter lists. Parses the text of every turned-on list (slow for big lists: call it off the main thread)
// and swaps the result in. `counts` (optional) gets the number of rules NotArc understood in each text.
void SetFilterListTexts(const std::vector<std::string>& texts, std::vector<size_t>* counts = nullptr);
size_t CountSupportedRules(const std::string& text);
size_t FilterRuleCount();  // rules in effect from subscribed lists
// The "! Title: ..." header of a list, or "".
std::string ListTitle(const std::string& text);
// CSS that hides what the cosmetic rules match on `page_url` ("" when none apply, blocking is off, the page is a
// per-site exception, or a list exempts it with "@@||host^$document" / "$elemhide").
std::string CosmeticCSS(const std::string& page_url);

}  // namespace content_blocker
