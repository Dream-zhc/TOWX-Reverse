#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <notify.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#define TOWX_LINK_READY "com.dream.towx.link.ready"
#define TOWX_LINK_ACK "com.dream.towx.link.openAck"
#define TOWX_LINK_GENERATION "com.dream.towx.link.generation"
#define TOWX_LINK_COUNT "com.dream.towx.link.count"
#define TOWX_LINK_STAGE "com.dream.towx.link.stage"
#define TOWX_LINK_ACK_INDEX "com.dream.towx.link.ackIndex"
#define TOWX_LINK_OPEN_PREFIX "com.dream.towx.link.open."
#define TOWX_MAX_RECENTS 30U
#define TOWX_PREFETCH_PATH_LIMIT 72U

static dispatch_source_t gTimer = nil;
static dispatch_queue_t gExportQueue = nil;
static uint64_t gGeneration = 0;
static uint64_t gLastStage = UINT64_MAX;
static uint64_t gLastCount = UINT64_MAX;
static uint64_t gSnapshotSerial = 0;
static BOOL gOpenBusy = NO;
static NSTimeInterval gLastDiscoveryAt = 0.0;

static __weak UITableView *gSnapshotTable = nil;
static NSIndexPath *gSnapshotPaths[TOWX_MAX_RECENTS];
static NSString *gSnapshotTitles[TOWX_MAX_RECENTS];
static NSUInteger gSnapshotImageKeys[TOWX_MAX_RECENTS];
static UIImage *gSnapshotImages[TOWX_MAX_RECENTS];
static NSUInteger gSnapshotCount = 0;

static NSArray<NSIndexPath *> *gBuildPaths = nil;
static NSUInteger gBuildCursor = 0;
static BOOL gBuildFinished = NO;
static BOOL gBuildScheduled = NO;
static NSUInteger gOffscreenBuildCount = 0;

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
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static NSString *TOWXLogPath(void) {
    return [TOWXCachesRoot() stringByAppendingPathComponent:@"TOWX-Link-WeChat-P2A4.log"];
}

