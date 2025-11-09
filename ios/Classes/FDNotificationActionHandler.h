// FDNotificationActionHandler.h
#import <Foundation/Foundation.h>

@interface FDNotificationActionHandler : NSObject
+ (instancetype)shared;

// Optional: keep as a no-op so older call sites compile.
// The plugin itself is the UNUserNotificationCenter delegate now.
- (void)attachAsDelegateIfNeeded;

// Convenience forwarders (optional, used by some call paths)
+ (void)handlePauseForTaskId:(NSString *)taskId;
+ (void)handleResumeForTaskId:(NSString *)taskId;
+ (void)handleCancelForTaskId:(NSString *)taskId;
@end
