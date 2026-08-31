#import <Foundation/Foundation.h>
@class UINavigationController;
@class UIViewController;

@interface WXIFConversationFix : NSObject
+ (void)prepareForPushFromNavigationController:(UINavigationController *)navigationController;
+ (void)viewControllerDidAppear:(UIViewController *)viewController;
@end
