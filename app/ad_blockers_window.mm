#import "app/ad_blockers_window.h"
#import "app/filter_lists.h"
#import "app/settings.h"
#include "app/content_blocker.h"

static NSString* const kListURLKey = @"listURL";

@implementation ManageAdBlockersWindowController {
  NSTextField* _status;
  NSButton* _builtIn;
  NSStackView* _lists;
  NSStackView* _sites;
  NSTextField* _addField;
  NSTextField* _addError;
}

+ (instancetype)shared {
  static ManageAdBlockersWindowController* c;
  if (!c) c = [ManageAdBlockersWindowController new];
  return c;
}

- (NSTextField*)heading:(NSString*)text {
  NSTextField* f = [NSTextField labelWithString:text];
  f.font = [NSFont boldSystemFontOfSize:13];
  return f;
}

- (NSTextField*)note:(NSString*)text {
  NSTextField* f = [NSTextField wrappingLabelWithString:text];
  f.font = [NSFont systemFontOfSize:11];
  f.textColor = NSColor.secondaryLabelColor;
  [f.widthAnchor constraintEqualToConstant:452].active = YES;
  return f;
}

- (NSScrollView*)scrollerFor:(NSStackView*)stack height:(CGFloat)h {
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 6;
  stack.edgeInsets = NSEdgeInsetsMake(6, 8, 6, 8);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  NSClipView* clip = [NSClipView new];
  clip.documentView = stack;
  NSScrollView* scroll = [NSScrollView new];
  scroll.contentView = clip;
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;
  scroll.drawsBackground = NO;
  [NSLayoutConstraint activateConstraints:@[
    [scroll.widthAnchor constraintEqualToConstant:452],
    [scroll.heightAnchor constraintEqualToConstant:h],
    [stack.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:clip.topAnchor],
  ]];
  return scroll;
}

- (instancetype)init {
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 500, 600)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                              backing:NSBackingStoreBuffered
                                                defer:YES];
  w.title = @"Manage Ad Blockers";
  w.releasedWhenClosed = NO;
  self = [super initWithWindow:w];
  if (!self) return nil;
  w.delegate = (id<NSWindowDelegate>)self;

  _status = [self note:@""];
  _builtIn = [NSButton checkboxWithTitle:@"" target:self action:@selector(builtInToggled:)];
  _lists = [NSStackView new];
  _sites = [NSStackView new];
  _addField = [NSTextField textFieldWithString:@""];
  _addField.placeholderString = @"Filter list address, e.g. https://example.com/filters.txt";
  _addField.target = self;
  _addField.action = @selector(addList:);
  [_addField.widthAnchor constraintEqualToConstant:350].active = YES;
  NSButton* add = [NSButton buttonWithTitle:@"Add List" target:self action:@selector(addList:)];
  _addError = [self note:@""];
  _addError.textColor = NSColor.systemRedColor;
  _addError.hidden = YES;
  NSButton* update = [NSButton buttonWithTitle:@"Update Now" target:self action:@selector(updateNow:)];
  NSButton* done = [NSButton buttonWithTitle:@"Done" target:self action:@selector(done:)];
  done.keyEquivalent = @"\r";

  NSStackView* stack = [NSStackView stackViewWithViews:@[
    _status,
    [self heading:@"Built-in Blocker"],
    _builtIn,
    [self heading:@"Filter Lists"],
    [self note:@"Lists from the web, in Adblock Plus format. NotArc downloads a list only when you turn it on, then "
               @"refreshes it once a day. Rules it doesn't understand are skipped."],
    [self scrollerFor:_lists height:170],
    [NSStackView stackViewWithViews:@[ _addField, add ]],
    _addError,
    update,
    [self heading:@"Sites Where Blocking Is Off"],
    [self note:@"Turn blocking off for a site in Site Settings (Cmd+Shift+I)."],
    [self scrollerFor:_sites height:110],
    done,
  ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  stack.edgeInsets = NSEdgeInsetsMake(18, 24, 18, 24);
  [stack setCustomSpacing:14 afterView:update];
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [w.contentView addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:w.contentView.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:w.contentView.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:w.contentView.topAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:w.contentView.bottomAnchor],
  ]];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(reload)
                                             name:FilterListsDidChangeNotification object:nil];
  [self reload];
  [w center];
  return self;
}

- (void)showWindow:(id)sender {
  [self reload];
  [super showWindow:sender];
}

- (void)windowDidBecomeKey:(NSNotification*)n { [self reload]; }

static NSString* RulesText(NSInteger n) {
  NSNumberFormatter* f = [NSNumberFormatter new];
  f.numberStyle = NSNumberFormatterDecimalStyle;
  return [NSString stringWithFormat:@"%@ %@", [f stringFromNumber:@(n)], n == 1 ? @"rule" : @"rules"];
}

- (NSString*)statusForList:(FilterList*)l {
  if (l.updating) return @"Updating...";
  if (l.suggested || (!l.updated && !l.error)) return @"Not downloaded";
  NSMutableArray* parts = [NSMutableArray array];
  if (l.updated) {
    NSRelativeDateTimeFormatter* rel = [NSRelativeDateTimeFormatter new];
    [parts addObject:RulesText(l.rules)];
    NSTimeInterval ago = -l.updated.timeIntervalSinceNow;
    [parts addObject:[@"Updated " stringByAppendingString:ago < 60 ? @"just now" : [rel localizedStringForDate:l.updated
                                                                                              relativeToDate:NSDate.date]]];
  }
  if (l.error) [parts addObject:[@"Last update failed: " stringByAppendingString:l.error]];
  return [parts componentsJoinedByString:@" · "];
}

