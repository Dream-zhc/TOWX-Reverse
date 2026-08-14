#import "TOWXV11DataController.h"
#import "TOWXV11Diagnostics.h"

#import <ImageIO/ImageIO.h>
#import <objc/message.h>
#include <notify.h>
#include <string.h>

#define TOWX_LINK_READY "com.dream.towx.link.ready"
#define TOWX_LINK_ACK "com.dream.towx.link.openAck"
#define TOWX_LINK_GENERATION "com.dream.towx.link.generation"
#define TOWX_LINK_COUNT "com.dream.towx.link.count"
#define TOWX_LINK_STAGE "com.dream.towx.link.stage"
#define TOWX_LINK_ACK_INDEX "com.dream.towx.link.ackIndex"
#define TOWX_LINK_APP_ACTIVE "com.dream.towx.link.appActive"
#define TOWX_LINK_OPEN_PREFIX "com.dream.towx.link.open."
#define TOWXV11_MAX_RECENTS_FIX3 15U

NSNotificationName const TOWXV11DataDidChangeNotification = @"com.dream.towx.v11.data.change";

static int gReadyToken = 0;
static int gAckToken = 0;
static int gGenerationToken = 0;
static int gCountToken = 0;
static int gStageToken = 0;
static int gAckIndexToken = 0;
static int gAppActiveToken = 0;
static dispatch_queue_t gDataQueue = nil;
static dispatch_source_t gWatchdog = nil;

static NSUInteger gMainCount = 0;
static BOOL gMainWeChatActive = NO;
static uint64_t gMainStage = 0;
static uint64_t gMainGeneration = 0;
static NSInteger gMainSelectedIndex = NSNotFound;
static NSArray *gMainImages = nil;

static uint64_t gRawCount = UINT64_MAX;
static uint64_t gRawStage = UINT64_MAX;
static uint64_t gRawGeneration = UINT64_MAX;
static uint64_t gRawActive = UINT64_MAX;
static NSString *gExportDir = nil;
static NSMutableArray *gDecodedImages = nil;
static NSMutableArray *gImageMtimes = nil;

static int TOWXRegisterStateFix3(const char *name, int *token) {
    uint32_t status = notify_register_check(name, token);
    if (status != NOTIFY_STATUS_OK) {
        TOWXV11DiagLog("DATA", "STATE-REGISTER-FAIL|fix=3|name=%s|status=%u", name, status);
        return 0;
    }
    return 1;
}

static BOOL TOWXReadStateFix3(int token, uint64_t *value) {
    return notify_get_state(token, value) == NOTIFY_STATUS_OK;
}

