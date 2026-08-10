#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
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

#define TOWX_LINK_READY "com.dream.towx.link.ready"
#define TOWX_LINK_ACK "com.dream.towx.link.openAck"
#define TOWX_LINK_GENERATION "com.dream.towx.link.generation"
#define TOWX_LINK_COUNT "com.dream.towx.link.count"
#define TOWX_LINK_STAGE "com.dream.towx.link.stage"
#define TOWX_LINK_ACK_INDEX "com.dream.towx.link.ackIndex"
#define TOWX_LINK_OPEN_PREFIX "com.dream.towx.link.open."

#define TOWX_GOLDEN_IMAGE "TOWXWeChatStandalone.dylib"
#define TOWX_GOLDEN_CONTROLLER_OFFSET ((uintptr_t)0x4040)
#define TOWX_GOLDEN_BAR_OFFSET ((uintptr_t)0x4050)
#define TOWX_GOLDEN_TABLE_OFFSET ((uintptr_t)0x4070)
#define TOWX_GOLDEN_COUNT_OFFSET ((uintptr_t)0x4078)
#define TOWX_MAX_RECENTS 6U

static dispatch_source_t gTimer;
static uintptr_t gGoldenBase = 0;
static uint64_t gGeneration = 0;
static uint64_t gLastStage = UINT64_MAX;
static uint64_t gLastCount = UINT64_MAX;
static NSUInteger gAvatarHashes[TOWX_MAX_RECENTS];
static unsigned int gTick = 0;

static int gGenerationToken = 0;
static int gCountToken = 0;
static int gStageToken = 0;
static int gAckIndexToken = 0;
static int gOpenTokens[TOWX_MAX_RECENTS];

