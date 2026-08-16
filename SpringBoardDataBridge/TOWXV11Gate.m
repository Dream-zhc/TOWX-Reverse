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
        /* Full-screen host is already WeChat: never draw the external rail. */
        show = NO;
        reason = "host-is-wechat";
    } else if (strictSplitBundle.length != 0) {
        /* Resolved split identity is authoritative. QQ/other apps are rejected here. */
        show = [strictSplitBundle isEqualToString:kTOWXV11WeChatBundle];
        reason = show ? "split-is-wechat" : "split-not-wechat";
    } else if (sessionBundleID.length != 0) {
        /* SessionController positive/negative identity is the second authority. */
        show = [sessionBundleID isEqualToString:kTOWXV11WeChatBundle];
        reason = show ? "session-is-wechat" : "session-not-wechat";
    } else if (weChatActive) {
        /* Fix9 recovery: TrollOpen 1.4.0 frequently exposes neither split nor session bundle.
           In that exact unresolved state, an active WeChat process plus a live TrollOpen session
           and non-zero avatar data is sufficient positive evidence to restore the rail.
           Any explicit QQ/other identity above still wins and hides immediately. */
        show = YES;
        reason = "wechat-active-recovery";
    } else {
        show = NO;
        reason = "identity-unresolved-inactive";
    }

    if (reasonOut) *reasonOut = reason;
    return show;
}

__attribute__((constructor)) static void TOWXV11GateMarker(void) {
    TOWXV11DiagLog("GATE", "LOADED|Smooth1-FIX9|resolved-identity-authoritative+wechat-active-recovery|qq-other-hide|host-wechat-hide");
}
