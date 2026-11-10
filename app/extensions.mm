#import "app/extensions.h"
#import "app/arc_extensions.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

#include <vector>

NSString* const kDisabledExtensionsKey = @"disabledExtensions";

@implementation NotArcExtension
@end

static BOOL IsExtensionID(NSString* s) {
  if (s.length != 32) return NO;
  for (NSUInteger i = 0; i < 32; ++i) {
    unichar c = [s characterAtIndex:i];
    if (c < 'a' || c > 'p') return NO;
  }
  return YES;
}

NSString* ExtensionIDFromInput(NSString* input) {
  NSString* text = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (IsExtensionID(text)) return text;
  NSURL* url = [NSURL URLWithString:text];
  if (!url.host && text.length) url = [NSURL URLWithString:[@"https://" stringByAppendingString:text]];
  NSString* host = url.host.lowercaseString;
  NSArray<NSString*>* parts = url.pathComponents;
  BOOL store = ([host isEqualToString:@"chromewebstore.google.com"] && [parts containsObject:@"detail"]) ||
               ([host isEqualToString:@"chrome.google.com"] && parts.count > 2 && [parts[1] isEqualToString:@"webstore"] &&
                [parts containsObject:@"detail"]);
  if (!store) return nil;
  for (NSString* p in parts)
    if (IsExtensionID(p)) return p;
  return nil;
}

NSURL* WebStoreCRXURL(NSString* extensionID) {
  // prodversion: the Chromium inside NotArc, so the Web Store serves the build made for it.
  return [NSURL URLWithString:[NSString stringWithFormat:
      @"https://clients2.google.com/service/update2/crx?response=redirect&prodversion=156.0.8078.17"
      @"&acceptformat=crx3&x=id%%3D%@%%26installsource%%3Dondemand%%26uc", extensionID]];
}

static NSString* IDFromHashPrefix(const uint8_t* bytes) {
  char out[33];
  for (int i = 0; i < 16; ++i) {
    out[2 * i] = (char)('a' + (bytes[i] >> 4));
    out[2 * i + 1] = (char)('a' + (bytes[i] & 0xF));
  }
  out[32] = 0;
  return [NSString stringWithUTF8String:out];
}

NSString* ExtensionIDForPublicKey(NSData* spki) {
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(spki.bytes, (CC_LONG)spki.length, digest);
  return IDFromHashPrefix(digest);
}

static NSError* Fail(NSString* message) {
  return [NSError errorWithDomain:@"NotArcExtensions" code:1 userInfo:@{NSLocalizedDescriptionKey : message}];
}

