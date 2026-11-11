#import "app/note_editor.h"

// Sizes and spacing. The first paragraph is the title; headings are bold and larger than body text.
static const CGFloat kTitleSize = 30, kH1Size = 24, kH2Size = 20, kH3Size = 17, kBodySize = 15;
static const CGFloat kReadingWidth = 680;  // Arc's notes are a centred column, not the full pane width
static const CGFloat kMinMargin = 28, kTopMargin = 72, kToolbarHeight = 34, kListIndent = 26;  // the format bar floats over the top

static NSString* const kBullet = @"\u2022\t", *const kUnchecked = @"\u2610\t", *const kChecked = @"\u2611\t";

static CGFloat SizeForBlock(NoteBlock b) {
  switch (b) {
    case NoteBlockHeading1: return kH1Size;
    case NoteBlockHeading2: return kH2Size;
    case NoteBlockHeading3: return kH3Size;
    default: return kBodySize;
  }
}
static NoteBlock BlockForSize(CGFloat s) {
  if (s >= 22.5) return NoteBlockHeading1;
  if (s >= 18.5) return NoteBlockHeading2;
  if (s >= 16.5) return NoteBlockHeading3;
  return NoteBlockText;
}
static NSFont* BodyFont() { return [NSFont systemFontOfSize:kBodySize]; }
static NSFont* TitleFont() { return [NSFont systemFontOfSize:kTitleSize weight:NSFontWeightBold]; }

static NSParagraphStyle* BodyStyle() {
  static NSParagraphStyle* s;
  if (!s) {
    NSMutableParagraphStyle* m = [NSMutableParagraphStyle new];
    m.lineHeightMultiple = 1.2;
    m.paragraphSpacing = 6;
    s = [m copy];
  }
  return s;
}
static NSParagraphStyle* TitleStyle() {
  static NSParagraphStyle* s;
  if (!s) {
    NSMutableParagraphStyle* m = [NSMutableParagraphStyle new];
    m.lineHeightMultiple = 1.05;
    m.paragraphSpacing = 14;
    s = [m copy];
  }
  return s;
}
static NSParagraphStyle* ListStyle() {
  static NSParagraphStyle* s;
  if (!s) {
    NSMutableParagraphStyle* m = [BodyStyle() mutableCopy];
    m.tabStops = @[ [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:kListIndent options:@{}] ];
    m.defaultTabInterval = kListIndent;
    m.headIndent = kListIndent;  // wrapped lines line up with the item's text, after the marker
    m.paragraphSpacing = 2;
    s = [m copy];
  }
  return s;
}
static NSParagraphStyle* StyleForBlock(NoteBlock b, NSParagraphStyle* current) {
  NSMutableParagraphStyle* m = [(current ?: BodyStyle()) mutableCopy];
  if (b == NoteBlockText) {
    m.paragraphSpacingBefore = 0;
    m.lineHeightMultiple = 1.2;
  } else {
    m.paragraphSpacingBefore = 10;
    m.lineHeightMultiple = 1.1;
  }
  return m;
}
static NSDictionary* BodyAttributes() {
  return @{NSFontAttributeName : BodyFont(), NSForegroundColorAttributeName : NSColor.textColor,
           NSParagraphStyleAttributeName : BodyStyle()};
}
static NSDictionary* TitleAttributes() {
  return @{NSFontAttributeName : TitleFont(), NSForegroundColorAttributeName : NSColor.textColor,
           NSParagraphStyleAttributeName : TitleStyle()};
}

// Lists are plain-text markers ("•", "1.", "☐"/"☑" then a tab) so they survive RTF, plain-text copies and every
// TextKit version the same way. Returns the marker's length (0 when the paragraph isn't a list item).
static NSUInteger ListPrefix(NSString* p, NoteList* kind, BOOL* checked) {
  if (kind) *kind = NoteListNone;
  if (checked) *checked = NO;
  if ([p hasPrefix:kBullet]) { if (kind) *kind = NoteListBullet; return kBullet.length; }
  if ([p hasPrefix:kUnchecked]) { if (kind) *kind = NoteListCheck; return kUnchecked.length; }
  if ([p hasPrefix:kChecked]) {
    if (kind) *kind = NoteListCheck;
    if (checked) *checked = YES;
    return kChecked.length;
  }
  NSUInteger i = 0;
  while (i < p.length && i < 4 && [NSCharacterSet.decimalDigitCharacterSet characterIsMember:[p characterAtIndex:i]]) ++i;
  if (i > 0 && i + 1 < p.length && [p characterAtIndex:i] == '.' && [p characterAtIndex:i + 1] == '\t') {
    if (kind) *kind = NoteListNumber;
    return i + 2;
  }
  return 0;
}

// Black/white text from older notes (or saved under the other appearance) follows the window's light/dark look, and
// the system font (which RTF reads back as Helvetica Neue) comes back as the system font.
static void NormalizeLoadedNote(NSMutableAttributedString* a) {
  if (!a.length) return;
  NSFontManager* fm = NSFontManager.sharedFontManager;
  [a enumerateAttribute:NSFontAttributeName inRange:NSMakeRange(0, a.length) options:0 usingBlock:^(NSFont* f, NSRange r, BOOL*) {
    if (![f.familyName isEqualToString:@"Helvetica Neue"]) return;
    NSFontTraitMask t = [fm traitsOfFont:f];
    NSFont* g = [NSFont systemFontOfSize:f.pointSize weight:(t & NSBoldFontMask) ? NSFontWeightBold : NSFontWeightRegular];
    if (t & NSItalicFontMask) g = [fm convertFont:g toHaveTrait:NSItalicFontMask];
    [a addAttribute:NSFontAttributeName value:g range:r];
  }];
  [a enumerateAttribute:NSForegroundColorAttributeName inRange:NSMakeRange(0, a.length) options:0
             usingBlock:^(NSColor* c, NSRange r, BOOL*) {
               NSColor* rgb = c ? [c colorUsingColorSpace:NSColorSpace.sRGBColorSpace] : nil;
               if (!c || !rgb || rgb.saturationComponent < 0.05)
                 [a addAttribute:NSForegroundColorAttributeName value:NSColor.textColor range:r];
             }];
}