static void TOWXLog(const char *format, ...) {
    @autoreleasepool {
        char body[1800];
        va_list args;
        va_start(args, format);
        int bodyLength = vsnprintf(body, sizeof(body), format, args);
        va_end(args);
        if (bodyLength < 0) return;

        struct timeval tv;
        gettimeofday(&tv, NULL);
        time_t seconds = (time_t)tv.tv_sec;
        struct tm localTm;
        memset(&localTm, 0, sizeof(localTm));
        localtime_r(&seconds, &localTm);
        char timestamp[64];
        if (strftime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S", &localTm) == 0) {
            snprintf(timestamp, sizeof(timestamp), "%lld", (long long)tv.tv_sec);
        }

        char line[2200];
        int lineLength = snprintf(line, sizeof(line), "%s.%03ld %s\n",
                                  timestamp,
                                  (long)(tv.tv_usec / 1000),
                                  body);
        if (lineLength <= 0) return;
        int fd = open(TOWXLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        if (fd < 0) return;
        size_t toWrite = MIN((size_t)lineLength, sizeof(line));
        (void)write(fd, line, toWrite);
        close(fd);
    }
}

static int TOWXRegisterState(const char *name, int *token) {
    uint32_t status = notify_register_check(name, token);
    if (status != NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|WX|THIRTY|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
        return 0;
    }
    return 1;
}

static BOOL TOWXSetToken(int token, uint64_t value) {
    return notify_set_state(token, value) == NOTIFY_STATUS_OK;
}

static void TOWXPublish(uint64_t stage, uint64_t count, BOOL force) {
    if (!force && stage == gLastStage && count == gLastCount) return;
    gGeneration += 1;
    if (!TOWXSetToken(gGenerationToken, gGeneration) ||
        !TOWXSetToken(gCountToken, count) ||
        !TOWXSetToken(gStageToken, stage)) {
        TOWXLog("TOWX|WX|THIRTY|STATE-WRITE-FAIL|generation=%llu|stage=%llu|count=%llu",
                (unsigned long long)gGeneration,
                (unsigned long long)stage,
                (unsigned long long)count);
        return;
    }
    gLastStage = stage;
    gLastCount = count;
    notify_post(TOWX_LINK_READY);
    TOWXLog("TOWX|WX|THIRTY|PUBLISH|generation=%llu|stage=%llu|count=%llu|snapshot=%llu",
            (unsigned long long)gGeneration,
            (unsigned long long)stage,
            (unsigned long long)count,
            (unsigned long long)gSnapshotSerial);
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
    for (UIWindow *window in application.windows) if (!window.hidden && window.alpha > 0.01) return window;
    return application.windows.firstObject;
}

static UINavigationController *TOWXFindNavigationController(UIViewController *controller) {
    if (!controller) return nil;
    if ([controller isKindOfClass:[UITabBarController class]]) {
        UINavigationController *found = TOWXFindNavigationController(((UITabBarController *)controller).selectedViewController);
        if (found) return found;
    }
    if ([controller isKindOfClass:[UINavigationController class]]) return (UINavigationController *)controller;
    if (controller.presentedViewController) {
        UINavigationController *found = TOWXFindNavigationController(controller.presentedViewController);
        if (found) return found;
    }
    for (UIViewController *child in controller.childViewControllers) {
        UINavigationController *found = TOWXFindNavigationController(child);
        if (found) return found;
    }
    return controller.navigationController;
}

static BOOL TOWXIndexPathValid(UITableView *table, NSIndexPath *path) {
    if (![table isKindOfClass:[UITableView class]] || !path || path.section < 0 || path.row < 0) return NO;
    NSInteger sections = [table numberOfSections];
    if (path.section >= sections) return NO;
    return path.row < [table numberOfRowsInSection:path.section];
}

static void TOWXCollectImageViews(UIView *view, NSMutableArray<UIImageView *> *result) {
    if ([view isKindOfClass:[UIImageView class]]) [result addObject:(UIImageView *)view];
    for (UIView *subview in view.subviews) TOWXCollectImageViews(subview, result);
}

static UIImage *TOWXAvatarImageFromCell(UITableViewCell *cell) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return nil;
    NSMutableArray<UIImageView *> *images = [NSMutableArray array];
    TOWXCollectImageViews(cell.contentView, images);
    UIImageView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    CGFloat centerY = CGRectGetMidY(cell.contentView.bounds);
    for (UIImageView *imageView in images) {
        if (!imageView.image || imageView.hidden || imageView.alpha <= 0.01) continue;
        CGRect frame = [imageView convertRect:imageView.bounds toView:cell.contentView];
        CGFloat width = CGRectGetWidth(frame), height = CGRectGetHeight(frame);
        CGFloat delta = fabs(width - height);
        if (width < 28.0 || width > 86.0 || height < 28.0 || height > 86.0 || delta > 14.0) continue;
        if (CGRectGetMinX(frame) < -4.0 || CGRectGetMinX(frame) > 122.0) continue;
        CGFloat yDelta = fabs(CGRectGetMidY(frame) - centerY);
        CGFloat score = width * height - CGRectGetMinX(frame) * 9.0 - yDelta * 12.0;
        if (score > bestScore) { bestScore = score; best = imageView; }
    }
    return best.image;
}

static void TOWXCollectLabels(UIView *view, NSMutableArray<UILabel *> *result) {
    if ([view isKindOfClass:[UILabel class]]) [result addObject:(UILabel *)view];
    for (UIView *subview in view.subviews) TOWXCollectLabels(subview, result);
}

