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
#define TOWX_GOLDEN_COUNT_OFFSET ((uintptr_t)0x4078)
#define TOWX_GOLDEN_PATHS_OFFSET ((uintptr_t)0x4080)
#define TOWX_MAX_RECENTS 6U

static dispatch_source_t gTimer;
static uintptr_t gGoldenBase = 0;
static uint64_t gGeneration = 0;
static uint64_t gLastStage = UINT64_MAX;
static uint64_t gLastCount = UINT64_MAX;
static unsigned int gTick = 0;

static UIView *gParkingView = nil;
static __weak UIView *gLastGoldenBar = nil;

static UITableView *gSnapshotTable = nil;
static NSIndexPath *gSnapshotPaths[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
static NSString *gSnapshotTitles[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
static NSUInteger gSnapshotHashes[TOWX_MAX_RECENTS] = { 0, 0, 0, 0, 0, 0 };
static NSUInteger gExportHashes[TOWX_MAX_RECENTS] = { 0, 0, 0, 0, 0, 0 };
static NSUInteger gSnapshotCount = 0;
static uint64_t gSnapshotSerial = 0;
static BOOL gOpenBusy = NO;
static NSUInteger gLastLoggedNavDepth = NSNotFound;

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
        char body[1200];
        va_list args;
        va_start(args, format);
        int bodyLength = vsnprintf(body, sizeof(body), format, args);
        va_end(args);
        if (bodyLength < 0) return;
        char line[1400];
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

static uint64_t TOWXGoldenCount(void) {
    if (gGoldenBase == 0) return 0;
    return (uint64_t)(*(volatile uint32_t *)(gGoldenBase + TOWX_GOLDEN_COUNT_OFFSET));
}

static void TOWXSuppressGoldenInAppBar(UIView *bar) {
    if (bar == nil) return;
    if (gParkingView == nil) {
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
        UIView *oldParent = bar.superview;
        [bar removeFromSuperview];
        [gParkingView addSubview:bar];
        TOWXLog("TOWX|WX|P2A4|INAPP-BAR-SUPPRESS|mode=park|bar=%p|oldSuper=%p", bar, oldParent);
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
    TOWXLog("TOWX|WX|P2A4|PUBLISH|generation=%llu|stage=%llu|count=%llu|snapshot=%llu",
            (unsigned long long)gGeneration,
            (unsigned long long)stage,
            (unsigned long long)count,
            (unsigned long long)gSnapshotSerial);
}

static BOOL TOWXIndexPathIsValid(UITableView *table, NSIndexPath *path) {
    if (table == nil || path == nil || path.section < 0 || path.row < 0) return NO;
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

static BOOL TOWXTableIsFrontmost(UITableView *table) {
    if (![table isKindOfClass:[UITableView class]] || table.window == nil || table.hidden || table.alpha <= 0.01) return NO;
    for (UIView *cursor = table.superview; cursor != nil; cursor = cursor.superview) {
        if (cursor.hidden || cursor.alpha <= 0.01) return NO;
    }
    UIWindow *window = table.window;
    CGPoint center = CGPointMake(CGRectGetMidX(table.bounds), CGRectGetMidY(table.bounds));
    CGPoint point = [table convertPoint:center toView:window];
    if (!CGRectContainsPoint(window.bounds, point)) return NO;
    UIView *hit = [window hitTest:point withEvent:nil];
    return hit != nil && (hit == table || [hit isDescendantOfView:table]);
}

static BOOL TOWXConversationRootIsActive(UITableView *table, NSUInteger *depthOut) {
    if (!TOWXTableIsFrontmost(table)) return NO;
    UIWindow *window = table.window ?: TOWXActiveWindow();
    UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
    if (navigation == nil || navigation.viewControllers.count == 0) return NO;
    NSUInteger depth = navigation.viewControllers.count;
    if (depthOut != NULL) *depthOut = depth;
    UIViewController *root = navigation.viewControllers.firstObject;
    BOOL topIsRoot = navigation.topViewController == root;
    BOOL tableInRoot = root.view != nil && [table isDescendantOfView:root.view];
    return topIsRoot && tableInRoot;
}

static void TOWXCollectImageViews(UIView *view, NSMutableArray<UIImageView *> *result) {
    if ([view isKindOfClass:[UIImageView class]]) [result addObject:(UIImageView *)view];
    for (UIView *subview in view.subviews) TOWXCollectImageViews(subview, result);
}

static UIImage *TOWXAvatarImageFromCell(UITableViewCell *cell, CGRect *frameOut) {
    NSMutableArray<UIImageView *> *candidates = [NSMutableArray array];
    TOWXCollectImageViews(cell.contentView, candidates);
    UIImageView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    CGFloat targetY = CGRectGetMidY(cell.contentView.bounds);
    for (UIImageView *imageView in candidates) {
        if (imageView.image == nil || imageView.hidden || imageView.alpha <= 0.01) continue;
        CGRect frame = [imageView convertRect:imageView.bounds toView:cell.contentView];
        CGFloat width = CGRectGetWidth(frame), height = CGRectGetHeight(frame);
        if (width < 30.0 || width > 76.0 || height < 30.0 || height > 76.0) continue;
        if (fabs(width - height) > 12.0 || CGRectGetMinX(frame) < -4.0 || CGRectGetMinX(frame) > 110.0) continue;
        if (!CGRectIntersectsRect(cell.contentView.bounds, frame)) continue;
        CGFloat score = width * height - CGRectGetMinX(frame) * 10.0 - fabs(CGRectGetMidY(frame) - targetY) * 14.0;
        if (score > bestScore) { bestScore = score; best = imageView; }
    }
    if (best == nil) return nil;
    if (frameOut != NULL) *frameOut = [best convertRect:best.bounds toView:cell.contentView];
    return best.image;
}

static void TOWXCollectLabels(UIView *view, NSMutableArray<UILabel *> *result) {
    if ([view isKindOfClass:[UILabel class]]) [result addObject:(UILabel *)view];
    for (UIView *subview in view.subviews) TOWXCollectLabels(subview, result);
}

static NSString *TOWXBestTitleFromCell(UITableViewCell *cell) {
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    TOWXCollectLabels(cell.contentView, labels);
    UILabel *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UILabel *label in labels) {
        NSString *text = [label.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length == 0 || text.length > 80 || label.hidden || label.alpha <= 0.01 || label.font.pointSize < 13.0) continue;
        CGRect frame = [label convertRect:label.bounds toView:cell.contentView];
        if (CGRectGetMinX(frame) < 50.0 || CGRectGetMinY(frame) < -2.0) continue;
        CGFloat score = label.font.pointSize * 100.0 - CGRectGetMinY(frame) * 3.0 - CGRectGetMinX(frame) * 0.2;
        if (score > bestScore) { bestScore = score; best = label; }
    }
    return [best.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static BOOL TOWXIdentityFromCell(UITableViewCell *cell,
                                 NSString **titleOut,
                                 NSUInteger *hashOut,
                                 UIImage **imageOut,
                                 CGRect *avatarFrameOut) {
    if (![cell isKindOfClass:[UITableViewCell class]]) return NO;
    NSString *title = TOWXBestTitleFromCell(cell);
    CGRect frame = CGRectZero;
    UIImage *image = TOWXAvatarImageFromCell(cell, &frame);
    if (title.length == 0 || image == nil) return NO;
    NSData *data = UIImagePNGRepresentation(image);
    if (data.length == 0) return NO;
    if (titleOut != NULL) *titleOut = title;
    if (hashOut != NULL) *hashOut = data.hash;
    if (imageOut != NULL) *imageOut = image;
    if (avatarFrameOut != NULL) *avatarFrameOut = frame;
    return YES;
}

static NSUInteger TOWXCaptureConversationSnapshot(UITableView *table, uint64_t count64, BOOL *changedOut) {
    if (![table isKindOfClass:[UITableView class]] || count64 == 0 || count64 > TOWX_MAX_RECENTS) return 0;

    NSIndexPath *paths[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
    NSString *titles[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
    NSUInteger hashes[TOWX_MAX_RECENTS] = { 0, 0, 0, 0, 0, 0 };
    UIImage *images[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
    CGRect frames[TOWX_MAX_RECENTS];
    NSUInteger usable = 0;

    for (NSUInteger sourceIndex = 0; sourceIndex < (NSUInteger)count64 && usable < TOWX_MAX_RECENTS; sourceIndex++) {
        NSIndexPath *path = (NSIndexPath *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_PATHS_OFFSET + sourceIndex * sizeof(uintptr_t));
        if (![path isKindOfClass:[NSIndexPath class]] || !TOWXIndexPathIsValid(table, path)) {
            TOWXLog("TOWX|WX|P2A4|SNAPSHOT-PATH-MISS|sourceIndex=%lu|path=%p|table=%p",
                    (unsigned long)sourceIndex, path, table);
            continue;
        }
        UITableViewCell *cell = [table cellForRowAtIndexPath:path];
        NSString *title = nil;
        NSUInteger hash = 0;
        UIImage *image = nil;
        CGRect avatarFrame = CGRectZero;
        if (!TOWXIdentityFromCell(cell, &title, &hash, &image, &avatarFrame)) {
            TOWXLog("TOWX|WX|P2A4|IDENTITY-MISS|sourceIndex=%lu|section=%ld|row=%ld|cell=%s",
                    (unsigned long)sourceIndex, (long)path.section, (long)path.row,
                    cell != nil ? (object_getClassName(cell) ?: "unknown") : "nil");
            continue;
        }
        paths[usable] = path;
        titles[usable] = [title copy];
        hashes[usable] = hash;
        images[usable] = image;
        frames[usable] = avatarFrame;
        usable += 1;
    }
    if (usable == 0) return 0;

    BOOL changed = (gSnapshotTable != table || gSnapshotCount != usable);
    if (!changed) {
        for (NSUInteger index = 0; index < usable; index++) {
            if (![gSnapshotPaths[index] isEqual:paths[index]] ||
                ![gSnapshotTitles[index] isEqualToString:titles[index]] ||
                gSnapshotHashes[index] != hashes[index]) {
                changed = YES;
                break;
            }
        }
    }

    gSnapshotTable = table;
    gSnapshotCount = usable;
    NSString *dir = TOWXExportDir();
    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        if (index < usable) {
            gSnapshotPaths[index] = paths[index];
            gSnapshotTitles[index] = [titles[index] copy];
            gSnapshotHashes[index] = hashes[index];
            NSData *data = UIImagePNGRepresentation(images[index]);
            NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
            if (data.length > 0 && (gExportHashes[index] != hashes[index] || ![[NSFileManager defaultManager] fileExistsAtPath:filePath])) {
                NSError *error = nil;
                if ([data writeToFile:filePath options:NSDataWritingAtomic error:&error]) {
                    gExportHashes[index] = hashes[index];
                    changed = YES;
                } else {
                    TOWXLog("TOWX|WX|P2A4|AVATAR-WRITE-FAIL|index=%lu|error=%s",
                            (unsigned long)index, error.localizedDescription.UTF8String ?: "unknown");
                }
            }
        } else {
            gSnapshotPaths[index] = nil;
            gSnapshotTitles[index] = nil;
            gSnapshotHashes[index] = 0;
            gExportHashes[index] = 0;
            NSString *filePath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
            [[NSFileManager defaultManager] removeItemAtPath:filePath error:nil];
        }
    }

    if (changed || gSnapshotSerial == 0) {
        gSnapshotSerial += 1;
        TOWXLog("TOWX|WX|P2A4|SNAPSHOT-CAPTURE|serial=%llu|source=conversation-root+golden-paths|table=%p|count=%lu",
                (unsigned long long)gSnapshotSerial, gSnapshotTable, (unsigned long)gSnapshotCount);
        for (NSUInteger index = 0; index < gSnapshotCount; index++) {
            TOWXLog("TOWX|WX|P2A4|IDENTITY-SLOT|index=%lu|section=%ld|row=%ld|title=%s|hash=%lu|avatarFrame={{%.1f,%.1f},{%.1f,%.1f}}",
                    (unsigned long)index,
                    (long)gSnapshotPaths[index].section,
                    (long)gSnapshotPaths[index].row,
                    gSnapshotTitles[index].UTF8String ?: "?",
                    (unsigned long)gSnapshotHashes[index],
                    frames[index].origin.x, frames[index].origin.y,
                    frames[index].size.width, frames[index].size.height);
        }
    }
    if (changedOut != NULL) *changedOut = changed;
    return gSnapshotCount;
}

static NSIndexPath *TOWXFindCurrentPathForIdentity(UITableView *table,
                                                    NSString *targetTitle,
                                                    NSUInteger targetHash,
                                                    BOOL *ambiguousOut) {
    if (ambiguousOut != NULL) *ambiguousOut = NO;
    NSArray<NSIndexPath *> *visiblePaths = [table indexPathsForVisibleRows] ?: @[];
    NSIndexPath *match = nil;
    NSUInteger matches = 0;
    for (NSIndexPath *path in visiblePaths) {
        UITableViewCell *cell = [table cellForRowAtIndexPath:path];
        NSString *title = nil;
        NSUInteger hash = 0;
        if (!TOWXIdentityFromCell(cell, &title, &hash, NULL, NULL)) continue;
        if ([title isEqualToString:targetTitle] && hash == targetHash) {
            match = path;
            matches += 1;
        }
    }
    if (matches > 1) {
        if (ambiguousOut != NULL) *ambiguousOut = YES;
        return nil;
    }
    return matches == 1 ? match : nil;
}

static void TOWXAck(NSUInteger index) {
    (void)TOWXSetToken(gAckIndexToken, (uint64_t)index);
    notify_post(TOWX_LINK_ACK);
}

static void TOWXResolveIdentityAndOpen(NSUInteger index,
                                       NSString *targetTitle,
                                       NSUInteger targetHash,
                                       NSUInteger attempt) {
    if (!gOpenBusy) return;
    UITableView *table = gSnapshotTable;
    NSUInteger navDepth = 0;
    if (![table isKindOfClass:[UITableView class]] || !TOWXConversationRootIsActive(table, &navDepth)) {
        if (attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                TOWXResolveIdentityAndOpen(index, targetTitle, targetHash, attempt + 1);
            });
        } else {
            gOpenBusy = NO;
            TOWXLog("TOWX|WX|P2A4|OPEN-IDENTITY-MISS|index=%lu|reason=root-not-ready|title=%s|hash=%lu",
                    (unsigned long)index, targetTitle.UTF8String ?: "?", (unsigned long)targetHash);
        }
        return;
    }

    BOOL ambiguous = NO;
    NSIndexPath *path = TOWXFindCurrentPathForIdentity(table, targetTitle, targetHash, &ambiguous);
    if (path == nil) {
        if (!ambiguous && attempt < 8) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                TOWXResolveIdentityAndOpen(index, targetTitle, targetHash, attempt + 1);
            });
        } else {
            gOpenBusy = NO;
            TOWXLog("TOWX|WX|P2A4|OPEN-IDENTITY-MISS|index=%lu|reason=%s|title=%s|hash=%lu",
                    (unsigned long)index,
                    ambiguous ? "ambiguous" : "not-visible",
                    targetTitle.UTF8String ?: "?",
                    (unsigned long)targetHash);
        }
        return;
    }

    id<UITableViewDelegate> delegate = table.delegate;
    if (delegate == nil || ![delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|P2A4|OPEN-IDENTITY-MISS|index=%lu|reason=delegate|title=%s|hash=%lu",
                (unsigned long)index, targetTitle.UTF8String ?: "?", (unsigned long)targetHash);
        return;
    }

    [table selectRowAtIndexPath:path animated:NO scrollPosition:UITableViewScrollPositionNone];
    [delegate tableView:table didSelectRowAtIndexPath:path];
    TOWXAck(index);
    gOpenBusy = NO;
    TOWXLog("TOWX|WX|P2A4|OPEN-IDENTITY-MATCH|index=%lu|title=%s|hash=%lu|section=%ld|row=%ld|delegate=%s",
            (unsigned long)index,
            targetTitle.UTF8String ?: "?",
            (unsigned long)targetHash,
            (long)path.section,
            (long)path.row,
            object_getClassName(delegate) ?: "unknown");
    TOWXLog("TOWX|WX|P2A4|OPEN-SNAPSHOT|index=%lu|serial=%llu|verifiedIdentity=yes",
            (unsigned long)index, (unsigned long long)gSnapshotSerial);
}

static void TOWXOpenRecent(NSUInteger index) {
    @autoreleasepool {
        if (index >= gSnapshotCount || index >= TOWX_MAX_RECENTS) {
            TOWXLog("TOWX|WX|P2A4|OPEN-REJECT|index=%lu|reason=out-of-range|count=%lu",
                    (unsigned long)index, (unsigned long)gSnapshotCount);
            return;
        }
        if (gOpenBusy) {
            TOWXLog("TOWX|WX|P2A4|OPEN-REJECT|index=%lu|reason=busy", (unsigned long)index);
            return;
        }
        NSString *targetTitle = [gSnapshotTitles[index] copy];
        NSUInteger targetHash = gSnapshotHashes[index];
        if (targetTitle.length == 0 || targetHash == 0) {
            TOWXLog("TOWX|WX|P2A4|OPEN-REJECT|index=%lu|reason=identity-empty", (unsigned long)index);
            return;
        }

        UIWindow *window = TOWXActiveWindow();
        UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
        gOpenBusy = YES;
        if (navigation != nil && navigation.viewControllers.count > 0 && navigation.topViewController != navigation.viewControllers.firstObject) {
            TOWXLog("TOWX|WX|P2A4|NAV-RESET|index=%lu|depth=%lu|target=%s",
                    (unsigned long)index,
                    (unsigned long)navigation.viewControllers.count,
                    targetTitle.UTF8String ?: "?");
            [navigation popToRootViewControllerAnimated:NO];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(50 * NSEC_PER_MSEC)),
                           dispatch_get_main_queue(), ^{
                TOWXResolveIdentityAndOpen(index, targetTitle, targetHash, 0);
            });
        } else {
            TOWXResolveIdentityAndOpen(index, targetTitle, targetHash, 0);
        }
    }
}

