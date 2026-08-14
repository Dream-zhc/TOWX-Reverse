#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
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
#define TOWX_GOLDEN_BAR_OFFSET ((uintptr_t)0x4050)
#define TOWX_GOLDEN_TABLE_OFFSET ((uintptr_t)0x4070)
#define TOWX_MAX_RECENTS 15U
#define TOWX_SCAN_PATH_LIMIT 48U

static dispatch_source_t gTimer;
static uintptr_t gGoldenBase = 0;
static uint64_t gGeneration = 0;
static uint64_t gLastStage = UINT64_MAX;
static uint64_t gLastCount = UINT64_MAX;
static unsigned int gTick = 0;

static UIView *gParkingView = nil;
static __weak UIView *gLastGoldenBar = nil;
static UITableView *gSnapshotTable = nil;
static NSIndexPath *gSnapshotPaths[TOWX_MAX_RECENTS];
static NSString *gSnapshotTitles[TOWX_MAX_RECENTS];
static NSUInteger gSnapshotHashes[TOWX_MAX_RECENTS];
static NSUInteger gExportHashes[TOWX_MAX_RECENTS];
static NSUInteger gSnapshotCount = 0;
static uint64_t gSnapshotSerial = 0;
static BOOL gOpenBusy = NO;
static NSMutableDictionary<NSString *, UITableViewCell *> *gPrefetchedCells = nil;
static __weak UITableView *gPrefetchTable = nil;

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
        char body[1600];
        va_list args;
        va_start(args, format);
        int bodyLength = vsnprintf(body, sizeof(body), format, args);
        va_end(args);
        if (bodyLength < 0) return;
        char line[1800];
        int lineLength = snprintf(line, sizeof(line), "%lld %s\n", (long long)time(NULL), body);
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
        TOWXLog("TOWX|WX|P2A4|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
        return 0;
    }
    return 1;
}

static int TOWXSetToken(int token, uint64_t value) {
    return notify_set_state(token, value) == NOTIFY_STATUS_OK;
}

static uintptr_t TOWXFindGoldenBase(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == NULL || strstr(name, TOWX_GOLDEN_IMAGE) == NULL) continue;
        const struct mach_header *header = _dyld_get_image_header(index);
        if (header != NULL) {
            TOWXLog("TOWX|WX|P2A4|GOLDEN-FOUND|image=%s|base=0x%llx", name, (unsigned long long)(uintptr_t)header);
            return (uintptr_t)header;
        }
    }
    return 0;
}

static id TOWXGoldenObjectAtOffset(uintptr_t offset) {
    if (gGoldenBase == 0) return nil;
    uintptr_t raw = *(volatile uintptr_t *)(gGoldenBase + offset);
    return raw == 0 ? nil : (__bridge id)(void *)raw;
}

static void TOWXSuppressGoldenBar(UIView *bar) {
    if (!bar) return;
    if (!gParkingView) {
        gParkingView = [[UIView alloc] initWithFrame:CGRectZero];
        gParkingView.hidden = YES;
        gParkingView.userInteractionEnabled = NO;
        gParkingView.layer.opacity = 0.0f;
    }
    bar.hidden = YES;
    bar.alpha = 0.0;
    bar.userInteractionEnabled = NO;
    bar.layer.opacity = 0.0f;
    if (bar.superview != gParkingView) {
        [bar removeFromSuperview];
        [gParkingView addSubview:bar];
        TOWXLog("TOWX|WX|P2A4|INAPP-BAR-SUPPRESS|v10|bar=%p", bar);
    }
    gLastGoldenBar = bar;
}

static void TOWXPublish(uint64_t stage, uint64_t count, BOOL force) {
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
    TOWXLog("TOWX|WX|P2A4|PUBLISH|v10|generation=%llu|stage=%llu|count=%llu|snapshot=%llu",
            (unsigned long long)gGeneration,
            (unsigned long long)stage,
            (unsigned long long)count,
            (unsigned long long)gSnapshotSerial);
}