static NSString *TOWXTitleFromCell(UITableViewCell *cell) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return @"";
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    TOWXCollectLabels(cell.contentView, labels);
    UILabel *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UILabel *label in labels) {
        NSString *text = [label.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length == 0 || text.length > 100 || label.hidden || label.alpha <= 0.01 || label.font.pointSize < 13.0) continue;
        if ([text containsString:@"微信已登录"] || [text containsString:@"Windows 已登录"] || [text containsString:@"Mac 已登录"]) continue;
        CGRect frame = [label convertRect:label.bounds toView:cell.contentView];
        if (CGRectGetMinX(frame) < 46.0 || CGRectGetMinY(frame) < -3.0) continue;
        CGFloat score = label.font.pointSize * 100.0 - CGRectGetMinY(frame) * 3.0 - CGRectGetMinX(frame) * 0.15;
        if (score > bestScore) { bestScore = score; best = label; }
    }
    return [best.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static NSUInteger TOWXCheapImageKey(UIImage *image) {
    if (!image) return 0;
    uintptr_t raw = image.CGImage ? (uintptr_t)image.CGImage : (uintptr_t)(__bridge void *)image;
    return (NSUInteger)(raw ^ ((uintptr_t)image.size.width << 7) ^ ((uintptr_t)image.size.height << 15));
}

static BOOL TOWXIdentityFromCell(UITableViewCell *cell,
                                 NSString **titleOut,
                                 NSUInteger *imageKeyOut,
                                 UIImage **imageOut) {
    NSString *title = TOWXTitleFromCell(cell);
    UIImage *image = TOWXAvatarImageFromCell(cell);
    if (title.length == 0 || !image) return NO;
    NSUInteger key = TOWXCheapImageKey(image);
    if (key == 0) return NO;
    if (titleOut) *titleOut = title;
    if (imageKeyOut) *imageKeyOut = key;
    if (imageOut) *imageOut = image;
    return YES;
}

static void TOWXCollectTablesDeep(UIView *view, NSMutableArray<UITableView *> *tables) {
    if (!view) return;
    if ([view isKindOfClass:[UITableView class]]) [tables addObject:(UITableView *)view];
    for (UIView *subview in view.subviews) TOWXCollectTablesDeep(subview, tables);
}

static NSInteger TOWXTableScore(UITableView *table) {
    if (![table isKindOfClass:[UITableView class]] || table.hidden || table.alpha <= 0.01 || !table.window) return NSIntegerMin;
    NSUInteger identities = 0;
    for (UITableViewCell *cell in table.visibleCells) {
        if (identities >= 8) break;
        if (TOWXIdentityFromCell(cell, NULL, NULL, NULL)) identities += 1;
    }
    if (identities == 0) return NSIntegerMin;
    NSInteger rows = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        rows += [table numberOfRowsInSection:section];
        if (rows > 240) { rows = 240; break; }
    }
    NSInteger score = (NSInteger)identities * 10000 + rows * 10;
    if (CGRectGetWidth(table.bounds) >= 250.0) score += 300;
    if (CGRectGetHeight(table.bounds) >= 240.0) score += 200;
    return score;
}

static UITableView *TOWXDiscoverConversationTable(BOOL force) {
    if (gSnapshotTable && gSnapshotTable.dataSource && gSnapshotTable.delegate && gSnapshotTable.window) return gSnapshotTable;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (!force && now - gLastDiscoveryAt < 6.0) return nil;
    gLastDiscoveryAt = now;

    UIWindow *window = TOWXActiveWindow();
    UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
    if (!navigation || navigation.viewControllers.count == 0) return nil;
    UIViewController *root = navigation.viewControllers.firstObject;
    if (navigation.topViewController != root) return nil;
    UIView *rootView = root.viewIfLoaded;
    if (!rootView) return nil;

    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    TOWXCollectTablesDeep(rootView, tables);
    UITableView *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (UITableView *candidate in tables) {
        NSInteger score = TOWXTableScore(candidate);
        if (score > bestScore) { bestScore = score; best = candidate; }
    }
    if (best) {
        gSnapshotTable = best;
        TOWXLog("TOWX|WX|THIRTY|TABLE-DISCOVERY|table=%p|class=%s|score=%ld|visible=%lu",
                best,
                object_getClassName(best) ?: "?",
                (long)bestScore,
                (unsigned long)best.visibleCells.count);
    }
    return best;
}

static BOOL TOWXDuplicateIdentity(NSString *title, NSUInteger imageKey, NSUInteger count) {
    for (NSUInteger i = 0; i < count; i++) {
        if ([gSnapshotTitles[i] isEqualToString:title] && gSnapshotImageKeys[i] == imageKey) return YES;
    }
    return NO;
}

static NSArray<NSIndexPath *> *TOWXCandidatePaths(UITableView *table) {
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray arrayWithCapacity:TOWX_PREFETCH_PATH_LIMIT];
    NSInteger sections = table.numberOfSections;
    for (NSInteger section = 0; section < sections && paths.count < TOWX_PREFETCH_PATH_LIMIT; section++) {
        NSInteger rows = [table numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows && paths.count < TOWX_PREFETCH_PATH_LIMIT; row++) {
            [paths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
        }
    }
    return paths;
}

