// Fetch a URL with a Space's own sign-ins (its CEF request context: cookies and logins), the way Arc read Gmail,
// Notion and Slack through their web apps instead of OAuth apps (#44 email peeking, #57 Favorite previews).
// Read-only GETs only. Call on the main (CEF UI) thread; `done` runs on the main thread.
#pragma once

#import <Foundation/Foundation.h>

#include "include/cef_request_context.h"

void SpaceFetch(CefRefPtr<CefRequestContext> context, NSString* url, NSDictionary<NSString*, NSString*>* headers,
                void (^done)(NSInteger status, NSData* body, NSString* finalURL));
