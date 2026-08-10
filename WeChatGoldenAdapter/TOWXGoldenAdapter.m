#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
#define TOWX_GOLDEN_PATHS_OFFSET ((uintptr_t)0x4080)
#define TOWX_MAX_RECENTS 6U

static dispatch_source_t gTimer;
static uintptr_t gGoldenBase = 0;
static uint64_t gGeneration = 0;
static uint64_t gLastStage = UINT64_MAX;
static uint64_t gLastCount = UINT64_MAX;
static NSUInteger gAvatarHashes[TOWX_MAX_RECENTS];
static unsigned int gTick = 0;

static UIView *gParkingView = nil;
static __weak UIView *gLastGoldenBar = nil;
static UITableView *gSnapshotTable = nil;
static NSIndexPath *gSnapshotPaths[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
static NSUInteger gSnapshotCount = 0;
static uint64_t gSnapshotSerial = 0;

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
    NSString *dir = [TOWXCachesRoot() stringByAppendingPathComponent:@"TOWXLinkP2A4"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:nil];
    return dir;
}

static NSString *TOWXLogPath(void) {
    return [TOWXCachesRoot() stringByAppendingPathComponent:@"TOWX-Link-WeChat-P2A4.log"];
}

static void TOWXLog(const char *format, ...) {
    @autoreleasepool {
        char body[1024];
        va_list args;
        va_start(args, format);
        int bodyLength = vsnprintf(body, sizeof(body), format, args);
        va_end(args);
        if (bodyLength < 0) return;

        char line[1152];
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
        TOWXLog("TOWX|WX|P2A4|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
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
            TOWXLog("TOWX|WX|P2A4|GOLDEN-FOUND|image=%s|base=0x%llx",
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
    if ([view isKindOfClass:[UIButton class]] && view.tag == tag) return (UIButton *)view;
    for (UIView *subview in view.subviews) {
        UIButton *found = TOWXFindButton(subview, tag);
        if (found != nil) return found;
    }
    return nil;
}

static void TOWXParkGoldenInAppBar(UIView *bar) {
    if (bar == nil) return;
    if (gParkingView == nil) {
        gParkingView = [[UIView alloc] initWithFrame:CGRectZero];
        gParkingView.hidden = YES;
        gParkingView.userInteractionEnabled = NO;
    }

    BOOL moved = bar.superview != gParkingView;
    if (moved) {
        UIView *oldParent = bar.superview;
        [bar removeFromSuperview];
        [gParkingView addSubview:bar];
        TOWXLog("TOWX|WX|P2A4|INAPP-BAR-SUPPRESS|mode=park|bar=%p|oldSuper=%p", bar, oldParent);
    }

    bar.userInteractionEnabled = NO;
    bar.layer.opacity = 0.0f;
    gLastGoldenBar = bar;
}

static void TOWXPublish(uint64_t stage, uint64_t count, int force) {
    if (!force && stage == gLastStage && count == gLastCount) return;

    gGeneration += 1;
    if (!TOWXSetToken(gGenerationToken, gGeneration) ||
        !TOWXSetToken(gCountToken, count) ||
        !TOWXSetToken(gStageToken, stage)) {
        TOWXLog("TOWX|WX|P2A4|STATE-WRITE-FAIL|generation=%llu|stage=%llu|count=%llu",
                (unsigned long long)gGeneration,
                (unsigned long long)stage,
                (unsigned long long)count);
        return;
    }

    gLastStage = stage;
    gLastCount = count;
    notify_post(TOWX_LINK_READY);
    TOWXLog("TOWX|WX|P2A4|PUBLISH|generation=%llu|stage=%llu|count=%llu|snapshot=%llu",
            (unsigned long long)gGeneration,
            (unsigned long long)stage,
            (unsigned long long)count,
            (unsigned long long)gSnapshotSerial);
}

static BOOL TOWXIndexPathIsValid(UITableView *table, NSIndexPath *indexPath) {
    if (table == nil || indexPath == nil) return NO;
    NSInteger section = indexPath.section;
    NSInteger row = indexPath.row;
    if (section < 0 || row < 0) return NO;
    NSInteger sections = [table numberOfSections];
    if (section >= sections) return NO;
    NSInteger rows = [table numberOfRowsInSection:section];
    return row < rows;
}

static NSUInteger TOWXCaptureGoldenSnapshot(UITableView *table, uint64_t count64) {
    if (![table isKindOfClass:[UITableView class]] || count64 == 0 || count64 > TOWX_MAX_RECENTS) return 0;

    NSUInteger requested = (NSUInteger)count64;
    NSIndexPath *paths[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
    NSUInteger usable = 0;
    for (NSUInteger index = 0; index < requested; index++) {
        NSIndexPath *path = (NSIndexPath *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_PATHS_OFFSET + index * sizeof(uintptr_t));
        if (![path isKindOfClass:[NSIndexPath class]] || !TOWXIndexPathIsValid(table, path)) {
            TOWXLog("TOWX|WX|P2A4|SNAPSHOT-PATH-MISS|index=%lu|path=%p|table=%p",
                    (unsigned long)index, path, table);
            break;
        }
        paths[index] = path;
        usable += 1;
    }
    if (usable == 0) return 0;

    BOOL changed = (gSnapshotTable != table || gSnapshotCount != usable);
    if (!changed) {
        for (NSUInteger index = 0; index < usable; index++) {
            if (![gSnapshotPaths[index] isEqual:paths[index]]) {
                changed = YES;
                break;
            }
        }
    }

    gSnapshotTable = table;
    gSnapshotCount = usable;
    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        gSnapshotPaths[index] = index < usable ? paths[index] : nil;
    }

    if (changed || gSnapshotSerial == 0) {
        gSnapshotSerial += 1;
        TOWXLog("TOWX|WX|P2A4|SNAPSHOT-CAPTURE|serial=%llu|source=golden-cache|table=%p|count=%lu|first=%ld:%ld",
                (unsigned long long)gSnapshotSerial,
                gSnapshotTable,
                (unsigned long)gSnapshotCount,
                (long)gSnapshotPaths[0].section,
                (long)gSnapshotPaths[0].row);
    }
    return gSnapshotCount;
}

static NSUInteger TOWXExportAvatars(UIView *bar, NSUInteger count, BOOL *changedOut) {
    NSUInteger exported = 0;
    BOOL changed = NO;
    NSString *dir = TOWXExportDir();
    NSUInteger limited = MIN((NSUInteger)TOWX_MAX_RECENTS, count);

    for (NSUInteger index = 0; index < limited; index++) {
        UIButton *button = TOWXFindButton(bar, (NSInteger)(100U + index));
        if (button == nil) {
            TOWXLog("TOWX|WX|P2A4|AVATAR-BUTTON-MISS|index=%lu", (unsigned long)index);
            continue;
        }

        UIImage *image = [button imageForState:UIControlStateNormal];
        if (image == nil) image = button.currentImage;
        if (image == nil) image = button.imageView.image;
        if (image == nil) {
            TOWXLog("TOWX|WX|P2A4|AVATAR-IMAGE-MISS|index=%lu", (unsigned long)index);
            continue;
        }

        NSData *data = UIImagePNGRepresentation(image);
        if (data.length == 0) continue;
        NSUInteger hash = data.hash;
        NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        if (gAvatarHashes[index] != hash || ![[NSFileManager defaultManager] fileExistsAtPath:path]) {
            NSError *error = nil;
            if (![data writeToFile:path options:NSDataWritingAtomic error:&error]) {
                TOWXLog("TOWX|WX|P2A4|AVATAR-WRITE-FAIL|index=%lu|error=%s",
                        (unsigned long)index, error.localizedDescription.UTF8String ?: "unknown");
                continue;
            }
            gAvatarHashes[index] = hash;
            changed = YES;
            TOWXLog("TOWX|WX|P2A4|AVATAR-EXPORT|index=%lu|bytes=%lu|hash=%lu",
                    (unsigned long)index, (unsigned long)data.length, (unsigned long)hash);
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

static UIWindow *TOWXActiveWindow(void) {
    UIApplication *application = UIApplication.sharedApplication;
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        if (windowScene.activationState != UISceneActivationStateForegroundActive) continue;
        for (UIWindow *window in windowScene.windows) if (window.isKeyWindow) return window;
        for (UIWindow *window in windowScene.windows) if (!window.hidden && window.alpha > 0.01) return window;
    }
    for (UIWindow *window in application.windows) if (window.isKeyWindow) return window;
    return application.windows.firstObject;
}

static UINavigationController *TOWXFindNavigationController(UIViewController *controller) {
    if (controller == nil) return nil;
    if ([controller isKindOfClass:[UITabBarController class]]) {
        UINavigationController *found = TOWXFindNavigationController(((UITabBarController *)controller).selectedViewController);
        if (found != nil) return found;
    }
    if ([controller isKindOfClass:[UINavigationController class]]) return (UINavigationController *)controller;
    if (controller.presentedViewController != nil) {
        UINavigationController *found = TOWXFindNavigationController(controller.presentedViewController);
        if (found != nil) return found;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UINavigationController *found = TOWXFindNavigationController(child);
        if (found != nil) return found;
    }
    return controller.navigationController;
}

static void TOWXAck(NSUInteger index) {
    (void)TOWXSetToken(gAckIndexToken, (uint64_t)index);
    notify_post(TOWX_LINK_ACK);
}

static void TOWXOpenViaGoldenFallback(NSUInteger index) {
    id controller = TOWXGoldenObjectAtOffset(TOWX_GOLDEN_CONTROLLER_OFFSET);
    SEL action = NSSelectorFromString(@"towxAvatarTapped:");
    uint64_t count = TOWXGoldenCount();
    if (controller == nil || index >= count || ![controller respondsToSelector:action]) {
        TOWXLog("TOWX|WX|P2A4|FALLBACK-MISS|index=%lu|count=%llu",
                (unsigned long)index, (unsigned long long)count);
        return;
    }
    UIButton *sender = [UIButton buttonWithType:UIButtonTypeCustom];
    sender.tag = (NSInteger)(100U + index);
    ((void (*)(id, SEL, id))objc_msgSend)(controller, action, sender);
    TOWXAck(index);
    TOWXLog("TOWX|WX|P2A4|OPEN-FALLBACK|index=%lu|method=towxAvatarTapped:", (unsigned long)index);
}

static void TOWXOpenSnapshotAtIndex(NSUInteger index) {
    UITableView *table = gSnapshotTable;
    NSIndexPath *path = index < TOWX_MAX_RECENTS ? gSnapshotPaths[index] : nil;
    if (table == nil || path == nil || index >= gSnapshotCount) {
        TOWXOpenViaGoldenFallback(index);
        return;
    }

    UIWindow *window = TOWXActiveWindow();
    UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
    if (navigation != nil && navigation.viewControllers.count > 1) {
        TOWXLog("TOWX|WX|P2A4|NAV-RESET|index=%lu|depth=%lu",
                (unsigned long)index, (unsigned long)navigation.viewControllers.count);
        [navigation popToRootViewControllerAnimated:NO];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (!TOWXIndexPathIsValid(table, path)) {
            TOWXLog("TOWX|WX|P2A4|OPEN-MISS|index=%lu|reason=path-invalid", (unsigned long)index);
            TOWXOpenViaGoldenFallback(index);
            return;
        }
        [table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
        id<UITableViewDelegate> delegate = table.delegate;
        if (delegate != nil && [delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
            [delegate tableView:table didSelectRowAtIndexPath:path];
            TOWXAck(index);
            TOWXLog("TOWX|WX|P2A4|OPEN-SNAPSHOT|index=%lu|serial=%llu|section=%ld|row=%ld|delegate=%s",
                    (unsigned long)index,
                    (unsigned long long)gSnapshotSerial,
                    (long)path.section,
                    (long)path.row,
                    object_getClassName(delegate) ?: "unknown");
        } else {
            TOWXOpenViaGoldenFallback(index);
        }
    });
}

static void TOWXOpenRecent(NSUInteger index) {
    @autoreleasepool {
        if (index >= TOWX_MAX_RECENTS) return;
        if (gGoldenBase == 0) gGoldenBase = TOWXFindGoldenBase();
        if (gSnapshotTable != nil && index < gSnapshotCount && gSnapshotPaths[index] != nil) {
            TOWXOpenSnapshotAtIndex(index);
        } else {
            TOWXOpenViaGoldenFallback(index);
        }
    }
}

static void TOWXHeavyTick(void) {
    UITableView *table = (UITableView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_TABLE_OFFSET);
    UIView *bar = (UIView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_BAR_OFFSET);
    uint64_t count64 = TOWXGoldenCount();
    BOOL heartbeat = (gTick % 80U) == 0U;

    if (count64 > TOWX_MAX_RECENTS) {
        TOWXPublish(490, count64, heartbeat);
        return;
    }
    if (![table isKindOfClass:[UITableView class]] || bar == nil || count64 == 0) {
        TOWXPublish(430, gSnapshotCount, heartbeat);
        return;
    }

    NSUInteger captured = TOWXCaptureGoldenSnapshot(table, count64);
    NSUInteger effectiveCount = captured > 0 ? captured : (NSUInteger)count64;
    BOOL changed = NO;
    NSUInteger exported = TOWXExportAvatars(bar, effectiveCount, &changed);
    TOWXParkGoldenInAppBar(bar);

    if (exported == 0) {
        TOWXPublish(440, effectiveCount, heartbeat);
        return;
    }

    TOWXLog("TOWX|WX|P2A4|SNAPSHOT-READY|source=P2A3-golden-cache|snapshot=%llu|count=%lu|exported=%lu|changed=%s",
            (unsigned long long)gSnapshotSerial,
            (unsigned long)effectiveCount,
            (unsigned long)exported,
            changed ? "yes" : "no");
    TOWXPublish(450, effectiveCount, changed || heartbeat);
}

static void TOWXTick(void) {
    @autoreleasepool {
        gTick += 1;
        if (gGoldenBase == 0) {
            gGoldenBase = TOWXFindGoldenBase();
            if (gGoldenBase == 0) {
                if ((gTick % 20U) == 0U) TOWXPublish(410, 0, YES);
                return;
            }
            TOWXPublish(420, 0, YES);
        }

        UIView *bar = (UIView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_BAR_OFFSET);
        if (bar != nil) TOWXParkGoldenInAppBar(bar);
        else if (gLastGoldenBar != nil) gLastGoldenBar.layer.opacity = 0.0f;

        if ((gTick % 10U) == 0U) TOWXHeavyTick();
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|P2A4|ADAPTER-START|v0.5.0|recovery=P2A3-data+P2A4-switch|golden=0.6.0-clean1|offsets=controller:0x4040,bar:0x4050,table:0x4070,count:0x4078,paths:0x4080");

    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) {
        TOWXLog("TOWX|WX|P2A4|INIT-ABORT|state-registration");
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
            TOWXLog("TOWX|WX|P2A4|OPEN-LISTENER-FAIL|index=%lu|status=%u",
                    (unsigned long)index, status);
        }
    }

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gTimer == nil) return;
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 20U),
                              (uint64_t)(NSEC_PER_SEC / 200U));
    dispatch_source_set_event_handler(gTimer, ^{ TOWXTick(); });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void TOWXGoldenAdapterInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                       dispatch_get_main_queue(), ^{ TOWXStart(); });
    });
}
