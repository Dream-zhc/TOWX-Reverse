#import "TOWXV11WindowFollower.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

#import <QuartzCore/QuartzCore.h>
#include <math.h>

static CADisplayLink *gDisplayLinkFix5 = nil;
static TOWXV11FollowerUpdateHandler gUpdateHandlerFix5 = nil;
static BOOL gEnabledFix5 = NO;
static BOOL gTrackingFix5 = NO;
static BOOL gHasLastRectFix5 = NO;
static CGRect gLastRectFix5 = {{0,0},{0,0}};
static NSUInteger gStableFramesFix5 = 0;
static __weak UIView *gAnchorViewFix5 = nil;
static __weak UIWindow *gAnchorWindowFix5 = nil;
static uint64_t gAnchorEpochFix5 = 0;
static CGSize gAnchorScreenSizeFix5 = {0,0};
static BOOL gAnchorLandscapeFix5 = NO;
static BOOL gInvalidReportedFix5 = NO;
static CFTimeInterval gNextDiscoveryTimeFix5 = 0.0;

typedef struct {
    __unsafe_unretained UIView *view;
    __unsafe_unretained UIWindow *window;
    CGRect rect;
    CGFloat score;
    NSUInteger depth;
} TOWXCandidateFix5;

static BOOL TOWXRectFiniteFix5(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
           isfinite(rect.size.width) && isfinite(rect.size.height) &&
           rect.size.width > 40.0 && rect.size.height > 40.0;
}

static BOOL TOWXRectChangedFix5(CGRect a, CGRect b) {
    const CGFloat epsilon = 0.25;
    return fabs(a.origin.x - b.origin.x) > epsilon ||
           fabs(a.origin.y - b.origin.y) > epsilon ||
           fabs(a.size.width - b.size.width) > epsilon ||
           fabs(a.size.height - b.size.height) > epsilon;
}

static id<UICoordinateSpace> TOWXCoordinateSpaceFix5(UIWindow *window) {
    if (window.screen) return window.screen.coordinateSpace;
    if (window.windowScene) return window.windowScene.coordinateSpace;
    return nil;
}

static CGRect TOWXScreenBoundsFix5(UIWindow *session) {
    id<UICoordinateSpace> coordinateSpace = TOWXCoordinateSpaceFix5(session);
    if (coordinateSpace) return coordinateSpace.bounds;
    if (session.screen) return session.screen.bounds;
    return UIScreen.mainScreen.bounds;
}

static BOOL TOWXLandscapeFix5(UIWindow *session, CGRect screenBounds) {
    BOOL screenLandscape = CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds);
    CGRect sessionFrame = session.frame;
    if (TOWXRectFiniteFix5(sessionFrame)) {
        BOOL frameLandscape = CGRectGetWidth(sessionFrame) > CGRectGetHeight(sessionFrame);
        CGFloat wr = CGRectGetWidth(sessionFrame) / MAX(1.0, CGRectGetWidth(screenBounds));
        CGFloat hr = CGRectGetHeight(sessionFrame) / MAX(1.0, CGRectGetHeight(screenBounds));
        /* TOJBClass022 is normally a near-full-screen control window. Its frame orientation is a
           stronger signal than the stale interfaceOrientation value seen during TrollOpen rotation. */
        if (wr > 0.88 && hr > 0.88) return frameLandscape;
    }
    return screenLandscape;
}

static NSArray<UIWindow *> *TOWXAllWindowsFix5(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in application.windows ?: @[]) {
        if (window) [windows addObject:window];
    }
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (window) [windows addObject:window];
        }
    }
    return windows.array;
}

static CGRect TOWXModelRectFix5(UIView *view, UIWindow *window) {
    id<UICoordinateSpace> coordinateSpace = TOWXCoordinateSpaceFix5(window);
    if (!view || !window || !coordinateSpace) return CGRectNull;
    @try {
        CGRect rect = [view convertRect:view.bounds toCoordinateSpace:coordinateSpace];
        return TOWXRectFiniteFix5(rect) ? rect : CGRectNull;
    } @catch (__unused NSException *exception) {
        return CGRectNull;
    }
}

static CGRect TOWXPresentationRectFix5(UIView *view, UIWindow *window) {
    id<UICoordinateSpace> coordinateSpace = TOWXCoordinateSpaceFix5(window);
    if (!view || !window || !coordinateSpace) return CGRectNull;
    @try {
        if ([view isKindOfClass:[UIWindow class]]) {
            CALayer *presentation = (CALayer *)view.layer.presentationLayer;
            CGRect frame = presentation ? presentation.frame : ((UIWindow *)view).frame;
            if (TOWXRectFiniteFix5(frame)) return frame;
        }

        CALayer *source = (CALayer *)view.layer.presentationLayer ?: view.layer;
        CALayer *root = (CALayer *)window.layer.presentationLayer ?: window.layer;
        if (source && root) {
            CGRect inWindow = [source convertRect:source.bounds toLayer:root];
            CGRect screenRect = [window convertRect:inWindow toCoordinateSpace:coordinateSpace];
            if (TOWXRectFiniteFix5(screenRect)) return screenRect;
        }
    } @catch (__unused NSException *exception) {
    }
    return TOWXModelRectFix5(view, window);
}

