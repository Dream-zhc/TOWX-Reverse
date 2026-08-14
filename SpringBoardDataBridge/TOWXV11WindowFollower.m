#import "TOWXV11WindowFollower.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

#import <QuartzCore/QuartzCore.h>
#include <math.h>

static CADisplayLink *gTOWXV11DisplayLink = nil;
static TOWXV11FollowerUpdateHandler gTOWXV11UpdateHandler = nil;
static BOOL gTOWXV11FollowerEnabled = NO;
static BOOL gTOWXV11FollowerTracking = NO;
static BOOL gTOWXV11HasLastRect = NO;
static CGRect gTOWXV11LastRect = {{0,0},{0,0}};
static NSUInteger gTOWXV11StableFrames = 0;
static NSString *gTOWXV11VisualSource = nil;
static __weak UIView *gTOWXV11GeometryView = nil;
static __weak UIWindow *gTOWXV11GeometryWindow = nil;
static uint64_t gTOWXV11GeometryEpoch = 0;
static BOOL gTOWXV11DiscoveryScheduled = NO;

typedef struct {
    __unsafe_unretained UIView *view;
    __unsafe_unretained UIWindow *window;
    CGRect rect;
    CGFloat score;
    NSUInteger depth;
} TOWXV11GeometryCandidate;

static BOOL TOWXV11RectFiniteAndUsable(CGRect rect) {
    if (!isfinite(rect.origin.x) || !isfinite(rect.origin.y) ||
        !isfinite(rect.size.width) || !isfinite(rect.size.height)) return NO;
    return rect.size.width > 40.0 && rect.size.height > 40.0;
}

static BOOL TOWXV11RectChanged(CGRect a, CGRect b) {
    const CGFloat epsilon = 0.25;
    return fabs(a.origin.x - b.origin.x) > epsilon ||
           fabs(a.origin.y - b.origin.y) > epsilon ||
           fabs(a.size.width - b.size.width) > epsilon ||
           fabs(a.size.height - b.size.height) > epsilon;
}

static NSArray<UIWindow *> *TOWXV11FollowerAllWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in app.windows ?: @[]) if (window) [set addObject:window];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) if (window) [set addObject:window];
    }
    return set.array;
}

static CGRect TOWXV11ModelRectForView(UIView *view, UIWindow *window) {
    if (!view || !window || !window.windowScene) return CGRectNull;
    @try {
        id<UICoordinateSpace> space = window.windowScene.coordinateSpace;
        CGRect rect = [view convertRect:view.bounds toCoordinateSpace:space];
        return TOWXV11RectFiniteAndUsable(rect) ? rect : CGRectNull;
    } @catch (__unused NSException *exception) {
        return CGRectNull;
    }
}

static CGRect TOWXV11PresentationRectForView(UIView *view, UIWindow *window) {
    if (!view || !window || !window.windowScene) return CGRectNull;
    @try {
        CALayer *source = (CALayer *)view.layer.presentationLayer ?: view.layer;
        CALayer *root = (CALayer *)window.layer.presentationLayer ?: window.layer;
        if (source && root) {
            CGRect inWindow = [source convertRect:source.bounds toLayer:root];
            id<UICoordinateSpace> space = window.windowScene.coordinateSpace;
            CGRect screenRect = [window convertRect:inWindow toCoordinateSpace:space];
            if (TOWXV11RectFiniteAndUsable(screenRect)) return screenRect;
        }
    } @catch (__unused NSException *exception) {
    }
    return TOWXV11ModelRectForView(view, window);
}