// --- Minimal protobuf reader (CRX3 header: CrxFileHeader / AsymmetricKeyProof / SignedData) ---
namespace {
struct PBField {
  uint64_t number = 0;
  NSData* bytes = nil;  // length-delimited fields only
};

bool ReadVarint(const uint8_t* p, size_t n, size_t* i, uint64_t* out) {
  uint64_t v = 0;
  for (int shift = 0; shift < 64 && *i < n; shift += 7) {
    uint8_t b = p[(*i)++];
    v |= (uint64_t)(b & 0x7F) << shift;
    if (!(b & 0x80)) {
      *out = v;
      return true;
    }
  }
  return false;
}

// Length-delimited fields of a message; false if the message is malformed.
bool ReadFields(NSData* msg, std::vector<PBField>* out) {
  const uint8_t* p = (const uint8_t*)msg.bytes;
  size_t n = msg.length, i = 0;
  while (i < n) {
    uint64_t key = 0;
    if (!ReadVarint(p, n, &i, &key)) return false;
    uint64_t wire = key & 7, number = key >> 3;
    if (wire == 0) {
      uint64_t ignore;
      if (!ReadVarint(p, n, &i, &ignore)) return false;
    } else if (wire == 2) {
      uint64_t len = 0;
      if (!ReadVarint(p, n, &i, &len) || len > n - i) return false;
      PBField f;
      f.number = number;
      f.bytes = [msg subdataWithRange:NSMakeRange(i, (NSUInteger)len)];
      out->push_back(f);
      i += (size_t)len;
    } else if (wire == 5) {
      if (n - i < 4) return false;
      i += 4;
    } else if (wire == 1) {
      if (n - i < 8) return false;
      i += 8;
    } else {
      return false;
    }
  }
  return true;
}

// DER: the BIT STRING key inside a SubjectPublicKeyInfo (PKCS#1 for RSA, the X9.63 point for EC).
bool DERReadLength(const uint8_t* p, size_t n, size_t* i, size_t* len) {
  if (*i >= n) return false;
  uint8_t b = p[(*i)++];
  if (b < 0x80) {
    *len = b;
  } else {
    int count = b & 0x7F;
    if (count < 1 || count > 4) return false;
    size_t v = 0;
    for (int k = 0; k < count; ++k) {
      if (*i >= n) return false;
      v = (v << 8) | p[(*i)++];
    }
    *len = v;
  }
  return *len <= n - *i;
}

NSData* KeyInsideSPKI(NSData* spki) {
  const uint8_t* p = (const uint8_t*)spki.bytes;
  size_t n = spki.length, i = 0, len = 0;
  if (n < 2 || p[i++] != 0x30 || !DERReadLength(p, n, &i, &len)) return nil;
  if (i >= n || p[i++] != 0x30 || !DERReadLength(p, n, &i, &len)) return nil;
  i += len;  // AlgorithmIdentifier
  if (i >= n || p[i++] != 0x03 || !DERReadLength(p, n, &i, &len) || len < 2 || p[i] != 0) return nil;
  return [spki subdataWithRange:NSMakeRange(i + 1, len - 1)];
}

NSData* DERWrap(uint8_t tag, NSData* content) {
  NSMutableData* d = [NSMutableData dataWithBytes:&tag length:1];
  NSUInteger len = content.length;
  if (len < 0x80) {
    uint8_t b = (uint8_t)len;
    [d appendBytes:&b length:1];
  } else {
    uint8_t buf[5];
    int count = 0;
    for (NSUInteger v = len; v; v >>= 8) ++count;
    buf[0] = (uint8_t)(0x80 | count);
    for (int k = 0; k < count; ++k) buf[1 + k] = (uint8_t)(len >> (8 * (count - 1 - k)));
    [d appendBytes:buf length:1 + count];
  }
  [d appendData:content];
  return d;
}

bool VerifyProof(NSData* spki, NSData* signature, NSData* message, bool rsa) {
  NSData* raw = KeyInsideSPKI(spki);
  if (!raw) return false;
  NSDictionary* attrs = @{
    (id)kSecAttrKeyType : rsa ? (id)kSecAttrKeyTypeRSA : (id)kSecAttrKeyTypeECSECPrimeRandom,
    (id)kSecAttrKeyClass : (id)kSecAttrKeyClassPublic,
  };
  SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)raw, (__bridge CFDictionaryRef)attrs, NULL);
  if (!key) return false;
  SecKeyAlgorithm alg = rsa ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256 : kSecKeyAlgorithmECDSASignatureMessageX962SHA256;
  bool ok = SecKeyVerifySignature(key, alg, (__bridge CFDataRef)message, (__bridge CFDataRef)signature, NULL);
  CFRelease(key);
  return ok;
}

NSData* SignedMessage(NSData* signedHeader, NSData* archive) {
  static const char kPrefix[] = "CRX3 SignedData";  // including its terminating NUL
  NSMutableData* m = [NSMutableData dataWithBytes:kPrefix length:sizeof(kPrefix)];
  uint32_t len = CFSwapInt32HostToLittle((uint32_t)signedHeader.length);
  [m appendBytes:&len length:4];
  [m appendData:signedHeader];
  [m appendData:archive];
  return m;
}

