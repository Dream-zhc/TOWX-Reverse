#import "TOWXV11Gate.h"
#import "TOWXV11Diagnostics.h"

static NSString * const kTOWXV11WeChatBundle = @"com.tencent.xin";

BOOL TOWXV11ShouldShowAvatarModule(BOOL sessionVisible,
                                   NSString *sessionBundleID,
                                   NSString *hostBundleID,
                                   BOOL weChatActive,
                                   NSUInteger avatarCount,
                                   const char **reasonOut) {
    (void)weChatActive;
    const char *reason = "show";
    BOOL show = YES;

    if (!sessionVisible) {
        show = NO;
        reason = "session-gone";
    } else if (avatarCount == 0) {
        show = NO;
        reason = "count-zero";
    } else if (sessionBundleID.length == 0) {
        /* Fix7 is deliberately fail-closed. Cached WeChat contacts must never leak into
           QQ/Telegram/other TrollOpen sessions simply because identity resolution is late. */
        show = NO;
        reason = "split-unresolved";
    } else if (![sessionBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        show = NO;
        reason = "split-not-wechat";
    } else if ([hostBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        /* Product rule retained: when the underlying full-screen app is WeChat, do not add
           a second external avatar module on top of it. */
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
    TOWXV11DiagLog("GATE", "LOADED|Smooth1-FIX7|strict-floating-wechat-only|qq-other-hide|unresolved-hide");
}