NSAttributedString* NoteLoadRTF(NSString* path) {
  NSData* d = path ? [NSData dataWithContentsOfFile:path] : nil;
  NSAttributedString* a = d ? [[NSAttributedString alloc] initWithRTF:d documentAttributes:nil] : nil;
  return a ?: [[NSAttributedString alloc] initWithString:@""];
}

#pragma mark Markdown

static NSString* EscapeMarkdown(NSString* s) {
  NSMutableString* out = [NSMutableString stringWithCapacity:s.length];
  for (NSUInteger i = 0; i < s.length; ++i) {
    unichar c = [s characterAtIndex:i];
    if (c == 0xFFFC) continue;  // attachments (images) have no text
    if (c == 0x2028) { [out appendString:@"  \n"]; continue; }
    if (c == '\\' || c == '*' || c == '_' || c == '`' || c == '[' || c == ']' || c == '~' || c == '<') [out appendString:@"\\"];
    [out appendFormat:@"%C", c];
  }
  return out;
}

static NSString* InlineMarkdown(NSAttributedString* a, NSRange r, BOOL heading) {
  NSMutableArray<NSMutableDictionary*>* segs = [NSMutableArray array];
  NSFontManager* fm = NSFontManager.sharedFontManager;
  [a enumerateAttributesInRange:r options:0 usingBlock:^(NSDictionary* at, NSRange rr, BOOL*) {
    NSFont* f = at[NSFontAttributeName];
    NSFontTraitMask t = f ? [fm traitsOfFont:f] : 0;
    id link = at[NSLinkAttributeName];
    NSString* url = [link isKindOfClass:NSURL.class] ? [(NSURL*)link absoluteString] : ([link isKindOfClass:NSString.class] ? link : nil);
    BOOL b = !heading && (t & NSBoldFontMask), i = (t & NSItalicFontMask) != 0;
    BOOL s = [at[NSStrikethroughStyleAttributeName] integerValue] != 0;
    BOOL u = !url && [at[NSUnderlineStyleAttributeName] integerValue] != 0;
    NSString* key = [NSString stringWithFormat:@"%d%d%d%d|%@", b, i, s, u, url ?: @""];
    NSString* text = [a.string substringWithRange:rr];
    if ([segs.lastObject[@"key"] isEqualToString:key]) {
      [segs.lastObject[@"text"] appendString:text];
    } else {
      [segs addObject:[@{@"key" : key, @"text" : [text mutableCopy], @"b" : @(b), @"i" : @(i), @"s" : @(s), @"u" : @(u),
                         @"url" : url ?: @""} mutableCopy]];
    }
  }];
  NSMutableString* out = [NSMutableString string];
  for (NSDictionary* seg in segs) {
    NSString* text = seg[@"text"];
    NSString* url = seg[@"url"];
    NSMutableString* open = [NSMutableString string];
    if ([seg[@"b"] boolValue]) [open appendString:@"**"];
    if ([seg[@"i"] boolValue]) [open appendString:@"*"];
    if ([seg[@"s"] boolValue]) [open appendString:@"~~"];
    if ([seg[@"u"] boolValue]) [open appendString:@"<u>"];
    NSString* core = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if ((!open.length && !url.length) || !core.length) {
      [out appendString:EscapeMarkdown(text)];
      continue;
    }
    // Markers hug the words: "**bold** text", never "** bold**".
    NSRange cr = [text rangeOfString:core];
    NSMutableString* close = [NSMutableString string];
    if ([seg[@"u"] boolValue]) [close appendString:@"</u>"];
    if ([seg[@"s"] boolValue]) [close appendString:@"~~"];
    if ([seg[@"i"] boolValue]) [close appendString:@"*"];
    if ([seg[@"b"] boolValue]) [close appendString:@"**"];
    NSString* styled = [NSString stringWithFormat:@"%@%@%@", open, EscapeMarkdown(core), close];
    if (url.length) {
      NSString* u = [[url stringByReplacingOccurrencesOfString:@" " withString:@"%20"] stringByReplacingOccurrencesOfString:@")" withString:@"%29"];
      styled = [NSString stringWithFormat:@"[%@](%@)", styled, u];
    }
    [out appendString:[text substringToIndex:cr.location]];
    [out appendString:styled];
    [out appendString:[text substringFromIndex:NSMaxRange(cr)]];
  }
  return out;
}

