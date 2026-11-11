#import "app/autofill.h"
#import "app/arc_alert.h"

#import <LocalAuthentication/LocalAuthentication.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "app/arc_cookies.h"
#import "app/bookmark_import.h"
#import "app/main_window.h"
#import "app/password_store.h"
#import "app/settings.h"

NSString* const kSettingPasswordSavingOff = @"passwordSavingOff";

#pragma mark Page script

// Runs in each http(s) document. Reports (never fills by itself):
//  - {t:'save', u, p}: a login form was submitted (submit, a click on a button, or Enter). For sign-up / change
//    forms the new password is reported (autocomplete=new-password, else the 2nd of 2-3 password fields).
//  - {t:'focus', g, x, y, w, h, d, top}: the user clicked (or tabbed) into an empty login, address or card field;
//    g is the group, the rect is in CSS pixels of this frame, d = devicePixelRatio.
//  - {t:'filled', g, n}: a fill NotArc asked for set n fields.
// window.__notarcAF.fill(data) fills the field group the user picked from; __notarcAF.request() reports the
// page's login field (Fill Password). Values are set through the native setter and followed by input + change
// events so frameworks (React, Vue) see them.
static const char kShim[] = R"JS((function(N){
'use strict';
if(window.__notarcAF)return;
var log=console.log.bind(console),P='__notarc_af__:'+N+':',J=JSON.stringify;
var ID=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value');
var SD=Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype,'value');
var last=null,sent='',tabAt=0,shownAt=0,shownEl=null;
function send(o){try{log(P+J(o));}catch(e){}}
function gv(e){return e.tagName==='SELECT'?SD.get.call(e):ID.get.call(e);}
function visible(e){var r=e.getBoundingClientRect();if(r.width<2||r.height<2)return false;var s=getComputedStyle(e);return s.visibility!=='hidden'&&s.display!=='none';}
function typ(e){return (e.type||'').toLowerCase();}
function fields(root){var a=(root||document).querySelectorAll('input,select'),out=[];for(var i=0;i<a.length;i++){var e=a[i];if(e.disabled||e.readOnly)continue;if(/^(hidden|submit|button|reset|image|checkbox|radio|file|range|color)$/.test(typ(e)))continue;out.push(e);}return out;}
function ac(e){var a=(e.getAttribute('autocomplete')||'').toLowerCase().trim().split(/\s+/);return a[a.length-1]||'';}
var AC={'username':'username','email':'email','current-password':'password','new-password':'password','name':'name','given-name':'given','additional-name':'middle','family-name':'family','organization':'org','street-address':'street','address-line1':'line1','address-line2':'line2','address-level2':'city','address-level1':'state','postal-code':'zip','country':'country','country-name':'country','tel':'tel','tel-national':'tel','cc-name':'ccname','cc-number':'ccnumber','cc-exp':'ccexp','cc-exp-month':'ccmonth','cc-exp-year':'ccyear','cc-csc':'csc'};
var RX=[[/card.?num|cc.?num|credit.?card|card.?no\b/,'ccnumber'],[/name.?on.?card|card.?holder|cc.?name|holder.?name/,'ccname'],[/cvc|cvv|csc|security.?code/,'csc'],[/exp\w*.?(month|mm)\b|cc.?month|card.?month/,'ccmonth'],[/exp\w*.?(year|yy)|cc.?year|card.?year/,'ccyear'],[/expir|exp.?date|cc.?exp|mm.?yy/,'ccexp'],[/e.?mail/,'email'],[/user.?name|login|user.?id|account.?name/,'username'],[/first.?name|given.?name|fname|forename/,'given'],[/last.?name|surname|family.?name|lname/,'family'],[/middle.?name/,'middle'],[/company|organi[sz]ation/,'org'],[/address.?(line)?.?2|apartment|\bapt\b|suite/,'line2'],[/address.?(line)?.?1|street|address/,'line1'],[/city|town|locality|suburb/,'city'],[/state|province|region|county/,'state'],[/zip|postal|post.?code/,'zip'],[/country/,'country'],[/phone|mobile|\btel\b|telephone/,'tel'],[/full.?name|^name$|your.?name|\bname\b/,'name']];
function kind(e){var t=typ(e);if(t==='password')return 'password';var a=AC[ac(e)];if(a)return a;if(t==='email')return 'email';if(t==='tel')return 'tel';var s=[e.name,e.id,e.getAttribute('placeholder'),e.getAttribute('aria-label')].join(' ').toLowerCase();for(var i=0;i<RX.length;i++)if(RX[i][0].test(s))return RX[i][1];return '';}
var ADDR={name:1,given:1,middle:1,family:1,org:1,street:1,line1:1,line2:1,city:1,state:1,zip:1,country:1,tel:1,email:1};
var CARD={ccname:1,ccnumber:1,ccexp:1,ccmonth:1,ccyear:1};
function rootOf(e){return e.form||(e.closest&&e.closest('form'))||document;}
function pws(root){return fields(root).filter(function(x){return typ(x)==='password'&&visible(x);});}
function textLike(x){return x.tagName==='INPUT'&&/^(text|email|tel|url|search|)$/.test(typ(x));}
function userField(root,pw){var fs=fields(root),cand=null;for(var i=0;i<fs.length;i++){var x=fs[i];if(x===pw)break;if(!textLike(x)||!visible(x))continue;var k=kind(x);if(k==='username')return x;if(k==='email'||k===''||k==='tel'||k==='name')cand=x;}return pw?cand:null;}
function addrCount(root,not){var n=0,fs=fields(root);for(var i=0;i<fs.length;i++){var k=kind(fs[i]);if(fs[i]!==not&&ADDR[k]&&k!=='email')n++;}return n;}
function group(e){var k=kind(e),root=rootOf(e),p=pws(root);if(k==='password')return 'login';if(CARD[k])return 'card';if(p.length&&textLike(e)&&userField(root,p[0])===e)return 'login';if(k==='username')return 'login';if(ADDR[k]){if(k==='email'&&!addrCount(root,e))return 'login';return 'address';}return '';}
function scan(root){var all=pws(root),filled=all.filter(function(x){return gv(x);});if(!filled.length)return;var nw=filled.filter(function(x){return ac(x)==='new-password';});var p=nw.length?gv(nw[0]):gv(filled[filled.length>=2?1:0]);var u=userField(root,all[0]),uv=u?gv(u):'';var key=uv+'\n'+p;if(key===sent)return;sent=key;send({t:'save',u:uv,p:p});}
function report(e,why){var g=group(e);if(!g)return;if(why!=='request'&&gv(e))return;var now=Date.now();if(why!=='request'&&shownEl===e&&now-shownAt<1500)return;shownEl=e;shownAt=now;last=e;var r=e.getBoundingClientRect();send({t:'focus',g:g,k:kind(e),why:why,x:r.left,y:r.top,w:r.width,h:r.height,d:window.devicePixelRatio||1,top:window===window.top?1:0});}
function setv(e,vals){if(!(vals instanceof Array))vals=[vals];for(var j=0;j<vals.length;j++){var v=vals[j];if(v==null||v==='')continue;v=String(v);if(e.tagName==='SELECT'){var o=e.options,lv=v.toLowerCase(),hit=-1,i;for(i=0;i<o.length&&hit<0;i++){var ov=o[i].value.toLowerCase(),ot=o[i].text.trim().toLowerCase();if(ov===lv||ot===lv||(+ov===+lv&&ov!==''&&!isNaN(+lv)))hit=i;}for(i=0;i<o.length&&hit<0&&lv.length>2;i++)if(o[i].text.toLowerCase().indexOf(lv)===0)hit=i;if(hit<0)continue;SD.set.call(e,o[hit].value);}else{ID.set.call(e,v);}e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true;}return false;}
function cardVal(k,x,f){var m=('0'+f.month).slice(-2),y=String(f.year),yy=y.slice(-2),lng=/yyyy/i.test(x.getAttribute('placeholder')||'')||(x.maxLength>=7&&x.maxLength<10);if(k==='ccnumber')return f.number;if(k==='ccname')return f.name;if(k==='ccmonth')return [m,String(+f.month)];if(k==='ccyear')return x.maxLength===2?[yy]:[y,yy];if(k==='ccexp')return lng?m+'/'+y:m+'/'+yy;return null;}
function fill(o){var e=last&&last.isConnected?last:document.activeElement;var root=e&&e!==document.body?rootOf(e):document,n=0;
if(o.g==='login'){var p=pws(root);if(!p.length&&root!==document)p=pws(document);var cur=p.filter(function(x){return ac(x)!=='new-password';});if(cur.length&&setv(cur[0],o.p))n++;var u=p.length?userField(rootOf(p[0]),p[0]):null;if(!u&&e&&e.tagName==='INPUT'&&typ(e)!=='password'&&group(e)==='login')u=e;if(u&&o.u&&setv(u,o.u))n++;}
else{var fs=fields(root);for(var i=0;i<fs.length;i++){var x=fs[i];if(!visible(x))continue;var k=kind(x),v=null;if(o.g==='card'){if(!CARD[k])continue;v=cardVal(k,x,o.f);}else{if(!ADDR[k])continue;v=o.f[k];if(k==='line1'&&!v)v=o.f.street;if(k==='street'&&!v)v=o.f.line1;}if(v!=null&&setv(x,v))n++;}}
send({t:'filled',g:o.g,n:n});}
function request(){var p=pws(document),e=p[0];if(!e){var fs=fields(document);for(var i=0;i<fs.length&&!e;i++)if(visible(fs[i])&&group(fs[i])==='login')e=fs[i];}if(e)report(e,'request');}
addEventListener('submit',function(ev){var f=ev.target;if(f&&f.tagName==='FORM')scan(f);},true);
addEventListener('click',function(ev){var t=ev.target,b=t&&t.closest&&t.closest('button,input[type=submit],input[type=button],input[type=image],[role=button]');if(b)scan(b.form||b.closest('form')||document);},true);
addEventListener('keydown',function(ev){if(ev.key==='Tab'){tabAt=Date.now();return;}var e=ev.target;if(ev.key==='Enter'&&e&&e.tagName==='INPUT')scan(rootOf(e));},true);
addEventListener('pointerdown',function(ev){var e=ev.target;if(e&&e.tagName==='INPUT')report(e,'click');},true);
addEventListener('focusin',function(ev){var e=ev.target;if(e&&e.tagName==='INPUT'&&Date.now()-tabAt<500)report(e,'tab');},true);
Object.defineProperty(window,'__notarcAF',{value:Object.freeze({fill:fill,request:request}),writable:false,configurable:false,enumerable:false});
})('__NONCE__');)JS";

