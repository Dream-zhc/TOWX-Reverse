#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const TOWXV11SessionDidBeginNotification;
FOUNDATION_EXPORT NSNotificationName const TOWXV11SessionDidEndNotification;
FOUNDATION_EXPORT NSNotificationName const TOWXV11SessionDidChangeNotification;

FOUNDATION_EXPORT UIWindow * _Nullable TOWXV11CurrentSessionWindow(void);
FOUNDATION_EXPORT NSString * _Nullable TOWXV11CurrentSessionBundleIdentifier(void);
FOUNDATION_EXPORT uint64_t TOWXV11CurrentSessionEpoch(void);
FOUNDATION_EXPORT BOOL TOWXV11SessionIsVisible(void);
FOUNDATION_EXPORT BOOL TOWXV11SessionIsWeChat(void);
FOUNDATION_EXPORT UIInterfaceOrientation TOWXV11CurrentSessionOrientation(void);

/* Main-thread refresh entry point for later V11 modules and recovery paths. */
FOUNDATION_EXPORT void TOWXV11RefreshSession(const char *reason);

NS_ASSUME_NONNULL_END
