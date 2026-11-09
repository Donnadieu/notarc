#import "app/email_peek.h"

NSString* const kGmailFeedURL = @"https://mail.google.com/mail/u/0/feed/atom";

@interface GmailFeedParser : NSObject <NSXMLParserDelegate>
@property(nonatomic, strong) NSMutableArray<NSDictionary*>* entries;
@property(nonatomic, strong) NSMutableDictionary* current;
@property(nonatomic, strong) NSMutableString* text;
@end
@implementation GmailFeedParser
- (void)parser:(NSXMLParser*)p didStartElement:(NSString*)el namespaceURI:(NSString*)ns qualifiedName:(NSString*)q
    attributes:(NSDictionary<NSString*, NSString*>*)attrs {
  if ([el isEqualToString:@"entry"]) self.current = [NSMutableDictionary dictionary];
  if ([el isEqualToString:@"link"] && self.current && attrs[@"href"]) self.current[@"link"] = attrs[@"href"];
  self.text = [NSMutableString string];
}
- (void)parser:(NSXMLParser*)p foundCharacters:(NSString*)s { [self.text appendString:s]; }
- (void)parser:(NSXMLParser*)p didEndElement:(NSString*)el namespaceURI:(NSString*)ns qualifiedName:(NSString*)q {
  NSString* t = [self.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
  if (!self.current) return;
  if ([el isEqualToString:@"entry"]) {
    [self.entries addObject:self.current];
    self.current = nil;
  } else if ([@[ @"title", @"summary", @"name", @"email" ] containsObject:el]) {
    self.current[el] = t;
  } else if ([el isEqualToString:@"issued"] || [el isEqualToString:@"modified"]) {
    NSISO8601DateFormatter* f = [NSISO8601DateFormatter new];
    NSDate* d = [f dateFromString:t];
    if (d && !self.current[@"issued"]) self.current[@"issued"] = d;
  }
}
@end

NSArray<NSDictionary*>* GmailFeedEntries(NSData* atom) {
  if (!atom.length) return @[];
  GmailFeedParser* g = [GmailFeedParser new];
  g.entries = [NSMutableArray array];
  NSXMLParser* p = [[NSXMLParser alloc] initWithData:atom];
  p.delegate = g;
  [p parse];
  return [g.entries sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    return [(b[@"issued"] ?: NSDate.distantPast) compare:(a[@"issued"] ?: NSDate.distantPast)];
  }];
}

// "accounts.example.co.uk" -> "example"
static NSString* SiteWord(NSString* host) {
  NSArray<NSString*>* parts = [host.lowercaseString componentsSeparatedByString:@"."];
  if (parts.count < 2) return host.lowercaseString;
  NSUInteger i = parts.count - 2;
  if (i > 0 && parts.lastObject.length == 2 && parts[i].length <= 3) --i;
  return parts[i];
}

NSDictionary* EmailPeekMatch(NSArray<NSDictionary*>* entries, NSString* host, NSDate* now, NSTimeInterval maxAge) {
  NSString* site = SiteWord(host ?: @"");
  if (site.length < 2) return nil;
  for (NSDictionary* e in entries) {
    NSDate* when = e[@"issued"];
    if (when && maxAge > 0 && [now timeIntervalSinceDate:when] > maxAge) continue;
    NSString* domain = [[[e[@"email"] ?: @"" componentsSeparatedByString:@"@"] lastObject] lowercaseString];
    BOOL fromSite = domain.length && [SiteWord(domain) isEqualToString:site];
    NSString* words = [NSString stringWithFormat:@"%@ %@", e[@"name"] ?: @"", e[@"title"] ?: @""].lowercaseString;
    if (fromSite || [words rangeOfString:site].location != NSNotFound) return e;
  }
  return nil;
}

NSString* AuthCodeInText(NSString* text) {
  if (!text.length) return nil;
  // Prefer a code right after a "code"-like word, then any standalone 4-8 digit number (not a year or a time).
  NSArray<NSString*>* patterns = @[
    @"(?i)(?:code|c[oó]digo|passcode|pin|otp|verification|one-time)[^0-9A-Z]{0,24}([0-9]{4,8}|[A-Z0-9]{3,4}-[A-Z0-9]{3,4})",
    @"\\b[A-Z]-([0-9]{4,8})\\b",  // "G-123456"
    @"(?<![0-9:.,/-])([0-9]{6})(?![0-9:.,/-])",
    @"(?<![0-9:.,/-])([0-9]{4,8})(?![0-9:.,/-])",
  ];
  for (NSString* pat in patterns) {
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    for (NSTextCheckingResult* m in [re matchesInString:text options:0 range:NSMakeRange(0, text.length)]) {
      NSString* code = [text substringWithRange:[m rangeAtIndex:1]];
      NSInteger n = code.integerValue;
      BOOL year = code.length == 4 && n >= 1900 && n <= 2100;
      if (!year) return code;
    }
  }
  return nil;
}
