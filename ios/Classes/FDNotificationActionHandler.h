// FDNotificationActionHandler.h
#import <Foundation/Foundation.h>

@interface FDNotificationActionHandler : NSObject
+ (instancetype)shared;

- (void)attachAsDelegateIfNeeded;

// No-op APIs kept only for compatibility with older call sites.
+ (void)handlePauseForTaskId:(NSString *)taskId;
+ (void)handleResumeForTaskId:(NSString *)taskId;
+ (void)handleCancelForTaskId:(NSString *)taskId;

@end
