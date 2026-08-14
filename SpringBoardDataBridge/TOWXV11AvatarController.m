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
#import "TOWXV11Diagnostics.h"

@interface TOWXV11OverlayRootController : UIViewController
@end
@implementation TOWXV11OverlayRootController
- (void)loadView {
    UIView *view = [[UIView alloc] initWithFrame:CGRectZero];
    view.backgroundColor = UIColor.clearColor;
    view.opaque = NO;
    self.view = view;
}
- (BOOL)prefersStatusBarHidden { return YES; }
@end

@interface TOWXV11OverlayWindow : UIWindow
@end
@implementation TOWXV11OverlayWindow
- (BOOL)canBecomeKeyWindow { return NO; }
@end

static TOWXV11OverlayWindow *gOverlayWindow = nil;
static TOWXV11AvatarView *gAvatarView = nil;
static TOWXV11AnimationController *gAnimationController = nil;
static UIViewPropertyAnimator *gRepositionAnimator = nil;
static TOWXV11AvatarPlacementMode gPlacementMode = TOWXV11AvatarPlacementHidden;
static CGRect gLastPlacementFrame = {{0,0},{0,0}};
static BOOL gShouldShow = NO;
static uint64_t gVisibilitySerial = 0;
static BOOL gLastGateShow = NO;
static NSString *gLastGateBundle = nil;
static NSString *gLastGateReason = nil;
static NSUInteger gLastGateCount = NSNotFound;

static BOOL TOWXV11FrameUsable(CGRect frame) {
    return !CGRectIsNull(frame) && !CGRectIsEmpty(frame) &&
           frame.size.width > 20.0 && frame.size.height > 20.0;
}

static CGRect TOWXV11ScreenBoundsForSession(UIWindow *session) {
    if (!session) return UIScreen.mainScreen.bounds;
    UIWindowScene *scene = session.windowScene;
    if (scene) {
        id<UICoordinateSpace> space = scene.coordinateSpace;
        if (space) return space.bounds;
        if (scene.screen) return scene.screen.bounds;
    }
    return session.screen ? session.screen.bounds : UIScreen.mainScreen.bounds;
}

static TOWXV11AvatarPlacement TOWXV11PlacementForRect(CGRect sessionRect) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    CGRect screenBounds = TOWXV11ScreenBoundsForSession(session);
    return TOWXV11ComputeAvatarPlacement(sessionRect,
                                         screenBounds,
                                         UIEdgeInsetsZero,
                                         TOWXV11CurrentSessionOrientation(),
                                         TOWXV11DataAvatarCount());
}

static void TOWXV11StopReposition(const char *reason) {
    if (!gRepositionAnimator) return;
    [gRepositionAnimator stopAnimation:YES];
    gRepositionAnimator = nil;
    TOWXV11DiagLog("PLACEMENT", "REPOSITION-INTERRUPT|reason=%s", reason ?: "?");
}

static void TOWXV11SetOverlayFrameDirect(CGRect frame) {
    if (!gOverlayWindow || !TOWXV11FrameUsable(frame)) return;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gOverlayWindow.frame = frame;
    [CATransaction commit];
    gLastPlacementFrame = frame;
}

static void TOWXV11SetOverlayFrameAnimated(CGRect frame, TOWXV11AvatarPlacementMode mode) {
    if (!gOverlayWindow || !TOWXV11FrameUsable(frame)) return;
    TOWXV11StopReposition("new-reposition");
    TOWXV11DiagLog("PLACEMENT", "REPOSITION-BEGIN|mode=%s|from={{%.1f,%.1f},{%.1f,%.1f}}|to={{%.1f,%.1f},{%.1f,%.1f}}",
                   TOWXV11PlacementModeName(mode),
                   gOverlayWindow.frame.origin.x, gOverlayWindow.frame.origin.y,
                   gOverlayWindow.frame.size.width, gOverlayWindow.frame.size.height,
                   frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.88];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.30 timingParameters:timing];
    [animator addAnimations:^{ gOverlayWindow.frame = frame; }];
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        if (gRepositionAnimator != animator) return;
        gRepositionAnimator = nil;
        gLastPlacementFrame = frame;
        TOWXV11DiagLog("PLACEMENT", "REPOSITION-END|mode=%s|position=%ld",
                       TOWXV11PlacementModeName(mode), (long)position);
    }];
    gRepositionAnimator = animator;
    [animator startAnimation];
}