NSString* NoteMarkdown(NSAttributedString* a) {
  NSString* s = a.string;
  NSMutableArray<NSString*>* lines = [NSMutableArray array];
  NSMutableArray<NSNumber*>* isList = [NSMutableArray array];
  __block NSUInteger index = 0;
  __block NSInteger number = 0;  // numbered items count up within a run of numbered paragraphs
  [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByParagraphs
                     usingBlock:^(NSString* para, NSRange sub, NSRange, BOOL*) {
    NSUInteger i = index++;
    NSString* prefix = @"";
    NSRange content = sub;
    BOOL heading = NO, list = NO, numbered = NO;
    if (i == 0) {
      prefix = @"# ";
      heading = YES;
    } else {
      NoteList kind;
      BOOL checked;
      NSUInteger len = ListPrefix(para, &kind, &checked);
      NSParagraphStyle* ps = sub.length ? [a attribute:NSParagraphStyleAttributeName atIndex:sub.location effectiveRange:nil] : nil;
      if (len) {
        content = NSMakeRange(sub.location + len, sub.length - len);
        list = YES;
        numbered = kind == NoteListNumber;
        prefix = kind == NoteListBullet ? @"- " : kind == NoteListCheck ? (checked ? @"- [x] " : @"- [ ] ") : nil;
      } else if (ps.textLists.count) {  // a list made with AppKit's own list tools
        NSTextList* tl = ps.textLists.lastObject;
        if ([para hasPrefix:@"\t"]) {
          NSRange tab = [para rangeOfString:@"\t" options:0 range:NSMakeRange(1, para.length - 1)];
          if (tab.location != NSNotFound) content = NSMakeRange(sub.location + tab.location + 1, sub.length - tab.location - 1);
        }
        list = YES;
        numbered = [tl.markerFormat rangeOfString:@"decimal"].location != NSNotFound;
        if (!numbered) prefix = @"- ";
      } else if (sub.length) {
        NSFont* f = [a attribute:NSFontAttributeName atIndex:sub.location effectiveRange:nil];
        NoteBlock b = BlockForSize(f.pointSize ?: kBodySize);
        if (b != NoteBlockText) {
          heading = YES;
          prefix = b == NoteBlockHeading1 ? @"## " : b == NoteBlockHeading2 ? @"### " : @"#### ";
        }
      }
    }
    number = numbered ? number + 1 : 0;
    if (numbered) prefix = [NSString stringWithFormat:@"%ld. ", (long)number];
    NSString* body = content.length ? InlineMarkdown(a, content, heading) : @"";
    if (!body.length && !list) return;  // empty lines only separate blocks, which Markdown does with a blank line
    if (!prefix.length) {  // plain text that would read as Markdown syntax at the start of a line
      NSString* first = body.length ? [body substringToIndex:1] : @"";
      if ([@[ @"#", @">", @"-", @"+" ] containsObject:first]) body = [@"\\" stringByAppendingString:body];
      NSRange num = [body rangeOfString:@"^[0-9]+\\." options:NSRegularExpressionSearch];
      if (num.location == 0) body = [body stringByReplacingCharactersInRange:NSMakeRange(NSMaxRange(num) - 1, 1) withString:@"\\."];
    }
    [lines addObject:[prefix stringByAppendingString:body]];
    [isList addObject:@(list)];
  }];
  NSMutableString* out = [NSMutableString string];
  for (NSUInteger i = 0; i < lines.count; ++i) {
    if (i) [out appendString:isList[i].boolValue && isList[i - 1].boolValue ? @"\n" : @"\n\n"];
    [out appendString:lines[i]];
  }
  if (out.length) [out appendString:@"\n"];
  return out;
}

#pragma mark Text view

@interface NoteEditorView ()
- (void)textViewFocused;
@end

@interface NoteTextView ()
@property(nonatomic, weak) NoteEditorView* owner;
@end

@implementation NoteTextView

- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) [self.owner textViewFocused];
  return ok;
}

- (NSRange)titleRange { return [self.string paragraphRangeForRange:NSMakeRange(0, 0)]; }

// Paragraphs (with their line ends) touched by the selection, not counting the title.
- (NSArray<NSValue*>*)selectedBodyParagraphs {
  NSString* s = self.string;
  NSRange title = [self titleRange];
  NSRange paras = [s paragraphRangeForRange:self.selectedRange];
  NSMutableArray* out = [NSMutableArray array];
  if (paras.length == 0) {  // the empty last line
    if (paras.location > 0 && paras.location >= NSMaxRange(title)) [out addObject:[NSValue valueWithRange:paras]];
    return out;
  }
  for (NSUInteger i = paras.location; i < NSMaxRange(paras);) {
    NSRange p = [s paragraphRangeForRange:NSMakeRange(i, 0)];
    if (p.location >= NSMaxRange(title) && p.location > 0) [out addObject:[NSValue valueWithRange:p]];
    i = NSMaxRange(p);
  }
  return out;
}

- (void)replaceRange:(NSRange)r with:(NSAttributedString*)a {
  if (![self shouldChangeTextInRange:r replacementString:a.string]) return;
  [self.textStorage replaceCharactersInRange:r withAttributedString:a];
  [self didChangeText];
  NSUInteger end = r.location + a.length;
  if (end > r.location && [a.string hasSuffix:@"\n"]) --end;
  self.selectedRange = NSMakeRange(end, 0);
  if (end > 0) {
    NSMutableDictionary* t = [[self.textStorage attributesAtIndex:end - 1 effectiveRange:nil] mutableCopy];
    [t removeObjectForKey:NSLinkAttributeName];
    self.typingAttributes = t;
  }
}

- (NSDictionary*)markerAttributes:(NSParagraphStyle*)style {
  return @{NSFontAttributeName : BodyFont(), NSForegroundColorAttributeName : NSColor.textColor,
           NSParagraphStyleAttributeName : style};
}

- (void)applyList:(NoteList)kind {
  NSArray<NSValue*>* paras = [self selectedBodyParagraphs];
  if (!paras.count) { NSBeep(); return; }
  NSString* s = self.string;
  BOOL all = YES;
  for (NSValue* v in paras) {
    NoteList k;
    ListPrefix([s substringWithRange:v.rangeValue], &k, NULL);
    if (k != kind) all = NO;
  }
  NSRange whole = NSUnionRange(paras.firstObject.rangeValue, paras.lastObject.rangeValue);
  NSMutableAttributedString* out = [NSMutableAttributedString new];
  NSInteger n = 1;
  for (NSValue* v in paras) {
    NSMutableAttributedString* p = [[self.textStorage attributedSubstringFromRange:v.rangeValue] mutableCopy];
    NSUInteger len = ListPrefix(p.string, NULL, NULL);
    if (len) [p deleteCharactersInRange:NSMakeRange(0, len)];
    NSParagraphStyle* style = all || kind == NoteListNone ? BodyStyle() : ListStyle();
    if (!all && kind != NoteListNone) {
      NSString* marker = kind == NoteListBullet ? kBullet : kind == NoteListCheck ? kUnchecked
                                                          : [NSString stringWithFormat:@"%ld.\t", (long)n++];
      [p insertAttributedString:[[NSAttributedString alloc] initWithString:marker attributes:[self markerAttributes:style]] atIndex:0];
    }
    if (p.length) [p addAttribute:NSParagraphStyleAttributeName value:style range:NSMakeRange(0, p.length)];
    [out appendAttributedString:p];
  }
  [self replaceRange:whole with:out];
}

