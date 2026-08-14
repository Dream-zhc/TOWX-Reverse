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

static CGRect TOWXV11ReadVisualRect(NSString **sourceOut) {
    UIWindow *window = TOWXV11CurrentSessionWindow();
    if (!TOWXV11SessionIsVisible() || !window) {
        if (sourceOut) *sourceOut = @"none";
        return CGRectNull;
    }

    CALayer *presentation = (CALayer *)window.layer.presentationLayer;
    if (presentation) {
        CGRect frame = presentation.frame;
        if (TOWXV11RectFiniteAndUsable(frame)) {
            if (sourceOut) *sourceOut = @"presentation";
            return frame;
        }
    }

    CGRect frame = window.frame;
    if (TOWXV11RectFiniteAndUsable(frame)) {
        if (sourceOut) *sourceOut = @"model";
        return frame;
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
    if (gTOWXV11FollowerEnabled == enabled) return;

    gTOWXV11FollowerEnabled = enabled;
    gTOWXV11DisplayLink.paused = !enabled;
    gTOWXV11HasLastRect = NO;
    gTOWXV11StableFrames = 0;
    gTOWXV11VisualSource = nil;

    if (!enabled && gTOWXV11FollowerTracking) {
        gTOWXV11FollowerTracking = NO;
        TOWXV11DiagLog("FOLLOWER", "TRACKING-END|epoch=%llu|reason=disabled",
                       (unsigned long long)TOWXV11CurrentSessionEpoch());
    }

    TOWXV11DiagLog("FOLLOWER", "%s|epoch=%llu",
                   enabled ? "START" : "STOP",
                   (unsigned long long)TOWXV11CurrentSessionEpoch());
}

BOOL TOWXV11FollowerIsEnabled(void) {
    return gTOWXV11FollowerEnabled;
}

BOOL TOWXV11FollowerIsTracking(void) {
    return gTOWXV11FollowerTracking;
}

CGRect TOWXV11FollowerCurrentVisualRect(void) {
    NSString *source = nil;
    CGRect rect = TOWXV11ReadVisualRect(&source);
    if (!CGRectIsNull(rect)) return rect;
    return gTOWXV11HasLastRect ? gTOWXV11LastRect : CGRectNull;
}

__attribute__((constructor)) static void TOWXV11WindowFollowerInit(void) {
    TOWXV11DiagLog("FOLLOWER", "LOADED|Smooth1-S2|presentation-layer+display-link");
}
