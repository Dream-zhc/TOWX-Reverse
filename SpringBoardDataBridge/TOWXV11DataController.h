#pragma once

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSNotificationName const TOWXV11DataDidChangeNotification;

FOUNDATION_EXPORT NSUInteger TOWXV11DataAvatarCount(void);
FOUNDATION_EXPORT BOOL TOWXV11DataWeChatActive(void);
FOUNDATION_EXPORT uint64_t TOWXV11DataStage(void);
FOUNDATION_EXPORT uint64_t TOWXV11DataGeneration(void);
FOUNDATION_EXPORT NSInteger TOWXV11DataSelectedIndex(void);
FOUNDATION_EXPORT NSArray *TOWXV11DataAvatarImages(void);
FOUNDATION_EXPORT void TOWXV11DataSendOpen(NSUInteger index);

NS_ASSUME_NONNULL_END