static NSString *TOWXCachesRoot(void) {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *TOWXExportDir(void) {
    NSString *dir = [TOWXCachesRoot() stringByAppendingPathComponent:@"TOWXLinkP2A3"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

static NSString *TOWXLogPath(void) {
    return [TOWXCachesRoot() stringByAppendingPathComponent:@"TOWX-Link-WeChat.log"];
}

static void TOWXLog(const char *format, ...) {
    @autoreleasepool {
        char body[896];
        va_list args;
        va_start(args, format);
        int bodyLength = vsnprintf(body, sizeof(body), format, args);
        va_end(args);
        if (bodyLength < 0) return;

        char line[1024];
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
        TOWXLog("TOWX|WX|LINK|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
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
            TOWXLog("TOWX|WX|LINK|GOLDEN-FOUND|image=%s|base=0x%llx",
                    name, (unsigned long long)(uintptr_t)header);
            return (uintptr_t)header;
        }
    }
    return 0;
}

static id TOWXGoldenObjectAtOffset(uintptr_t offset) {
    if (gGoldenBase == 0) return nil;
    volatile uintptr_t *slot = (volatile uintptr_t *)(gGoldenBase + offset);
    uintptr_t raw = *slot;
    if (raw == 0) return nil;
    return (__bridge id)(void *)raw;
}

static uint64_t TOWXGoldenCount(void) {
    if (gGoldenBase == 0) return 0;
    volatile uint32_t *slot = (volatile uint32_t *)(gGoldenBase + TOWX_GOLDEN_COUNT_OFFSET);
    return (uint64_t)(*slot);
}

static UIButton *TOWXFindButton(UIView *view, NSInteger tag) {
    if ([view isKindOfClass:[UIButton class]] && view.tag == tag) {
        return (UIButton *)view;
    }
    for (UIView *subview in view.subviews) {
        UIButton *found = TOWXFindButton(subview, tag);
        if (found != nil) return found;
    }
    return nil;
}

static void TOWXPublish(uint64_t stage, uint64_t count, int force) {
    if (!force && stage == gLastStage && count == gLastCount) return;

    gGeneration += 1;
    if (!TOWXSetToken(gGenerationToken, gGeneration) ||
        !TOWXSetToken(gCountToken, count) ||
        !TOWXSetToken(gStageToken, stage)) {
        TOWXLog("TOWX|WX|LINK|STATE-WRITE-FAIL|generation=%llu|stage=%llu|count=%llu",
                (unsigned long long)gGeneration,
                (unsigned long long)stage,
                (unsigned long long)count);
        return;
    }

    gLastStage = stage;
    gLastCount = count;
    notify_post(TOWX_LINK_READY);
    TOWXLog("TOWX|WX|LINK|PUBLISH|generation=%llu|stage=%llu|count=%llu",
            (unsigned long long)gGeneration,
            (unsigned long long)stage,
            (unsigned long long)count);
}

static NSUInteger TOWXExportAvatars(UIView *bar, NSUInteger count, BOOL *changedOut) {
    NSUInteger exported = 0;
    BOOL changed = NO;
    NSString *dir = TOWXExportDir();

    NSUInteger limited = MIN((NSUInteger)TOWX_MAX_RECENTS, count);
    for (NSUInteger index = 0; index < limited; index++) {
        UIButton *button = TOWXFindButton(bar, (NSInteger)(100U + index));
        if (button == nil) {
            TOWXLog("TOWX|WX|LINK|AVATAR-BUTTON-MISS|index=%lu", (unsigned long)index);
            continue;
        }

        UIImage *image = [button imageForState:UIControlStateNormal];
        if (image == nil) image = button.currentImage;
        if (image == nil) image = button.imageView.image;
        if (image == nil) {
            TOWXLog("TOWX|WX|LINK|AVATAR-IMAGE-MISS|index=%lu", (unsigned long)index);
            continue;
        }

        NSData *data = UIImagePNGRepresentation(image);
        if (data.length == 0) {
            TOWXLog("TOWX|WX|LINK|AVATAR-ENCODE-FAIL|index=%lu", (unsigned long)index);
            continue;
        }

        NSUInteger hash = data.hash;
        NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        if (gAvatarHashes[index] != hash || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSError *error = nil;
            if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
                TOWXLog("TOWX|WX|LINK|AVATAR-WRITE-FAIL|index=%lu|error=%s",
                        (unsigned long)index, error.localizedDescription.UTF8String ?: "unknown");
                continue;
            }
            gAvatarHashes[index] = hash;
            changed = YES;
            TOWXLog("TOWX|WX|LINK|AVATAR-EXPORT|index=%lu|bytes=%lu|hash=%lu|path=%s",
                    (unsigned long)index,
                    (unsigned long)data.length,
                    (unsigned long)hash,
                    path.UTF8String);
        }
        exported += 1;
    }

    for (NSUInteger index = limited; index < TOWX_MAX_RECENTS; index++) {
        NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            gAvatarHashes[index] = 0;
            changed = YES;
        }
    }

    if (changedOut != NULL) *changedOut = changed;
    return exported;
}

static void TOWXOpenRecent(NSUInteger index) {
    @autoreleasepool {
        if (gGoldenBase == 0) gGoldenBase = TOWXFindGoldenBase();
        if (gGoldenBase == 0) {
            TOWXLog("TOWX|WX|LINK|OPEN-MISS|index=%lu|reason=golden", (unsigned long)index);
            return;
        }

        uint64_t count = TOWXGoldenCount();
        id controller = TOWXGoldenObjectAtOffset(TOWX_GOLDEN_CONTROLLER_OFFSET);
        if (controller == nil || index >= count || index >= TOWX_MAX_RECENTS) {
            TOWXLog("TOWX|WX|LINK|OPEN-MISS|index=%lu|count=%llu|controller=%s",
                    (unsigned long)index,
                    (unsigned long long)count,
                    controller ? "yes" : "no");
            return;
        }

        SEL action = NSSelectorFromString(@"towxAvatarTapped:");
        if (![controller respondsToSelector:action]) {
            TOWXLog("TOWX|WX|LINK|OPEN-MISS|index=%lu|reason=selector", (unsigned long)index);
            return;
        }

        UIButton *sender = [UIButton buttonWithType:UIButtonTypeCustom];
        sender.tag = (NSInteger)(100U + index);
        ((void (*)(id, SEL, id))objc_msgSend)(controller, action, sender);
        (void)TOWXSetToken(gAckIndexToken, (uint64_t)index);
        notify_post(TOWX_LINK_ACK);
        TOWXLog("TOWX|WX|LINK|OPEN-INVOKE|index=%lu|count=%llu|method=towxAvatarTapped:",
                (unsigned long)index, (unsigned long long)count);
    }
}

static void TOWXTick(void) {
    @autoreleasepool {
        gTick += 1;
        int heartbeat = (gTick % 5U) == 0U;

        if (gGoldenBase == 0) {
            gGoldenBase = TOWXFindGoldenBase();
            if (gGoldenBase == 0) {
                TOWXPublish(310, 0, heartbeat);
                return;
            }
            TOWXPublish(320, 0, 1);
        }

        id table = TOWXGoldenObjectAtOffset(TOWX_GOLDEN_TABLE_OFFSET);
        UIView *bar = (UIView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_BAR_OFFSET);
        uint64_t count64 = TOWXGoldenCount();
        if (count64 > TOWX_MAX_RECENTS) {
            TOWXLog("TOWX|WX|LINK|CACHE-BAD|count=%llu", (unsigned long long)count64);
            TOWXPublish(390, count64, heartbeat);
            return;
        }

        if (table == nil || bar == nil || count64 == 0) {
            TOWXPublish(330, count64, heartbeat);
            return;
        }

        BOOL changed = NO;
        NSUInteger exported = TOWXExportAvatars(bar, (NSUInteger)count64, &changed);
        if (exported == 0) {
            TOWXPublish(340, count64, heartbeat);
            return;
        }

        TOWXLog("TOWX|WX|LINK|EXPORT-PASS|count=%llu|exported=%lu|changed=%s",
                (unsigned long long)count64,
                (unsigned long)exported,
                changed ? "yes" : "no");
        TOWXPublish(350, count64, changed || heartbeat);
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|LINK|ADAPTER-START|v0.3.0|golden=0.6.0-clean1|offsets=controller:0x4040,bar:0x4050,table:0x4070,count:0x4078");

    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) {
        TOWXLog("TOWX|WX|LINK|INIT-ABORT|state-registration");
        return;
    }

    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        char name[96];
        (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
        uint32_t status = notify_register_dispatch(name,
                                                   &gOpenTokens[index],
                                                   dispatch_get_main_queue(),
                                                   ^(int token) {
            (void)token;
            TOWXOpenRecent(index);
        });
        if (status != NOTIFY_STATUS_OK) {
            TOWXLog("TOWX|WX|LINK|OPEN-LISTENER-FAIL|index=%lu|status=%u",
                    (unsigned long)index, status);
        }
    }

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gTimer == nil) {
        TOWXLog("TOWX|WX|LINK|INIT-ABORT|timer");
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
