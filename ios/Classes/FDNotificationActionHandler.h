#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>

@interface FDNotificationActionHandler : NSObject <UNUserNotificationCenterDelegate>
+ (instancetype)shared;
@end
