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
#define TOWX_MAX_RECENTS 15U

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
static NSUInteger gSnapshotCount = 0;

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
        TOWXLog("TOWX|WX|PASSIVE|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
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
        TOWXLog("TOWX|WX|PASSIVE|STATE-WRITE-FAIL|generation=%llu|stage=%llu|count=%llu",
                (unsigned long long)gGeneration,
                (unsigned long long)stage,
                (unsigned long long)count);
        return;
    }
    gLastStage = stage;
    gLastCount = count;
    notify_post(TOWX_LINK_READY);
    TOWXLog("TOWX|WX|PASSIVE|PUBLISH|generation=%llu|stage=%llu|count=%llu|snapshot=%llu",
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
        CGFloat delta = width > height ? width - height : height - width;
        if (width < 28.0 || width > 82.0 || height < 28.0 || height > 82.0 || delta > 14.0) continue;
        if (CGRectGetMinX(frame) < -4.0 || CGRectGetMinX(frame) > 118.0) continue;
        CGFloat yDelta = CGRectGetMidY(frame) > centerY ? CGRectGetMidY(frame) - centerY : centerY - CGRectGetMidY(frame);
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

static BOOL TOWXIdentityFromVisibleCell(UITableViewCell *cell,
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

static NSInteger TOWXPassiveTableScore(UITableView *table) {
    if (![table isKindOfClass:[UITableView class]] || table.hidden || table.alpha <= 0.01 || !table.window) return NSIntegerMin;
    NSUInteger identities = 0;
    for (UITableViewCell *cell in table.visibleCells) {
        if (identities >= 8) break;
        if (TOWXIdentityFromVisibleCell(cell, NULL, NULL, NULL)) identities += 1;
    }
    if (identities == 0) return NSIntegerMin;
    NSInteger rows = 0;
    for (NSInteger section = 0; section < table.numberOfSections; section++) {
        rows += [table numberOfRowsInSection:section];
        if (rows > 200) { rows = 200; break; }
    }
    NSInteger score = (NSInteger)identities * 10000 + rows * 10;
    if (CGRectGetWidth(table.bounds) >= 250.0) score += 300;
    if (CGRectGetHeight(table.bounds) >= 240.0) score += 200;
    return score;
}

static UITableView *TOWXDiscoverConversationTable(BOOL force) {
    if (gSnapshotTable && gSnapshotTable.dataSource && gSnapshotTable.delegate) return gSnapshotTable;
    NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
    if (!force && now - gLastDiscoveryAt < 5.0) return nil;
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
        NSInteger score = TOWXPassiveTableScore(candidate);
        if (score > bestScore) { bestScore = score; best = candidate; }
    }
    if (best) {
        gSnapshotTable = best;
        TOWXLog("TOWX|WX|PASSIVE|TABLE-DISCOVERY|table=%p|class=%s|score=%ld|visible=%lu",
                best,
                object_getClassName(best) ?: "?",
                (long)bestScore,
                (unsigned long)best.visibleCells.count);
    }
    return best;
}

static BOOL TOWXDuplicateIdentity(NSString *title,
                                  NSUInteger imageKey,
                                  NSUInteger count,
                                  NSString * __strong *titles,
                                  const NSUInteger *imageKeys) {
    for (NSUInteger i = 0; i < count; i++) {
        if (imageKeys[i] == imageKey && [titles[i] isEqualToString:title]) return YES;
    }
    return NO;
}

static NSArray<NSIndexPath *> *TOWXSortedVisiblePaths(UITableView *table) {
    NSArray<NSIndexPath *> *paths = table.indexPathsForVisibleRows ?: @[];
    return [paths sortedArrayUsingComparator:^NSComparisonResult(NSIndexPath *a, NSIndexPath *b) {
        if (a.section < b.section) return NSOrderedAscending;
        if (a.section > b.section) return NSOrderedDescending;
        if (a.row < b.row) return NSOrderedAscending;
        if (a.row > b.row) return NSOrderedDescending;
        return NSOrderedSame;
    }];
}

static void TOWXScheduleAvatarExport(NSArray<UIImage *> *images, NSUInteger count, uint64_t serial) {
    if (!gExportQueue) return;
    NSArray<UIImage *> *snapshotImages = [images copy];
    dispatch_async(gExportQueue, ^{
        NSString *dir = TOWXExportDir();
        BOOL ok = YES;
        for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
            NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)i]];
            if (i >= count) {
                [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
                continue;
            }
            UIImage *image = i < snapshotImages.count ? snapshotImages[i] : nil;
            NSData *data = image ? UIImagePNGRepresentation(image) : nil;
            if (data.length == 0 || ![data writeToFile:file atomically:YES]) ok = NO;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (serial != gSnapshotSerial) return;
            TOWXLog("TOWX|WX|PASSIVE|EXPORT-END|serial=%llu|count=%lu|ok=%d|queue=background",
                    (unsigned long long)serial,
                    (unsigned long)count,
                    ok ? 1 : 0);
            TOWXPublish(ok ? 650 : 645, count, YES);
        });
    });
}

