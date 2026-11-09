// Web notifications in macOS Notification Center (#78). macOS asks the person once ("NotArc would like to send you
// notifications") the first time a site they allowed sends one. Clicking a notification calls the handler with the
// sidebar item's id so NotArc can show that tab.
#pragma once

#import <Foundation/Foundation.h>

void WebNotificationsSetClickHandler(void (^handler)(NSString* itemID));
void PostWebNotification(NSString* title, NSString* body, NSString* host, NSString* tag, NSString* itemID);
