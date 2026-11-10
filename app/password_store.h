// NotArc's own password manager and autofill store (#67). NotArc pages run in CEF's Alloy style, which has no
// Chromium password manager, so NotArc keeps its own list of logins, addresses and cards.
//
// Store: one file in NotArc's data folder (Passwords.dat; SelfTestPasswords.dat in tests). The whole file is
// encrypted with Chromium's own scheme ("v10" + AES-128-CBC), and each password and card number is encrypted again
// inside it, so they stay encrypted in memory until used. The key comes from NotArc's own "NotArc Safe Storage"
// Keychain item (made on first use). Self-tests use a throwaway in-memory key and never touch the Keychain.
//
// Import: Chromium-family "Login Data" (+ "Login Data For Account") and "Web Data" (addresses, cards), read from a
// private copy (the other browser is never changed or locked), and password CSV files (Chrome, Firefox, Apple
// Passwords exports).
#pragma once

#import <Foundation/Foundation.h>

@interface SavedLogin : NSObject
@property(nonatomic, copy) NSString* origin;    // "https://example.com" (scheme://host[:port])
@property(nonatomic, copy) NSString* username;  // may be ""
@property(nonatomic, copy) NSData* sealedPassword;
@property(nonatomic, copy) NSString* source;    // "NotArc", "Arc (Default)", "Google Chrome (Person 1)", "CSV"
@property(nonatomic, strong) NSDate* created;
@property(nonatomic, strong) NSDate* lastUsed;
- (NSString*)host;
@end

// Address fields use these keys: name, given, middle, family, org, street (all lines), line1, line2, city, state,
// zip, country, tel, email.
@interface AutofillAddress : NSObject
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* fields;
@property(nonatomic, copy) NSString* source;
- (NSString*)summary;  // "Jane Doe, 1 Main St"
- (NSString*)fullName;
@end

@interface AutofillCard : NSObject
@property(nonatomic, copy) NSString* name;  // name on card
@property(nonatomic, copy) NSData* sealedNumber;
@property(nonatomic, copy) NSString* last4;
@property(nonatomic) int expMonth;
@property(nonatomic) int expYear;  // four digits
@property(nonatomic, copy) NSString* nickname;
@property(nonatomic, copy) NSString* source;
- (NSString*)summary;  // "•••• 4242 (Jane Doe, 04/2031)"
@end

typedef NS_ENUM(NSInteger, PasswordSaveResult) { PasswordUnchanged = 0, PasswordAdded = 1, PasswordUpdated = 2 };

@interface PasswordStore : NSObject
// The app's store. PasswordStoreConfigure must run first (at launch). The file and key load on first use.
+ (instancetype)shared;
- (instancetype)initWithPath:(NSString*)path key:(NSData*)key;
@property(nonatomic, readonly) NSString* path;
@property(nonatomic, readonly) BOOL usable;  // NO when the key is missing or the file can't be decrypted
@property(nonatomic, readonly) NSMutableArray<SavedLogin*>* logins;
@property(nonatomic, readonly) NSMutableArray<AutofillAddress*>* addresses;
@property(nonatomic, readonly) NSMutableArray<AutofillCard*>* cards;
@property(nonatomic, readonly) NSMutableSet<NSString*>* neverOrigins;  // "Never for this site"

- (NSData*)seal:(NSString*)secret;     // encrypts with the store key
- (NSString*)unseal:(NSData*)sealed;
- (NSString*)passwordFor:(SavedLogin*)login;
- (NSString*)cardNumberFor:(AutofillCard*)card;

- (SavedLogin*)loginForOrigin:(NSString*)origin username:(NSString*)username;
// Logins for a page: same origin first, then the same site on its other subdomains. A login saved on an https
// page is never offered on an http page.
- (NSArray<SavedLogin*>*)loginsForOrigin:(NSString*)origin;
- (PasswordSaveResult)saveOrigin:(NSString*)origin username:(NSString*)username password:(NSString*)password
                          source:(NSString*)source;
// What saving would do, without saving: Added (new), Updated (password changed) or Unchanged.
- (PasswordSaveResult)checkOrigin:(NSString*)origin username:(NSString*)username password:(NSString*)password;
// Added by hand in the Passwords window. Addresses need a street, email or phone; cards a number that passes the
// Luhn check (12-19 digits). NO when invalid or already saved.
- (BOOL)addAddressFields:(NSDictionary<NSString*, NSString*>*)fields;
- (BOOL)addCardNumber:(NSString*)number name:(NSString*)name month:(int)month year:(int)year;
- (void)removeLogin:(SavedLogin*)login;
- (void)removeAddress:(AutofillAddress*)address;
- (void)removeCard:(AutofillCard*)card;
- (void)setNever:(BOOL)never forOrigin:(NSString*)origin;
- (BOOL)isNeverOrigin:(NSString*)origin;
- (BOOL)save;
- (BOOL)reload;  // tests: drop the in-memory copy and read the file again
- (BOOL)unlockIfNeeded;  // reads NotArc's Keychain key again if it wasn't available; YES when usable

// Import one Chromium-family profile folder (Arc, Chrome, Brave, Edge, Vivaldi, Chromium) with that browser's
// Safe Storage key. Returns @{passwords, addresses, cards, never, undecryptable, existing} counts (existing = logins already here), or nil
// when nothing in the folder could be read. Importing twice adds nothing twice.
- (NSDictionary<NSString*, NSNumber*>*)importChromiumProfile:(NSString*)profileDir key:(NSData*)key source:(NSString*)source;
// Password CSV export (Chrome: name,url,username,password,note; Firefox: url,username,password,...; Apple
// Passwords: Title,URL,Username,Password,Notes,OTPAuth). Returns logins added, or NSNotFound if unreadable.
- (NSUInteger)importCSVFile:(NSString*)path source:(NSString*)source;
@end

// Call once at launch. Self-test runs use SelfTestPasswords.dat and a random in-memory key (never the Keychain).
void PasswordStoreConfigure(BOOL selfTest);
BOOL PasswordStoreIsSelfTest(void);
NSString* PasswordStorePath(BOOL selfTest);
// "https://Example.com:443/a?b" -> "https://example.com"; file URLs -> "file://"; nil for other schemes.
NSString* AutofillOriginOfURL(NSString* url);
// Parses one CSV document into rows (handles quotes, doubled quotes and newlines inside quotes).
NSArray<NSArray<NSString*>*>* AutofillParseCSV(NSString* text);
// Digits only, 12-19 long and passing the Luhn check; nil otherwise.
NSString* AutofillCardDigits(NSString* number);