static NSString *TOWXResolveExportDirFix3(void) {
    if (gExportDir.length && [[NSFileManager defaultManager] fileExistsAtPath:gExportDir]) return gExportDir;
    gExportDir = nil;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL appSelector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [(id)proxyClass respondsToSelector:appSelector]) {
        @try {
            id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, appSelector, @"com.tencent.xin");
            SEL dataSelector = NSSelectorFromString(@"dataContainerURL");
            if (proxy && [proxy respondsToSelector:dataSelector]) {
                NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, dataSelector);
                if ([url isKindOfClass:[NSURL class]]) {
                    gExportDir = [[[[url path] stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"] copy];
                }
            }
        } @catch (__unused NSException *exception) {
            gExportDir = nil;
        }
    }

    if (!gExportDir.length) {
        NSString *root = @"/var/mobile/Containers/Data/Application";
        NSArray *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
        for (NSString *item in items) {
            NSString *container = [root stringByAppendingPathComponent:item];
            NSString *metaPath = [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
            if ([meta[@"MCMMetadataIdentifier"] isEqualToString:@"com.tencent.xin"]) {
                gExportDir = [[[container stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"] copy];
                break;
            }
        }
    }

    if (gExportDir.length) TOWXV11DiagLog("DATA", "EXPORT-DIR|fix=3|path=%s", gExportDir.UTF8String ?: "?");
    else TOWXV11DiagLog("DATA", "EXPORT-DIR-MISS|fix=3");
    return gExportDir;
}

static UIImage *TOWXDecodeAvatarFix3(NSString *path) {
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!source) return nil;
    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @160,
        (__bridge NSString *)kCGImageSourceShouldCacheImmediately: @YES,
    };
    CGImageRef cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!cgImage) return nil;
    UIImage *image = [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cgImage);
    return image;
}

static void TOWXPublishImagesFix3(NSArray *images, NSUInteger loaded) {
    dispatch_async(dispatch_get_main_queue(), ^{
        gMainImages = [images copy] ?: @[];
        TOWXV11DiagLog("DATA", "IMAGE-APPLY|fix=3|count=%lu|loaded=%lu", (unsigned long)gMainCount, (unsigned long)loaded);
        [[NSNotificationCenter defaultCenter] postNotificationName:TOWXV11DataDidChangeNotification object:nil];
    });
}

static void TOWXEnsureImageArraysFix3(void) {
    if (gDecodedImages && gImageMtimes) return;
    gDecodedImages = [NSMutableArray arrayWithCapacity:TOWXV11_MAX_RECENTS_FIX3];
    gImageMtimes = [NSMutableArray arrayWithCapacity:TOWXV11_MAX_RECENTS_FIX3];
    for (NSUInteger i = 0; i < TOWXV11_MAX_RECENTS_FIX3; i++) {
        [gDecodedImages addObject:NSNull.null];
        [gImageMtimes addObject:NSNull.null];
    }
}

static void TOWXLoadImagesFix3(NSUInteger count) {
    if (!gDataQueue) return;
    dispatch_async(gDataQueue, ^{
        TOWXEnsureImageArraysFix3();
        NSString *dir = TOWXResolveExportDirFix3();
        NSUInteger limited = MIN(count, (NSUInteger)TOWXV11_MAX_RECENTS_FIX3);
        NSUInteger loaded = 0;

        for (NSUInteger i = 0; i < TOWXV11_MAX_RECENTS_FIX3; i++) {
            if (!dir.length || i >= limited) {
                gDecodedImages[i] = NSNull.null;
                gImageMtimes[i] = NSNull.null;
                continue;
            }
            NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)i]];
            NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            NSDate *mtime = attrs[NSFileModificationDate];
            id oldMtime = gImageMtimes[i];
            id oldImage = gDecodedImages[i];
            if (mtime && [oldMtime isKindOfClass:[NSDate class]] && [oldMtime isEqual:mtime] && [oldImage isKindOfClass:[UIImage class]]) {
                loaded += 1;
                continue;
            }
            UIImage *image = TOWXDecodeAvatarFix3(path);
            if (image) {
                gDecodedImages[i] = image;
                gImageMtimes[i] = mtime ?: NSDate.date;
                loaded += 1;
                TOWXV11DiagLog("DATA", "LOAD-END|fix=3|index=%lu|ok=1", (unsigned long)i);
            } else {
                gDecodedImages[i] = NSNull.null;
                gImageMtimes[i] = NSNull.null;
                TOWXV11DiagLog("DATA", "LOAD-END|fix=3|index=%lu|ok=0", (unsigned long)i);
            }
        }
        TOWXPublishImagesFix3([gDecodedImages copy], loaded);
    });
}

static void TOWXApplyRemoteStateFix3(uint64_t generation, uint64_t count, uint64_t stage, uint64_t active, const char *reason) {
    NSUInteger limited = MIN((NSUInteger)count, (NSUInteger)TOWXV11_MAX_RECENTS_FIX3);
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL changed = gMainGeneration != generation || gMainCount != limited || gMainStage != stage || gMainWeChatActive != (active != 0);
        gMainGeneration = generation;
        gMainCount = limited;
        gMainStage = stage;
        gMainWeChatActive = active != 0;
        TOWXV11DiagLog("DATA", "STATE|fix=3|reason=%s|generation=%llu|remoteCount=%llu|count=%lu|stage=%llu|active=%d",
                       reason ?: "?",
                       (unsigned long long)generation,
                       (unsigned long long)count,
                       (unsigned long)limited,
                       (unsigned long long)stage,
                       gMainWeChatActive ? 1 : 0);
        if (changed) [[NSNotificationCenter defaultCenter] postNotificationName:TOWXV11DataDidChangeNotification object:nil];
        TOWXLoadImagesFix3(limited);
    });
}

