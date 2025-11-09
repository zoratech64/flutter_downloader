// FDNotificationCenter.h
#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FDCategoryRunning;
extern NSString * const FDCategoryPaused;
extern NSString * const FDCategoryDone;

extern NSString * const FDActionPause;
extern NSString * const FDActionResume;
extern NSString * const FDActionCancel;
extern NSString * const FDActionOpen;

@interface FDNotificationCenter : NSObject
+ (instancetype)shared;

- (void)registerCategories;
- (void)ensureAuthorization:(void(^)(void))completion;

/**
 * Adds or replaces a notification for the given download.
 * Pass silent:YES for progress/pause/resume updates (no banner/sound),
 * and silent:NO for first show or final states (start/complete/fail).
 */
- (void)postOrUpdateForTaskId:(NSString *)taskId
                        title:(NSString *)title
                         body:(NSString *)body
                     category:(NSString *)category
                     userInfo:(nullable NSDictionary *)userInfo
                       silent:(BOOL)silent;

- (void)removeForTaskId:(NSString *)taskId;
@end

NS_ASSUME_NONNULL_END