static void TOWXV11EvaluateGeometryView(UIView *view,
                                        UIWindow *window,
                                        CGRect screenBounds,
                                        NSUInteger depth,
                                        TOWXV11GeometryCandidate *best) {
    if (!view || !window || !best || view.hidden || view.alpha <= 0.01) return;
    if (CGRectGetWidth(view.bounds) < 80.0 || CGRectGetHeight(view.bounds) < 100.0) return;

    CGRect rect = TOWXV11ModelRectForView(view, window);
    if (!TOWXV11RectFiniteAndUsable(rect)) return;
    CGFloat sw = CGRectGetWidth(screenBounds), sh = CGRectGetHeight(screenBounds);
    if (sw < 100.0 || sh < 100.0) return;

    CGFloat wr = CGRectGetWidth(rect) / sw;
    CGFloat hr = CGRectGetHeight(rect) / sh;
    CGFloat areaRatio = (CGRectGetWidth(rect) * CGRectGetHeight(rect)) / (sw * sh);
    CGRect intersection = CGRectIntersection(rect, screenBounds);
    CGFloat visibleArea = CGRectIsNull(intersection) ? 0.0 : CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
    CGFloat rectArea = CGRectGetWidth(rect) * CGRectGetHeight(rect);
    CGFloat visibleRatio = rectArea > 1.0 ? visibleArea / rectArea : 0.0;

    /* The floating content is large but not a full-screen SpringBoard host. */
    if (wr < 0.42 || hr < 0.34 || wr > 0.975 || hr > 0.965 || areaRatio < 0.16 || areaRatio > 0.90 || visibleRatio < 0.80) return;

    CGFloat score = areaRatio * 300.0;
    CGFloat corner = view.layer.cornerRadius;
    score += MIN(corner, 36.0) * 2.0;
    if (view.clipsToBounds || view.layer.masksToBounds) score += 18.0;
    if (!CGAffineTransformIsIdentity(view.transform)) score += 28.0;
    if (depth <= 4) score += 12.0;
    if (![view isKindOfClass:[UIScrollView class]] && ![view isKindOfClass:[UIImageView class]] && ![view isKindOfClass:[UILabel class]]) score += 10.0;

    CGFloat left = CGRectGetMinX(rect) - CGRectGetMinX(screenBounds);
    CGFloat right = CGRectGetMaxX(screenBounds) - CGRectGetMaxX(rect);
    CGFloat top = CGRectGetMinY(rect) - CGRectGetMinY(screenBounds);
    CGFloat bottom = CGRectGetMaxY(screenBounds) - CGRectGetMaxY(rect);
    if (left > 4.0 && right > 4.0 && top > 4.0 && bottom > 4.0) score += 24.0;

    NSString *className = NSStringFromClass(view.class);
    if ([className rangeOfString:@"TOJB"].location != NSNotFound) score += 35.0;
    if ([view isKindOfClass:[UIWindow class]] && view != TOWXV11CurrentSessionWindow()) score += 40.0;

    if (!best->view || score > best->score) {
        best->view = view;
        best->window = window;
        best->rect = rect;
        best->score = score;
        best->depth = depth;
    }
}

static void TOWXV11ScanGeometryTree(UIView *view,
                                    UIWindow *window,
                                    CGRect screenBounds,
                                    NSUInteger depth,
                                    TOWXV11GeometryCandidate *best) {
    if (!view || depth > 10) return;
    TOWXV11EvaluateGeometryView(view, window, screenBounds, depth, best);
    for (UIView *child in view.subviews) {
        TOWXV11ScanGeometryTree(child, window, screenBounds, depth + 1, best);
    }
}

static BOOL TOWXV11DiscoverGeometryAnchor(void) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!TOWXV11SessionIsVisible() || !session || !session.windowScene) return NO;
    CGRect screenBounds = session.windowScene.coordinateSpace.bounds;
    TOWXV11GeometryCandidate best = { nil, nil, CGRectZero, -CGFLOAT_MAX, 0 };

    /* Prefer the active TrollOpen session hierarchy, then other TOJB windows in the same scene. */
    TOWXV11ScanGeometryTree(session, session, screenBounds, 0, &best);
    for (UIWindow *window in TOWXV11FollowerAllWindows()) {
        if (window == session || window.hidden || window.alpha <= 0.01 || window.windowScene != session.windowScene) continue;
        NSString *className = NSStringFromClass(window.class);
        if ([className rangeOfString:@"TOJB"].location == NSNotFound) continue;
        TOWXV11ScanGeometryTree(window, window, screenBounds, 0, &best);
    }

    gTOWXV11GeometryEpoch = TOWXV11CurrentSessionEpoch();
    if (!best.view || !best.window) {
        gTOWXV11GeometryView = nil;
        gTOWXV11GeometryWindow = nil;
        TOWXV11DiagLog("FOLLOWER", "ANCHOR-MISS|epoch=%llu|fallback=session-window",
                       (unsigned long long)gTOWXV11GeometryEpoch);
        return NO;
    }

    gTOWXV11GeometryView = best.view;
    gTOWXV11GeometryWindow = best.window;
    CGRect liveRect = TOWXV11PresentationRectForView(best.view, best.window);
    if (!TOWXV11RectFiniteAndUsable(liveRect)) liveRect = best.rect;
    TOWXV11DiagLog("FOLLOWER", "ANCHOR-FOUND|epoch=%llu|window=%s|view=%s|depth=%lu|score=%.1f|corner=%.1f|rect={{%.1f,%.1f},{%.1f,%.1f}}",
                   (unsigned long long)gTOWXV11GeometryEpoch,
                   NSStringFromClass(best.window.class).UTF8String ?: "?",
                   NSStringFromClass(best.view.class).UTF8String ?: "?",
                   (unsigned long)best.depth,
                   best.score,
                   best.view.layer.cornerRadius,
                   liveRect.origin.x, liveRect.origin.y, liveRect.size.width, liveRect.size.height);
    return YES;
}

