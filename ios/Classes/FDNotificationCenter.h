#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const FDCategoryRunning;
extern NSString * const FDCategoryPaused;
extern NSString * const FDCategoryDone;

@interface FDNotificationCenter : NSObject
+ (instancetype)shared;

- (void)ensureAuthorization:(void(^)(void))completion;

- (void)postOrUpdateForTaskId:(NSString *)taskId
                        title:(NSString *)title
                         body:(NSString *)body
                     category:(NSString *)category
                     userInfo:(nullable NSDictionary *)userInfo
                       silent:(BOOL)silent;

- (void)removeForTaskId:(NSString *)taskId;

@end

NS_ASSUME_NONNULL_END