- (void)applyBlock:(NoteBlock)block {
  NSArray<NSValue*>* paras = [self selectedBodyParagraphs];
  if (!paras.count) { NSBeep(); return; }  // the title keeps its own style
  NSTextStorage* ts = self.textStorage;
  NSFontManager* fm = NSFontManager.sharedFontManager;
  NSRange whole = NSUnionRange(paras.firstObject.rangeValue, paras.lastObject.rangeValue);
  CGFloat size = SizeForBlock(block);
  if (whole.length && [self shouldChangeTextInRange:whole replacementString:nil]) {
    [ts beginEditing];
    for (NSValue* v in paras) {
      NSRange pr = v.rangeValue;
      if (!pr.length) continue;
      [ts enumerateAttribute:NSFontAttributeName inRange:pr options:0 usingBlock:^(NSFont* f, NSRange r, BOOL*) {
        NSFont* g = [fm convertFont:f ?: BodyFont() toSize:size];
        if (block != NoteBlockText) g = [fm convertFont:g toHaveTrait:NSBoldFontMask];
        else if (BlockForSize(f.pointSize) != NoteBlockText) g = [fm convertFont:g toNotHaveTrait:NSBoldFontMask];
        [ts addAttribute:NSFontAttributeName value:g range:r];
      }];
      NSParagraphStyle* cur = [ts attribute:NSParagraphStyleAttributeName atIndex:pr.location effectiveRange:nil];
      [ts addAttribute:NSParagraphStyleAttributeName value:StyleForBlock(block, cur) range:pr];
    }
    [ts endEditing];
    [self didChangeText];
  }
  NSMutableDictionary* t = [self.typingAttributes mutableCopy];
  NSFont* f = [fm convertFont:t[NSFontAttributeName] ?: BodyFont() toSize:size];
  t[NSFontAttributeName] = block != NoteBlockText ? [fm convertFont:f toHaveTrait:NSBoldFontMask] : [fm convertFont:f toNotHaveTrait:NSBoldFontMask];
  t[NSParagraphStyleAttributeName] = StyleForBlock(block, t[NSParagraphStyleAttributeName]);
  self.typingAttributes = t;
}

- (void)toggleTrait:(NSFontTraitMask)trait {
  NSFontManager* fm = NSFontManager.sharedFontManager;
  NSRange r = self.selectedRange;
  NSTextStorage* ts = self.textStorage;
  if (!r.length) {
    NSMutableDictionary* t = [self.typingAttributes mutableCopy];
    NSFont* f = t[NSFontAttributeName] ?: BodyFont();
    t[NSFontAttributeName] = ([fm traitsOfFont:f] & trait) ? [fm convertFont:f toNotHaveTrait:trait] : [fm convertFont:f toHaveTrait:trait];
    self.typingAttributes = t;
    return;
  }
  __block BOOL all = YES;
  [ts enumerateAttribute:NSFontAttributeName inRange:r options:0 usingBlock:^(NSFont* f, NSRange, BOOL*) {
    if (!f || !([fm traitsOfFont:f] & trait)) all = NO;
  }];
  if (![self shouldChangeTextInRange:r replacementString:nil]) return;
  [ts beginEditing];
  [ts enumerateAttribute:NSFontAttributeName inRange:r options:0 usingBlock:^(NSFont* f, NSRange rr, BOOL*) {
    NSFont* g = all ? [fm convertFont:f ?: BodyFont() toNotHaveTrait:trait] : [fm convertFont:f ?: BodyFont() toHaveTrait:trait];
    [ts addAttribute:NSFontAttributeName value:g range:rr];
  }];
  [ts endEditing];
  [self didChangeText];
}

- (void)toggleStyleAttribute:(NSAttributedStringKey)key {
  NSRange r = self.selectedRange;
  NSTextStorage* ts = self.textStorage;
  if (!r.length) {
    NSMutableDictionary* t = [self.typingAttributes mutableCopy];
    if ([t[key] integerValue]) [t removeObjectForKey:key];
    else t[key] = @(NSUnderlineStyleSingle);
    self.typingAttributes = t;
    return;
  }
  __block BOOL all = YES;
  [ts enumerateAttribute:key inRange:r options:0 usingBlock:^(id v, NSRange, BOOL*) { if (![v integerValue]) all = NO; }];
  if (![self shouldChangeTextInRange:r replacementString:nil]) return;
  [ts beginEditing];
  if (all) [ts removeAttribute:key range:r];
  else [ts addAttribute:key value:@(NSUnderlineStyleSingle) range:r];
  [ts endEditing];
  [self didChangeText];
}

