// FDNotificationActionHandler.m
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

/**
 * In the new design, the FlutterDownloaderPlugin is the UNUserNotificationCenter delegate.
 * So this handler no longer implements those delegate callbacks.
 * Instead, it provides helper methods to forward actions manually if ever needed.
 */

- (void)attachAsDelegateIfNeeded {
  // Intentionally left blank — plugin sets itself as delegate.
}

+ (void)handlePauseForTaskId:(NSString *)taskId {
  [FlutterDownloaderPlugin handleNotificationActionPause:taskId];
}

+ (void)handleResumeForTaskId:(NSString *)taskId {
  [FlutterDownloaderPlugin handleNotificationActionResume:taskId];
}

+ (void)handleCancelForTaskId:(NSString *)taskId {
  [FlutterDownloaderPlugin handleNotificationActionCancel:taskId];
}

@end
