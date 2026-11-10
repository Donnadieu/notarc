#import "app/arc_max.h"

#import "app/settings.h"
#import "NotArcAI-Swift.h"  // generated from app/on_device_ai.swift by the build

#include <cmath>

NSString* const kSettingMaxEnabled = @"maxEnabled";
NSString* const kSettingMaxAskOnPage = @"maxAskOnPage";
NSString* const kSettingMaxChatGPT = @"maxChatGPT";
NSString* const kSettingMaxPreviews = @"maxPreviews";
NSString* const kSettingMaxTidyTabs = @"maxTidyTabs";
NSString* const kSettingMaxTidyTitles = @"maxTidyTitles";

NSDictionary* MaxDefaultSettings(void) {
  return @{ kSettingMaxEnabled : @YES, kSettingMaxAskOnPage : @YES, kSettingMaxChatGPT : @YES, kSettingMaxPreviews : @YES,
            kSettingMaxTidyTabs : @YES, kSettingMaxTidyTitles : @YES };
}

BOOL MaxFeatureOn(NSString* key) { return SettingBool(kSettingMaxEnabled) && (!key || SettingBool(key)); }

#pragma mark Model

static NSString* g_testAvailability;
static MaxResponder g_testResponder;

void MaxSetTestModel(NSString* availability, MaxResponder responder) {
  g_testAvailability = [availability copy];
  g_testResponder = [responder copy];
}

NSString* MaxRealModelAvailability(void) { return [NotArcOnDeviceModel availabilityDescription]; }

NSString* MaxModelAvailability(void) { return g_testAvailability ?: MaxRealModelAvailability(); }
BOOL MaxModelAvailable(void) { return [MaxModelAvailability() isEqualToString:@"available"]; }
BOOL MaxTidyTitlesUseModel(void) { return MaxFeatureOn(kSettingMaxTidyTitles) && MaxModelAvailable(); }

NSString* MaxModelStatusText(NSString* a) {
  if ([a isEqualToString:@"available"]) return @"Apple Intelligence is on. Max runs on this Mac with Apple's built-in model.";
  if ([a hasSuffix:@":off"])
    return @"Apple Intelligence is off. Turn it on in System Settings > Apple Intelligence & Siri to use the AI parts of Max.";
  if ([a hasSuffix:@":notready"]) return @"Apple's on-device model is still downloading. Max uses the non-AI versions until it's ready.";
  if ([a hasSuffix:@":device"]) return @"This Mac can't run Apple Intelligence, so Max uses its non-AI versions.";
  if ([a hasSuffix:@":os"]) return @"Apple's on-device model needs macOS 26 or later, so Max uses its non-AI versions.";
  return @"Apple's on-device model isn't available, so Max uses its non-AI versions.";
}

void MaxRespond(NSString* instructions, NSString* prompt, MaxReply done) {
  MaxReply finish = [done copy];
  if (g_testAvailability) {
    if (![g_testAvailability isEqualToString:@"available"] || !g_testResponder) {
      dispatch_async(dispatch_get_main_queue(), ^{ finish(nil, g_testAvailability); });
      return;
    }
    MaxResponder r = g_testResponder;
    dispatch_async(dispatch_get_main_queue(), ^{ r(instructions, prompt, finish); });
    return;
  }
  [NotArcOnDeviceModel respondWithInstructions:instructions prompt:prompt completion:^(NSString* text, NSString* error) {
    finish(text, error);
  }];
}

#pragma mark Prompts

NSString* MaxTrimText(NSString* text, NSUInteger limit) {
  if (!text.length) return @"";
  NSMutableArray<NSString*>* lines = [NSMutableArray array];
  for (NSString* raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    NSString* l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (l.length) [lines addObject:l];
  }
  NSString* joined = [lines componentsJoinedByString:@"\n"];
  if (joined.length <= limit) return joined;
  NSString* cut = [joined substringToIndex:limit];
  NSRange space = [cut rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet options:NSBackwardsSearch];
  if (space.location != NSNotFound && space.location > limit * 3 / 4) cut = [cut substringToIndex:space.location];
  return [cut stringByAppendingString:@" …"];
}

// Apple's on-device model has a 4,096-token window (instructions, page and answer together), so page text is cut
// to a few thousand characters; the start of a page usually carries what matters.
static const NSUInteger kAskTextLimit = 7000;

NSString* MaxAskInstructions(void) {
  return @"You answer questions about a web page using only the page text you are given. Answer in at most four short "
         @"sentences. If the page text doesn't contain the answer, say that the page doesn't say. Don't make things up.";
}

NSString* MaxAskPrompt(NSString* question, NSString* title, NSString* url, NSString* pageText) {
  return [NSString stringWithFormat:@"Page title: %@\nAddress: %@\n\nPage text:\n\"\"\"\n%@\n\"\"\"\n\nQuestion: %@",
                                    title ?: @"", url ?: @"", MaxTrimText(pageText, kAskTextLimit), question ?: @""];
}

NSString* MaxSummaryInstructions(NSUInteger bullets) {
  return [NSString stringWithFormat:@"You summarise web pages. Reply with %lu short bullet points, each on its own line "
                                    @"starting with \"- \", covering the main points of the page text you are given. "
                                    @"Use only that text and nothing else.",
                                    (unsigned long)MAX((NSUInteger)1, bullets)];
}

NSString* MaxSummaryPrompt(NSString* title, NSString* url, NSString* pageText, NSUInteger limit) {
  return [NSString stringWithFormat:@"Page title: %@\nAddress: %@\n\nPage text:\n\"\"\"\n%@\n\"\"\"",
                                    title ?: @"", url ?: @"", MaxTrimText(pageText, limit ?: kAskTextLimit)];
}

static NSString* SiteOfURL(NSString* url) {
  NSString* h = [NSURL URLWithString:url ?: @""].host.lowercaseString ?: @"";
  return [h hasPrefix:@"www."] ? [h substringFromIndex:4] : h;
}

static const NSUInteger kTidyMaxTabs = 40;

