#import "WXIFConfigInstaller.h"
#import "WXIFConfigViewController.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *WXIFConfigButtonAssociationKey = &WXIFConfigButtonAssociationKey;

@interface WXIFConfigInstallerTarget : NSObject
@property (nonatomic, weak) UIViewController *hostViewController;
+ (instancetype)sharedTarget;
- (void)openConfig:(id)sender;
@end

@implementation WXIFConfigInstallerTarget

+ (instancetype)sharedTarget {
    static WXIFConfigInstallerTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [WXIFConfigInstallerTarget new]; });
    return target;
}

- (void)openConfig:(id)sender {
    (void)sender;
    UIViewController *host = self.hostViewController;
    UINavigationController *navigationController = host.navigationController;
    if (host == nil || navigationController == nil) return;
    if (navigationController.topViewController != host) return;

    WXIFConfigViewController *config = [WXIFConfigViewController new];
    [navigationController pushViewController:config animated:YES];
}

@end

static BOOL WXIFViewContainsTable(UIView *view) {
    if ([view isKindOfClass:UITableView.class]) return YES;
    for (UIView *subview in view.subviews) {
        if (WXIFViewContainsTable(subview)) return YES;
    }
    return NO;
}

static void WXIFCollectLabelTexts(UIView *view, NSMutableArray<NSString *> *texts) {
    if ([view isKindOfClass:UILabel.class]) {
        NSString *text = ((UILabel *)view).text;
        if (text.length > 0) [texts addObject:text];
    }
    for (UIView *subview in view.subviews) {
        WXIFCollectLabelTexts(subview, texts);
    }
}

static BOOL WXIFLooksLikeWeChatSettings(UIViewController *viewController) {
    if (viewController == nil || viewController.navigationController == nil) return NO;
    if (viewController.navigationController.topViewController != viewController) return NO;
    if (!viewController.isViewLoaded || viewController.view.window == nil) return NO;

    NSString *title = viewController.title ?: viewController.navigationItem.title ?: @"";
    BOOL titleMatches = [title isEqualToString:@"设置"] || [title caseInsensitiveCompare:@"Settings"] == NSOrderedSame;
    if (!titleMatches || !WXIFViewContainsTable(viewController.view)) return NO;

    NSString *className = NSStringFromClass(viewController.class).lowercaseString;
    if ([className containsString:@"setting"]) return YES;

    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    WXIFCollectLabelTexts(viewController.view, texts);
    NSArray<NSString *> *markers = @[@"账号与安全", @"通用", @"关于微信", @"帮助与反馈",
                                     @"Account", @"General", @"About WeChat", @"Help & Feedback"];
    NSUInteger hits = 0;
    for (NSString *marker in markers) {
        for (NSString *text in texts) {
            if ([text localizedCaseInsensitiveContainsString:marker]) {
                hits += 1;
                break;
            }
        }
        if (hits >= 1) return YES;
    }
    return NO;
}

@implementation WXIFConfigInstaller

+ (void)inspectViewController:(UIViewController *)viewController {
    if (!WXIFLooksLikeWeChatSettings(viewController)) return;

    WXIFConfigInstallerTarget *target = [WXIFConfigInstallerTarget sharedTarget];
    target.hostViewController = viewController;

    UIBarButtonItem *existingButton = objc_getAssociatedObject(viewController, WXIFConfigButtonAssociationKey);
    if (existingButton != nil) return;

    UIBarButtonItem *button = [[UIBarButtonItem alloc] initWithTitle:@"iPad Fix"
                                                               style:UIBarButtonItemStylePlain
                                                              target:target
                                                              action:@selector(openConfig:)];
    NSMutableArray<UIBarButtonItem *> *items = [NSMutableArray arrayWithObject:button];
    NSArray<UIBarButtonItem *> *currentItems = viewController.navigationItem.rightBarButtonItems;
    if (currentItems.count > 0) [items addObjectsFromArray:currentItems];
    viewController.navigationItem.rightBarButtonItems = items;
    objc_setAssociatedObject(viewController, WXIFConfigButtonAssociationKey, button, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

@end
