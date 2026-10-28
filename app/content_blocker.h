// Built-in ad and tracker blocking (#53): Settings > Block ads & trackers, with a per-site exception in Site Settings.
// Requests from a page to a known ad or tracking host are cancelled before they load. Pages themselves (the main
// frame) and requests to the page's own site are never blocked.
#pragma once

#include <string>
#include <vector>

namespace content_blocker {

void SetEnabled(bool enabled);
bool Enabled();
// Hosts (e.g. "example.com") where blocking is turned off; matches subdomains too.
void SetExceptions(const std::vector<std::string>& hosts);
// url: the request; page_url: the page that asked for it (first party); main_frame: a page navigation.
bool ShouldBlock(const std::string& url, const std::string& page_url, bool main_frame);
// True when `host` is on the block list (exact host or a subdomain of a listed one).
bool IsListedHost(const std::string& host);
size_t ListSize();

}  // namespace content_blocker