std::string AutofillShimScript(const std::string& nonce) {
  std::string s(kShim);
  size_t at = s.rfind("__NONCE__");
  if (at != std::string::npos) s.replace(at, 9, nonce);
  return s;
}

#pragma mark Device authentication

static NSInteger gAuthRequests = 0;
NSInteger AutofillAuthRequestsForTest(void) { return gAuthRequests; }

void AutofillAuthenticate(NSString* reason, void (^done)(BOOL ok)) {
  ++gAuthRequests;
  if (PasswordStoreIsSelfTest()) {  // hidden test runs: never show Touch ID / password sheets
    done(YES);
    return;
  }
  LAContext* ctx = [LAContext new];
  NSError* error = nil;
  if (![ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthentication error:&error]) {
    done(NO);
    return;
  }
  [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthentication localizedReason:reason reply:^(BOOL ok, NSError*) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(ok); });
  }];
}

static void CopySecret(NSPasteboard* pb, NSString* secret) {
  // Marked concealed so clipboard managers that honour it don't keep a history of it.
  [pb clearContents];
  [pb declareTypes:@[ NSPasteboardTypeString, @"org.nspasteboard.ConcealedType" ] owner:nil];
  [pb setString:secret forType:NSPasteboardTypeString];
  [pb setString:secret forType:@"org.nspasteboard.ConcealedType"];
}

