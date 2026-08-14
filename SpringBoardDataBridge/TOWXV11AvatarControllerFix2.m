#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

#import "TOWXV11SessionController.h"
#import "TOWXV11WindowFollower.h"
#import "TOWXV11PlacementEngine.h"
#import "TOWXV11AvatarView.h"
#import "TOWXV11AnimationController.h"
#import "TOWXV11DataController.h"
#import "TOWXV11Gate.h"
#import "TOWXV11HostContext.h"
#import "TOWXV11KeyboardState.h"
#import "TOWXV11Diagnostics.h"

@interface TOWXV11OverlayRootControllerFix2 : UIViewController
@end
@implementation TOWXV11OverlayRootControllerFix2
- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    view.userInteractionEnabled = YES;
    self.view = view;
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

@interface TOWXV11OverlayWindowFix2 : UIWindow
@end
@implementation TOWXV11OverlayWindowFix2
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static TOWXV11OverlayWindowFix2 *gOverlayWindow = nil;
static TOWXV11AvatarView *gAvatarView = nil;
static TOWXV11AnimationController *gAnimationController = nil;
static UIViewPropertyAnimator *gRepositionAnimator = nil;
static TOWXV11AvatarPlacementMode gPlacementMode = TOWXV11AvatarPlacementHidden;
static CGRect gLastPlacementFrame = {{0,0},{0,0}};
static BOOL gShouldShow = NO;
static uint64_t gVisibilitySerial = 0;
static BOOL gLastGateShow = NO;
static NSString *gLastGateSession = nil;
static NSString *gLastGateHost = nil;
static NSString *gLastGateReason = nil;
static NSUInteger gLastGateCount = NSNotFound;

static BOOL TOWXFrameUsable(CGRect frame) {
    return !CGRectIsNull(frame) && !CGRectIsEmpty(frame) &&
           isfinite(frame.origin.x) && isfinite(frame.origin.y) &&
           isfinite(frame.size.width) && isfinite(frame.size.height) &&
           frame.size.width > 20.0 && frame.size.height > 20.0;
}

static CGRect TOWXScreenBounds(UIWindow *session) {
    if (session.screen) return session.screen.coordinateSpace.bounds;
    if (session.windowScene) return session.windowScene.coordinateSpace.bounds;
    return UIScreen.mainScreen.coordinateSpace.bounds;
}

static TOWXV11AvatarPlacement TOWXPlacementForRect(CGRect visualRect) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    return TOWXV11ComputeAvatarPlacement(visualRect,
                                         TOWXScreenBounds(session),
                                         UIEdgeInsetsZero,
                                         TOWXV11CurrentSessionOrientation(),
                                         TOWXV11DataAvatarCount());
}

static void TOWXStopReposition(const char *reason) {
    if (!gRepositionAnimator) return;
    [gRepositionAnimator stopAnimation:YES];
    gRepositionAnimator = nil;
    TOWXV11DiagLog("PLACEMENT", "REPOSITION-INTERRUPT|fix=2|reason=%s", reason ?: "?");
}

static void TOWXSetOverlayFrameDirect(CGRect frame) {
    if (!gOverlayWindow || !TOWXFrameUsable(frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gOverlayWindow.frame = frame;
    [CATransaction commit];
    gLastPlacementFrame = frame;
}

static void TOWXSetOverlayFrameAnimated(CGRect frame, TOWXV11AvatarPlacementMode mode) {
    if (!gOverlayWindow || !TOWXFrameUsable(frame)) return;
    TOWXStopReposition("new-reposition");
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.90];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.24 timingParameters:timing];
    TOWXV11DiagLog("PLACEMENT", "REPOSITION-BEGIN|fix=2|mode=%s|to={{%.1f,%.1f},{%.1f,%.1f}}",
                   TOWXV11PlacementModeName(mode), frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    [animator addAnimations:^{ gOverlayWindow.frame = frame; }];
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        if (gRepositionAnimator != animator) return;
        gRepositionAnimator = nil;
        gLastPlacementFrame = frame;
        TOWXV11DiagLog("PLACEMENT", "REPOSITION-END|fix=2|mode=%s|position=%ld", TOWXV11PlacementModeName(mode), (long)position);
    }];
    gRepositionAnimator = animator;
    [animator startAnimation];
}

