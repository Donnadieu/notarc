#import "app/main_window_max.h"

#import <objc/runtime.h>

#import "app/arc_import.h"
#import "app/arc_max.h"
#import "app/settings.h"

// Existing private methods of MainWindowController used here.
@interface MainWindowController (MaxPrivate)
- (void)reloadSidebar;
- (void)scheduleSave;
- (NSPasteboard*)copyPasteboard;
- (NSString*)itemCurrentURL:(ArcItem*)item;
- (void)ensureBrowserForItem:(ArcItem*)item;
- (void)layoutPanes;
- (void)showToast:(NSString*)text action:(NSString*)action selector:(SEL)selector;
@end

// The link preview card: a small borderless panel near the pointer.
@interface MaxPreviewCard : NSPanel
@property(nonatomic, copy) NSString* url;
- (void)setTitle:(NSString*)title site:(NSString*)site body:(NSString*)body note:(NSString*)note;
@property(nonatomic, readonly) NSString* bodyText;
@end

@implementation MaxPreviewCard {
  NSTextField* _title;
  NSTextField* _site;
  NSTextField* _body;
  NSTextField* _note;
}
- (instancetype)init {
  self = [super initWithContentRect:NSMakeRect(0, 0, 320, 120)
                          styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                            backing:NSBackingStoreBuffered
                              defer:YES];
  if (!self) return nil;
  self.releasedWhenClosed = NO;
  self.opaque = NO;
  self.backgroundColor = NSColor.clearColor;
  self.hasShadow = YES;
  self.ignoresMouseEvents = YES;  // never steals the click on the link under it
  NSVisualEffectView* bg = [NSVisualEffectView new];
  bg.material = NSVisualEffectMaterialPopover;
  bg.state = NSVisualEffectStateActive;
  bg.wantsLayer = YES;
  bg.layer.cornerRadius = 10;
  bg.layer.masksToBounds = YES;
  self.contentView = bg;
  _title = [NSTextField wrappingLabelWithString:@""];
  _title.font = [NSFont boldSystemFontOfSize:13];
  _title.maximumNumberOfLines = 2;
  _site = [NSTextField labelWithString:@""];
  _site.font = [NSFont systemFontOfSize:11];
  _site.textColor = NSColor.secondaryLabelColor;
  _body = [NSTextField wrappingLabelWithString:@""];
  _body.font = [NSFont systemFontOfSize:12];
  _body.maximumNumberOfLines = 8;
  _note = [NSTextField labelWithString:@""];
  _note.font = [NSFont systemFontOfSize:10];
  _note.textColor = NSColor.tertiaryLabelColor;
  for (NSTextField* f in @[ _title, _body ]) f.preferredMaxLayoutWidth = 292;
  NSStackView* stack = [NSStackView stackViewWithViews:@[ _title, _site, _body, _note ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 4;
  stack.edgeInsets = NSEdgeInsetsMake(10, 14, 10, 14);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [bg addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:bg.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:bg.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:bg.topAnchor], [stack.widthAnchor constraintEqualToConstant:320],
  ]];
  return self;
}
- (void)setTitle:(NSString*)title site:(NSString*)site body:(NSString*)body note:(NSString*)note {
  _title.stringValue = title ?: @"";
  _site.stringValue = site ?: @"";
  _body.stringValue = body ?: @"";
  _note.stringValue = note ?: @"";
  _note.hidden = !note.length;
  NSView* stack = self.contentView.subviews.firstObject;
  [stack layoutSubtreeIfNeeded];
  NSRect top = self.frame;
  CGFloat h = MIN(320, stack.fittingSize.height);
  [self setFrame:NSMakeRect(top.origin.x, NSMaxY(top) - h, 320, h) display:YES];
}
- (NSString*)bodyText { return _body.stringValue; }
@end