NSString* MaxTidyTabsInstructions(void) {
  return @"You label web browser tabs with a short topic. Follow the reply format exactly.";
}

// The on-device model is small: asking it for whole folders gave muddled groups, while one topic per tab (then
// grouping equal topics here) gave clean ones. The parser also accepts "Folder: 1, 4" lines in case it answers that way.
NSString* MaxTidyTabsPrompt(NSArray<NSDictionary*>* tabs) {
  NSMutableString* list = [NSMutableString string];
  NSUInteger n = 0;
  for (NSDictionary* t in tabs) {
    if (n >= kTidyMaxTabs) break;
    NSString* title = MaxTrimText(t[@"title"] ?: @"", 80);
    [list appendFormat:@"%lu. %@ (%@)\n", (unsigned long)++n, title, SiteOfURL(t[@"url"])];
  }
  return [NSString stringWithFormat:
      @"Give each tab a broad topic of 1 or 2 words, such as Programming, News, Cooking or Travel. Tabs about the same "
      @"subject must get exactly the same topic. Reply with one line per tab in the form \"3: Topic\" and nothing else.\n\n"
      @"Tabs:\n%@", list];
}

static NSString* TopicName(NSString* raw) {
  NSString* t = [[raw stringByReplacingOccurrencesOfString:@"**" withString:@""]
      stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t-*•#\"'`.:"]];
  if (!t.length || t.length > 40) return nil;
  return [[t substringToIndex:1].uppercaseString stringByAppendingString:[t substringFromIndex:1]];
}

NSArray<NSDictionary*>* MaxParseTidyGroups(NSString* reply, NSUInteger tabCount) {
  NSMutableArray<NSString*>* order = [NSMutableArray array];               // topic keys, first seen first
  NSMutableDictionary<NSString*, NSString*>* names = [NSMutableDictionary dictionary];
  NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* members = [NSMutableDictionary dictionary];
  NSMutableSet<NSNumber*>* used = [NSMutableSet set];
  NSCharacterSet* digits = NSCharacterSet.decimalDigitCharacterSet;
  NSCharacterSet* listChars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789, "];
  void (^add)(NSString*, NSInteger) = ^(NSString* topic, NSInteger number) {
    NSString* name = TopicName(topic);
    if (!name || number < 1 || number > (NSInteger)tabCount) return;
    NSNumber* zero = @(number - 1);
    if ([used containsObject:zero]) return;
    NSString* key = name.lowercaseString;
    if (!members[key]) {
      members[key] = [NSMutableArray array];
      names[key] = name;
      [order addObject:key];
    }
    [members[key] addObject:zero];
    [used addObject:zero];
  };
  NSArray<NSString*>* lines = [reply ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet];
  // "N: Topic" replies with one line per tab: trust the line order over the numbers, which the small model sometimes
  // gets wrong ("3: Programming" for the first tab).
  NSUInteger labelLines = 0;
  for (NSString* raw in lines) {
    NSRange c = [raw rangeOfString:@":"];
    NSString* l = c.location == NSNotFound ? @"" : [[raw substringToIndex:c.location]
        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t-*•"]];
    if (l.length && [l rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound) ++labelLines;
  }
  BOOL byPosition = labelLines == tabCount;
  NSInteger position = 0;
  for (NSString* raw in lines) {
    NSString* line = [raw stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t-*•"]];
    NSRange colon = [line rangeOfString:@":"];
    if (colon.location == NSNotFound || colon.location == 0) continue;
    NSString* left = [[line substringToIndex:colon.location] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSString* right = [[line substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    left = [left stringByReplacingOccurrencesOfString:@"**" withString:@""];
    if ([left hasPrefix:@"Tab "] || [left hasPrefix:@"tab "]) left = [left substringFromIndex:4];
    if (left.length && [left rangeOfCharacterFromSet:digits.invertedSet].location == NSNotFound) {
      ++position;
      add(right, byPosition ? position : left.integerValue);  // "3: Cooking"
      continue;
    }
    // "Cooking: 1, 4 and 7"
    NSString* list = [[right stringByReplacingOccurrencesOfString:@"and" withString:@","]
        stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" .\t"]];
    if (!list.length || [list rangeOfCharacterFromSet:listChars.invertedSet].location != NSNotFound) continue;
    for (NSString* part in [list componentsSeparatedByString:@","]) {
      NSString* p = [part stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
      if (p.length) add(left, p.integerValue);
    }
  }
  NSMutableArray* out = [NSMutableArray array];
  for (NSString* key in order) {
    if (members[key].count < 2) continue;
    [out addObject:@{ @"name" : names[key], @"indexes" : members[key] }];
    if (out.count >= 6) break;
  }
  return out;
}

// A readable folder name for a site: "github.com" -> "GitHub" is out of reach without a list, so drop the ending
// and capitalise: "news.ycombinator.com" -> "Ycombinator", "nytimes.com" -> "Nytimes".
static NSString* SiteFolderName(NSString* site) {
  NSArray<NSString*>* parts = [site componentsSeparatedByString:@"."];
  NSString* core = parts.count >= 2 ? parts[parts.count - 2] : site;
  static NSSet* second;
  if (!second) second = [NSSet setWithArray:@[ @"co", @"com", @"org", @"net", @"ac", @"gov", @"edu", @"ne", @"or" ]];
  if (parts.count >= 3 && [second containsObject:core]) core = parts[parts.count - 3];  // bbc.co.uk -> Bbc
  if (!core.length) return site;
  return [[core substringToIndex:1].uppercaseString stringByAppendingString:[core substringFromIndex:1]];
}

static NSString* RegistrableSite(NSString* site) {
  NSArray<NSString*>* parts = [site componentsSeparatedByString:@"."];
  if (parts.count <= 2) return site;
  NSString* last2 = [[parts subarrayWithRange:NSMakeRange(parts.count - 2, 2)] componentsJoinedByString:@"."];
  // "co.uk", "com.au": keep three labels.
  if (parts[parts.count - 2].length <= 3 && parts.lastObject.length == 2)
    return [[parts subarrayWithRange:NSMakeRange(parts.count - 3, 3)] componentsJoinedByString:@"."];
  return last2;
}

NSArray<NSDictionary*>* MaxGroupTabsBySite(NSArray<NSDictionary*>* tabs) {
  NSMutableArray<NSString*>* order = [NSMutableArray array];
  NSMutableDictionary<NSString*, NSMutableArray<NSNumber*>*>* bySite = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < tabs.count; ++i) {
    NSString* site = RegistrableSite(SiteOfURL(tabs[i][@"url"]));
    if (!site.length) continue;
    if (!bySite[site]) {
      bySite[site] = [NSMutableArray array];
      [order addObject:site];
    }
    [bySite[site] addObject:@(i)];
  }
  NSMutableArray* out = [NSMutableArray array];
  for (NSString* site in order)
    if (bySite[site].count >= 2) [out addObject:@{ @"name" : SiteFolderName(site), @"indexes" : bySite[site] }];
  return out;
}

NSString* MaxTidyTitleInstructions(void) {
  return @"You shorten web browser tab titles. Reply with only the new title: 1 to 5 words, no site name, no quotes, "
         @"no emoji, keeping the main subject.";
}

NSString* MaxTidyTitlePrompt(NSString* title, NSString* url) {
  return [NSString stringWithFormat:@"Tab title: %@\nSite: %@", MaxTrimText(title, 200), SiteOfURL(url)];
}

NSString* MaxCleanModelTitle(NSString* reply) {
  NSString* first = nil;
  for (NSString* l in [reply ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    NSString* t = [l stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (t.length) {
      first = t;
      break;
    }
  }
  if (!first) return nil;
  if ([first.lowercaseString hasPrefix:@"title:"]) first = [first substringFromIndex:6];
  first = [first stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" \t\"'“”‘’*`."]];
  if (first.length > 60) first = [[first substringToIndex:60] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  return first.length ? first : nil;
}

NSString* MaxCleanSummary(NSString* reply) {
  NSMutableArray<NSString*>* lines = [NSMutableArray array];
  for (NSString* raw in [reply ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    NSString* l = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!l.length) continue;
    for (NSString* b in @[ @"- ", @"* ", @"• " ])
      if ([l hasPrefix:b]) l = [@"• " stringByAppendingString:[l substringFromIndex:b.length]];
    l = [l stringByReplacingOccurrencesOfString:@"**" withString:@""];
    [lines addObject:l];
  }
  return [lines componentsJoinedByString:@"\n"];
}

#pragma mark Non-AI fallbacks

NSArray<NSString*>* MaxSentences(NSString* text) {
  NSMutableArray<NSString*>* out = [NSMutableArray array];
  for (NSString* para in [text ?: @"" componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
    [para enumerateSubstringsInRange:NSMakeRange(0, para.length)
                             options:NSStringEnumerationBySentences
                          usingBlock:^(NSString* s, NSRange, NSRange, BOOL*) {
                            NSString* t = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
                            // Real sentences: a few words and not a menu label.
                            if (t.length >= 25 && t.length <= 400 && [t componentsSeparatedByString:@" "].count >= 5)
                              [out addObject:t];
                          }];
  }
  return out;
}

static NSArray<NSString*>* Words(NSString* s) {
  NSMutableArray* out = [NSMutableArray array];
  static NSSet* stop;
  if (!stop)
    stop = [NSSet setWithArray:@[ @"the", @"a", @"an", @"and", @"or", @"of", @"to", @"in", @"on", @"for", @"is", @"are",
                                  @"was", @"were", @"be", @"it", @"its", @"this", @"that", @"with", @"as", @"at", @"by",
                                  @"from", @"what", @"which", @"who", @"how", @"when", @"why", @"does", @"do", @"did",
                                  @"can", @"you", @"your", @"i", @"we", @"they", @"he", @"she", @"not", @"but", @"have",
                                  @"has", @"had", @"will", @"would", @"there", @"their", @"about", @"page" ]];
  [s.lowercaseString enumerateSubstringsInRange:NSMakeRange(0, s.length)
                                        options:NSStringEnumerationByWords
                                     usingBlock:^(NSString* w, NSRange, NSRange, BOOL*) {
                                       if (w.length > 1 && ![stop containsObject:w]) [out addObject:w];
                                     }];
  return out;
}

NSString* MaxExtractiveSummary(NSString* text, NSUInteger count) {
  NSArray<NSString*>* sentences = MaxSentences(text);
  if (!sentences.count) return MaxTrimText(text, 300);
  NSCountedSet* freq = [NSCountedSet set];
  for (NSString* s in sentences) [freq addObjectsFromArray:Words(s)];
  NSMutableArray<NSArray*>* scored = [NSMutableArray array];
  for (NSUInteger i = 0; i < sentences.count && i < 400; ++i) {
    NSArray* w = Words(sentences[i]);
    double score = 0;
    for (NSString* x in w) score += [freq countForObject:x];
    score = w.count ? score / std::sqrt((double)w.count) : 0;
    score *= 1.0 + 0.5 / (1 + i);  // earlier sentences lean slightly ahead
    [scored addObject:@[ @(score), @(i) ]];
  }
  [scored sortUsingComparator:^NSComparisonResult(NSArray* a, NSArray* b) { return [b[0] compare:a[0]]; }];
  NSMutableArray<NSNumber*>* pick = [NSMutableArray array];
  for (NSArray* s in scored) {
    if (pick.count >= count) break;
    [pick addObject:s[1]];
  }
  [pick sortUsingSelector:@selector(compare:)];
  NSMutableArray* lines = [NSMutableArray array];
  for (NSNumber* i in pick) [lines addObject:[@"• " stringByAppendingString:sentences[i.unsignedIntegerValue]]];
  return [lines componentsJoinedByString:@"\n"];
}

NSString* MaxBestMatchingSentences(NSString* question, NSString* text, NSUInteger count) {
  NSSet* q = [NSSet setWithArray:Words(question)];
  if (!q.count) return nil;
  NSArray<NSString*>* sentences = MaxSentences(text);
  NSMutableArray<NSArray*>* scored = [NSMutableArray array];
  for (NSUInteger i = 0; i < sentences.count; ++i) {
    NSSet* w = [NSSet setWithArray:Words(sentences[i])];
    NSMutableSet* both = [q mutableCopy];
    [both intersectSet:w];
    if (both.count) [scored addObject:@[ @(both.count + 0.001 * (sentences.count - i)), @(i) ]];
  }
  if (!scored.count) return nil;
  [scored sortUsingComparator:^NSComparisonResult(NSArray* a, NSArray* b) { return [b[0] compare:a[0]]; }];
  NSMutableArray<NSNumber*>* pick = [NSMutableArray array];
  for (NSArray* s in scored) {
    if (pick.count >= count) break;
    [pick addObject:s[1]];
  }
  [pick sortUsingSelector:@selector(compare:)];
  NSMutableArray* lines = [NSMutableArray array];
  for (NSNumber* i in pick) [lines addObject:[@"• " stringByAppendingString:sentences[i.unsignedIntegerValue]]];
  return [lines componentsJoinedByString:@"\n"];
}

NSString* MaxChatGPTURL(NSString* question) {
  NSString* q = [question ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSMutableCharacterSet* allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
  [allowed removeCharactersInString:@"&=+?#/;:@$,"];
  return [@"https://chatgpt.com/?q=" stringByAppendingString:[q stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @""];
}

#pragma mark Page scripts and their reply channel

NSString* MaxNewNonce(void) {
  return [NSString stringWithFormat:@"%08x%08x", arc4random(), arc4random()];
}

// Shared head of both scripts: send(s) posts s back in console chunks tagged with the nonce.
static NSString* ScriptHead(NSString* nonce) {
  return [NSString stringWithFormat:
      @"var N='%@';function send(s){s=String(s);var z=16000,n=Math.max(1,Math.ceil(s.length/z));"
      @"for(var i=0;i<n;i++)console.log('__notarc_max__:'+N+':'+i+'/'+n+':'+s.substr(i*z,z));}"
      @"function rootEl(){var r=document.querySelector('article')||document.querySelector('main,[role=main]');"
      @"if(r&&(r.innerText||'').length>=200)return r;return document.body||document.documentElement;}", nonce];
}

NSString* MaxPageTextScript(NSString* nonce) {
  return [NSString stringWithFormat:
      @"(function(){%@try{var r=rootEl(),t=r?r.innerText:'';"
      @"var d=document.querySelector('meta[name=description],meta[property=\"og:description\"]');"
      @"send(JSON.stringify({title:document.title,url:location.href,description:d?(d.content||''):'',text:(t||'').slice(0,60000)}));"
      @"}catch(e){send(JSON.stringify({error:String(e)}));}})()", ScriptHead(nonce)];
}

// DOM to Markdown, written for NotArc (no library): headings, paragraphs, emphasis, code and pre blocks, links and
// images (made absolute), nested lists, block quotes, tables and rules. Scripts, styles, forms, navigation and
// hidden elements are skipped. \u0001 marks list indentation and \u0002n\u0002 a pre block until the end, so the
// whitespace clean-up can't eat them.
static NSString* const kMarkdownBody =
    @"var SKIP={SCRIPT:1,STYLE:1,NOSCRIPT:1,TEMPLATE:1,SVG:1,CANVAS:1,IFRAME:1,BUTTON:1,INPUT:1,SELECT:1,TEXTAREA:1,"
    @"FORM:1,NAV:1,HEAD:1,DIALOG:1,OBJECT:1,EMBED:1,VIDEO:1,AUDIO:1};"
    @"var BLOCK={DIV:1,SECTION:1,ARTICLE:1,MAIN:1,HEADER:1,FOOTER:1,ASIDE:1,FIGURE:1,FIGCAPTION:1,DL:1,DT:1,DD:1,"
    @"DETAILS:1,SUMMARY:1,ADDRESS:1,LI:1,CENTER:1};"
    @"var PRE=[];"
    @"function hid(e){try{if(e.hidden||e.getAttribute('aria-hidden')==='true')return true;"
    @"if(e.checkVisibility)return !e.checkVisibility();var s=getComputedStyle(e);return s.display==='none'||s.visibility==='hidden';"
    @"}catch(x){return false;}}"
    @"function abs(u){try{return new URL(u,location.href).href}catch(x){return u||''}}"
    @"function clean(s){return s.replace(/\\u00a0/g,' ').replace(/[ \\t]+\\n/g,'\\n').replace(/\\n[ \\t]+/g,'\\n')"
    @".replace(/[ \\t]{2,}/g,' ').replace(/\\n{3,}/g,'\\n\\n').trim();}"
    @"function kids(n){var s='';for(var c=n.firstChild;c;c=c.nextSibling)s+=md(c);return s;}"
    @"function wrap(n,m){var t=clean(kids(n)).replace(/\\n+/g,' ');return t?m+t+m:'';}"
    @"function list(n){var ol=n.tagName==='OL',i=parseInt(n.getAttribute('start')||'1',10)||1,out=[];"
    @"for(var c=n.firstElementChild;c;c=c.nextElementSibling){if(c.tagName!=='LI'||hid(c))continue;"
    @"var mk=ol?(i++)+'. ':'- ',pad=Array(mk.length+1).join('\\u0001');"
    @"var ls=clean(kids(c)).split('\\n').filter(function(l){return l.trim()!=='';});if(!ls.length)continue;"
    @"out.push(mk+ls[0]+(ls.length>1?'\\n'+ls.slice(1).map(function(l){return pad+l;}).join('\\n'):''));}"
    @"return out.join('\\n');}"
    @"function table(n){var rows=[],w=0;var trs=n.querySelectorAll('tr');for(var r=0;r<trs.length;r++){"
    @"if(trs[r].closest('table')!==n)continue;var cs=[];for(var c=trs[r].firstElementChild;c;c=c.nextElementSibling)"
    @"if(c.tagName==='TD'||c.tagName==='TH')cs.push(clean(kids(c)).replace(/\\n+/g,' ').replace(/\\|/g,'\\\\|'));"
    @"if(cs.length){rows.push(cs);w=Math.max(w,cs.length);}}if(!rows.length)return '';"
    @"function line(cs){var a=cs.slice();while(a.length<w)a.push('');return '| '+a.join(' | ')+' |';}"
    @"var sep=[];for(var k=0;k<w;k++)sep.push('---');"
    @"return [line(rows[0]),line(sep)].concat(rows.slice(1).map(line)).join('\\n');}"
    @"function md(n){if(n.nodeType===3)return n.nodeValue.replace(/\\s+/g,' ');if(n.nodeType!==1)return '';"
    @"var t=n.tagName;if(SKIP[t]||hid(n))return '';"
    @"if(/^H[1-6]$/.test(t)){var h=clean(kids(n)).replace(/\\n+/g,' ');return h?'\\n\\n'+Array(+t[1]+1).join('#')+' '+h+'\\n\\n':'';}"
    @"switch(t){"
    @"case 'P':return '\\n\\n'+kids(n)+'\\n\\n';"
    @"case 'BR':return '\\n';"
    @"case 'HR':return '\\n\\n---\\n\\n';"
    @"case 'STRONG':case 'B':return wrap(n,'**');"
    @"case 'EM':case 'I':return wrap(n,'*');"
    @"case 'S':case 'DEL':case 'STRIKE':return wrap(n,'~~');"
    @"case 'CODE':case 'KBD':case 'SAMP':{var c=n.textContent;return c?'`'+c+'`':'';}"
    @"case 'PRE':{PRE.push(n.textContent.replace(/\\n+$/,''));return '\\n\\n\\u0002'+(PRE.length-1)+'\\u0002\\n\\n';}"
    @"case 'A':{var a=clean(kids(n)).replace(/\\n+/g,' '),u=n.getAttribute('href');"
    @"if(!u||u.charAt(0)==='#'||/^javascript:/i.test(u))return a;return a?'['+a.replace(/\\]/g,'\\\\]')+']('+abs(u)+')':'';}"
    @"case 'IMG':{var s=n.getAttribute('src');if(!s||/^data:/i.test(s))return '';"
    @"return '!['+(n.getAttribute('alt')||'').trim()+']('+abs(s)+')';}"
    @"case 'UL':case 'OL':return '\\n\\n'+list(n)+'\\n\\n';"
    @"case 'BLOCKQUOTE':{var q=clean(kids(n));return q?'\\n\\n'+q.split('\\n').map(function(l){return l?'> '+l:'>';}).join('\\n')+'\\n\\n':'';}"
    @"case 'TABLE':return '\\n\\n'+table(n)+'\\n\\n';"
    @"}"
    @"if(BLOCK[t])return '\\n\\n'+kids(n)+'\\n\\n';return kids(n);}"
    @"function toMarkdown(root){var body=clean(md(root));"
    @"body=body.replace(/\\u0002(\\d+)\\u0002/g,function(m,i){return '```\\n'+PRE[+i]+'\\n```';}).replace(/\\u0001/g,' ');"
    @"var title=(document.title||'').trim(),head='',src='Source: '+location.href;"
    @"if(/^# /.test(body)){var nl=body.indexOf('\\n');head=nl<0?body:body.slice(0,nl);body=nl<0?'':body.slice(nl).trim();}"
    @"else if(title)head='# '+title;"
    @"var out=(head?head+'\\n\\n':'')+src+(body?'\\n\\n'+body:'');return out.slice(0,2000000)+'\\n';}";

NSString* MaxPageMarkdownScript(NSString* nonce) {
  return [NSString stringWithFormat:@"(function(){%@%@try{send(toMarkdown(rootEl()));}catch(e){send('');}})()", ScriptHead(nonce),
                                    kMarkdownBody];
}

@interface MaxPendingReply : NSObject
@property(nonatomic, copy) void (^done)(NSString*);
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSString*>* parts;
@property(nonatomic) NSUInteger total;
@end
@implementation MaxPendingReply
@end

static NSMutableDictionary<NSString*, MaxPendingReply*>* g_pending;

void MaxExpectPageReply(NSString* nonce, NSTimeInterval timeout, void (^done)(NSString* payload)) {
  if (!g_pending) g_pending = [NSMutableDictionary dictionary];
  MaxPendingReply* p = [MaxPendingReply new];
  p.done = done;
  p.parts = [NSMutableDictionary dictionary];
  g_pending[nonce] = p;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    MaxPendingReply* still = g_pending[nonce];
    if (still != p) return;
    [g_pending removeObjectForKey:nonce];
    if (p.done) p.done(nil);
  });
}

BOOL MaxHandleConsoleMessage(NSString* m) {
  static NSString* const kPrefix = @"__notarc_max__:";
  if (![m hasPrefix:kPrefix]) return NO;
  NSString* rest = [m substringFromIndex:kPrefix.length];
  NSRange c1 = [rest rangeOfString:@":"];
  if (c1.location == NSNotFound) return YES;
  NSString* nonce = [rest substringToIndex:c1.location];
  NSString* afterNonce = [rest substringFromIndex:NSMaxRange(c1)];
  NSRange c2 = [afterNonce rangeOfString:@":"];
  if (c2.location == NSNotFound) return YES;
  NSArray<NSString*>* seq = [[afterNonce substringToIndex:c2.location] componentsSeparatedByString:@"/"];
  NSString* chunk = [afterNonce substringFromIndex:NSMaxRange(c2)];
  MaxPendingReply* p = g_pending[nonce];
  if (!p || seq.count != 2) return YES;  // late, unknown or forged: swallow
  NSInteger i = seq[0].integerValue, n = seq[1].integerValue;
  if (n < 1 || n > 200 || i < 0 || i >= n || (p.total && (NSInteger)p.total != n)) return YES;
  p.total = (NSUInteger)n;
  p.parts[@(i)] = chunk;
  if (p.parts.count < p.total) return YES;
  NSMutableString* all = [NSMutableString string];
  for (NSInteger k = 0; k < n; ++k) [all appendString:p.parts[@(k)] ?: @""];
  [g_pending removeObjectForKey:nonce];
  if (p.done) p.done(all);
  return YES;
}

#pragma mark Link previews

static NSString* DecodeEntities(NSString* s) {
  if ([s rangeOfString:@"&"].location == NSNotFound) return s;
  NSMutableString* out = [NSMutableString stringWithCapacity:s.length];
  NSScanner* sc = [NSScanner scannerWithString:s];
  sc.charactersToBeSkipped = nil;
  NSDictionary* named = @{ @"amp" : @"&", @"lt" : @"<", @"gt" : @">", @"quot" : @"\"", @"apos" : @"'", @"nbsp" : @" ",
                           @"mdash" : @"—", @"ndash" : @"–", @"hellip" : @"…", @"rsquo" : @"’", @"lsquo" : @"‘",
                           @"rdquo" : @"”", @"ldquo" : @"“", @"copy" : @"©" };
  while (!sc.atEnd) {
    NSString* chunk = nil;
    if ([sc scanUpToString:@"&" intoString:&chunk]) [out appendString:chunk];
    if (sc.atEnd) break;
    sc.scanLocation += 1;
    NSString* ent = nil;
    NSUInteger start = sc.scanLocation;
    if ([sc scanUpToString:@";" intoString:&ent] && !sc.atEnd && ent.length <= 10) {
      sc.scanLocation += 1;
      NSString* rep = named[ent];
      if (!rep && [ent hasPrefix:@"#"]) {
        unsigned code = 0;
        if ([ent hasPrefix:@"#x"] || [ent hasPrefix:@"#X"])
          [[NSScanner scannerWithString:[ent substringFromIndex:2]] scanHexInt:&code];
        else
          code = (unsigned)[ent substringFromIndex:1].intValue;
        if (code > 0 && code < 0x110000) {
          UTF32Char c = code;
          rep = [[NSString alloc] initWithBytes:&c length:4 encoding:NSUTF32LittleEndianStringEncoding];
        }
      }
      if (rep) {
        [out appendString:rep];
        continue;
      }
    }
    sc.scanLocation = start;
    [out appendString:@"&"];
  }
  return out;
}

static NSString* StripTags(NSString* s) {
  static NSRegularExpression* tags;
  if (!tags) tags = [NSRegularExpression regularExpressionWithPattern:@"<[^>]*>" options:0 error:nil];
  NSString* t = [tags stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@" "];
  t = DecodeEntities(t);
  NSArray* words = [t componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return [[words filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
}

static NSString* MetaContent(NSString* html, NSArray<NSString*>* names) {
  static NSRegularExpression* meta, *attr;
  if (!meta) {
    meta = [NSRegularExpression regularExpressionWithPattern:@"<meta\\b[^>]*>" options:NSRegularExpressionCaseInsensitive error:nil];
    attr = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z:-]+)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)" options:0 error:nil];
  }
  for (NSTextCheckingResult* m in [meta matchesInString:html options:0 range:NSMakeRange(0, MIN(html.length, (NSUInteger)200000))]) {
    NSString* tag = [html substringWithRange:m.range];
    NSMutableDictionary* a = [NSMutableDictionary dictionary];
    for (NSTextCheckingResult* r in [attr matchesInString:tag options:0 range:NSMakeRange(0, tag.length)]) {
      NSString* v = [tag substringWithRange:[r rangeAtIndex:2]];
      if ([v hasPrefix:@"\""] || [v hasPrefix:@"'"]) v = [v substringWithRange:NSMakeRange(1, v.length - 2)];
      a[[tag substringWithRange:[r rangeAtIndex:1]].lowercaseString] = v;
    }
    NSString* key = [(a[@"name"] ?: a[@"property"]) lowercaseString];
    if (key && [names containsObject:key] && [a[@"content"] length]) return StripTags(a[@"content"]);
  }
  return nil;
}

NSDictionary* MaxParseHTML(NSString* html) {
  if (!html.length) return @{ @"title" : @"", @"description" : @"", @"text" : @"" };
  NSRegularExpressionOptions o = NSRegularExpressionCaseInsensitive | NSRegularExpressionDotMatchesLineSeparators;
  NSRegularExpression* junk = [NSRegularExpression
      regularExpressionWithPattern:@"<!--.*?-->|<(script|style|noscript|svg|template|nav|header|footer|form)\\b.*?</\\1\\s*>"
                           options:o error:nil];
  NSString* h = [junk stringByReplacingMatchesInString:html options:0 range:NSMakeRange(0, html.length) withTemplate:@" "];
  NSRegularExpression* titleRe = [NSRegularExpression regularExpressionWithPattern:@"<title\\b[^>]*>(.*?)</title>" options:o error:nil];
  NSTextCheckingResult* tm = [titleRe firstMatchInString:html options:0 range:NSMakeRange(0, html.length)];
  NSString* title = MetaContent(html, @[ @"og:title" ]) ?: (tm ? StripTags([html substringWithRange:[tm rangeAtIndex:1]]) : @"");
  NSString* desc = MetaContent(html, @[ @"description", @"og:description", @"twitter:description" ]) ?: @"";
  NSRegularExpression* para = [NSRegularExpression regularExpressionWithPattern:@"<(p|h[1-3]|li)\\b[^>]*>(.*?)</\\1\\s*>" options:o error:nil];
  NSMutableArray* paras = [NSMutableArray array];
  NSUInteger total = 0;
  for (NSTextCheckingResult* m in [para matchesInString:h options:0 range:NSMakeRange(0, h.length)]) {
    NSString* t = StripTags([h substringWithRange:[m rangeAtIndex:2]]);
    if (t.length < 2) continue;
    [paras addObject:t];
    total += t.length;
    if (total > 20000) break;
  }
  NSString* text = [paras componentsJoinedByString:@"\n"];
  if (text.length < 200) {
    NSRegularExpression* bodyRe = [NSRegularExpression regularExpressionWithPattern:@"<body\\b[^>]*>(.*)" options:o error:nil];
    NSTextCheckingResult* bm = [bodyRe firstMatchInString:h options:0 range:NSMakeRange(0, h.length)];
    NSString* all = StripTags(bm ? [h substringWithRange:[bm rangeAtIndex:1]] : h);
    if (all.length > text.length) text = all.length > 20000 ? [all substringToIndex:20000] : all;
  }
  return @{ @"title" : title ?: @"", @"description" : desc, @"text" : text ?: @"" };
}

BOOL MaxPreviewURLAllowed(NSString* url) {
  NSString* scheme = [NSURL URLWithString:url ?: @""].scheme.lowercaseString;
  return [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"http"];
}

static void (^g_testFetcher)(NSString*, MaxFetchDone);
void MaxSetTestFetcher(void (^fetcher)(NSString* url, MaxFetchDone done)) { g_testFetcher = [fetcher copy]; }

void MaxFetchPage(NSString* url, MaxFetchDone done) {
  MaxFetchDone finish = [done copy];
  if (g_testFetcher) {
    g_testFetcher(url, ^(NSString* html, NSString* error) {
      dispatch_async(dispatch_get_main_queue(), ^{ finish(html, error); });
    });
    return;
  }
  NSURL* u = [NSURL URLWithString:url ?: @""];
  if (!u || !MaxPreviewURLAllowed(url)) {
    dispatch_async(dispatch_get_main_queue(), ^{ finish(nil, @"unsupported address"); });
    return;
  }
  static NSURLSession* session;
  if (!session) {
    // Ephemeral and cookie-less: a preview never signs in, never stores anything and never sends the Space's cookies.
    NSURLSessionConfiguration* c = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    c.HTTPCookieAcceptPolicy = NSHTTPCookieAcceptPolicyNever;
    c.HTTPShouldSetCookies = NO;
    c.HTTPCookieStorage = nil;
    c.URLCache = nil;
    c.timeoutIntervalForRequest = 6;
    c.timeoutIntervalForResource = 10;
    session = [NSURLSession sessionWithConfiguration:c];
  }
  NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:u];
  [req setValue:@"text/html,application/xhtml+xml;q=0.9,*/*;q=0.5" forHTTPHeaderField:@"Accept"];
  [[session dataTaskWithRequest:req completionHandler:^(NSData* data, NSURLResponse* resp, NSError* error) {
    NSString* html = nil, *err = error.localizedDescription;
    NSString* mime = resp.MIMEType.lowercaseString ?: @"";
    if (!error && ![mime containsString:@"html"]) err = @"not a web page";
    else if (!error && data.length) {
      NSData* d = data.length > 2000000 ? [data subdataWithRange:NSMakeRange(0, 2000000)] : data;
      NSStringEncoding enc = NSUTF8StringEncoding;
      if (resp.textEncodingName) {
        CFStringEncoding cf = CFStringConvertIANACharSetNameToEncoding((__bridge CFStringRef)resp.textEncodingName);
        if (cf != kCFStringEncodingInvalidId) enc = CFStringConvertEncodingToNSStringEncoding(cf);
      }
      html = [[NSString alloc] initWithData:d encoding:enc] ?: [[NSString alloc] initWithData:d encoding:NSISOLatin1StringEncoding];
    }
    dispatch_async(dispatch_get_main_queue(), ^{ finish(html, html ? nil : (err ?: @"empty page")); });
  }] resume];
}

#pragma mark Settings section

@interface MaxSettingsTarget : NSObject
@property(nonatomic, strong) NSMutableArray<NSButton*>* featureBoxes;
@end
@implementation MaxSettingsTarget
- (void)toggled:(NSButton*)sender {
  SettingSetBool(sender.identifier, sender.state == NSControlStateValueOn);
  if ([sender.identifier isEqualToString:kSettingMaxEnabled])
    for (NSButton* b in self.featureBoxes) b.enabled = sender.state == NSControlStateValueOn;
}
@end

NSView* MaxSettingsSection(void) {
  static MaxSettingsTarget* target;
  if (!target) target = [MaxSettingsTarget new];
  target.featureBoxes = [NSMutableArray array];
  NSButton* (^box)(NSString*, NSString*) = ^NSButton*(NSString* title, NSString* key) {
    NSButton* b = [NSButton checkboxWithTitle:title target:target action:@selector(toggled:)];
    b.identifier = key;
    b.state = SettingBool(key) ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
  };
  NSTextField* heading = [NSTextField labelWithString:@"Max"];
  heading.font = [NSFont boldSystemFontOfSize:13];
  NSButton* master = box(@"Turn on Max", kSettingMaxEnabled);
  NSArray<NSButton*>* features = @[
    box(@"Ask on Page and page summaries (Cmd+Shift+A)", kSettingMaxAskOnPage),
    box(@"\"Ask ChatGPT\" in the command bar", kSettingMaxChatGPT),
    box(@"5-second previews: hold Shift while pointing at a link", kSettingMaxPreviews),
    box(@"Tidy Tabs: sort Today's tabs into folders", kSettingMaxTidyTabs),
    box(@"Tidy tab titles with Apple's model (else the built-in rules)", kSettingMaxTidyTitles),
  ];
  for (NSButton* b in features) {
    b.enabled = SettingBool(kSettingMaxEnabled);
    [target.featureBoxes addObject:b];
  }
  NSTextField* status = [NSTextField wrappingLabelWithString:
      [MaxModelStatusText(MaxModelAvailability()) stringByAppendingString:
          @" Nothing is sent to a NotArc server. ChatGPT opens chatgpt.com with your own sign-in."]];
  status.font = [NSFont systemFontOfSize:11];
  status.textColor = NSColor.secondaryLabelColor;
  status.identifier = @"maxStatus";
  NSMutableArray* views = [NSMutableArray arrayWithObjects:heading, master, nil];
  for (NSButton* b in features) {
    NSStackView* indent = [NSStackView stackViewWithViews:@[ b ]];
    indent.edgeInsets = NSEdgeInsetsMake(0, 18, 0, 0);
    [views addObject:indent];
  }
  [views addObject:status];
  NSStackView* stack = [NSStackView stackViewWithViews:views];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 6;
  stack.identifier = @"maxSection";
  [status.widthAnchor constraintEqualToConstant:420].active = YES;
  return stack;
}

#pragma mark Panel

@implementation MaxPanel {
  NSTextField* _title;
  NSTextField* _field;
  NSTextView* _answer;
  NSScrollView* _scroll;
  NSTextField* _note;
  NSButton* _chatgpt;
  NSButton* _copy;
  NSProgressIndicator* _spinner;
}

- (instancetype)init {
  self = [super initWithContentRect:NSMakeRect(0, 0, 380, 280)
                          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskUtilityWindow |
                                    NSWindowStyleMaskNonactivatingPanel
                            backing:NSBackingStoreBuffered
                              defer:YES];
  if (!self) return nil;
  self.releasedWhenClosed = NO;
  self.floatingPanel = YES;
  self.becomesKeyOnlyIfNeeded = YES;
  self.title = @"Max";
  NSView* v = self.contentView;
  _title = [NSTextField labelWithString:@""];
  _title.font = [NSFont boldSystemFontOfSize:13];
  _title.lineBreakMode = NSLineBreakByTruncatingTail;
  _field = [NSTextField textFieldWithString:@""];
  _field.placeholderString = @"Ask a question about this page";
  _field.target = self;
  _field.action = @selector(submit:);
  _scroll = [NSScrollView new];
  _scroll.hasVerticalScroller = YES;
  _scroll.drawsBackground = NO;
  _answer = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 340, 150)];
  _answer.editable = NO;
  _answer.drawsBackground = NO;
  _answer.font = [NSFont systemFontOfSize:13];
  _answer.textContainerInset = NSMakeSize(0, 4);
  _answer.autoresizingMask = NSViewWidthSizable;
  _scroll.documentView = _answer;
  _note = [NSTextField wrappingLabelWithString:@""];
  _note.font = [NSFont systemFontOfSize:11];
  _note.textColor = NSColor.secondaryLabelColor;
  _spinner = [NSProgressIndicator new];
  _spinner.style = NSProgressIndicatorStyleSpinning;
  _spinner.controlSize = NSControlSizeSmall;
  _spinner.displayedWhenStopped = NO;
  _chatgpt = [NSButton buttonWithTitle:@"Ask ChatGPT" target:self action:@selector(askChatGPT:)];
  _copy = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(copyAnswer:)];
  NSStackView* buttons = [NSStackView stackViewWithViews:@[ _spinner, [NSView new], _chatgpt, _copy ]];
  buttons.distribution = NSStackViewDistributionFill;
  NSStackView* stack = [NSStackView stackViewWithViews:@[ _title, _field, _scroll, _note, buttons ]];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = 8;
  stack.edgeInsets = NSEdgeInsetsMake(12, 14, 12, 14);
  stack.translatesAutoresizingMaskIntoConstraints = NO;
  [v addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [stack.leadingAnchor constraintEqualToAnchor:v.leadingAnchor], [stack.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
    [stack.topAnchor constraintEqualToAnchor:v.topAnchor], [stack.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
    [_field.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-28],
    [_scroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-28],
    [_scroll.heightAnchor constraintGreaterThanOrEqualToConstant:120],
    [_note.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-28],
    [buttons.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-28],
  ]];
  return self;
}

- (BOOL)canBecomeKeyWindow { return YES; }
- (void)cancelOperation:(id)sender { [self close]; }

- (void)placeOver:(NSWindow*)parent {
  if (self.parentWindow != parent) {
    [self.parentWindow removeChildWindow:self];
    [parent addChildWindow:self ordered:NSWindowAbove];
  }
  NSRect f = parent.frame;
  [self setFrameTopLeftPoint:NSMakePoint(NSMaxX(f) - self.frame.size.width - 24, NSMaxY(f) - 64)];
  if (parent.alphaValue < 0.05) {  // hidden self-test run: never visible, never clickable
    self.alphaValue = 0.01;
    self.ignoresMouseEvents = YES;
    [self orderFront:nil];
  } else {
    [self makeKeyAndOrderFront:nil];
  }
}

- (void)reset {
  _answer.string = @"";
  _note.stringValue = @"";
  _note.hidden = YES;
  _chatgpt.hidden = YES;
  _copy.hidden = YES;
  [_spinner stopAnimation:nil];
}

- (void)showAskOver:(NSWindow*)parent {
  [self reset];
  _title.stringValue = @"Ask on Page";
  _field.hidden = NO;
  _field.stringValue = @"";
  [self placeOver:parent];
  [self makeFirstResponder:_field];
}

- (void)showTitle:(NSString*)title over:(NSWindow*)parent {
  [self reset];
  _title.stringValue = title ?: @"";
  _field.hidden = YES;
  [self placeOver:parent];
}

- (void)setBusy:(NSString*)message {
  _answer.string = @"";
  _note.stringValue = message ?: @"";
  _note.hidden = !message.length;
  _chatgpt.hidden = YES;
  _copy.hidden = YES;
  [_spinner startAnimation:nil];
}

- (void)setAnswer:(NSString*)text note:(NSString*)note offerChatGPT:(BOOL)chatgpt {
  [_spinner stopAnimation:nil];
  _answer.string = text ?: @"";
  _note.stringValue = note ?: @"";
  _note.hidden = !note.length;
  _chatgpt.hidden = !chatgpt;
  _copy.hidden = !text.length;
}

- (NSString*)answerText { return _answer.string; }
- (NSString*)noteText { return _note.hidden ? @"" : _note.stringValue; }
- (BOOL)chatGPTOffered { return !_chatgpt.hidden; }
- (NSString*)question { return _field.hidden ? @"" : _field.stringValue; }

- (void)submit:(id)sender {
  NSString* q = [_field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (q.length && self.onAsk) self.onAsk(q);
}
- (void)askChatGPT:(id)sender {
  if (self.onChatGPT) self.onChatGPT(self.question);
}
- (void)copyAnswer:(id)sender {
  [NSPasteboard.generalPasteboard clearContents];
  [NSPasteboard.generalPasteboard setString:_answer.string forType:NSPasteboardTypeString];
}
@end
