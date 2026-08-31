#import "WXIFConfigInstaller.h"
#import "WXIFConversationFix.h"
#import "WXIFGestureFix.h"
#import "WXIFSettings.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface UINavigationController (WXIFCore)
- (void)wxif_pushViewController:(UIViewController *)viewController animated:(BOOL)animated;
@end

@interface UIViewController (WXIFCore)
- (void)wxif_viewDidAppear:(BOOL)animated;
@end

@implementation UINavigationController (WXIFCore)

- (void)wxif_pushViewController:(UIViewController *)viewController animated:(BOOL)animated {
    [WXIFConversationFix prepareForPushFromNavigationController:self];
    [self wxif_pushViewController:viewController animated:animated];
}

@end

@implementation UIViewController (WXIFCore)

- (void)wxif_viewDidAppear:(BOOL)animated {
    [self wxif_viewDidAppear:animated];

    UINavigationController *navigationController = self.navigationController;
    if (navigationController != nil) {
        [WXIFGestureFix prepareNavigationController:navigationController];
    }
    [WXIFConversationFix viewControllerDidAppear:self];
    [WXIFConfigInstaller inspectViewController:self];
}

@end

static void WXIFExchangeInstanceMethods(Class cls, SEL originalSelector, SEL replacementSelector) {
    Method original = class_getInstanceMethod(cls, originalSelector);
    Method replacement = class_getInstanceMethod(cls, replacementSelector);
    if (original == NULL || replacement == NULL) return;
    method_exchangeImplementations(original, replacement);
}

__attribute__((constructor)) static void WXIFInitialize(void) {
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier;
        if (![bundleIdentifier isEqualToString:@"com.tencent.xin"]) return;

        [WXIFSettings registerDefaults];
        dispatch_async(dispatch_get_main_queue(), ^{
            WXIFExchangeInstanceMethods(UINavigationController.class,
                                        @selector(pushViewController:animated:),
                                        @selector(wxif_pushViewController:animated:));
            WXIFExchangeInstanceMethods(UIViewController.class,
                                        @selector(viewDidAppear:),
                                        @selector(wxif_viewDidAppear:));
        });
    }
}
