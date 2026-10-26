#import "app/live_folder.h"

@implementation LiveFolderEntry
@end

NSString* LiveFolderFetchURL(NSString* kind, NSString* source) {
  if ([kind isEqualToString:@"github-prs"] || [kind isEqualToString:@"github-issues"]) {
    NSString* what = [kind isEqualToString:@"github-prs"] ? @"pulls" : @"issues";
    return [NSString stringWithFormat:@"https://api.github.com/repos/%@/%@?state=open&per_page=30", source, what];
  }
  return source;
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
  NSURL* url = [NSURL URLWithString:LiveFolderFetchURL(kind, source) ?: @""];
  if (!url) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(nil, @"Bad address"); });
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