- (void)reload {
  BOOL on = SettingBool(kSettingBlockAds);
  _status.stringValue = on ? @"Ads and trackers are blocked on every site except the ones listed at the bottom."
                           : @"Blocking is off. Turn on Block ads & trackers in Settings to use these lists.";
  _builtIn.title = [NSString stringWithFormat:@"NotArc's built-in list (%lu ad and tracking hosts)",
                                              (unsigned long)content_blocker::ListSize()];
  _builtIn.state = SettingBool(kSettingAdBlockBuiltIn) ? NSControlStateValueOn : NSControlStateValueOff;

  for (NSView* v in _lists.arrangedSubviews.copy) [v removeFromSuperview];
  for (FilterList* l in [FilterListManager.shared lists]) {
    NSButton* check = [NSButton checkboxWithTitle:l.title target:self action:@selector(listToggled:)];
    check.state = l.enabled ? NSControlStateValueOn : NSControlStateValueOff;
    check.identifier = l.url;
    check.toolTip = l.url;
    NSTextField* status = [NSTextField labelWithString:[self statusForList:l]];
    status.font = [NSFont systemFontOfSize:11];
    status.textColor = l.error ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    status.lineBreakMode = NSLineBreakByTruncatingTail;
    [status.widthAnchor constraintLessThanOrEqualToConstant:300].active = YES;
    NSStackView* text = [NSStackView stackViewWithViews:@[ check, status ]];
    text.orientation = NSUserInterfaceLayoutOrientationVertical;
    text.alignment = NSLayoutAttributeLeading;
    text.spacing = 1;
    NSMutableArray* row = [NSMutableArray arrayWithObject:text];
    if (!l.suggested) {
      NSButton* remove = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removeList:)];
      remove.identifier = l.url;
      remove.controlSize = NSControlSizeSmall;
      [row addObject:remove];
    }
    NSStackView* r = [NSStackView stackViewWithViews:row];
    r.identifier = [@"list=" stringByAppendingString:l.title];
    [r.widthAnchor constraintEqualToConstant:420].active = YES;
    [_lists addArrangedSubview:r];
  }

  for (NSView* v in _sites.arrangedSubviews.copy) [v removeFromSuperview];
  NSArray* sites = SettingObject(kSettingAdBlockExceptions);
  for (id host in sites) {
    if (![host isKindOfClass:NSString.class]) continue;
    NSTextField* label = [NSTextField labelWithString:host];
    NSButton* remove = [NSButton buttonWithTitle:@"Remove" target:self action:@selector(removeSite:)];
    remove.identifier = host;
    remove.controlSize = NSControlSizeSmall;
    NSStackView* r = [NSStackView stackViewWithViews:@[ label, remove ]];
    r.identifier = [@"site=" stringByAppendingString:host];
    [r setHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [r.widthAnchor constraintEqualToConstant:420].active = YES;
    [_sites addArrangedSubview:r];
  }
  if (!sites.count) {
    NSTextField* none = [NSTextField labelWithString:@"None"];
    none.textColor = NSColor.secondaryLabelColor;
    [_sites addArrangedSubview:none];
  }
}

// MARK: actions

- (void)builtInToggled:(NSButton*)sender {
  SettingSetBool(kSettingAdBlockBuiltIn, sender.state == NSControlStateValueOn);
  ApplyContentBlockerSettings();
}

- (void)listToggled:(NSButton*)sender {
  [FilterListManager.shared setList:sender.identifier enabled:sender.state == NSControlStateValueOn];
}

- (void)removeList:(NSButton*)sender { [FilterListManager.shared removeList:sender.identifier]; }

- (void)addList:(id)sender {
  NSString* url = _addField.stringValue;
  if (!url.length) return;
  BOOL ok = [FilterListManager.shared addListURL:url];
  _addError.stringValue = ok ? @"" : @"Enter the web address of a filter list (https://...) that isn't already on.";
  _addError.hidden = ok;
  if (ok) _addField.stringValue = @"";
}

- (void)updateNow:(id)sender { [FilterListManager.shared updateAll]; }

- (void)removeSite:(NSButton*)sender { [self removeSiteException:sender.identifier]; }

- (void)done:(id)sender { [self.window performClose:sender]; }

// MARK: tests

- (NSArray<NSString*>*)rowSummaries {
  NSMutableArray* out = [NSMutableArray arrayWithObject:[NSString stringWithFormat:@"builtin=%d", _builtIn.state == NSControlStateValueOn]];
  NSArray* lists = [FilterListManager.shared lists];
  for (NSView* v in _lists.arrangedSubviews) {
    if (![v.identifier hasPrefix:@"list="]) continue;
    for (FilterList* l in lists)
      if ([v.identifier isEqualToString:[@"list=" stringByAppendingString:l.title]])
        [out addObject:[NSString stringWithFormat:@"list=%@|on=%d|rules=%ld|updated=%d|suggested=%d", l.title, l.enabled,
                                                  (long)l.rules, l.updated != nil, l.suggested]];
  }
  for (NSView* v in _sites.arrangedSubviews)
    if ([v.identifier hasPrefix:@"site="]) [out addObject:v.identifier];
  return out;
}

- (BOOL)addListFromField:(NSString*)url {
  _addField.stringValue = url;
  [self addList:nil];
  return _addError.hidden;
}

- (void)toggleBuiltIn {
  _builtIn.state = _builtIn.state == NSControlStateValueOn ? NSControlStateValueOff : NSControlStateValueOn;
  [self builtInToggled:_builtIn];
}

- (void)removeSiteException:(NSString*)host {
  NSMutableArray* list = [SettingObject(kSettingAdBlockExceptions) mutableCopy];
  [list removeObject:host];
  SettingSetObject(kSettingAdBlockExceptions, list ?: @[]);
  ApplyContentBlockerSettings();
  [self reload];
}

@end
