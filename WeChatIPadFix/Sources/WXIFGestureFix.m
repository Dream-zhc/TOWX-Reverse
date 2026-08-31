#import "WXIFGestureFix.h"
#import "WXIFHaptics.h"
#import "WXIFSettings.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const void *WXIFTrackerAssociationKey = &WXIFTrackerAssociationKey;
static const void *WXIFGestureAttachedKey = &WXIFGestureAttachedKey;

@interface WXIFGestureTracker : NSObject
@property (nonatomic, weak) UINavigationController *navigationController;
@property (nonatomic) NSUInteger startDepth;
@property (nonatomic) NSTimeInterval lastImpactTime;
- (void)handleEdgeGesture:(UIGestureRecognizer *)gesture;
@end

@implementation WXIFGestureTracker

- (void)handleEdgeGesture:(UIGestureRecognizer *)gesture {
    UINavigationController *navigationController = self.navigationController;
    if (navigationController == nil) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        self.startDepth = navigationController.viewControllers.count;
        return;
    }

    if (gesture.state != UIGestureRecognizerStateEnded) return;
    NSUInteger expectedDepth = self.startDepth;
    if (expectedDepth < 2) return;

    __weak typeof(self) weakSelf = self;
    void (^checkCompletion)(void) = ^{
        typeof(self) strongSelf = weakSelf;
        UINavigationController *nav = strongSelf.navigationController;
        if (strongSelf == nil || nav == nil) return;
        if (nav.viewControllers.count >= expectedDepth) return;

        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (now - strongSelf.lastImpactTime < 0.45) return;
        strongSelf.lastImpactTime = now;
        [WXIFHaptics emitConfiguredImpact];
    };

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), checkCompletion);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), checkCompletion);
}

@end

static void WXIFCollectEdgeGestures(UIView *view, NSMutableArray<UIGestureRecognizer *> *result) {
    for (UIGestureRecognizer *gesture in view.gestureRecognizers ?: @[]) {
        if ([gesture isKindOfClass:UIScreenEdgePanGestureRecognizer.class]) {
            [result addObject:gesture];
        }
    }
    for (UIView *subview in view.subviews) {
        WXIFCollectEdgeGestures(subview, result);
    }
}

@implementation WXIFGestureFix

+ (void)prepareNavigationController:(UINavigationController *)navigationController {
    if (navigationController == nil || navigationController.viewControllers.count < 2) return;

    WXIFGestureTracker *tracker = objc_getAssociatedObject(navigationController, WXIFTrackerAssociationKey);
    if (tracker == nil) {
        tracker = [WXIFGestureTracker new];
        tracker.navigationController = navigationController;
        objc_setAssociatedObject(navigationController, WXIFTrackerAssociationKey, tracker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    NSMutableArray<UIGestureRecognizer *> *edgeGestures = [NSMutableArray array];
    WXIFCollectEdgeGestures(navigationController.view, edgeGestures);

    UIGestureRecognizer *systemGesture = navigationController.interactivePopGestureRecognizer;
    if (systemGesture != nil && ![edgeGestures containsObject:systemGesture]) {
        [edgeGestures addObject:systemGesture];
    }

    NSUInteger nonSystemEdgeCount = 0;
    for (UIGestureRecognizer *gesture in edgeGestures) {
        if (gesture != systemGesture) nonSystemEdgeCount += 1;
    }

    if ([WXIFSettings gestureEnabled] && systemGesture != nil && nonSystemEdgeCount == 0 && !systemGesture.enabled) {
        systemGesture.enabled = YES;
    }

    if ([WXIFSettings hapticStyle] == WXIFHapticStyleOff) return;

    for (UIGestureRecognizer *gesture in edgeGestures) {
        if ([objc_getAssociatedObject(gesture, WXIFGestureAttachedKey) boolValue]) continue;
        [gesture addTarget:tracker action:@selector(handleEdgeGesture:)];
        objc_setAssociatedObject(gesture, WXIFGestureAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

@end
