#import "app/link_routing.h"

@implementation LinkRule
@end

NSString* LinkRoutingPath(BOOL selfTest) {
  NSString* dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"];
  return [dir stringByAppendingPathComponent:selfTest ? @"SelfTestLinkRouting.json" : @"LinkRouting.json"];
}

// Swift enums in Arc's JSON: {"case": {"_0": payload, "_1": ...}}.
static NSString* CaseName(id v) {
  return [v isKindOfClass:NSDictionary.class] && [v count] ? [[v allKeys] firstObject] : nil;
}
static id Payload(id v, NSString* n) {
  NSString* c = CaseName(v);
  id inner = c ? v[c] : nil;
  return [inner isKindOfClass:NSDictionary.class] ? inner[n] : nil;
}

// destination {"space":{"_0":{"mostRecent":{}}}} | {"space":{"_0":{"specific":{"_0":id}}}} | {"littleArc":...}
static void ParseDestination(id d, NSString** kind, NSString** spaceID) {
  NSString* c = CaseName(d);
  *kind = [c isEqualToString:@"space"] ? @"space" : @"little";
  *spaceID = nil;
  id which = Payload(d, @"_0");
  if ([CaseName(which) isEqualToString:@"specific"]) {
    id p = which[@"specific"];
    id idv = [p isKindOfClass:NSDictionary.class] ? (p[@"_0"] ?: p[@"id"]) : p;
    if ([idv isKindOfClass:NSDictionary.class]) idv = idv[@"_0"] ?: idv[@"id"];
    if ([idv isKindOfClass:NSString.class]) *spaceID = idv;
  }
}

static NSString* HostOf(NSString* url) { return [NSURL URLWithString:url].host.lowercaseString ?: @""; }

BOOL LinkRuleMatchesURL(LinkRule* r, NSString* url) {
  if (!r.pattern.length) return YES;
  NSString* u = url.lowercaseString, *p = r.pattern.lowercaseString;
  NSString* bare = [u stringByReplacingOccurrencesOfString:@"https://" withString:@""];
  bare = [bare stringByReplacingOccurrencesOfString:@"http://" withString:@""];
  if ([bare hasPrefix:@"www."]) bare = [bare substringFromIndex:4];
  if ([r.matchType isEqualToString:@"exact"])
    return [u isEqualToString:p] || [bare isEqualToString:p] || [[bare stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/"]] isEqualToString:p];
  if ([r.matchType isEqualToString:@"startsWith"]) return [u hasPrefix:p] || [bare hasPrefix:p];
  if ([r.matchType isEqualToString:@"domain"]) {
    NSString* h = HostOf(url);
    return [h isEqualToString:p] || [h hasSuffix:[@"." stringByAppendingString:p]];
  }
  if ([r.matchType isEqualToString:@"regex"]) {
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:r.pattern options:NSRegularExpressionCaseInsensitive error:nil];
    return re && [re firstMatchInString:url options:0 range:NSMakeRange(0, url.length)] != nil;
  }
  return [u rangeOfString:p].location != NSNotFound;  // contains
}

@implementation LinkRouting

+ (instancetype)fromArcFile:(NSString*)path {
  NSData* data = [NSData dataWithContentsOfFile:path];
  NSDictionary* root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![root isKindOfClass:NSDictionary.class]) return nil;
  LinkRouting* lr = [LinkRouting new];
  NSString* kind, *sid;
  ParseDestination(root[@"defaultDestination"], &kind, &sid);
  lr.defaultDestination = root[@"defaultDestination"] ? kind : @"little";
  lr.defaultSpaceID = sid;
  NSMutableArray* rules = [NSMutableArray array];
  for (NSDictionary* r in [root[@"rules"] isKindOfClass:NSArray.class] ? root[@"rules"] : @[]) {
    if (![r isKindOfClass:NSDictionary.class]) continue;
    LinkRule* rule = [LinkRule new];
    ParseDestination(r[@"destination"], &kind, &sid);
    rule.destination = kind;
    rule.spaceID = sid;
    BOOL ok = NO;
    for (NSDictionary* comp in [r[@"sourceComponents"] isKindOfClass:NSArray.class] ? r[@"sourceComponents"] : @[]) {
      id t = [comp isKindOfClass:NSDictionary.class] ? comp[@"componentType"] : nil;
      NSString* c = CaseName(t);
      if ([c isEqualToString:@"urlMatch"]) {
        rule.matchType = CaseName(Payload(t, @"_0")) ?: @"contains";
        id pat = Payload(t, @"_1");
        if ([pat isKindOfClass:NSString.class]) { rule.pattern = pat; ok = YES; }
      } else if ([c isEqualToString:@"application"] || [c isEqualToString:@"sourceApplication"]) {
        id a = Payload(t, @"_0");
        if ([a isKindOfClass:NSDictionary.class]) a = a[@"bundleID"] ?: a[@"bundleIdentifier"];
        if ([a isKindOfClass:NSString.class]) { rule.sourceApp = a; ok = YES; }
      }
    }
    if (ok) [rules addObject:rule];
  }
  lr.rules = rules;
  return lr;
}

