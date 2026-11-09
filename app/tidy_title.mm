#import "app/tidy_title.h"

static NSString* Trimmed(NSString* s) {
  return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

// Lowercase letters and digits only: "Google Docs" -> "googledocs".
static NSString* Squashed(NSString* s) {
  NSMutableString* out = [NSMutableString string];
  for (NSUInteger i = 0; i < s.length; ++i) {
    unichar c = [s.lowercaseString characterAtIndex:i];
    if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:c]) [out appendFormat:@"%C", c];
  }
  return out;
}

// "mail.google.com" -> "google"; "news.ycombinator.com" -> "ycombinator"; "bbc.co.uk" -> "bbc".
static NSString* SiteName(NSString* host) {
  NSArray<NSString*>* parts = [host.lowercaseString componentsSeparatedByString:@"."];
  if (parts.count < 2) return host.lowercaseString ?: @"";
  NSSet* secondLevel = [NSSet setWithArray:@[ @"co", @"com", @"org", @"net", @"gov", @"ac", @"edu" ]];
  NSUInteger i = parts.count - 2;
  if (i > 0 && parts[parts.count - 1].length == 2 && [secondLevel containsObject:parts[i]]) --i;
  return parts[i];
}

// A segment that only names the site, an account or a generic place adds nothing to a pinned tab's name.
static BOOL IsBoilerplate(NSString* segment, NSString* host) {
  NSString* sq = Squashed(segment);
  if (!sq.length) return YES;
  NSString* site = Squashed(SiteName(host ?: @""));
  NSString* fullHost = Squashed(host ?: @"");
  if (site.length >= 3 && ([sq isEqualToString:site] || [sq hasPrefix:site] || [site hasPrefix:sq] ||
                           [sq isEqualToString:fullHost]))
    return YES;
  if ([segment rangeOfString:@"@"].location != NSNotFound && [segment rangeOfString:@" "].location == NSNotFound)
    return YES;  // an e-mail address (Gmail: "Inbox - me@example.com - Gmail")
  return NO;
}

NSString* TidyTabTitle(NSString* title, NSString* host) {
  NSString* t = Trimmed(title ?: @"");
  if (!t.length) return title;
  // Unread counts and markers in front: "(3) Inbox", "[12] Feed", "• Slack".
  NSRegularExpression* lead = [NSRegularExpression regularExpressionWithPattern:@"^(\\(\\d+\\+?\\)|\\[\\d+\\+?\\]|[•●*])\\s*"
                                                                        options:0 error:nil];
  t = Trimmed([lead stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@""]);
  // Split on the separators sites put between the page and the site name. " - " needs spaces around it so
  // hyphenated words survive; "·", "|", "—", "–", "•" and "::" do too.
  NSRegularExpression* sep = [NSRegularExpression regularExpressionWithPattern:@"\\s+(?:[|·•—–-]|::)\\s+" options:0 error:nil];
  NSMutableArray<NSString*>* segments = [NSMutableArray array];
  __block NSUInteger start = 0;
  [sep enumerateMatchesInString:t options:0 range:NSMakeRange(0, t.length)
                     usingBlock:^(NSTextCheckingResult* r, NSMatchingFlags, BOOL*) {
                       [segments addObject:Trimmed([t substringWithRange:NSMakeRange(start, r.range.location - start)])];
                       start = NSMaxRange(r.range);
                     }];
  [segments addObject:Trimmed([t substringFromIndex:start])];
  NSMutableArray<NSString*>* kept = [NSMutableArray array];
  for (NSString* s in segments)
    if (!IsBoilerplate(s, host)) [kept addObject:s];
  if (!kept.count) return t.length ? t : title;  // the whole title is the site's name: keep it as it is
  // Keep the first meaningful segment: sites put the page's own name first ("Pull requests · GitHub").
  NSString* out = kept.firstObject;
  // Trailing unread counts: "Inbox (3)".
  NSRegularExpression* trail = [NSRegularExpression regularExpressionWithPattern:@"\\s*\\(\\d+\\+?\\)$" options:0 error:nil];
  out = Trimmed([trail stringByReplacingMatchesInString:out options:0 range:NSMakeRange(0, out.length) withTemplate:@""]);
  return out.length ? out : title;
}
