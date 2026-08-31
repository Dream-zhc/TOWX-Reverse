#import <Foundation/Foundation.h>

@interface WXIFConversationFix : NSObject
+ (void)startMonitoring;
+ (NSDictionary<NSString *, NSString *> *)diagnosticSnapshot;
@end