static NSString* JSLiteral(id obj) {
  NSData* d = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
  return d ? [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] : @"null";
}

static NSString* DisplayHost(NSString* origin) {
  if ([origin isEqualToString:@"file://"]) return @"this file";
  NSString* h = [NSURL URLWithString:origin].host ?: origin;
  return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

#pragma mark Passwords window

@interface PasswordsWindowController () <NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate,
                                         NSWindowDelegate>
@end

@implementation PasswordsWindowController {
  NSSegmentedControl* _sections;
  NSSearchField* _search;
  NSTableView* _table;
  NSButton* _show, *_copy, *_delete, *_add, *_offer;
  NSArray* _rows;
  NSMutableDictionary<NSValue*, NSString*>* _revealed;  // object pointer -> shown secret
  NSDate* _authorizedUntil;
}

+ (instancetype)shared {
  static PasswordsWindowController* c = nil;
  if (!c) c = [PasswordsWindowController new];
  return c;
}

- (instancetype)init {
  NSWindow* w = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 720, 500)
                                            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                      NSWindowStyleMaskResizable
                                              backing:NSBackingStoreBuffered defer:NO];
  w.title = @"Passwords";
  w.releasedWhenClosed = NO;
  w.minSize = NSMakeSize(560, 360);
  [w center];
  if (!(self = [super initWithWindow:w])) return nil;
  _revealed = [NSMutableDictionary dictionary];
  NSView* root = w.contentView;
  _sections = [NSSegmentedControl segmentedControlWithLabels:@[ @"Passwords", @"Addresses", @"Cards" ]
                                                trackingMode:NSSegmentSwitchTrackingSelectOne target:self
                                                      action:@selector(sectionChanged:)];
  _sections.selectedSegment = 0;
  _sections.frame = NSMakeRect(12, 464, 300, 24);
  _sections.autoresizingMask = NSViewMinYMargin;
  [root addSubview:_sections];
  _search = [[NSSearchField alloc] initWithFrame:NSMakeRect(470, 464, 238, 24)];
  _search.autoresizingMask = NSViewMinXMargin | NSViewMinYMargin;
  _search.placeholderString = @"Search";
  _search.delegate = self;
  [root addSubview:_search];

  NSScrollView* scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(12, 92, 696, 362)];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  scroll.borderType = NSBezelBorder;
  _table = [[NSTableView alloc] initWithFrame:scroll.bounds];
  for (NSArray* c in @[ @[ @"a", @250 ], @[ @"b", @230 ], @[ @"c", @190 ] ]) {
    NSTableColumn* col = [[NSTableColumn alloc] initWithIdentifier:c[0]];
    col.width = [c[1] doubleValue];
    [_table addTableColumn:col];
  }
  _table.dataSource = self;
  _table.delegate = self;
  _table.usesAlternatingRowBackgroundColors = YES;
  scroll.documentView = _table;
  [root addSubview:scroll];

  _show = [NSButton buttonWithTitle:@"Show Password" target:self action:@selector(showClicked:)];
  _copy = [NSButton buttonWithTitle:@"Copy Password" target:self action:@selector(copyClicked:)];
  _delete = [NSButton buttonWithTitle:@"Delete" target:self action:@selector(deleteClicked:)];
  _add = [NSButton buttonWithTitle:@"Add..." target:self action:@selector(addClicked:)];
  CGFloat x = 12;
  for (NSButton* b in @[ _add, _show, _copy, _delete ]) {
    [b sizeToFit];
    b.frame = NSMakeRect(x, 56, b.frame.size.width + 8, 28);
    b.autoresizingMask = NSViewMaxYMargin;
    x += b.frame.size.width + 8;
    [root addSubview:b];
  }
  _offer = [NSButton checkboxWithTitle:@"Offer to save passwords" target:self action:@selector(offerToggled:)];
  [_offer sizeToFit];
  _offer.frame = NSMakeRect(720 - 12 - _offer.frame.size.width, 60, _offer.frame.size.width, 20);
  _offer.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
  [root addSubview:_offer];
  NSTextField* note = [NSTextField wrappingLabelWithString:
      @"Import from Arc, Chrome, Brave, Edge, Vivaldi or a passwords CSV file with File > Import Passwords. Safari's "
      @"passwords are kept in Apple's Passwords app, which other apps can't read: export them there (File > Export "
      @"All Passwords) and import the CSV file, then delete it."];
  note.font = [NSFont systemFontOfSize:11];
  note.textColor = NSColor.secondaryLabelColor;
  note.frame = NSMakeRect(12, 8, 696, 42);
  note.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
  [root addSubview:note];
  [self reload];
  return self;
}