// Per-window state (a category can't add instance variables).
@interface MaxWindowState : NSObject
@property(nonatomic, strong) MaxPanel* panel;
@property(nonatomic, strong) MaxPreviewCard* card;
@property(nonatomic, copy) NSString* hoverURL;
@property(nonatomic, strong) id flagsMonitor;
@property(nonatomic, strong) NSCache<NSString*, NSArray*>* previewCache;  // url -> @[title, body, note]
@property(nonatomic, weak) ArcItem* panelItem;
@end
@implementation MaxWindowState
@end

static const void* kMaxStateKey = &kMaxStateKey;

static NSString* SiteLabel(NSString* url) {
  NSString* h = [NSURL URLWithString:url ?: @""].host ?: @"";
  return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

static BOOL IsWebItem(ArcItem* item) {
  return item && !item.isFolder && !item.isSplit && !item.noteID && !item.easelID &&
         ([item.url hasPrefix:@"http://"] || [item.url hasPrefix:@"https://"]);
}

@implementation MainWindowController (Max)

- (MaxWindowState*)maxState {
  MaxWindowState* s = objc_getAssociatedObject(self, kMaxStateKey);
  if (!s) {
    s = [MaxWindowState new];
    s.previewCache = [NSCache new];
    s.previewCache.countLimit = 50;
    objc_setAssociatedObject(self, kMaxStateKey, s, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return s;
}

- (MaxPanel*)maxPanel {
  MaxWindowState* s = [self maxState];
  if (!s.panel) {
    s.panel = [MaxPanel new];
    __weak MainWindowController* weakSelf = self;
    s.panel.onAsk = ^(NSString* q) {
      MainWindowController* me = weakSelf;
      [me askOnPage:q item:[me maxState].panelItem ?: me.shownItem done:nil];
    };
    s.panel.onChatGPT = ^(NSString* q) {
      MainWindowController* me = weakSelf;
      ArcItem* item = [me maxState].panelItem ?: me.shownItem;
      NSString* url = item ? [me itemCurrentURL:item] : nil;
      NSString* text = q.length ? (url.length ? [NSString stringWithFormat:@"%@ (about %@)", q, url] : q)
                                : (url.length ? [@"Summarize this page: " stringByAppendingString:url] : @"");
      [me openChatGPTFor:text];
    };
  }
  return s.panel;
}

#pragma mark Page access

- (void)maxRunScript:(NSString* (*)(NSString*))make item:(ArcItem*)item done:(void (^)(NSString*))done {
  if (!IsWebItem(item) || !item.browserId) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(nil); });
    return;
  }
  NSString* nonce = MaxNewNonce();
  MaxExpectPageReply(nonce, 8, done);
  [self runJS:make(nonce) inItem:item];
}