static BOOL TOWXIndexPathValid(UITableView *table, NSIndexPath *path) {
    if (!table || !path || path.section < 0 || path.row < 0) return NO;
    if (path.section >= [table numberOfSections]) return NO;
    return path.row < [table numberOfRowsInSection:path.section];
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

static BOOL TOWXTableFrontmost(UITableView *table) {
    if (![table isKindOfClass:[UITableView class]] || !table.window || table.hidden || table.alpha <= 0.01) return NO;
    for (UIView *cursor = table.superview; cursor; cursor = cursor.superview) {
        if (cursor.hidden || cursor.alpha <= 0.01) return NO;
    }
    UIWindow *window = table.window;
    CGPoint center = CGPointMake(CGRectGetMidX(table.bounds), CGRectGetMidY(table.bounds));
    CGPoint p = [table convertPoint:center toView:window];
    if (!CGRectContainsPoint(window.bounds, p)) return NO;
    UIView *hit = [window hitTest:p withEvent:nil];
    return hit && (hit == table || [hit isDescendantOfView:table]);
}

static BOOL TOWXConversationRootActive(UITableView *table, NSUInteger *depthOut) {
    if (!TOWXTableFrontmost(table)) return NO;
    UIWindow *window = table.window ?: TOWXActiveWindow();
    UINavigationController *nav = TOWXFindNavigationController(window.rootViewController);
    if (!nav || nav.viewControllers.count == 0) return NO;
    if (depthOut) *depthOut = nav.viewControllers.count;
    UIViewController *root = nav.viewControllers.firstObject;
    return nav.topViewController == root && root.view && [table isDescendantOfView:root.view];
}

static void TOWXCollectImageViews(UIView *view, NSMutableArray<UIImageView *> *result) {
    if ([view isKindOfClass:[UIImageView class]]) [result addObject:(UIImageView *)view];
    for (UIView *subview in view.subviews) TOWXCollectImageViews(subview, result);
}

static UIImage *TOWXAvatarImageFromCell(UITableViewCell *cell) {
    NSMutableArray<UIImageView *> *images = [NSMutableArray array];
    TOWXCollectImageViews(cell.contentView, images);
    UIImageView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    CGFloat centerY = CGRectGetMidY(cell.contentView.bounds);
    for (UIImageView *imageView in images) {
        if (!imageView.image || imageView.hidden || imageView.alpha <= 0.01) continue;
        CGRect frame = [imageView convertRect:imageView.bounds toView:cell.contentView];
        CGFloat w = CGRectGetWidth(frame), h = CGRectGetHeight(frame);
        if (w < 28.0 || w > 82.0 || h < 28.0 || h > 82.0 || fabs(w-h) > 14.0) continue;
        if (CGRectGetMinX(frame) < -4.0 || CGRectGetMinX(frame) > 118.0) continue;
        CGFloat score = w*h - CGRectGetMinX(frame)*9.0 - fabs(CGRectGetMidY(frame)-centerY)*12.0;
        if (score > bestScore) { bestScore = score; best = imageView; }
    }
    return best.image;
}

static void TOWXCollectLabels(UIView *view, NSMutableArray<UILabel *> *result) {
    if ([view isKindOfClass:[UILabel class]]) [result addObject:(UILabel *)view];
    for (UIView *subview in view.subviews) TOWXCollectLabels(subview, result);
}

static NSString *TOWXTitleFromCell(UITableViewCell *cell) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    TOWXCollectLabels(cell.contentView, labels);
    UILabel *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UILabel *label in labels) {
        NSString *text = [label.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length == 0 || text.length > 100 || label.hidden || label.alpha <= 0.01 || label.font.pointSize < 13.0) continue;
        CGRect frame = [label convertRect:label.bounds toView:cell.contentView];
        if (CGRectGetMinX(frame) < 46.0 || CGRectGetMinY(frame) < -3.0) continue;
        CGFloat score = label.font.pointSize*100.0 - CGRectGetMinY(frame)*3.0 - CGRectGetMinX(frame)*0.15;
        if (score > bestScore) { bestScore = score; best = label; }
    }
    return [best.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static BOOL TOWXIdentityFromCell(UITableViewCell *cell, NSString **titleOut, NSUInteger *hashOut, UIImage **imageOut) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return NO;
    NSString *title = TOWXTitleFromCell(cell);
    UIImage *image = TOWXAvatarImageFromCell(cell);
    if (title.length == 0 || !image) return NO;
    NSData *data = UIImagePNGRepresentation(image);
    if (data.length == 0) return NO;
    if (titleOut) *titleOut = title;
    if (hashOut) *hashOut = data.hash;
    if (imageOut) *imageOut = image;
    return YES;
}

static NSString *TOWXPathKey(NSIndexPath *path) {
    return [NSString stringWithFormat:@"%ld:%ld", (long)path.section, (long)path.row];
}