static BOOL TOWXCaptureVisible(UITableView *table) {
    if (![table isKindOfClass:[UITableView class]] || !table.window) return NO;
    if (table.tracking || table.dragging || table.decelerating) {
        TOWXLog("TOWX|WX|PASSIVE|CAPTURE-SKIP|reason=scrolling");
        return NO;
    }

    NSIndexPath *paths[TOWX_MAX_RECENTS] = { nil };
    NSString *titles[TOWX_MAX_RECENTS] = { nil };
    NSUInteger imageKeys[TOWX_MAX_RECENTS] = { 0 };
    UIImage *images[TOWX_MAX_RECENTS] = { nil };
    NSUInteger usable = 0;

    for (NSIndexPath *path in TOWXSortedVisiblePaths(table)) {
        if (usable >= TOWX_MAX_RECENTS) break;
        UITableViewCell *cell = [table cellForRowAtIndexPath:path];
        if (!cell) continue; /* Passive rule: never ask the data source to build an off-screen cell. */
        NSString *title = nil;
        NSUInteger imageKey = 0;
        UIImage *image = nil;
        if (!TOWXIdentityFromVisibleCell(cell, &title, &imageKey, &image)) continue;
        if (TOWXDuplicateIdentity(title, imageKey, usable, titles, imageKeys)) continue;
        paths[usable] = path;
        titles[usable] = [title copy];
        imageKeys[usable] = imageKey;
        images[usable] = image;
        usable += 1;
    }
    if (usable == 0) return NO;

    BOOL changed = gSnapshotTable != table || gSnapshotCount != usable;
    if (!changed) {
        for (NSUInteger i = 0; i < usable; i++) {
            if (![gSnapshotPaths[i] isEqual:paths[i]] ||
                ![gSnapshotTitles[i] isEqualToString:titles[i]] ||
                gSnapshotImageKeys[i] != imageKeys[i]) {
                changed = YES;
                break;
            }
        }
    }
    if (!changed) return NO;

    gSnapshotTable = table;
    gSnapshotCount = usable;
    NSMutableArray<UIImage *> *exportImages = [NSMutableArray arrayWithCapacity:usable];
    for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
        if (i < usable) {
            gSnapshotPaths[i] = paths[i];
            gSnapshotTitles[i] = [titles[i] copy];
            gSnapshotImageKeys[i] = imageKeys[i];
            [exportImages addObject:images[i]];
        } else {
            gSnapshotPaths[i] = nil;
            gSnapshotTitles[i] = nil;
            gSnapshotImageKeys[i] = 0;
        }
    }
    gSnapshotSerial += 1;
    TOWXLog("TOWX|WX|PASSIVE|SNAPSHOT|serial=%llu|count=%lu|source=visible-cells-only|offscreen-build=0|png-main-thread=0",
            (unsigned long long)gSnapshotSerial,
            (unsigned long)usable);
    TOWXScheduleAvatarExport(exportImages, usable, gSnapshotSerial);
    return YES;
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

    for (NSIndexPath *path in TOWXSortedVisiblePaths(table)) {
        UITableViewCell *cell = [table cellForRowAtIndexPath:path];
        if (!cell) continue;
        NSString *visibleTitle = TOWXTitleFromCell(cell);
        if ([visibleTitle isEqualToString:target]) return path;
    }
    return nil;
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