BOOL RunDitto(NSArray<NSString*>* args) {
  NSTask* t = [NSTask new];
  t.executableURL = [NSURL fileURLWithPath:@"/usr/bin/ditto"];
  t.arguments = args;
  t.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  t.standardError = NSFileHandle.fileHandleWithNullDevice;
  if (![t launchAndReturnError:nil]) return NO;
  [t waitUntilExit];
  return t.terminationStatus == 0;
}
}  // namespace

NSString* InstallExtensionCRX(NSData* crx, NSString* expectedID, NSString* destination, NSError** error) {
  NSError* e = nil;
  NSString* name = nil;
  do {
    const uint8_t* p = (const uint8_t*)crx.bytes;
    if (crx.length < 12 || memcmp(p, "Cr24", 4) != 0) { e = Fail(@"The download isn't a Chrome extension package."); break; }
    uint32_t version = OSReadLittleInt32(p, 4), headerLen = OSReadLittleInt32(p, 8);
    if (version != 3) { e = Fail(@"This extension package uses an old format NotArc can't check."); break; }
    if (headerLen > crx.length - 12) { e = Fail(@"The extension package is damaged."); break; }
    NSData* header = [crx subdataWithRange:NSMakeRange(12, headerLen)];
    NSData* archive = [crx subdataWithRange:NSMakeRange(12 + headerLen, crx.length - 12 - headerLen)];
    std::vector<PBField> fields;
    if (!ReadFields(header, &fields)) { e = Fail(@"The extension package is damaged."); break; }
    NSData* signedHeader = nil;
    for (auto& f : fields) if (f.number == 10000) signedHeader = f.bytes;
    std::vector<PBField> sh;
    NSData* crxID = nil;
    if (signedHeader && ReadFields(signedHeader, &sh))
      for (auto& f : sh) if (f.number == 1 && f.bytes.length == 16) crxID = f.bytes;
    if (!crxID) { e = Fail(@"The extension package isn't signed."); break; }
    NSString* packageID = IDFromHashPrefix((const uint8_t*)crxID.bytes);
    if (expectedID && ![packageID isEqualToString:expectedID]) {
      e = Fail(@"The package belongs to a different extension than the one asked for.");
      break;
    }
    // Every signature must check out, and one of them must be made with the key the ID comes from.
    NSData* message = SignedMessage(signedHeader, archive);
    NSData* ownKey = nil;
    int proofs = 0;
    bool allValid = true;
    for (auto& f : fields) {
      if (f.number != 2 && f.number != 3) continue;
      std::vector<PBField> proof;
      NSData *key = nil, *sig = nil;
      if (ReadFields(f.bytes, &proof))
        for (auto& q : proof) {
          if (q.number == 1) key = q.bytes;
          if (q.number == 2) sig = q.bytes;
        }
      ++proofs;
      if (!key || !sig || !VerifyProof(key, sig, message, f.number == 2)) { allValid = false; break; }
      if ([ExtensionIDForPublicKey(key) isEqualToString:packageID]) ownKey = key;
    }
    if (!proofs || !allValid || !ownKey) { e = Fail(@"The extension's signature doesn't match its contents."); break; }

    // Unpack next to the destination, then swap in, so a failed install never leaves half a folder.
    NSFileManager* fm = NSFileManager.defaultManager;
    [fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* work = [destination stringByAppendingPathComponent:[@".installing-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString* zip = [work stringByAppendingPathExtension:@"zip"];
    NSString* dst = [destination stringByAppendingPathComponent:packageID];
    if (![archive writeToFile:zip atomically:NO] || !RunDitto(@[ @"-x", @"-k", zip, work ])) {
      e = Fail(@"Couldn't unpack the extension.");
    } else {
      NSString* mpath = [work stringByAppendingPathComponent:@"manifest.json"];
      NSData* md = [NSData dataWithContentsOfFile:mpath];
      NSMutableDictionary* manifest = md ? [NSJSONSerialization JSONObjectWithData:md options:NSJSONReadingMutableContainers error:nil] : nil;
      if (![manifest isKindOfClass:NSDictionary.class]) {
        e = Fail(@"The extension's manifest can't be read.");
      } else if ([manifest[@"manifest_version"] intValue] < 3) {
        e = Fail(@"This extension uses Manifest V2, which current Chromium no longer runs.");
      } else {
        manifest[@"key"] = [ownKey base64EncodedStringWithOptions:0];  // unpacked copy keeps the Web Store ID
        NSData* out = [NSJSONSerialization dataWithJSONObject:manifest
                                                      options:NSJSONWritingPrettyPrinted | NSJSONWritingWithoutEscapingSlashes
                                                        error:nil];
        // Web Store signature data only verifies Web Store installs; unpacked loading rejects it.
        [fm removeItemAtPath:[work stringByAppendingPathComponent:@"_metadata"] error:nil];
        if (!out || ![out writeToFile:mpath atomically:YES]) {
          e = Fail(@"Couldn't save the extension.");
        } else {
          [fm removeItemAtPath:dst error:nil];
          if ([fm moveItemAtPath:work toPath:dst error:nil]) name = ExtensionDisplayName(manifest, dst);
          else e = Fail(@"Couldn't save the extension.");
        }
      }
    }
    [fm removeItemAtPath:zip error:nil];
    [fm removeItemAtPath:work error:nil];
  } while (false);
  if (error) *error = e;
  return e ? nil : name;
}

static ExtensionFetcher g_testFetcher;
void SetExtensionFetcherForTest(ExtensionFetcher fetcher) { g_testFetcher = [fetcher copy]; }

void InstallExtensionFromWebStore(NSString* extensionID, NSString* destination,
                                  void (^done)(NSString* extensionID, NSString* name, NSError* error)) {
  void (^finish)(NSString*, NSError*) = ^(NSString* name, NSError* err) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(extensionID, name, err); });
  };
  void (^received)(NSData*, NSError*) = ^(NSData* data, NSError* err) {
    if (!data) {
      finish(nil, err ?: Fail(@"Couldn't download the extension."));
      return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSError* e = nil;
      NSString* name = InstallExtensionCRX(data, extensionID, destination, &e);
      finish(name, e);
    });
  };
  if (!IsExtensionID(extensionID)) {
    finish(nil, Fail(@"That isn't a Chrome Web Store link or extension ID."));
    return;
  }
  NSURL* url = WebStoreCRXURL(extensionID);
  if (g_testFetcher) {
    g_testFetcher(url, received);
    return;
  }
  NSURLSession* session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
  [[session dataTaskWithURL:url completionHandler:^(NSData* data, NSURLResponse* response, NSError* err) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
    if (err) received(nil, Fail([@"Couldn't reach the Chrome Web Store: " stringByAppendingString:err.localizedDescription]));
    else if (status == 404 || status == 204) received(nil, Fail(@"The Chrome Web Store has no extension with that ID."));
    else if (status != 200) received(nil, Fail([NSString stringWithFormat:@"The Chrome Web Store answered %ld.", (long)status]));
    else received(data, nil);
  }] resume];
  [session finishTasksAndInvalidate];
}

