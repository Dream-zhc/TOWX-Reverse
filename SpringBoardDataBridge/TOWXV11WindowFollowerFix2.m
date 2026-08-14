#import "TOWXV11WindowFollower.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

#import <QuartzCore/QuartzCore.h>
#include <math.h>

static CADisplayLink *gDisplayLink = nil;
static TOWXV11FollowerUpdateHandler gUpdateHandler = nil;
static BOOL gEnabled = NO;
static BOOL gTracking = NO;
static BOOL gHasLastRect = NO;
static BOOL gReportedLost = NO;
static CGRect gLastRect = {{0,0},{0,0}};
static NSUInteger gStableFrames = 0;
static NSString *gVisualSource = nil;
static __weak UIView *gGeometryView = nil;
static __weak UIWindow *gGeometryWindow = nil;
static uint64_t gGeometryEpoch = 0;
static BOOL gDiscoveryScheduled = NO;

typedef struct {
    __unsafe_unretained UIView *view;
    __unsafe_unretained UIWindow *window;
    CGRect rect;
    CGFloat score;
    NSUInteger depth;
} TOWXV11GeometryCandidateFix2;

static BOOL TOWXRectFinite(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
           isfinite(rect.size.width) && isfinite(rect.size.height);
}

static BOOL TOWXRectUsable(CGRect rect) {
    return TOWXRectFinite(rect) && rect.size.width > 40.0 && rect.size.height > 40.0;
}

static BOOL TOWXRectChanged(CGRect a, CGRect b) {
    const CGFloat epsilon = 0.20;
    return fabs(a.origin.x - b.origin.x) > epsilon ||
           fabs(a.origin.y - b.origin.y) > epsilon ||
           fabs(a.size.width - b.size.width) > epsilon ||
           fabs(a.size.height - b.size.height) > epsilon;
}

static NSArray<UIWindow *> *TOWXAllWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in app.windows ?: @[]) if (window) [set addObject:window];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) if (window) [set addObject:window];
    }
    return set.array;
}

static CGRect TOWXScreenBounds(UIWindow *window) {
    if (window.windowScene) return window.windowScene.coordinateSpace.bounds;
    return window.screen ? window.screen.bounds : UIScreen.mainScreen.bounds;
}

static CGRect TOWXModelRect(UIView *view, UIWindow *window) {
    if (!view || !window || !window.windowScene) return CGRectNull;
    @try {
        CGRect rect = [view convertRect:view.bounds toCoordinateSpace:window.windowScene.coordinateSpace];
        return TOWXRectUsable(rect) ? rect : CGRectNull;
    } @catch (__unused NSException *exception) {
        return CGRectNull;
    }
}

static CGRect TOWXPresentationRect(UIView *view, UIWindow *window) {
    if (!view || !window || !window.windowScene) return CGRectNull;
    @try {
        CALayer *source = (CALayer *)view.layer.presentationLayer ?: view.layer;
        CALayer *root = (CALayer *)window.layer.presentationLayer ?: window.layer;
        if (source && root) {
            CGRect inWindow = [source convertRect:source.bounds toLayer:root];
            CGRect screenRect = [window convertRect:inWindow toCoordinateSpace:window.windowScene.coordinateSpace];
            if (TOWXRectUsable(screenRect)) return screenRect;
        }
    } @catch (__unused NSException *exception) {
    }
    return TOWXModelRect(view, window);
}

static BOOL TOWXViewVisuallyPresent(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha <= 0.02) return NO;
    CALayer *presentation = (CALayer *)view.layer.presentationLayer;
    if (presentation && presentation.opacity <= 0.03f) return NO;
    return YES;
}

static BOOL TOWXRectLooksMinimized(CGRect rect, CGRect screenBounds) {
    if (!TOWXRectUsable(rect)) return YES;
    CGFloat sw = CGRectGetWidth(screenBounds), sh = CGRectGetHeight(screenBounds);
    if (sw < 100.0 || sh < 100.0) return YES;
    CGFloat wr = CGRectGetWidth(rect) / sw;
    CGFloat hr = CGRectGetHeight(rect) / sh;
    CGFloat area = CGRectGetWidth(rect) * CGRectGetHeight(rect);
    CGFloat screenArea = sw * sh;
    CGFloat ar = screenArea > 1.0 ? area / screenArea : 0.0;
    return wr < 0.115 || hr < 0.185 || ar < 0.055;
}

