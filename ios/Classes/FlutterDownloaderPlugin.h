#import <Flutter/Flutter.h>

@interface FlutterDownloaderPlugin : NSObject<FlutterPlugin>

@property (nonatomic, copy) void(^backgroundTransferCompletionHandler)(void);

+ (void)handleNotificationActionPause:(NSString *)taskId;
+ (void)handleNotificationActionResume:(NSString *)taskId;
+ (void)handleNotificationActionCancel:(NSString *)taskId;

+ (instancetype)sharedInstance;

@end
