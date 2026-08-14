#import "TOWXV11PlacementEngine.h"

#include <math.h>

static CGFloat TOWXClampFix3(CGFloat value, CGFloat lower, CGFloat upper) {
    if (upper < lower) return lower;
    return MIN(MAX(value, lower), upper);
}

static CGRect TOWXSafeRectFix3(CGRect screenBounds, UIEdgeInsets insets) {
    const CGFloat margin = 3.0;
    CGRect rect = UIEdgeInsetsInsetRect(screenBounds,
                                        UIEdgeInsetsMake(insets.top + margin,
                                                         insets.left + margin,
                                                         insets.bottom + margin,
                                                         insets.right + margin));
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) {
        rect = CGRectInset(screenBounds, margin, margin);
    }
    return rect;
}

static BOOL TOWXLandscapeFix3(UIInterfaceOrientation orientation, CGRect screenBounds) {
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
        CGRectGetWidth(sessionRect) < 70.0 || CGRectGetHeight(sessionRect) < 90.0 ||
        CGRectGetWidth(screenBounds) < 100.0 || CGRectGetHeight(screenBounds) < 100.0 ||
        avatarCount == 0) return result;

    CGRect safeRect = TOWXSafeRectFix3(screenBounds, safeInsets);
    BOOL landscape = TOWXLandscapeFix3(orientation, screenBounds);

    /* The first strip overlaps the TrollOpen edge only for hit-testing. The circles begin after a visible 5pt gap. */
    const CGFloat edgeShield = 7.0;
    const CGFloat visualGap = 5.0;
    const CGFloat diameter = 44.0;
    const CGFloat crossPadding = 4.0;

    if (!landscape) {
        CGFloat width = CGRectGetWidth(sessionRect) * 0.95;
        width = MIN(width, CGRectGetWidth(safeRect));
        width = MAX(150.0, width);

        CGFloat height = edgeShield + visualGap + diameter + crossPadding * 2.0;
        CGFloat x = CGRectGetMidX(sessionRect) - width * 0.5;
        x = TOWXClampFix3(x, CGRectGetMinX(safeRect), CGRectGetMaxX(safeRect) - width);

        CGFloat y = CGRectGetMaxY(sessionRect) - edgeShield;
        if (y + height > CGRectGetMaxY(screenBounds)) {
            /* Preserve attachment even near the screen bottom; only clip the outer transparent padding. */
            y = MIN(y, CGRectGetMaxY(screenBounds) - height);
        }
        y = MAX(CGRectGetMinY(screenBounds), y);

        result.frame = CGRectMake(x, y, width, height);
        result.mode = TOWXV11AvatarPlacementBottom;
        result.vertical = NO;
        return result;
    }

    CGFloat width = edgeShield + visualGap + diameter + crossPadding * 2.0;
    CGFloat desiredHeight = CGRectGetHeight(sessionRect) * 0.92;
    desiredHeight = MAX(160.0, desiredHeight);
    desiredHeight = MIN(desiredHeight, CGRectGetHeight(safeRect));

    CGFloat y = CGRectGetMidY(sessionRect) - desiredHeight * 0.5;
    y = TOWXClampFix3(y, CGRectGetMinY(safeRect), CGRectGetMaxY(safeRect) - desiredHeight);

    CGFloat rightX = CGRectGetMaxX(sessionRect) - edgeShield;
    BOOL rightFits = rightX + width <= CGRectGetMaxX(screenBounds) + 0.5;
    if (rightFits) {
        result.frame = CGRectMake(rightX, y, width, desiredHeight);
        result.mode = TOWXV11AvatarPlacementRight;
        result.vertical = YES;
        return result;
    }

    /* If the floating window is dragged flush to the physical right edge, keep the rail attached on the left rather than detach it. */
    CGFloat leftX = CGRectGetMinX(sessionRect) - (width - edgeShield);
    leftX = MAX(CGRectGetMinX(screenBounds), leftX);
    result.frame = CGRectMake(leftX, y, width, desiredHeight);
    result.mode = TOWXV11AvatarPlacementLeft;
    result.vertical = YES;
    return result;
}

__attribute__((constructor)) static void TOWXV11PlacementFix3Marker(void) {
    NSLog(@"TOWX|V11|PLACEMENT|LOADED|Smooth1-FIX3|portraitWidth=95pct|gap=5|edgeShield=7|landscape=right|avatars=15");
}
