#import <Flutter/Flutter.h>
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>

@interface FlutterDownloaderPlugin : NSObject <FlutterPlugin, UIApplicationDelegate>

@property (nonatomic, copy) void (^backgroundTransferCompletionHandler)(void);

@property (nonatomic, strong, readwrite) NSURLSession *currentSession;

+ (instancetype)sharedInstance;

+ (void)handleNotificationActionPause:(NSString *)taskId;
+ (void)handleNotificationActionResume:(NSString *)taskId;
+ (void)handleNotificationActionCancel:(NSString *)taskId;

@end
