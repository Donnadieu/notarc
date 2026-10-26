#import "app/boost_store.h"

@implementation Boost
- (instancetype)init {
  if ((self = [super init])) {
    _enabled = YES;
    _hue = -1;
    _colorStrength = 0.6;
    _textZoom = 1;
    _zaps = [NSMutableArray array];
  }
  return self;
}
- (BOOL)matchesURL:(NSString*)url {
  NSString* h = BoostHostForURL(url);
  return h && (_host.length && ([h isEqualToString:_host] || [h hasSuffix:[@"." stringByAppendingString:_host]]));
}
static NSString* CSSString(NSString* s) {
  return [[s stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"] stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}
- (NSString*)styleSheet {
  NSMutableString* css = [NSMutableString string];
  if (_hue >= 0) {
    // Arc tints the page with a hue blend over the content; same idea, as a fixed overlay that ignores clicks.
    [css appendFormat:@"html::after{content:\"\";position:fixed;inset:0;pointer-events:none;z-index:2147483646;"
                      @"background:hsl(%.0f,85%%,50%%);mix-blend-mode:hue;opacity:%.2f}\n",
                      fmod(_hue, 360), MAX(0.05, MIN(1, _colorStrength))];
  }
  if (_font.length) [css appendFormat:@"body,body *:not(code):not(pre):not(kbd):not(samp){font-family:\"%@\",system-ui !important}\n", CSSString(_font)];
  if (_textZoom > 0 && fabs(_textZoom - 1) > 0.01) [css appendFormat:@"html{zoom:%.2f}\n", _textZoom];
  if ([_textTransform isEqualToString:@"uppercase"] || [_textTransform isEqualToString:@"lowercase"])
    [css appendFormat:@"body{text-transform:%@ !important}\n", _textTransform];
  for (NSString* z in _zaps)
    if (z.length) [css appendFormat:@"%@{display:none !important}\n", z];
  if (_css.length) [css appendFormat:@"%@\n", _css];
  return css;
}
- (NSDictionary*)dict {
  NSMutableDictionary* d = [@{ @"host" : _host ?: @"", @"enabled" : @(_enabled), @"hue" : @(_hue),
                               @"colorStrength" : @(_colorStrength), @"textZoom" : @(_textZoom), @"zaps" : _zaps ?: @[] } mutableCopy];
  if (_font.length) d[@"font"] = _font;
  if (_textTransform.length) d[@"textTransform"] = _textTransform;
  if (_css.length) d[@"css"] = _css;
  if (_js.length) d[@"js"] = _js;
  return d;
}
+ (instancetype)fromDict:(NSDictionary*)d {
  if (![d isKindOfClass:NSDictionary.class] || ![d[@"host"] isKindOfClass:NSString.class]) return nil;
  Boost* b = [Boost new];
  b.host = d[@"host"];
  b.enabled = [d[@"enabled"] respondsToSelector:@selector(boolValue)] ? [d[@"enabled"] boolValue] : YES;
  if ([d[@"hue"] respondsToSelector:@selector(doubleValue)]) b.hue = [d[@"hue"] doubleValue];
  if ([d[@"colorStrength"] respondsToSelector:@selector(doubleValue)]) b.colorStrength = [d[@"colorStrength"] doubleValue];
  if ([d[@"textZoom"] respondsToSelector:@selector(doubleValue)]) b.textZoom = [d[@"textZoom"] doubleValue];
  if ([d[@"font"] isKindOfClass:NSString.class]) b.font = d[@"font"];
  if ([d[@"textTransform"] isKindOfClass:NSString.class]) b.textTransform = d[@"textTransform"];
  if ([d[@"css"] isKindOfClass:NSString.class]) b.css = d[@"css"];
  if ([d[@"js"] isKindOfClass:NSString.class]) b.js = d[@"js"];
  if ([d[@"zaps"] isKindOfClass:NSArray.class])
    for (id z in d[@"zaps"]) if ([z isKindOfClass:NSString.class]) [b.zaps addObject:z];
  return b;
}
@end

NSString* BoostStorePath(BOOL selfTest) {
  NSString* support = [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:@"NotArc"] copy];
  return [support stringByAppendingPathComponent:selfTest ? @"SelfTestBoosts.json" : @"Boosts.json"];
}

NSMutableArray<Boost*>* BoostStoreLoad(NSString* path) {
  NSMutableArray* out = [NSMutableArray array];
  NSData* data = [NSData dataWithContentsOfFile:path];
  id root = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if ([root isKindOfClass:NSDictionary.class]) root = root[@"boosts"];
  if ([root isKindOfClass:NSArray.class])
    for (id d in root) if (Boost* b = [Boost fromDict:d]) [out addObject:b];
  return out;
}

BOOL BoostStoreSave(NSArray<Boost*>* boosts, NSString* path) {
  NSMutableArray* arr = [NSMutableArray array];
  for (Boost* b in boosts) [arr addObject:[b dict]];
  NSData* data = [NSJSONSerialization dataWithJSONObject:@{ @"version" : @1, @"boosts" : arr }
                                                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                   error:nil];
  [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:nil error:nil];
  return [data writeToFile:path atomically:YES];
}

NSString* BoostHostForURL(NSString* url) {
  NSURL* u = [NSURL URLWithString:url ?: @""];
  if (![u.scheme isEqualToString:@"http"] && ![u.scheme isEqualToString:@"https"]) return nil;
  NSString* h = u.host.lowercaseString;
  if ([h hasPrefix:@"www."]) h = [h substringFromIndex:4];
  return h.length ? h : nil;
}

static NSString* JSString(NSString* s) {
  NSData* d = [NSJSONSerialization dataWithJSONObject:@[ s ?: @"" ] options:0 error:nil];
  NSString* arr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
  return [arr substringWithRange:NSMakeRange(1, arr.length - 2)];  // strip [ ]
}

NSString* BoostApplyScript(Boost* b) {
  BOOL on = b && b.enabled;
  NSString* css = on ? [b styleSheet] : @"";
  NSString* js = on && b.js.length ? b.js : @"";
  return [NSString stringWithFormat:
      @"(function(){var id='__notarc_boost__';var s=document.getElementById(id);var css=%@;"
       "if(!css){if(s)s.remove();document.documentElement.removeAttribute('data-notarc-boost');return;}"
       "if(!s){s=document.createElement('style');s.id=id;(document.head||document.documentElement).appendChild(s);}"
       "s.textContent=css;document.documentElement.setAttribute('data-notarc-boost','1');"
       "var js=%@;if(js&&window.__notarcBoostJS!==js){window.__notarcBoostJS=js;try{(0,eval)(js);}catch(e){console.error(e);}}})();",
      JSString(css), JSString(js)];
}

NSString* BoostZapModeScript(void) {
  return @"(function(){if(window.__notarcZap)return;window.__notarcZap=1;"
          "var box=document.createElement('div');box.style.cssText='position:fixed;pointer-events:none;z-index:2147483647;"
          "border:2px solid #E5484D;background:rgba(229,72,77,.18);border-radius:4px;transition:all .06s';"
          "document.documentElement.appendChild(box);var cur=null;"
          "function sel(e){if(e.id&&/^[A-Za-z][\\w-]*$/.test(e.id))return '#'+e.id;var p=[];"
          "while(e&&e.nodeType==1&&e!==document.documentElement){var t=e.tagName.toLowerCase();"
          "if(e.id&&/^[A-Za-z][\\w-]*$/.test(e.id)){p.unshift('#'+e.id);break;}"
          "var i=1,s=e;while((s=s.previousElementSibling))if(s.tagName===e.tagName)i++;"
          "p.unshift(t+':nth-of-type('+i+')');e=e.parentElement;}return p.join(' > ');}"
          "function mv(ev){cur=ev.target;var r=cur.getBoundingClientRect();"
          "box.style.left=r.left+'px';box.style.top=r.top+'px';box.style.width=r.width+'px';box.style.height=r.height+'px';}"
          "function end(){removeEventListener('mousemove',mv,true);removeEventListener('click',ck,true);"
          "removeEventListener('keydown',kd,true);box.remove();window.__notarcZap=0;}"
          "function ck(ev){ev.preventDefault();ev.stopPropagation();var s=cur?sel(cur):'';end();console.log('__notarc_zap__:'+s);}"
          "function kd(ev){if(ev.key==='Escape'){end();console.log('__notarc_zap__:');}}"
          "addEventListener('mousemove',mv,true);addEventListener('click',ck,true);addEventListener('keydown',kd,true);})();";
}