static void TOWXHeavyTick(void) {
    UITableView *table = (UITableView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_TABLE_OFFSET);
    uint64_t count64 = TOWXGoldenCount();
    BOOL heartbeat = (gTick % 300U) == 0U;
    if (count64 > TOWX_MAX_RECENTS) {
        TOWXPublish(490, count64, heartbeat);
        return;
    }
    if (![table isKindOfClass:[UITableView class]] || count64 == 0) {
        TOWXPublish(gSnapshotCount > 0 ? 470 : 430, gSnapshotCount, heartbeat);
        return;
    }

    NSUInteger navDepth = 0;
    if (!TOWXConversationRootIsActive(table, &navDepth)) {
        if (gLastLoggedNavDepth != navDepth) {
            gLastLoggedNavDepth = navDepth;
            TOWXLog("TOWX|WX|P2A4|SNAPSHOT-HOLD|reason=not-conversation-root|navDepth=%lu|count=%lu",
                    (unsigned long)navDepth, (unsigned long)gSnapshotCount);
        }
        TOWXPublish(gSnapshotCount > 0 ? 470 : 430, gSnapshotCount, heartbeat);
        return;
    }
    gLastLoggedNavDepth = navDepth;

    BOOL changed = NO;
    NSUInteger captured = TOWXCaptureConversationSnapshot(table, count64, &changed);
    if (captured == 0) {
        TOWXPublish(gSnapshotCount > 0 ? 470 : 430, gSnapshotCount, heartbeat);
        return;
    }
    TOWXLog("TOWX|WX|P2A4|SNAPSHOT-READY|source=conversation-root+identity|snapshot=%llu|count=%lu|changed=%s",
            (unsigned long long)gSnapshotSerial,
            (unsigned long)captured,
            changed ? "yes" : "no");
    TOWXPublish(450, captured, changed || heartbeat);
}

