#import "app/password_store.h"

#import <Security/Security.h>
#include <sqlite3.h>

#import "app/arc_cookies.h"

static BOOL gSelfTest = NO;
static BOOL gConfigured = NO;

void PasswordStoreConfigure(BOOL selfTest) {
  gSelfTest = selfTest;
  gConfigured = YES;
}
BOOL PasswordStoreIsSelfTest(void) { return gSelfTest; }

NSString* PasswordStorePath(BOOL selfTest) {
  NSString* support =
      [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
          stringByAppendingPathComponent:@"NotArc"];
  return [support stringByAppendingPathComponent:selfTest ? @"SelfTestPasswords.dat" : @"Passwords.dat"];
}

static NSData* RandomBytes(size_t n) {
  NSMutableData* d = [NSMutableData dataWithLength:n];
  if (SecRandomCopyBytes(kSecRandomDefault, n, d.mutableBytes) != errSecSuccess) arc4random_buf(d.mutableBytes, n);
  return d;
}

// The key for NotArc's own store. Real runs: Chromium's scheme (PBKDF2 over a random password) with the password
// kept in NotArc's own Keychain item, "NotArc Safe Storage" (made on first use; an item NotArc made itself never
// brings an access prompt). Not CEF's "Chromium Safe Storage", which the Chromium browser also uses.
// Self-test runs: a random key that lives only in memory; the Keychain is never read or written.
static NSString* const kStoreService = @"NotArc Safe Storage";
static NSString* const kStoreAccount = @"NotArc";

static NSData* StoreKey(void) {
  static NSData* key = nil;
  if (key) return key;
  if (gSelfTest) {
    key = RandomBytes(16);
    return key;
  }
  if (!gConfigured) return nil;
  NSError* error = nil;
  NSString* pw = SafeStoragePassword(kStoreService, kStoreAccount, &error);
  if (!pw && error.code == errSecItemNotFound) {
    NSString* fresh = [RandomBytes(16) base64EncodedStringWithOptions:0];
    NSDictionary* add = @{
      (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
      (__bridge id)kSecAttrService : kStoreService,
      (__bridge id)kSecAttrAccount : kStoreAccount,
      (__bridge id)kSecAttrLabel : kStoreService,
      (__bridge id)kSecValueData : [fresh dataUsingEncoding:NSUTF8StringEncoding],
    };
    OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    pw = st == errSecSuccess ? fresh : SafeStoragePassword(kStoreService, kStoreAccount, nil);
  }
  if (!pw.length) return nil;
  key = ArcCookieKey(pw);
  return key;
}

NSString* AutofillOriginOfURL(NSString* url) {
  if (!url.length) return nil;
  NSURL* u = [NSURL URLWithString:url];
  NSString* scheme = u.scheme.lowercaseString;
  if ([scheme isEqualToString:@"file"]) return @"file://";
  if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) || !u.host.length) return nil;
  NSString* origin = [NSString stringWithFormat:@"%@://%@", scheme, u.host.lowercaseString];
  if (u.port && !((u.port.intValue == 443 && [scheme isEqualToString:@"https"]) ||
                  (u.port.intValue == 80 && [scheme isEqualToString:@"http"])))
    origin = [origin stringByAppendingFormat:@":%@", u.port];
  return origin;
}

static NSString* HostOfOrigin(NSString* origin) {
  NSRange r = [origin rangeOfString:@"://"];
  if (r.location == NSNotFound) return origin;
  NSString* h = [origin substringFromIndex:NSMaxRange(r)];
  NSRange colon = [h rangeOfString:@":" options:NSBackwardsSearch];
  return colon.location == NSNotFound ? h : [h substringToIndex:colon.location];
}