static void TOWXClearSnapshot(void) {
    for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
        gSnapshotPaths[i] = nil;
        gSnapshotTitles[i] = nil;
        gSnapshotImageKeys[i] = 0;
        gSnapshotImages[i] = nil;
    }
    gSnapshotCount = 0;
    gBuildCursor = 0;
    gBuildFinished = NO;
    gOffscreenBuildCount = 0;
}

static void TOWXScheduleAvatarExport(NSUInteger count, uint64_t serial) {
    if (!gExportQueue) return;
    NSMutableArray *snapshot = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger i = 0; i < count; i++) [snapshot addObject:gSnapshotImages[i] ?: NSNull.null];
    dispatch_async(gExportQueue, ^{
        NSString *dir = TOWXExportDir();
        BOOL ok = YES;
        for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
            NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)i]];
            if (i >= count) {
                [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
                continue;
            }
            id value = i < snapshot.count ? snapshot[i] : nil;
            UIImage *image = [value isKindOfClass:[UIImage class]] ? value : nil;
            NSData *data = image ? UIImagePNGRepresentation(image) : nil;
            if (data.length == 0 || ![data writeToFile:file atomically:YES]) ok = NO;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (serial != gSnapshotSerial) return;
            TOWXLog("TOWX|WX|THIRTY|EXPORT-END|serial=%llu|count=%lu|ok=%d|queue=background|offscreenBuilt=%lu",
                    (unsigned long long)serial,
                    (unsigned long)count,
                    ok ? 1 : 0,
                    (unsigned long)gOffscreenBuildCount);
            TOWXPublish(ok ? 660 : 655, count, YES);
        });
    });
}

static void TOWXPublishSnapshot(BOOL force) {
    if (gSnapshotCount == 0) return;
    gSnapshotSerial += 1;
    TOWXLog("TOWX|WX|THIRTY|SNAPSHOT|serial=%llu|count=%lu|max=30|strategy=idle-incremental|batch=1|scroll-pause=1|png-main-thread=0",
            (unsigned long long)gSnapshotSerial,
            (unsigned long)gSnapshotCount);
    TOWXScheduleAvatarExport(gSnapshotCount, gSnapshotSerial);
    if (force) TOWXPublish(658, gSnapshotCount, YES);
}