+ (instancetype)loadFrom:(NSString*)path {
  NSData* data = [NSData dataWithContentsOfFile:path];
  NSDictionary* root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if (![root isKindOfClass:NSDictionary.class]) return nil;
  LinkRouting* lr = [LinkRouting new];
  lr.defaultDestination = [root[@"default"] isEqualToString:@"space"] ? @"space" : @"little";
  lr.defaultSpaceID = [root[@"defaultSpace"] isKindOfClass:NSString.class] ? root[@"defaultSpace"] : nil;
  NSMutableArray* rules = [NSMutableArray array];
  for (NSDictionary* d in [root[@"rules"] isKindOfClass:NSArray.class] ? root[@"rules"] : @[]) {
    if (![d isKindOfClass:NSDictionary.class]) continue;
    LinkRule* r = [LinkRule new];
    r.matchType = d[@"match"] ?: @"contains";
    r.pattern = [d[@"pattern"] isKindOfClass:NSString.class] ? d[@"pattern"] : nil;
    r.sourceApp = [d[@"app"] isKindOfClass:NSString.class] ? d[@"app"] : nil;
    r.destination = [d[@"to"] isEqualToString:@"little"] ? @"little" : @"space";
    r.spaceID = [d[@"space"] isKindOfClass:NSString.class] ? d[@"space"] : nil;
    [rules addObject:r];
  }
  lr.rules = rules;
  return lr;
}

- (BOOL)saveTo:(NSString*)path {
  NSMutableArray* rules = [NSMutableArray array];
  for (LinkRule* r in self.rules) {
    NSMutableDictionary* d = [@{@"match" : r.matchType ?: @"contains", @"to" : r.destination ?: @"space"} mutableCopy];
    if (r.pattern) d[@"pattern"] = r.pattern;
    if (r.sourceApp) d[@"app"] = r.sourceApp;
    if (r.spaceID) d[@"space"] = r.spaceID;
    [rules addObject:d];
  }
  NSMutableDictionary* root = [@{@"version" : @1, @"default" : self.defaultDestination ?: @"little", @"rules" : rules} mutableCopy];
  if (self.defaultSpaceID) root[@"defaultSpace"] = self.defaultSpaceID;
  NSData* data = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
  return [data writeToFile:path atomically:YES];
}

- (LinkRule*)ruleForURL:(NSString*)url sourceApp:(NSString*)bundleID {
  for (LinkRule* r in self.rules) {
    if (r.sourceApp.length && ![r.sourceApp isEqualToString:bundleID]) continue;
    if (!r.pattern.length && !r.sourceApp.length) continue;
    if (LinkRuleMatchesURL(r, url)) return r;
  }
  return nil;
}
@end