static void TOWXV11ApplyPlacement(TOWXV11AvatarPlacement placement, BOOL tracking, BOOL allowAnimatedModeChange) {
    if (!gOverlayWindow || placement.mode == TOWXV11AvatarPlacementHidden || !TOWXV11FrameUsable(placement.frame)) return;

    BOOL modeChanged = gPlacementMode != placement.mode;
    if (modeChanged) {
        TOWXV11DiagLog("PLACEMENT", "MODE|from=%s|to=%s|tracking=%d|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                       TOWXV11PlacementModeName(gPlacementMode),
                       TOWXV11PlacementModeName(placement.mode),
                       tracking ? 1 : 0,
                       placement.frame.origin.x, placement.frame.origin.y,
                       placement.frame.size.width, placement.frame.size.height);
        gPlacementMode = placement.mode;
        gAvatarView.vertical = placement.vertical;
    }

    if (tracking) {
        TOWXV11StopReposition("follower-tracking");
        TOWXV11SetOverlayFrameDirect(placement.frame);
        return;
    }

    BOOL frameChanged = !CGRectEqualToRect(gLastPlacementFrame, placement.frame);
    if (!frameChanged) return;
    if (modeChanged && allowAnimatedModeChange && !gOverlayWindow.hidden) {
        TOWXV11SetOverlayFrameAnimated(placement.frame, placement.mode);
    } else {
        TOWXV11SetOverlayFrameDirect(placement.frame);
    }
}

static void TOWXV11DestroyOverlay(void) {
    TOWXV11StopReposition("destroy-overlay");
    if (gOverlayWindow) {
        gOverlayWindow.hidden = YES;
        gOverlayWindow.rootViewController = nil;
    }
    gOverlayWindow = nil;
    gAvatarView = nil;
    gAnimationController = nil;
    gPlacementMode = TOWXV11AvatarPlacementHidden;
    gLastPlacementFrame = CGRectZero;
}

static void TOWXV11EnsureOverlay(UIWindow *session) {
    if (!session || !session.windowScene) return;
    if (gOverlayWindow && gOverlayWindow.windowScene != session.windowScene) {
        TOWXV11DiagLog("OVERLAY", "SCENE-CHANGE|old=%p|new=%p", gOverlayWindow.windowScene, session.windowScene);
        TOWXV11DestroyOverlay();
    }
    if (gOverlayWindow) {
        gOverlayWindow.windowLevel = session.windowLevel + 2.0;
        return;
    }

    TOWXV11OverlayWindow *window = [[TOWXV11OverlayWindow alloc] initWithWindowScene:session.windowScene];
    window.backgroundColor = UIColor.clearColor;
    window.opaque = NO;
    window.windowLevel = session.windowLevel + 2.0;
    window.hidden = YES;

    TOWXV11OverlayRootController *root = [TOWXV11OverlayRootController new];
    window.rootViewController = root;
    (void)root.view;

    TOWXV11AvatarView *avatarView = [[TOWXV11AvatarView alloc] initWithFrame:root.view.bounds];
    avatarView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:avatarView];
    avatarView.tapHandler = ^(NSUInteger index) {
        TOWXV11DataSendOpen(index);
    };

    gOverlayWindow = window;
    gAvatarView = avatarView;
    gAnimationController = [[TOWXV11AnimationController alloc] initWithView:avatarView];
    gPlacementMode = TOWXV11AvatarPlacementHidden;
    gLastPlacementFrame = CGRectZero;
    TOWXV11DiagLog("OVERLAY", "CREATE|window=%p|scene=%p|level=%.1f", window, session.windowScene, window.windowLevel);
}

static void TOWXV11ApplyDataToAvatarView(BOOL animated) {
    if (!gAvatarView) return;
    [gAvatarView applyImages:TOWXV11DataAvatarImages()
                       count:TOWXV11DataAvatarCount()
               selectedIndex:TOWXV11DataSelectedIndex()
                    animated:animated];
}

static void TOWXV11LogGateIfChanged(BOOL show, const char *reason) {
    NSString *bundle = TOWXV11CurrentSessionBundleIdentifier() ?: @"";
    NSString *reasonString = reason ? [NSString stringWithUTF8String:reason] : @"?";
    NSUInteger count = TOWXV11DataAvatarCount();
    if (gLastGateShow == show && [gLastGateBundle isEqualToString:bundle] &&
        [gLastGateReason isEqualToString:reasonString] && gLastGateCount == count) return;
    gLastGateShow = show;
    gLastGateBundle = [bundle copy];
    gLastGateReason = [reasonString copy];
    gLastGateCount = count;
    TOWXV11DiagLog("GATE", "STATE|show=%d|reason=%s|bundle=%s|active=%d|count=%lu|epoch=%llu",
                   show ? 1 : 0,
                   reason ?: "?",
                   bundle.length ? bundle.UTF8String : "?",
                   TOWXV11DataWeChatActive() ? 1 : 0,
                   (unsigned long)count,
                   (unsigned long long)TOWXV11CurrentSessionEpoch());
}

