// Password saving and autofill in NotArc's own pages (#67): the page script, the save prompt, the fill menu,
// Edit > AutoFill > Fill Password, the Passwords window, and File > Import Passwords. Data lives in PasswordStore.
#pragma once

#ifdef __cplusplus
#include <string>
// The script each http(s) document gets (BrowserClient::InjectAutofillShim). It only reports; it never fills on
// its own. `nonce` ties its messages to the frame it was injected into.
std::string AutofillShimScript(const std::string& nonce);
#endif

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

@class MainWindowController, PasswordStore;

// Device authentication (Touch ID or the Mac's password) before showing or copying a password or filling a card.
// Self-test runs never show it: they count the request and allow it.
void AutofillAuthenticate(NSString* reason, void (^done)(BOOL ok));
NSInteger AutofillAuthRequestsForTest(void);
extern NSString* const kSettingPasswordSavingOff;  // BOOL, default NO: NotArc offers to save passwords

@interface PasswordsWindowController : NSWindowController
+ (instancetype)shared;
@property(nonatomic, copy) NSPasteboard* (^pasteboardProvider)(void);  // private pasteboard in tests
- (void)reload;
// Tests: the list as shown (0 passwords, 1 addresses, 2 cards), search, and the row buttons.
@property(nonatomic) NSInteger section;
- (void)setSearchText:(NSString*)text;
- (NSInteger)rowCount;
- (NSString*)titleAtRow:(NSInteger)row;
- (NSString*)shownSecretAtRow:(NSInteger)row;  // the revealed password, or nil while hidden
- (void)showSecretAtRow:(NSInteger)row;         // asks for device authentication first
- (void)copySecretAtRow:(NSInteger)row;         // asks for device authentication first
- (void)deleteRow:(NSInteger)row;
// Add... in the current section. Keys: website/username/password; name, org, line1, line2, city, state, zip,
// country, tel, email; number/name/month/year. NO if invalid or already saved.
- (BOOL)addEntry:(NSDictionary<NSString*, NSString*>*)values;
@end

// One per window. MainWindowController forwards the page messages here.
@interface AutofillController : NSObject
- (instancetype)initWithHost:(MainWindowController*)host;
- (void)handleMessage:(NSString*)json browser:(int)browserId nonce:(NSString*)nonce origin:(NSString*)origin
            mainFrame:(BOOL)mainFrame;
- (void)fillPasswordInBrowser:(int)browserId;  // Edit > AutoFill > Fill Password
- (void)importPasswordsFromMenu;               // File > Import Passwords...
// Tests: the save prompt and the fill menu without clicking.
@property(nonatomic, readonly) NSString* pendingSavePrompt;  // "Save password for ..." / "Update password ..." / nil
- (void)savePending:(id)sender;
- (void)neverPending:(id)sender;
@property(nonatomic) BOOL recordMenusOnly;                   // tests: remember the menu instead of showing it
@property(nonatomic, readonly) NSArray<NSString*>* lastMenuTitles;
@property(nonatomic, readonly) NSString* lastMenuGroup;      // "login", "address", "card"
@property(nonatomic, readonly) NSInteger menusOffered;       // fill menus offered so far
- (void)chooseMenuItemAtIndex:(NSInteger)index;
@property(nonatomic, readonly) NSInteger lastFilledCount;    // fields the last fill set (-1 before any)
@end
#endif
