#include <CoreFoundation/CoreFoundation.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define TOWX_LOG_DIR  "/var/mobile/TrollOpenJB"
#define TOWX_LOG_PATH "/var/mobile/TrollOpenJB/bridge_probe.log"

static CFStringRef kWXReady;
static CFStringRef kPing;
static CFStringRef kPong;
static CFStringRef kWXAlive;
static CFStringRef kSBReady;
static CFNotificationCenterRef gCenter;
static int gObserverToken;

static void TOWXAppend(const char *fmt, ...) {
    (void)mkdir(TOWX_LOG_DIR, 0755);
    int fd = open(TOWX_LOG_PATH, O_CREAT | O_WRONLY | O_APPEND, 0644);
    if (fd < 0) return;

    char message[512];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(message, sizeof(message), fmt, ap);
    va_end(ap);
    if (n < 0) {
        close(fd);
        return;
    }
    if ((size_t)n >= sizeof(message)) n = (int)sizeof(message) - 1;

    char line[640];
    time_t now = time(NULL);
    int m = snprintf(line, sizeof(line), "%lld %s\n", (long long)now, message);
    if (m > 0) {
        if ((size_t)m >= sizeof(line)) m = (int)sizeof(line) - 1;
        (void)write(fd, line, (size_t)m);
    }
    close(fd);
}

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

    if (CFEqual(name, kWXReady)) {
        TOWXAppend("TOWX|SB|WX-READY-RECV");
        TOWXAppend("TOWX|SB|PING-SEND");
        TOWXPost(kPing);
    } else if (CFEqual(name, kPong)) {
        TOWXAppend("TOWX|SB|PONG-RECV|PASS");
    } else if (CFEqual(name, kWXAlive)) {
        TOWXAppend("TOWX|SB|WX-ALIVE-RECV");
    }
}

__attribute__((constructor)) static void TOWXInit(void) {
    TOWXAppend("TOWX|SB|LOADED|v0.1.0");

    gCenter = CFNotificationCenterGetDarwinNotifyCenter();
    if (!gCenter) {
        TOWXAppend("TOWX|SB|DARWIN-CENTER-FAIL");
        return;
    }

    kWXReady = CFSTR("com.dream.towx.bridge.wx-ready");
    kPing    = CFSTR("com.dream.towx.bridge.ping");
    kPong    = CFSTR("com.dream.towx.bridge.pong");
    kWXAlive = CFSTR("com.dream.towx.bridge.wx-alive");
    kSBReady = CFSTR("com.dream.towx.bridge.sb-ready");

    CFNotificationCenterAddObserver(gCenter, &gObserverToken, TOWXOnDarwin, kWXReady, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(gCenter, &gObserverToken, TOWXOnDarwin, kPong, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(gCenter, &gObserverToken, TOWXOnDarwin, kWXAlive, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    TOWXAppend("TOWX|SB|IPC-READY|DARWIN");
    TOWXPost(kSBReady);
}
