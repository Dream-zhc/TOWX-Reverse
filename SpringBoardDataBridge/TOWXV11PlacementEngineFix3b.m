#import "TOWXV11PlacementEngine.h"

#include <math.h>

static CGFloat TOWXClampFix3B(CGFloat value, CGFloat lower, CGFloat upper) {
    if (upper < lower) return lower;
    return MIN(MAX(value, lower), upper);
}

static CGRect TOWXSafeRectFix3B(CGRect screenBounds, UIEdgeInsets insets) {
    const CGFloat margin = 3.0;
    CGRect rect = UIEdgeInsetsInsetRect(screenBounds,
                                        UIEdgeInsetsMake(insets.top + margin,
                                                         insets.left + margin,
                                                         insets.bottom + margin,
                                                         insets.right + margin));
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) rect = CGRectInset(screenBounds, margin, margin);
    return rect;
}

static BOOL TOWXLandscapeFix3B(UIInterfaceOrientation orientation, CGRect screenBounds) {
    BOOL byGeometry = CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds);
    if (orientation == UIInterfaceOrientationUnknown) return byGeometry;
    BOOL byOrientation = UIInterfaceOrientationIsLandscape(orientation);
    if (byOrientation != byGeometry) return byGeometry;
    return byOrientation;
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
        CGRectGetWidth(sessionRect) < 70.0 || CGRectGetHeight(sessionRect) < 90.0 ||
        CGRectGetWidth(screenBounds) < 100.0 || CGRectGetHeight(screenBounds) < 100.0 || avatarCount == 0) return result;

    CGRect safeRect = TOWXSafeRectFix3B(screenBounds, safeInsets);
    BOOL landscape = TOWXLandscapeFix3B(orientation, screenBounds);
    const CGFloat edgeShield = 7.0;      /* transparent touch shield overlapping TrollOpen edge */
    const CGFloat visualGap = 8.0;       /* actual visible gap between window chrome and avatar circles */
    const CGFloat diameter = 44.0;
    const CGFloat padding = 5.0;
    const CGFloat spacing = 7.0;

    if (!landscape) {
        /* Product rule: portrait module is exactly 95% of the current floating-window width when space permits. */
        CGFloat desiredWidth = CGRectGetWidth(sessionRect) * 0.95;
        CGFloat width = MIN(desiredWidth, CGRectGetWidth(safeRect));
        width = MAX(120.0, width);
        CGFloat height = edgeShield + visualGap + diameter + padding * 2.0;
        CGFloat x = TOWXClampFix3B(CGRectGetMidX(sessionRect) - width * 0.5,
                                   CGRectGetMinX(safeRect), CGRectGetMaxX(safeRect) - width);
        CGFloat y = CGRectGetMaxY(sessionRect) - edgeShield;
        if (y + height > CGRectGetMaxY(screenBounds)) y = CGRectGetMaxY(screenBounds) - height;
        y = MAX(CGRectGetMinY(screenBounds), y);
        result.frame = CGRectMake(x, y, width, height);
        result.mode = TOWXV11AvatarPlacementBottom;
        result.vertical = NO;
        return result;
    }

    /* Landscape is always a compact vertical rail on the floating window's right edge. */
    CGFloat width = edgeShield + visualGap + diameter + padding * 2.0;
    CGFloat fiveAvatarViewport = diameter * 5.0 + spacing * 4.0 + padding * 2.0;
    CGFloat height = MIN(CGRectGetHeight(sessionRect) * 0.86, fiveAvatarViewport);
    height = MIN(height, CGRectGetHeight(safeRect));
    height = MAX(diameter + padding * 2.0, height);
    CGFloat y = TOWXClampFix3B(CGRectGetMidY(sessionRect) - height * 0.5,
                               CGRectGetMinY(safeRect), CGRectGetMaxY(safeRect) - height);

    CGFloat rightX = CGRectGetMaxX(sessionRect) - edgeShield;
    CGFloat maxX = CGRectGetMaxX(screenBounds) - width;
    CGFloat x = MIN(rightX, maxX);
    x = MAX(CGRectGetMinX(screenBounds), x);
    result.frame = CGRectMake(x, y, width, height);
    result.mode = TOWXV11AvatarPlacementRight;
    result.vertical = YES;
    return result;
}

__attribute__((constructor)) static void TOWXV11PlacementFix3BMarker(void) {
    NSLog(@"TOWX|V11|PLACEMENT|LOADED|Smooth1-FIX5|portraitWidth=95pct|visibleGap=8|edgeShield=7|landscape=right-only|avatars=15");
}
