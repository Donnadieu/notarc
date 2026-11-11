// Test isolation: self-tests, restore tests, visual shots and sidebar snapshots must never touch the user's real
// NotArc profile (data folder or preferences).
//
// Why this exists: CFFIXED_USER_HOME moves NSHomeDirectory() (and so every NotArc data file) into a throwaway
// home, but NSUserDefaults writes still go through cfprefsd to the REAL
// ~/Library/Preferences/io.github.donnadieu.notarc.plist (checked Nov 10 2026). So any code path that wrote
// NSUserDefaults directly during a test (import done, updater check, window frames) changed the user's settings.
#import <Foundation/Foundation.h>

// The user's real home folder (from the password database), whatever CFFIXED_USER_HOME says.
NSString* TestIsolationRealHome(void);
// YES when NSHomeDirectory() is a throwaway home, not the real one.
BOOL TestIsolationHomeIsolated(void);
// Test runs only: from now on NSUserDefaults writes stay in memory, and the user's own saved NotArc preferences
// read as unset (argument and registration domains still apply). Also records the real profile's file times.
void TestIsolationInstall(void);
BOOL TestIsolationActive(void);
// "isolatedHome=1 prefsUntouched=1 dataUntouched=1 canaryHeld=1 blockedWrites=N": any 0 means a test touched the real profile.
// A change made while another NotArc (the user's own) is open counts as untouched; see TestIsolationDebug().
NSString* TestIsolationReport(void);
NSString* TestIsolationDebug(void);
