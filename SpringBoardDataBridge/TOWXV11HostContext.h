#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const TOWXV11HostContextDidChangeNotification;
FOUNDATION_EXPORT NSString * _Nullable TOWXV11HostBundleIdentifier(void);
FOUNDATION_EXPORT NSString *TOWXV11HostBundleSource(void);
FOUNDATION_EXPORT void TOWXV11RefreshHostContext(const char *reason);

NS_ASSUME_NONNULL_END