- (PasswordStore*)store { return [PasswordStore shared]; }

- (NSInteger)section { return _sections.selectedSegment; }
- (void)setSection:(NSInteger)section {
  _sections.selectedSegment = section;
  [self sectionChanged:nil];
}

- (void)sectionChanged:(id)sender {
  [_revealed removeAllObjects];
  [self reload];
}

- (void)offerToggled:(id)sender { SettingSetBool(kSettingPasswordSavingOff, _offer.state != NSControlStateValueOn); }

- (void)setSearchText:(NSString*)text {
  _search.stringValue = text ?: @"";
  [self reload];
}
- (void)controlTextDidChange:(NSNotification*)note { [self reload]; }

- (NSArray<NSString*>*)columnsForRow:(id)row {
  if ([row isKindOfClass:SavedLogin.class]) {
    SavedLogin* l = row;
    NSString* shown = _revealed[[NSValue valueWithNonretainedObject:l]];
    return @[ DisplayHost(l.origin), l.username.length ? l.username : @"(no username)", shown ?: @"••••••••" ];
  }
  if ([row isKindOfClass:AutofillAddress.class]) {
    AutofillAddress* a = row;
    NSDictionary* f = a.fields;
    NSString* place = [@[ f[@"line1"] ?: @"", f[@"city"] ?: @"", f[@"zip"] ?: @"" ] componentsJoinedByString:@" "];
    return @[ a.fullName.length ? a.fullName : @"-", [place stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet],
              f[@"email"] ?: f[@"tel"] ?: @"" ];
  }
  AutofillCard* c = row;
  NSString* shown = _revealed[[NSValue valueWithNonretainedObject:c]];
  return @[ shown ?: [NSString stringWithFormat:@"•••• %@", c.last4 ?: @"????"], c.name ?: @"",
            c.expMonth ? [NSString stringWithFormat:@"%02d/%d", c.expMonth, c.expYear] : @"" ];
}

- (void)reload {
  PasswordStore* store = [self store];
  NSInteger s = _sections.selectedSegment;
  NSArray* all = s == 0 ? (NSArray*)store.logins : s == 1 ? (NSArray*)store.addresses : (NSArray*)store.cards;
  NSArray* titles = s == 0 ? @[ @"Website", @"Username", @"Password" ]
                  : s == 1 ? @[ @"Name", @"Address", @"Email or Phone" ] : @[ @"Card", @"Name on Card", @"Expires" ];
  for (NSUInteger i = 0; i < 3; ++i) _table.tableColumns[i].title = titles[i];
  NSString* q = [_search.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
  NSMutableArray* rows = [NSMutableArray array];
  for (id r in all) {
    if (q.length) {
      NSString* hay = [[[self columnsForRow:r] subarrayWithRange:NSMakeRange(0, 2)] componentsJoinedByString:@" "];
      if ([r isKindOfClass:SavedLogin.class]) hay = [hay stringByAppendingFormat:@" %@", ((SavedLogin*)r).origin];
      if ([hay.lowercaseString rangeOfString:q].location == NSNotFound) continue;
    }
    [rows addObject:r];
  }
  if (s == 0)
    [rows sortUsingComparator:^NSComparisonResult(SavedLogin* a, SavedLogin* b) {
      NSComparisonResult r = [DisplayHost(a.origin) compare:DisplayHost(b.origin)];
      return r != NSOrderedSame ? r : [a.username compare:b.username];
    }];
  _rows = rows;
  [_table reloadData];
  _show.title = s == 2 ? @"Show Number" : @"Show Password";
  _copy.title = s == 2 ? @"Copy Number" : @"Copy Password";
  _show.hidden = _copy.hidden = s == 1;
  _offer.state = SettingBool(kSettingPasswordSavingOff) ? NSControlStateValueOff : NSControlStateValueOn;
  self.window.title = store.usable ? @"Passwords" : @"Passwords (locked: NotArc couldn't read its Keychain key)";
}

- (NSInteger)numberOfRowsInTableView:(NSTableView*)tv { return (NSInteger)_rows.count; }

- (NSView*)tableView:(NSTableView*)tv viewForTableColumn:(NSTableColumn*)col row:(NSInteger)row {
  NSTextField* cell = [tv makeViewWithIdentifier:@"cell" owner:self];
  if (!cell) {
    cell = [NSTextField labelWithString:@""];
    cell.identifier = @"cell";
    cell.lineBreakMode = NSLineBreakByTruncatingTail;
  }
  NSUInteger i = [tv.tableColumns indexOfObject:col];
  cell.stringValue = [self columnsForRow:_rows[row]][i];
  cell.selectable = i == 2 && _revealed[[NSValue valueWithNonretainedObject:_rows[row]]] != nil;
  return cell;
}

- (NSInteger)rowCount { return (NSInteger)_rows.count; }
- (NSString*)titleAtRow:(NSInteger)row {
  return row >= 0 && row < (NSInteger)_rows.count ? [[self columnsForRow:_rows[row]] componentsJoinedByString:@" | "] : nil;
}

- (NSString*)secretFor:(id)row {
  if ([row isKindOfClass:SavedLogin.class]) return [[self store] passwordFor:row];
  if ([row isKindOfClass:AutofillCard.class]) return [[self store] cardNumberFor:row];
  return nil;
}

- (NSString*)shownSecretAtRow:(NSInteger)row {
  return row >= 0 && row < (NSInteger)_rows.count ? _revealed[[NSValue valueWithNonretainedObject:_rows[row]]] : nil;
}

// Asks once, then trusts this window for 5 minutes (closing it forgets).
- (void)authorize:(void (^)(void))then {
  if (_authorizedUntil && _authorizedUntil.timeIntervalSinceNow > 0) {
    then();
    return;
  }
  __weak PasswordsWindowController* weakSelf = self;
  AutofillAuthenticate(@"show your saved passwords", ^(BOOL ok) {
    PasswordsWindowController* me = weakSelf;
    if (!me || !ok) return;
    me->_authorizedUntil = [NSDate dateWithTimeIntervalSinceNow:300];
    then();
  });
}

- (void)showSecretAtRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_rows.count) return;
  id r = _rows[row];
  [self authorize:^{
    NSString* secret = [self secretFor:r];
    if (secret) self->_revealed[[NSValue valueWithNonretainedObject:r]] = secret;
    [self->_table reloadData];
  }];
}

