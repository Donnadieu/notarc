// Live Folders (Arc: LiveFolderDataSource): a sidebar folder whose tabs come from a feed and refresh on their own.
// Sources: an RSS or Atom feed, or a GitHub repository's open pull requests or issues (public REST API).
#import <Foundation/Foundation.h>

// One entry fetched from a source.
@interface LiveFolderEntry : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* url;
@end

// kind: "feed" (source = feed URL), "github-prs" or "github-issues" (source = "owner/repo").
NSString* LiveFolderFetchURL(NSString* kind, NSString* source);
// Parses a fetched response; nil if it can't be read. At most `limit` entries, newest first as served.
NSArray<LiveFolderEntry*>* LiveFolderParse(NSString* kind, NSData* data, NSUInteger limit);
// Fetches and parses; calls back on the main queue with entries or an error message.
void LiveFolderFetch(NSString* kind, NSString* source, NSUInteger limit,
                     void (^done)(NSArray<LiveFolderEntry*>* entries, NSString* error));
// Turns user input ("github.com/owner/repo", "owner/repo", a feed URL) into kind + source; nil if unusable.
NSDictionary* LiveFolderSourceFromInput(NSString* input, BOOL issues);
