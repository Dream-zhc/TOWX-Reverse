#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <notify.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define TOWX_P2A_READY "com.dream.towx.p2a.ready"
#define TOWX_P2A_GENERATION "com.dream.towx.p2a.generation"
#define TOWX_P2A_COUNT "com.dream.towx.p2a.count"
#define TOWX_P2A_AVATAR0_LENGTH "com.dream.towx.p2a.avatar0.length"
#define TOWX_P2A_AVATAR0_HASH "com.dream.towx.p2a.avatar0.hash"
#define TOWX_P2A_CHUNK_PREFIX "com.dream.towx.p2a.avatar0.chunk."
#define TOWX_P2A_MAX_BYTES 4096U

static const char *kLogDir = "/var/mobile/TrollOpenJB";
static const char *kLogPath = "/var/mobile/TrollOpenJB/phase2a.log";
static const char *kAvatarPath = "/var/mobile/TrollOpenJB/avatar0-p2a.jpg";

static uint64_t TOWXFNV1a64(const uint8_t *bytes, size_t length) {
    uint64_t value = UINT64_C(1469598103934665603);
    for (size_t i = 0; i < length; i++) {
        value ^= (uint64_t)bytes[i];
        value *= UINT64_C(1099511628211);
    }
    return value;
}

static void TOWXEnsureLogDir(void) {
    (void)mkdir(kLogDir, 0755);
}

static void TOWXLog(const char *format, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) {
        return;
    }

    char message[768];
    va_list args;
    va_start(args, format);
    int bodyLength = vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    if (bodyLength < 0) {
        close(fd);
        return;
    }

    char line[896];
    time_t now = time(NULL);
    int lineLength = snprintf(line, sizeof(line), "%lld %s\n", (long long)now, message);
    if (lineLength > 0) {
        size_t toWrite = (size_t)lineLength;
        if (toWrite > sizeof(line)) {
            toWrite = sizeof(line);
        }
        (void)write(fd, line, toWrite);
    }
    close(fd);
}

static int TOWXReadState(const char *name, uint64_t *value) {
    int token = 0;
    uint32_t status = notify_register_check(name, &token);
    if (status != NOTIFY_STATUS_OK) {
        return 0;
    }
    status = notify_get_state(token, value);
    (void)notify_cancel(token);
    return status == NOTIFY_STATUS_OK;
}

static int TOWXReadAvatar(uint8_t *buffer, size_t length) {
    size_t chunkCount = (length + 7U) / 8U;
    for (size_t chunkIndex = 0; chunkIndex < chunkCount; chunkIndex++) {
        char name[128];
        (void)snprintf(name, sizeof(name), "%s%04zu", TOWX_P2A_CHUNK_PREFIX, chunkIndex);
        uint64_t state = 0;
        if (!TOWXReadState(name, &state)) {
            return 0;
        }
        for (size_t byteIndex = 0; byteIndex < 8U; byteIndex++) {
            size_t outputIndex = chunkIndex * 8U + byteIndex;
            if (outputIndex >= length) {
                break;
            }
            buffer[outputIndex] = (uint8_t)((state >> (byteIndex * 8U)) & UINT64_C(0xff));
        }
    }
    return 1;
}

static int TOWXWriteAvatar(const uint8_t *bytes, size_t length) {
    TOWXEnsureLogDir();
    int fd = open(kAvatarPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        return 0;
    }
    size_t offset = 0;
    while (offset < length) {
        ssize_t written = write(fd, bytes + offset, length - offset);
        if (written <= 0) {
            close(fd);
            return 0;
        }
        offset += (size_t)written;
    }
    (void)fsync(fd);
    close(fd);
    return 1;
}

static void TOWXHandleReady(void) {
    uint64_t generation = 0;
    uint64_t count = 0;
    uint64_t length64 = 0;
    uint64_t expectedHash = 0;

    if (!TOWXReadState(TOWX_P2A_GENERATION, &generation) ||
        !TOWXReadState(TOWX_P2A_COUNT, &count) ||
        !TOWXReadState(TOWX_P2A_AVATAR0_LENGTH, &length64) ||
        !TOWXReadState(TOWX_P2A_AVATAR0_HASH, &expectedHash)) {
        TOWXLog("TOWX|SB|P2A|META-READ-FAIL");
        return;
    }

    if (length64 == 0 || length64 > TOWX_P2A_MAX_BYTES) {
        TOWXLog("TOWX|SB|P2A|BAD-LENGTH|generation=%llu|count=%llu|length=%llu",
                (unsigned long long)generation,
                (unsigned long long)count,
                (unsigned long long)length64);
        return;
    }

    size_t length = (size_t)length64;
    uint8_t buffer[TOWX_P2A_MAX_BYTES];
    memset(buffer, 0, sizeof(buffer));
    if (!TOWXReadAvatar(buffer, length)) {
        TOWXLog("TOWX|SB|P2A|CHUNK-READ-FAIL|generation=%llu|length=%zu",
                (unsigned long long)generation, length);
        return;
    }

    uint64_t actualHash = TOWXFNV1a64(buffer, length);
    if (actualHash != expectedHash) {
        TOWXLog("TOWX|SB|P2A|HASH-MISMATCH|generation=%llu|expected=%016llx|actual=%016llx",
                (unsigned long long)generation,
                (unsigned long long)expectedHash,
                (unsigned long long)actualHash);
        return;
    }

    if (!TOWXWriteAvatar(buffer, length)) {
        TOWXLog("TOWX|SB|P2A|WRITE-FAIL|generation=%llu|length=%zu",
                (unsigned long long)generation, length);
        return;
    }

    TOWXLog("TOWX|SB|P2A|AVATAR0-PASS|generation=%llu|count=%llu|bytes=%zu|hash=%016llx|file=%s",
            (unsigned long long)generation,
            (unsigned long long)count,
            length,
            (unsigned long long)actualHash,
            kAvatarPath);
}

__attribute__((constructor)) static void TOWXSpringBoardDataBridgeInit(void) {
    TOWXLog("TOWX|SB|P2A|LOADED|v0.2.0");
    static int readyToken = 0;
    dispatch_queue_t queue = dispatch_queue_create("com.dream.towx.p2a.receiver", DISPATCH_QUEUE_SERIAL);
    uint32_t status = notify_register_dispatch(TOWX_P2A_READY, &readyToken, queue, ^(int token) {
        (void)token;
        TOWXHandleReady();
    });
    if (status == NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|SB|P2A|READY-LISTENER");
    } else {
        TOWXLog("TOWX|SB|P2A|READY-LISTENER-FAIL|status=%u", status);
    }
}
