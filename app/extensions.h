// Chrome extensions for Chrome-style pages (#66): installing from the Chrome Web Store without Chrome's own
// installer, and the list behind the extension picker.
//
// CEF has no API to install or load an extension while running, so NotArc keeps one folder of unpacked extensions
// (Arc copies and Web Store installs, one folder per extension ID) and loads it with --load-extension at startup.
// A Web Store install downloads the extension's signed .crx from the Web Store's public update URL, checks every
// signature in it and that the package belongs to the requested ID, then unpacks it with the manifest "key" set, so
// the unpacked copy keeps the Web Store ID (and with it the extension's saved settings).
#pragma once

#import <Foundation/Foundation.h>

extern NSString* const kDisabledExtensionsKey;  // user default: NSArray of extension IDs turned off in the picker

@interface NotArcExtension : NSObject
@property(nonatomic, copy) NSString* extensionID;
@property(nonatomic, copy) NSString* name;
@property(nonatomic, copy) NSString* version;
@property(nonatomic, copy) NSString* path;         // folder holding manifest.json
@property(nonatomic, copy) NSString* popupPage;    // action popup, relative to the extension root; nil if none
@property(nonatomic, copy) NSString* optionsPage;  // options page, relative; nil if none
@property(nonatomic, copy) NSString* iconPath;     // absolute; nil if none
@property(nonatomic) BOOL enabled;
// YES: in NotArc's folder (Arc copy or Install Extension). NO: installed by Chromium itself into a Space's profile
// (Chrome Web Store's own button); Chromium owns those, so they're managed on chrome://extensions.
@property(nonatomic) BOOL managedByNotArc;
@end

// "abcdefghijklmnopabcdefghijklmnop", or a Chrome Web Store link (new or old store), -> the extension ID; nil if neither.
NSString* ExtensionIDFromInput(NSString* input);
// The Web Store's public download link for an extension's current .crx.
NSURL* WebStoreCRXURL(NSString* extensionID);
// Chromium's ID for a public key (SubjectPublicKeyInfo DER): SHA-256, first 16 bytes, each nibble as a-p.
NSString* ExtensionIDForPublicKey(NSData* spki);

// Checks and unpacks a CRX3 package into destination/<id>, replacing any older copy. expectedID nil = any ID.
// Returns the extension's display name, or nil with an error a person can read.
NSString* InstallExtensionCRX(NSData* crx, NSString* expectedID, NSString* destination, NSError** error);

// Download (from the Web Store) + InstallExtensionCRX, off the main thread. `done` runs on the main thread.
typedef void (^ExtensionFetcher)(NSURL* url, void (^done)(NSData* data, NSError* error));
void InstallExtensionFromWebStore(NSString* extensionID, NSString* destination,
                                  void (^done)(NSString* extensionID, NSString* name, NSError* error));
void SetExtensionFetcherForTest(ExtensionFetcher fetcher);  // self-tests: never touch the network

// Folders to pass to --load-extension: every extension in `directory` except the turned-off ones.
NSArray<NSString*>* ExtensionLoadPaths(NSString* directory, NSSet<NSString*>* disabled);
// NotArc's own extensions plus the ones Chromium installed into the given profile folders, sorted by name.
NSArray<NotArcExtension*>* InstalledExtensions(NSString* directory, NSArray<NSString*>* profileDirs,
                                               NSSet<NSString*>* disabled);
BOOL RemoveExtensionFolder(NSString* directory, NSString* extensionID);

// Self-tests: a signed CRX3 built from scratch (fresh in-memory RSA key, never stored) holding `files`.
NSData* BuildTestCRX(NSDictionary<NSString*, NSData*>* files, NSString** extensionID);