- (void)copySecretAtRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_rows.count) return;
  id r = _rows[row];
  [self authorize:^{
    NSString* secret = [self secretFor:r];
    if (!secret) return;
    NSPasteboard* pb = self.pasteboardProvider ? self.pasteboardProvider() : NSPasteboard.generalPasteboard;
    CopySecret(pb, secret);
  }];
}

- (void)deleteRow:(NSInteger)row {
  if (row < 0 || row >= (NSInteger)_rows.count) return;
  id r = _rows[row];
  [_revealed removeObjectForKey:[NSValue valueWithNonretainedObject:r]];
  if ([r isKindOfClass:SavedLogin.class]) [[self store] removeLogin:r];
  else if ([r isKindOfClass:AutofillAddress.class]) [[self store] removeAddress:r];
  else [[self store] removeCard:r];
  [self reload];
}

- (void)showClicked:(id)sender { [self showSecretAtRow:_table.selectedRow]; }
- (void)copyClicked:(id)sender { [self copySecretAtRow:_table.selectedRow]; }
- (void)deleteClicked:(id)sender {
  NSInteger row = _table.selectedRow;
  if (row < 0) return;
  ArcAlert* a = [ArcAlert new];
  a.messageText = @"Delete this item?";
  a.informativeText = [self titleAtRow:row] ?: @"";
  [a addButtonWithTitle:@"Delete"];
  [a addButtonWithTitle:@"Cancel"];
  __weak PasswordsWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r == NSAlertFirstButtonReturn) [weakSelf deleteRow:row];
  }];
}

// The form for Add... in each section: [label, key, secure].
- (NSArray<NSArray*>*)addFormFields {
  switch (_sections.selectedSegment) {
    case 0:
      return @[ @[ @"Website", @"website", @NO ], @[ @"Username", @"username", @NO ], @[ @"Password", @"password", @YES ] ];
    case 1:
      return @[ @[ @"Name", @"name", @NO ], @[ @"Company", @"org", @NO ], @[ @"Street", @"line1", @NO ],
                @[ @"Apt, suite", @"line2", @NO ], @[ @"City", @"city", @NO ], @[ @"State", @"state", @NO ],
                @[ @"ZIP", @"zip", @NO ], @[ @"Country", @"country", @NO ], @[ @"Phone", @"tel", @NO ],
                @[ @"Email", @"email", @NO ] ];
    default:
      return @[ @[ @"Card number", @"number", @YES ], @[ @"Name on card", @"name", @NO ], @[ @"Month (MM)", @"month", @NO ],
                @[ @"Year (YYYY)", @"year", @NO ] ];
  }
}

