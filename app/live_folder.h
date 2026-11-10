// Live Folders (Arc: LiveFolderDataSource): a sidebar folder whose tabs come from a feed and refresh on their own.
// Sources: an RSS or Atom feed, a GitHub repository's open pull requests or issues (public REST API), your own open
// pull requests (github.com pages read with the Space's own sign-in), or a YouTube channel (its public feed).
#import <Foundation/Foundation.h>

// One entry fetched from a source.
@interface LiveFolderEntry : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy) NSString* url;
@end

// kind: "feed" (source = feed URL), "github-prs" or "github-issues" (source = "owner/repo"), "github-mine" (source =
// "@me"; the window fetches LiveFolderGitHubMineURLs with the Space's cookies), "youtube" (source = channel id).
NSString* LiveFolderFetchURL(NSString* kind, NSString* source);
// Parses a fetched response; nil if it can't be read. At most `limit` entries, newest first as served.
NSArray<LiveFolderEntry*>* LiveFolderParse(NSString* kind, NSData* data, NSUInteger limit);
// Fetches and parses; calls back on the main queue with entries or an error message. Not for "github-mine".
void LiveFolderFetch(NSString* kind, NSString* source, NSUInteger limit,
                     void (^done)(NSArray<LiveFolderEntry*>* entries, NSString* error));
// Turns user input into kind + source; nil if unusable. Accepts "github.com/owner/repo", "owner/repo", a feed URL, or a
// YouTube channel address. A YouTube address without a channel id ("youtube.com/@name", "@name") comes back as kind
// "youtube" with "resolve" = the page to read the channel id from (LiveFolderResolveYouTube) and no source.
NSDictionary* LiveFolderSourceFromInput(NSString* input, BOOL issues);

// Self-tests: answer fetches for these URLs from local files (URL -> file path) instead of the network. nil = off.
void LiveFolderSetTestPages(NSDictionary<NSString*, NSString*>* pages);
BOOL LiveFolderTestPagesActive(void);
NSData* LiveFolderTestPage(NSString* url);  // the file's contents if `url` is a test page, else nil

// My pull requests: the github.com pages read for "github-mine" (yours, then ones waiting for your review), in order.
NSArray<NSString*>* LiveFolderGitHubMineURLs(void);
extern NSString* const kLiveFolderGitHubSignInURL;  // the entry shown while the Space isn't signed in to GitHub
extern NSString* const kLiveFolderGitHubNoneURL;    // the entry shown when you have no open pull requests
// Reads pull requests from a github.com HTML page (search results or a pull request list). *signedIn says whether
// the page was served to a signed-in user. `review` labels entries as waiting for your review.
NSArray<LiveFolderEntry*>* LiveFolderParseGitHubHTML(NSString* html, NSUInteger limit, BOOL review, BOOL* signedIn);
// True once a tab is back on github.com past the sign-in pages (the folder can refresh then).
BOOL LiveFolderIsGitHubSignedInLanding(NSString* url);

// YouTube: the channel id ("UC" + 22 characters) and name from a channel (or video) page's HTML; nil if not found.
NSString* LiveFolderYouTubeChannelIDFromHTML(NSString* html, NSString** name);
// Reads `pageURL` once to find its channel id; calls back on the main queue.
void LiveFolderResolveYouTube(NSString* pageURL, void (^done)(NSString* channelID, NSString* name, NSString* error));
