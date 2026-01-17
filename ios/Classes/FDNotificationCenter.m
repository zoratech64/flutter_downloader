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
    UNNotificationAction *pause = [UNNotificationAction actionWithIdentifier:FDActionPause
                                                                       title:@"Pause"
                                                                     options:UNNotificationActionOptionNone];
    UNNotificationAction *resume = [UNNotificationAction actionWithIdentifier:FDActionResume
                                                                        title:@"Resume"
                                                                      options:UNNotificationActionOptionNone];
    UNNotificationAction *cancel = [UNNotificationAction actionWithIdentifier:FDActionCancel
                                                                        title:@"Cancel"
                                                                      options:UNNotificationActionOptionDestructive];
    UNNotificationAction *open = [UNNotificationAction actionWithIdentifier:FDActionOpen
                                                                      title:@"Open"
                                                                    options:UNNotificationActionOptionForeground];
    UNNotificationCategory *runningCategory = [UNNotificationCategory categoryWithIdentifier:FDCategoryRunning
                                                                                   actions:@[pause, cancel]
                                                                         intentIdentifiers:@[]
                                                                                   options:UNNotificationCategoryOptionCustomDismissAction |
                                                                                            UNNotificationCategoryOptionAllowAnnouncement];
    UNNotificationCategory *pausedCategory = [UNNotificationCategory categoryWithIdentifier:FDCategoryPaused
                                                                                  actions:@[resume, cancel]
                                                                        intentIdentifiers:@[]
                                                                                  options:UNNotificationCategoryOptionCustomDismissAction |
                                                                                           UNNotificationCategoryOptionAllowAnnouncement];
    UNNotificationCategory *doneCategory = [UNNotificationCategory categoryWithIdentifier:FDCategoryDone
                                                                                actions:@[open]
                                                                      intentIdentifiers:@[]
                                                                                options:UNNotificationCategoryOptionNone];
    NSSet<UNNotificationCategory *> *categories = [NSSet setWithObjects:runningCategory, pausedCategory, doneCategory, nil];
    [[UNUserNotificationCenter currentNotificationCenter] setNotificationCategories:categories];
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
                     userInfo:(NSDictionary *)userInfo
                       silent:(BOOL)silent {

    UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];

    NSString *runningId = [NSString stringWithFormat:@"fd.task.%@.running", taskId];
    NSString *pausedId  = [NSString stringWithFormat:@"fd.task.%@.paused",  taskId];
    NSString *doneId    = [NSString stringWithFormat:@"fd.task.%@.done",    taskId];

    NSString *identifier = runningId;
    if ([category isEqualToString:FDCategoryPaused]) identifier = pausedId;
    if ([category isEqualToString:FDCategoryDone])   identifier = doneId;

    NSArray *allIds = @[runningId, pausedId, doneId];
    NSMutableArray *toRemove = [NSMutableArray arrayWithArray:allIds];
    [toRemove removeObject:identifier];

    [c removePendingNotificationRequestsWithIdentifiers:toRemove];
    [c removeDeliveredNotificationsWithIdentifiers:toRemove];

    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = title ?: @"Download";
    content.body = body ?: @"";
    content.categoryIdentifier = @"";
    content.userInfo = userInfo ?: @{@"taskId": taskId};

    if (!silent) {
        content.sound = [UNNotificationSound defaultSound];
    }
    if (@available(iOS 15.0, *)) {
        content.interruptionLevel = UNNotificationInterruptionLevelPassive;
    }

    UNNotificationRequest *request =
    [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
    [c addNotificationRequest:request withCompletionHandler:^(NSError *error) {
        if (error) NSLog(@"[FD] Failed to add/update notification: %@", error);
    }];
}

- (void)removeForTaskId:(NSString *)taskId {
  UNUserNotificationCenter *c = [UNUserNotificationCenter currentNotificationCenter];
  NSString *runningId = [NSString stringWithFormat:@"fd.task.%@.running", taskId];
  NSString *pausedId  = [NSString stringWithFormat:@"fd.task.%@.paused",  taskId];
  NSString *doneId    = [NSString stringWithFormat:@"fd.task.%@.done",    taskId];
  NSArray *ids = @[runningId, pausedId, doneId];
  [c removePendingNotificationRequestsWithIdentifiers:ids];
  [c removeDeliveredNotificationsWithIdentifiers:ids];
}

- (void)moveNotificationFromTaskId:(NSString *)oldTaskId toTaskId:(NSString *)newTaskId {
    if (!oldTaskId.length) return;
    [self removeForTaskId:oldTaskId];
}

@end
