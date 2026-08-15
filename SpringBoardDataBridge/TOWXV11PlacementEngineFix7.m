#import "TOWXV11PlacementEngine.h"
#import "TOWXV11Diagnostics.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>

#include <math.h>

static CGFloat TOWXClampFix7(CGFloat value, CGFloat lower, CGFloat upper) {
    if (upper < lower) return lower;
    return MIN(MAX(value, lower), upper);
}

static CGRect TOWXSafeRectFix7(CGRect screenBounds, UIEdgeInsets insets) {
    const CGFloat margin = 3.0;
    CGRect rect = UIEdgeInsetsInsetRect(screenBounds,
                                        UIEdgeInsetsMake(insets.top + margin,
                                                         insets.left + margin,
                                                         insets.bottom + margin,
                                                         insets.right + margin));
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) rect = CGRectInset(screenBounds, margin, margin);
    return rect;
}

static BOOL TOWXOrientationIsValid(UIInterfaceOrientation value) {
    return value == UIInterfaceOrientationPortrait ||
           value == UIInterfaceOrientationPortraitUpsideDown ||
           value == UIInterfaceOrientationLandscapeLeft ||
           value == UIInterfaceOrientationLandscapeRight;
}

static UIInterfaceOrientation TOWXOrientationFromDevice(void) {
    UIDeviceOrientation device = UIDevice.currentDevice.orientation;
    switch (device) {
        case UIDeviceOrientationLandscapeLeft: return UIInterfaceOrientationLandscapeRight;
        case UIDeviceOrientationLandscapeRight: return UIInterfaceOrientationLandscapeLeft;
        case UIDeviceOrientationPortrait: return UIInterfaceOrientationPortrait;
        case UIDeviceOrientationPortraitUpsideDown: return UIInterfaceOrientationPortraitUpsideDown;
        default: return UIInterfaceOrientationUnknown;
    }
}

static UIInterfaceOrientation TOWXReadIntegerOrientation(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return UIInterfaceOrientationUnknown;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return UIInterfaceOrientationUnknown;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return UIInterfaceOrientationUnknown;
    const char *type = signature.methodReturnType;
    while (type && strchr("rnNoORV", *type)) type++;
    if (!type || !strchr("cislqCISLQ", *type)) return UIInterfaceOrientationUnknown;
    @try {
        NSInteger raw = ((NSInteger (*)(id, SEL))objc_msgSend)(object, selector);
        UIInterfaceOrientation value = (UIInterfaceOrientation)raw;
        return TOWXOrientationIsValid(value) ? value : UIInterfaceOrientationUnknown;
    } @catch (__unused NSException *exception) {
        return UIInterfaceOrientationUnknown;
    }
}

static UIInterfaceOrientation TOWXSpringBoardOrientation(void) {
    Class cls = NSClassFromString(@"SBUIController");
    if (!cls) return UIInterfaceOrientationUnknown;
    id shared = nil;
    SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
    if ([(id)cls respondsToSelector:sharedSelector]) {
        @try { shared = ((id (*)(id, SEL))objc_msgSend)((id)cls, sharedSelector); }
        @catch (__unused NSException *exception) { shared = nil; }
    }
    if (!shared) return UIInterfaceOrientationUnknown;
    for (NSString *name in @[@"activeInterfaceOrientation", @"interfaceOrientation", @"currentInterfaceOrientation"]) {
        UIInterfaceOrientation value = TOWXReadIntegerOrientation(shared, name);
        if (TOWXOrientationIsValid(value)) return value;
    }
    return UIInterfaceOrientationUnknown;
}

static UIInterfaceOrientation TOWXApplicationOrientation(void) {
    UIApplication *application = UIApplication.sharedApplication;
    UIInterfaceOrientation status = TOWXReadIntegerOrientation(application, @"statusBarOrientation");
    if (TOWXOrientationIsValid(status)) return status;

    UIInterfaceOrientation landscapeCandidate = UIInterfaceOrientationUnknown;
    UIInterfaceOrientation portraitCandidate = UIInterfaceOrientationUnknown;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UIInterfaceOrientation value = windowScene.interfaceOrientation;
        if (!TOWXOrientationIsValid(value)) continue;
        if (UIInterfaceOrientationIsLandscape(value)) landscapeCandidate = value;
        else portraitCandidate = value;
        if (scene.activationState == UISceneActivationStateForegroundActive) return value;
    }
    return TOWXOrientationIsValid(landscapeCandidate) ? landscapeCandidate : portraitCandidate;
}

static BOOL TOWXLandscapeFix7(UIInterfaceOrientation supplied, CGRect screenBounds, const char **sourceOut) {
    UIInterfaceOrientation value = TOWXOrientationFromDevice();
    if (TOWXOrientationIsValid(value)) {
        if (sourceOut) *sourceOut = "UIDevice";
        return UIInterfaceOrientationIsLandscape(value);
    }

    value = TOWXSpringBoardOrientation();
    if (TOWXOrientationIsValid(value)) {
        if (sourceOut) *sourceOut = "SBUIController";
        return UIInterfaceOrientationIsLandscape(value);
    }

    value = TOWXApplicationOrientation();
    if (TOWXOrientationIsValid(value)) {
        if (sourceOut) *sourceOut = "UIApplication/scene";
        return UIInterfaceOrientationIsLandscape(value);
    }

    if (TOWXOrientationIsValid(supplied)) {
        if (sourceOut) *sourceOut = "session";
        return UIInterfaceOrientationIsLandscape(supplied);
    }

    if (sourceOut) *sourceOut = "screen-geometry";
    return CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds);
}