NSArray<NSString*>* ExtensionLoadPaths(NSString* directory, NSSet<NSString*>* disabled) {
  NSMutableArray* out = [NSMutableArray array];
  for (NSString* p in ArcCopiedExtensionPaths(directory))
    if (IsExtensionID(p.lastPathComponent) && ![disabled containsObject:p.lastPathComponent]) [out addObject:p];
  return out;
}

static NSString* PickIcon(id icons, NSString* root) {
  if ([icons isKindOfClass:NSString.class]) return [root stringByAppendingPathComponent:icons];
  if (![icons isKindOfClass:NSDictionary.class]) return nil;
  NSString* best = nil;
  int bestSize = 0;
  for (NSString* k in icons) {
    int s = k.intValue;
    if (![icons[k] isKindOfClass:NSString.class]) continue;
    // Prefer the smallest icon of at least 32 px; else the largest smaller one.
    BOOL better = !best || (s >= 32 && (bestSize < 32 || s < bestSize)) || (s < 32 && bestSize < 32 && s > bestSize);
    if (better) {
      best = icons[k];
      bestSize = s;
    }
  }
  return best ? [root stringByAppendingPathComponent:best] : nil;
}

static NotArcExtension* DescribeExtension(NSString* extID, NSString* dir) {
  NSData* md = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"manifest.json"]];
  NSDictionary* m = md ? [NSJSONSerialization JSONObjectWithData:md options:0 error:nil] : nil;
  if (![m isKindOfClass:NSDictionary.class]) return nil;
  NotArcExtension* x = [NotArcExtension new];
  x.extensionID = extID;
  x.path = dir;
  x.name = ExtensionDisplayName(m, dir).length ? ExtensionDisplayName(m, dir) : extID;
  x.version = [m[@"version"] isKindOfClass:NSString.class] ? m[@"version"] : @"";
  NSDictionary* action = [m[@"action"] isKindOfClass:NSDictionary.class]           ? m[@"action"]
                         : [m[@"browser_action"] isKindOfClass:NSDictionary.class] ? m[@"browser_action"]
                                                                                    : nil;
  if ([action[@"default_popup"] isKindOfClass:NSString.class] && [action[@"default_popup"] length])
    x.popupPage = action[@"default_popup"];
  NSDictionary* ui = [m[@"options_ui"] isKindOfClass:NSDictionary.class] ? m[@"options_ui"] : nil;
  if ([ui[@"page"] isKindOfClass:NSString.class]) x.optionsPage = ui[@"page"];
  else if ([m[@"options_page"] isKindOfClass:NSString.class]) x.optionsPage = m[@"options_page"];
  x.iconPath = PickIcon(m[@"icons"], dir) ?: PickIcon(action[@"default_icon"], dir);
  return x;
}

