#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import "../Sources/WXIFRestorePolicy.h"

static void WXIFAssert(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        WXIFAssert(WXIFShouldRestoreConversationOffset(YES, 1800.0, -88.0, -88.0), @"jump-to-top should restore");
        WXIFAssert(!WXIFShouldRestoreConversationOffset(YES, 1800.0, 1770.0, -88.0), @"already-preserved offset must not restore");
        WXIFAssert(!WXIFShouldRestoreConversationOffset(YES, 1800.0, 620.0, -88.0), @"normal user scroll must not be fought");
        WXIFAssert(!WXIFShouldRestoreConversationOffset(YES, 4.0, -88.0, -88.0), @"near-top sessions do not need restore");
        WXIFAssert(!WXIFShouldRestoreConversationOffset(NO, 1800.0, -88.0, -88.0), @"disabled setting must never restore");
        WXIFAssert(WXIFShouldRestoreConversationOffset(YES, 600.0, 0.0, 0.0), @"zero-inset jump-to-top should restore");
        printf("WXIF restore policy tests passed\n");
    }
    return 0;
}