- (void)setLinkOnSelection:(NSString*)url {
  NSString* u = [url stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (u.length && [u rangeOfString:@":"].location == NSNotFound) u = [@"https://" stringByAppendingString:u];
  NSURL* link = u.length ? [NSURL URLWithString:u] : nil;
  NSRange r = self.selectedRange;
  NSTextStorage* ts = self.textStorage;
  if (!r.length) {  // nothing selected: the address itself becomes the link text
    if (!link) return;
    NSMutableDictionary* at = [self.typingAttributes mutableCopy];
    at[NSLinkAttributeName] = link;
    NSAttributedString* a = [[NSAttributedString alloc] initWithString:u attributes:at];
    if (![self shouldChangeTextInRange:r replacementString:u]) return;
    [ts replaceCharactersInRange:r withAttributedString:a];
    [self didChangeText];
    self.selectedRange = NSMakeRange(r.location + a.length, 0);
    return;
  }
  if (![self shouldChangeTextInRange:r replacementString:nil]) return;
  if (link) [ts addAttribute:NSLinkAttributeName value:link range:r];
  else [ts removeAttribute:NSLinkAttributeName range:r];
  [self didChangeText];
}

- (BOOL)toggleCheckboxInParagraphAt:(NSUInteger)index {
  NSString* s = self.string;
  if (index > s.length) return NO;
  NSRange para = [s paragraphRangeForRange:NSMakeRange(index, 0)];
  NoteList kind;
  BOOL checked;
  if (!ListPrefix([s substringWithRange:para], &kind, &checked) || kind != NoteListCheck) return NO;
  NSRange box = NSMakeRange(para.location, 1);
  NSString* now = checked ? @"\u2610" : @"\u2611";
  if (![self shouldChangeTextInRange:box replacementString:now]) return NO;
  [self.textStorage replaceCharactersInRange:box withString:now];
  [self didChangeText];
  return YES;
}

// Clicking a checklist box ticks it.
- (void)mouseDown:(NSEvent*)e {
  NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
  NSUInteger i = [self characterIndexForInsertionAtPoint:p];
  NSString* s = self.string;
  if (i < s.length) {
    NSRange para = [s paragraphRangeForRange:NSMakeRange(i, 0)];
    NoteList kind;
    if (ListPrefix([s substringWithRange:para], &kind, NULL) && kind == NoteListCheck && i - para.location <= 1 &&
        [self toggleCheckboxInParagraphAt:para.location])
      return;
  }
  [super mouseDown:e];
}

// Return in a list item starts the next item; Return on an empty item ends the list.
- (void)insertNewline:(id)sender {
  NSString* s = self.string;
  NSRange sel = self.selectedRange;
  NSRange para = [s paragraphRangeForRange:NSMakeRange(sel.location, 0)];
  NSString* line = [[s substringWithRange:para] stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet];
  NoteList kind;
  NSUInteger len = para.location > 0 && para.location >= NSMaxRange([self titleRange]) ? ListPrefix(line, &kind, NULL) : 0;
  if (len && !sel.length && sel.location >= para.location + len) {
    if (line.length == len) {
      NSString* rest = [[s substringWithRange:para] substringFromIndex:len];  // the line end, if any
      [self replaceRange:para with:[[NSAttributedString alloc] initWithString:rest attributes:BodyAttributes()]];
      self.selectedRange = NSMakeRange(para.location, 0);
      self.typingAttributes = BodyAttributes();
      return;
    }
    NSString* marker = kind == NoteListBullet ? kBullet : kind == NoteListCheck ? kUnchecked
                                                      : [NSString stringWithFormat:@"%ld.\t", (long)line.integerValue + 1];
    NSMutableDictionary* at = [[self markerAttributes:ListStyle()] mutableCopy];
    NSAttributedString* a = [[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:marker] attributes:at];
    if (![self shouldChangeTextInRange:sel replacementString:a.string]) return;
    [self.textStorage replaceCharactersInRange:sel withAttributedString:a];
    [self didChangeText];
    self.selectedRange = NSMakeRange(sel.location + a.length, 0);
    self.typingAttributes = at;
    return;
  }
  [super insertNewline:sender];
  // A new line after a heading is body text again.
  NSFont* f = self.typingAttributes[NSFontAttributeName];
  if (f && BlockForSize(f.pointSize) != NoteBlockText && self.selectedRange.location > NSMaxRange([self titleRange]) - 1)
    self.typingAttributes = BodyAttributes();
}

// Backspace right after a list marker removes the marker (the line becomes plain text).
- (void)deleteBackward:(id)sender {
  NSRange sel = self.selectedRange;
  NSString* s = self.string;
  if (!sel.length && sel.location > 0 && sel.location <= s.length) {
    NSRange para = [s paragraphRangeForRange:NSMakeRange(sel.location, 0)];
    NSUInteger len = para.location >= NSMaxRange([self titleRange]) ? ListPrefix([s substringWithRange:para], NULL, NULL) : 0;
    if (len && sel.location == para.location + len) {
      NSMutableAttributedString* rest = [[self.textStorage attributedSubstringFromRange:NSMakeRange(para.location + len, para.length - len)] mutableCopy];
      if (rest.length) [rest addAttribute:NSParagraphStyleAttributeName value:BodyStyle() range:NSMakeRange(0, rest.length)];
      [self replaceRange:para with:rest];
      self.selectedRange = NSMakeRange(para.location, 0);
      return;
    }
  }
  [super deleteBackward:sender];
}

- (IBAction)noteFormatBlock:(id)sender {
  NSInteger tag = [sender isKindOfClass:NSPopUpButton.class] ? [(NSPopUpButton*)sender selectedItem].tag : [sender tag];
  [self applyBlock:(NoteBlock)tag];
}
- (IBAction)noteToggleBold:(id)sender { [self toggleTrait:NSBoldFontMask]; }
- (IBAction)noteToggleItalic:(id)sender { [self toggleTrait:NSItalicFontMask]; }
- (IBAction)noteToggleUnderline:(id)sender { [self toggleStyleAttribute:NSUnderlineStyleAttributeName]; }
- (IBAction)noteToggleStrikethrough:(id)sender { [self toggleStyleAttribute:NSStrikethroughStyleAttributeName]; }
- (IBAction)noteToggleBulletList:(id)sender { [self applyList:NoteListBullet]; }
- (IBAction)noteToggleNumberedList:(id)sender { [self applyList:NoteListNumber]; }
- (IBAction)noteToggleChecklist:(id)sender { [self applyList:NoteListCheck]; }
- (IBAction)noteAddLink:(id)sender {
  NSRange r = self.selectedRange;
  id cur = r.length ? [self.textStorage attribute:NSLinkAttributeName atIndex:r.location effectiveRange:nil] : nil;
  NSAlert* alert = [NSAlert new];
  alert.messageText = r.length ? @"Link the selected text to:" : @"Insert a link to:";
  [alert addButtonWithTitle:@"OK"];
  [alert addButtonWithTitle:@"Cancel"];
  if (cur) [alert addButtonWithTitle:@"Remove Link"];
  NSTextField* field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 300, 24)];
  field.placeholderString = @"https://";
  field.stringValue = [cur isKindOfClass:NSURL.class] ? [(NSURL*)cur absoluteString] : ([cur isKindOfClass:NSString.class] ? cur : @"");
  alert.accessoryView = field;
  alert.window.initialFirstResponder = field;
  __weak NoteTextView* weakSelf = self;
  [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse code) {
    NoteTextView* me = weakSelf;
    if (!me) return;
    me.selectedRange = r;
    if (code == NSAlertFirstButtonReturn && field.stringValue.length) [me setLinkOnSelection:field.stringValue];
    else if (code == NSAlertThirdButtonReturn) [me setLinkOnSelection:nil];
  }];
}