static void TOWXTick(void) {
    @autoreleasepool {
        gTick += 1;
        if (gGoldenBase == 0) {
            gGoldenBase = TOWXFindGoldenBase();
            if (gGoldenBase == 0) {
                if ((gTick % 50U) == 0U) TOWXPublish(410, 0, YES);
                return;
            }
            TOWXPublish(420, 0, YES);
        }

        UIView *bar = (UIView *)TOWXGoldenObjectAtOffset(TOWX_GOLDEN_BAR_OFFSET);
        if (bar != nil) TOWXSuppressGoldenInAppBar(bar);
        else if (gLastGoldenBar != nil) {
            gLastGoldenBar.hidden = YES;
            gLastGoldenBar.alpha = 0.0;
            gLastGoldenBar.layer.opacity = 0.0f;
        }

        if ((gTick % 5U) == 0U) TOWXHeavyTick();
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|P2A4|ADAPTER-START|v0.7.0|mode=conversation-root+identity-lock+no-index-fallback|golden=0.6.0-clean1|paths:0x4080");
    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) return;

    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        char name[96];
        (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
        uint32_t status = notify_register_dispatch(name, &gOpenTokens[index], dispatch_get_main_queue(), ^(int token) {
            (void)token;
            TOWXOpenRecent(index);
        });
        if (status != NOTIFY_STATUS_OK) {
            TOWXLog("TOWX|WX|P2A4|OPEN-LISTENER-FAIL|index=%lu|status=%u", (unsigned long)index, status);
        }
    }

    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gTimer == nil) return;
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 10U),
                              (uint64_t)(NSEC_PER_SEC / 100U));
    dispatch_source_set_event_handler(gTimer, ^{ TOWXTick(); });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void TOWXGoldenAdapterInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXStart(); });
}
