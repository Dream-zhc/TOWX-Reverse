#import "TOWXV11PlacementEngine.h"

#include <math.h>

static CGRect TOWXV11SafeRect(CGRect screenBounds, UIEdgeInsets insets) {
    CGFloat margin = 8.0;
    UIEdgeInsets expanded = UIEdgeInsetsMake(insets.top + margin,
                                             insets.left + margin,
                                             insets.bottom + margin,
                                             insets.right + margin);
    CGRect rect = UIEdgeInsetsInsetRect(screenBounds, expanded);
    if (CGRectGetWidth(rect) < 80.0 || CGRectGetHeight(rect) < 80.0) {
        rect = CGRectInset(screenBounds, margin, margin);
    }
    return rect;
}

static CGFloat TOWXV11Clamp(CGFloat value, CGFloat lower, CGFloat upper) {
    if (upper < lower) return lower;
    return MIN(MAX(value, lower), upper);
}

static BOOL TOWXV11OrientationIsLandscape(UIInterfaceOrientation orientation, CGRect screenBounds) {
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
    TOWXV11AvatarPlacement result;
    result.frame = CGRectZero;
    result.mode = TOWXV11AvatarPlacementHidden;
    result.vertical = NO;

    if (CGRectIsNull(sessionRect) || CGRectIsEmpty(sessionRect) ||
        CGRectGetWidth(sessionRect) < 40.0 || CGRectGetHeight(sessionRect) < 40.0 ||
        CGRectGetWidth(screenBounds) < 100.0 || CGRectGetHeight(screenBounds) < 100.0 ||
        avatarCount == 0) {
        return result;
    }

    CGRect safeRect = TOWXV11SafeRect(screenBounds, safeInsets);
    NSUInteger count = MIN(avatarCount, (NSUInteger)6);
    CGFloat diameter = 52.0;
    CGFloat spacing = 10.0;
    CGFloat padding = 8.0;
    CGFloat contentLength = diameter * (CGFloat)count + spacing * (CGFloat)(count > 0 ? count - 1 : 0) + padding * 2.0;
    BOOL landscape = TOWXV11OrientationIsLandscape(orientation, screenBounds);

    if (!landscape) {
        CGFloat height = 64.0;
        CGFloat maxWidth = CGRectGetWidth(safeRect);
        CGFloat preferredWidth = MIN(contentLength, MAX(72.0, CGRectGetWidth(sessionRect) * 0.95));
        CGFloat width = MIN(maxWidth, MAX(72.0, preferredWidth));
        CGFloat gap = 10.0;
        CGFloat x = CGRectGetMidX(sessionRect) - width * 0.5;
        x = TOWXV11Clamp(x, CGRectGetMinX(safeRect), CGRectGetMaxX(safeRect) - width);

        CGFloat bottomY = CGRectGetMaxY(sessionRect) + gap;
        BOOL bottomFits = bottomY + height <= CGRectGetMaxY(safeRect);
        if (bottomFits) {
            result.frame = CGRectMake(x, bottomY, width, height);
            result.mode = TOWXV11AvatarPlacementBottom;
            result.vertical = NO;
            return result;
        }

        CGFloat topY = CGRectGetMinY(sessionRect) - gap - height;
        BOOL topFits = topY >= CGRectGetMinY(safeRect);
        if (topFits) {
            result.frame = CGRectMake(x, topY, width, height);
            result.mode = TOWXV11AvatarPlacementTop;
            result.vertical = NO;
            return result;
        }

        CGFloat belowSpace = CGRectGetMaxY(safeRect) - CGRectGetMaxY(sessionRect);
        CGFloat aboveSpace = CGRectGetMinY(sessionRect) - CGRectGetMinY(safeRect);
        CGFloat y = belowSpace >= aboveSpace ? CGRectGetMaxY(safeRect) - height : CGRectGetMinY(safeRect);
        result.frame = CGRectMake(x, y, width, height);
        result.mode = belowSpace >= aboveSpace ? TOWXV11AvatarPlacementBottom : TOWXV11AvatarPlacementTop;
        result.vertical = NO;
        return result;
    }

    CGFloat width = 64.0;
    CGFloat maxHeight = CGRectGetHeight(safeRect);
    CGFloat preferredHeight = MIN(contentLength, MAX(72.0, CGRectGetHeight(sessionRect) * 0.95));
    CGFloat height = MIN(maxHeight, MAX(72.0, preferredHeight));
    CGFloat gap = 12.0;
    CGFloat y = CGRectGetMidY(sessionRect) - height * 0.5;
    y = TOWXV11Clamp(y, CGRectGetMinY(safeRect), CGRectGetMaxY(safeRect) - height);

    CGFloat rightX = CGRectGetMaxX(sessionRect) + gap;
    BOOL rightFits = rightX + width <= CGRectGetMaxX(safeRect);
    if (rightFits) {
        result.frame = CGRectMake(rightX, y, width, height);
        result.mode = TOWXV11AvatarPlacementRight;
        result.vertical = YES;
        return result;
    }

    CGFloat leftX = CGRectGetMinX(sessionRect) - gap - width;
    BOOL leftFits = leftX >= CGRectGetMinX(safeRect);
    if (leftFits) {
        result.frame = CGRectMake(leftX, y, width, height);
        result.mode = TOWXV11AvatarPlacementLeft;
        result.vertical = YES;
        return result;
    }

    CGFloat rightSpace = CGRectGetMaxX(safeRect) - CGRectGetMaxX(sessionRect);
    CGFloat leftSpace = CGRectGetMinX(sessionRect) - CGRectGetMinX(safeRect);
    CGFloat x = rightSpace >= leftSpace ? CGRectGetMaxX(safeRect) - width : CGRectGetMinX(safeRect);
    result.frame = CGRectMake(x, y, width, height);
    result.mode = rightSpace >= leftSpace ? TOWXV11AvatarPlacementRight : TOWXV11AvatarPlacementLeft;
    result.vertical = YES;
    return result;
}