static UITableViewCell *TOWXCellForPath(UITableView *table, NSIndexPath *path) {
    if (!TOWXIndexPathValid(table, path)) return nil;
    UITableViewCell *cell = [table cellForRowAtIndexPath:path];
    if (cell) return cell;

    if (gPrefetchTable != table) {
        gPrefetchTable = table;
        gPrefetchedCells = [NSMutableDictionary dictionary];
    }
    NSString *key = TOWXPathKey(path);
    cell = gPrefetchedCells[key];
    if (cell) return cell;

    id<UITableViewDataSource> dataSource = table.dataSource;
    if (!dataSource || ![dataSource respondsToSelector:@selector(tableView:cellForRowAtIndexPath:)]) return nil;
    @try {
        cell = [dataSource tableView:table cellForRowAtIndexPath:path];
        if (cell) {
            if (gPrefetchedCells.count > 64) [gPrefetchedCells removeAllObjects];
            gPrefetchedCells[key] = cell;
        }
    } @catch (NSException *exception) {
        TOWXLog("TOWX|WX|P2A4|PREFETCH-EXCEPTION|path=%s|reason=%s", key.UTF8String ?: "?", exception.reason.UTF8String ?: "?");
        cell = nil;
    }
    return cell;
}

static NSArray<NSIndexPath *> *TOWXConversationPaths(UITableView *table) {
    NSMutableArray<NSIndexPath *> *paths = [NSMutableArray array];
    NSInteger sections = [table numberOfSections];
    for (NSInteger section = 0; section < sections && paths.count < TOWX_SCAN_PATH_LIMIT; section++) {
        NSInteger rows = [table numberOfRowsInSection:section];
        for (NSInteger row = 0; row < rows && paths.count < TOWX_SCAN_PATH_LIMIT; row++) {
            [paths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
        }
    }
    return paths;
}

static BOOL TOWXIdentityAlreadyAdded(NSString *title, NSUInteger hash, NSUInteger count, NSString * __strong *titles, const NSUInteger *hashes) {
    for (NSUInteger i = 0; i < count; i++) {
        if (hashes[i] == hash && [titles[i] isEqualToString:title]) return YES;
    }
    return NO;
}

static NSUInteger TOWXCaptureSnapshot(UITableView *table, BOOL *changedOut) {
    if (![table isKindOfClass:[UITableView class]]) return 0;
    NSIndexPath *paths[TOWX_MAX_RECENTS] = { nil };
    NSString *titles[TOWX_MAX_RECENTS] = { nil };
    NSUInteger hashes[TOWX_MAX_RECENTS] = { 0 };
    UIImage *images[TOWX_MAX_RECENTS] = { nil };
    NSUInteger usable = 0;

    for (NSIndexPath *path in TOWXConversationPaths(table)) {
        if (usable >= TOWX_MAX_RECENTS) break;
        UITableViewCell *cell = TOWXCellForPath(table, path);
        NSString *title = nil;
        NSUInteger hash = 0;
        UIImage *image = nil;
        if (!TOWXIdentityFromCell(cell, &title, &hash, &image)) continue;
        if (TOWXIdentityAlreadyAdded(title, hash, usable, titles, hashes)) continue;
        paths[usable] = path;
        titles[usable] = [title copy];
        hashes[usable] = hash;
        images[usable] = image;
        usable += 1;
    }

    if (usable == 0) return 0;
    if (gSnapshotCount > usable && usable < TOWX_MAX_RECENTS) {
        TOWXLog("TOWX|WX|P2A4|SNAPSHOT-HOLD|v10|reason=partial-prefetch|new=%lu|old=%lu",
                (unsigned long)usable, (unsigned long)gSnapshotCount);
        return gSnapshotCount;
    }

    BOOL changed = gSnapshotTable != table || gSnapshotCount != usable;
    if (!changed) {
        for (NSUInteger i = 0; i < usable; i++) {
            if (![gSnapshotPaths[i] isEqual:paths[i]] || ![gSnapshotTitles[i] isEqualToString:titles[i]] || gSnapshotHashes[i] != hashes[i]) {
                changed = YES;
                break;
            }
        }
    }

    gSnapshotTable = table;
    gSnapshotCount = usable;
    NSString *dir = TOWXExportDir();
    for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
        NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)i]];
        if (i < usable) {
            gSnapshotPaths[i] = paths[i];
            gSnapshotTitles[i] = [titles[i] copy];
            gSnapshotHashes[i] = hashes[i];
            NSData *data = UIImagePNGRepresentation(images[i]);
            if (data.length > 0 && (gExportHashes[i] != hashes[i] || ![[NSFileManager defaultManager] fileExistsAtPath:file])) {
                NSError *error = nil;
                if ([data writeToFile:file options:NSDataWritingAtomic error:&error]) {
                    gExportHashes[i] = hashes[i];
                    changed = YES;
                } else {
                    TOWXLog("TOWX|WX|P2A4|AVATAR-WRITE-FAIL|v10|index=%lu|error=%s", (unsigned long)i, error.localizedDescription.UTF8String ?: "?");
                }
            }
        } else {
            gSnapshotPaths[i] = nil;
            gSnapshotTitles[i] = nil;
            gSnapshotHashes[i] = 0;
            gExportHashes[i] = 0;
            [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        }
    }

    if (changed || gSnapshotSerial == 0) {
        gSnapshotSerial += 1;
        TOWXLog("TOWX|WX|P2A4|SNAPSHOT-CAPTURE|v10|serial=%llu|source=table-first15|count=%lu",
                (unsigned long long)gSnapshotSerial, (unsigned long)gSnapshotCount);
        for (NSUInteger i = 0; i < gSnapshotCount; i++) {
            TOWXLog("TOWX|WX|P2A4|IDENTITY-SLOT|v10|index=%lu|section=%ld|row=%ld|title=%s|hash=%lu",
                    (unsigned long)i,
                    (long)gSnapshotPaths[i].section,
                    (long)gSnapshotPaths[i].row,
                    gSnapshotTitles[i].UTF8String ?: "?",
                    (unsigned long)gSnapshotHashes[i]);
        }
    }
    if (changedOut) *changedOut = changed;
    return gSnapshotCount;
}