static void TOWXVerifyMaskedSwitch(NSUInteger index,
                                   UINavigationController *navigation,
                                   UIViewController *root,
                                   UIViewController *oldTop,
                                   NSArray<UIViewController *> *originalStack,
                                   UIView *mask,
                                   NSUInteger attempt,
                                   BOOL fallbackPhase);

static void TOWXMaskedFallback(NSUInteger index,
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
        TOWXLog("TOWX|WX|PASSIVE|DIRECT-SWITCH-FAIL|index=%lu|reason=fallback-path-miss", (unsigned long)index);
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
    TOWXVerifyMaskedSwitch(index, navigation, root, oldTop, originalStack, mask, 0, YES);
}

static void TOWXVerifyMaskedSwitch(NSUInteger index,
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
        TOWXLog("TOWX|WX|PASSIVE|DIRECT-SWITCH-SUCCESS|index=%lu|attempt=%lu|fallback=%d|newTop=%s",
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
            TOWXVerifyMaskedSwitch(index, navigation, root, oldTop, originalStack, mask, attempt + 1, fallbackPhase);
        });
        return;
    }
    if (!fallbackPhase) {
        TOWXMaskedFallback(index, navigation, root, oldTop, originalStack, mask);
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
            TOWXLog("TOWX|WX|PASSIVE|OPEN-REJECT|index=%lu|reason=path-unavailable|target=%s",
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
                TOWXLog("TOWX|WX|PASSIVE|OPEN-ROOT|index=%lu|target=%s", (unsigned long)index, gSnapshotTitles[index].UTF8String ?: "?");
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
        TOWXLog("TOWX|WX|PASSIVE|DIRECT-SWITCH-BEGIN|index=%lu|target=%s|oldTop=%s|depth=%lu",
                (unsigned long)index,
                gSnapshotTitles[index].UTF8String ?: "?",
                object_getClassName(oldTop) ?: "?",
                (unsigned long)navigation.viewControllers.count);
        TOWXVerifyMaskedSwitch(index, navigation, root, oldTop, originalStack, mask, 0, NO);
    }
}

static void TOWXPassiveTick(const char *reason) {
    @autoreleasepool {
        if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
        UIWindow *window = TOWXActiveWindow();
        UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
        if (!navigation || navigation.viewControllers.count == 0) return;
        UIViewController *root = navigation.viewControllers.firstObject;
        if (navigation.topViewController != root) return; /* Never inspect the hidden list while inside a chat. */

        UITableView *table = gSnapshotTable;
        if (!table || !table.window || table.dataSource == nil || table.delegate == nil) {
            gSnapshotTable = nil;
            table = TOWXDiscoverConversationTable(NO);
        }
        if (!table) return;
        if (table.tracking || table.dragging || table.decelerating) return;
        BOOL changed = TOWXCaptureVisible(table);
        if (changed) {
            TOWXLog("TOWX|WX|PASSIVE|TICK|reason=%s|changed=1|count=%lu", reason ?: "?", (unsigned long)gSnapshotCount);
        }
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|PASSIVE|ADAPTER-START|v0.10.3-fix8|visible-cells-only|offscreen-build=0|global-uiview-hooks=0|timer=1.5s|scroll-skip=1|png-background=1");
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
            TOWXLog("TOWX|WX|PASSIVE|OPEN-LISTENER-FAIL|index=%lu|status=%u", (unsigned long)index, status);
        }
    }

    gExportQueue = dispatch_queue_create("com.dream.towx.wechat.passive-export", DISPATCH_QUEUE_SERIAL);
    TOWXPublish(610, 0, YES);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(450 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            TOWXPassiveTick("app-active");
        });
    }];

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTimer) return;
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(700 * NSEC_PER_MSEC)),
                              (uint64_t)(1500 * NSEC_PER_MSEC),
                              (uint64_t)(300 * NSEC_PER_MSEC));
    dispatch_source_set_event_handler(gTimer, ^{ TOWXPassiveTick("timer"); });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void TOWXGoldenAdapterV12PassiveInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXStart(); });
}