static BOOL TOWXLooksMinimizedFix5(CGRect rect, CGRect screenBounds) {
    if (!TOWXRectFiniteFix5(rect)) return YES;
    CGFloat sw = CGRectGetWidth(screenBounds);
    CGFloat sh = CGRectGetHeight(screenBounds);
    if (sw < 100.0 || sh < 100.0) return YES;
    CGFloat wr = CGRectGetWidth(rect) / sw;
    CGFloat hr = CGRectGetHeight(rect) / sh;
    CGFloat area = (CGRectGetWidth(rect) * CGRectGetHeight(rect)) / (sw * sh);
    return wr < 0.10 || hr < 0.16 || area < 0.045;
}

static void TOWXEvaluateFix5(UIView *view,
                             UIWindow *window,
                             CGRect screenBounds,
                             BOOL landscape,
                             NSUInteger depth,
                             TOWXCandidateFix5 *best) {
    if (!view || !window || !best || view.hidden || view.alpha <= 0.02) return;
    if (CGRectGetWidth(view.bounds) < 65.0 || CGRectGetHeight(view.bounds) < 80.0) return;

    CGRect rect = TOWXModelRectFix5(view, window);
    if (!TOWXRectFiniteFix5(rect)) return;

    CGFloat sw = CGRectGetWidth(screenBounds);
    CGFloat sh = CGRectGetHeight(screenBounds);
    CGFloat wr = CGRectGetWidth(rect) / MAX(1.0, sw);
    CGFloat hr = CGRectGetHeight(rect) / MAX(1.0, sh);
    CGFloat area = (CGRectGetWidth(rect) * CGRectGetHeight(rect)) / MAX(1.0, sw * sh);
    CGRect intersection = CGRectIntersection(rect, screenBounds);
    CGFloat visibleArea = CGRectIsNull(intersection) ? 0.0 : CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
    CGFloat visibleRatio = visibleArea / MAX(1.0, CGRectGetWidth(rect) * CGRectGetHeight(rect));

    if (landscape) {
        /* In landscape the actual TrollOpen card can be almost full display height. Width, area,
           TOJB ancestry and rounded presentation geometry distinguish it from the full-screen host. */
        if (wr < 0.08 || wr > 0.78 || hr < 0.25 || hr > 1.15 || area < 0.03 || area > 0.78) return;
    } else {
        if (wr < 0.25 || wr > 0.98 || hr < 0.30 || hr > 1.04 || area < 0.07 || area > 0.90) return;
    }
    if (visibleRatio < 0.50) return;

    NSString *className = NSStringFromClass(view.class);
    CGFloat corner = view.layer.cornerRadius;
    CGFloat targetArea = landscape ? 0.40 : 0.42;
    CGFloat score = 160.0 - fabs(area - targetArea) * 220.0;
    score += MIN(MAX(corner, 0.0), 56.0) * 7.5;
    if (view.clipsToBounds || view.layer.masksToBounds) score += 80.0;
    if ([className rangeOfString:@"_UIScenePresentationView"].location != NSNotFound) score += 220.0;
    if ([className rangeOfString:@"TOJB"].location != NSNotFound) score += 170.0;
    if (!CGAffineTransformIsIdentity(view.transform)) score += 42.0;
    if (![view isKindOfClass:[UIScrollView class]] &&
        ![view isKindOfClass:[UIImageView class]] &&
        ![view isKindOfClass:[UILabel class]]) score += 30.0;
    if (depth >= 1 && depth <= 8) score += 35.0;
    if ([view isKindOfClass:[UIWindow class]]) score -= 55.0;

    if (landscape) {
        if (wr >= 0.12 && wr <= 0.58 && hr >= 0.48) score += 240.0;
        if (hr >= 0.85 && hr <= 1.10 && wr <= 0.58) score += 150.0;
        if (wr > 0.70) score -= 260.0;
    } else {
        if (wr >= 0.38 && wr <= 0.92 && hr >= 0.45) score += 150.0;
    }

    if (!best->view || score > best->score) {
        best->view = view;
        best->window = window;
        best->rect = rect;
        best->score = score;
        best->depth = depth;
    }
}

