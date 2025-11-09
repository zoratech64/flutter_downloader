#import "FDNotificationActionHandler.h"
#import "FDNotificationCenter.h"
#import "FlutterDownloaderPlugin.h"
#import <UserNotifications/UserNotifications.h>

@implementation FDNotificationActionHandler

+ (instancetype)shared {
  static FDNotificationActionHandler *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [FDNotificationActionHandler new]; });
  return s;
}

// Show notifications while app is in foreground (iOS 10+)
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
       willPresentNotification:(UNNotification *)notification
         withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler
{
  if (@available(iOS 14.0, *)) {
    completionHandler(UNNotificationPresentationOptionBanner |
                      UNNotificationPresentationOptionList |
                      UNNotificationPresentationOptionSound);
  } else {
    completionHandler(UNNotificationPresentationOptionAlert |
                      UNNotificationPresentationOptionSound |
                      UNNotificationPresentationOptionBadge);
  }
}

// Called when user taps action buttons (Pause / Resume / Cancel) or the card
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler
{
  NSDictionary *info = response.notification.request.content.userInfo;
  NSString *taskId = info[@"task_id"];

  if ([response.actionIdentifier isEqualToString:FDActionPause]) {
    [FlutterDownloaderPlugin handleNotificationActionPause:taskId];
  } else if ([response.actionIdentifier isEqualToString:FDActionResume]) {
    [FlutterDownloaderPlugin handleNotificationActionResume:taskId];
  } else if ([response.actionIdentifier isEqualToString:FDActionCancel]) {
    [FlutterDownloaderPlugin handleNotificationActionCancel:taskId];
  } else {
    // Tapping the notification body. No-op or open UI if desired.
  }

  if (completionHandler) completionHandler();
}

@end
