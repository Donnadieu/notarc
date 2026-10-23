// Read Arc's (Chromium) cookie database so logins carry over into NotArc Spaces.
// Chromium macOS scheme: value = "v10" + AES-128-CBC(key, iv = 16 spaces, PKCS7), where
// key = PBKDF2-HMAC-SHA1(<Keychain "Arc Safe Storage" password>, "saltysalt", 1003 rounds, 16 bytes).
// DB meta version >= 24 prefixes the plaintext with SHA-256(host_key), which we verify and strip.
#pragma once

#import <Foundation/Foundation.h>

// Shows a macOS Keychain prompt the first time (the item belongs to Arc).
NSString* ArcSafeStoragePassword(NSError** error);
NSData* ArcCookieKey(NSString* password);

@interface ArcCookie : NSObject
@property(nonatomic, copy) NSString* host;  // host_key: ".example.com" = domain cookie
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* value;
@property(nonatomic, copy) NSString* path;
@property(nonatomic) BOOL secure;
@property(nonatomic) BOOL httpOnly;
@property(nonatomic) BOOL hasExpires;
@property(nonatomic) int64_t expiresUTC;  // microseconds since 1601-01-01 (same as cef_basetime_t)
@property(nonatomic) int64_t creationUTC;
@property(nonatomic) int64_t lastAccessUTC;
@property(nonatomic) int sameSite;  // Chromium DB: -1 unspecified, 0 none, 1 lax, 2 strict
@property(nonatomic) int priority;  // Chromium DB: 0 low, 1 medium, 2 high
@end

typedef struct {
  NSUInteger total;
  NSUInteger expired;
  NSUInteger undecryptable;
} ArcCookieStats;

// Copies the DB first (Arc keeps it open). Expired cookies are skipped.
NSArray<ArcCookie*>* ArcReadCookies(NSString* dbPath, NSData* key, ArcCookieStats* stats, NSError** error);
NSString* ArcCookieDBPath(NSString* profileDirectory);  // .../Arc/User Data/<profile>/Cookies