- (BOOL)addEntry:(NSDictionary<NSString*, NSString*>*)v {
  PasswordStore* store = [self store];
  BOOL ok = NO;
  switch (_sections.selectedSegment) {
    case 0: {
      NSString* site = [v[@"website"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (site.length && [site rangeOfString:@"://"].location == NSNotFound) site = [@"https://" stringByAppendingString:site];
      NSString* origin = AutofillOriginOfURL(site);
      ok = origin && ![origin isEqualToString:@"file://"] && v[@"password"].length &&
           [store saveOrigin:origin username:v[@"username"] ?: @"" password:v[@"password"] source:@"NotArc"] != PasswordUnchanged;
      break;
    }
    case 1:
      ok = [store addAddressFields:v];
      break;
    default:
      ok = [store addCardNumber:v[@"number"] name:v[@"name"] month:v[@"month"].intValue year:v[@"year"].intValue];
  }
  [self reload];
  return ok;
}

- (void)addClicked:(id)sender {
  NSArray<NSArray*>* spec = [self addFormFields];
  NSMutableArray<NSTextField*>* inputs = [NSMutableArray array];
  NSMutableArray* rows = [NSMutableArray array];
  for (NSArray* f in spec) {
    NSTextField* in = [f[2] boolValue] ? [NSSecureTextField new] : [NSTextField new];
    in.frame = NSMakeRect(0, 0, 220, 22);
    [inputs addObject:in];
    [rows addObject:@[ [NSTextField labelWithString:f[0]], in ]];
  }
  NSGridView* grid = [NSGridView gridViewWithViews:rows];
  grid.rowSpacing = 6;
  [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
  grid.frame = NSMakeRect(0, 0, 320, spec.count * 28);
  ArcAlert* a = [ArcAlert new];
  NSInteger s = _sections.selectedSegment;
  a.messageText = s == 0 ? @"Add a password" : s == 1 ? @"Add an address" : @"Add a card";
  a.informativeText = s == 2 ? @"NotArc never stores the security code." : @"";
  a.accessoryView = grid;
  [a addButtonWithTitle:@"Add"];
  [a addButtonWithTitle:@"Cancel"];
  a.window.initialFirstResponder = inputs.firstObject;
  __weak PasswordsWindowController* weakSelf = self;
  [a beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    NSMutableDictionary* v = [NSMutableDictionary dictionary];
    for (NSUInteger i = 0; i < spec.count; ++i) v[spec[i][1]] = inputs[i].stringValue ?: @"";
    if (![weakSelf addEntry:v]) NSBeep();
  }];
}

- (void)windowWillClose:(NSNotification*)note {
  [_revealed removeAllObjects];
  _authorizedUntil = nil;
}

- (void)showWindow:(id)sender {
  self.window.delegate = self;
  [self reload];
  [super showWindow:sender];
}

@end

#pragma mark Controller

@implementation AutofillController {
  __weak MainWindowController* _host;
  NSString* _pendingOrigin, *_pendingUser;
  NSData* _pendingSealed;
  NSString* _pendingPrompt;
  NSArray<NSDictionary*>* _menuEntries;  // {nonce, group, item}
  NSArray<NSString*>* _lastMenuTitles;
  NSString* _lastMenuGroup;
  NSInteger _lastFilledCount;
  NSDate* _fillRequestedAt;
}

- (instancetype)initWithHost:(MainWindowController*)host {
  if ((self = [super init])) {
    _host = host;
    _lastFilledCount = -1;
  }
  return self;
}

- (NSString*)pendingSavePrompt { return _pendingPrompt; }
- (NSArray<NSString*>*)lastMenuTitles { return _lastMenuTitles; }
- (NSString*)lastMenuGroup { return _lastMenuGroup; }
- (NSInteger)lastFilledCount { return _lastFilledCount; }

- (void)handleMessage:(NSString*)json browser:(int)browserId nonce:(NSString*)nonce origin:(NSString*)origin
            mainFrame:(BOOL)mainFrame {
  NSDictionary* m = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  if (![m isKindOfClass:NSDictionary.class]) return;
  NSString* t = m[@"t"];
  if ([t isEqualToString:@"save"]) [self offerSave:m origin:origin];
  else if ([t isEqualToString:@"focus"]) [self offerFill:m browser:browserId nonce:nonce origin:origin mainFrame:mainFrame];
  else if ([t isEqualToString:@"filled"]) _lastFilledCount = [m[@"n"] integerValue];
}

#pragma mark Saving

- (void)offerSave:(NSDictionary*)m origin:(NSString*)origin {
  NSString* user = [m[@"u"] isKindOfClass:NSString.class] ? m[@"u"] : @"";
  NSString* pw = [m[@"p"] isKindOfClass:NSString.class] ? m[@"p"] : nil;
  PasswordStore* store = [PasswordStore shared];
  if (!pw.length || pw.length > 4096 || user.length > 1024 || !store.usable || SettingBool(kSettingPasswordSavingOff) ||
      [store isNeverOrigin:origin])
    return;
  PasswordSaveResult r = [store checkOrigin:origin username:user password:pw];
  if (r == PasswordUnchanged) return;
  _pendingOrigin = origin;
  _pendingUser = user;
  _pendingSealed = [store seal:pw];
  NSString* site = DisplayHost(origin);
  if (r == PasswordUpdated) {
    _pendingPrompt = [NSString stringWithFormat:@"Update the saved password for %@ on %@?",
                                                user.length ? user : @"this account", site];
    [_host showToast:_pendingPrompt buttons:@[ @[ @"Update", @"savePending:" ] ] target:self duration:20];
  } else {
    _pendingPrompt = [NSString stringWithFormat:@"Save password for %@?", site];
    [_host showToast:_pendingPrompt
             buttons:@[ @[ @"Save", @"savePending:" ], @[ @"Never for This Site", @"neverPending:" ] ]
              target:self duration:20];
  }
}

- (void)clearPending {
  _pendingOrigin = _pendingUser = _pendingPrompt = nil;
  _pendingSealed = nil;
}

- (void)savePending:(id)sender {
  PasswordStore* store = [PasswordStore shared];
  NSString* pw = _pendingSealed ? [store unseal:_pendingSealed] : nil;
  if (_pendingOrigin && pw) [store saveOrigin:_pendingOrigin username:_pendingUser password:pw source:@"NotArc"];
  [self clearPending];
  [_host hideToast];
  [self refreshPasswordsWindow];
}

- (void)neverPending:(id)sender {
  if (_pendingOrigin) [[PasswordStore shared] setNever:YES forOrigin:_pendingOrigin];
  [self clearPending];
  [_host hideToast];
}

- (void)refreshPasswordsWindow {
  PasswordsWindowController* pw = [PasswordsWindowController shared];
  if (pw.window.isVisible) [pw reload];
}

#pragma mark Filling

- (BOOL)userJustActed:(NSString*)why {
  if (_host.selfTestProfiles) return YES;
  if ([why isEqualToString:@"request"]) return _fillRequestedAt && -_fillRequestedAt.timeIntervalSinceNow < 3;
  if (!_host.window.isKeyWindow) return NO;
  CGEventType type = [why isEqualToString:@"tab"] ? kCGEventKeyDown : kCGEventLeftMouseDown;
  return CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, type) < 1.5;
}

- (void)offerFill:(NSDictionary*)m browser:(int)browserId nonce:(NSString*)nonce origin:(NSString*)origin
        mainFrame:(BOOL)mainFrame {
  NSString* why = [m[@"why"] isKindOfClass:NSString.class] ? m[@"why"] : @"";
  NSString* group = [m[@"g"] isKindOfClass:NSString.class] ? m[@"g"] : @"";
  if (![self userJustActed:why]) return;  // only ever in answer to a click, Tab or Fill Password
  _fillRequestedAt = nil;
  PasswordStore* store = [PasswordStore shared];
  if (!store.usable) return;
  NSMutableArray* entries = [NSMutableArray array], *titles = [NSMutableArray array];
  if ([group isEqualToString:@"login"]) {
    for (SavedLogin* l in [store loginsForOrigin:origin]) {
      NSString* t = l.username.length ? l.username : @"(no username)";
      if (![l.origin isEqualToString:origin]) t = [t stringByAppendingFormat:@"  (%@)", DisplayHost(l.origin)];
      [titles addObject:t];
      [entries addObject:@{@"nonce" : nonce, @"group" : group, @"item" : l}];
    }
  } else if ([group isEqualToString:@"address"]) {
    for (AutofillAddress* a in store.addresses) {
      [titles addObject:a.summary];
      [entries addObject:@{@"nonce" : nonce, @"group" : group, @"item" : a}];
    }
  } else if ([group isEqualToString:@"card"]) {
    for (AutofillCard* c in store.cards) {
      [titles addObject:c.summary];
      [entries addObject:@{@"nonce" : nonce, @"group" : group, @"item" : c}];
    }
  }
  if (!entries.count) {
    if ([why isEqualToString:@"request"] && !_host.selfTestProfiles) NSBeep();  // Fill Password: nothing saved here
    return;
  }
  _menuEntries = entries;
  ++_menusOffered;
  _lastMenuTitles = titles;
  _lastMenuGroup = group;
  if (self.recordMenusOnly) return;

  NSMenu* menu = [[NSMenu alloc] initWithTitle:@"AutoFill"];
  menu.autoenablesItems = NO;
  for (NSUInteger i = 0; i < titles.count; ++i) {
    NSMenuItem* mi = [menu addItemWithTitle:titles[i] action:@selector(menuChose:) keyEquivalent:@""];
    mi.target = self;
    mi.tag = (NSInteger)i;
    mi.image = [NSImage imageWithSystemSymbolName:[group isEqualToString:@"login"] ? @"key.fill"
                                                  : [group isEqualToString:@"card"] ? @"creditcard" : @"person.crop.circle"
                         accessibilityDescription:nil];
  }
  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem* manage = [menu addItemWithTitle:[group isEqualToString:@"login"] ? @"Passwords..." : @"Addresses and Cards..."
                                       action:@selector(showPasswords:) keyEquivalent:@""];
  manage.target = _host;
  manage.tag = [group isEqualToString:@"login"] ? 0 : [group isEqualToString:@"card"] ? 2 : 1;

  NSView* view = [_host viewForBrowserId:browserId];
  if (!view.window) return;
  NSPoint at;
  double x = [m[@"x"] doubleValue], y = [m[@"y"] doubleValue], h = [m[@"h"] doubleValue];
  double scale = [m[@"d"] doubleValue] / (view.window.backingScaleFactor ?: 2);  // CSS px -> points (page zoom)
  if (scale <= 0) scale = 1;
  if (mainFrame && [m[@"top"] intValue]) {
    double top = (y + h) * scale + 4;
    at = NSMakePoint(x * scale, view.isFlipped ? top : NSHeight(view.bounds) - top);
  } else {  // a frame inside the page: its offset isn't known here, so open at the pointer
    at = [view convertPoint:[view.window convertPointFromScreen:NSEvent.mouseLocation] fromView:nil];
    if (!NSPointInRect(at, view.bounds)) at = NSMakePoint(20, view.isFlipped ? 20 : NSHeight(view.bounds) - 20);
  }
  dispatch_async(dispatch_get_main_queue(), ^{ [menu popUpMenuPositioningItem:nil atLocation:at inView:view]; });
}

- (void)menuChose:(NSMenuItem*)mi { [self chooseMenuItemAtIndex:mi.tag]; }

- (void)chooseMenuItemAtIndex:(NSInteger)index {
  if (index < 0 || index >= (NSInteger)_menuEntries.count) return;
  NSDictionary* e = _menuEntries[index];
  NSString* nonce = e[@"nonce"], *group = e[@"group"];
  id item = e[@"item"];
  PasswordStore* store = [PasswordStore shared];
  __weak MainWindowController* host = _host;
  void (^run)(NSDictionary*) = ^(NSDictionary* data) {
    [host autofillRun:[NSString stringWithFormat:@"window.__notarcAF&&window.__notarcAF.fill(%@)", JSLiteral(data)]
                nonce:nonce];
  };
  if ([item isKindOfClass:SavedLogin.class]) {
    SavedLogin* l = item;
    NSString* pw = [store passwordFor:l];
    if (!pw) return;
    l.lastUsed = [NSDate date];
    [store save];
    run(@{@"g" : @"login", @"u" : l.username ?: @"", @"p" : pw});
  } else if ([item isKindOfClass:AutofillAddress.class]) {
    run(@{@"g" : @"address", @"f" : ((AutofillAddress*)item).fields ?: @{}});
  } else if ([item isKindOfClass:AutofillCard.class]) {
    AutofillCard* c = item;
    AutofillAuthenticate(@"fill your card details", ^(BOOL ok) {
      NSString* number = ok ? [store cardNumberFor:c] : nil;
      if (!number) return;
      run(@{@"g" : group, @"f" : @{@"number" : number, @"name" : c.name ?: @"", @"month" : @(c.expMonth),
                                   @"year" : @(c.expYear)}});
    });
  }
}

- (void)fillPasswordInBrowser:(int)browserId {
  _fillRequestedAt = [NSDate date];
  [_host autofillRunAllFrames:@"window.__notarcAF&&window.__notarcAF.request()" browser:browserId];
}

#pragma mark Import

- (void)importPasswordsFromMenu {
  NSWindow* window = _host.window;
  ArcAlert* a = [ArcAlert new];
  a.messageText = @"Import Passwords";
  a.informativeText = @"Saved passwords, addresses and cards are copied into NotArc; the other browser isn't changed. "
                      @"macOS asks once for each browser's own Keychain key.";
  NSPopUpButton* from = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 26) pullsDown:NO];
  for (NSArray* s in DetectedPasswordSources()) {
    [from addItemWithTitle:s[0]];
    from.lastItem.representedObject = s;
  }
  [from addItemWithTitle:@"Passwords CSV file..."];
  from.lastItem.representedObject = @"csv";
  [from addItemWithTitle:@"Safari"];
  from.lastItem.representedObject = @"safari";
  a.accessoryView = from;
  [a addButtonWithTitle:@"Import"];
  [a addButtonWithTitle:@"Cancel"];
  __weak AutofillController* weakSelf = self;
  [a beginSheetModalForWindow:window completionHandler:^(NSModalResponse r) {
    if (r != NSAlertFirstButtonReturn) return;
    id src = from.selectedItem.representedObject;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf importFrom:src]; });
  }];
}