static UITableViewCell *TOWXCellForBuildPath(UITableView *table, NSIndexPath *path, BOOL *offscreenOut) {
    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    if (cell) {
        if (offscreenOut) *offscreenOut = NO;
        return cell;
    }
    id<UITableViewDataSource> dataSource = table.dataSource;
    if (!dataSource || ![dataSource respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) return nil;
    @try {
        cell = [dataSource tableView:table cellForRowAtIndexPath:path];
        if (cell && offscreenOut) *offscreenOut = YES;
        return cell;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static BOOL TOWXStorePath(UITableView *table, NSIndexPath *path) {
    BOOL offscreen = NO;
    UITableViewCell *cell = TOWXCellForBuildPath(table, path, &offscreen);
    if (!cell) return NO;
    NSString *title = nil;
    NSUInteger imageKey = 0;
    UIImage *image = nil;
    if (!TOWXIdentityFromCell(cell, &title, &imageKey, &image)) return NO;
    if (TOWXDuplicateIdentity(title, imageKey, gSnapshotCount)) return NO;
    if (gSnapshotCount >= TOWX_MAX_RECENTS) return NO;

    NSUInteger index = gSnapshotCount++;
    gSnapshotPaths[index] = path;
    gSnapshotTitles[index] = [title copy];
    gSnapshotImageKeys[index] = imageKey;
    gSnapshotImages[index] = image;
    if (offscreen) gOffscreenBuildCount += 1;
    TOWXLog("TOWX|WX|THIRTY|CAPTURE|index=%lu|path=%ld:%ld|offscreen=%d|title=%s",
            (unsigned long)index,
            (long)path.section,
            (long)path.row,
            offscreen ? 1 : 0,
            title.UTF8String ?: "?");
    return YES;
}

static BOOL TOWXAtConversationRoot(UITableView **tableOut) {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return NO;
    UIWindow *window = TOWXActiveWindow();
    UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
    if (!navigation || navigation.viewControllers.count == 0) return NO;
    UIViewController *root = navigation.viewControllers.firstObject;
    if (navigation.topViewController != root) return NO;
    UITableView *table = gSnapshotTable;
    if (!table || !table.window || table.dataSource == nil || table.delegate == nil) {
        gSnapshotTable = nil;
        table = TOWXDiscoverConversationTable(NO);
    }
    if (!table) return NO;
    if (tableOut) *tableOut = table;
    return YES;
}

static void TOWXBuildStep(void);

static void TOWXScheduleBuildAfter(NSTimeInterval delay) {
    if (gBuildScheduled || gBuildFinished) return;
    gBuildScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        gBuildScheduled = NO;
        TOWXBuildStep();
    });
}

static void TOWXBuildStep(void) {
    if (gBuildFinished || gSnapshotCount >= TOWX_MAX_RECENTS) {
        gBuildFinished = YES;
        return;
    }

    UITableView *table = nil;
    if (!TOWXAtConversationRoot(&table)) {
        TOWXScheduleBuildAfter(0.45);
        return;
    }
    if (table.tracking || table.dragging || table.decelerating) {
        TOWXLog("TOWX|WX|THIRTY|PREFETCH-PAUSE|reason=scrolling|cursor=%lu|count=%lu",
                (unsigned long)gBuildCursor,
                (unsigned long)gSnapshotCount);
        TOWXScheduleBuildAfter(0.35);
        return;
    }

    if (!gBuildPaths || gBuildPaths.count == 0) gBuildPaths = TOWXCandidatePaths(table);
    if (gBuildCursor >= gBuildPaths.count) {
        gBuildFinished = YES;
        TOWXPublishSnapshot(YES);
        TOWXLog("TOWX|WX|THIRTY|PREFETCH-END|reason=paths-exhausted|count=%lu|offscreenBuilt=%lu",
                (unsigned long)gSnapshotCount,
                (unsigned long)gOffscreenBuildCount);
        return;
    }

    NSIndexPath *path = gBuildPaths[gBuildCursor++];
    BOOL added = TOWXStorePath(table, path);
    if (added && (gSnapshotCount == 1 || gSnapshotCount % 5 == 0 || gSnapshotCount == TOWX_MAX_RECENTS)) {
        TOWXPublishSnapshot(NO);
    }

    if (gSnapshotCount >= TOWX_MAX_RECENTS) {
        gBuildFinished = YES;
        TOWXPublishSnapshot(YES);
        TOWXLog("TOWX|WX|THIRTY|PREFETCH-END|reason=max30|count=30|offscreenBuilt=%lu",
                (unsigned long)gOffscreenBuildCount);
        return;
    }
    TOWXScheduleBuildAfter(0.11);
}

static void TOWXStartBuildForTable(UITableView *table, const char *reason) {
    if (!table) return;
    gSnapshotTable = table;
    TOWXClearSnapshot();
    gBuildPaths = TOWXCandidatePaths(table);
    TOWXLog("TOWX|WX|THIRTY|PREFETCH-BEGIN|reason=%s|candidatePaths=%lu|max=30|batch=1|intervalMs=110",
            reason ?: "?",
            (unsigned long)gBuildPaths.count);
    TOWXScheduleBuildAfter(0.06);
}

static NSIndexPath *TOWXResolvedPathForIndex(UITableView *table, NSUInteger index) {
    if (index >= gSnapshotCount || ![table isKindOfClass:[UITableView class]]) return nil;
    NSString *target = gSnapshotTitles[index];
    NSIndexPath *stored = gSnapshotPaths[index];
    if (TOWXIndexPathValid(table, stored)) {
        UITableViewCell *existing = [table cellForRowAtIndexPath:stored];
        if (!existing) return stored;
        NSString *current = TOWXTitleFromCell(existing);
        if ([current isEqualToString:target]) return stored;
    }

    for (NSIndexPath *path in table.indexPathsForVisibleRows ?: @[]) {
        UITableViewCell *cell = [table cellForRowAtIndexPath:path];
        if (!cell) continue;
        if ([[TOWXTitleFromCell(cell) ?: @""] isEqualToString:target]) return path;
    }
    return stored && TOWXIndexPathValid(table, stored) ? stored : nil;
}

static BOOL TOWXSelectPath(UITableView *table, NSIndexPath *path) {
    if (!TOWXIndexPathValid(table, path)) return NO;
    id<UITableViewDelegate> delegate = table.delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    [table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
    [delegate tableView:table didSelectRowAtIndexPath:path];
    return YES;
}

static void TOWXAck(NSUInteger index) {
    (void)TOWXSetToken(gAckIndexToken, (uint64_t)index);
    notify_post(TOWX_LINK_ACK);
}

static UIView *TOWXInstallDirectSwitchMask(UIWindow *window) {
    if (!window) return nil;
    UIView *mask = [window snapshotViewAfterScreenUpdates:NO];
    if (!mask) return nil;
    mask.frame = window.bounds;
    mask.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mask.userInteractionEnabled = NO;
    mask.accessibilityElementsHidden = YES;
    mask.layer.zPosition = 100000.0;
    [window addSubview:mask];
    return mask;
}

static void TOWXRemoveDirectSwitchMask(UIView *mask, BOOL animated) {
    if (!mask) return;
    if (!animated) { [mask removeFromSuperview]; return; }
    [UIView animateWithDuration:0.08
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ mask.alpha = 0.0; }
                     completion:^(__unused BOOL finished) { [mask removeFromSuperview]; }];
}

static void TOWXVerifySwitch(NSUInteger index,
                             UINavigationController *navigation,
                             UIViewController *root,
                             UIViewController *oldTop,
                             NSArray<UIViewController *> *originalStack,
                             UIView *mask,
                             NSUInteger attempt,
                             BOOL fallbackPhase);

static void TOWXFallbackSwitch(NSUInteger index,
                               UINavigationController *navigation,
                               UIViewController *root,
                               UIViewController *oldTop,
                               NSArray<UIViewController *> *originalStack,
                               UIView *mask) {
    UITableView *table = gSnapshotTable;
    NSIndexPath *path = TOWXResolvedPathForIndex(table, index);
    if (!path) {
        if (originalStack.count) [navigation setViewControllers:originalStack animated:NO];
        TOWXRemoveDirectSwitchMask(mask, NO);
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|THIRTY|DIRECT-SWITCH-FAIL|index=%lu|reason=fallback-path-miss", (unsigned long)index);
        return;
    }
    [UIView performWithoutAnimation:^{ [navigation setViewControllers:@[root] animated:NO]; }];
    __block BOOL selected = NO;
    [UIView performWithoutAnimation:^{ selected = TOWXSelectPath(table, path); }];
    if (!selected) {
        if (originalStack.count) [navigation setViewControllers:originalStack animated:NO];
        TOWXRemoveDirectSwitchMask(mask, NO);
        gOpenBusy = NO;
        return;
    }
    TOWXVerifySwitch(index, navigation, root, oldTop, originalStack, mask, 0, YES);
}

static void TOWXVerifySwitch(NSUInteger index,
                             UINavigationController *navigation,
                             UIViewController *root,
                             UIViewController *oldTop,
                             NSArray<UIViewController *> *originalStack,
                             UIView *mask,
                             NSUInteger attempt,
                             BOOL fallbackPhase) {
    UIViewController *newTop = navigation.topViewController;
    if (newTop && newTop != root && newTop != oldTop) {
        [UIView performWithoutAnimation:^{ [navigation setViewControllers:@[root, newTop] animated:NO]; }];
        TOWXAck(index);
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|THIRTY|DIRECT-SWITCH-SUCCESS|index=%lu|attempt=%lu|fallback=%d|newTop=%s",
                (unsigned long)index,
                (unsigned long)attempt,
                fallbackPhase ? 1 : 0,
                object_getClassName(newTop) ?: "?");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(55 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            TOWXRemoveDirectSwitchMask(mask, YES);
        });
        return;
    }
    if (attempt < 7) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            TOWXVerifySwitch(index, navigation, root, oldTop, originalStack, mask, attempt + 1, fallbackPhase);
        });
        return;
    }
    if (!fallbackPhase) {
        TOWXFallbackSwitch(index, navigation, root, oldTop, originalStack, mask);
        return;
    }
    if (originalStack.count) [navigation setViewControllers:originalStack animated:NO];
    TOWXRemoveDirectSwitchMask(mask, NO);
    gOpenBusy = NO;
}

