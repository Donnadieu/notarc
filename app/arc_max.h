// Arc Max (#58, #59): Ask on Page, ChatGPT in the command bar, 5-second link previews, Tidy Tabs, tidy tab
// titles, page summaries and Copy Page as Markdown. The AI parts run on the Mac with Apple's built-in on-device
// model (app/on_device_ai.swift); when it isn't available every feature falls back to a non-AI version or is
// hidden. This file holds the parts that don't need a window: settings, the model wrapper (with a test stub),
// prompt building and reply parsing, the page scripts and their reply channel, the non-AI fallbacks, the link
// preview fetcher, the Settings section and the answer panel.
#pragma once

#import <Cocoa/Cocoa.h>

// Settings (Settings > Max). The master switch turns every Max feature off at once.
extern NSString* const kSettingMaxEnabled;      // BOOL, default YES
extern NSString* const kSettingMaxAskOnPage;    // BOOL, default YES: Ask on Page and Summarize Page
extern NSString* const kSettingMaxChatGPT;      // BOOL, default YES: "Ask ChatGPT" row in the command bar
extern NSString* const kSettingMaxPreviews;     // BOOL, default YES: Shift+hover a link for a short summary
extern NSString* const kSettingMaxTidyTabs;     // BOOL, default YES: Tidy Tabs (Today tabs into folders)
extern NSString* const kSettingMaxTidyTitles;   // BOOL, default YES: tidy titles (#18) use the on-device model
NSDictionary* MaxDefaultSettings(void);
BOOL MaxFeatureOn(NSString* key);  // master switch and the feature's own switch
NSView* MaxSettingsSection(void);  // the Settings window's "Max" section

// The on-device model. Availability is "available" or "unavailable:<reason>" (os, device, off, notready, other).
NSString* MaxModelAvailability(void);
BOOL MaxModelAvailable(void);
BOOL MaxTidyTitlesUseModel(void);  // Max and its tidy-title switch on, and the model available
NSString* MaxModelStatusText(NSString* availability);  // a sentence for Settings and the panels
typedef void (^MaxReply)(NSString* text, NSString* error);
typedef void (^MaxResponder)(NSString* instructions, NSString* prompt, MaxReply done);
void MaxRespond(NSString* instructions, NSString* prompt, MaxReply done);  // done runs on the main queue
// Self-test: a fake model (availability string + responder). Pass nil, nil to go back to the real one.
void MaxSetTestModel(NSString* availability, MaxResponder responder);
NSString* MaxRealModelAvailability(void);  // ignores the test stub

// Prompts and replies (pure).
NSString* MaxTrimText(NSString* text, NSUInteger limit);  // collapses blank runs, cuts at a word boundary
NSString* MaxAskInstructions(void);
NSString* MaxAskPrompt(NSString* question, NSString* title, NSString* url, NSString* pageText);
NSString* MaxSummaryInstructions(NSUInteger bullets);
NSString* MaxSummaryPrompt(NSString* title, NSString* url, NSString* pageText, NSUInteger limit);
NSString* MaxTidyTabsInstructions(void);
NSString* MaxTidyTabsPrompt(NSArray<NSDictionary*>* tabs);  // each @{title, url}
// "Folder: 1, 3" lines -> @[@{name, indexes (0-based NSNumbers)}]; drops bad numbers, repeats and 1-tab groups.
NSArray<NSDictionary*>* MaxParseTidyGroups(NSString* reply, NSUInteger tabCount);
NSArray<NSDictionary*>* MaxGroupTabsBySite(NSArray<NSDictionary*>* tabs);  // non-AI Tidy Tabs: same site, 2+ tabs
NSString* MaxTidyTitleInstructions(void);
NSString* MaxTidyTitlePrompt(NSString* title, NSString* url);
NSString* MaxCleanModelTitle(NSString* reply);              // first line, no quotes or trailing dot, <= 60 chars
NSString* MaxCleanSummary(NSString* reply);                 // trims, normalises bullets to "• "
// Non-AI fallbacks.
NSArray<NSString*>* MaxSentences(NSString* text);
NSString* MaxExtractiveSummary(NSString* text, NSUInteger count);   // the most central sentences, in page order
NSString* MaxBestMatchingSentences(NSString* question, NSString* text, NSUInteger count);
// ChatGPT in the command bar: https://chatgpt.com/?q=<question>, opened in the Space's own sign-in.
NSString* MaxChatGPTURL(NSString* question);

// Page scripts. Each posts its result back as console lines "__notarc_max__:<nonce>:<i>/<n>:<chunk>"; the
// browser client hands them to MaxHandleConsoleMessage, which reassembles them and calls the waiting block.
NSString* MaxNewNonce(void);
NSString* MaxPageTextScript(NSString* nonce);      // JSON {title, url, description, text}
NSString* MaxPageMarkdownScript(NSString* nonce);  // Markdown of the page (our own DOM-to-Markdown walker)
void MaxExpectPageReply(NSString* nonce, NSTimeInterval timeout, void (^done)(NSString* payload));  // nil on timeout
BOOL MaxHandleConsoleMessage(NSString* message);   // YES if it was ours (swallowed)

// 5-second previews: fetches a linked page without cookies (ephemeral session) and pulls out its title,
// description and readable text. Self-tests install a fake fetcher instead (no network).
NSDictionary* MaxParseHTML(NSString* html);  // @{title, description, text}
typedef void (^MaxFetchDone)(NSString* html, NSString* error);
void MaxFetchPage(NSString* url, MaxFetchDone done);  // done on the main queue
void MaxSetTestFetcher(void (^fetcher)(NSString* url, MaxFetchDone done));
BOOL MaxPreviewURLAllowed(NSString* url);  // http(s) only

// The small panel that shows answers and summaries over the page.
@interface MaxPanel : NSPanel
@property(nonatomic, copy) void (^onAsk)(NSString* question);
@property(nonatomic, copy) void (^onChatGPT)(NSString* question);
- (void)showAskOver:(NSWindow*)parent;               // question field, empty answer
- (void)showTitle:(NSString*)title over:(NSWindow*)parent;  // summaries: no question field
- (void)setBusy:(NSString*)message;
- (void)setAnswer:(NSString*)text note:(NSString*)note offerChatGPT:(BOOL)chatgpt;
@property(nonatomic, readonly) NSString* answerText;
@property(nonatomic, readonly) NSString* noteText;
@property(nonatomic, readonly) BOOL chatGPTOffered;
@property(nonatomic, readonly) NSString* question;
@end
