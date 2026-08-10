#include <CoreFoundation/CoreFoundation.h>

static CFStringRef kWXReady;
static CFStringRef kPing;
static CFStringRef kPong;
static CFStringRef kWXAlive;
static CFStringRef kSBReady;
static CFNotificationCenterRef gCenter;
static int gObserverToken;

static void TOWXPost(CFStringRef name) {
    if (!gCenter || !name) return;
    CFNotificationCenterPostNotification(gCenter, name, NULL, NULL, true);
}

static void TOWXOnDarwin(CFNotificationCenterRef center,
                         void *observer,
                         CFStringRef name,
                         const void *object,
                         CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)object;
    (void)userInfo;

    if (CFEqual(name, kPing)) {
        TOWXPost(kPong);
    } else if (CFEqual(name, kSBReady)) {
        TOWXPost(kWXAlive);
        TOWXPost(kWXReady);
    }
}

__attribute__((constructor)) static void TOWXInit(void) {
    gCenter = CFNotificationCenterGetDarwinNotifyCenter();
    if (!gCenter) return;

    kWXReady = CFSTR("com.dream.towx.bridge.wx-ready");
    kPing    = CFSTR("com.dream.towx.bridge.ping");
    kPong    = CFSTR("com.dream.towx.bridge.pong");
    kWXAlive = CFSTR("com.dream.towx.bridge.wx-alive");
    kSBReady = CFSTR("com.dream.towx.bridge.sb-ready");

    CFNotificationCenterAddObserver(gCenter, &gObserverToken, TOWXOnDarwin, kPing, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(gCenter, &gObserverToken, TOWXOnDarwin, kSBReady, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    TOWXPost(kWXReady);
}
