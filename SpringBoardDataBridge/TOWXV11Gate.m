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
        /* Product rule: if the underlying/full-screen host itself is WeChat, never show the
           external avatar module, regardless of which TrollOpen app is floating above it. */
        show = NO;
        reason = "host-is-wechat";
    } else if ([sessionBundleID isEqualToString:kTOWXV11WeChatBundle]) {
        /* TrollOpen can remote-host WeChat while UIApplication reports inactive, especially
           across landscape transitions. The floating-session identity is stronger than appActive. */
        show = YES;
        reason = weChatActive ? "floating-wechat-active" : "floating-wechat-remote";
    } else if (sessionBundleID.length == 0) {
        /* TOJBClass022 bundle resolution is best-effort. If the host is definitely not WeChat and
           we have valid exported contacts, fail open so rotation/session transitions do not blank UI. */
        show = YES;
        reason = weChatActive ? "session-unresolved-active" : "session-unresolved-remote";
    } else if (weChatActive) {
        show = YES;
        reason = "wechat-active-host-not-wechat";
    } else {
        show = NO;
        reason = "known-nonwechat-session-inactive";
    }

    if (reasonOut) *reasonOut = reason;
    return show;
}

__attribute__((constructor)) static void TOWXV11GateMarker(void) {
    TOWXV11DiagLog("GATE", "LOADED|Smooth1-FIX5|host-wechat-hard-hide|floating-wechat-active-signal-optional");
}