static void TOWXApplyPlacement(TOWXV11AvatarPlacement placement, BOOL tracking, BOOL animateModeChange) {
    if (!gOverlayWindow || placement.mode == TOWXV11AvatarPlacementHidden || !TOWXFrameUsable(placement.frame)) return;
    BOOL modeChanged = gPlacementMode != placement.mode;
    if (modeChanged) {
        TOWXV11DiagLog("PLACEMENT", "MODE|fix=2|from=%s|to=%s|tracking=%d|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                       TOWXV11PlacementModeName(gPlacementMode), TOWXV11PlacementModeName(placement.mode),
                       tracking ? 1 : 0,
                       placement.frame.origin.x, placement.frame.origin.y, placement.frame.size.width, placement.frame.size.height);
        gPlacementMode = placement.mode;
        gAvatarView.vertical = placement.vertical;
    }

    BOOL changed = !CGRectEqualToRect(gLastPlacementFrame, placement.frame);
    if (!changed) return;

    if (tracking) {
        TOWXStopReposition("follower-tracking");
        TOWXSetOverlayFrameDirect(placement.frame);
    } else if (modeChanged && animateModeChange && !gOverlayWindow.hidden) {
        TOWXSetOverlayFrameAnimated(placement.frame, placement.mode);
    } else {
        TOWXSetOverlayFrameDirect(placement.frame);
    }
}

static void TOWXHardHideOverlay(const char *reason) {
    gVisibilitySerial += 1;
    TOWXStopReposition("hard-hide");
    if (gAnimationController) [gAnimationController setHiddenImmediately];
    if (gAvatarView) gAvatarView.userInteractionEnabled = NO;
    if (gOverlayWindow && !gOverlayWindow.hidden) {
        gOverlayWindow.hidden = YES;
        TOWXV11DiagLog("OVERLAY", "HARD-HIDE|fix=6|reason=%s|serial=%llu",
                       reason ?: "?", (unsigned long long)gVisibilitySerial);
    }
}

static void TOWXDestroyOverlay(void) {
    TOWXHardHideOverlay("destroy");
    if (gOverlayWindow) gOverlayWindow.rootViewController = nil;
    gOverlayWindow = nil;
    gAvatarView = nil;
    gAnimationController = nil;
    gPlacementMode = TOWXV11AvatarPlacementHidden;
    gLastPlacementFrame = CGRectZero;
}

static void TOWXEnsureOverlay(UIWindow *session) {
    if (!session || !session.windowScene) return;
    if (gOverlayWindow && gOverlayWindow.windowScene != session.windowScene) TOWXDestroyOverlay();
    if (gOverlayWindow) {
        gOverlayWindow.windowLevel = session.windowLevel + 2.0;
        return;
    }

    TOWXV11OverlayWindowFix2 *window = [[TOWXV11OverlayWindowFix2 alloc] initWithWindowScene:session.windowScene];
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.windowLevel = session.windowLevel + 2.0;
    window.hidden = YES;
    window.userInteractionEnabled = YES;

    TOWXV11OverlayRootControllerFix2 *root = [TOWXV11OverlayRootControllerFix2 new];
    window.rootViewController = root;
    (void)root.view;

    TOWXV11AvatarView *avatarView = [[TOWXV11AvatarView alloc] initWithFrame:root.view.bounds];
    avatarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    avatarView.userInteractionEnabled = YES;
    [root.view addSubview:avatarView];
    avatarView.tapHandler = ^(NSUInteger index) { TOWXV11DataSendOpen(index); };

    gOverlayWindow = window;
    gAvatarView = avatarView;
    gAnimationController = [[TOWXV11AnimationController alloc] initWithView:avatarView];
    gPlacementMode = TOWXV11AvatarPlacementHidden;
    gLastPlacementFrame = CGRectZero;
    TOWXV11DiagLog("OVERLAY", "CREATE|fix=6|window=%p|scene=%p|level=%.1f|edgeShield=10", window, session.windowScene, window.windowLevel);
}