NSArray<NotArcExtension*>* InstalledExtensions(NSString* directory, NSArray<NSString*>* profileDirs,
                                               NSSet<NSString*>* disabled) {
  NSMutableArray<NotArcExtension*>* out = [NSMutableArray array];
  NSMutableSet* seen = [NSMutableSet set];
  for (NSString* p in ArcCopiedExtensionPaths(directory)) {
    if (!IsExtensionID(p.lastPathComponent)) continue;  // e.g. an install that was cut short
    NotArcExtension* x = DescribeExtension(p.lastPathComponent, p);
    if (!x) continue;
    x.managedByNotArc = YES;
    x.enabled = ![disabled containsObject:x.extensionID];
    [seen addObject:x.extensionID];
    [out addObject:x];
  }
  NSFileManager* fm = NSFileManager.defaultManager;
  for (NSString* profile in profileDirs) {
    NSString* root = [profile stringByAppendingPathComponent:@"Extensions"];
    for (NSString* extID in [fm contentsOfDirectoryAtPath:root error:nil]) {
      if (!IsExtensionID(extID) || [seen containsObject:extID]) continue;
      NSString* extDir = [root stringByAppendingPathComponent:extID];
      NSArray* versions = [[fm contentsOfDirectoryAtPath:extDir error:nil] sortedArrayUsingComparator:^(NSString* a, NSString* b) {
        return [a compare:b options:NSNumericSearch];
      }];
      NotArcExtension* x = versions.count ? DescribeExtension(extID, [extDir stringByAppendingPathComponent:versions.lastObject]) : nil;
      if (!x) continue;
      x.enabled = YES;  // Chromium keeps its own on/off state for these (chrome://extensions)
      [seen addObject:extID];
      [out addObject:x];
    }
  }
  [out sortUsingComparator:^(NotArcExtension* a, NotArcExtension* b) { return [a.name localizedCaseInsensitiveCompare:b.name]; }];
  return out;
}

