#import "TOWXV11Gate.h"
#import "TOWXV11SplitIdentity.h"
#import "TOWXV11Diagnostics.h"

static NSString * const kTOWXV11WeChatBundle = @"com.tencent.xin";

BOOL TOWXV11ShouldShowAvatarModule(BOOL sessionVisible,
                                   NSString *sessionBundleID,
                                   NSString *hostBundleID,
                                   BOOL weChatActive,
                                   NSUInteger avatarCount,
                                   const char **reasonOut) {
    (void)sessionBundleID;
    (void)weChatActive;
    NSString *strictSplitBundle = TOWXV11SplitBundleIdentifier();
    const char *reason = "show";
    BOOL show = YES;

    if (!sessionVisible) {
        show = NO;
        reason = "session-gone";
    } else if (avatarCount == 0) {
        show = NO;
        reason = "count-zero";
    } else if (strictSplitBundle.length == 0) {
        show = NO;
        reason = "split-unresolved";
    } else if (![strictSplitBundle isEqualToString:kTOWXV11WeChatBundle]) {
        show = NO;
        reason = "split-not-wechat";
    } else if ([hostBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        show = NO;
        reason = "host-is-wechat";
    } else {
        show = YES;
        reason = "split-is-wechat";
    }

    if (reasonOut) *reasonOut = reason;
    return show;
}

__attribute__((constructor)) static void TOWXV11GateMarker(void) {
    TOWXV11DiagLog("GATE", "LOADED|Smooth1-FIX7|SplitIdentity-authoritative|wechat-only|qq-other-hide|unresolved-hide");
}