const char *TOWXV11PlacementModeName(TOWXV11AvatarPlacementMode mode) {
    switch (mode) {
        case TOWXV11AvatarPlacementBottom: return "bottom";
        case TOWXV11AvatarPlacementTop: return "top";
        case TOWXV11AvatarPlacementRight: return "right";
        case TOWXV11AvatarPlacementLeft: return "left";
        default: return "hidden";
    }
}

TOWXV11AvatarPlacement TOWXV11ComputeAvatarPlacement(CGRect sessionRect,
                                                      CGRect screenBounds,
                                                      UIEdgeInsets safeInsets,
                                                      UIInterfaceOrientation orientation,
                                                      NSUInteger avatarCount) {
    TOWXV11AvatarPlacement result = { CGRectZero, TOWXV11AvatarPlacementHidden, NO };
    if (CGRectIsNull(sessionRect) || CGRectIsEmpty(sessionRect) ||
        CGRectGetWidth(sessionRect) < 70.0 || CGRectGetHeight(sessionRect) < 90.0 || avatarCount == 0) return result;

    /* Use the largest sane screen rectangle supplied by SpringBoard/session; the orientation decision
       is independent and comes from live system orientation above. */
    CGRect main = UIScreen.mainScreen.coordinateSpace.bounds;
    if (CGRectGetWidth(screenBounds) < 100.0 || CGRectGetHeight(screenBounds) < 100.0) screenBounds = main;
    if (CGRectGetWidth(main) * CGRectGetHeight(main) > CGRectGetWidth(screenBounds) * CGRectGetHeight(screenBounds) * 0.95) screenBounds = main;

    const char *orientationSource = NULL;
    BOOL landscape = TOWXLandscapeFix7(orientation, screenBounds, &orientationSource);

    /* If the coordinate-space rectangle is portrait-shaped while the device is physically landscape,
       rotate only the available screen extents. The session visual rect remains in the follower's screen
       coordinate space and is not transformed here. */
    if (landscape && CGRectGetWidth(screenBounds) < CGRectGetHeight(screenBounds)) {
        screenBounds = CGRectMake(CGRectGetMinX(screenBounds), CGRectGetMinY(screenBounds),
                                  CGRectGetHeight(screenBounds), CGRectGetWidth(screenBounds));
    } else if (!landscape && CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds)) {
        screenBounds = CGRectMake(CGRectGetMinX(screenBounds), CGRectGetMinY(screenBounds),
                                  CGRectGetHeight(screenBounds), CGRectGetWidth(screenBounds));
    }

    CGRect safeRect = TOWXSafeRectFix7(screenBounds, safeInsets);
    const CGFloat edgeShield = 7.0;
    const CGFloat visualGap = 8.0;
    const CGFloat diameter = 44.0;
    const CGFloat padding = 5.0;
    const CGFloat baseSpacing = 7.0;

    if (!landscape) {
        CGFloat desiredWidth = CGRectGetWidth(sessionRect) * 0.95;
        CGFloat width = MIN(MAX(120.0, desiredWidth), CGRectGetWidth(safeRect));
        CGFloat height = edgeShield + visualGap + diameter + padding * 2.0;
        CGFloat x = TOWXClampFix7(CGRectGetMidX(sessionRect) - width * 0.5,
                                  CGRectGetMinX(safeRect), CGRectGetMaxX(safeRect) - width);
        CGFloat y = CGRectGetMaxY(sessionRect) - edgeShield;
        if (y + height > CGRectGetMaxY(screenBounds)) y = CGRectGetMaxY(screenBounds) - height;
        y = MAX(CGRectGetMinY(screenBounds), y);
        result.frame = CGRectMake(x, y, width, height);
        result.mode = TOWXV11AvatarPlacementBottom;
        result.vertical = NO;
    } else {
        CGFloat width = edgeShield + visualGap + diameter + padding * 2.0;
        CGFloat fiveAvatarViewport = diameter * 5.0 + baseSpacing * 4.0 + padding * 2.0;
        CGFloat height = MIN(MAX(diameter + padding * 2.0, CGRectGetHeight(sessionRect) * 0.88), fiveAvatarViewport);
        height = MIN(height, CGRectGetHeight(safeRect));
        CGFloat y = TOWXClampFix7(CGRectGetMidY(sessionRect) - height * 0.5,
                                  CGRectGetMinY(safeRect), CGRectGetMaxY(safeRect) - height);
        CGFloat x = CGRectGetMaxX(sessionRect) - edgeShield;
        x = TOWXClampFix7(x, CGRectGetMinX(screenBounds), CGRectGetMaxX(screenBounds) - width);
        result.frame = CGRectMake(x, y, width, height);
        result.mode = TOWXV11AvatarPlacementRight;
        result.vertical = YES;
    }

    static BOOL lastLandscape = NO;
    static const char *lastSource = NULL;
    if (lastLandscape != landscape || lastSource != orientationSource) {
        lastLandscape = landscape;
        lastSource = orientationSource;
        TOWXV11DiagLog("PLACEMENT", "ORIENTATION|fix=7|landscape=%d|source=%s|supplied=%ld|screen={{%.1f,%.1f},{%.1f,%.1f}}",
                       landscape ? 1 : 0,
                       orientationSource ?: "?",
                       (long)orientation,
                       screenBounds.origin.x, screenBounds.origin.y,
                       screenBounds.size.width, screenBounds.size.height);
    }
    return result;
}

__attribute__((constructor)) static void TOWXV11PlacementFix7Marker(void) {
    [UIDevice.currentDevice beginGeneratingDeviceOrientationNotifications];
    TOWXV11DiagLog("PLACEMENT", "LOADED|Smooth1-FIX7|physical-orientation|landscape-right-vertical|portrait-95pct");
}