static void TOWXV11ScheduleGeometryRediscovery(void) {
    if (gTOWXV11DiscoveryScheduled) return;
    gTOWXV11DiscoveryScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        gTOWXV11DiscoveryScheduled = NO;
        if (!gTOWXV11FollowerEnabled || !TOWXV11SessionIsVisible()) return;
        (void)TOWXV11DiscoverGeometryAnchor();
        gTOWXV11HasLastRect = NO;
    });
}

static CGRect TOWXV11ReadVisualRect(NSString **sourceOut) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!TOWXV11SessionIsVisible() || !session) {
        if (sourceOut) *sourceOut = @"none";
        return CGRectNull;
    }

    uint64_t epoch = TOWXV11CurrentSessionEpoch();
    UIView *geometryView = gTOWXV11GeometryView;
    UIWindow *geometryWindow = gTOWXV11GeometryWindow;
    if (geometryView && geometryWindow && gTOWXV11GeometryEpoch == epoch && geometryView.window) {
        CGRect rect = TOWXV11PresentationRectForView(geometryView, geometryWindow);
        if (TOWXV11RectFiniteAndUsable(rect)) {
            if (sourceOut) *sourceOut = @"floating-container-presentation";
            return rect;
        }
    }

    if (gTOWXV11GeometryEpoch != epoch || !geometryView || !geometryWindow) TOWXV11ScheduleGeometryRediscovery();

    CALayer *presentation = (CALayer *)session.layer.presentationLayer;
    CGRect fallback = presentation ? presentation.frame : session.frame;
    if (TOWXV11RectFiniteAndUsable(fallback)) {
        if (sourceOut) *sourceOut = @"session-fallback";
        return fallback;
    }

    if (sourceOut) *sourceOut = @"invalid";
    return CGRectNull;
}

@interface TOWXV11FollowerDriver : NSObject
+ (instancetype)shared;
- (void)displayLinkTick:(CADisplayLink *)link;
@end

@implementation TOWXV11FollowerDriver
+ (instancetype)shared {
    static TOWXV11FollowerDriver *driver;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ driver = [self new]; });
    return driver;
}

- (void)displayLinkTick:(CADisplayLink *)link {
    (void)link;
    if (!gTOWXV11FollowerEnabled || !TOWXV11SessionIsVisible()) return;

    NSString *source = nil;
    CGRect rect = TOWXV11ReadVisualRect(&source);
    if (CGRectIsNull(rect)) return;

    if (![source isEqualToString:gTOWXV11VisualSource]) {
        gTOWXV11VisualSource = [source copy];
        TOWXV11DiagLog("FOLLOWER", "VISUAL-SOURCE|value=%s|epoch=%llu",
                       source.UTF8String ?: "?",
                       (unsigned long long)TOWXV11CurrentSessionEpoch());
    }

    if (!gTOWXV11HasLastRect) {
        gTOWXV11HasLastRect = YES;
        gTOWXV11LastRect = rect;
        gTOWXV11StableFrames = 0;
        TOWXV11FollowerUpdateHandler handler = gTOWXV11UpdateHandler;
        if (handler) handler(rect, NO);
        return;
    }

    if (TOWXV11RectChanged(gTOWXV11LastRect, rect)) {
        gTOWXV11StableFrames = 0;
        if (!gTOWXV11FollowerTracking) {
            gTOWXV11FollowerTracking = YES;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-BEGIN|epoch=%llu|rect={{%.2f,%.2f},{%.2f,%.2f}}",
                           (unsigned long long)TOWXV11CurrentSessionEpoch(),
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
        }
        gTOWXV11LastRect = rect;
        TOWXV11FollowerUpdateHandler handler = gTOWXV11UpdateHandler;
        if (handler) handler(rect, YES);
        return;
    }

    if (gTOWXV11FollowerTracking) {
        gTOWXV11StableFrames += 1;
        if (gTOWXV11StableFrames >= 8) {
            gTOWXV11FollowerTracking = NO;
            gTOWXV11StableFrames = 0;
            TOWXV11DiagLog("FOLLOWER", "TRACKING-END|epoch=%llu|rect={{%.2f,%.2f},{%.2f,%.2f}}",
                           (unsigned long long)TOWXV11CurrentSessionEpoch(),
                           rect.origin.x, rect.origin.y, rect.size.width, rect.size.height);
            TOWXV11FollowerUpdateHandler handler = gTOWXV11UpdateHandler;
            if (handler) handler(rect, NO);
        }
    }
}
@end

