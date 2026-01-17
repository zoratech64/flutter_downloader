// FDNotificationActionHandler.m
#import "FDNotificationActionHandler.h"

@implementation FDNotificationActionHandler

+ (instancetype)shared {
  static FDNotificationActionHandler *s; static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [FDNotificationActionHandler new]; });
  return s;
}

- (void)attachAsDelegateIfNeeded {
  // No-op
}

+ (void)handlePauseForTaskId:(NSString *)taskId {
  // No-op
}

+ (void)handleResumeForTaskId:(NSString *)taskId {
  // No-op
}

+ (void)handleCancelForTaskId:(NSString *)taskId {
  // No-op
}

@end
