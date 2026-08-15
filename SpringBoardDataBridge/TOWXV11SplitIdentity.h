#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const TOWXV11SplitIdentityDidChangeNotification;

FOUNDATION_EXPORT void TOWXV11SplitIdentityStart(void);
FOUNDATION_EXPORT void TOWXV11SplitIdentityRefresh(const char *reason);
FOUNDATION_EXPORT NSString * _Nullable TOWXV11SplitBundleIdentifier(void);
FOUNDATION_EXPORT NSString *TOWXV11SplitBundleSource(void);
FOUNDATION_EXPORT BOOL TOWXV11SplitIsWeChat(void);

NS_ASSUME_NONNULL_END
