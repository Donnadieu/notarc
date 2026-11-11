// Notes (Arc: NoteDocument, ArcRichTextEditor). One note's editor: a small formatting toolbar over a centred page
// whose first line is the note's large title. Saved locally as RTF; exported as Markdown.
#import <Cocoa/Cocoa.h>

typedef NS_ENUM(NSInteger, NoteBlock) { NoteBlockText = 0, NoteBlockHeading1 = 1, NoteBlockHeading2 = 2, NoteBlockHeading3 = 3 };
typedef NS_ENUM(NSInteger, NoteList) { NoteListNone = 0, NoteListBullet, NoteListNumber, NoteListCheck };

@class NoteEditorView;
@protocol NoteEditorDelegate <NSObject>
- (void)noteEditorDidChange:(NoteEditorView*)editor;  // text changed (its title may have too)
- (void)noteEditorDidFocus:(NoteEditorView*)editor;   // its page became first responder
- (void)noteEditor:(NoteEditorView*)editor openLink:(NSString*)url;
@end

// The note's page. Toolbar buttons and Format menu items (nil target) call these.
@interface NoteTextView : NSTextView
- (IBAction)noteFormatBlock:(id)sender;  // sender's tag (or selected item's tag) is a NoteBlock
- (IBAction)noteToggleBold:(id)sender;
- (IBAction)noteToggleItalic:(id)sender;
- (IBAction)noteToggleUnderline:(id)sender;
- (IBAction)noteToggleStrikethrough:(id)sender;
- (IBAction)noteToggleBulletList:(id)sender;
- (IBAction)noteToggleNumberedList:(id)sender;
- (IBAction)noteToggleChecklist:(id)sender;
- (IBAction)noteAddLink:(id)sender;  // asks for an address
- (void)applyBlock:(NoteBlock)block;
- (void)applyList:(NoteList)list;
- (void)setLinkOnSelection:(NSString*)url;  // nil/empty removes the link
- (BOOL)toggleCheckboxInParagraphAt:(NSUInteger)index;
@end

@interface NoteEditorView : NSView
@property(nonatomic, weak) id<NoteEditorDelegate> delegate;
@property(nonatomic, strong) id item;      // the sidebar item (ArcItem) this editor shows
@property(nonatomic, copy) NSString* path;  // RTF file
@property(nonatomic, readonly) NoteTextView* textView;
@property(nonatomic, readonly) NSView* toolbar;
- (void)load;
- (void)save;  // writes now (edits also save half a second after typing stops)
- (NSString*)title;     // first line, trimmed, up to 80 characters; nil when empty
- (NSString*)markdown;  // the note as Markdown
// Tests.
- (NSArray<NSControl*>*)toolbarControls;
- (NSString*)floatingBarDescription;  // tests (V44)
- (CGFloat)readingWidth;  // width of the text column
- (CGFloat)sideMargin;
- (BOOL)looksDark;        // toolbar and page resolve to dark colours, with light text
- (BOOL)looksLight;
@end

NSAttributedString* NoteLoadRTF(NSString* path);
NSString* NoteMarkdown(NSAttributedString* text);  // first line is the title (# ...)