static void TOWXScanFix5(UIView *view,
                         UIWindow *window,
                         CGRect screenBounds,
                         BOOL landscape,
                         NSUInteger depth,
                         TOWXCandidateFix5 *best) {
    if (!view || depth > 12) return;
    TOWXEvaluateFix5(view, window, screenBounds, landscape, depth, best);
    for (UIView *child in view.subviews) {
        TOWXScanFix5(child, window, screenBounds, landscape, depth + 1, best);
    }
}

static BOOL TOWXDiscoverFix5(void) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!TOWXV11SessionIsVisible() || !session) return NO;

    CGRect screenBounds = TOWXScreenBoundsFix5(session);
    BOOL landscape = TOWXLandscapeFix5(session, screenBounds);
    TOWXCandidateFix5 best = { nil, nil, CGRectZero, -CGFLOAT_MAX, 0 };
    NSArray<UIWindow *> *windows = TOWXAllWindowsFix5();

    TOWXScanFix5(session, session, screenBounds, landscape, 0, &best);
    for (UIWindow *window in windows) {
        if (window == session || window.hidden || window.alpha <= 0.02) continue;
        if (session.screen && window.screen && window.screen != session.screen) continue;
        NSString *windowClass = NSStringFromClass(window.class);
        if ([windowClass rangeOfString:@"TOJB"].location == NSNotFound) continue;
        TOWXScanFix5(window, window, screenBounds, landscape, 0, &best);
    }

    gAnchorEpochFix5 = TOWXV11CurrentSessionEpoch();
    gAnchorScreenSizeFix5 = screenBounds.size;
    gAnchorLandscapeFix5 = landscape;

    if (!best.view || !best.window) {
        gAnchorViewFix5 = nil;
        gAnchorWindowFix5 = nil;
        TOWXV11DiagLog("FOLLOWER",
                       "ANCHOR-MISS|fix=5|epoch=%llu|orientation=%ld|landscape=%d|screen={%.1f,%.1f}|sessionFrame={{%.1f,%.1f},{%.1f,%.1f}}|windows=%lu|policy=fail-closed",
                       (unsigned long long)gAnchorEpochFix5,
                       (long)TOWXV11CurrentSessionOrientation(),
                       landscape ? 1 : 0,
                       screenBounds.size.width, screenBounds.size.height,
                       session.frame.origin.x, session.frame.origin.y,
                       session.frame.size.width, session.frame.size.height,
                       (unsigned long)windows.count);
        return NO;
    }

    gAnchorViewFix5 = best.view;
    gAnchorWindowFix5 = best.window;
    CGRect live = TOWXPresentationRectFix5(best.view, best.window);
    if (!TOWXRectFiniteFix5(live)) live = best.rect;
    TOWXV11DiagLog("FOLLOWER",
                   "ANCHOR-FOUND|fix=5|epoch=%llu|orientation=%ld|landscape=%d|window=%s|view=%s|depth=%lu|score=%.1f|rect={{%.1f,%.1f},{%.1f,%.1f}}|screen={%.1f,%.1f}",
                   (unsigned long long)gAnchorEpochFix5,
                   (long)TOWXV11CurrentSessionOrientation(),
                   landscape ? 1 : 0,
                   NSStringFromClass(best.window.class).UTF8String ?: "?",
                   NSStringFromClass(best.view.class).UTF8String ?: "?",
                   (unsigned long)best.depth,
                   best.score,
                   live.origin.x, live.origin.y, live.size.width, live.size.height,
                   screenBounds.size.width, screenBounds.size.height);
    return YES;
}

static CGRect TOWXReadVisualFix5(void) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!gEnabledFix5 || !TOWXV11SessionIsVisible() || !session) return CGRectNull;

    CGRect screenBounds = TOWXScreenBoundsFix5(session);
    BOOL landscape = TOWXLandscapeFix5(session, screenBounds);
    uint64_t epoch = TOWXV11CurrentSessionEpoch();
    BOOL geometryChanged = gAnchorEpochFix5 != epoch ||
                           gAnchorLandscapeFix5 != landscape ||
                           fabs(gAnchorScreenSizeFix5.width - screenBounds.size.width) > 0.5 ||
                           fabs(gAnchorScreenSizeFix5.height - screenBounds.size.height) > 0.5;

    CFTimeInterval now = CACurrentMediaTime();
    if (geometryChanged || !gAnchorViewFix5 || !gAnchorWindowFix5) {
        if (geometryChanged || now >= gNextDiscoveryTimeFix5) {
            gNextDiscoveryTimeFix5 = now + 0.10;
            (void)TOWXDiscoverFix5();
        }
    }

    UIView *view = gAnchorViewFix5;
    UIWindow *window = gAnchorWindowFix5;
    if (!view || !window || !view.window || view.hidden || view.alpha <= 0.02) {
        if (now >= gNextDiscoveryTimeFix5) {
            gNextDiscoveryTimeFix5 = now + 0.10;
            (void)TOWXDiscoverFix5();
            view = gAnchorViewFix5;
            window = gAnchorWindowFix5;
        }
        if (!view || !window || !view.window || view.hidden || view.alpha <= 0.02) return CGRectNull;
    }

    CGRect rect = TOWXPresentationRectFix5(view, window);
    if (TOWXLooksMinimizedFix5(rect, screenBounds)) {
        TOWXV11DiagLog("FOLLOWER",
                       "VISUAL-LOST|fix=5|reason=minimized|rect={{%.1f,%.1f},{%.1f,%.1f}}|screen={%.1f,%.1f}",
                       rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
                       screenBounds.size.width, screenBounds.size.height);
        return CGRectNull;
    }
    return rect;
}