- (BOOL)validateUserInterfaceItem:(id<NSValidatedUserInterfaceItem>)item {
  SEL a = item.action;
  if (a == @selector(noteFormatBlock:) || a == @selector(noteToggleBulletList:) || a == @selector(noteToggleNumberedList:) ||
      a == @selector(noteToggleChecklist:))
    return self.isEditable && [self selectedBodyParagraphs].count > 0;
  if (a == @selector(noteToggleBold:) || a == @selector(noteToggleItalic:) || a == @selector(noteToggleUnderline:) ||
      a == @selector(noteToggleStrikethrough:) || a == @selector(noteAddLink:))
    return self.isEditable;
  return [super validateUserInterfaceItem:item];
}
@end

#pragma mark Editor

@interface NoteEditorView () <NSTextViewDelegate, NSTextStorageDelegate>
@end

@implementation NoteEditorView {
  NSView* _toolbar;
  NSStackView* _stack;
  NSPopUpButton* _blockPopup;
  NSBox* _rule;
  NSScrollView* _scroll;
  NoteTextView* _textView;
  NSTimer* _saveTimer;
  BOOL _styling;
  NSMutableArray<NSControl*>* _controls;
  NSTextField* _placeholder;
}

- (instancetype)initWithFrame:(NSRect)frame {
  if (!(self = [super initWithFrame:frame])) return nil;
  _scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  _scroll.hasVerticalScroller = YES;
  _scroll.autohidesScrollers = YES;
  _scroll.scrollerStyle = NSScrollerStyleOverlay;
  _scroll.drawsBackground = NO;
  _textView = [[NoteTextView alloc] initWithFrame:NSMakeRect(0, 0, 400, 400)];
  _textView.owner = self;
  _textView.autoresizingMask = NSViewWidthSizable;
  _textView.verticallyResizable = YES;
  _textView.horizontallyResizable = NO;
  _textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
  _textView.textContainer.widthTracksTextView = YES;
  _textView.drawsBackground = NO;
  _textView.richText = YES;
  _textView.allowsUndo = YES;
  _textView.usesFontPanel = YES;
  _textView.usesRuler = NO;
  _textView.importsGraphics = YES;
  _textView.automaticLinkDetectionEnabled = YES;
  _textView.defaultParagraphStyle = BodyStyle();
  _textView.typingAttributes = TitleAttributes();
  _textView.delegate = self;
  _textView.textStorage.delegate = self;
  _scroll.documentView = _textView;
  [self addSubview:_scroll];
  // Arc's empty note: a large grey "Untitled" where the title goes.
  _placeholder = [NSTextField labelWithString:@"Untitled"];
  _placeholder.font = TitleFont();
  _placeholder.textColor = NSColor.tertiaryLabelColor;
  _placeholder.identifier = @"notePlaceholder";
  [_textView addSubview:_placeholder];
  [self buildToolbar];
  [self layoutParts];
  return self;
}

- (NSButton*)button:(NSString*)symbol tip:(NSString*)tip action:(SEL)action {
  NSImage* img = [NSImage imageWithSystemSymbolName:symbol accessibilityDescription:tip];
  NSButton* b = img ? [NSButton buttonWithImage:img target:_textView action:action]
                    : [NSButton buttonWithTitle:tip target:_textView action:action];
  b.bordered = NO;
  b.toolTip = tip;
  b.contentTintColor = NSColor.secondaryLabelColor;
  [b.widthAnchor constraintEqualToConstant:26].active = YES;
  [_controls addObject:b];
  return b;
}
- (NSView*)separator {
  NSBox* box = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 1, 16)];
  box.boxType = NSBoxSeparator;
  [box.widthAnchor constraintEqualToConstant:1].active = YES;
  [box.heightAnchor constraintEqualToConstant:16].active = YES;
  return box;
}

