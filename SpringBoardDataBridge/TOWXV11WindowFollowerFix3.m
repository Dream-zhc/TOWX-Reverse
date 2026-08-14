#import "TOWXV11WindowFollower.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

#import <QuartzCore/QuartzCore.h>
#include <math.h>

static CADisplayLink *gDisplayLinkFix3 = nil;
static TOWXV11FollowerUpdateHandler gUpdateHandlerFix3 = nil;
static BOOL gEnabledFix3 = NO;
static BOOL gTrackingFix3 = NO;
static BOOL gHasLastRectFix3 = NO;
static CGRect gLastRectFix3 = {{0,0},{0,0}};
static NSUInteger gStableFramesFix3 = 0;
static __weak UIView *gAnchorViewFix3 = nil;
static __weak UIWindow *gAnchorWindowFix3 = nil;
static uint64_t gAnchorEpochFix3 = 0;
static UIInterfaceOrientation gAnchorOrientationFix3 = UIInterfaceOrientationUnknown;
static CGSize gAnchorScreenSizeFix3 = {0,0};
static BOOL gRediscoveryScheduledFix3 = NO;
static BOOL gInvalidReportedFix3 = NO;

typedef struct {
    __unsafe_unretained UIView *view;
    __unsafe_unretained UIWindow *window;
    CGRect rect;
    CGFloat score;
    NSUInteger depth;
} TOWXCandidateFix3;

static BOOL TOWXRectFiniteFix3(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
           isfinite(rect.size.width) && isfinite(rect.size.height) &&
           rect.size.width > 40.0 && rect.size.height > 40.0;
}

static BOOL TOWXRectChangedFix3(CGRect a, CGRect b) {
    const CGFloat e = 0.25;
    return fabs(a.origin.x-b.origin.x)>e || fabs(a.origin.y-b.origin.y)>e ||
           fabs(a.size.width-b.size.width)>e || fabs(a.size.height-b.size.height)>e;
}

static NSArray<UIWindow *> *TOWXAllWindowsFix3(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in app.windows ?: @[]) if (window) [set addObject:window];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) if (window) [set addObject:window];
    }
    return set.array;
}

static CGRect TOWXModelRectFix3(UIView *view, UIWindow *window) {
    if (!view || !window || !window.windowScene) return CGRectNull;
    @try {
        CGRect rect = [view convertRect:view.bounds toCoordinateSpace:window.windowScene.coordinateSpace];
        return TOWXRectFiniteFix3(rect) ? rect : CGRectNull;
    } @catch (__unused NSException *exception) {
        return CGRectNull;
    }
}

static CGRect TOWXPresentationRectFix3(UIView *view, UIWindow *window) {
    if (!view || !window || !window.windowScene) return CGRectNull;
    @try {
        if ([view isKindOfClass:[UIWindow class]]) {
            CALayer *p = (CALayer *)view.layer.presentationLayer;
            CGRect frame = p ? p.frame : ((UIWindow *)view).frame;
            if (TOWXRectFiniteFix3(frame)) return frame;
        }
        CALayer *source = (CALayer *)view.layer.presentationLayer ?: view.layer;
        CALayer *root = (CALayer *)window.layer.presentationLayer ?: window.layer;
        if (source && root) {
            CGRect inWindow = [source convertRect:source.bounds toLayer:root];
            CGRect screenRect = [window convertRect:inWindow toCoordinateSpace:window.windowScene.coordinateSpace];
            if (TOWXRectFiniteFix3(screenRect)) return screenRect;
        }
    } @catch (__unused NSException *exception) {
    }
    return TOWXModelRectFix3(view, window);
}

static BOOL TOWXIsLandscapeFix3(UIInterfaceOrientation orientation, CGRect bounds) {
    if (UIInterfaceOrientationIsLandscape(orientation)) return YES;
    if (UIInterfaceOrientationIsPortrait(orientation)) return NO;
    return CGRectGetWidth(bounds) > CGRectGetHeight(bounds);
}

