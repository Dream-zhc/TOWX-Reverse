#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TOWXV11AvatarPlacementMode) {
    TOWXV11AvatarPlacementHidden = 0,
    TOWXV11AvatarPlacementBottom,
    TOWXV11AvatarPlacementTop,
    TOWXV11AvatarPlacementRight,
    TOWXV11AvatarPlacementLeft,
};

typedef struct {
    CGRect frame;
    TOWXV11AvatarPlacementMode mode;
    BOOL vertical;
} TOWXV11AvatarPlacement;

FOUNDATION_EXPORT TOWXV11AvatarPlacement TOWXV11ComputeAvatarPlacement(CGRect sessionRect,
                                                                       CGRect screenBounds,
                                                                       UIEdgeInsets safeInsets,
                                                                       UIInterfaceOrientation orientation,
                                                                       NSUInteger avatarCount);
FOUNDATION_EXPORT const char *TOWXV11PlacementModeName(TOWXV11AvatarPlacementMode mode);

NS_ASSUME_NONNULL_END