static void TOWXOpenRecent(NSUInteger index) {
    @autoreleasepool {
        if (index >= gSnapshotCount || index >= TOWX_MAX_RECENTS || gOpenBusy) return;
        UITableView *table = gSnapshotTable;
        NSIndexPath *path = TOWXResolvedPathForIndex(table, index);
        if (!path) {
            TOWXLog("TOWX|WX|THIRTY|OPEN-REJECT|index=%lu|reason=path-unavailable|target=%s",
                    (unsigned long)index,
                    gSnapshotTitles[index].UTF8String ?: "?");
            return;
        }

        UIWindow *window = TOWXActiveWindow();
        UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
        if (!navigation || navigation.viewControllers.count == 0) return;
        UIViewController *root = navigation.viewControllers.firstObject;
        UIViewController *oldTop = navigation.topViewController;
        NSArray<UIViewController *> *originalStack = [navigation.viewControllers copy];
        gOpenBusy = YES;

        if (oldTop == root) {
            if (TOWXSelectPath(table, path)) {
                TOWXAck(index);
                TOWXLog("TOWX|WX|THIRTY|OPEN-ROOT|index=%lu|target=%s", (unsigned long)index, gSnapshotTitles[index].UTF8String ?: "?");
            }
            gOpenBusy = NO;
            return;
        }

        UIView *mask = TOWXInstallDirectSwitchMask(window);
        __block BOOL selected = NO;
        [UIView performWithoutAnimation:^{ selected = TOWXSelectPath(table, path); }];
        if (!selected) {
            TOWXRemoveDirectSwitchMask(mask, NO);
            gOpenBusy = NO;
            return;
        }
        TOWXLog("TOWX|WX|THIRTY|DIRECT-SWITCH-BEGIN|index=%lu|target=%s|oldTop=%s|depth=%lu",
                (unsigned long)index,
                gSnapshotTitles[index].UTF8String ?: "?",
                object_getClassName(oldTop) ?: "?",
                (unsigned long)navigation.viewControllers.count);
        TOWXVerifySwitch(index, navigation, root, oldTop, originalStack, mask, 0, NO);
    }
}