static BOOL TOWXLooksMinimizedFix3(CGRect rect, CGRect screenBounds) {
    if (!TOWXRectFiniteFix3(rect)) return YES;
    CGFloat sw = CGRectGetWidth(screenBounds), sh = CGRectGetHeight(screenBounds);
    if (sw < 100.0 || sh < 100.0) return YES;
    CGFloat wr = CGRectGetWidth(rect)/sw, hr = CGRectGetHeight(rect)/sh;
    CGFloat ar = (CGRectGetWidth(rect)*CGRectGetHeight(rect))/(sw*sh);
    return wr < 0.10 || hr < 0.16 || ar < 0.045;
}

static void TOWXEvaluateFix3(UIView *view,
                             UIWindow *window,
                             CGRect screenBounds,
                             BOOL landscape,
                             NSUInteger depth,
                             TOWXCandidateFix3 *best) {
    if (!view || !window || !best || view.hidden || view.alpha <= 0.02) return;
    if (CGRectGetWidth(view.bounds) < 70.0 || CGRectGetHeight(view.bounds) < 90.0) return;
    CGRect rect = TOWXModelRectFix3(view, window);
    if (!TOWXRectFiniteFix3(rect)) return;

    CGFloat sw = CGRectGetWidth(screenBounds), sh = CGRectGetHeight(screenBounds);
    CGFloat wr = CGRectGetWidth(rect)/sw, hr = CGRectGetHeight(rect)/sh;
    CGFloat area = (CGRectGetWidth(rect)*CGRectGetHeight(rect))/(sw*sh);
    CGRect inter = CGRectIntersection(rect, screenBounds);
    CGFloat visibleArea = CGRectIsNull(inter) ? 0.0 : CGRectGetWidth(inter)*CGRectGetHeight(inter);
    CGFloat visibleRatio = visibleArea / MAX(1.0, CGRectGetWidth(rect)*CGRectGetHeight(rect));

    if (landscape) {
        if (wr < 0.11 || wr > 0.78 || hr < 0.32 || hr > 0.995 || area < 0.045 || area > 0.72) return;
    } else {
        if (wr < 0.28 || wr > 0.97 || hr < 0.34 || hr > 0.995 || area < 0.09 || area > 0.88) return;
    }
    if (visibleRatio < 0.64) return;

    NSString *name = NSStringFromClass(view.class);
    CGFloat corner = view.layer.cornerRadius;
    CGFloat targetArea = landscape ? 0.24 : 0.42;
    CGFloat score = 160.0 - fabs(area-targetArea)*260.0;
    score += MIN(MAX(corner,0.0),56.0)*7.5;
    if (view.clipsToBounds || view.layer.masksToBounds) score += 80.0;
    if ([name rangeOfString:@"TOJB"].location != NSNotFound) score += 150.0;
    if (!CGAffineTransformIsIdentity(view.transform)) score += 42.0;
    if (![view isKindOfClass:[UIScrollView class]] && ![view isKindOfClass:[UIImageView class]] && ![view isKindOfClass:[UILabel class]]) score += 30.0;
    if (depth >= 1 && depth <= 7) score += 30.0;
    if ([view isKindOfClass:[UIWindow class]]) score -= 45.0;
    if (area > 0.72) score -= 220.0;

    if (landscape && wr >= 0.14 && wr <= 0.52 && hr >= 0.50) score += 170.0;
    if (!landscape && wr >= 0.42 && wr <= 0.92 && hr >= 0.48) score += 130.0;

    if (!best->view || score > best->score) {
        best->view = view;
        best->window = window;
        best->rect = rect;
        best->score = score;
        best->depth = depth;
    }
}

static void TOWXScanFix3(UIView *view,
                         UIWindow *window,
                         CGRect screenBounds,
                         BOOL landscape,
                         NSUInteger depth,
                         TOWXCandidateFix3 *best) {
    if (!view || depth > 11) return;
    TOWXEvaluateFix3(view, window, screenBounds, landscape, depth, best);
    for (UIView *child in view.subviews) TOWXScanFix3(child, window, screenBounds, landscape, depth+1, best);
}

