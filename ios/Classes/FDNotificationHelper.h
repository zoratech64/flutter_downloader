#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

NS_ASSUME_NONNULL_BEGIN

// Categories (state-specific)
extern NSString * const FDCategoryDownloadRunning; // Pause + Cancel
extern NSString * const FDCategoryDownloadPaused;  // Resume + Cancel

// Actions
extern NSString * const FDActionPause;
extern NSString * const FDActionResume;
extern NSString * const FDActionCancel;

// userInfo keys
extern NSString * const FDUserInfoTaskId;
extern NSString * const FDUserInfoState;   // "running" | "paused" | "done" | "failed"

typedef NS_ENUM(NSInteger, FDDownloadState) {
  FDDownloadStateRunning,
  FDDownloadStatePaused,
  FDDownloadStateDone,
  FDDownloadStateFailed
};

@interface FDNotificationHelper : NSObject

/// Call once. Registers categories and (if not determined) requests permission.
+ (void)prepareAndRegisterCategories;

/// Running → Pause/Cancel; Paused → Resume/Cancel
+ (void)showOrUpdateForTaskId:(NSString *)taskId
                        title:(NSString *)title
                     progress:(NSInteger)progress
                        state:(FDDownloadState)state;

/// Final states: Done / Failed (no actions)
+ (void)showDoneForTaskId:(NSString *)taskId title:(NSString *)title;
+ (void)showFailedForTaskId:(NSString *)taskId title:(NSString *)title error:(nullable NSError *)error;

@end

NS_ASSUME_NONNULL_END