// Arc's note format bar: paragraph type, then bold/italic/underline/strikethrough, lists, link.
- (void)buildToolbar {
  _controls = [NSMutableArray array];
  // Arc's format bar floats over the top of the note as a small rounded bar, not a full-width strip.
  NSVisualEffectView* bar = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
  bar.material = NSVisualEffectMaterialPopover;
  bar.state = NSVisualEffectStateActive;
  bar.wantsLayer = YES;
  bar.layer.cornerRadius = 10;
  bar.layer.borderWidth = 0.5;
  bar.layer.borderColor = [NSColor colorWithWhite:0.5 alpha:0.25].CGColor;
  bar.shadow = [NSShadow new];
  _toolbar = bar;
  _blockPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 110, 24) pullsDown:NO];
  _blockPopup.bordered = NO;
  _blockPopup.font = [NSFont systemFontOfSize:12];
  _blockPopup.controlSize = NSControlSizeSmall;
  for (NSArray* e in @[ @[ @"Body", @(NoteBlockText) ], @[ @"Heading 1", @(NoteBlockHeading1) ],
                        @[ @"Heading 2", @(NoteBlockHeading2) ], @[ @"Heading 3", @(NoteBlockHeading3) ] ]) {
    [_blockPopup addItemWithTitle:e[0]];
    _blockPopup.lastItem.tag = [e[1] integerValue];
  }
  _blockPopup.target = _textView;
  _blockPopup.action = @selector(noteFormatBlock:);
  _blockPopup.toolTip = @"Paragraph style";
  [_controls addObject:_blockPopup];
  NSArray* views = @[
    _blockPopup, [self separator],
    [self button:@"bold" tip:@"Bold" action:@selector(noteToggleBold:)],
    [self button:@"italic" tip:@"Italic" action:@selector(noteToggleItalic:)],
    [self button:@"underline" tip:@"Underline" action:@selector(noteToggleUnderline:)],
    [self button:@"strikethrough" tip:@"Strikethrough" action:@selector(noteToggleStrikethrough:)], [self separator],
    [self button:@"list.bullet" tip:@"Bulleted List" action:@selector(noteToggleBulletList:)],
    [self button:@"list.number" tip:@"Numbered List" action:@selector(noteToggleNumberedList:)],
    [self button:@"checklist" tip:@"Checklist" action:@selector(noteToggleChecklist:)], [self separator],
    [self button:@"link" tip:@"Add Link" action:@selector(noteAddLink:)],
  ];
  _stack = [NSStackView stackViewWithViews:views];
  _stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  _stack.spacing = 6;
  _stack.alignment = NSLayoutAttributeCenterY;
  _stack.translatesAutoresizingMaskIntoConstraints = YES;
  [_toolbar addSubview:_stack];
  _rule = [[NSBox alloc] initWithFrame:NSZeroRect];
  _rule.boxType = NSBoxSeparator;
  [_toolbar addSubview:_rule];
  [self addSubview:_toolbar];
}

- (void)resizeSubviewsWithOldSize:(NSSize)old { [self layoutParts]; }
- (void)setFrameSize:(NSSize)size {
  [super setFrameSize:size];
  [self layoutParts];
}

- (void)layoutParts {
  NSRect b = self.bounds;
  NSSize fit = _stack.fittingSize;
  CGFloat w = MIN(fit.width, b.size.width - 40);
  _toolbar.frame = NSMakeRect(floor((b.size.width - w - 20) / 2), NSMaxY(b) - kToolbarHeight - 12, w + 20, kToolbarHeight);
  _rule.hidden = YES;
  _stack.frame = NSMakeRect(10, floor((kToolbarHeight - fit.height) / 2), w, fit.height);
  _scroll.frame = b;
  CGFloat width = _scroll.contentSize.width;
  CGFloat margin = MAX(kMinMargin, floor((width - kReadingWidth) / 2));
  if (_textView.textContainerInset.width != margin) _textView.textContainerInset = NSMakeSize(margin, kTopMargin);
  _textView.frame = NSMakeRect(0, 0, width, MAX(_textView.frame.size.height, _scroll.contentSize.height));
  [self updatePlaceholder];
}
- (void)updatePlaceholder {
  _placeholder.hidden = _textView.string.length > 0;
  NSSize s = _placeholder.fittingSize;
  NSSize inset = _textView.textContainerInset;
  CGFloat pad = _textView.textContainer.lineFragmentPadding;
  _placeholder.frame = NSMakeRect(inset.width + pad, _textView.isFlipped ? inset.height : NSMaxY(_textView.bounds) - inset.height - s.height,
                                  s.width, s.height);
}
- (NSString*)floatingBarDescription {  // tests (V44)
  NSRect b = self.bounds, t = _toolbar.frame;
  return [NSString stringWithFormat:@"floating=%d centred=%d radius=%.0f placeholder=%d", NSMaxY(t) == NSMaxY(b) - 12 && t.size.width < b.size.width,
                                    fabs(NSMidX(t) - NSMidX(b)) <= 1, _toolbar.layer.cornerRadius, !_placeholder.hidden];
}

// The page colour comes from the window's appearance, which follows the Space (light, dark or system).
- (void)drawRect:(NSRect)dirty {
  [NSColor.textBackgroundColor setFill];
  NSRectFill(dirty);
}
- (BOOL)isOpaque { return YES; }

- (NoteTextView*)textView { return _textView; }
- (NSView*)toolbar { return _toolbar; }

- (void)load {
  NSMutableAttributedString* a = [NoteLoadRTF(self.path) mutableCopy];
  NormalizeLoadedNote(a);
  [_textView.textStorage setAttributedString:a];
  _textView.typingAttributes = a.length ? BodyAttributes() : TitleAttributes();
  [_textView.undoManager removeAllActions];
  [self updatePlaceholder];
  [self updateToolbarState];
}

- (void)save {
  [_saveTimer invalidate];
  _saveTimer = nil;
  if (!self.path) return;
  NSAttributedString* a = _textView.textStorage;
  NSData* rtf = [a RTFFromRange:NSMakeRange(0, a.length) documentAttributes:@{NSDocumentTypeDocumentAttribute : NSRTFTextDocumentType}];
  [[NSFileManager defaultManager] createDirectoryAtPath:self.path.stringByDeletingLastPathComponent withIntermediateDirectories:YES
                                             attributes:nil error:nil];
  [rtf writeToFile:self.path atomically:YES];
}