- (void)maxPageTextOfItem:(ArcItem*)item done:(void (^)(NSDictionary*))done {
  [self maxRunScript:MaxPageTextScript item:item done:^(NSString* payload) {
    NSDictionary* page = nil;
    if (payload.length) {
      id obj = [NSJSONSerialization JSONObjectWithData:[payload dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
      if ([obj isKindOfClass:NSDictionary.class] && !obj[@"error"]) page = obj;
    }
    done(page);
  }];
}

- (void)maxPageMarkdownOfItem:(ArcItem*)item done:(void (^)(NSString*))done {
  [self maxRunScript:MaxPageMarkdownScript item:item done:^(NSString* md) { done(md.length ? md : nil); }];
}

- (void)maxLoadItemInBackground:(ArcItem*)item {
  [self ensureBrowserForItem:item];
  [self layoutPanes];
}

#pragma mark Ask on Page and summaries

- (IBAction)showAskOnPage:(id)sender {
  if (!MaxFeatureOn(kSettingMaxAskOnPage) || !IsWebItem(self.shownItem)) {
    NSBeep();
    return;
  }
  [self maxState].panelItem = self.shownItem;
  [[self maxPanel] showAskOver:self.window];
}

- (void)askOnPage:(NSString*)question item:(ArcItem*)item done:(void (^)(NSString*, BOOL))done {
  MaxPanel* p = [self maxPanel];
  [self maxState].panelItem = item;
  if (!p.isVisible) [p showAskOver:self.window];
  [p setBusy:@"Reading the page…"];
  void (^finish)(NSString*, BOOL) = ^(NSString* a, BOOL ai) {
    if (done) done(a, ai);
  };
  [self maxPageTextOfItem:item done:^(NSDictionary* page) {
    if (!page) {
      [p setAnswer:nil note:@"NotArc couldn't read this page." offerChatGPT:YES];
      finish(nil, NO);
      return;
    }
    NSString* text = page[@"text"] ?: @"";
    void (^fallback)(NSString*) = ^(NSString* why) {
      NSString* matches = MaxBestMatchingSentences(question, text, 3);
      [p setAnswer:matches ?: @"Nothing on this page matches your question."
              note:[why stringByAppendingString:@" Without it, these are the sentences on the page that best match your question."]
      offerChatGPT:YES];
      finish(matches, NO);
    };
    if (!MaxModelAvailable()) {
      fallback(MaxModelStatusText(MaxModelAvailability()));
      return;
    }
    [p setBusy:@"Thinking on this Mac…"];
    MaxRespond(MaxAskInstructions(), MaxAskPrompt(question, page[@"title"], page[@"url"], text), ^(NSString* answer, NSString* error) {
      NSString* a = [answer stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (!a.length) {
        fallback([NSString stringWithFormat:@"The on-device model couldn't answer (%@).", error ?: @"no reply"]);
        return;
      }
      [p setAnswer:a note:@"Answered on this Mac by Apple's on-device model, from this page only." offerChatGPT:YES];
      finish(a, YES);
    });
  }];
}

- (IBAction)summarizePage:(id)sender {
  ArcItem* item = self.shownItem;
  if (!MaxFeatureOn(kSettingMaxAskOnPage) || !IsWebItem(item)) {
    NSBeep();
    return;
  }
  [self summarizeItem:item done:nil];
}

- (void)summarizeItem:(ArcItem*)item done:(void (^)(NSString*, BOOL))done {
  MaxPanel* p = [self maxPanel];
  [self maxState].panelItem = item;
  [p showTitle:[NSString stringWithFormat:@"Summary of %@", item.displayTitle ?: @"this page"] over:self.window];
  [p setBusy:@"Reading the page…"];
  [self maxPageTextOfItem:item done:^(NSDictionary* page) {
    if (!page) {
      [p setAnswer:nil note:@"NotArc couldn't read this page." offerChatGPT:YES];
      if (done) done(nil, NO);
      return;
    }
    NSString* text = page[@"text"] ?: @"";
    void (^fallback)(NSString*) = ^(NSString* why) {
      NSString* desc = [page[@"description"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
      NSString* pick = MaxExtractiveSummary(text, 3);
      NSString* s = desc.length ? [NSString stringWithFormat:@"%@\n\n%@", desc, pick] : pick;
      [p setAnswer:s note:[why stringByAppendingString:@" This summary picks the page's key sentences without AI."] offerChatGPT:YES];
      if (done) done(s, NO);
    };
    if (!MaxModelAvailable()) {
      fallback(MaxModelStatusText(MaxModelAvailability()));
      return;
    }
    [p setBusy:@"Summarizing on this Mac…"];
    MaxRespond(MaxSummaryInstructions(4), MaxSummaryPrompt(page[@"title"], page[@"url"], text, 0), ^(NSString* reply, NSString* error) {
      NSString* s = MaxCleanSummary(reply);
      if (!s.length) {
        fallback([NSString stringWithFormat:@"The on-device model couldn't summarise this page (%@).", error ?: @"no reply"]);
        return;
      }
      [p setAnswer:s note:@"Summarised on this Mac by Apple's on-device model." offerChatGPT:NO];
      if (done) done(s, YES);
    });
  }];
}

#pragma mark Copy Page as Markdown

- (IBAction)copyPageAsMarkdown:(id)sender {
  ArcItem* item = self.shownItem;
  if (!IsWebItem(item)) {
    NSBeep();
    return;
  }
  [self copyMarkdownOfItem:item done:nil];
}

- (void)copyMarkdownOfItem:(ArcItem*)item done:(void (^)(NSString*))done {
  __weak MainWindowController* weakSelf = self;
  [self maxPageMarkdownOfItem:item done:^(NSString* md) {
    MainWindowController* me = weakSelf;
    if (md.length) {
      NSPasteboard* pb = [me copyPasteboard];
      [pb clearContents];
      [pb setString:md forType:NSPasteboardTypeString];
      if (!me.selfTestProfiles) [me showToast:@"Copied page as Markdown" action:nil selector:nil];
    } else if (!me.selfTestProfiles) {
      NSBeep();
    }
    if (done) done(md);
  }];
}

#pragma mark ChatGPT in the command bar

- (NSDictionary*)maxChatGPTSuggestionFor:(NSString*)text {
  NSString* q = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (q.length < 2 || !MaxFeatureOn(kSettingMaxChatGPT)) return nil;
  NSString* resolved = ResolveCommandBarInput(q) ?: q;
  BOOL search = [resolved containsString:@"?q="] || [resolved containsString:@"search?"];
  if (!search) return nil;  // an address, not a question
  return @{ @"kind" : @"chatgpt", @"title" : q, @"subtitle" : @"Ask ChatGPT", @"key" : @"chatgpt", @"text" : q,
            @"url" : MaxChatGPTURL(q) };
}

- (NSString*)openChatGPTFor:(NSString*)question {
  NSString* url = MaxChatGPTURL(question);
  [self openInNewTab:url];
  return url;
}

#pragma mark Tidy Tabs

- (IBAction)tidyTodayTabs:(id)sender {
  if (!MaxFeatureOn(kSettingMaxTidyTabs)) {
    NSBeep();
    return;
  }
  __weak MainWindowController* weakSelf = self;
  [self tidyTabsInSpace:self.currentSpace done:^(NSArray<ArcItem*>* folders, BOOL usedModel) {
    MainWindowController* me = weakSelf;
    if (!me || me.selfTestProfiles) return;
    NSUInteger tabs = 0;
    for (ArcItem* f in folders) tabs += f.children.count;
    if (!folders.count)
      [me showToast:@"Nothing to tidy: no tabs share a topic" action:nil selector:nil];
    else
      [me showToast:[NSString stringWithFormat:@"Tidied %lu tabs into %lu folders%@", (unsigned long)tabs,
                                               (unsigned long)folders.count, usedModel ? @"" : @" by site"]
             action:@"Undo"
           selector:@selector(undoTidyTabs:)];
  }];
}

- (IBAction)undoTidyTabs:(id)sender {
  NSUndoManager* u = [self sidebarUndoManager];
  if ([u.undoActionName isEqualToString:@"Tidy Tabs"]) [u undo];
}

- (void)tidyTabsInSpace:(ArcSpace*)space done:(void (^)(NSArray<ArcItem*>*, BOOL))done {
  NSMutableArray<ArcItem*>* tabs = [NSMutableArray array];
  NSMutableArray<NSDictionary*>* infos = [NSMutableArray array];
  for (ArcItem* it in space.unpinned.children) {
    if (!IsWebItem(it) || tabs.count >= 40) continue;
    [tabs addObject:it];
    [infos addObject:@{ @"title" : it.displayTitle ?: @"", @"url" : [self itemCurrentURL:it] ?: it.url }];
  }
  if (tabs.count < 2) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(@[], NO); });
    return;
  }
  __weak MainWindowController* weakSelf = self;
  void (^apply)(NSArray<NSDictionary*>*, BOOL) = ^(NSArray<NSDictionary*>* groups, BOOL ai) {
    MainWindowController* me = weakSelf;
    NSArray* folders = me ? [me applyTidyGroups:groups tabs:tabs space:space] : @[];
    done(folders, ai && folders.count > 0);
  };
  if (!MaxModelAvailable()) {
    apply(MaxGroupTabsBySite(infos), NO);
    return;
  }
  MaxRespond(MaxTidyTabsInstructions(), MaxTidyTabsPrompt(infos), ^(NSString* reply, NSString* error) {
    NSArray* groups = MaxParseTidyGroups(reply, infos.count);
    if (groups.count) apply(groups, YES);
    else apply(MaxGroupTabsBySite(infos), NO);
  });
}

// Puts each group's tabs (still top-level in Today) into a new folder at the top of Today, in group order.
- (NSArray<ArcItem*>*)applyTidyGroups:(NSArray<NSDictionary*>*)groups tabs:(NSArray<ArcItem*>*)tabs space:(ArcSpace*)space {
  NSMutableArray<ArcItem*>* today = space.unpinned.children;
  NSMutableDictionary<NSString*, NSNumber*>* original = [NSMutableDictionary dictionary];  // itemID -> index before
  for (NSUInteger i = 0; i < today.count; ++i)
    if (today[i].itemID) original[today[i].itemID] = @(i);
  NSMutableArray<ArcItem*>* folders = [NSMutableArray array];
  for (NSDictionary* g in groups) {
    NSMutableArray<ArcItem*>* members = [NSMutableArray array];
    for (NSNumber* i in g[@"indexes"]) {
      if (i.unsignedIntegerValue >= tabs.count) continue;
      ArcItem* t = tabs[i.unsignedIntegerValue];
      if ([today indexOfObjectIdenticalTo:t] != NSNotFound && ![members containsObject:t]) [members addObject:t];
    }
    if (members.count < 2) continue;
    ArcItem* folder = [ArcItem new];
    folder.itemID = NSUUID.UUID.UUIDString;
    folder.title = g[@"name"];
    folder.isFolder = YES;
    folder.children = [NSMutableArray array];
    for (ArcItem* t in members) {
      [today removeObjectIdenticalTo:t];
      [folder.children addObject:t];
    }
    [today insertObject:folder atIndex:folders.count];
    [folders addObject:folder];
  }
  if (!folders.count) return folders;
  [self reloadSidebar];
  if (space == self.currentSpace)
    for (ArcItem* f in folders)
      if (![self folderExpanded:f]) [self toggleFolder:f];
  [self scheduleSave];
  __weak MainWindowController* weakSelf = self;
  NSUndoManager* undo = [self sidebarUndoManager];
  [undo registerUndoWithTarget:self handler:^(id target) {
    MainWindowController* me = weakSelf;
    // Dissolve the folders: their tabs go back to where they were (clamped), in the original order.
    NSMutableArray<ArcItem*>* back = [NSMutableArray array];
    for (ArcItem* f in folders) {
      [back addObjectsFromArray:f.children];
      [space.unpinned.children removeObjectIdenticalTo:f];
    }
    [back sortUsingComparator:^NSComparisonResult(ArcItem* a, ArcItem* b) {
      return [original[a.itemID ?: @""] ?: @0 compare:original[b.itemID ?: @""] ?: @0];
    }];
    for (ArcItem* t in back) {
      NSUInteger at = MIN([original[t.itemID ?: @""] unsignedIntegerValue], space.unpinned.children.count);
      [space.unpinned.children insertObject:t atIndex:at];
    }
    [me reloadSidebar];
    [me scheduleSave];
  }];
  [undo setActionName:@"Tidy Tabs"];
  return folders;
}

#pragma mark Tidy tab titles

- (IBAction)tidyTabTitle:(id)sender {
  ArcItem* item = self.shownItem;
  if (!IsWebItem(item)) {
    NSBeep();
    return;
  }
  [self tidyTitleOfItem:item announce:NO done:nil];
}

// The on-device model when it's on (#58), else the rule-based TidyTabTitle (#18), which is also the fallback when
// the model's reply is unusable. A reply that arrives after the title changed (renamed by hand meanwhile) is dropped.
- (void)tidyTitleOfItem:(ArcItem*)item announce:(BOOL)announce done:(void (^)(NSString*, BOOL))done {
  if (!item) {
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(nil, NO); });
    return;
  }
  NSString* title = item.displayTitle ?: @"";
  if (!MaxTidyTitlesUseModel()) {
    NSString* t = [self ruleTidyTitleOfItem:item];
    BOOL changed = [self applyTidyTitle:t toItem:item announce:announce];
    if (done) dispatch_async(dispatch_get_main_queue(), ^{ done(changed ? t : nil, NO); });
    return;
  }
  NSString* url = [self itemCurrentURL:item] ?: item.url;
  __weak MainWindowController* weakSelf = self;
  MaxRespond(MaxTidyTitleInstructions(), MaxTidyTitlePrompt(title, url), ^(NSString* reply, NSString* error) {
    MainWindowController* me = weakSelf;
    if (!me || ![item.displayTitle isEqualToString:title]) {
      if (done) done(nil, NO);
      return;
    }
    NSString* t = MaxCleanModelTitle(reply);
    BOOL ai = t.length > 0;
    if (!ai) t = [me ruleTidyTitleOfItem:item];
    BOOL changed = [me applyTidyTitle:t toItem:item announce:announce];
    if (done) done(changed ? t : nil, ai);
  });
}