static void TOWXEvaluate(UIView *view,
                         UIWindow *window,
                         CGRect screenBounds,
                         BOOL landscape,
                         NSUInteger depth,
                         TOWXV11GeometryCandidateFix2 *best) {
    if (!view || !window || !best || view.hidden || view.alpha <= 0.02) return;
    if (CGRectGetWidth(view.bounds) < 80.0 || CGRectGetHeight(view.bounds) < 100.0) return;

    CGRect rect = TOWXModelRect(view, window);
    if (!TOWXRectUsable(rect)) return;
    CGFloat sw = CGRectGetWidth(screenBounds), sh = CGRectGetHeight(screenBounds);
    if (sw < 100.0 || sh < 100.0) return;

    CGFloat wr = CGRectGetWidth(rect) / sw;
    CGFloat hr = CGRectGetHeight(rect) / sh;
    CGFloat areaRatio = (CGRectGetWidth(rect) * CGRectGetHeight(rect)) / (sw * sh);
    CGRect intersection = CGRectIntersection(rect, screenBounds);
    CGFloat visibleArea = CGRectIsNull(intersection) ? 0.0 : CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
    CGFloat rectArea = CGRectGetWidth(rect) * CGRectGetHeight(rect);
    CGFloat visibleRatio = rectArea > 1.0 ? visibleArea / rectArea : 0.0;

    /* Landscape TrollOpen windows can be narrow (~20% screen width), so never use the old 42% minimum. */
    if (wr < 0.145 || hr < 0.28 || wr > 0.965 || hr > 0.985 ||
        areaRatio < 0.065 || areaRatio > 0.86 || visibleRatio < 0.72) return;

    NSString *className = NSStringFromClass(view.class);
    CGFloat corner = view.layer.cornerRadius;
    CGFloat score = 0.0;

    score += MIN(MAX(corner, 0.0), 52.0) * 7.0;
    if (view.clipsToBounds || view.layer.masksToBounds) score += 72.0;
    if ([className rangeOfString:@"TOJB"].location != NSNotFound) score += 130.0;
    if (!CGAffineTransformIsIdentity(view.transform)) score += 48.0;
    if (![view isKindOfClass:[UIScrollView class]] && ![view isKindOfClass:[UIImageView class]] && ![view isKindOfClass:[UILabel class]]) score += 36.0;

    /* Prefer a floating-card sized surface instead of a full-screen host. */
    score += MAX(0.0, 125.0 - fabs(areaRatio - 0.34) * 260.0);
    if (areaRatio > 0.72) score -= 160.0;
    if ([view isKindOfClass:[UIWindow class]]) score -= 70.0;

    if (landscape) {
        if (wr >= 0.16 && wr <= 0.58 && hr >= 0.52 && hr <= 0.98) score += 150.0;
        if (wr > 0.72) score -= 130.0;
    } else {
        if (wr >= 0.45 && wr <= 0.94 && hr >= 0.42 && hr <= 0.96) score += 120.0;
    }

    CGFloat left = CGRectGetMinX(rect) - CGRectGetMinX(screenBounds);
    CGFloat right = CGRectGetMaxX(screenBounds) - CGRectGetMaxX(rect);
    CGFloat top = CGRectGetMinY(rect) - CGRectGetMinY(screenBounds);
    CGFloat bottom = CGRectGetMaxY(screenBounds) - CGRectGetMaxY(rect);
    if (left > 3.0 || right > 3.0) score += 18.0;
    if (top > 3.0 || bottom > 3.0) score += 18.0;
    if (depth >= 1 && depth <= 6) score += 32.0;
    if (depth > 9) score -= 45.0;

    if (!best->view || score > best->score) {
        best->view = view;
        best->window = window;
        best->rect = rect;
        best->score = score;
        best->depth = depth;
    }
}

static void TOWXScan(UIView *view,
                     UIWindow *window,
                     CGRect screenBounds,
                     BOOL landscape,
                     NSUInteger depth,
                     TOWXV11GeometryCandidateFix2 *best) {
    if (!view || depth > 12) return;
    TOWXEvaluate(view, window, screenBounds, landscape, depth, best);
    for (UIView *child in view.subviews) TOWXScan(child, window, screenBounds, landscape, depth + 1, best);
}

