#import "TOWXV11Gate.h"
#import "TOWXV11Diagnostics.h"

static NSString * const kTOWXV11WeChatBundle = @"com.tencent.xin";

BOOL TOWXV11ShouldShowAvatarModule(BOOL sessionVisible,
                                   NSString *sessionBundleID,
                                   NSString *hostBundleID,
                                   BOOL weChatActive,
                                   NSUInteger avatarCount,
                                   const char **reasonOut) {
    const char *reason = "show";
    BOOL show = YES;

    if (!sessionVisible) {
        show = NO;
        reason = "session-gone";
    } else if (avatarCount == 0) {
        show = NO;
        reason = "count-zero";
    } else if ([hostBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        /* Product rule: when the underlying/full-screen app is WeChat, the avatar rail is redundant,
           regardless of which app TrollOpen is floating above it. */
        show = NO;
        reason = "host-is-wechat";
    } else if (!weChatActive) {
        show = NO;
        reason = "wechat-inactive";
    } else if ([sessionBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        /* Desired primary case: WeChat itself is the floating TrollOpen app over Home/another app. */
        show = YES;
        reason = "floating-wechat";
    } else if (sessionBundleID.length == 0) {
        show = YES;
        reason = "session-unresolved-host-not-wechat";
    } else if (hostBundleID.length == 0) {
        /* If WeChat reports active but the floating app is known to be another app, fail closed until
           the underlying host resolver catches up. This avoids showing the rail inside full-screen WeChat. */
        show = NO;
        reason = "host-unresolved-safe-hide";
    } else {
        show = YES;
        reason = "host-not-wechat";
    }

    if (reasonOut) *reasonOut = reason;
    return show;
}

__attribute__((constructor)) static void TOWXV11GateMarker(void) {
    TOWXV11DiagLog("GATE", "LOADED|Smooth1-FIX1|underlying-host-gate|wechat=com.tencent.xin");
}