#pragma mark 5-second previews

- (void)maxLinkHovered:(NSString*)url browser:(int)browserId {
  BOOL shift = (NSEvent.modifierFlags & NSEventModifierFlagShift) != 0;
  [self maxLinkHovered:url shiftDown:shift];
}

- (void)maxLinkHovered:(NSString*)url shiftDown:(BOOL)shift {
  MaxWindowState* s = [self maxState];
  s.hoverURL = MaxPreviewURLAllowed(url) ? url : nil;
  if (!s.hoverURL) {
    __weak MainWindowController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), dispatch_get_main_queue(), ^{
      MainWindowController* me = weakSelf;
      if (me && ![me maxState].hoverURL) [me hidePreviewCard];
    });
    return;
  }
  if (!MaxFeatureOn(kSettingMaxPreviews)) return;
  [self installShiftMonitor];
  if (shift) [self showPreviewFor:url];
  else if (s.card.isVisible && ![s.card.url isEqualToString:url]) [self hidePreviewCard];
}

// Pressing Shift while already pointing at a link opens its preview too.
- (void)installShiftMonitor {
  MaxWindowState* s = [self maxState];
  if (s.flagsMonitor || self.selfTestProfiles) return;
  __weak MainWindowController* weakSelf = self;
  s.flagsMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskFlagsChanged handler:^NSEvent*(NSEvent* e) {
    MainWindowController* me = weakSelf;
    MaxWindowState* st = [me maxState];
    if (me && e.window == me.window && (e.modifierFlags & NSEventModifierFlagShift) && st.hoverURL &&
        MaxFeatureOn(kSettingMaxPreviews))
      [me showPreviewFor:st.hoverURL];
    return e;
  }];
}

