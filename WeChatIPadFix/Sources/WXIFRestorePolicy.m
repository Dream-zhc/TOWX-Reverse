#import "WXIFRestorePolicy.h"
#import <math.h>

BOOL WXIFShouldRestoreConversationOffset(BOOL enabled,
                                         double savedOffsetY,
                                         double currentOffsetY,
                                         double topOffsetY) {
    if (!enabled) return NO;
    if (savedOffsetY <= topOffsetY + 100.0) return NO;
    if (fabs(currentOffsetY - savedOffsetY) <= 45.0) return NO;
    return currentOffsetY <= topOffsetY + 90.0;
}