static NSIndexPath *TOWXFindPathForIdentity(UITableView *table, NSString *title, NSUInteger hash) {
    for (NSIndexPath *path in TOWXConversationPaths(table)) {
        NSString *candidateTitle = nil;
        NSUInteger candidateHash = 0;
        if (!TOWXIdentityFromCell(TOWXCellForPath(table, path), &candidateTitle, &candidateHash, NULL)) continue;
        if (candidateHash == hash && [candidateTitle isEqualToString:title]) return path;
    }
    return nil;
}

static void TOWXAck(NSUInteger index) {
    (void)TOWXSetToken(gAckIndexToken, (uint64_t)index);
    notify_post(TOWX_LINK_ACK);
}

static BOOL TOWXSelectPath(UITableView *table, NSIndexPath *path) {
    if (!TOWXIndexPathValid(table, path)) return NO;
    id<UITableViewDelegate> delegate = table.delegate;
    if (!delegate || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) return NO;
    [table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
    [delegate tableView:table didSelectRowAtIndexPath:path];
    return YES;
}

static void TOWXOpenFromRoot(NSUInteger index, NSString *title, NSUInteger hash) {
    UITableView *table = gSnapshotTable;
    NSIndexPath *path = TOWXFindPathForIdentity(table, title, hash);
    if (!path || !TOWXSelectPath(table, path)) {
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|P2A4|OPEN-MISS|v10|index=%lu|mode=root|target=%s", (unsigned long)index, title.UTF8String ?: "?");
        return;
    }
    TOWXAck(index);
    gOpenBusy = NO;
    TOWXLog("TOWX|WX|P2A4|OPEN-SNAPSHOT|v10|index=%lu|mode=root|section=%ld|row=%ld|target=%s",
            (unsigned long)index, (long)path.section, (long)path.row, title.UTF8String ?: "?");
}

static void TOWXFallbackViaRoot(NSUInteger index, NSString *title, NSUInteger hash, UINavigationController *nav) {
    TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-FALLBACK|index=%lu|target=%s|reason=no-new-top",
            (unsigned long)index, title.UTF8String ?: "?");
    [nav popToRootViewControllerAnimated:NO];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        TOWXOpenFromRoot(index, title, hash);
    });
}

static void TOWXVerifyDirectPush(NSUInteger index,
                                 NSString *title,
                                 NSUInteger hash,
                                 UINavigationController *nav,
                                 UIViewController *root,
                                 UIViewController *oldTop,
                                 NSUInteger attempt) {
    UIViewController *newTop = nav.topViewController;
    if (newTop && newTop != oldTop && newTop != root) {
        [nav setViewControllers:@[root, newTop] animated:NO];
        TOWXAck(index);
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-SUCCESS|index=%lu|target=%s|attempt=%lu|newTop=%s",
                (unsigned long)index, title.UTF8String ?: "?", (unsigned long)attempt, object_getClassName(newTop) ?: "?");
        return;
    }
    if (attempt < 5) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(22 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            TOWXVerifyDirectPush(index, title, hash, nav, root, oldTop, attempt + 1);
        });
        return;
    }
    TOWXFallbackViaRoot(index, title, hash, nav);
}

