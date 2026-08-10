#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define TOWX_P2A2_READY "com.dream.towx.p2a2.ready"
#define TOWX_P2A2_GENERATION "com.dream.towx.p2a2.generation"
#define TOWX_P2A2_COUNT "com.dream.towx.p2a2.count"
#define TOWX_P2A2_STAGE "com.dream.towx.p2a2.stage"

#define TOWX_GOLDEN_IMAGE "TOWXWeChatStandalone.dylib"
#define TOWX_GOLDEN_TABLE_OFFSET ((uintptr_t)0x4070)
#define TOWX_GOLDEN_COUNT_OFFSET ((uintptr_t)0x4078)

static dispatch_source_t gTimer;
static uintptr_t gGoldenBase = 0;
static uint64_t gGeneration = 0;
static uint64_t gLastStage = UINT64_MAX;
static uint64_t gLastCount = UINT64_MAX;
static unsigned int gTick = 0;

static int gGenerationToken = 0;
static int gCountToken = 0;
static int gStageToken = 0;

static NSString *TOWXLogPath(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = paths.firstObject ?: NSTemporaryDirectory();
    return [dir stringByAppendingPathComponent:@"TOWX-GoldenAdapter.log"];
}

static void TOWXLog(const char *format, ...) {
    @autoreleasepool {
        char body[768];
        va_list args;
        va_start(args, format);
        int bodyLength = vsnprintf(body, sizeof(body), format, args);
        va_end(args);
        if (bodyLength < 0) return;

        char line[896];
        time_t now = time(NULL);
        int lineLength = snprintf(line, sizeof(line), "%lld %s\n", (long long)now, body);
        if (lineLength <= 0) return;

        NSString *path = TOWXLogPath();
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        size_t toWrite = (size_t)lineLength;
        if (toWrite > sizeof(line)) toWrite = sizeof(line);
        (void)write(fd, line, toWrite);
        close(fd);
    }
}

static int TOWXRegisterState(const char *name, int *token) {
    uint32_t status = notify_register_check(name, token);
    if (status != NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|WX|P2A2|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
        return 0;
    }
    return 1;
}

static int TOWXSetToken(int token, uint64_t value) {
    return notify_set_state(token, value) == NOTIFY_STATUS_OK;
}

static uintptr_t TOWXFindGoldenBase(void) {
    uint32_t imageCount = _dyld_image_count();
    for (uint32_t index = 0; index < imageCount; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == NULL || strstr(name, TOWX_GOLDEN_IMAGE) == NULL) continue;
        const struct mach_header *header = _dyld_get_image_header(index);
        if (header != NULL) {
            TOWXLog("TOWX|WX|P2A2|GOLDEN-FOUND|image=%s|base=0x%llx",
                    name, (unsigned long long)(uintptr_t)header);
            return (uintptr_t)header;
        }
    }
    return 0;
}

static void TOWXPublish(uint64_t stage, uint64_t count, int force) {
    if (!force && stage == gLastStage && count == gLastCount) return;

    gGeneration += 1;
    if (!TOWXSetToken(gGenerationToken, gGeneration) ||
        !TOWXSetToken(gCountToken, count) ||
        !TOWXSetToken(gStageToken, stage)) {
        TOWXLog("TOWX|WX|P2A2|STATE-WRITE-FAIL|generation=%llu|stage=%llu|count=%llu",
                (unsigned long long)gGeneration,
                (unsigned long long)stage,
                (unsigned long long)count);
        return;
    }

    gLastStage = stage;
    gLastCount = count;
    notify_post(TOWX_P2A2_READY);
    TOWXLog("TOWX|WX|P2A2|PUBLISH|generation=%llu|stage=%llu|count=%llu",
            (unsigned long long)gGeneration,
            (unsigned long long)stage,
            (unsigned long long)count);
}

static void TOWXTick(void) {
    @autoreleasepool {
        gTick += 1;
        int heartbeat = (gTick % 10U) == 0U;

        if (gGoldenBase == 0) {
            gGoldenBase = TOWXFindGoldenBase();
            if (gGoldenBase == 0) {
                TOWXPublish(210, 0, heartbeat);
                return;
            }
            TOWXPublish(220, 0, 1);
        }

        volatile uintptr_t *tableSlot = (volatile uintptr_t *)(gGoldenBase + TOWX_GOLDEN_TABLE_OFFSET);
        volatile uint32_t *countSlot = (volatile uint32_t *)(gGoldenBase + TOWX_GOLDEN_COUNT_OFFSET);
        uintptr_t table = *tableSlot;
        uint64_t count = (uint64_t)(*countSlot);

        if (count > 6U) {
            TOWXLog("TOWX|WX|P2A2|CACHE-BAD|table=0x%llx|count=%llu",
                    (unsigned long long)table,
                    (unsigned long long)count);
            TOWXPublish(290, count, heartbeat);
            return;
        }

        if (table == 0 || count == 0) {
            TOWXPublish(230, count, heartbeat);
            return;
        }

        TOWXPublish(240, count, heartbeat);
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|P2A2|ADAPTER-START|v0.2.2|goldenOffsets=table:0x4070,count:0x4078");

    if (!TOWXRegisterState(TOWX_P2A2_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_P2A2_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_P2A2_STAGE, &gStageToken)) {
        TOWXLog("TOWX|WX|P2A2|INIT-ABORT|state-registration");
        return;
    }

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gTimer == nil) {
        TOWXLog("TOWX|WX|P2A2|INIT-ABORT|timer");
        return;
    }
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)NSEC_PER_SEC,
                              (uint64_t)(NSEC_PER_SEC / 10));
    dispatch_source_set_event_handler(gTimer, ^{
        TOWXTick();
    });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void TOWXGoldenAdapterInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            TOWXStart();
        });
    });
}
