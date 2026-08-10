#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <notify.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define TOWX_P2A2_READY "com.dream.towx.p2a2.ready"
#define TOWX_P2A2_GENERATION "com.dream.towx.p2a2.generation"
#define TOWX_P2A2_COUNT "com.dream.towx.p2a2.count"
#define TOWX_P2A2_STAGE "com.dream.towx.p2a2.stage"

static const char *kLogDir = "/var/mobile/TrollOpenJB";
static const char *kLogPath = "/var/mobile/TrollOpenJB/phase2a2.log";

static int gReadyToken = 0;
static int gGenerationToken = 0;
static int gCountToken = 0;
static int gStageToken = 0;

static void TOWXEnsureLogDir(void) {
    (void)mkdir(kLogDir, 0755);
}

static void TOWXLog(const char *format, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    char body[768];
    va_list args;
    va_start(args, format);
    int bodyLength = vsnprintf(body, sizeof(body), format, args);
    va_end(args);
    if (bodyLength < 0) {
        close(fd);
        return;
    }

    char line[896];
    time_t now = time(NULL);
    int lineLength = snprintf(line, sizeof(line), "%lld %s\n", (long long)now, body);
    if (lineLength > 0) {
        size_t toWrite = (size_t)lineLength;
        if (toWrite > sizeof(line)) toWrite = sizeof(line);
        (void)write(fd, line, toWrite);
    }
    close(fd);
}

static const char *TOWXStageName(uint64_t stage) {
    switch (stage) {
        case 210: return "GOLDEN-MISSING";
        case 220: return "GOLDEN-FOUND";
        case 230: return "CACHE-WAIT";
        case 240: return "GOLDEN-COUNT";
        case 290: return "CACHE-BAD";
        default: return "UNKNOWN";
    }
}

static int TOWXRegisterState(const char *name, int *token) {
    uint32_t status = notify_register_check(name, token);
    if (status != NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|SB|P2A2|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
        return 0;
    }
    return 1;
}

static int TOWXReadToken(int token, uint64_t *value) {
    return notify_get_state(token, value) == NOTIFY_STATUS_OK;
}

static void TOWXHandleReady(void) {
    uint64_t generation = 0;
    uint64_t count = 0;
    uint64_t stage = 0;

    if (!TOWXReadToken(gGenerationToken, &generation) ||
        !TOWXReadToken(gCountToken, &count) ||
        !TOWXReadToken(gStageToken, &stage)) {
        TOWXLog("TOWX|SB|P2A2|STATE-READ-FAIL");
        return;
    }

    TOWXLog("TOWX|SB|P2A2|READY-RECV|generation=%llu|stage=%llu|stageName=%s|count=%llu",
            (unsigned long long)generation,
            (unsigned long long)stage,
            TOWXStageName(stage),
            (unsigned long long)count);

    if (stage == 220) {
        TOWXLog("TOWX|SB|P2A2|GOLDEN-FOUND-PASS|generation=%llu",
                (unsigned long long)generation);
    }
    if (stage == 240 && count > 0 && count <= 6) {
        TOWXLog("TOWX|SB|P2A2|COUNT-PASS|generation=%llu|count=%llu|source=golden-0.6-cache",
                (unsigned long long)generation,
                (unsigned long long)count);
    }
    if (stage == 290) {
        TOWXLog("TOWX|SB|P2A2|CACHE-BAD|generation=%llu|count=%llu",
                (unsigned long long)generation,
                (unsigned long long)count);
    }
}

__attribute__((constructor)) static void TOWXSpringBoardDataBridgeInit(void) {
    TOWXLog("TOWX|SB|P2A2|LOADED|v0.2.2|source=golden-0.6-adapter");

    if (!TOWXRegisterState(TOWX_P2A2_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_P2A2_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_P2A2_STAGE, &gStageToken)) {
        TOWXLog("TOWX|SB|P2A2|INIT-ABORT|state-registration");
        return;
    }

    dispatch_queue_t queue = dispatch_queue_create("com.dream.towx.p2a2.receiver", DISPATCH_QUEUE_SERIAL);
    uint32_t status = notify_register_dispatch(TOWX_P2A2_READY, &gReadyToken, queue, ^(int token) {
        (void)token;
        TOWXHandleReady();
    });
    if (status == NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|SB|P2A2|READY-LISTENER");
    } else {
        TOWXLog("TOWX|SB|P2A2|READY-LISTENER-FAIL|status=%u", status);
    }
}
