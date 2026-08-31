#import "WXIFSettings.h"

static NSString * const WXIFGestureEnabledKey = @"com.dream.wechatipadfix.gestureEnabled";
static NSString * const WXIFHapticStyleKey = @"com.dream.wechatipadfix.hapticStyle";
static NSString * const WXIFConversationFixKey = @"com.dream.wechatipadfix.conversationPositionFixEnabled";

@implementation WXIFSettings

+ (NSUserDefaults *)defaults {
    return NSUserDefaults.standardUserDefaults;
}

+ (void)registerDefaults {
    [[self defaults] registerDefaults:@{
        WXIFGestureEnabledKey: @YES,
        WXIFHapticStyleKey: @(WXIFHapticStyleMedium),
        WXIFConversationFixKey: @YES,
    }];
}

+ (BOOL)gestureEnabled {
    return [[self defaults] boolForKey:WXIFGestureEnabledKey];
}

+ (void)setGestureEnabled:(BOOL)enabled {
    [[self defaults] setBool:enabled forKey:WXIFGestureEnabledKey];
}

+ (WXIFHapticStyle)hapticStyle {
    NSInteger value = [[self defaults] integerForKey:WXIFHapticStyleKey];
    if (value < WXIFHapticStyleOff || value > WXIFHapticStyleHeavy) {
        return WXIFHapticStyleMedium;
    }
    return (WXIFHapticStyle)value;
}

+ (void)setHapticStyle:(WXIFHapticStyle)style {
    NSInteger safe = MAX(WXIFHapticStyleOff, MIN(WXIFHapticStyleHeavy, style));
    [[self defaults] setInteger:safe forKey:WXIFHapticStyleKey];
}

+ (BOOL)conversationPositionFixEnabled {
    return [[self defaults] boolForKey:WXIFConversationFixKey];
}

+ (void)setConversationPositionFixEnabled:(BOOL)enabled {
    [[self defaults] setBool:enabled forKey:WXIFConversationFixKey];
}

@end
