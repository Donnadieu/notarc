#import "app/live_folder.h"

@implementation LiveFolderEntry
@end

NSString* const kLiveFolderGitHubSignInURL = @"https://github.com/login?return_to=https%3A%2F%2Fgithub.com%2Fpulls";
NSString* const kLiveFolderGitHubNoneURL = @"https://github.com/pulls";

static NSDictionary<NSString*, NSString*>* gTestPages;
void LiveFolderSetTestPages(NSDictionary<NSString*, NSString*>* pages) { gTestPages = [pages copy]; }
BOOL LiveFolderTestPagesActive(void) { return gTestPages != nil; }
NSData* LiveFolderTestPage(NSString* url) {
  NSString* path = url ? gTestPages[url] : nil;
  return path ? [NSData dataWithContentsOfFile:path] : nil;
}

NSString* LiveFolderFetchURL(NSString* kind, NSString* source) {
  if ([kind isEqualToString:@"github-prs"] || [kind isEqualToString:@"github-issues"]) {
    NSString* what = [kind isEqualToString:@"github-prs"] ? @"pulls" : @"issues";
    return [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@?state=open&per_page=30", source, what];
  }
  if ([kind isEqualToString:@"github-mine"]) return LiveFolderGitHubMineURLs().firstObject;
  if ([kind isEqualToString:@"youtube"])
    return [NSString stringWithFormat:@"https://www.youtube.com/feeds/videos.xml?channel_id=%@",
                                      [source stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet]];
  return source;
}

NSArray<NSString*>* LiveFolderGitHubMineURLs(void) {
  // GitHub's own search pages, as a signed-in user sees them: open, not archived, most recently updated first.
  return @[
    @"https://github.com/search?q=is%3Apr+is%3Aopen+archived%3Afalse+author%3A%40me&type=pullrequests&s=updated&o=desc",
    @"https://github.com/search?q=is%3Apr+is%3Aopen+archived%3Afalse+review-requested%3A%40me&type=pullrequests&s=updated&o=desc",
  ];
}

static NSString* DecodeHTMLText(NSString* s) {
  if (![s containsString:@"&"]) return s;
  NSDictionary* named = @{@"amp" : @"&", @"lt" : @"<", @"gt" : @">", @"quot" : @"\"", @"apos" : @"'", @"nbsp" : @" "};
  NSMutableString* out = [NSMutableString string];
  NSUInteger i = 0, n = s.length;
  while (i < n) {
    NSRange amp = [s rangeOfString:@"&" options:0 range:NSMakeRange(i, n - i)];
    if (amp.location == NSNotFound) { [out appendString:[s substringFromIndex:i]]; break; }
    [out appendString:[s substringWithRange:NSMakeRange(i, amp.location - i)]];
    NSRange semi = [s rangeOfString:@";" options:0 range:NSMakeRange(amp.location, MIN((NSUInteger)10, n - amp.location))];
    NSString* ent = semi.location != NSNotFound ? [s substringWithRange:NSMakeRange(amp.location + 1, semi.location - amp.location - 1)] : nil;
    NSString* rep = ent ? named[ent] : nil;
    if (!rep && [ent hasPrefix:@"#"] && ent.length > 1) {
      BOOL hex = [ent hasPrefix:@"#x"] || [ent hasPrefix:@"#X"];
      unsigned long long v = strtoull([ent substringFromIndex:hex ? 2 : 1].UTF8String, NULL, hex ? 16 : 10);
      UTF32Char c = (UTF32Char)v;
      if (v > 0 && v < 0x110000) rep = [[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding];
    }
    if (rep) {
      [out appendString:rep];
      i = semi.location + 1;
    } else {
      [out appendString:@"&"];
      i = amp.location + 1;
    }
  }
  return out;
}

// Visible text of an HTML fragment: tags dropped, entities decoded, whitespace collapsed.
static NSString* HTMLFragmentText(NSString* html) {
  static NSRegularExpression* tags, *space;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:nil];
    space = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
  });
  NSString* t = [tags stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, html.length) withTemplate:@" "];
  t = DecodeHTMLText(t);
  t = [space stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "];
  return [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

static NSString* PullTitle(NSString* title, NSString* repo, NSString* number, BOOL review) {
  NSString* t = [NSString stringWithFormat:@"%@ · %@#%@", title, repo, number];
  return review ? [@"Review: " stringByAppendingString:t] : t;
}

// Pull requests in GitHub's page data (React pages embed JSON): any object with a pull request URL and a title.
static void CollectPullsFromJSON(id node, NSRegularExpression* pullURL, NSMutableArray* found, int depth) {
  if (depth > 40 || found.count > 200) return;
  if ([node isKindOfClass:NSArray.class]) {
    for (id c in node) CollectPullsFromJSON(c, pullURL, found, depth + 1);
  } else if ([node isKindOfClass:NSDictionary.class]) {
    NSDictionary* d = node;
    if ([d[@"title"] isKindOfClass:NSString.class]) {
      for (NSString* key in @[ @"permalink", @"url", @"html_url", @"path" ]) {
        NSString* u = d[key];
        if (![u isKindOfClass:NSString.class]) continue;
        NSTextCheckingResult* m = [pullURL firstMatchInString:u options:0 range:NSMakeRange(0, u.length)];
        if (!m || m.range.length != u.length) continue;
        [found addObject:@[ [u substringWithRange:[m rangeAtIndex:1]], [u substringWithRange:[m rangeAtIndex:2]],
                            [u substringWithRange:[m rangeAtIndex:3]], d[@"title"] ]];
        break;
      }
    }
    for (id c in d.allValues) CollectPullsFromJSON(c, pullURL, found, depth + 1);
  }
}

NSArray<LiveFolderEntry*>* LiveFolderParseGitHubHTML(NSString* html, NSUInteger limit, BOOL review, BOOL* signedIn) {
  if (signedIn) *signedIn = NO;
  if (!html.length) return nil;
  // Every github.com page names the signed-in user here; it's empty for visitors.
  NSRegularExpression* login = [NSRegularExpression regularExpressionWithPattern:@"<meta\\s+name=\"user-login\"\\s+content=\"([^\"]*)\""
                                                                         options:NSRegularExpressionCaseInsensitive error:nil];
  NSTextCheckingResult* lm = [login firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
  if (!lm) return nil;  // not a github.com page
  if (signedIn) *signedIn = [lm rangeAtIndex:1].length > 0;
  NSMutableArray<LiveFolderEntry*>* out = [NSMutableArray array];
  NSMutableDictionary<NSString*, LiveFolderEntry*>* byURL = [NSMutableDictionary dictionary];
  void (^add)(NSString*, NSString*, NSString*, NSString*) = ^(NSString* owner, NSString* repo, NSString* num, NSString* title) {
    NSString* url = [NSString stringWithFormat:@"https://github.com/%@/%@/pull/%@", owner, repo, num];
    if (byURL[url] || out.count >= limit) return;
    LiveFolderEntry* e = [LiveFolderEntry new];
    e.url = url;
    e.title = PullTitle(title, repo, num, review);
    byURL[url] = e;
    [out addObject:e];
  };
  // Server-rendered results: the link to the pull request whose text is its title (number-only links skipped).
  NSRegularExpression* anchor = [NSRegularExpression
      regularExpressionWithPattern:@"<a\\b[^>]*?\\bhref=\"(?:https://github\\.com)?/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/(\\d+)\"[^>]*>(.*?)</a>"
                           options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
  NSRegularExpression* numberOnly = [NSRegularExpression regularExpressionWithPattern:@"^#?\\d+$" options:0 error:nil];
  for (NSTextCheckingResult* m in [anchor matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
    NSString* text = HTMLFragmentText([html substringWithRange:[m rangeAtIndex:4]]);
    if (!text.length || [numberOnly numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)]) continue;
    add([html substringWithRange:[m rangeAtIndex:1]], [html substringWithRange:[m rangeAtIndex:2]],
        [html substringWithRange:[m rangeAtIndex:3]], text);
  }
  if (!out.count) {  // client-rendered pages: read the embedded page data instead
    NSRegularExpression* script = [NSRegularExpression regularExpressionWithPattern:@"<script type=\"application/json\"[^>]*>(.*?)</script>"
        options:NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators error:nil];
    NSRegularExpression* pullURL = [NSRegularExpression
        regularExpressionWithPattern:@"^(?:https://github\\.com)?/([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)/pull/(\\d+)$" options:0 error:nil];
    NSMutableArray* found = [NSMutableArray array];
    for (NSTextCheckingResult* m in [script matchesInString:html options:0 range:NSMakeRange(0, html.length)]) {
      NSData* d = [[html substringWithRange:[m rangeAtIndex:1]] dataUsingEncoding:NSUTF8StringEncoding];
      id json = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
      if (json) CollectPullsFromJSON(json, pullURL, found, 0);
    }
    for (NSArray* f in found) add(f[0], f[1], f[2], f[3]);
  }
  return out;
}

BOOL LiveFolderIsGitHubSignedInLanding(NSString* url) {
  NSURL* u = [NSURL URLWithString:url ?: @""];
  if (![u.host.lowercaseString isEqualToString:@"github.com"]) return NO;
  for (NSString* p in @[ @"/login", @"/session", @"/signup", @"/password_reset", @"/join" ])
    if ([u.path hasPrefix:p]) return NO;
  return YES;
}

NSString* LiveFolderYouTubeChannelIDFromHTML(NSString* html, NSString** name) {
  if (name) *name = nil;
  if (!html.length) return nil;
  NSString* idPat = @"(UC[0-9A-Za-z_-]{22})";
  NSArray* patterns = @[
    [NSString stringWithFormat:@"<link rel=\"canonical\" href=\"https://www\\.youtube\\.com/channel/%@\"", idPat],
    [NSString stringWithFormat:@"<meta itemprop=\"identifier\" content=\"%@\"", idPat],
    [NSString stringWithFormat:@"<meta itemprop=\"channelId\" content=\"%@\"", idPat],
    [NSString stringWithFormat:@"\"externalId\":\"%@\"", idPat],
    [NSString stringWithFormat:@"\"channelId\":\"%@\"", idPat],
  ];
  NSString* found = nil;
  for (NSString* p in patterns) {
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:p options:0 error:nil];
    NSTextCheckingResult* m = [re firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (m) { found = [html substringWithRange:[m rangeAtIndex:1]]; break; }
  }
  if (found && name) {
    NSRegularExpression* og = [NSRegularExpression regularExpressionWithPattern:@"<meta property=\"og:title\" content=\"([^\"]*)\"" options:0 error:nil];
    NSTextCheckingResult* m = [og firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
    if (m) *name = DecodeHTMLText([html substringWithRange:[m rangeAtIndex:1]]);
  }
  return found;
}

void LiveFolderResolveYouTube(NSString* pageURL, void (^done)(NSString* channelID, NSString* name, NSString* error)) {
  NSURL* url = [NSURL URLWithString:pageURL ?: @""];
  void (^finish)(NSData*, NSString*) = ^(NSData* data, NSString* err) {
    NSString* html = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSString* name = nil;
    NSString* cid = LiveFolderYouTubeChannelIDFromHTML(html, &name);
    dispatch_async(dispatch_get_main_queue(), ^{ done(cid, name, cid ? nil : (err ?: @"Couldn't find that YouTube channel")); });
  };
  if (!url) { finish(nil, @"Bad address"); return; }
  if (LiveFolderTestPagesActive()) { finish(LiveFolderTestPage(pageURL), @"No network in self-tests"); return; }
  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:20];
  // A desktop browser's page (it has the channel id), past YouTube's cookie-consent page.
  [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Safari/537.36"
      forHTTPHeaderField:@"User-Agent"];
  [req setValue:@"SOCS=CAI" forHTTPHeaderField:@"Cookie"];
  [[NSURLSession.sharedSession dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
    finish(err ? nil : data, err.localizedDescription);
  }] resume];
}

// RSS 2.0 (<item><title><link>) and Atom (<entry><title><link href>).
@interface LiveFeedParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<LiveFolderEntry*>* entries;
@property(nonatomic) NSUInteger limit;
@end
@implementation LiveFeedParser {
  LiveFolderEntry* _cur;
  NSMutableString* _text;
  NSString* _atomAltLink;
}
- (void)parser:(NSXMLParser*)p didStartElement:(NSString*)el namespaceURI:(NSString*)ns qualifiedName:(NSString*)q
    attributes:(NSDictionary<NSString*, NSString*>*)attrs {
  NSString* name = el.lowercaseString;
  if ([name isEqualToString:@"item"] || [name isEqualToString:@"entry"]) {
    _cur = [LiveFolderEntry new];
    _atomAltLink = nil;
  } else if (_cur && [name isEqualToString:@"link"] && attrs[@"href"]) {
    NSString* rel = attrs[@"rel"];
    if (!rel || [rel isEqualToString:@"alternate"]) _atomAltLink = attrs[@"href"];
  }
  _text = [NSMutableString string];
}
- (void)parser:(NSXMLParser*)p foundCharacters:(NSString*)s { [_text appendString:s]; }
- (void)parser:(NSXMLParser*)p foundCDATA:(NSData*)d {
  NSString* s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  if (s) [_text appendString:s];
}
- (void)parser:(NSXMLParser*)p didEndElement:(NSString*)el namespaceURI:(NSString*)ns qualifiedName:(NSString*)q {
  NSString* name = el.lowercaseString;
  NSString* t = [_text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (_cur && [name isEqualToString:@"title"] && !_cur.title) _cur.title = t;
  else if (_cur && [name isEqualToString:@"link"] && t.length && !_cur.url) _cur.url = t;
  else if (_cur && ([name isEqualToString:@"item"] || [name isEqualToString:@"entry"])) {
    if (!_cur.url) _cur.url = _atomAltLink;
    NSURL* u = _cur.url ? [NSURL URLWithString:_cur.url] : nil;
    if (([u.scheme isEqualToString:@"https"] || [u.scheme isEqualToString:@"http"]) && self.entries.count < self.limit) {
      if (!_cur.title.length) _cur.title = _cur.url;
      [self.entries addObject:_cur];
    }
    _cur = nil;
  }
  _text = [NSMutableString string];
}
@end

NSArray<LiveFolderEntry*>* LiveFolderParse(NSString* kind, NSData* data, NSUInteger limit) {
  if (!data.length) return nil;
  NSMutableArray<LiveFolderEntry*>* out = [NSMutableArray array];
  if ([kind isEqualToString:@"github-mine"])
    return LiveFolderParseGitHubHTML([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding], limit, NO, NULL);
  if ([kind hasPrefix:@"github-"]) {
    NSArray* arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![arr isKindOfClass:NSArray.class]) return nil;
    BOOL issuesOnly = [kind isEqualToString:@"github-issues"];
    for (NSDictionary* d in arr) {
      if (![d isKindOfClass:NSDictionary.class]) continue;
      if (issuesOnly && d[@"pull_request"]) continue;  // the issues API also lists PRs
      NSString* url = d[@"html_url"], *title = d[@"title"];
      if (![url isKindOfClass:NSString.class] || ![url hasPrefix:@"https://github.com/"]) continue;
      LiveFolderEntry* e = [LiveFolderEntry new];
      e.url = url;
      NSNumber* num = [d[@"number"] isKindOfClass:NSNumber.class] ? d[@"number"] : nil;
      e.title = [title isKindOfClass:NSString.class] ? (num ? [NSString stringWithFormat:@"#%@ %@", num, title] : title) : url;
      [out addObject:e];
      if (out.count >= limit) break;
    }
    return out;
  }
  NSXMLParser* p = [[NSXMLParser alloc] initWithData:data];
  p.shouldResolveExternalEntities = NO;
  LiveFeedParser* d = [LiveFeedParser new];
  d.entries = out;
  d.limit = limit;
  p.delegate = d;
  if (![p parse] && !out.count) return nil;
  return out;
}

void LiveFolderFetch(NSString* kind, NSString* source, NSUInteger limit,
                     void (^done)(NSArray<LiveFolderEntry*>* entries, NSString* error)) {
  NSString* address = LiveFolderFetchURL(kind, source);
  NSURL* url = [NSURL URLWithString:address ?: @""];
  if (!url) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"Bad address"); });
    return;
  }
  if (LiveFolderTestPagesActive() && ![url.scheme isEqualToString:@"file"]) {  // self-tests never reach the network
    NSArray* entries = LiveFolderParse(kind, LiveFolderTestPage(address), limit);
    dispatch_async(dispatch_get_main_queue(), ^{ done(entries, entries ? nil : @"No network in self-tests"); });
    return;
  }
  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:20];
  if ([kind hasPrefix:@"github-"]) [req setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
  [req setValue:@"NotArc Live Folders" forHTTPHeaderField:@"User-Agent"];
  [[NSURLSession.sharedSession dataTaskWithRequest:req
                                 completionHandler:^(NSData* data, NSURLResponse* resp, NSError* err) {
    NSInteger status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)resp).statusCode : 200;
    NSArray* entries = (!err && status < 400) ? LiveFolderParse(kind, data, limit) : nil;
    NSString* msg = entries ? nil
                    : (err ? err.localizedDescription
                           : (status >= 400 ? [NSString stringWithFormat:@"The server answered %ld", (long)status]
                                            : @"Couldn't read the feed"));
    dispatch_async(dispatch_get_main_queue(), ^{ done(entries, msg); });
  }] resume];
}

