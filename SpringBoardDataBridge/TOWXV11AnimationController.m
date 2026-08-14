#import "TOWXV11AnimationController.h"
#import "TOWXV11Diagnostics.h"
#import <QuartzCore/QuartzCore.h>

@interface TOWXV11AnimationController ()
@property (nonatomic, weak) UIView *view;
@property (nonatomic, strong) UIViewPropertyAnimator *animator;
@property (nonatomic, assign) TOWXV11AvatarVisibilityState state;
@property (nonatomic, assign) uint64_t serial;
@end

@implementation TOWXV11AnimationController

- (instancetype)initWithView:(UIView *)view {
    self = [super init];
    if (!self) return nil;
    _view = view;
    _state = TOWXV11AvatarVisibilityHidden;
    view.alpha = 0.0;
    view.transform = CGAffineTransformMakeScale(0.92, 0.92);
    view.userInteractionEnabled = NO;
    return self;
}

- (CGAffineTransform)transformForMode:(TOWXV11AvatarPlacementMode)mode scale:(CGFloat)scale distance:(CGFloat)distance {
    CGFloat dx = 0.0, dy = 0.0;
    switch (mode) {
        case TOWXV11AvatarPlacementTop: dy = -distance; break;
        case TOWXV11AvatarPlacementRight: dx = distance; break;
        case TOWXV11AvatarPlacementLeft: dx = -distance; break;
        case TOWXV11AvatarPlacementBottom:
        default: dy = distance; break;
    }
    return CGAffineTransformConcat(CGAffineTransformMakeScale(scale, scale), CGAffineTransformMakeTranslation(dx, dy));
}

- (void)capturePresentationStateIfNeeded {
    UIView *view = self.view;
    CALayer *presentation = (CALayer *)view.layer.presentationLayer;
    if (!view || !presentation) return;
    CGFloat alpha = presentation.opacity;
    CGAffineTransform transform = presentation.affineTransform;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    view.alpha = alpha;
    view.transform = transform;
    [CATransaction commit];
}

- (void)stopCurrentAnimatorPreservingPresentation {
    if (!self.animator) return;
    [self capturePresentationStateIfNeeded];
    [self.animator stopAnimation:YES];
    self.animator = nil;
}

- (void)showFromPlacementMode:(TOWXV11AvatarPlacementMode)mode completion:(void (^)(BOOL))completion {
    UIView *view = self.view;
    if (!view) return;
    if (self.state == TOWXV11AvatarVisibilityVisible && !self.animator) {
        view.userInteractionEnabled = YES;
        if (completion) completion(YES);
        return;
    }

    [self stopCurrentAnimatorPreservingPresentation];
    self.serial += 1;
    uint64_t serial = self.serial;
    BOOL fromHidden = self.state == TOWXV11AvatarVisibilityHidden || view.alpha <= 0.01;
    self.state = TOWXV11AvatarVisibilityAppearing;
    view.hidden = NO;
    view.userInteractionEnabled = YES;
    if (fromHidden) {
        view.alpha = 0.0;
        view.transform = [self transformForMode:mode scale:0.92 distance:12.0];
    }

    TOWXV11DiagLog("ANIM", "APPEAR-BEGIN|serial=%llu|mode=%s|alpha=%.3f",
                   (unsigned long long)serial, TOWXV11PlacementModeName(mode), view.alpha);

    UISpringTimingParameters *timing = [[UISpringTimingParameters alloc] initWithDampingRatio:0.86];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.32 timingParameters:timing];
    [animator addAnimations:^{
        view.alpha = 1.0;
        view.transform = CGAffineTransformIdentity;
    }];
    __weak typeof(self) weakSelf = self;
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || serial != self.serial) return;
        self.animator = nil;
        BOOL finished = position == UIViewAnimatingPositionEnd;
        if (finished) {
            self.state = TOWXV11AvatarVisibilityVisible;
            view.alpha = 1.0;
            view.transform = CGAffineTransformIdentity;
            view.userInteractionEnabled = YES;
        }
        TOWXV11DiagLog("ANIM", "APPEAR-END|serial=%llu|finished=%d|position=%ld",
                       (unsigned long long)serial, finished ? 1 : 0, (long)position);
        if (completion) completion(finished);
    }];
    self.animator = animator;
    [animator startAnimation];
}

- (void)hideTowardPlacementMode:(TOWXV11AvatarPlacementMode)mode completion:(void (^)(BOOL))completion {
    UIView *view = self.view;
    if (!view) return;
    if (self.state == TOWXV11AvatarVisibilityHidden && !self.animator) {
        view.userInteractionEnabled = NO;
        if (completion) completion(YES);
        return;
    }

    [self stopCurrentAnimatorPreservingPresentation];
    self.serial += 1;
    uint64_t serial = self.serial;
    self.state = TOWXV11AvatarVisibilityDisappearing;
    view.userInteractionEnabled = NO;

    TOWXV11DiagLog("ANIM", "DISAPPEAR-BEGIN|serial=%llu|mode=%s|alpha=%.3f",
                   (unsigned long long)serial, TOWXV11PlacementModeName(mode), view.alpha);

    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:0.20 curve:UIViewAnimationCurveEaseInOut animations:^{
        view.alpha = 0.0;
        view.transform = [self transformForMode:mode scale:0.96 distance:8.0];
    }];
    __weak typeof(self) weakSelf = self;
    [animator addCompletion:^(UIViewAnimatingPosition position) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || serial != self.serial) return;
        self.animator = nil;
        BOOL finished = position == UIViewAnimatingPositionEnd;
        if (finished) {
            self.state = TOWXV11AvatarVisibilityHidden;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
        }
        TOWXV11DiagLog("ANIM", "DISAPPEAR-END|serial=%llu|finished=%d|position=%ld",
                       (unsigned long long)serial, finished ? 1 : 0, (long)position);
        if (completion) completion(finished);
    }];
    self.animator = animator;
    [animator startAnimation];
}

- (void)setVisibleImmediately {
    [self.animator stopAnimation:YES];
    self.animator = nil;
    self.serial += 1;
    self.state = TOWXV11AvatarVisibilityVisible;
    self.view.hidden = NO;
    self.view.alpha = 1.0;
    self.view.transform = CGAffineTransformIdentity;
    self.view.userInteractionEnabled = YES;
    TOWXV11DiagLog("ANIM", "FORCE-VISIBLE|serial=%llu", (unsigned long long)self.serial);
}

- (void)setHiddenImmediately {
    [self.animator stopAnimation:YES];
    self.animator = nil;
    self.serial += 1;
    self.state = TOWXV11AvatarVisibilityHidden;
    self.view.alpha = 0.0;
    self.view.transform = CGAffineTransformMakeScale(0.96, 0.96);
    self.view.userInteractionEnabled = NO;
    TOWXV11DiagLog("ANIM", "FORCE-HIDDEN|serial=%llu", (unsigned long long)self.serial);
}

@end

__attribute__((constructor)) static void TOWXV11AnimationMarker(void) {
    TOWXV11DiagLog("ANIM", "LOADED|Smooth1-S5|interruptible-property-animator");
}