static void TOWXV11EnsureDisplayLink(void) {
    if (gTOWXV11DisplayLink) return;
    gTOWXV11DisplayLink = [CADisplayLink displayLinkWithTarget:[TOWXV11FollowerDriver shared]
                                                     selector:@selector(displayLinkTick:)];
    if (@available(iOS 15.0, *)) {
        NSInteger maximum = UIScreen.mainScreen.maximumFramesPerSecond;
        if (maximum < 60) maximum = 60;
        gTOWXV11DisplayLink.preferredFrameRateRange = CAFrameRateRangeMake(30.0, (float)maximum, (float)maximum);
    }
    [gTOWXV11DisplayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    gTOWXV11DisplayLink.paused = YES;
}

void TOWXV11FollowerSetUpdateHandler(TOWXV11FollowerUpdateHandler handler) {
    NSCAssert(NSThread.isMainThread, @"TOWXV11FollowerSetUpdateHandler must run on main thread");
    gTOWXV11UpdateHandler = [handler copy];
}

void TOWXV11FollowerSetEnabled(BOOL enabled) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11FollowerSetEnabled(enabled); });
        return;
    }

    TOWXV11EnsureDisplayLink();
    if (gTOWXV11FollowerEnabled == enabled) {
        if (enabled && gTOWXV11GeometryEpoch != TOWXV11CurrentSessionEpoch()) {
            (void)TOWXV11DiscoverGeometryAnchor();
            gTOWXV11HasLastRect = NO;
        }
        return;
    }

    gTOWXV11FollowerEnabled = enabled;
    gTOWXV11DisplayLink.paused = !enabled;
    gTOWXV11HasLastRect = NO;
    gTOWXV11StableFrames = 0;
    gTOWXV11VisualSource = nil;

    if (enabled) {
        (void)TOWXV11DiscoverGeometryAnchor();
    } else {
        gTOWXV11GeometryView = nil;
        gTOWXV11GeometryWindow = nil;
        gTOWXV11GeometryEpoch = 0;
    }

    if (!enabled && gTOWXV11FollowerTracking) {
        gTOWXV11FollowerTracking = NO;
        TOWXV11DiagLog("FOLLOWER", "TRACKING-END|epoch=%llu|reason=disabled",
                       (unsigned long long)TOWXV11CurrentSessionEpoch());
    }

    TOWXV11DiagLog("FOLLOWER", "%s|epoch=%llu",
                   enabled ? "START" : "STOP",
                   (unsigned long long)TOWXV11CurrentSessionEpoch());
}

BOOL TOWXV11FollowerIsEnabled(void) { return gTOWXV11FollowerEnabled; }
BOOL TOWXV11FollowerIsTracking(void) { return gTOWXV11FollowerTracking; }

CGRect TOWXV11FollowerCurrentVisualRect(void) {
    if (TOWXV11SessionIsVisible() && gTOWXV11GeometryEpoch != TOWXV11CurrentSessionEpoch()) {
        (void)TOWXV11DiscoverGeometryAnchor();
    }
    NSString *source = nil;
    CGRect rect = TOWXV11ReadVisualRect(&source);
    if (!CGRectIsNull(rect)) return rect;
    return gTOWXV11HasLastRect ? gTOWXV11LastRect : CGRectNull;
}

__attribute__((constructor)) static void TOWXV11WindowFollowerInit(void) {
    TOWXV11DiagLog("FOLLOWER", "LOADED|Smooth1-FIX1|visual-container-presentation+display-link");
}
