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
    } else if ([hostBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        /* The full-screen host is already WeChat. The external TrollOpen avatar rail is only for
           a floating WeChat session above another host app. */
        show = NO;
        reason = "host-is-wechat";
    } else if (strictSplitBundle.length != 0) {
        /* A resolved SplitIdentity is authoritative. This preserves the QQ/other-app hard-hide fix. */
        show = [strictSplitBundle isEqualToString:kTOWXV11WeChatBundle];
        reason = show ? "split-is-wechat" : "split-not-wechat";
    } else if ([sessionBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        /* Fix8 recovery path: TrollOpen 1.4.0 does not reliably expose a dedicated split identity
           on every presentation. The existing SessionController can still positively identify
           com.tencent.xin. Positive WeChat identification may show; unresolved state never may. */
        show = YES;
        reason = "session-is-wechat-fallback";
    } else {
        /* Fail closed. In particular, do not revive Fix5's "contacts exist => show" behavior. */
        show = NO;
        reason = sessionBundleID.length ? "session-not-wechat" : "identity-unresolved";
    }

    if (reasonOut) *reasonOut = reason;
    return show;
}

__attribute__((constructor)) static void TOWXV11GateMarker(void) {
    TOWXV11DiagLog("GATE", "LOADED|Smooth1-FIX8|split-authoritative+positive-session-wechat-fallback|qq-other-hide|unresolved-hide");
}
