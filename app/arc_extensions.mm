#import "app/arc_extensions.h"

@implementation ArcExtensionCopy
@end

NSString* NotArcExtensionsDirectory(BOOL selfTest) {
  NSString* support = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"];
  return [support stringByAppendingPathComponent:selfTest ? @"SelfTestExtensions" : @"Extensions From Arc"];
}

static NSString* ResolveName(NSDictionary* manifest, NSString* dir) {
  NSString* name = manifest[@"name"];
  if (![name isKindOfClass:NSString.class]) return @"";
  if (![name hasPrefix:@"__MSG_"]) return name;
  NSString* key = [[name substringFromIndex:6] stringByReplacingOccurrencesOfString:@"__" withString:@""];
  NSString* locale = [manifest[@"default_locale"] isKindOfClass:NSString.class] ? manifest[@"default_locale"] : @"en";
  NSData* d = [NSData dataWithContentsOfFile:[dir stringByAppendingFormat:@"/_locales/%@/messages.json", locale]];
  NSDictionary* msgs = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
  for (NSString* k in msgs)
    if ([k caseInsensitiveCompare:key] == NSOrderedSame && [msgs[k] isKindOfClass:NSDictionary.class]) return msgs[k][@"message"] ?: name;
  return name;
}

NSArray<ArcExtensionCopy*>* ArcCopyExtensions(NSString* arcUserData, NSArray<NSString*>* profiles, NSString* destination) {
  NSFileManager* fm = NSFileManager.defaultManager;
  [fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];
  NSMutableArray* out = [NSMutableArray array];
  NSMutableSet* seen = [NSMutableSet set];
  for (NSString* profile in profiles) {
    NSString* root = [[arcUserData stringByAppendingPathComponent:profile] stringByAppendingPathComponent:@"Extensions"];
    for (NSString* extID in [fm contentsOfDirectoryAtPath:root error:nil]) {
      if (extID.length != 32 || [seen containsObject:extID]) continue;
      NSString* extDir = [root stringByAppendingPathComponent:extID];
      NSArray* versions = [[fm contentsOfDirectoryAtPath:extDir error:nil] sortedArrayUsingComparator:^(NSString* a, NSString* b) {
        return [a compare:b options:NSNumericSearch];
      }];
      NSString* src = versions.count ? [extDir stringByAppendingPathComponent:versions.lastObject] : nil;
      NSData* m = src ? [NSData dataWithContentsOfFile:[src stringByAppendingPathComponent:@"manifest.json"]] : nil;
      NSDictionary* manifest = m ? [NSJSONSerialization JSONObjectWithData:m options:0 error:nil] : nil;
      if (![manifest isKindOfClass:NSDictionary.class]) continue;
      [seen addObject:extID];
      ArcExtensionCopy* c = [ArcExtensionCopy new];
      c.extensionID = extID;
      c.name = ResolveName(manifest, src);
      if ([manifest[@"manifest_version"] intValue] < 3) {
        c.skippedMV2 = YES;
        [out addObject:c];
        continue;
      }
      NSString* dst = [destination stringByAppendingPathComponent:extID];
      [fm removeItemAtPath:dst error:nil];
      if (![fm copyItemAtPath:src toPath:dst error:nil]) continue;
      // Web Store signature data only verifies Web Store installs; unpacked loading rejects it.
      [fm removeItemAtPath:[dst stringByAppendingPathComponent:@"_metadata"] error:nil];
      c.path = dst;
      [out addObject:c];
    }
  }
  return out;
}

NSArray<NSString*>* ArcCopiedExtensionPaths(NSString* destination) {
  NSMutableArray* out = [NSMutableArray array];
  for (NSString* e in [NSFileManager.defaultManager contentsOfDirectoryAtPath:destination error:nil]) {
    NSString* p = [destination stringByAppendingPathComponent:e];
    if ([NSFileManager.defaultManager fileExistsAtPath:[p stringByAppendingPathComponent:@"manifest.json"]]) [out addObject:p];
  }
  return [out sortedArrayUsingSelector:@selector(compare:)];
}