static BOOL TOWXDiscover(void) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!TOWXV11SessionIsVisible() || !session || !session.windowScene) return NO;
    CGRect screenBounds = TOWXScreenBounds(session);
    BOOL landscape = CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds);
    TOWXV11GeometryCandidateFix2 best = { nil, nil, CGRectZero, -CGFLOAT_MAX, 0 };

    TOWXScan(session, session, screenBounds, landscape, 0, &best);
    for (UIWindow *window in TOWXAllWindows()) {
        if (window == session || window.hidden || window.alpha <= 0.02 || window.windowScene != session.windowScene) continue;
        NSString *name = NSStringFromClass(window.class);
        if ([name rangeOfString:@"TOJB"].location == NSNotFound) continue;
        TOWXScan(window, window, screenBounds, landscape, 0, &best);
    }

    gGeometryEpoch = TOWXV11CurrentSessionEpoch();
    if (!best.view || !best.window) {
        gGeometryView = nil;
        gGeometryWindow = nil;
        TOWXV11DiagLog("FOLLOWER", "ANCHOR-MISS|epoch=%llu|policy=fail-closed-no-session-frame",
                       (unsigned long long)gGeometryEpoch);
        return NO;
    }

    gGeometryView = best.view;
    gGeometryWindow = best.window;
    CGRect liveRect = TOWXPresentationRect(best.view, best.window);
    if (!TOWXRectUsable(liveRect)) liveRect = best.rect;
    TOWXV11DiagLog("FOLLOWER", "ANCHOR-FOUND|fix=2|epoch=%llu|window=%s|view=%s|depth=%lu|score=%.1f|corner=%.1f|rect={{%.1f,%.1f},{%.1f,%.1f}}|screen={{%.1f,%.1f}}",
                   (unsigned long long)gGeometryEpoch,
                   NSStringFromClass(best.window.class).UTF8String ?: "?",
                   NSStringFromClass(best.view.class).UTF8String ?: "?",
                   (unsigned long)best.depth,
                   best.score,
                   best.view.layer.cornerRadius,
                   liveRect.origin.x, liveRect.origin.y, liveRect.size.width, liveRect.size.height,
                   screenBounds.size.width, screenBounds.size.height);
    return YES;
}

static void TOWXScheduleDiscovery(void) {
    if (gDiscoveryScheduled) return;
    gDiscoveryScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gDiscoveryScheduled = NO;
        if (!gEnabled || !TOWXV11SessionIsVisible()) return;
        (void)TOWXDiscover();
        gHasLastRect = NO;
    });
}

static void TOWXScheduleSettlingDiscoveries(void) {
    const uint64_t delaysMs[] = { 24, 90, 220 };
    uint64_t epoch = TOWXV11CurrentSessionEpoch();
    for (NSUInteger i = 0; i < sizeof(delaysMs) / sizeof(delaysMs[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaysMs[i] * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (!gEnabled || epoch != TOWXV11CurrentSessionEpoch() || !TOWXV11SessionIsVisible()) return;
            if (!gGeometryView || !TOWXViewVisuallyPresent(gGeometryView)) {
                (void)TOWXDiscover();
                gHasLastRect = NO;
            }
        });
    }
}

static CGRect TOWXReadRect(NSString **sourceOut) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!TOWXV11SessionIsVisible() || !session) {
        if (sourceOut) *sourceOut = @"session-gone";
        return CGRectNull;
    }

    uint64_t epoch = TOWXV11CurrentSessionEpoch();
    UIView *view = gGeometryView;
    UIWindow *window = gGeometryWindow;
    if (!view || !window || gGeometryEpoch != epoch) {
        TOWXScheduleDiscovery();
        if (sourceOut) *sourceOut = @"anchor-pending";
        return CGRectNull;
    }

    if (!TOWXViewVisuallyPresent(view)) {
        if (sourceOut) *sourceOut = @"anchor-hidden";
        return CGRectNull;
    }

    CGRect rect = TOWXPresentationRect(view, window);
    CGRect screenBounds = TOWXScreenBounds(session);
    if (!TOWXRectUsable(rect)) {
        if (sourceOut) *sourceOut = @"anchor-invalid";
        return CGRectNull;
    }
    if (TOWXRectLooksMinimized(rect, screenBounds)) {
        if (sourceOut) *sourceOut = @"anchor-minimized";
        return CGRectNull;
    }

    if (sourceOut) *sourceOut = @"floating-container-presentation";
    return rect;
}

@interface TOWXV11FollowerDriverFix2 : NSObject
+ (instancetype)shared;
- (void)tick:(CADisplayLink *)link;
@end

@implementation TOWXV11FollowerDriverFix2
+ (instancetype)shared {
    static TOWXV11FollowerDriverFix2 *driver;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ driver = [self new]; });
    return driver;
}

