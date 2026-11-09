// Email peeking (#44): Arc's "Peek Email" finds the newest email a site just sent you (a sign-in code or link) in
// Gmail, copies the code or shows the email in a Peek. NotArc reads Gmail's own unread-mail feed with the Space's
// Gmail sign-in (no OAuth app); these are the pure parts, so tests need no network.
#pragma once

#import <Foundation/Foundation.h>

extern NSString* const kGmailFeedURL;  // unread inbox messages, Atom

// Entries of a Gmail Atom feed: dictionaries with title, summary, name, email, link, issued (NSDate), newest first.
NSArray<NSDictionary*>* GmailFeedEntries(NSData* atom);
// The newest entry sent by `host`'s site (sender domain), or naming it, within `maxAge` seconds of `now`.
NSDictionary* EmailPeekMatch(NSArray<NSDictionary*>* entries, NSString* host, NSDate* now, NSTimeInterval maxAge);
// A one-time code in an email's subject or preview ("Your code is 482913", "G-123456"), or nil.
NSString* AuthCodeInText(NSString* text);