static void TOWXRefreshRemoteStateFix3(const char *reason) {
    uint64_t generation = 0, count = 0, stage = 0, active = 0;
    if (!TOWXReadStateFix3(gGenerationToken, &generation) ||
        !TOWXReadStateFix3(gCountToken, &count) ||
        !TOWXReadStateFix3(gStageToken, &stage) ||
        !TOWXReadStateFix3(gAppActiveToken, &active)) {
        TOWXV11DiagLog("DATA", "STATE-READ-FAIL|fix=3|reason=%s", reason ?: "?");
        return;
    }
    BOOL changed = generation != gRawGeneration || count != gRawCount || stage != gRawStage || active != gRawActive;
    gRawGeneration = generation;
    gRawCount = count;
    gRawStage = stage;
    gRawActive = active;
    if (changed || (reason && strcmp(reason, "ready") == 0)) TOWXApplyRemoteStateFix3(generation, count, stage, active, reason);
}

NSUInteger TOWXV11DataAvatarCount(void) { return gMainCount; }
BOOL TOWXV11DataWeChatActive(void) { return gMainWeChatActive; }
uint64_t TOWXV11DataStage(void) { return gMainStage; }
uint64_t TOWXV11DataGeneration(void) { return gMainGeneration; }
NSInteger TOWXV11DataSelectedIndex(void) { return gMainSelectedIndex; }
NSArray *TOWXV11DataAvatarImages(void) { return gMainImages ?: @[]; }

void TOWXV11DataSendOpen(NSUInteger index) {
    if (index >= gMainCount || index >= TOWXV11_MAX_RECENTS_FIX3) return;
    gMainSelectedIndex = (NSInteger)index;
    [[NSNotificationCenter defaultCenter] postNotificationName:TOWXV11DataDidChangeNotification object:nil];
    char name[96];
    snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
    notify_post(name);
    TOWXV11DiagLog("DATA", "OPEN-SEND|fix=3|index=%lu|notification=%s", (unsigned long)index, name);
}

static void TOWXStartWatchdogFix3(void) {
    if (gWatchdog) return;
    gWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gDataQueue);
    dispatch_source_set_timer(gWatchdog,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC,
                              NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(gWatchdog, ^{ TOWXRefreshRemoteStateFix3("watchdog"); });
    dispatch_resume(gWatchdog);
}

__attribute__((constructor)) static void TOWXV11DataControllerFix3Init(void) {
    gMainImages = @[];
    gDataQueue = dispatch_queue_create("com.dream.towx.v11.avatar-data.fix3", DISPATCH_QUEUE_SERIAL);
    TOWXV11DiagLog("DATA", "LOADED|Smooth1-FIX3|15-recents+background-imageio");

    if (!TOWXRegisterStateFix3(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterStateFix3(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterStateFix3(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterStateFix3(TOWX_LINK_ACK_INDEX, &gAckIndexToken) ||
        !TOWXRegisterStateFix3(TOWX_LINK_APP_ACTIVE, &gAppActiveToken)) {
        TOWXV11DiagLog("DATA", "INIT-ABORT|fix=3|state-registration");
        return;
    }

    uint32_t readyStatus = notify_register_dispatch(TOWX_LINK_READY, &gReadyToken, gDataQueue, ^(__unused int token) {
        TOWXRefreshRemoteStateFix3("ready");
    });
    uint32_t ackStatus = notify_register_dispatch(TOWX_LINK_ACK, &gAckToken, gDataQueue, ^(__unused int token) {
        uint64_t index = UINT64_MAX;
        if (!TOWXReadStateFix3(gAckIndexToken, &index)) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            gMainSelectedIndex = index < TOWXV11_MAX_RECENTS_FIX3 ? (NSInteger)index : NSNotFound;
            TOWXV11DiagLog("DATA", "OPEN-ACK|fix=3|index=%llu", (unsigned long long)index);
            [[NSNotificationCenter defaultCenter] postNotificationName:TOWXV11DataDidChangeNotification object:nil];
        });
    });
    TOWXV11DiagLog("DATA", "LISTENERS|fix=3|ready=%u|ack=%u|max=15", readyStatus, ackStatus);

    dispatch_async(gDataQueue, ^{
        TOWXRefreshRemoteStateFix3("constructor");
        TOWXStartWatchdogFix3();
    });
}
