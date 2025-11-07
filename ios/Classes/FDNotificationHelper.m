#import "FDNotificationHelper.h"

// Categories
NSString * const FDCategoryDownloadRunning = @"fd.category.download.running";
NSString * const FDCategoryDownloadPaused  = @"fd.category.download.paused";

// Actions
NSString * const FDActionPause  = @"fd.action.pause";
NSString * const FDActionResume = @"fd.action.resume";
NSString * const FDActionCancel = @"fd.action.cancel";

// userInfo keys
NSString * const FDUserInfoTaskId = @"fd.userInfo.taskId";
NSString * const FDUserInfoState  = @"fd.userInfo.state";

@implementation FDNotificationHelper

+ (UNUserNotificationCenter *)center { return [UNUserNotificationCenter currentNotificationCenter]; }

+ (void)prepareAndRegisterCategories {
  // Running: Pause + Cancel
  UNNotificationAction *pause =
    [UNNotificationAction actionWithIdentifier:FDActionPause
                                         title:@"Pause"
                                       options:UNNotificationActionOptionForeground];

  // Paused: Resume + Cancel
  UNNotificationAction *resume =
    [UNNotificationAction actionWithIdentifier:FDActionResume
                                         title:@"Resume"
                                       options:UNNotificationActionOptionForeground];

  UNNotificationAction *cancel =
    [UNNotificationAction actionWithIdentifier:FDActionCancel
                                         title:@"Cancel"
                                       options:UNNotificationActionOptionDestructive];

  UNNotificationCategory *runningCategory =
    [UNNotificationCategory categoryWithIdentifier:FDCategoryDownloadRunning
                                           actions:@[pause, cancel]
                                 intentIdentifiers:@[]
                                           options:UNNotificationCategoryOptionCustomDismissAction];

  UNNotificationCategory *pausedCategory =
    [UNNotificationCategory categoryWithIdentifier:FDCategoryDownloadPaused
                                           actions:@[resume, cancel]
                                 intentIdentifiers:@[]
                                           options:UNNotificationCategoryOptionCustomDismissAction];

  [[self center] setNotificationCategories:[NSSet setWithObjects:runningCategory, pausedCategory, nil]];

  // Ask permission if not determined
  [[self center] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
    if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
      [[self center] requestAuthorizationWithOptions:(UNAuthorizationOptionAlert|UNAuthorizationOptionSound|UNAuthorizationOptionBadge)
                                    completionHandler:^(__unused BOOL granted, __unused NSError * _Nullable error) {}];
    }
  }];
}

+ (NSString *)_identifierForTask:(NSString *)taskId {
  return [NSString stringWithFormat:@"fd.task.%@", taskId ?: @""];
}

+ (UNMutableNotificationContent *)_base:(NSString *)taskId
                                  title:(NSString *)title
                                   body:(NSString *)body
                                  state:(FDDownloadState)state {
  UNMutableNotificationContent *c = [UNMutableNotificationContent new];
  c.title = title.length ? title : @"Download";
  c.body  = body ?: @"";
  c.sound = [UNNotificationSound defaultSound];

  // Choose category by state (controls which actions appear)
  switch (state) {
    case FDDownloadStateRunning: c.categoryIdentifier = FDCategoryDownloadRunning; break;
    case FDDownloadStatePaused:  c.categoryIdentifier = FDCategoryDownloadPaused;  break;
    default:                     c.categoryIdentifier = @"";                        break; // final states: no actions
  }

  NSString *stateStr = @"running";
  if (state == FDDownloadStatePaused) stateStr = @"paused";
  else if (state == FDDownloadStateDone) stateStr = @"done";
  else if (state == FDDownloadStateFailed) stateStr = @"failed";

  c.userInfo = @{ FDUserInfoTaskId: taskId ?: @"", FDUserInfoState: stateStr };
  return c;
}

+ (void)_enqueue:(UNMutableNotificationContent *)content id:(NSString *)identifier {
  UNTimeIntervalNotificationTrigger *t = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:0.1 repeats:NO];
  UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:t];
  [[self center] addNotificationRequest:r withCompletionHandler:nil];
}

+ (void)showOrUpdateForTaskId:(NSString *)taskId
                        title:(NSString *)title
                     progress:(NSInteger)progress
                        state:(FDDownloadState)state {
  if (progress < 0) progress = 0;
  if (progress > 100) progress = 100;

  NSString *body = (state == FDDownloadStatePaused)
      ? [NSString stringWithFormat:@"Paused • %ld%%", (long)progress]
      : [NSString stringWithFormat:@"%ld%% completed", (long)progress];

  // Title reflects state
  NSString *finalTitle = title.length ? title :
    (state == FDDownloadStatePaused ? @"Download paused" : @"Downloading…");

  UNMutableNotificationContent *c = [self _base:taskId title:finalTitle body:body state:state];
  [self _enqueue:c id:[self _identifierForTask:taskId]];
}

+ (void)showDoneForTaskId:(NSString *)taskId title:(NSString *)title {
  UNMutableNotificationContent *c =
    [self _base:taskId title:(title.length ? title : @"Download complete") body:@"Tap to open" state:FDDownloadStateDone];
  // categoryIdentifier already blanked for final states
  [self _enqueue:c id:[self _identifierForTask:taskId]];
}

+ (void)showFailedForTaskId:(NSString *)taskId title:(NSString *)title error:(NSError *)error {
  UNMutableNotificationContent *c =
    [self _base:taskId title:(title.length ? title : @"Download failed") body:(error.localizedDescription ?: @"Please try again") state:FDDownloadStateFailed];
  [self _enqueue:c id:[self _identifierForTask:taskId]];
}

@end