static void TOWXApplyData(BOOL animated) {
    if (!gAvatarView) return;
    [gAvatarView applyImages:TOWXV11DataAvatarImages()
                       count:TOWXV11DataAvatarCount()
               selectedIndex:TOWXV11DataSelectedIndex()
                    animated:animated];
}

static void TOWXLogGate(BOOL show, const char *reason) {
    NSString *session = TOWXV11CurrentSessionBundleIdentifier() ?: @"";
    NSString *host = TOWXV11HostBundleIdentifier() ?: @"";
    NSString *r = reason ? [NSString stringWithUTF8String:reason] : @"?";
    NSUInteger count = TOWXV11DataAvatarCount();
    if (gLastGateShow == show && [gLastGateSession isEqualToString:session] && [gLastGateHost isEqualToString:host] && [gLastGateReason isEqualToString:r] && gLastGateCount == count) return;
    gLastGateShow = show;
    gLastGateSession = [session copy];
    gLastGateHost = [host copy];
    gLastGateReason = [r copy];
    gLastGateCount = count;
    TOWXV11DiagLog("GATE", "STATE|fix=6|show=%d|reason=%s|session=%s|host=%s|hostSource=%s|wechatActive=%d|keyboard=%d|keyboardSource=%s|count=%lu|epoch=%llu",
                   show ? 1 : 0, reason ?: "?",
                   session.length ? session.UTF8String : "?",
                   host.length ? host.UTF8String : "?",
                   TOWXV11HostBundleSource().UTF8String ?: "?",
                   TOWXV11DataWeChatActive() ? 1 : 0,
                   TOWXV11KeyboardVisible() ? 1 : 0,
                   TOWXV11KeyboardSource().UTF8String ?: "?",
                   (unsigned long)count,
                   (unsigned long long)TOWXV11CurrentSessionEpoch());
}

static void TOWXShowAtRect(CGRect visualRect, BOOL tracking, BOOL animateIfHidden, const char *reason) {
    if (!gShouldShow || TOWXV11KeyboardVisible() || !TOWXFrameUsable(visualRect)) return;
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!session) return;
    TOWXEnsureOverlay(session);
    if (!gOverlayWindow || !gAvatarView) return;

    TOWXV11AvatarPlacement placement = TOWXPlacementForRect(visualRect);
    if (placement.mode == TOWXV11AvatarPlacementHidden || !TOWXFrameUsable(placement.frame)) return;
    TOWXApplyPlacement(placement, tracking, !tracking);

    BOOL wasHidden = gOverlayWindow.hidden;
    if (wasHidden) {
        gOverlayWindow.hidden = NO;
        gAvatarView.userInteractionEnabled = YES;
        if (animateIfHidden) [gAnimationController showFromPlacementMode:placement.mode completion:nil];
        else [gAnimationController setVisibleImmediately];
        TOWXV11DiagLog("OVERLAY", "SHOW|fix=6|reason=%s|mode=%s|anchor={{%.1f,%.1f},{%.1f,%.1f}}|frame={{%.1f,%.1f},{%.1f,%.1f}}|edgeShield=10",
                       reason ?: "?", TOWXV11PlacementModeName(placement.mode),
                       visualRect.origin.x, visualRect.origin.y, visualRect.size.width, visualRect.size.height,
                       placement.frame.origin.x, placement.frame.origin.y, placement.frame.size.width, placement.frame.size.height);
    }
}