static void TOWXMaintenanceTick(const char *reason) {
    @autoreleasepool {
        UITableView *table = nil;
        if (!TOWXAtConversationRoot(&table)) return;
        if (table.tracking || table.dragging || table.decelerating) return;
        if (gSnapshotTable != table || !gBuildPaths) {
            TOWXStartBuildForTable(table, reason ?: "maintenance");
            return;
        }
        if (!gBuildFinished) TOWXScheduleBuildAfter(0.05);
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|THIRTY|ADAPTER-START|v0.11.0|recent=30|idle-incremental=1|batch=1|intervalMs=110|scroll-pause=1|global-uiview-hooks=0|png-background=1");
    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) return;

    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        char name[96];
        (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
        uint32_t status = notify_register_dispatch(name, &gOpenTokens[index], dispatch_get_main_queue(), ^(__unused int token) {
            TOWXOpenRecent(index);
        });
        if (status != NOTIFY_STATUS_OK) {
            TOWXLog("TOWX|WX|THIRTY|OPEN-LISTENER-FAIL|index=%lu|status=%u", (unsigned long)index, status);
        }
    }

    gExportQueue = dispatch_queue_create("com.dream.towx.wechat.thirty-export", DISPATCH_QUEUE_SERIAL);
    TOWXPublish(610, 0, YES);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(500 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            UITableView *table = TOWXDiscoverConversationTable(YES);
            if (table) TOWXStartBuildForTable(table, "app-active");
        });
    }];

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTimer) return;
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(900 * NSEC_PER_MSEC)),
                              (uint64_t)(2200 * NSEC_PER_MSEC),
                              (uint64_t)(350 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gTimer, ^{ TOWXMaintenanceTick("timer"); });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void TOWXGoldenAdapterV13ThirtyInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXStart(); });
}
