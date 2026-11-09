// Tidy tab titles (#18): Arc renames pinned tabs to short, clean names. NotArc does it on the Mac without AI:
// it drops unread counts, the site's own name, e-mail addresses and other boilerplate segments of a page title.
// One function, so an on-device model can replace it later (#58) without touching the callers.
#pragma once

#import <Foundation/Foundation.h>

// Returns a shorter title for a tab, or `title` itself when nothing can safely be removed. `host` is the page's
// host ("github.com"); it tells which segment is the site's name. Pure function, no I/O.
NSString* TidyTabTitle(NSString* title, NSString* host);
