#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const TOWXV11KeyboardStateDidChangeNotification;

FOUNDATION_EXPORT void TOWXV11KeyboardStartObserving(void);
FOUNDATION_EXPORT BOOL TOWXV11KeyboardVisible(void);
FOUNDATION_EXPORT CGRect TOWXV11KeyboardFrame(void);
FOUNDATION_EXPORT NSString *TOWXV11KeyboardSource(void);
FOUNDATION_EXPORT void TOWXV11KeyboardRefresh(const char *reason);

NS_ASSUME_NONNULL_END