// "login.example.co.uk" -> "example.co.uk". A small heuristic (no public suffix list): two labels, or three when
// the second-level label is short and the top-level one is a country code. IP addresses match only themselves.
static NSString* SiteOfHost(NSString* host) {
  NSArray* parts = [host componentsSeparatedByString:@"."];
  if (parts.count < 3 || [host rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location == NSNotFound)
    return host;
  NSUInteger keep = 2;
  NSString* tld = parts.lastObject, *sld = parts[parts.count - 2];
  if (tld.length == 2 && sld.length <= 3) keep = 3;
  if (parts.count <= keep) return host;
  return [[parts subarrayWithRange:NSMakeRange(parts.count - keep, keep)] componentsJoinedByString:@"."];
}

NSArray<NSArray<NSString*>*>* AutofillParseCSV(NSString* text) {
  NSMutableArray* rows = [NSMutableArray array];
  NSMutableArray* row = [NSMutableArray array];
  NSMutableString* field = [NSMutableString string];
  BOOL quoted = NO, any = NO;
  NSUInteger n = text.length;
  for (NSUInteger i = 0; i < n; ++i) {
    unichar c = [text characterAtIndex:i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < n && [text characterAtIndex:i + 1] == '"') {
          [field appendString:@"\""];
          ++i;
        } else {
          quoted = NO;
        }
      } else {
        [field appendFormat:@"%C", c];
      }
      continue;
    }
    if (c == '"') {
      quoted = YES;
      any = YES;
    } else if (c == ',') {
      [row addObject:[field copy]];
      [field setString:@""];
      any = YES;
    } else if (c == '\n' || c == '\r') {
      if (c == '\r' && i + 1 < n && [text characterAtIndex:i + 1] == '\n') ++i;
      if (any || field.length) {
        [row addObject:[field copy]];
        [rows addObject:row];
      }
      row = [NSMutableArray array];
      [field setString:@""];
      any = NO;
    } else {
      [field appendFormat:@"%C", c];
      any = YES;
    }
  }
  if (any || field.length) {
    [row addObject:[field copy]];
    [rows addObject:row];
  }
  return rows;
}

NSString* AutofillCardDigits(NSString* number) {
  NSString* digits = [[number componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet]
      componentsJoinedByString:@""];
  if (digits.length < 12 || digits.length > 19) return nil;
  int sum = 0;
  BOOL dbl = NO;
  for (NSInteger i = (NSInteger)digits.length - 1; i >= 0; --i) {
    int d = [digits characterAtIndex:i] - '0';
    if (dbl && (d *= 2) > 9) d -= 9;
    sum += d;
    dbl = !dbl;
  }
  return sum % 10 == 0 ? digits : nil;
}

#pragma mark Model

@implementation SavedLogin
- (NSString*)host { return HostOfOrigin(self.origin); }
@end

@implementation AutofillAddress
- (NSString*)fullName {
  NSString* n = self.fields[@"name"];
  if (n.length) return n;
  NSMutableArray* parts = [NSMutableArray array];
  for (NSString* k in @[ @"given", @"middle", @"family" ])
    if (self.fields[k].length) [parts addObject:self.fields[k]];
  return [parts componentsJoinedByString:@" "];
}
- (NSString*)summary {
  NSMutableArray* parts = [NSMutableArray array];
  if (self.fullName.length) [parts addObject:self.fullName];
  NSString* line = self.fields[@"line1"].length ? self.fields[@"line1"] : self.fields[@"email"];
  if (line.length) [parts addObject:line];
  if (!parts.count && self.fields[@"tel"].length) [parts addObject:self.fields[@"tel"]];
  return parts.count ? [parts componentsJoinedByString:@", "] : @"Address";
}
@end

@implementation AutofillCard
- (NSString*)summary {
  NSMutableString* s = [NSMutableString stringWithFormat:@"•••• %@", self.last4 ?: @"????"];
  NSMutableArray* extra = [NSMutableArray array];
  if (self.nickname.length) [extra addObject:self.nickname];
  else if (self.name.length) [extra addObject:self.name];
  if (self.expMonth && self.expYear) [extra addObject:[NSString stringWithFormat:@"%02d/%d", self.expMonth, self.expYear]];
  if (extra.count) [s appendFormat:@" (%@)", [extra componentsJoinedByString:@", "]];
  return s;
}
@end

#pragma mark SQLite helpers (read-only copies)