- (void)tick:(CADisplayLink *)link {
    (void)link;
    if (!gEnabled) return;

    NSString *source = nil;
    CGRect rect = TOWXReadRect(&source);
    if (![source isEqualToString:gVisualSource]) {
        gVisualSource = [source copy];
        TOWXV11DiagLog("FOLLOWER", "VISUAL-SOURCE|fix=2|value=%s|epoch=%llu",
                       source.UTF8String ?: "?", (unsigned long long)TOWXV11CurrentSessionEpoch());
    }

    if (CGRectIsNull(rect)) {
        if (!gReportedLost) {
            gReportedLost = YES;
            gHasLastRect = NO;
            gStableFrames = 0;
            if (gTracking) {
                gTracking = NO;
                TOWXV11DiagLog("FOLLOWER", "TRACKING-END|reason=visual-lost|epoch=%llu",
                               (unsigned long long)TOWXV11CurrentSessionEpoch());
            }
            TOWXV11DiagLog("FOLLOWER", "VISUAL-LOST|source=%s|epoch=%llu|action=hard-hide",
                           source.UTF8String ?: "?", (unsigned long long)TOWXV11CurrentSessionEpoch());
            TOWXV11FollowerUpdateHandler handler = gUpdateHandler;
            if (handler) handler(CGRectNull, NO);
        }
        return;
    }

    gReportedLost = NO;
    if (!gHasLastRect) {
        gHasLastRect = YES;
        gLastRect = rect;
        gStableFrames = 0;
        TOWXV11FollowerUpdateHandler handler = gUpdateHandler;
        if (handler) handler(rect, NO);
        return;
    }

    if (TOWXRectChanged(gLastRect, rect)) {
        gStableFrames = 0;
        if (!gTracking) {
            gTracking = YES;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-BEGIN|fix=2|epoch=%llu|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                           (unsigned long long)TOWXV11CurrentSessionEpoch(), rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        }
        gLastRect = rect;
        TOWXV11FollowerUpdateHandler handler = gUpdateHandler;
        if (handler) handler(rect, YES);
        return;
    }

    if (gTracking) {
        if (++gStableFrames >= 3) {
            gTracking = NO;
            gStableFrames = 0;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-END|fix=2|epoch=%llu|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                           (unsigned long long)TOWXV11CurrentSessionEpoch(), rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
            TOWXV11FollowerUpdateHandler handler = gUpdateHandler;
            if (handler) handler(rect, NO);
        }
    }
}
@end

static void TOWXEnsureDisplayLink(void) {
    if (gDisplayLink) return;
    gDisplayLink = [CADisplayLink displayLinkWithTarget:[TOWXV11FollowerDriverFix2 shared] selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) {
        NSInteger maximum = UIScreen.mainScreen.maximumFramesPerSecond;
        if (maximum < 60) maximum = 60;
        gDisplayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, (float)maximum, (float)maximum);
    }
    [gDisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    gDisplayLink.paused = YES;
}

void TOWXV11FollowerSetUpdateHandler(TOWXV11FollowerUpdateHandler handler) {
    NSCAssert(NSThread.isMainThread, @"Follower handler must be set on main thread");
    gUpdateHandler = [handler copy];
}

void TOWXV11FollowerSetEnabled(BOOL enabled) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11FollowerSetEnabled(enabled); });
        return;
    }
    TOWXEnsureDisplayLink();
    if (gEnabled == enabled) return;
    gEnabled = enabled;
    gDisplayLink.paused = !enabled;
    gHasLastRect = NO;
    gReportedLost = NO;
    gStableFrames = 0;
    gVisualSource = nil;

    if (enabled) {
        (void)TOWXDiscover();
        TOWXScheduleSettlingDiscoveries();
    } else {
        if (gTracking) TOWXV11DiagLog("FOLLOWER", "TRACKING-END|reason=disabled|epoch=%llu", (unsigned long long)TOWXV11CurrentSessionEpoch());
        gTracking = NO;
        gGeometryView = nil;
        gGeometryWindow = nil;
        gGeometryEpoch = 0;
    }
    TOWXV11DiagLog("FOLLOWER", "%s|fix=2|epoch=%llu", enabled ? "START" : "STOP", (unsigned long long)TOWXV11CurrentSessionEpoch());
}

BOOL TOWXV11FollowerIsEnabled(void) { return gEnabled; }
BOOL TOWXV11FollowerIsTracking(void) { return gTracking; }

CGRect TOWXV11FollowerCurrentVisualRect(void) {
    NSString *source = nil;
    return TOWXReadRect(&source);
}

__attribute__((constructor)) static void TOWXV11FollowerFix2Marker(void) {
    TOWXV11DiagLog("FOLLOWER", "LOADED|Smooth1-FIX2|compact-anchor+fail-closed+minimize-hard-hide+3-frame-settle");
}