BOOL RemoveExtensionFolder(NSString* directory, NSString* extensionID) {
  if (!IsExtensionID(extensionID)) return NO;
  return [NSFileManager.defaultManager removeItemAtPath:[directory stringByAppendingPathComponent:extensionID] error:nil];
}

// --- Self-tests ---
static NSData* PBBytes(uint64_t number, NSData* bytes) {
  NSMutableData* d = [NSMutableData data];
  auto varint = [&](uint64_t v) {
    do {
      uint8_t b = v & 0x7F;
      v >>= 7;
      if (v) b |= 0x80;
      [d appendBytes:&b length:1];
    } while (v);
  };
  varint((number << 3) | 2);
  varint(bytes.length);
  [d appendData:bytes];
  return d;
}

NSData* BuildTestCRX(NSDictionary<NSString*, NSData*>* files, NSString** extensionID) {
  NSDictionary* params = @{(id)kSecAttrKeyType : (id)kSecAttrKeyTypeRSA, (id)kSecAttrKeySizeInBits : @2048};
  SecKeyRef priv = SecKeyCreateRandomKey((__bridge CFDictionaryRef)params, NULL);  // in memory, never in a keychain
  if (!priv) return nil;
  SecKeyRef pub = SecKeyCopyPublicKey(priv);
  NSData* pkcs1 = CFBridgingRelease(SecKeyCopyExternalRepresentation(pub, NULL));
  CFRelease(pub);
  static const uint8_t kRSAAlg[] = {0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00};
  NSMutableData* bits = [NSMutableData dataWithLength:1];
  [bits appendData:pkcs1];
  NSMutableData* body = [NSMutableData dataWithBytes:kRSAAlg length:sizeof(kRSAAlg)];
  [body appendData:DERWrap(0x03, bits)];
  NSData* spki = DERWrap(0x30, body);
  NSString* extID = ExtensionIDForPublicKey(spki);

  NSString* dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"notarc-crx-" stringByAppendingString:NSUUID.UUID.UUIDString]];
  NSString* zip = [dir stringByAppendingPathExtension:@"zip"];
  for (NSString* rel in files) {
    NSString* f = [dir stringByAppendingPathComponent:rel];
    [NSFileManager.defaultManager createDirectoryAtPath:f.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    [files[rel] writeToFile:f atomically:NO];
  }
  BOOL zipped = RunDitto(@[ @"-c", @"-k", @"--norsrc", @"--noextattr", @"--noqtn", dir, zip ]);
  NSData* archive = zipped ? [NSData dataWithContentsOfFile:zip] : nil;
  [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
  [NSFileManager.defaultManager removeItemAtPath:zip error:nil];
  if (!archive) {
    CFRelease(priv);
    return nil;
  }
  uint8_t digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(spki.bytes, (CC_LONG)spki.length, digest);
  NSData* signedHeader = PBBytes(1, [NSData dataWithBytes:digest length:16]);
  NSData* sig = CFBridgingRelease(SecKeyCreateSignature(priv, kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256,
                                                        (__bridge CFDataRef)SignedMessage(signedHeader, archive), NULL));
  CFRelease(priv);
  if (!sig) return nil;
  NSMutableData* proof = [NSMutableData dataWithData:PBBytes(1, spki)];
  [proof appendData:PBBytes(2, sig)];
  NSMutableData* header = [NSMutableData dataWithData:PBBytes(2, proof)];
  [header appendData:PBBytes(10000, signedHeader)];
  NSMutableData* crx = [NSMutableData dataWithBytes:"Cr24" length:4];
  uint32_t v = CFSwapInt32HostToLittle(3), hl = CFSwapInt32HostToLittle((uint32_t)header.length);
  [crx appendBytes:&v length:4];
  [crx appendBytes:&hl length:4];
  [crx appendData:header];
  [crx appendData:archive];
  if (extensionID) *extensionID = extID;
  return crx;
}