NSDictionary* LiveFolderSourceFromInput(NSString* input, BOOL issues) {
  NSString* s = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!s.length) return nil;
  // YouTube: a channel address ("/channel/UC..." has the id; "/@name", "/c/name", "/user/name" or a video need a look).
  NSRegularExpression* handle = [NSRegularExpression regularExpressionWithPattern:@"^@[A-Za-z0-9._-]{1,100}$" options:0 error:nil];
  if ([handle numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)])
    return @{@"kind" : @"youtube", @"resolve" : [@"https://www.youtube.com/" stringByAppendingString:s]};
  NSURL* yu = [NSURL URLWithString:[s containsString:@"://"] ? s : [@"https://" stringByAppendingString:s]];
  NSString* yhost = yu.host.lowercaseString;
  if ([yhost isEqualToString:@"youtube.com"] || [yhost hasSuffix:@".youtube.com"] || [yhost isEqualToString:@"youtu.be"]) {
    NSArray<NSString*>* parts = [yu.path componentsSeparatedByString:@"/"];  // "", "channel", "UC..."
    NSRegularExpression* cid = [NSRegularExpression regularExpressionWithPattern:@"^UC[0-9A-Za-z_-]{22}$" options:0 error:nil];
    if (parts.count >= 3 && [parts[1] isEqualToString:@"channel"] &&
        [cid numberOfMatchesInString:parts[2] options:0 range:NSMakeRange(0, parts[2].length)])
      return @{@"kind" : @"youtube", @"source" : parts[2]};
    if ([yu.path hasPrefix:@"/feeds/videos.xml"]) return @{@"kind" : @"feed", @"source" : yu.absoluteString};
    if (parts.count < 2 || !parts[1].length) return nil;  // youtube.com itself isn't a channel
    NSURLComponents* c = [NSURLComponents new];
    c.scheme = @"https";
    c.host = [yhost isEqualToString:@"youtu.be"] ? @"youtu.be" : @"www.youtube.com";
    c.percentEncodedPath = yu.path;
    c.percentEncodedQuery = yu.query;
    return @{@"kind" : @"youtube", @"resolve" : c.URL.absoluteString ?: @""};
  }
  NSString* gh = nil;
  for (NSString* prefix in @[ @"https://github.com/", @"http://github.com/", @"github.com/" ])
    if ([s.lowercaseString hasPrefix:prefix]) gh = [s substringFromIndex:prefix.length];
  NSRegularExpression* repo = [NSRegularExpression regularExpressionWithPattern:@"^([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)"
                                                                        options:0 error:nil];
  if (!gh && ![s containsString:@":"] && ![s containsString:@"."]) gh = s;  // bare owner/repo
  if (gh) {
    NSTextCheckingResult* m = [repo firstMatchInString:gh options:0 range:NSMakeRange(0, gh.length)];
    if (!m) return nil;
    NSString* name = [NSString stringWithFormat:@"%@/%@", [gh substringWithRange:[m rangeAtIndex:1]],
                                                [[gh substringWithRange:[m rangeAtIndex:2]] stringByReplacingOccurrencesOfString:@".git" withString:@""]];
    BOOL wantIssues = issues || [gh containsString:@"/issues"];
    return @{@"kind" : wantIssues ? @"github-issues" : @"github-prs", @"source" : name};
  }
  if (![s containsString:@"://"]) s = [@"https://" stringByAppendingString:s];
  NSURL* u = [NSURL URLWithString:s];
  if (!([u.scheme isEqualToString:@"https"] || [u.scheme isEqualToString:@"http"] || [u.scheme isEqualToString:@"file"])) return nil;
  if (!u.host.length && ![u.scheme isEqualToString:@"file"]) return nil;
  return @{@"kind" : @"feed", @"source" : u.absoluteString};
}