- (void)hidePreviewCard {
  MaxPreviewCard* c = [self maxState].card;
  if (!c) return;
  [c.parentWindow removeChildWindow:c];
  [c orderOut:nil];
  c.url = nil;
}

- (void)showPreviewFor:(NSString*)url {
  MaxWindowState* s = [self maxState];
  if (s.card.isVisible && [s.card.url isEqualToString:url]) return;
  if (!s.card) s.card = [MaxPreviewCard new];
  MaxPreviewCard* card = s.card;
  card.url = url;
  NSString* site = SiteLabel(url);
  NSArray* cached = [s.previewCache objectForKey:url];
  if (cached) [card setTitle:cached[0] site:site body:cached[1] note:cached[2]];
  else [card setTitle:site site:url body:@"Summarizing…" note:nil];
  // Below and to the right of the pointer, kept inside the window.
  NSPoint m = NSEvent.mouseLocation;
  NSRect wf = self.window.frame;
  if (!NSPointInRect(m, wf)) m = NSMakePoint(NSMidX(wf), NSMidY(wf));
  NSSize size = card.frame.size;
  CGFloat x = MIN(m.x + 12, NSMaxX(wf) - size.width - 8), y = MAX(m.y - 18 - size.height, NSMinY(wf) + 8);
  [card setFrameOrigin:NSMakePoint(MAX(x, NSMinX(wf) + 8), y)];
  if (card.parentWindow != self.window) {
    [card.parentWindow removeChildWindow:card];
    [self.window addChildWindow:card ordered:NSWindowAbove];
  }
  if (self.window.alphaValue < 0.05) card.alphaValue = 0.01;  // hidden self-test run
  [card orderFront:nil];
  if (cached) return;
  __weak MainWindowController* weakSelf = self;
  MaxFetchPage(url, ^(NSString* html, NSString* error) {
    MainWindowController* me = weakSelf;
    if (!me) return;
    void (^show)(NSString*, NSString*, NSString*) = ^(NSString* title, NSString* body, NSString* note) {
      NSArray* entry = @[ title ?: site, body ?: @"", note ?: @"" ];
      [[me maxState].previewCache setObject:entry forKey:url];
      if ([card.url isEqualToString:url]) [card setTitle:entry[0] site:site body:entry[1] note:entry[2]];
    };
    if (!html) {
      show(site, [NSString stringWithFormat:@"No preview: %@.", error ?: @"the page didn't load"], nil);
      return;
    }
    NSDictionary* page = MaxParseHTML(html);
    NSString* title = [page[@"title"] length] ? page[@"title"] : site;
    void (^fallback)(void) = ^{
      NSString* desc = page[@"description"];
      NSString* body = desc.length ? desc : MaxExtractiveSummary(page[@"text"], 2);
      show(title, body.length ? body : @"No summary available for this page.", @"Summary without AI");
    };
    if (!MaxModelAvailable() || [page[@"text"] length] + [page[@"description"] length] < 40) {
      fallback();
      return;
    }
    NSString* text = [page[@"description"] length] ? [NSString stringWithFormat:@"%@\n%@", page[@"description"], page[@"text"]]
                                                   : page[@"text"];
    MaxRespond(MaxSummaryInstructions(3), MaxSummaryPrompt(title, url, text, 3500), ^(NSString* reply, NSString* err) {
      NSString* sum = MaxCleanSummary(reply);
      if (sum.length) show(title, sum, @"Summarised on this Mac");
      else fallback();
    });
  });
}

