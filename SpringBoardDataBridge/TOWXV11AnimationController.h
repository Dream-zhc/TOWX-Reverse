#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "TOWXV11PlacementEngine.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TOWXV11AvatarVisibilityState) {
    TOWXV11AvatarVisibilityHidden = 0,
    TOWXV11AvatarVisibilityAppearing,
    TOWXV11AvatarVisibilityVisible,
    TOWXV11AvatarVisibilityDisappearing,
};

@interface TOWXV11AnimationController : NSObject
@property (nonatomic, readonly) TOWXV11AvatarVisibilityState state;
- (instancetype)initWithView:(UIView *)view;
- (void)showFromPlacementMode:(TOWXV11AvatarPlacementMode)mode completion:(void (^ _Nullable)(BOOL finished))completion;
- (void)hideTowardPlacementMode:(TOWXV11AvatarPlacementMode)mode completion:(void (^ _Nullable)(BOOL finished))completion;
- (void)setVisibleImmediately;
- (void)setHiddenImmediately;
@end

NS_ASSUME_NONNULL_END
