#import "TOWXV11PlacementEngine.h"

#include <math.h>

static CGRect TOWXSafeRect(CGRect screenBounds, UIEdgeInsets insets) {
    CGFloat margin = 4.0;
    UIEdgeInsets expanded = UIEdgeInsetsMake(insets.top + margin,
                                             insets.left + margin,
                                             insets.bottom + margin,
                                             insets.right + margin);
    CGRect rect = UIEdgeInsetsInsetRect(screenBounds, expanded);
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) rect = CGRectInset(screenBounds, margin, margin);
    return rect;
}

static CGFloat TOWXClamp(CGFloat value, CGFloat lower, CGFloat upper) {
    if (upper < lower) return lower;
    return MIN(MAX(value, lower), upper);
}

static BOOL TOWXLandscape(UIInterfaceOrientation orientation, CGRect screenBounds) {
    if (UIInterfaceOrientationIsLandscape(orientation)) return YES;
    if (UIInterfaceOrientationIsPortrait(orientation)) return NO;
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
        CGRectGetWidth(sessionRect) < 80.0 || CGRectGetHeight(sessionRect) < 100.0 ||
        CGRectGetWidth(screenBounds) < 100.0 || CGRectGetHeight(screenBounds) < 100.0 ||
        avatarCount == 0) return result;

    CGRect safeRect = TOWXSafeRect(screenBounds, safeInsets);
    NSUInteger count = MIN(avatarCount, (NSUInteger)6);

    /* Fix2 visual metrics: smaller cells, obvious scroll range, transparent edge-shield overlap. */
    const CGFloat diameter = 44.0;
    const CGFloat spacing = 7.0;
    const CGFloat padding = 4.0;
    const CGFloat edgeShield = 10.0;
    const CGFloat visibleItems = 4.15;
    CGFloat contentLength = diameter * (CGFloat)count + spacing * (CGFloat)(count > 0 ? count - 1 : 0) + padding * 2.0;
    BOOL landscape = TOWXLandscape(orientation, screenBounds);

    if (!landscape) {
        const CGFloat height = 56.0;
        CGFloat viewportCap = diameter * visibleItems + spacing * 4.0 + padding * 2.0;
        CGFloat sessionCap = MAX(150.0, CGRectGetWidth(sessionRect) * 0.62);
        CGFloat width = MIN(contentLength, MIN(viewportCap, sessionCap));
        width = MIN(CGRectGetWidth(safeRect), MAX(150.0, width));

        CGFloat x = CGRectGetMidX(sessionRect) - width * 0.5;
        x = TOWXClamp(x, CGRectGetMinX(safeRect), CGRectGetMaxX(safeRect) - width);

        /* Overlay starts inside the lower edge so its transparent first 10pt steals TrollOpen edge gestures.
           Avatar circles themselves are laid out below that shield, visually flush with the window edge. */
        CGFloat y = CGRectGetMaxY(sessionRect) - edgeShield;
        if (y + height > CGRectGetMaxY(safeRect)) y = CGRectGetMaxY(safeRect) - height;
        y = MAX(CGRectGetMinY(safeRect), y);

        result.frame = CGRectMake(x, y, width, height);
        result.mode = TOWXV11AvatarPlacementBottom;
        result.vertical = NO;
        return result;
    }

    const CGFloat width = 56.0;
    CGFloat viewportCap = diameter * visibleItems + spacing * 4.0 + padding * 2.0;
    CGFloat sessionCap = MAX(150.0, CGRectGetHeight(sessionRect) * 0.62);
    CGFloat height = MIN(contentLength, MIN(viewportCap, sessionCap));
    height = MIN(CGRectGetHeight(safeRect), MAX(150.0, height));

    CGFloat y = CGRectGetMidY(sessionRect) - height * 0.5;
    y = TOWXClamp(y, CGRectGetMinY(safeRect), CGRectGetMaxY(safeRect) - height);

    /* Same edge-shield strategy on the right side. Keep right as the canonical side rather than jumping left. */
    CGFloat x = CGRectGetMaxX(sessionRect) - edgeShield;
    if (x + width > CGRectGetMaxX(safeRect)) x = CGRectGetMaxX(safeRect) - width;
    x = MAX(CGRectGetMinX(safeRect), x);

    result.frame = CGRectMake(x, y, width, height);
    result.mode = TOWXV11AvatarPlacementRight;
    result.vertical = YES;
    return result;
}

__attribute__((constructor)) static void TOWXV11PlacementFix2Marker(void) {
    NSLog(@"TOWX|V11|PLACEMENT|LOADED|Smooth1-FIX2|diameter=44|edgeShield=10|portrait=bottom|landscape=right");
}
