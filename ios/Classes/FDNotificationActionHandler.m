#import "FDNotificationActionHandler.h"
#import "FDNotificationCenter.h"
#import "FlutterDownloaderPlugin.h"

@implementation FDNotificationActionHandler
+ (instancetype)shared {
  static FDNotificationActionHandler *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [FDNotificationActionHandler new]; });
  return s;
}

// Called when user taps action buttons
- (void)userNotificationCenter:(UNUserNotificationCenter *)center
 didReceiveNotificationResponse:(UNNotificationResponse *)response
          withCompletionHandler:(void (^)(void))completionHandler {

  NSDictionary *info = response.notification.request.content.userInfo;
  NSString *taskId = info[@"task_id"];

  if ([response.actionIdentifier isEqualToString:FDActionPause]) {
    [FlutterDownloaderPlugin handleNotificationActionPause:taskId];
  } else if ([response.actionIdentifier isEqualToString:FDActionResume]) {
    [FlutterDownloaderPlugin handleNotificationActionResume:taskId];
  } else if ([response.actionIdentifier isEqualToString:FDActionCancel]) {
    [FlutterDownloaderPlugin handleNotificationActionCancel:taskId];
  } else {
    // tapping the card — no-op or open UI
  }
  if (completionHandler) completionHandler();
}
@end
