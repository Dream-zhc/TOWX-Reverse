#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT BOOL TOWXV11ShouldShowAvatarModule(BOOL sessionVisible,
                                                     NSString * _Nullable sessionBundleID,
                                                     BOOL weChatActive,
                                                     NSUInteger avatarCount,
                                                     const char * _Nullable * _Nullable reasonOut);

NS_ASSUME_NONNULL_END
