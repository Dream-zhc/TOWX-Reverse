#import "TOWXV11Gate.h"
#import "TOWXV11Diagnostics.h"

BOOL TOWXV11ShouldShowAvatarModule(BOOL sessionVisible,
                                   NSString *sessionBundleID,
                                   BOOL weChatActive,
                                   NSUInteger avatarCount,
                                   const char **reasonOut) {
    const char *reason = "show";
    BOOL show = YES;

    if (!sessionVisible) {
        show = NO;
        reason = "session-gone";
    } else if (!weChatActive) {
        show = NO;
        reason = "wechat-inactive";
    } else if (avatarCount == 0) {
        show = NO;
        reason = "count-zero";
    } else if ([sessionBundleID isEqualToString:@"com.tencent.xin"]) {
        show = NO;
        reason = "session-is-wechat";
    } else if (sessionBundleID.length == 0) {
        /* Fail-open for UI continuity until the private TrollOpen bundle probe resolves. */
        show = YES;
        reason = "bundle-unresolved-show-safe";
    } else {
        show = YES;
        reason = "non-wechat-session";
    }

    if (reasonOut) *reasonOut = reason;
    return show;
}

__attribute__((constructor)) static void TOWXV11GateMarker(void) {
    TOWXV11DiagLog("GATE", "LOADED|Smooth1-S6|session-bundle-gate|wechat=com.tencent.xin");
}