static void TOWXOpenRecent(NSUInteger index) {
    @autoreleasepool {
        if (index >= gSnapshotCount || index >= TOWX_MAX_RECENTS || gOpenBusy) return;
        UITableView *table = gSnapshotTable;
        NSString *title = [gSnapshotTitles[index] copy];
        NSUInteger hash = gSnapshotHashes[index];
        if (![table isKindOfClass:[UITableView class]] || title.length == 0 || hash == 0) return;

        NSIndexPath *path = TOWXFindPathForIdentity(table, title, hash);
        if (!path) {
            TOWXLog("TOWX|WX|P2A4|OPEN-REJECT|v10|index=%lu|reason=identity-not-found|target=%s",
                    (unsigned long)index, title.UTF8String ?: "?");
            return;
        }

        UIWindow *window = TOWXActiveWindow();
        UINavigationController *nav = TOWXFindNavigationController(window.rootViewController);
        if (!nav || nav.viewControllers.count == 0) return;
        UIViewController *root = nav.viewControllers.firstObject;
        UIViewController *oldTop = nav.topViewController;
        gOpenBusy = YES;

        if (oldTop == root) {
            TOWXOpenFromRoot(index, title, hash);
            return;
        }

        /* Direct-switch path: ask the conversation-list delegate to build the target chat while keeping the current chat on-screen. */
        BOOL animationsEnabled = [UIView areAnimationsEnabled];
        [UIView setAnimationsEnabled:NO];
        BOOL selected = TOWXSelectPath(table, path);
        [UIView setAnimationsEnabled:animationsEnabled];
        if (!selected) {
            TOWXFallbackViaRoot(index, title, hash, nav);
            return;
        }

        TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-BEGIN|index=%lu|target=%s|oldTop=%s|depth=%lu",
                (unsigned long)index, title.UTF8String ?: "?", object_getClassName(oldTop) ?: "?", (unsigned long)nav.viewControllers.count);
        TOWXVerifyDirectPush(index, title, hash, nav, root, oldTop, 0);
    }
}

static void TOWXHeavyTick(void) {
    UITableView *table = (UITableView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_TABLE_OFFSET);
    BOOL heartbeat = (gTick % 300U) == 0U;
    if (![table isKindOfClass:[UITableView class]]) {
        TOWXPublish(gSnapshotCount > 0 ? 570 : 530, gSnapshotCount, heartbeat);
        return;
    }

    NSUInteger depth = 0;
    if (!TOWXConversationRootActive(table, &depth)) {
        TOWXPublish(gSnapshotCount > 0 ? 570 : 530, gSnapshotCount, heartbeat);
        return;
    }

    BOOL changed = NO;
    NSUInteger captured = TOWXCaptureSnapshot(table, &changed);
    if (captured == 0) {
        TOWXPublish(gSnapshotCount > 0 ? 570 : 530, gSnapshotCount, heartbeat);
        return;
    }
    TOWXPublish(550, captured, changed || heartbeat);
}

static void TOWXTick(void) {
    @autoreleasepool {
        gTick += 1;
        if (gGoldenBase == 0) {
            gGoldenBase = TOWXFindGoldenBase();
            if (gGoldenBase == 0) {
                if ((gTick % 50U) == 0U) TOWXPublish(510, 0, YES);
                return;
            }
            TOWXPublish(520, 0, YES);
        }
        UIView *bar = (UIView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_BAR_OFFSET);
        if (bar) TOWXSuppressGoldenBar(bar);
        else if (gLastGoldenBar) {
            gLastGoldenBar.hidden = YES;
            gLastGoldenBar.alpha = 0.0;
            gLastGoldenBar.layer.opacity = 0.0f;
        }
        if ((gTick % 5U) == 0U) TOWXHeavyTick();
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|P2A4|ADAPTER-START|v0.10.0|mode=table-first15+prefetch+direct-switch|max=15");
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
            TOWXLog("TOWX|WX|P2A4|OPEN-LISTENER-FAIL|v10|index=%lu|status=%u", (unsigned long)index, status);
        }
    }

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTimer) return;
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 10U),
                              (uint64_t)(NSEC_PER_SEC / 100U));
    dispatch_source_set_event_handler(gTimer, ^{ TOWXTick(); });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void TOWXGoldenAdapterV10Init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXStart(); });
}