@interface TOWXV11FollowerDriverFix5 : NSObject
+ (instancetype)shared;
- (void)tick:(CADisplayLink *)link;
@end

@implementation TOWXV11FollowerDriverFix5
+ (instancetype)shared {
    static TOWXV11FollowerDriverFix5 *driver = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ driver = [self new]; });
    return driver;
}

- (void)tick:(CADisplayLink *)link {
    (void)link;
    if (!gEnabledFix5) return;

    CGRect rect = TOWXReadVisualFix5();
    if (CGRectIsNull(rect)) {
        if (!gInvalidReportedFix5) {
            gInvalidReportedFix5 = YES;
            TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix5;
            if (handler) handler(CGRectNull, NO);
        }
        return;
    }
    gInvalidReportedFix5 = NO;

    if (!gHasLastRectFix5) {
        gHasLastRectFix5 = YES;
        gLastRectFix5 = rect;
        gStableFramesFix5 = 0;
        TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix5;
        if (handler) handler(rect, NO);
        return;
    }

    if (TOWXRectChangedFix5(gLastRectFix5, rect)) {
        gStableFramesFix5 = 0;
        if (!gTrackingFix5) {
            gTrackingFix5 = YES;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-BEGIN|fix=5|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        }
        gLastRectFix5 = rect;
        TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix5;
        if (handler) handler(rect, YES);
    } else if (gTrackingFix5) {
        gStableFramesFix5 += 1;
        if (gStableFramesFix5 >= 4) {
            gTrackingFix5 = NO;
            gStableFramesFix5 = 0;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-END|fix=5|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
            TOWXV11FollowerUpdateHandler handler = gUpdateHandlerFix5;
            if (handler) handler(rect, NO);
        }
    }
}
@end

static void TOWXEnsureDisplayLinkFix5(void) {
    if (gDisplayLinkFix5) return;
    gDisplayLinkFix5 = [CADisplayLink displayLinkWithTarget:[TOWXV11FollowerDriverFix5 shared]
                                                   selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) {
        NSInteger maxFPS = UIScreen.mainScreen.maximumFramesPerSecond;
        if (maxFPS < 60) maxFPS = 60;
        gDisplayLinkFix5.preferredFrameRateRange = CAFrameRateRangeMake(30.0, (float)maxFPS, (float)maxFPS);
    }
    [gDisplayLinkFix5 addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    gDisplayLinkFix5.paused = YES;
}

void TOWXV11FollowerSetUpdateHandler(TOWXV11FollowerUpdateHandler handler) {
    gUpdateHandlerFix5 = [handler copy];
}

void TOWXV11FollowerSetEnabled(BOOL enabled) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11FollowerSetEnabled(enabled); });
        return;
    }

    TOWXEnsureDisplayLinkFix5();
    if (gEnabledFix5 == enabled) return;

    gEnabledFix5 = enabled;
    gDisplayLinkFix5.paused = !enabled;
    gHasLastRectFix5 = NO;
    gTrackingFix5 = NO;
    gStableFramesFix5 = 0;
    gInvalidReportedFix5 = NO;
    gNextDiscoveryTimeFix5 = 0.0;

    if (enabled) {
        (void)TOWXDiscoverFix5();
    } else {
        gAnchorViewFix5 = nil;
        gAnchorWindowFix5 = nil;
    }

    TOWXV11DiagLog("FOLLOWER", "%s|fix=5|epoch=%llu",
                   enabled ? "START" : "STOP",
                   (unsigned long long)TOWXV11CurrentSessionEpoch());
}

BOOL TOWXV11FollowerIsEnabled(void) { return gEnabledFix5; }
BOOL TOWXV11FollowerIsTracking(void) { return gTrackingFix5; }
CGRect TOWXV11FollowerCurrentVisualRect(void) { return TOWXReadVisualFix5(); }

__attribute__((constructor)) static void TOWXV11FollowerFix5Marker(void) {
    TOWXV11DiagLog("FOLLOWER",
                   "LOADED|Smooth1-FIX5|screen-coordinate-space+landscape-fullheight-card+presentation+displaylink");
}
