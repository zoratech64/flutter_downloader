#import "FDNotificationCenter.h"

NSString * const FDCategoryRunning = @"FD_DOWNLOAD_RUNNING";
NSString * const FDCategoryPaused  = @"FD_DOWNLOAD_PAUSED";
NSString * const FDCategoryDone    = @"FD_DOWNLOAD_DONE";

NSString * const FDActionPause  = @"FD_ACTION_PAUSE";
NSString * const FDActionResume = @"FD_ACTION_RESUME";
NSString * const FDActionCancel = @"FD_ACTION_CANCEL";
NSString * const FDActionOpen   = @"FD_ACTION_OPEN";

@implementation FDNotificationCenter
+ (instancetype)shared {
  static FDNotificationCenter *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [FDNotificationCenter new]; });
  return s;
}

- (void)registerCategories {
  UNNotificationAction *pause  = [UNNotificationAction actionWithIdentifier:FDActionPause title:@"Pause" options:UNNotificationActionOptionNone];
  UNNotificationAction *resume = [UNNotificationAction actionWithIdentifier:FDActionResume title:@"Resume" options:UNNotificationActionOptionNone];
  UNNotificationAction *cancel = [UNNotificationAction actionWithIdentifier:FDActionCancel title:@"Cancel" options:UNNotificationActionOptionDestructive];
  UNNotificationAction *open   = [UNNotificationAction actionWithIdentifier:FDActionOpen title:@"Open" options:UNNotificationActionOptionForeground];

  UNNotificationCategory *running = [UNNotificationCategory categoryWithIdentifier:FDCategoryRunning actions:@[pause, cancel] intentIdentifiers:@[] options:UNNotificationCategoryOptionCustomDismissAction];
  UNNotificationCategory *paused  = [UNNotificationCategory categoryWithIdentifier:FDCategoryPaused actions:@[resume, cancel] intentIdentifiers:@[] options:UNNotificationCategoryOptionCustomDismissAction];
  UNNotificationCategory *done    = [UNNotificationCategory categoryWithIdentifier:FDCategoryDone actions:@[open] intentIdentifiers:@[] options:UNNotificationCategoryOptionNone];

  [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories:[NSSet setWithObjects:running, paused, done, nil]];
}

- (void)ensureAuthorization:(void(^)(void))completion {
  UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
  [c getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
    if (settings.authorizationStatus == UNAuthorizationStatusAuthorized ||
        settings.authorizationStatus == UNAuthorizationStatusProvisional) {
      if (completion) completion();
    } else {
      [c requestAuthorizationWithOptions:(UNAuthorizationOptionAlert|UNAuthorizationOptionSound|UNAuthorizationOptionBadge)
                       completionHandler:^(__unused BOOL granted, __unused NSError * _Nullable error) {
        if (completion) completion();
      }];
    }
  }];
}

- (void)postOrUpdateForTaskId:(NSString *)taskId
                        title:(NSString *)title
                         body:(NSString *)body
                     category:(NSString *)category
                     userInfo:(NSDictionary *)userInfo {
  UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
  NSString *identifier = [NSString stringWithFormat:@"fd.task.%@", taskId];

  [c removeDeliveredNotificationsWithIdentifiers:@[identifier]];

  UNMutableNotificationContent *content = [UNMutableNotificationContent new];
  content.title = title ?: @"Download";
  content.body  = body ?: @"";
  content.sound = [UNNotificationSound defaultSound];
  content.categoryIdentifier = category;
  content.threadIdentifier = [NSString stringWithFormat:@"fd.download.%@", taskId];

  NSMutableDictionary *info = userInfo ? [userInfo mutableCopy] : [NSMutableDictionary new];
  info[@"task_id"] = taskId;
  content.userInfo = info;

  UNTimeIntervalNotificationTrigger *trigger = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
  UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:trigger];
  [c addNotificationRequest:req withCompletionHandler:nil];
}

- (void)removeForTaskId:(NSString *)taskId {
  UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
  NSString *identifier = [NSString stringWithFormat:@"fd.task.%@", taskId];
  [c removePendingNotificationRequestsWithIdentifiers:@[identifier]];
  [c removeDeliveredNotificationsWithIdentifiers:@[identifier]];
}
@end
