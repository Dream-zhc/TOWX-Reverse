#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, WXIFHapticStyle) {
    WXIFHapticStyleOff = 0,
    WXIFHapticStyleLight = 1,
    WXIFHapticStyleMedium = 2,
    WXIFHapticStyleHeavy = 3,
};

@interface WXIFSettings : NSObject
+ (void)registerDefaults;
+ (BOOL)gestureEnabled;
+ (void)setGestureEnabled:(BOOL)enabled;
+ (WXIFHapticStyle)hapticStyle;
+ (void)setHapticStyle:(WXIFHapticStyle)style;
+ (BOOL)conversationPositionFixEnabled;
+ (void)setConversationPositionFixEnabled:(BOOL)enabled;
@end

NS_ASSUME_NONNULL_END
