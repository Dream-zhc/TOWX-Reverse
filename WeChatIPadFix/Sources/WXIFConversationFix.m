#import "WXIFConversationFix.h"
#import "WXIFMainFrameFix.h"

@implementation WXIFConversationFix

+ (void)startMonitoring {
    [WXIFMainFrameFix start];
}

+ (NSDictionary<NSString *,NSString *> *)diagnosticSnapshot {
    return [WXIFMainFrameFix diagnosticSnapshot];
}

@end
