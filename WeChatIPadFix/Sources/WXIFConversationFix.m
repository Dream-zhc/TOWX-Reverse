#import "WXIFConversationFix.h"
#import "WXIFRestorePolicy.h"
#import "WXIFSettings.h"
#import <UIKit/UIKit.h>

@interface WXIFConversationState : NSObject
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic, weak) UIViewController *sourceViewController;
@property (nonatomic, weak) UITableView *tableView;
@property (nonatomic) NSUInteger sourceDepth;
@property (nonatomic) CGFloat savedOffsetY;
@property (nonatomic) NSTimeInterval capturedAt;
@property (nonatomic) NSTimeInterval restoreDeadline;
@property (nonatomic) BOOL armed;
@end

@implementation WXIFConversationState
@end

static WXIFConversationState *WXIFState(void) {
    static WXIFConversationState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ state = [WXIFConversationState new]; });
    return state;
}

static void WXIFClearState(void) {
    WXIFConversationState *state = WXIFState();
    state.navigationController = nil;
    state.sourceViewController = nil;
    state.tableView = nil;
    state.sourceDepth = 0;
    state.savedOffsetY = 0;
    state.capturedAt = 0;
    state.restoreDeadline = 0;
    state.armed = NO;
}

static NSArray<UIWindow *> *WXIFWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    if (windows.count == 0) {
        id<UIApplicationDelegate> delegate = application.delegate;
        if ([delegate respondsToSelector:@selector(window)] && delegate.window != nil) {
            [windows addObject:delegate.window];
        }
    }
    return windows;
}

static UITabBar *WXIFVisibleTabBarInView(UIView *view) {
    if ([view isKindOfClass:UITabBar.class] && !view.hidden && view.alpha > 0.05 && view.window != nil) {
        return (UITabBar *)view;
    }
    for (UIView *subview in view.subviews) {
        UITabBar *found = WXIFVisibleTabBarInView(subview);
        if (found != nil) return found;
    }
    return nil;
}

static BOOL WXIFMessagesTabIsVisible(void) {
    for (UIWindow *window in WXIFWindows()) {
        if (window.hidden || window.alpha <= 0.05) continue;
        UITabBar *tabBar = WXIFVisibleTabBarInView(window);
        if (tabBar == nil || tabBar.selectedItem == nil) continue;
        NSUInteger index = [tabBar.items indexOfObject:tabBar.selectedItem];
        if (index != NSNotFound) return index == 0;
    }
    return NO;
}

static void WXIFCollectTables(UIView *view, NSMutableArray<UITableView *> *tables) {
    if ([view isKindOfClass:UITableView.class] && !view.hidden && view.alpha > 0.05 && view.window != nil) {
        UITableView *table = (UITableView *)view;
        if (CGRectGetWidth(table.bounds) >= 250.0 && CGRectGetHeight(table.bounds) >= 240.0) {
            [tables addObject:table];
        }
    }
    for (UIView *subview in view.subviews) {
        WXIFCollectTables(subview, tables);
    }
}

static UITableView *WXIFBestConversationTable(UIViewController *viewController) {
    if (!viewController.isViewLoaded || viewController.view.window == nil) return nil;
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    WXIFCollectTables(viewController.view, tables);

    UITableView *best = nil;
    double bestScore = 0;
    for (UITableView *table in tables) {
        NSUInteger visibleCount = table.visibleCells.count;
        if (visibleCount < 2) continue;
        double area = CGRectGetWidth(table.bounds) * CGRectGetHeight(table.bounds);
        double scrollBonus = table.contentSize.height > CGRectGetHeight(table.bounds) ? 75000.0 : 0.0;
        double score = area + (double)visibleCount * 45000.0 + scrollBonus;
        if (score > bestScore) {
            bestScore = score;
            best = table;
        }
    }
    return best;
}

static void WXIFAttemptRestore(void) {
    WXIFConversationState *state = WXIFState();
    if (!state.armed) return;

    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now > state.restoreDeadline) {
        WXIFClearState();
        return;
    }

    UITableView *table = state.tableView;
    UIViewController *source = state.sourceViewController;
    UINavigationController *navigationController = state.navigationController;
    if (table == nil || source == nil || navigationController == nil) {
        WXIFClearState();
        return;
    }
    if (source.view.window == nil || table.window == nil) return;
    if (navigationController.topViewController != source || navigationController.viewControllers.count != state.sourceDepth) return;

    CGFloat topY = -table.adjustedContentInset.top;
    CGFloat currentY = table.contentOffset.y;
    if (WXIFShouldRestoreConversationOffset([WXIFSettings conversationPositionFixEnabled],
                                            state.savedOffsetY,
                                            currentY,
                                            topY)) {
        [table setContentOffset:CGPointMake(table.contentOffset.x, state.savedOffsetY) animated:NO];
        [table layoutIfNeeded];
    }
}

@implementation WXIFConversationFix

+ (void)prepareForPushFromNavigationController:(UINavigationController *)navigationController {
    if (![WXIFSettings conversationPositionFixEnabled]) {
        WXIFClearState();
        return;
    }
    if (navigationController == nil || !WXIFMessagesTabIsVisible()) return;

    UIViewController *source = navigationController.topViewController;
    UITableView *table = WXIFBestConversationTable(source);
    if (source == nil || table == nil) return;

    CGFloat topY = -table.adjustedContentInset.top;
    CGFloat offsetY = table.contentOffset.y;
    if (offsetY <= topY + 100.0) {
        WXIFClearState();
        return;
    }

    WXIFConversationState *state = WXIFState();
    state.navigationController = navigationController;
    state.sourceViewController = source;
    state.tableView = table;
    state.sourceDepth = navigationController.viewControllers.count;
    state.savedOffsetY = offsetY;
    state.capturedAt = NSDate.date.timeIntervalSinceReferenceDate;
    state.restoreDeadline = 0;
    state.armed = YES;
}

+ (void)viewControllerDidAppear:(UIViewController *)viewController {
    if (![WXIFSettings conversationPositionFixEnabled]) {
        WXIFClearState();
        return;
    }

    WXIFConversationState *state = WXIFState();
    if (!state.armed || viewController != state.sourceViewController) return;

    UINavigationController *navigationController = state.navigationController;
    if (navigationController == nil || navigationController.topViewController != viewController) return;
    if (navigationController.viewControllers.count != state.sourceDepth) return;

    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    if (now - state.capturedAt > 300.0) {
        WXIFClearState();
        return;
    }

    state.restoreDeadline = now + 1.0;
    NSArray<NSNumber *> *delays = @[@0.0, @0.06, @0.16, @0.32, @0.58, @0.86, @1.02];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            WXIFAttemptRestore();
        });
    }
}

@end
