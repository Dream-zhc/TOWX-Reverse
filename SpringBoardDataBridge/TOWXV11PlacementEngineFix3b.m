#import "TOWXV11PlacementEngine.h"

#include <math.h>

static CGFloat TOWXClampFix5(CGFloat value, CGFloat lower, CGFloat upper) {
    if (upper < lower) return lower;
    return MIN(MAX(value, lower), upper);
}

static CGRect TOWXSafeRectFix5(CGRect screenBounds, UIEdgeInsets insets) {
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

static CGRect TOWXLiveScreenBoundsFix5(CGRect supplied) {
    CGRect live = UIScreen.mainScreen.coordinateSpace.bounds;
    if (CGRectGetWidth(live) >= 100.0 && CGRectGetHeight(live) >= 100.0) return live;
    return supplied;
}

static BOOL TOWXLandscapeFix5(UIInterfaceOrientation orientation, CGRect screenBounds) {
    BOOL byGeometry = CGRectGetWidth(screenBounds) > CGRectGetHeight(screenBounds);
    if (orientation == UIInterfaceOrientationUnknown) return byGeometry;
    BOOL byOrientation = UIInterfaceOrientationIsLandscape(orientation);
    /* TrollOpen can keep orientation=portrait for one or more cycles while the physical display is
       already landscape. Current screen coordinate-space geometry is authoritative. */
    return byOrientation == byGeometry ? byOrientation : byGeometry;
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
    screenBounds = TOWXLiveScreenBoundsFix5(screenBounds);
    if (CGRectIsNull(sessionRect) || CGRectIsEmpty(sessionRect) ||
        CGRectGetWidth(sessionRect) < 70.0 || CGRectGetHeight(sessionRect) < 90.0 ||
        CGRectGetWidth(screenBounds) < 100.0 || CGRectGetHeight(screenBounds) < 100.0 ||
        avatarCount == 0) return result;

    CGRect safeRect = TOWXSafeRectFix5(screenBounds, safeInsets);
    BOOL landscape = TOWXLandscapeFix5(orientation, screenBounds);
    const CGFloat edgeShield = 7.0;
    const CGFloat visualGap = 8.0;
    const CGFloat diameter = 44.0;
    const CGFloat padding = 5.0;
    const CGFloat baseSpacing = 7.0;

    if (!landscape) {
        /* Exact product rule: visible module width is 95% of the current floating WeChat window. */
        CGFloat desiredWidth = CGRectGetWidth(sessionRect) * 0.95;
        CGFloat width = MIN(desiredWidth, CGRectGetWidth(safeRect));
        width = MAX(120.0, width);
        CGFloat height = edgeShield + visualGap + diameter + padding * 2.0;
        CGFloat x = TOWXClampFix5(CGRectGetMidX(sessionRect) - width * 0.5,
                                  CGRectGetMinX(safeRect), CGRectGetMaxX(safeRect) - width);
        CGFloat y = CGRectGetMaxY(sessionRect) - edgeShield;
        if (y + height > CGRectGetMaxY(screenBounds)) y = CGRectGetMaxY(screenBounds) - height;
        y = MAX(CGRectGetMinY(screenBounds), y);
        result.frame = CGRectMake(x, y, width, height);
        result.mode = TOWXV11AvatarPlacementBottom;
        result.vertical = NO;
        return result;
    }

    /* Landscape product rule: vertical rail is attached only to the right side. The transparent
       edge shield overlaps 7pt of TrollOpen while the visible avatar circle starts 8pt outside it. */
    CGFloat width = edgeShield + visualGap + diameter + padding * 2.0;
    CGFloat fiveAvatarViewport = diameter * 5.0 + baseSpacing * 4.0 + padding * 2.0;
    CGFloat height = MIN(CGRectGetHeight(sessionRect) * 0.88, fiveAvatarViewport);
    height = MIN(height, CGRectGetHeight(safeRect));
    height = MAX(diameter + padding * 2.0, height);
    CGFloat y = TOWXClampFix5(CGRectGetMidY(sessionRect) - height * 0.5,
                              CGRectGetMinY(safeRect), CGRectGetMaxY(safeRect) - height);

    CGFloat rightX = CGRectGetMaxX(sessionRect) - edgeShield;
    CGFloat x = TOWXClampFix5(rightX,
                              CGRectGetMinX(screenBounds),
                              CGRectGetMaxX(screenBounds) - width);
    result.frame = CGRectMake(x, y, width, height);
    result.mode = TOWXV11AvatarPlacementRight;
    result.vertical = YES;
    return result;
}

__attribute__((constructor)) static void TOWXV11PlacementFix5Marker(void) {
    NSLog(@"TOWX|V11|PLACEMENT|LOADED|Smooth1-FIX5|portraitWidth=95pct|integerSlots|visibleGap=8|edgeShield=7|landscape=right-only|avatars=15");
}