static void TOWXSyncController(const char *reason) {
    if (!NSThread.isMainThread) {
        NSString *copy = reason ? [NSString stringWithUTF8String:reason] : @"async";
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXSyncController(copy.UTF8String); });
        return;
    }

    UIWindow *session = TOWXV11CurrentSessionWindow();
    const char *gateReason = NULL;
    BOOL show = TOWXV11ShouldShowAvatarModule(TOWXV11SessionIsVisible(),
                                              TOWXV11CurrentSessionBundleIdentifier(),
                                              TOWXV11HostBundleIdentifier(),
                                              TOWXV11DataWeChatActive(),
                                              TOWXV11DataAvatarCount(),
                                              &gateReason);
    if (TOWXV11SessionIsVisible() && TOWXV11KeyboardVisible()) {
        show = NO;
        gateReason = "keyboard-visible";
    }
    TOWXLogGate(show, gateReason);
    gShouldShow = show;
    gVisibilitySerial += 1;
    uint64_t serial = gVisibilitySerial;

    if (!show || !session) {
        TOWXV11FollowerSetEnabled(NO);
        if (TOWXV11KeyboardVisible()) {
            TOWXHardHideOverlay("keyboard-visible");
            return;
        }
        if (!session || (reason && strcmp(reason, "session-end") == 0)) {
            TOWXHardHideOverlay(reason ?: "session-gone");
            return;
        }
        if (gOverlayWindow && !gOverlayWindow.hidden) {
            [gAnimationController hideTowardPlacementMode:gPlacementMode completion:^(BOOL finished) {
                if (!finished || serial != gVisibilitySerial || gShouldShow) return;
                gOverlayWindow.hidden = YES;
                TOWXV11DiagLog("OVERLAY", "HIDDEN|fix=6|reason=%s|serial=%llu", reason ?: "?", (unsigned long long)serial);
            }];
        }
        return;
    }

    TOWXEnsureOverlay(session);
    TOWXApplyData(YES);
    gOverlayWindow.windowLevel = session.windowLevel + 2.0;

    TOWXV11FollowerSetEnabled(YES);
    CGRect visualRect = TOWXV11FollowerCurrentVisualRect();
    if (!TOWXFrameUsable(visualRect)) {
        TOWXHardHideOverlay("visual-not-ready");
        TOWXV11DiagLog("OVERLAY", "WAIT-GEOMETRY|fix=6|reason=%s|policy=fail-closed", reason ?: "?");
        return;
    }
    TOWXShowAtRect(visualRect, NO, YES, reason ?: "sync");
}

static void TOWXInstallObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:TOWXV11SessionDidBeginNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshHostContext("session-begin");
        TOWXV11KeyboardRefresh("session-begin");
        TOWXSyncController("session-begin");
    }];
    [center addObserverForName:TOWXV11SessionDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshHostContext("session-change");
        TOWXV11KeyboardRefresh("session-change");
        TOWXSyncController("session-change");
    }];
    [center addObserverForName:TOWXV11SessionDidEndNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshHostContext("session-end");
        TOWXSyncController("session-end");
    }];
    [center addObserverForName:TOWXV11DataDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXApplyData(YES);
        TOWXSyncController("data-change");
    }];
    [center addObserverForName:TOWXV11HostContextDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXSyncController("host-change");
    }];
    [center addObserverForName:TOWXV11KeyboardStateDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXSyncController("keyboard-state");
    }];
}

__attribute__((constructor)) static void TOWXV11AvatarControllerFix2Init(void) {
    TOWXV11DiagLog("PRODUCT", "LOADED|Smooth1-FIX6|keyboard-avatar-mutual-exclusion+hard-hide+fix5-layout");
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXV11KeyboardStartObserving();
        TOWXInstallObservers();
        TOWXV11FollowerSetUpdateHandler(^(CGRect visualRect, BOOL tracking) {
            if (!gShouldShow || TOWXV11KeyboardVisible()) return;
            if (!TOWXFrameUsable(visualRect)) {
                TOWXHardHideOverlay("follower-visual-lost");
                return;
            }
            TOWXShowAtRect(visualRect, tracking, YES, tracking ? "follower-tracking" : "follower-stable");
        });
        TOWXV11RefreshHostContext("v11-fix6-init");
        TOWXV11RefreshSession("v11-fix6-init");
        TOWXV11KeyboardRefresh("v11-fix6-init");
        TOWXSyncController("constructor");
    });
}
