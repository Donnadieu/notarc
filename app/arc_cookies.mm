#import "app/arc_cookies.h"

#import <CommonCrypto/CommonCrypto.h>
#import <Security/Security.h>
#include <sqlite3.h>

@implementation ArcCookie
@end

static NSError* Err(NSString* msg) {
  return [NSError errorWithDomain:@"ArcCookies" code:1 userInfo:@{NSLocalizedDescriptionKey : msg}];
}

NSString* ArcSafeStoragePassword(NSError** error) {
  NSDictionary* query = @{
    (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
    (__bridge id)kSecAttrService : @"Arc Safe Storage",
    (__bridge id)kSecAttrAccount : @"Arc",
    (__bridge id)kSecReturnData : @YES,
    (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
  };
  CFTypeRef result = NULL;
  OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
  if (status != errSecSuccess || !result) {
    if (error) *error = Err([NSString stringWithFormat:@"Keychain read failed (OSStatus %d)", (int)status]);
    return nil;
  }
  NSData* data = (__bridge_transfer NSData*)result;
  return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

NSData* ArcCookieKey(NSString* password) {
  NSData* pw = [password dataUsingEncoding:NSUTF8StringEncoding];
  NSMutableData* key = [NSMutableData dataWithLength:kCCKeySizeAES128];
  const char salt[] = "saltysalt";
  CCKeyDerivationPBKDF(kCCPBKDF2, (const char*)pw.bytes, pw.length, (const uint8_t*)salt, sizeof(salt) - 1,
                       kCCPRFHmacAlgSHA1, 1003, (uint8_t*)key.mutableBytes, key.length);
  return key;
}

// "v10" + AES-128-CBC, IV = 16 spaces, PKCS7 padding.
static NSData* Decrypt(const uint8_t* blob, int length, NSData* key) {
  if (length < 3 + kCCBlockSizeAES128 || memcmp(blob, "v10", 3) != 0) return nil;
  uint8_t iv[kCCBlockSizeAES128];
  memset(iv, ' ', sizeof(iv));
  NSMutableData* out = [NSMutableData dataWithLength:length];
  size_t moved = 0;
  CCCryptorStatus st = CCCrypt(kCCDecrypt, kCCAlgorithmAES128, kCCOptionPKCS7Padding, key.bytes, key.length, iv,
                               blob + 3, length - 3, out.mutableBytes, out.length, &moved);
  if (st != kCCSuccess) return nil;
  out.length = moved;
  return out;
}

static int64_t NowChromeMicros(void) {
  // Chromium time: microseconds since 1601-01-01 UTC.
  return (int64_t)(([[NSDate date] timeIntervalSince1970] + 11644473600.0) * 1e6);
}

NSString* ArcCookieDBPath(NSString* profileDirectory) {
  NSString* support =
      NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  return [[[[support stringByAppendingPathComponent:@"Arc"] stringByAppendingPathComponent:@"User Data"]
      stringByAppendingPathComponent:profileDirectory] stringByAppendingPathComponent:@"Cookies"];
}

NSArray<ArcCookie*>* ArcReadCookies(NSString* dbPath, NSData* key, ArcCookieStats* stats, NSError** error) {
  ArcCookieStats local = {0, 0, 0};
  // Arc holds the DB open; read a private copy (plus WAL if present).
  NSString* tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSFileManager* fm = NSFileManager.defaultManager;
  if (![fm copyItemAtPath:dbPath toPath:tmp error:error]) return nil;
  for (NSString* ext in @[ @"-wal", @"-journal" ])
    if ([fm fileExistsAtPath:[dbPath stringByAppendingString:ext]])
      [fm copyItemAtPath:[dbPath stringByAppendingString:ext] toPath:[tmp stringByAppendingString:ext] error:nil];

  sqlite3* db = NULL;
  NSMutableArray* out = [NSMutableArray array];
  if (sqlite3_open_v2(tmp.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
    if (error) *error = Err(@"cannot open cookie DB copy");
    sqlite3_close(db);
    return nil;
  }
  int version = 0;
  sqlite3_stmt* st = NULL;
  if (sqlite3_prepare_v2(db, "select value from meta where key='version'", -1, &st, NULL) == SQLITE_OK &&
      sqlite3_step(st) == SQLITE_ROW)
    version = atoi((const char*)sqlite3_column_text(st, 0));
  sqlite3_finalize(st);

  const char* sql =
      "select host_key,name,encrypted_value,path,expires_utc,is_secure,is_httponly,has_expires,"
      "creation_utc,last_access_utc,samesite,priority from cookies";
  if (sqlite3_prepare_v2(db, sql, -1, &st, NULL) != SQLITE_OK) {
    if (error) *error = Err(@"cookie table query failed");
    sqlite3_close(db);
    return nil;
  }
  int64_t now = NowChromeMicros();
  while (sqlite3_step(st) == SQLITE_ROW) {
    local.total++;
    const char* host = (const char*)sqlite3_column_text(st, 0);
    int64_t expires = sqlite3_column_int64(st, 4);
    BOOL hasExpires = sqlite3_column_int(st, 7) != 0;
    if (hasExpires && expires > 0 && expires < now) {
      local.expired++;
      continue;
    }
    NSData* plain = Decrypt((const uint8_t*)sqlite3_column_blob(st, 2), sqlite3_column_bytes(st, 2), key);
    if (plain && version >= 24) {
      // First 32 bytes = SHA-256(host_key); verifies the key and binds the value to its domain.
      uint8_t digest[CC_SHA256_DIGEST_LENGTH];
      CC_SHA256(host, (CC_LONG)strlen(host), digest);
      if (plain.length < 32 || memcmp(plain.bytes, digest, 32) != 0) plain = nil;
      else plain = [plain subdataWithRange:NSMakeRange(32, plain.length - 32)];
    }
    NSString* value = plain ? [[NSString alloc] initWithData:plain encoding:NSUTF8StringEncoding] : nil;
    if (!value) {
      local.undecryptable++;
      continue;
    }
    ArcCookie* c = [ArcCookie new];
    c.host = @(host);
    c.name = @((const char*)sqlite3_column_text(st, 1));
    c.value = value;
    c.path = @((const char*)sqlite3_column_text(st, 3));
    c.expiresUTC = expires;
    c.secure = sqlite3_column_int(st, 5) != 0;
    c.httpOnly = sqlite3_column_int(st, 6) != 0;
    c.hasExpires = hasExpires;
    c.creationUTC = sqlite3_column_int64(st, 8);
    c.lastAccessUTC = sqlite3_column_int64(st, 9);
    c.sameSite = sqlite3_column_int(st, 10);
    c.priority = sqlite3_column_int(st, 11);
    [out addObject:c];
  }
  sqlite3_finalize(st);
  sqlite3_close(db);
  for (NSString* ext in @[ @"", @"-wal", @"-journal" ]) [fm removeItemAtPath:[tmp stringByAppendingString:ext] error:nil];
  if (stats) *stats = local;
  return out;
}
