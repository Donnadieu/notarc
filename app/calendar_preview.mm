#import "app/calendar_preview.h"

#import <EventKit/EventKit.h>

@implementation CalendarEvent
@end

NSString* MeetingLinkInText(NSString* text) {
  if (!text.length) return nil;
  static NSRegularExpression* re;
  if (!re)
    re = [NSRegularExpression
        regularExpressionWithPattern:@"https?://(?:[a-z0-9-]+\\.)*(?:zoom\\.us/(?:j|my|w)/|meet\\.google\\.com/[a-z]{3}-[a-z]{4}-[a-z]{3}|"
                                     "teams\\.microsoft\\.com/l/meetup-join/|teams\\.live\\.com/meet/|[a-z0-9-]+\\.webex\\.com/(?:meet|join|wbxmjs)|"
                                     "whereby\\.com/|meet\\.jit\\.si/|around\\.co/|app\\.slack\\.com/huddle/|facetime\\.apple\\.com/join)[^\\s<>\"')]*"
                             options:NSRegularExpressionCaseInsensitive
                               error:nil];
  NSTextCheckingResult* m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
  return m ? [text substringWithRange:m.range] : nil;
}

CalendarEvent* NextMeeting(NSArray<CalendarEvent*>* events, NSDate* now, NSTimeInterval lead) {
  CalendarEvent* best = nil;
  for (CalendarEvent* e in events) {
    if (e.allDay || !e.start || !e.end) continue;
    BOOL inProgress = [e.start compare:now] != NSOrderedDescending && [e.end compare:now] == NSOrderedDescending;
    NSTimeInterval until = [e.start timeIntervalSinceDate:now];
    if (!inProgress && (until < 0 || until > lead)) continue;
    if (!best || [e.start compare:best.start] == NSOrderedAscending) best = e;
  }
  return best;
}

NSString* MeetingTimeLabel(CalendarEvent* e, NSDate* now) {
  NSTimeInterval until = [e.start timeIntervalSinceDate:now];
  if (until <= 30) return @"now";
  if (until < 3600) return [NSString stringWithFormat:@"in %d min", (int)ceil(until / 60)];
  NSDateFormatter* f = [NSDateFormatter new];
  f.timeStyle = NSDateFormatterShortStyle;
  f.dateStyle = NSDateFormatterNoStyle;
  return [f stringFromDate:e.start];
}

static EKEventStore* Store() {
  static EKEventStore* s;
  if (!s) s = [EKEventStore new];
  return s;
}

BOOL CalendarAccessAllowed(void) {
  EKAuthorizationStatus st = [EKEventStore authorizationStatusForEntityType:EKEntityTypeEvent];
  if (@available(macOS 14.0, *)) return st == EKAuthorizationStatusFullAccess;
  return st == EKAuthorizationStatusAuthorized;
}

static NSArray<CalendarEvent*>* TodayEvents(void) {
  NSDate* now = NSDate.date;
  NSCalendar* cal = NSCalendar.currentCalendar;
  NSDate* end = [cal dateByAddingUnit:NSCalendarUnitDay value:1 toDate:[cal startOfDayForDate:now] options:0];
  NSPredicate* p = [Store() predicateForEventsWithStartDate:[now dateByAddingTimeInterval:-4 * 3600] endDate:end calendars:nil];
  NSMutableArray* out = [NSMutableArray array];
  for (EKEvent* ev in [Store() eventsMatchingPredicate:p]) {
    if ([ev.endDate compare:now] != NSOrderedDescending) continue;
    BOOL declined = NO;
    for (EKParticipant* a in ev.attendees)
      if (a.isCurrentUser && a.participantStatus == EKParticipantStatusDeclined) declined = YES;
    if (declined || ev.status == EKEventStatusCanceled) continue;
    CalendarEvent* e = [CalendarEvent new];
    e.title = ev.title.length ? ev.title : @"Busy";
    e.start = ev.startDate;
    e.end = ev.endDate;
    e.allDay = ev.allDay;
    e.meetingURL = MeetingLinkInText(ev.URL.absoluteString) ?: MeetingLinkInText(ev.location) ?: MeetingLinkInText(ev.notes);
    [out addObject:e];
  }
  [out sortUsingComparator:^NSComparisonResult(CalendarEvent* a, CalendarEvent* b) { return [a.start compare:b.start]; }];
  return out;
}

void CalendarLoadToday(void (^done)(NSArray<CalendarEvent*>* events, BOOL allowed)) {
  if (CalendarAccessAllowed()) {
    done(TodayEvents(), YES);
    return;
  }
  void (^finish)(BOOL, NSError*) = ^(BOOL granted, NSError*) {
    dispatch_async(dispatch_get_main_queue(), ^{ done(granted ? TodayEvents() : @[], granted); });
  };
  if (@available(macOS 14.0, *)) [Store() requestFullAccessToEventsWithCompletion:finish];
  else [Store() requestAccessToEntityType:EKEntityTypeEvent completion:finish];
}