static void TOWXV11SyncController(const char *reason) {
    if (!NSThread.isMainThread) {
        NSString *r = reason ? [NSString stringWithUTF8String:reason] : @"async";
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11SyncController(r.UTF8String); });
        return;
    }

    UIWindow *session = TOWXV11CurrentSessionWindow();
    const char *gateReason = NULL;
    BOOL show = TOWXV11ShouldShowAvatarModule(TOWXV11SessionIsVisible(),
                                              TOWXV11CurrentSessionBundleIdentifier(),
                                              TOWXV11DataWeChatActive(),
                                              TOWXV11DataAvatarCount(),
                                              &gateReason);
    TOWXV11LogGateIfChanged(show, gateReason);
    gShouldShow = show;
    gVisibilitySerial += 1;
    uint64_t serial = gVisibilitySerial;

    if (!show || !session) {
        TOWXV11FollowerSetEnabled(NO);
        if (gOverlayWindow && !gOverlayWindow.hidden) {
            TOWXV11DiagLog("OVERLAY", "HIDE-REQUEST|reason=%s|gate=%s|serial=%llu",
                           reason ?: "?", gateReason ?: "?", (unsigned long long)serial);
            [gAnimationController hideTowardPlacementMode:gPlacementMode completion:^(BOOL finished) {
                if (!finished || serial != gVisibilitySerial || gShouldShow) return;
                gOverlayWindow.hidden = YES;
                TOWXV11DiagLog("OVERLAY", "HIDDEN|serial=%llu", (unsigned long long)serial);
            }];
        }
        return;
    }

    TOWXV11EnsureOverlay(session);
    if (!gOverlayWindow || !gAvatarView) return;
    gOverlayWindow.windowLevel = session.windowLevel + 2.0;
    TOWXV11ApplyDataToAvatarView(YES);

    CGRect visualRect = TOWXV11FollowerCurrentVisualRect();
    if (!TOWXV11FrameUsable(visualRect)) visualRect = session.frame;
    TOWXV11AvatarPlacement placement = TOWXV11PlacementForRect(visualRect);
    if (placement.mode == TOWXV11AvatarPlacementHidden) return;
    TOWXV11ApplyPlacement(placement, NO, YES);

    BOOL wasHidden = gOverlayWindow.hidden;
    if (wasHidden) gOverlayWindow.hidden = NO;
    TOWXV11FollowerSetEnabled(YES);
    TOWXV11DiagLog("OVERLAY", "SHOW-REQUEST|reason=%s|serial=%llu|mode=%s|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                   reason ?: "?", (unsigned long long)serial,
                   TOWXV11PlacementModeName(placement.mode),
                   placement.frame.origin.x, placement.frame.origin.y,
                   placement.frame.size.width, placement.frame.size.height);
    [gAnimationController showFromPlacementMode:placement.mode completion:^(BOOL finished) {
        if (!finished || serial != gVisibilitySerial || !gShouldShow) return;
        TOWXV11DiagLog("OVERLAY", "VISIBLE|serial=%llu", (unsigned long long)serial);
    }];
}

static void TOWXV11InstallObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:TOWXV11SessionDidBeginNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11SyncController("session-begin");
    }];
    [center addObserverForName:TOWXV11SessionDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11SyncController("session-change");
    }];
    [center addObserverForName:TOWXV11SessionDidEndNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11SyncController("session-end");
    }];
    [center addObserverForName:TOWXV11DataDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11ApplyDataToAvatarView(YES);
        TOWXV11SyncController("data-change");
    }];
}

__attribute__((constructor)) static void TOWXV11AvatarControllerInit(void) {
    TOWXV11DiagLog("PRODUCT", "LOADED|Smooth1-FINAL|overlay-window+follower+placement+native-scroll+interruptible-anim+wechat-gate+bg-decode");
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXV11InstallObservers();
        TOWXV11FollowerSetUpdateHandler(^(CGRect visualRect, BOOL tracking) {
            if (!gShouldShow || !gOverlayWindow || !TOWXV11FrameUsable(visualRect)) return;
            TOWXV11AvatarPlacement placement = TOWXV11PlacementForRect(visualRect);
            if (placement.mode == TOWXV11AvatarPlacementHidden) return;
            TOWXV11ApplyPlacement(placement, tracking, !tracking);
        });
        TOWXV11RefreshSession("v11-product-init");
        TOWXV11SyncController("constructor");
    });
}