- (void)importFrom:(id)src {
  NSWindow* window = _host.window;
  PasswordStore* store = [PasswordStore shared];
  ArcAlert* done = [ArcAlert new];
  if (!store.usable) {
    done.messageText = @"NotArc couldn't open its password store";
    done.informativeText = @"It is locked with the \"NotArc Safe Storage\" item in your Keychain, which NotArc couldn't read.";
  } else if ([src isEqual:@"safari"]) {
    done.messageText = @"Safari's passwords can't be read by other apps";
    done.informativeText = @"They're kept in Apple's Passwords app. Open Passwords, choose File > Export All Passwords, "
                           @"then import that CSV file here (Passwords CSV file...) and delete it afterwards.";
  } else if ([src isEqual:@"csv"]) {
    NSOpenPanel* p = [NSOpenPanel openPanel];
    p.allowedContentTypes = @[ UTTypeCommaSeparatedText ];
    if ([p runModal] != NSModalResponseOK) return;
    NSUInteger n = [store importCSVFile:p.URL.path source:@"CSV"];
    done.messageText = n == NSNotFound ? @"That file doesn't look like a passwords export"
                       : n ? [NSString stringWithFormat:@"%lu passwords imported", (unsigned long)n]
                           : @"No new passwords to import";
    if (n != NSNotFound) done.informativeText = @"You can delete the CSV file now; it holds your passwords unencrypted.";
  } else if ([src isKindOfClass:NSArray.class]) {
    NSArray* s = src;
    NSString* pw = SafeStoragePassword(s[2], nil, nil);
    NSDictionary* n = pw ? [store importChromiumProfile:s[1] key:ArcCookieKey(pw) source:s[0]] : nil;
    if (!pw) {
      done.messageText = [NSString stringWithFormat:@"Couldn't unlock %@'s passwords", s[0]];
      done.informativeText = [NSString stringWithFormat:@"macOS didn't give NotArc the \"%@\" Keychain item.", s[2]];
    } else if (!n) {
      done.messageText = [NSString stringWithFormat:@"Couldn't read %@'s saved passwords", s[0]];
    } else {
      done.messageText = [NSString stringWithFormat:@"Imported from %@", s[0]];
      done.informativeText = [NSString stringWithFormat:@"%@ passwords, %@ addresses, %@ cards added.%@", n[@"passwords"],
                                                        n[@"addresses"], n[@"cards"],
                                                        [n[@"undecryptable"] intValue]
                                                            ? [NSString stringWithFormat:@" %@ items couldn't be decrypted.",
                                                                                         n[@"undecryptable"]]
                                                            : @""];
    }
  } else {
    return;
  }
  [self refreshPasswordsWindow];
  [done beginSheetModalForWindow:window completionHandler:nil];
}

@end
