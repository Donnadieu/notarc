// Arc Max (#58, #59) in the main window: Ask on Page, page summaries, Copy Page as Markdown, ChatGPT from the
// command bar, 5-second link previews (Shift + pointing at a link), Tidy Tabs and tidy tab titles. The model, the
// prompts, the page scripts and the fallbacks live in app/arc_max.mm.
#pragma once

#import "app/main_window.h"

@interface MainWindowController (Max)
// Menu commands (View > Ask on Page... Cmd+Shift+A, View > Summarize Page, View > Tidy Tab Title,
// Edit > Copy Page as Markdown, Tabs > Tidy Today Tabs).
- (IBAction)showAskOnPage:(id)sender;
- (IBAction)summarizePage:(id)sender;
- (IBAction)copyPageAsMarkdown:(id)sender;
- (IBAction)tidyTodayTabs:(id)sender;
- (IBAction)tidyTabTitle:(id)sender;
- (IBAction)undoTidyTabs:(id)sender;
// Called from validateMenuItem:; sets *handled for Max's own items.
- (BOOL)maxValidateMenuItem:(NSMenuItem*)mi handled:(BOOL*)handled;

// The same work for a given tab (the menu commands use the shown tab).
- (void)maxPageTextOfItem:(ArcItem*)item done:(void (^)(NSDictionary* page))done;  // nil if unreadable
- (void)maxPageMarkdownOfItem:(ArcItem*)item done:(void (^)(NSString* markdown))done;
- (void)askOnPage:(NSString*)question item:(ArcItem*)item done:(void (^)(NSString* answer, BOOL usedModel))done;
- (void)summarizeItem:(ArcItem*)item done:(void (^)(NSString* summary, BOOL usedModel))done;
- (void)copyMarkdownOfItem:(ArcItem*)item done:(void (^)(NSString* markdown))done;
// Tidy Tabs: the Space's top-level Today tabs into topic folders (on-device model) or by site (fallback).
// Registers "Tidy Tabs" with the sidebar's undo manager.
- (void)tidyTabsInSpace:(ArcSpace*)space done:(void (^)(NSArray<ArcItem*>* folders, BOOL usedModel))done;
// Tidy tab title: the on-device model's short name when MaxTidyTitlesUseModel(), else (or when its reply is
// unusable) the rule-based TidyTabTitle (#18). Undoable as "Tidy Tab Title". `title` is nil when nothing changed.
- (void)tidyTitleOfItem:(ArcItem*)item announce:(BOOL)announce done:(void (^)(NSString* title, BOOL usedModel))done;
// ChatGPT in the command bar: the suggestion row and what it opens.
- (NSDictionary*)maxChatGPTSuggestionFor:(NSString*)text;  // nil when off or the text is an address
- (NSString*)openChatGPTFor:(NSString*)question;           // new tab; returns its address

// 5-second previews. CEF reports the link under the pointer (status message); with Shift held a small card shows
// a short on-device summary of the linked page (fetched without cookies). Moving off the link hides it.
- (void)maxLinkHovered:(NSString*)url browser:(int)browserId;
- (void)maxLinkHovered:(NSString*)url shiftDown:(BOOL)shift;  // tests

// Tests.
@property(nonatomic, readonly) BOOL maxPanelShown;
@property(nonatomic, readonly) NSString* maxPanelAnswer;
@property(nonatomic, readonly) NSString* maxPanelNote;
@property(nonatomic, readonly) BOOL maxPanelOffersChatGPT;
@property(nonatomic, readonly) BOOL maxPreviewShown;
@property(nonatomic, readonly) NSString* maxPreviewText;
- (void)hideMaxPanels;
- (void)maxLoadItemInBackground:(ArcItem*)item;  // creates the tab's web view without showing it
@end