// Copies a database (plus its -wal/-journal) to a private temp folder and opens the copy read-only, so the other
// browser's file is never locked or changed. *tmp gets the folder to delete.
static sqlite3* OpenCopy(NSString* path, NSString** tmpDir) {
  NSFileManager* fm = NSFileManager.defaultManager;
  if (![fm isReadableFileAtPath:path]) return NULL;
  NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                              [@"notarc-import-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions : @0700} error:nil];
  NSString* copy = [dir stringByAppendingPathComponent:@"db"];
  if (![fm copyItemAtPath:path toPath:copy error:nil]) {
    [fm removeItemAtPath:dir error:nil];
    return NULL;
  }
  for (NSString* ext in @[ @"-wal", @"-journal" ])
    if ([fm fileExistsAtPath:[path stringByAppendingString:ext]])
      [fm copyItemAtPath:[path stringByAppendingString:ext] toPath:[copy stringByAppendingString:ext] error:nil];
  sqlite3* db = NULL;
  if (sqlite3_open_v2(copy.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
    sqlite3_close(db);
    [fm removeItemAtPath:dir error:nil];
    return NULL;
  }
  *tmpDir = dir;
  return db;
}

static BOOL HasTable(sqlite3* db, const char* name) {
  sqlite3_stmt* st = NULL;
  BOOL found = NO;
  if (sqlite3_prepare_v2(db, "select 1 from sqlite_master where type='table' and name=?", -1, &st, NULL) == SQLITE_OK) {
    sqlite3_bind_text(st, 1, name, -1, SQLITE_STATIC);
    found = sqlite3_step(st) == SQLITE_ROW;
  }
  sqlite3_finalize(st);
  return found;
}

// Rows as dictionaries (column name -> NSString, or NSData for blobs). Missing tables give no rows.
static NSArray<NSDictionary*>* Rows(sqlite3* db, NSString* sql) {
  NSMutableArray* out = [NSMutableArray array];
  sqlite3_stmt* st = NULL;
  if (sqlite3_prepare_v2(db, sql.UTF8String, -1, &st, NULL) != SQLITE_OK) return out;
  while (sqlite3_step(st) == SQLITE_ROW) {
    NSMutableDictionary* row = [NSMutableDictionary dictionary];
    for (int i = 0; i < sqlite3_column_count(st); ++i) {
      NSString* name = @(sqlite3_column_name(st, i));
      switch (sqlite3_column_type(st, i)) {
        case SQLITE_BLOB:
          row[name] = [NSData dataWithBytes:sqlite3_column_blob(st, i) length:sqlite3_column_bytes(st, i)];
          break;
        case SQLITE_NULL:
          break;
        default: {
          const unsigned char* t = sqlite3_column_text(st, i);
          if (t) row[name] = @((const char*)t);
        }
      }
    }
    [out addObject:row];
  }
  sqlite3_finalize(st);
  return out;
}

static NSString* Text(id v) { return [v isKindOfClass:NSString.class] ? v : nil; }

static NSDate* ChromeTime(id v) {  // microseconds since 1601
  long long us = [Text(v) longLongValue];
  return us > 0 ? [NSDate dateWithTimeIntervalSince1970:us / 1e6 - 11644473600.0] : nil;
}

#pragma mark Store

@implementation PasswordStore {
  NSData* _key;
  NSMutableArray<SavedLogin*>* _logins;
  NSMutableArray<AutofillAddress*>* _addresses;
  NSMutableArray<AutofillCard*>* _cards;
  NSMutableSet<NSString*>* _never;
  BOOL _usable;
}

+ (instancetype)shared {
  static PasswordStore* store = nil;
  if (!store) store = [[PasswordStore alloc] initWithPath:PasswordStorePath(gSelfTest) key:StoreKey()];
  return store;
}

- (instancetype)initWithPath:(NSString*)path key:(NSData*)key {
  if ((self = [super init])) {
    _path = [path copy];
    _key = key;
    [self reload];
  }
  return self;
}

- (NSMutableArray<SavedLogin*>*)logins { return _logins; }
- (NSMutableArray<AutofillAddress*>*)addresses { return _addresses; }
- (NSMutableArray<AutofillCard*>*)cards { return _cards; }
- (NSMutableSet<NSString*>*)neverOrigins { return _never; }
- (BOOL)usable { return _usable; }

- (NSData*)seal:(NSString*)secret {
  return ChromiumEncryptValue([secret ?: @"" dataUsingEncoding:NSUTF8StringEncoding], _key);
}

- (NSString*)unseal:(NSData*)sealed {
  NSData* plain = ChromiumDecryptValue(sealed, _key);
  return plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
}

- (NSString*)passwordFor:(SavedLogin*)login { return [self unseal:login.sealedPassword]; }
- (NSString*)cardNumberFor:(AutofillCard*)card { return [self unseal:card.sealedNumber]; }

- (BOOL)reload {
  _logins = [NSMutableArray array];
  _addresses = [NSMutableArray array];
  _cards = [NSMutableArray array];
  _never = [NSMutableSet set];
  _usable = _key.length == 16;
  if (!_usable) return NO;
  NSData* blob = [NSData dataWithContentsOfFile:_path];
  if (!blob) return YES;  // nothing saved yet
  NSData* json = ChromiumDecryptValue(blob, _key);
  NSDictionary* root = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
  if (![root isKindOfClass:NSDictionary.class]) {
    _usable = NO;  // wrong key or damaged: never overwrite it
    return NO;
  }
  for (NSDictionary* d in root[@"logins"]) {
    if (![d isKindOfClass:NSDictionary.class]) continue;
    SavedLogin* l = [SavedLogin new];
    l.origin = Text(d[@"origin"]);
    l.username = Text(d[@"username"]) ?: @"";
    l.sealedPassword = [[NSData alloc] initWithBase64EncodedString:Text(d[@"password"]) ?: @"" options:0];
    l.source = Text(d[@"source"]);
    if ([d[@"created"] isKindOfClass:NSNumber.class]) l.created = [NSDate dateWithTimeIntervalSince1970:[d[@"created"] doubleValue]];
    if ([d[@"lastUsed"] isKindOfClass:NSNumber.class]) l.lastUsed = [NSDate dateWithTimeIntervalSince1970:[d[@"lastUsed"] doubleValue]];
    if (l.origin.length && l.sealedPassword.length) [_logins addObject:l];
  }
  for (NSDictionary* d in root[@"addresses"]) {
    if (![d isKindOfClass:NSDictionary.class] || ![d[@"fields"] isKindOfClass:NSDictionary.class]) continue;
    AutofillAddress* a = [AutofillAddress new];
    a.fields = d[@"fields"];
    a.source = Text(d[@"source"]);
    [_addresses addObject:a];
  }
  for (NSDictionary* d in root[@"cards"]) {
    if (![d isKindOfClass:NSDictionary.class]) continue;
    AutofillCard* c = [AutofillCard new];
    c.name = Text(d[@"name"]);
    c.sealedNumber = [[NSData alloc] initWithBase64EncodedString:Text(d[@"number"]) ?: @"" options:0];
    c.last4 = Text(d[@"last4"]);
    c.expMonth = [d[@"expMonth"] intValue];
    c.expYear = [d[@"expYear"] intValue];
    c.nickname = Text(d[@"nickname"]);
    c.source = Text(d[@"source"]);
    if (c.sealedNumber.length) [_cards addObject:c];
  }
  for (id o in root[@"never"])
    if (Text(o)) [_never addObject:o];
  return YES;
}

- (BOOL)save {
  if (!_usable) return NO;
  NSMutableArray* logins = [NSMutableArray array], *addresses = [NSMutableArray array], *cards = [NSMutableArray array];
  for (SavedLogin* l in _logins) {
    NSMutableDictionary* d = [@{
      @"origin" : l.origin,
      @"username" : l.username ?: @"",
      @"password" : [l.sealedPassword base64EncodedStringWithOptions:0],
    } mutableCopy];
    if (l.source) d[@"source"] = l.source;
    if (l.created) d[@"created"] = @(l.created.timeIntervalSince1970);
    if (l.lastUsed) d[@"lastUsed"] = @(l.lastUsed.timeIntervalSince1970);
    [logins addObject:d];
  }
  for (AutofillAddress* a in _addresses) {
    NSMutableDictionary* d = [@{@"fields" : a.fields ?: @{}} mutableCopy];
    if (a.source) d[@"source"] = a.source;
    [addresses addObject:d];
  }
  for (AutofillCard* c in _cards) {
    NSMutableDictionary* d = [@{
      @"number" : [c.sealedNumber base64EncodedStringWithOptions:0],
      @"expMonth" : @(c.expMonth),
      @"expYear" : @(c.expYear),
    } mutableCopy];
    if (c.name) d[@"name"] = c.name;
    if (c.last4) d[@"last4"] = c.last4;
    if (c.nickname) d[@"nickname"] = c.nickname;
    if (c.source) d[@"source"] = c.source;
    [cards addObject:d];
  }
  NSDictionary* root = @{
    @"version" : @1,
    @"logins" : logins,
    @"addresses" : addresses,
    @"cards" : cards,
    @"never" : [_never.allObjects sortedArrayUsingSelector:@selector(compare:)],
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:root options:0 error:nil];
  NSData* blob = ChromiumEncryptValue(json, _key);
  if (!blob) return NO;
  [NSFileManager.defaultManager createDirectoryAtPath:_path.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES attributes:nil error:nil];
  if (![blob writeToFile:_path options:NSDataWritingAtomic error:nil]) return NO;
  [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions : @0600} ofItemAtPath:_path error:nil];
  return YES;
}

- (SavedLogin*)loginForOrigin:(NSString*)origin username:(NSString*)username {
  for (SavedLogin* l in _logins)
    if ([l.origin isEqualToString:origin] && [l.username isEqualToString:username ?: @""]) return l;
  return nil;
}

- (NSArray<SavedLogin*>*)loginsForOrigin:(NSString*)origin {
  if (!origin.length) return @[];
  NSMutableArray* exact = [NSMutableArray array], *related = [NSMutableArray array];
  BOOL pageSecure = [origin hasPrefix:@"https://"] || [origin isEqualToString:@"file://"];
  NSString* site = SiteOfHost(HostOfOrigin(origin));
  for (SavedLogin* l in _logins) {
    if ([l.origin isEqualToString:origin]) {
      [exact addObject:l];
      continue;
    }
    if (!pageSecure && [l.origin hasPrefix:@"https://"]) continue;  // https logins never go to an http page
    if ([origin isEqualToString:@"file://"] || [l.origin isEqualToString:@"file://"]) continue;
    if ([SiteOfHost(l.host) isEqualToString:site]) [related addObject:l];
  }
  NSComparator byUse = ^NSComparisonResult(SavedLogin* a, SavedLogin* b) {
    NSDate* da = a.lastUsed ?: a.created ?: NSDate.distantPast, *db = b.lastUsed ?: b.created ?: NSDate.distantPast;
    return [db compare:da];
  };
  [exact sortUsingComparator:byUse];
  [related sortUsingComparator:byUse];
  return [exact arrayByAddingObjectsFromArray:related];
}

- (PasswordSaveResult)checkOrigin:(NSString*)origin username:(NSString*)username password:(NSString*)password {
  if (!origin.length || !password.length) return PasswordUnchanged;
  SavedLogin* l = [self loginForOrigin:origin username:username];
  if (!l && !username.length)  // password-only step of a sign-in: matches any saved login with that password
    for (SavedLogin* x in [self loginsForOrigin:origin])
      if ([[self passwordFor:x] isEqualToString:password]) return PasswordUnchanged;
  if (!l) return PasswordAdded;
  return [[self passwordFor:l] isEqualToString:password] ? PasswordUnchanged : PasswordUpdated;
}

- (PasswordSaveResult)saveOrigin:(NSString*)origin username:(NSString*)username password:(NSString*)password
                          source:(NSString*)source {
  PasswordSaveResult r = [self checkOrigin:origin username:username password:password];
  if (r == PasswordUnchanged || !_usable) return PasswordUnchanged;
  SavedLogin* l = [self loginForOrigin:origin username:username];
  if (!l) {
    l = [SavedLogin new];
    l.origin = origin;
    l.username = username ?: @"";
    l.created = [NSDate date];
    l.source = source;
    [_logins addObject:l];
  }
  l.sealedPassword = [self seal:password];
  l.lastUsed = [NSDate date];
  [self save];
  return r;
}

- (void)removeLogin:(SavedLogin*)login {
  [_logins removeObject:login];
  [self save];
}
- (void)removeAddress:(AutofillAddress*)address {
  [_addresses removeObject:address];
  [self save];
}
- (void)removeCard:(AutofillCard*)card {
  [_cards removeObject:card];
  [self save];
}

- (void)setNever:(BOOL)never forOrigin:(NSString*)origin {
  if (!origin.length) return;
  if (never) [_never addObject:origin];
  else [_never removeObject:origin];
  [self save];
}
- (BOOL)isNeverOrigin:(NSString*)origin { return origin && [_never containsObject:origin]; }

#pragma mark Import

// Adds a login unless that site + username is already saved (NotArc's own copy wins over an import).
- (BOOL)importLogin:(NSString*)origin username:(NSString*)username password:(NSString*)password
            created:(NSDate*)created source:(NSString*)source {
  if (!origin.length || !password.length || [self loginForOrigin:origin username:username ?: @""]) return NO;
  SavedLogin* l = [SavedLogin new];
  l.origin = origin;
  l.username = username ?: @"";
  l.sealedPassword = [self seal:password];
  l.created = created ?: [NSDate date];
  l.source = source;
  [_logins addObject:l];
  return YES;
}

static NSString* AddressKey(NSDictionary* f) {
  NSString* name = f[@"name"] ?: [NSString stringWithFormat:@"%@ %@", f[@"given"] ?: @"", f[@"family"] ?: @""];
  return [[NSString stringWithFormat:@"%@|%@|%@|%@", name, f[@"line1"] ?: @"", f[@"zip"] ?: @"", f[@"email"] ?: @""]
      lowercaseString];
}

// Fills in name / street parts that can be derived from the others.
static NSDictionary* CompleteAddress(NSMutableDictionary* f) {
  for (NSString* k in f.allKeys)
    if (![f[k] isKindOfClass:NSString.class] || ![f[k] length]) [f removeObjectForKey:k];
  if (!f[@"name"]) {
    NSMutableArray* parts = [NSMutableArray array];
    for (NSString* k in @[ @"given", @"middle", @"family" ]) if (f[k]) [parts addObject:f[k]];
    if (parts.count) f[@"name"] = [parts componentsJoinedByString:@" "];
  } else if (!f[@"given"] && !f[@"family"]) {
    NSRange sp = [f[@"name"] rangeOfString:@" " options:NSBackwardsSearch];
    if (sp.location != NSNotFound) {
      f[@"given"] = [f[@"name"] substringToIndex:sp.location];
      f[@"family"] = [f[@"name"] substringFromIndex:sp.location + 1];
    }
  }
  if (f[@"street"] && !f[@"line1"]) {
    NSArray* lines = [f[@"street"] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
    f[@"line1"] = lines.firstObject;
    if (lines.count > 1) f[@"line2"] = [[lines subarrayWithRange:NSMakeRange(1, lines.count - 1)] componentsJoinedByString:@", "];
  } else if (f[@"line1"] && !f[@"street"]) {
    f[@"street"] = f[@"line2"] ? [NSString stringWithFormat:@"%@\n%@", f[@"line1"], f[@"line2"]] : f[@"line1"];
  }
  return f;
}

- (BOOL)importAddressFields:(NSMutableDictionary*)raw source:(NSString*)source {
  NSDictionary* f = CompleteAddress(raw);
  if (!f[@"line1"] && !f[@"email"] && !f[@"tel"]) return NO;
  NSString* key = AddressKey(f);
  for (AutofillAddress* a in _addresses)
    if ([AddressKey(a.fields) isEqualToString:key]) return NO;
  AutofillAddress* a = [AutofillAddress new];
  a.fields = f;
  a.source = source;
  [_addresses addObject:a];
  return YES;
}

- (BOOL)addAddressFields:(NSDictionary<NSString*, NSString*>*)fields {
  NSMutableDictionary* f = [NSMutableDictionary dictionary];
  for (NSString* k in fields) {
    NSString* v = [fields[k] isKindOfClass:NSString.class]
                      ? [fields[k] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                      : nil;
    if (v.length) f[k] = v;
  }
  if (!_usable || ![self importAddressFields:f source:@"NotArc"]) return NO;
  return [self save];
}

- (BOOL)addCardNumber:(NSString*)number name:(NSString*)name month:(int)month year:(int)year {
  NSString* digits = AutofillCardDigits(number);
  if (!_usable || !digits || month < 0 || month > 12) return NO;
  for (AutofillCard* c in _cards)
    if ([[self cardNumberFor:c] isEqualToString:digits]) return NO;
  AutofillCard* c = [AutofillCard new];
  c.sealedNumber = [self seal:digits];
  c.last4 = [digits substringFromIndex:digits.length - 4];
  c.name = [name stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  c.expMonth = month;
  c.expYear = year > 0 && year < 100 ? year + 2000 : year;
  c.source = @"NotArc";
  [_cards addObject:c];
  return [self save];
}

- (NSUInteger)importAddressesFrom:(sqlite3*)db source:(NSString*)source {
  NSUInteger added = 0;
  // Chrome 113 and later: one row of (type, value) per field. Type numbers are Chromium's FieldType values.
  static NSDictionary<NSString*, NSString*>* types = @{
    @"3" : @"given", @"4" : @"middle", @"5" : @"family", @"7" : @"name", @"9" : @"email", @"14" : @"tel",
    @"30" : @"line1", @"31" : @"line2", @"33" : @"city", @"34" : @"state", @"35" : @"zip", @"36" : @"country",
    @"60" : @"org", @"77" : @"street"};
  for (NSString* table in @[ @"local_addresses_type_tokens", @"contact_info_type_tokens", @"address_type_tokens" ]) {
    if (!HasTable(db, table.UTF8String)) continue;
    NSMutableDictionary<NSString*, NSMutableDictionary*>* byGuid = [NSMutableDictionary dictionary];
    NSMutableArray* order = [NSMutableArray array];
    for (NSDictionary* r in Rows(db, [NSString stringWithFormat:@"select guid, type, value from %@", table])) {
      NSString* guid = Text(r[@"guid"]), *key = types[Text(r[@"type"]) ?: @""];
      if (!guid || !key || !Text(r[@"value"]).length) continue;
      if (!byGuid[guid]) {
        byGuid[guid] = [NSMutableDictionary dictionary];
        [order addObject:guid];
      }
      byGuid[guid][key] = r[@"value"];
    }
    for (NSString* g in order) added += [self importAddressFields:byGuid[g] source:source];
  }
  // Older Chrome (and Arc): autofill_profiles plus name / email / phone side tables.
  if (HasTable(db, "autofill_profiles")) {
    NSMutableDictionary<NSString*, NSMutableDictionary*>* byGuid = [NSMutableDictionary dictionary];
    NSMutableArray* order = [NSMutableArray array];
    for (NSDictionary* r in Rows(db, @"select * from autofill_profiles")) {
      NSString* guid = Text(r[@"guid"]);
      if (!guid) continue;
      NSMutableDictionary* f = [NSMutableDictionary dictionary];
      f[@"org"] = Text(r[@"company_name"]);
      f[@"street"] = Text(r[@"street_address"]);
      f[@"city"] = Text(r[@"city"]);
      f[@"state"] = Text(r[@"state"]);
      f[@"zip"] = Text(r[@"zipcode"]);
      f[@"country"] = Text(r[@"country_code"]);
      byGuid[guid] = f;
      [order addObject:guid];
    }
    for (NSDictionary* r in Rows(db, @"select * from autofill_profile_names")) {
      NSMutableDictionary* f = byGuid[Text(r[@"guid"]) ?: @""];
      if (!f || f[@"given"] || f[@"name"]) continue;  // first name row only
      f[@"given"] = Text(r[@"first_name"]);
      f[@"middle"] = Text(r[@"middle_name"]);
      f[@"family"] = Text(r[@"last_name"]);
      f[@"name"] = Text(r[@"full_name"]);
    }
    for (NSDictionary* r in Rows(db, @"select * from autofill_profile_emails")) {
      NSMutableDictionary* f = byGuid[Text(r[@"guid"]) ?: @""];
      if (f && !f[@"email"]) f[@"email"] = Text(r[@"email"]);
    }
    for (NSDictionary* r in Rows(db, @"select * from autofill_profile_phones")) {
      NSMutableDictionary* f = byGuid[Text(r[@"guid"]) ?: @""];
      if (f && !f[@"tel"]) f[@"tel"] = Text(r[@"number"]);
    }
    for (NSString* g in order) added += [self importAddressFields:byGuid[g] source:source];
  }
  return added;
}

- (NSUInteger)importCardsFrom:(sqlite3*)db key:(NSData*)key source:(NSString*)source undecryptable:(NSUInteger*)bad {
  if (!HasTable(db, "credit_cards")) return 0;
  NSUInteger added = 0;
  NSMutableSet* have = [NSMutableSet set];
  for (AutofillCard* c in _cards) {
    NSString* n = [self cardNumberFor:c];
    if (n) [have addObject:n];
  }
  for (NSDictionary* r in Rows(db, @"select * from credit_cards")) {
    NSData* blob = [r[@"card_number_encrypted"] isKindOfClass:NSData.class] ? r[@"card_number_encrypted"] : nil;
    NSData* plain = ChromiumDecryptValue(blob, key);
    NSString* raw = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
    NSString* number = [[raw componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet]
        componentsJoinedByString:@""];
    if (number.length < 12) {
      if (blob.length) ++*bad;
      continue;
    }
    if ([have containsObject:number]) continue;
    [have addObject:number];
    AutofillCard* c = [AutofillCard new];
    c.name = Text(r[@"name_on_card"]);
    c.sealedNumber = [self seal:number];
    c.last4 = [number substringFromIndex:number.length - 4];
    c.expMonth = [Text(r[@"expiration_month"]) intValue];
    c.expYear = [Text(r[@"expiration_year"]) intValue];
    if (c.expYear > 0 && c.expYear < 100) c.expYear += 2000;
    c.nickname = Text(r[@"nickname"]);
    c.source = source;
    [_cards addObject:c];
    ++added;
  }
  return added;
}

- (NSDictionary<NSString*, NSNumber*>*)importChromiumProfile:(NSString*)profileDir key:(NSData*)key source:(NSString*)source {
  if (!_usable || key.length != 16) return nil;
  NSUInteger passwords = 0, addresses = 0, cards = 0, never = 0, bad = 0;
  BOOL readAny = NO;
  for (NSString* file in @[ @"Login Data", @"Login Data For Account" ]) {
    NSString* tmp = nil;
    sqlite3* db = OpenCopy([profileDir stringByAppendingPathComponent:file], &tmp);
    if (!db) continue;
    readAny = YES;
    for (NSDictionary* r in Rows(db, @"select origin_url, signon_realm, username_value, password_value, "
                                      @"blacklisted_by_user, date_created from logins")) {
      NSString* origin = AutofillOriginOfURL(Text(r[@"signon_realm"])) ?: AutofillOriginOfURL(Text(r[@"origin_url"]));
      if (!origin || [origin isEqualToString:@"file://"]) continue;  // android:// and federated rows
      if ([Text(r[@"blacklisted_by_user"]) intValue]) {  // the user chose "Never" for this site
        if (![_never containsObject:origin]) {
          [_never addObject:origin];
          ++never;
        }
        continue;
      }
      NSData* blob = [r[@"password_value"] isKindOfClass:NSData.class] ? r[@"password_value"] : nil;
      if (!blob.length) continue;
      NSData* plain = ChromiumDecryptValue(blob, key);
      NSString* pw = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
      if (!pw.length) {
        ++bad;
        continue;
      }
      passwords += [self importLogin:origin username:Text(r[@"username_value"]) password:pw
                             created:ChromeTime(r[@"date_created"]) source:source];
    }
    sqlite3_close(db);
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
  }
  NSString* tmp = nil;
  sqlite3* web = OpenCopy([profileDir stringByAppendingPathComponent:@"Web Data"], &tmp);
  if (web) {
    readAny = YES;
    addresses = [self importAddressesFrom:web source:source];
    cards = [self importCardsFrom:web key:key source:source undecryptable:&bad];
    sqlite3_close(web);
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
  }
  if (!readAny) return nil;
  if (passwords || addresses || cards || never) [self save];
  return @{@"passwords" : @(passwords), @"addresses" : @(addresses), @"cards" : @(cards), @"never" : @(never),
           @"undecryptable" : @(bad)};
}

- (NSUInteger)importCSVFile:(NSString*)path source:(NSString*)source {
  if (!_usable) return NSNotFound;
  NSString* text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  if (!text) return NSNotFound;
  NSArray<NSArray<NSString*>*>* rows = AutofillParseCSV(text);
  if (rows.count < 1) return NSNotFound;
  NSInteger urlCol = -1, userCol = -1, pwCol = -1;
  for (NSUInteger i = 0; i < rows[0].count; ++i) {
    NSString* h = [rows[0][i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    if ([h hasPrefix:@"\uFEFF"]) h = [h substringFromIndex:1];
    if (urlCol < 0 && ([h isEqualToString:@"url"] || [h isEqualToString:@"website"] || [h isEqualToString:@"login_uri"]))
      urlCol = i;
    else if (userCol < 0 && ([h isEqualToString:@"username"] || [h isEqualToString:@"login"] ||
                             [h isEqualToString:@"user name"] || [h isEqualToString:@"login_username"]))
      userCol = i;
    else if (pwCol < 0 && ([h isEqualToString:@"password"] || [h isEqualToString:@"login_password"]))
      pwCol = i;
  }
  if (urlCol < 0 || pwCol < 0) return NSNotFound;
  NSUInteger added = 0;
  for (NSUInteger i = 1; i < rows.count; ++i) {
    NSArray* r = rows[i];
    if ((NSInteger)r.count <= MAX(urlCol, pwCol)) continue;
    NSString* origin = AutofillOriginOfURL(r[urlCol]);
    if (!origin || [origin isEqualToString:@"file://"]) continue;
    NSString* user = userCol >= 0 && (NSInteger)r.count > userCol ? r[userCol] : @"";
    added += [self importLogin:origin username:user password:r[pwCol] created:nil source:source];
  }
  if (added) [self save];
  return added;
}

@end
