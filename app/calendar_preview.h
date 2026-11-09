// Calendar (#56): Arc showed your next meeting in the sidebar with a Join button, and today's events when you hovered
// a calendar Favorite. NotArc reads the Mac's own Calendar (EventKit), so any calendar already added to macOS works
// (Google, iCloud, Exchange) with no sign-in. Off until turned on; macOS asks for Calendar access once.
#pragma once

#import <Foundation/Foundation.h>

@interface CalendarEvent : NSObject
@property(nonatomic, copy) NSString* title;
@property(nonatomic, strong) NSDate* start;
@property(nonatomic, strong) NSDate* end;
@property(nonatomic) BOOL allDay;
@property(nonatomic, copy) NSString* meetingURL;  // Zoom, Meet, Teams, Webex... link found in the event, or nil
@end

NSString* MeetingLinkInText(NSString* text);  // first video-call link in a URL, location or notes
// The meeting to show now: in progress, or starting within `lead` seconds; never all-day events. Earliest first.
CalendarEvent* NextMeeting(NSArray<CalendarEvent*>* events, NSDate* now, NSTimeInterval lead);
// "in 5 min", "now", "10:30" for the bar.
NSString* MeetingTimeLabel(CalendarEvent* e, NSDate* now);
BOOL CalendarAccessAllowed(void);
// Today's remaining events (all calendars). Asks for access the first time; `allowed` is NO if refused.
void CalendarLoadToday(void (^done)(NSArray<CalendarEvent*>* events, BOOL allowed));