static BOOL TOWXDiscoverFix3(void) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!TOWXV11SessionIsVisible() || !session || !session.windowScene) return NO;
    CGRect screenBounds = session.windowScene.coordinateSpace.bounds;
    UIInterfaceOrientation orientation = TOWXV11CurrentSessionOrientation();
    BOOL landscape = TOWXIsLandscapeFix3(orientation, screenBounds);
    TOWXCandidateFix3 best = { nil, nil, CGRectZero, -CGFLOAT_MAX, 0 };

    TOWXScanFix3(session, session, screenBounds, landscape, 0, &best);
    for (UIWindow *window in TOWXAllWindowsFix3()) {
        if (window == session || window.hidden || window.alpha <= 0.02 || window.windowScene != session.windowScene) continue;
        NSString *name = NSStringFromClass(window.class);
        if ([name rangeOfString:@"TOJB"].location == NSNotFound) continue;
        TOWXScanFix3(window, window, screenBounds, landscape, 0, &best);
    }

    /* A compact TOJB session window is a safe fallback; a full-screen host is not. */
    CGRect sessionRect = session.frame;
    if (!best.view && TOWXRectFiniteFix3(sessionRect)) {
        CGFloat wr = CGRectGetWidth(sessionRect)/MAX(1.0,CGRectGetWidth(screenBounds));
        CGFloat hr = CGRectGetHeight(sessionRect)/MAX(1.0,CGRectGetHeight(screenBounds));
        if ((landscape && wr < 0.78 && hr < 0.995) || (!landscape && wr < 0.97 && hr < 0.995)) {
            best.view = session;
            best.window = session;
            best.rect = sessionRect;
            best.score = 1.0;
            best.depth = 0;
        }
    }

    gAnchorEpochFix3 = TOWXV11CurrentSessionEpoch();
    gAnchorOrientationFix3 = orientation;
    gAnchorScreenSizeFix3 = screenBounds.size;
    if (!best.view || !best.window) {
        gAnchorViewFix3 = nil;
        gAnchorWindowFix3 = nil;
        TOWXV11DiagLog("FOLLOWER", "ANCHOR-MISS|fix=3|epoch=%llu|orientation=%ld|policy=fail-closed",
                       (unsigned long long)gAnchorEpochFix3, (long)orientation);
        return NO;
    }

    gAnchorViewFix3 = best.view;
    gAnchorWindowFix3 = best.window;
    CGRect live = TOWXPresentationRectFix3(best.view, best.window);
    if (!TOWXRectFiniteFix3(live)) live = best.rect;
    TOWXV11DiagLog("FOLLOWER", "ANCHOR-FOUND|fix=3|epoch=%llu|orientation=%ld|window=%s|view=%s|depth=%lu|score=%.1f|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                   (unsigned long long)gAnchorEpochFix3, (long)orientation,
                   NSStringFromClass(best.window.class).UTF8String ?: "?",
                   NSStringFromClass(best.view.class).UTF8String ?: "?",
                   (unsigned long)best.depth, best.score,
                   live.origin.x, live.origin.y, live.size.width, live.size.height);
    return YES;
}

static void TOWXScheduleRediscoveryFix3(void) {
    if (gRediscoveryScheduledFix3) return;
    gRediscoveryScheduledFix3 = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gRediscoveryScheduledFix3 = NO;
        if (!gEnabledFix3 || !TOWXV11SessionIsVisible()) return;
        (void)TOWXDiscoverFix3();
        gHasLastRectFix3 = NO;
    });
}

static CGRect TOWXReadVisualFix3(void) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!gEnabledFix3 || !TOWXV11SessionIsVisible() || !session || !session.windowScene) return CGRectNull;
    CGRect screenBounds = session.windowScene.coordinateSpace.bounds;
    UIInterfaceOrientation orientation = TOWXV11CurrentSessionOrientation();
    uint64_t epoch = TOWXV11CurrentSessionEpoch();

    if (gAnchorEpochFix3 != epoch || gAnchorOrientationFix3 != orientation ||
        fabs(gAnchorScreenSizeFix3.width-screenBounds.size.width)>0.5 ||
        fabs(gAnchorScreenSizeFix3.height-screenBounds.size.height)>0.5) {
        gAnchorViewFix3 = nil;
        gAnchorWindowFix3 = nil;
        (void)TOWXDiscoverFix3();
    }

    UIView *view = gAnchorViewFix3;
    UIWindow *window = gAnchorWindowFix3;
    if (!view || !window || !view.window || view.hidden || view.alpha <= 0.02) {
        TOWXScheduleRediscoveryFix3();
        return CGRectNull;
    }

    CGRect rect = TOWXPresentationRectFix3(view, window);
    if (TOWXLooksMinimizedFix3(rect, screenBounds)) {
        TOWXV11DiagLog("FOLLOWER", "VISUAL-LOST|fix=3|reason=minimized|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                       rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        return CGRectNull;
    }
    return rect;
}