#pragma mark Menus and tests

- (BOOL)maxValidateMenuItem:(NSMenuItem*)mi handled:(BOOL*)handled {
  SEL a = mi.action;
  BOOL web = IsWebItem(self.shownItem) && self.shownItem.browserId;
  *handled = YES;
  if (a == @selector(showAskOnPage:) || a == @selector(summarizePage:)) {
    mi.hidden = !MaxFeatureOn(kSettingMaxAskOnPage);
    return web && !mi.hidden;
  }
  if (a == @selector(tidyTabTitle:)) {  // works without the model too (TidyTabTitle, #18)
    mi.hidden = NO;
    ArcItem* item = self.shownItem;
    return IsWebItem(item) && (MaxTidyTitlesUseModel() || ![[self ruleTidyTitleOfItem:item] isEqualToString:item.displayTitle]);
  }
  if (a == @selector(tidyTodayTabs:)) {
    mi.hidden = !MaxFeatureOn(kSettingMaxTidyTabs);
    return !mi.hidden;
  }
  if (a == @selector(copyPageAsMarkdown:)) return web;  // works without AI
  if (a == @selector(undoTidyTabs:)) return [[self sidebarUndoManager].undoActionName isEqualToString:@"Tidy Tabs"];
  *handled = NO;
  return YES;
}

- (BOOL)maxPanelShown { return [self maxState].panel.isVisible; }
- (NSString*)maxPanelAnswer { return [self maxState].panel.answerText ?: @""; }
- (NSString*)maxPanelNote { return [self maxState].panel.noteText ?: @""; }
- (BOOL)maxPanelOffersChatGPT { return [self maxState].panel.chatGPTOffered; }
- (BOOL)maxPreviewShown { return [self maxState].card.isVisible; }
- (NSString*)maxPreviewText { return [self maxState].card.bodyText ?: @""; }

- (void)hideMaxPanels {
  MaxPanel* p = [self maxState].panel;
  [p.parentWindow removeChildWindow:p];
  [p orderOut:nil];
  [self hidePreviewCard];
}
@end