- (NSString*)title {
  NSString* first = [[_textView.string componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet] firstObject];
  first = [first stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  return first.length ? (first.length > 80 ? [first substringToIndex:80] : first) : nil;
}

- (NSString*)markdown { return NoteMarkdown(_textView.textStorage); }

- (void)textViewFocused { [self.delegate noteEditorDidFocus:self]; }

// The first paragraph is always the large title; anything typed after it at title size is body text.
- (void)textStorage:(NSTextStorage*)ts willProcessEditing:(NSTextStorageEditActions)actions range:(NSRange)edited
     changeInLength:(NSInteger)delta {
  if (!(actions & NSTextStorageEditedCharacters) || _styling) return;
  _styling = YES;
  NSFontManager* fm = NSFontManager.sharedFontManager;
  NSString* s = ts.string;
  NSRange title = [s paragraphRangeForRange:NSMakeRange(0, 0)];
  if (title.length) {
    [ts enumerateAttribute:NSFontAttributeName inRange:title options:0 usingBlock:^(NSFont* f, NSRange r, BOOL*) {
      if (f.pointSize == kTitleSize && ([fm traitsOfFont:f] & NSBoldFontMask)) return;
      NSFont* t = TitleFont();
      if (f && ([fm traitsOfFont:f] & NSItalicFontMask)) t = [fm convertFont:t toHaveTrait:NSItalicFontMask];
      [ts addAttribute:NSFontAttributeName value:t range:r];
    }];
    [ts addAttribute:NSParagraphStyleAttributeName value:TitleStyle() range:title];
  }
  NSRange body = NSMakeRange(NSMaxRange(title), s.length - NSMaxRange(title));
  NSRange rest = NSIntersectionRange([s paragraphRangeForRange:NSIntersectionRange(edited, NSMakeRange(0, s.length))], body);
  if (rest.length) {
    [ts enumerateAttribute:NSFontAttributeName inRange:rest options:0 usingBlock:^(NSFont* f, NSRange r, BOOL*) {
      if (f && f.pointSize < kTitleSize - 0.5) return;
      NSFont* b = BodyFont();
      if (f && ([fm traitsOfFont:f] & NSItalicFontMask)) b = [fm convertFont:b toHaveTrait:NSItalicFontMask];
      [ts addAttribute:NSFontAttributeName value:b range:r];
    }];
    [ts enumerateAttribute:NSParagraphStyleAttributeName inRange:rest options:0 usingBlock:^(NSParagraphStyle* p, NSRange r, BOOL*) {
      if (!p || [p isEqual:TitleStyle()]) [ts addAttribute:NSParagraphStyleAttributeName value:BodyStyle() range:r];
    }];
    [ts enumerateAttribute:NSForegroundColorAttributeName inRange:rest options:0 usingBlock:^(id c, NSRange r, BOOL*) {
      if (!c) [ts addAttribute:NSForegroundColorAttributeName value:NSColor.textColor range:r];
    }];
  }
  _styling = NO;
}

- (void)textDidChange:(NSNotification*)n {
  [self updatePlaceholder];
  [self.delegate noteEditorDidChange:self];
  [_saveTimer invalidate];
  __weak NoteEditorView* weakSelf = self;
  _saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer*) { [weakSelf save]; }];
}

- (void)textViewDidChangeSelection:(NSNotification*)n {
  NSString* s = _textView.string;
  NSRange title = [s paragraphRangeForRange:NSMakeRange(0, 0)];
  NSUInteger titleEnd = NSMaxRange(title) - ([[s substringWithRange:title] hasSuffix:@"\n"] ? 1 : 0);
  BOOL inTitle = _textView.selectedRange.location <= titleEnd;
  NSFont* f = _textView.typingAttributes[NSFontAttributeName];
  BOOL titleFont = f.pointSize >= kTitleSize - 0.5;
  if (inTitle && !titleFont) _textView.typingAttributes = TitleAttributes();
  else if (!inTitle && titleFont) _textView.typingAttributes = BodyAttributes();
  [self updateToolbarState];
}

- (void)updateToolbarState {
  NSString* s = _textView.string;
  NSUInteger loc = _textView.selectedRange.location;
  NSRange title = [s paragraphRangeForRange:NSMakeRange(0, 0)];
  BOOL inTitle = loc < NSMaxRange(title) || (loc == NSMaxRange(title) && ![[s substringWithRange:title] hasSuffix:@"\n"]);
  _blockPopup.enabled = !inTitle;
  NSFont* f = loc < s.length && !inTitle ? [_textView.textStorage attribute:NSFontAttributeName atIndex:loc effectiveRange:nil]
                                         : _textView.typingAttributes[NSFontAttributeName];
  [_blockPopup selectItemWithTag:inTitle ? NoteBlockText : BlockForSize(f.pointSize ?: kBodySize)];
}

- (BOOL)textView:(NSTextView*)tv clickedOnLink:(id)link atIndex:(NSUInteger)index {
  NSString* url = [link isKindOfClass:NSURL.class] ? [(NSURL*)link absoluteString] : ([link isKindOfClass:NSString.class] ? link : nil);
  if (!url.length) return NO;
  [self.delegate noteEditor:self openLink:url];
  return YES;
}

// Tests.
- (NSArray<NSControl*>*)toolbarControls { return _controls; }
- (CGFloat)readingWidth { return _textView.textContainer.size.width; }
- (CGFloat)sideMargin { return _textView.textContainerInset.width; }
- (BOOL)looksDark {
  NSString* (^name)(NSView*) = ^NSString*(NSView* v) {
    return [v.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
  };
  if (![name(self) isEqualToString:NSAppearanceNameDarkAqua] || ![name(_toolbar) isEqualToString:NSAppearanceNameDarkAqua]) return NO;
  __block BOOL dark = NO;
  NSTextStorage* ts = _textView.textStorage;
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    NSColor* bg = [NSColor.textBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor* fg = (ts.length ? [ts attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:nil] : nil) ?: NSColor.textColor;
    fg = [fg colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    dark = bg.brightnessComponent < 0.35 && fg.brightnessComponent > 0.65;
  }];
  return dark;
}
- (BOOL)looksLight {
  NSString* n = [self.effectiveAppearance bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
  if (![n isEqualToString:NSAppearanceNameAqua]) return NO;
  __block BOOL light = NO;
  NSTextStorage* ts = _textView.textStorage;
  [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
    NSColor* bg = [NSColor.textBackgroundColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    NSColor* fg = (ts.length ? [ts attribute:NSForegroundColorAttributeName atIndex:0 effectiveRange:nil] : nil) ?: NSColor.textColor;
    fg = [fg colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    light = bg.brightnessComponent > 0.8 && fg.brightnessComponent < 0.35;
  }];
  return light;
}
@end