@interface TOWXV11FollowerDriverFix3 : NSObject
+ (instancetype)shared;
- (void)tick:(CADisplayLink *)link;
@end

@implementation TOWXV11FollowerDriverFix3
+ (instancetype)shared {
    static TOWXV11FollowerDriverFix3 *obj;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ obj = [self new]; });
    return obj;
}
- (void)tick:(CADisplayLink *)link {
    (void)link;
    if (!gEnabledFix3) return;
    CGRect rect = TOWXReadVisualFix3();
    if (CGRectIsNull(rect)) {
        if (!gInvalidReportedFix3) {
            gInvalidReportedFix3 = YES;
            TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix3;
            if (handler) handler(CGRectNull, NO);
        }
        return;
    }
    gInvalidReportedFix3 = NO;

    if (!gHasLastRectFix3) {
        gHasLastRectFix3 = YES;
        gLastRectFix3 = rect;
        gStableFramesFix3 = 0;
        TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix3;
        if (handler) handler(rect, NO);
        return;
    }

    if (TOWXRectChangedFix3(gLastRectFix3, rect)) {
        gStableFramesFix3 = 0;
        if (!gTrackingFix3) {
            gTrackingFix3 = YES;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-BEGIN|fix=3|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        }
        gLastRectFix3 = rect;
        TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix3;
        if (handler) handler(rect, YES);
    } else if (gTrackingFix3) {
        gStableFramesFix3 += 1;
        if (gStableFramesFix3 >= 4) {
            gTrackingFix3 = NO;
            gStableFramesFix3 = 0;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-END|fix=3|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
            TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix3;
            if (handler) handler(rect, NO);
        }
    }
}
@end

static void TOWXEnsureDisplayLinkFix3(void) {
    if (gDisplayLinkFix3) return;
    gDisplayLinkFix3 = [CADisplayLink displayLinkWithTarget:[TOWXV11FollowerDriverFix3 shared] selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) {
        NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond;
        if (maxFPS < 60) maxFPS = 60;
        gDisplayLinkFix3.preferredFrameRateRange = CAFrameRateRangeMake(30.0, (float)maxFPS, (float)maxFPS);
    }
    [gDisplayLinkFix3 addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    gDisplayLinkFix3.paused = YES;
}

void TOWXV11FollowerSetUpdateHandler(TOWXV11FollowerUpdateHandler handler) {
    gUpdateHandlerFix3 = [handler copy];
}

void TOWXV11FollowerSetEnabled(BOOL enabled) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11FollowerSetEnabled(enabled); });
        return;
    }
    TOWXEnsureDisplayLinkFix3();
    if (gEnabledFix3 == enabled) return;
    gEnabledFix3 = enabled;
    gDisplayLinkFix3.paused = !enabled;
    gHasLastRectFix3 = NO;
    gTrackingFix3 = NO;
    gStableFramesFix3 = 0;
    gInvalidReportedFix3 = NO;
    if (enabled) {
        (void)TOWXDiscoverFix3();
    } else {
        gAnchorViewFix3 = nil;
        gAnchorWindowFix3 = nil;
    }
    TOWXV11DiagLog("FOLLOWER", "%s|fix=3|epoch=%llu", enabled ? "START" : "STOP", (unsigned long long)TOWXV11CurrentSessionEpoch());
}

BOOL TOWXV11FollowerIsEnabled(void) { return gEnabledFix3; }
BOOL TOWXV11FollowerIsTracking(void) { return gTrackingFix3; }
CGRect TOWXV11FollowerCurrentVisualRect(void) { return TOWXReadVisualFix3(); }

__attribute__((constructor)) static void TOWXV11FollowerFix3Marker(void) {
    TOWXV11DiagLog("FOLLOWER", "LOADED|Smooth1-FIX3|rotation-rediscovery+landscape-compact+presentation+displaylink");
}
