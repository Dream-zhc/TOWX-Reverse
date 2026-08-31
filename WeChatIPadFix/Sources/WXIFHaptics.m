#import "WXIFHaptics.h"
#import "WXIFSettings.h"
#import <UIKit/UIKit.h>

@implementation WXIFHaptics

+ (void)emitConfiguredImpact {
    WXIFHapticStyle style = [WXIFSettings hapticStyle];
    if (style == WXIFHapticStyleOff) return;

    UIImpactFeedbackStyle feedbackStyle = UIImpactFeedbackStyleMedium;
    switch (style) {
        case WXIFHapticStyleLight: feedbackStyle = UIImpactFeedbackStyleLight; break;
        case WXIFHapticStyleMedium: feedbackStyle = UIImpactFeedbackStyleMedium; break;
        case WXIFHapticStyleHeavy: feedbackStyle = UIImpactFeedbackStyleHeavy; break;
        case WXIFHapticStyleOff: return;
    }

    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:feedbackStyle];
    [generator prepare];
    [generator impactOccurred];
}

@end
