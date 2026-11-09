#import "app/web_notifications.h"

#import <UserNotifications/UserNotifications.h>

@interface WebNotificationDelegate : NSObject <UNUserNotificationCenterDelegate>
@property(nonatomic, copy) void (^onClick)(NSString* itemID);
@end
@implementation WebNotificationDelegate
// Show it even while NotArc is in front (the page asked for it; Chrome and Arc do the same).
- (void)userNotificationCenter:(UNUserNotificationCenter*)c willPresentNotification:(UNNotification*)n
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions))done {
  done(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList | UNNotificationPresentationOptionSound);
}
- (void)userNotificationCenter:(UNUserNotificationCenter*)c didReceiveNotificationResponse:(UNNotificationResponse*)r
         withCompletionHandler:(void (^)(void))done {
  NSString* itemID = r.notification.request.content.userInfo[@"item"];
  if (self.onClick && itemID.length) dispatch_async(dispatch_get_main_queue(), ^{ self.onClick(itemID); });
  done();
}
@end

static WebNotificationDelegate* Delegate() {
  static WebNotificationDelegate* d;
  if (!d) {
    d = [WebNotificationDelegate new];
    UNUserNotificationCenter.currentNotificationCenter.delegate = d;
  }
  return d;
}

void WebNotificationsSetClickHandler(void (^handler)(NSString* itemID)) { Delegate().onClick = handler; }

void PostWebNotification(NSString* title, NSString* body, NSString* host, NSString* tag, NSString* itemID) {
  Delegate();
  UNUserNotificationCenter* c = UNUserNotificationCenter.currentNotificationCenter;
  [c requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound
                   completionHandler:^(BOOL granted, NSError*) {
                     if (!granted) return;
                     UNMutableNotificationContent* content = [UNMutableNotificationContent new];
                     content.title = title ?: @"";
                     content.subtitle = host ?: @"";
                     content.body = body ?: @"";
                     content.sound = UNNotificationSound.defaultSound;
                     content.userInfo = @{@"item" : itemID ?: @""};
                     content.threadIdentifier = host ?: @"";
                     // A tag replaces the earlier notification with the same tag, as on the web.
                     NSString* ident = tag.length ? [NSString stringWithFormat:@"%@|%@", host, tag] : NSUUID.UUID.UUIDString;
                     [c addNotificationRequest:[UNNotificationRequest requestWithIdentifier:ident content:content trigger:nil]
                         withCompletionHandler:nil];
                   }];
}
