#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TOWXV11FollowerUpdateHandler)(CGRect visualRect, BOOL tracking);

FOUNDATION_EXPORT void TOWXV11FollowerSetUpdateHandler(TOWXV11FollowerUpdateHandler _Nullable handler);
FOUNDATION_EXPORT void TOWXV11FollowerSetEnabled(BOOL enabled);
FOUNDATION_EXPORT BOOL TOWXV11FollowerIsEnabled(void);
FOUNDATION_EXPORT BOOL TOWXV11FollowerIsTracking(void);
FOUNDATION_EXPORT CGRect TOWXV11FollowerCurrentVisualRect(void);

NS_ASSUME_NONNULL_END
