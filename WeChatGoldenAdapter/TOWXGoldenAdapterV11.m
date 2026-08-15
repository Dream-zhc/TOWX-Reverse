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
#define TOWX_SCAN_PATH_LIMIT 64U
#define TOWX_SCORE_SAMPLE_LIMIT 20U

static dispatch_source_t gTimer = nil;
static uint64_t gGeneration = 0;
static uint64_t gLastStage = UINT64_MAX;
static uint64_t gLastCount = UINT64_MAX;
static unsigned int gTick = 0;

static __weak UITableView *gSnapshotTable = nil;
static __weak UITableView *gLastDiscoveredTable = nil;
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
        TOWXLog("TOWX|WX|P2A4|STATE-REGISTER-FAIL|v11|name=%s|status=%u", name, status);
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
        TOWXLog("TOWX|WX|P2A4|STATE-WRITE-FAIL|v11|generation=%llu|stage=%llu|count=%llu",
                (unsigned long long)gGeneration,
                (unsigned long long)stage,
                (unsigned long long)count);
        return;
    }
    gLastStage = stage;
    gLastCount = count;
    notify_post(TOWX_LINK_READY);
    TOWXLog("TOWX|WX|P2A4|PUBLISH|v11|generation=%llu|stage=%llu|count=%llu|snapshot=%llu",
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
            if (gPrefetchedCells.count > 96) [gPrefetchedCells removeAllObjects];
            gPrefetchedCells[key] = cell;
        }
    } @catch (NSException *exception) {
        TOWXLog("TOWX|WX|P2A4|PREFETCH-EXCEPTION|v11|path=%s|reason=%s",
                key.UTF8String ?: "?",
                exception.reason.UTF8String ?: "?");
        cell = nil;
    }
    return cell;
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
        CGFloat width = CGRectGetWidth(frame);
        CGFloat height = CGRectGetHeight(frame);
        if (width < 28.0 || width > 82.0 || height < 28.0 || height > 82.0) continue;
        if (fabs(width - height) > 14.0) continue;
        if (CGRectGetMinX(frame) < -4.0 || CGRectGetMinX(frame) > 118.0) continue;
        CGFloat score = width * height - CGRectGetMinX(frame) * 9.0 - fabs(CGRectGetMidY(frame) - centerY) * 12.0;
        if (score > bestScore) {
            bestScore = score;
            best = imageView;
        }
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
        if (score > bestScore) {
            bestScore = score;
            best = label;
        }
    }
    return [best.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

static BOOL TOWXIdentityFromCell(UITableViewCell *cell,
                                 NSString **titleOut,
                                 NSUInteger *hashOut,
                                 UIImage **imageOut) {
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

static void TOWXCollectTablesDeep(UIView *view, NSMutableArray<UITableView *> *tables) {
    if (!view) return;
    if ([view isKindOfClass:[UITableView class]]) [tables addObject:(UITableView *)view];
    for (UIView *subview in view.subviews) TOWXCollectTablesDeep(subview, tables);
}

static NSInteger TOWXConversationTableScore(UITableView *table) {
    if (![table isKindOfClass:[UITableView class]]) return NSIntegerMin;
    NSArray<NSIndexPath *> *paths = TOWXConversationPaths(table);
    if (paths.count == 0) return NSIntegerMin;

    NSUInteger identityCount = 0;
    NSUInteger sampleCount = MIN((NSUInteger)TOWX_SCORE_SAMPLE_LIMIT, paths.count);
    for (NSUInteger index = 0; index < sampleCount; index++) {
        NSString *title = nil;
        NSUInteger hash = 0;
        if (TOWXIdentityFromCell(TOWXCellForPath(table, paths[index]), &title, &hash, NULL) && title.length > 0 && hash != 0) {
            identityCount += 1;
        }
    }
    if (identityCount < 2) return NSIntegerMin;

    NSInteger score = (NSInteger)identityCount * 1000 + (NSInteger)MIN((NSUInteger)100, paths.count) * 5;
    CGFloat width = CGRectGetWidth(table.bounds);
    CGFloat height = CGRectGetHeight(table.bounds);
    if (width >= 250.0) score += 200;
    if (height >= 240.0) score += 100;
    return score;
}

static UITableView *TOWXDiscoverConversationTable(void) {
    UIWindow *window = TOWXActiveWindow();
    UINavigationController *navigation = TOWXFindNavigationController(window.rootViewController);
    if (!navigation || navigation.viewControllers.count == 0) return nil;
    UIViewController *root = navigation.viewControllers.firstObject;
    UIView *rootView = root.viewIfLoaded;
    if (!rootView) return nil;

    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    TOWXCollectTablesDeep(rootView, tables);
    UITableView *best = nil;
    NSInteger bestScore = NSIntegerMin;
    for (UITableView *candidate in tables) {
        NSInteger score = TOWXConversationTableScore(candidate);
        if (score > bestScore) {
            bestScore = score;
            best = candidate;
        }
    }

    if (best && gLastDiscoveredTable != best) {
        gLastDiscoveredTable = best;
        NSInteger sections = [best numberOfSections];
        NSInteger rows0 = sections > 0 ? [best numberOfRowsInSection:0] : 0;
        TOWXLog("TOWX|WX|P2A4|TABLE-DISCOVERY|v11|table=%p|class=%s|score=%ld|sections=%ld|rows0=%ld",
                best,
                object_getClassName(best) ?: "?",
                (long)bestScore,
                (long)sections,
                (long)rows0);
    }
    return best;
}

static BOOL TOWXIdentityAlreadyAdded(NSString *title,
                                     NSUInteger hash,
                                     NSUInteger count,
                                     NSString * __strong *titles,
                                     const NSUInteger *hashes) {
    for (NSUInteger index = 0; index < count; index++) {
        if (hashes[index] == hash && [titles[index] isEqualToString:title]) return YES;
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
        TOWXLog("TOWX|WX|P2A4|SNAPSHOT-HOLD|v11|reason=partial-prefetch|new=%lu|old=%lu",
                (unsigned long)usable,
                (unsigned long)gSnapshotCount);
        return gSnapshotCount;
    }

    BOOL changed = gSnapshotTable != table || gSnapshotCount != usable;
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
        NSString *file = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        if (index < usable) {
            gSnapshotPaths[index] = paths[index];
            gSnapshotTitles[index] = [titles[index] copy];
            gSnapshotHashes[index] = hashes[index];
            NSData *data = UIImagePNGRepresentation(images[index]);
            if (data.length > 0 &&
                (gExportHashes[index] != hashes[index] || ![[NSFileManager defaultManager] fileExistsAtPath:file])) {
                NSError *error = nil;
                if ([data writeToFile:file options:NSDataWritingAtomic error:&error]) {
                    gExportHashes[index] = hashes[index];
                    changed = YES;
                } else {
                    TOWXLog("TOWX|WX|P2A4|AVATAR-WRITE-FAIL|v11|index=%lu|error=%s",
                            (unsigned long)index,
                            error.localizedDescription.UTF8String ?: "?");
                }
            }
        } else {
            gSnapshotPaths[index] = nil;
            gSnapshotTitles[index] = nil;
            gSnapshotHashes[index] = 0;
            gExportHashes[index] = 0;
            [[NSFileManager defaultManager] removeItemAtPath:file error:nil];
        }
    }

    if (changed || gSnapshotSerial == 0) {
        gSnapshotSerial += 1;
        TOWXLog("TOWX|WX|P2A4|SNAPSHOT-CAPTURE|v11|serial=%llu|source=wechat-root-table|count=%lu",
                (unsigned long long)gSnapshotSerial,
                (unsigned long)gSnapshotCount);
        for (NSUInteger index = 0; index < gSnapshotCount; index++) {
            TOWXLog("TOWX|WX|P2A4|IDENTITY-SLOT|v11|index=%lu|section=%ld|row=%ld|title=%s|hash=%lu",
                    (unsigned long)index,
                    (long)gSnapshotPaths[index].section,
                    (long)gSnapshotPaths[index].row,
                    gSnapshotTitles[index].UTF8String ?: "?",
                    (unsigned long)gSnapshotHashes[index]);
        }
    }

    if (changedOut) *changedOut = changed;
    return gSnapshotCount;
}

static NSIndexPath *TOWXFindPathForIdentity(UITableView *table, NSString *title, NSUInteger hash) {
    if (![table isKindOfClass:[UITableView class]] || title.length == 0 || hash == 0) return nil;
    for (NSIndexPath *path in TOWXConversationPaths(table)) {
        NSString *candidateTitle = nil;
        NSUInteger candidateHash = 0;
        if (!TOWXIdentityFromCell(TOWXCellForPath(table, path), &candidateTitle, &candidateHash, NULL)) continue;
        if (candidateHash == hash && [candidateTitle isEqualToString:title]) return path;
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

static void TOWXOpenFromRoot(NSUInteger index, NSString *title, NSUInteger hash) {
    UITableView *table = gSnapshotTable ?: TOWXDiscoverConversationTable();
    NSIndexPath *path = TOWXFindPathForIdentity(table, title, hash);
    if (!path || !TOWXSelectPath(table, path)) {
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|P2A4|OPEN-MISS|v11|index=%lu|mode=root|target=%s",
                (unsigned long)index,
                title.UTF8String ?: "?");
        return;
    }
    TOWXAck(index);
    gOpenBusy = NO;
    TOWXLog("TOWX|WX|P2A4|OPEN-SNAPSHOT|v11|index=%lu|mode=root|section=%ld|row=%ld|target=%s",
            (unsigned long)index,
            (long)path.section,
            (long)path.row,
            title.UTF8String ?: "?");
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
    TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-MASK|v12|state=installed|window=%p", window);
    return mask;
}

static void TOWXRemoveDirectSwitchMask(UIView *mask, BOOL animated) {
    if (!mask) return;
    void (^remove)(void) = ^{
        [mask removeFromSuperview];
        TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-MASK|v12|state=removed");
    };
    if (!animated) { remove(); return; }
    [UIView animateWithDuration:0.08
                          delay:0.0
                        options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ mask.alpha = 0.0; }
                     completion:^(__unused BOOL finished) { remove(); }];
}

static void TOWXVerifyMaskedSwitch(NSUInteger index,
                                   NSString *title,
                                   NSUInteger hash,
                                   UINavigationController *navigation,
                                   UIViewController *root,
                                   UIViewController *oldTop,
                                   NSArray<UIViewController *> *originalStack,
                                   UIView *mask,
                                   NSUInteger attempt,
                                   BOOL fallbackPhase);

static void TOWXMaskedFallback(NSUInteger index,
                               NSString *title,
                               NSUInteger hash,
                               UINavigationController *navigation,
                               UIViewController *root,
                               UIViewController *oldTop,
                               NSArray<UIViewController *> *originalStack,
                               UIView *mask) {
    TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-MASKED-FALLBACK|v12|index=%lu|target=%s|policy=never-expose-root",
            (unsigned long)index,
            title.UTF8String ?: "?");

    UITableView *table = gSnapshotTable ?: TOWXDiscoverConversationTable();
    NSIndexPath *path = TOWXFindPathForIdentity(table, title, hash);
    if (!path) {
        if (originalStack.count) [navigation setViewControllers:originalStack animated:NO];
        TOWXRemoveDirectSwitchMask(mask, NO);
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-FAIL|v12|index=%lu|reason=fallback-identity-miss", (unsigned long)index);
        return;
    }

    [UIView performWithoutAnimation:^{
        [navigation setViewControllers:@[root] animated:NO];
    }];
    __block BOOL selected = NO;
    [UIView performWithoutAnimation:^{ selected = TOWXSelectPath(table, path); }];
    if (!selected) {
        if (originalStack.count) [navigation setViewControllers:originalStack animated:NO];
        TOWXRemoveDirectSwitchMask(mask, NO);
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-FAIL|v12|index=%lu|reason=fallback-select-failed", (unsigned long)index);
        return;
    }

    TOWXVerifyMaskedSwitch(index, title, hash, navigation, root, oldTop, originalStack, mask, 0, YES);
}

static void TOWXVerifyMaskedSwitch(NSUInteger index,
                                   NSString *title,
                                   NSUInteger hash,
                                   UINavigationController *navigation,
                                   UIViewController *root,
                                   UIViewController *oldTop,
                                   NSArray<UIViewController *> *originalStack,
                                   UIView *mask,
                                   NSUInteger attempt,
                                   BOOL fallbackPhase) {
    UIViewController *newTop = navigation.topViewController;
    if (newTop && newTop != root && (!oldTop || newTop != oldTop)) {
        [UIView performWithoutAnimation:^{
            [navigation setViewControllers:@[root, newTop] animated:NO];
        }];
        TOWXAck(index);
        gOpenBusy = NO;
        TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-SUCCESS|v12|index=%lu|target=%s|attempt=%lu|fallback=%d|newTop=%s",
                (unsigned long)index,
                title.UTF8String ?: "?",
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
            TOWXVerifyMaskedSwitch(index, title, hash, navigation, root, oldTop, originalStack, mask, attempt + 1, fallbackPhase);
        });
        return;
    }

    if (!fallbackPhase) {
        TOWXMaskedFallback(index, title, hash, navigation, root, oldTop, originalStack, mask);
        return;
    }

    if (originalStack.count) [navigation setViewControllers:originalStack animated:NO];
    TOWXRemoveDirectSwitchMask(mask, NO);
    gOpenBusy = NO;
    TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-FAIL|v12|index=%lu|target=%s|reason=no-target-after-masked-fallback",
            (unsigned long)index,
            title.UTF8String ?: "?");
}

static void TOWXOpenRecent(NSUInteger index) {
    @autoreleasepool {
        if (index >= gSnapshotCount || index >= TOWX_MAX_RECENTS || gOpenBusy) return;
        UITableView *table = gSnapshotTable ?: TOWXDiscoverConversationTable();
        NSString *title = [gSnapshotTitles[index] copy];
        NSUInteger hash = gSnapshotHashes[index];
        if (![table isKindOfClass:[UITableView class]] || title.length == 0 || hash == 0) return;

        NSIndexPath *path = TOWXFindPathForIdentity(table, title, hash);
        if (!path) {
            TOWXLog("TOWX|WX|P2A4|OPEN-REJECT|v12|index=%lu|reason=identity-not-found|target=%s",
                    (unsigned long)index,
                    title.UTF8String ?: "?");
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
            TOWXOpenFromRoot(index, title, hash);
            return;
        }

        UIView *mask = TOWXInstallDirectSwitchMask(window);
        __block BOOL selected = NO;
        [UIView performWithoutAnimation:^{ selected = TOWXSelectPath(table, path); }];
        if (!selected) {
            TOWXRemoveDirectSwitchMask(mask, NO);
            gOpenBusy = NO;
            TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-FAIL|v12|index=%lu|reason=direct-select-failed|target=%s",
                    (unsigned long)index,
                    title.UTF8String ?: "?");
            return;
        }

        TOWXLog("TOWX|WX|P2A4|DIRECT-SWITCH-BEGIN|v12|index=%lu|target=%s|oldTop=%s|depth=%lu|mask=%d",
                (unsigned long)index,
                title.UTF8String ?: "?",
                object_getClassName(oldTop) ?: "?",
                (unsigned long)navigation.viewControllers.count,
                mask ? 1 : 0);
        TOWXVerifyMaskedSwitch(index, title, hash, navigation, root, oldTop, originalStack, mask, 0, NO);
    }
}

static void TOWXHeavyTick(void) {
    BOOL heartbeat = (gTick % 300U) == 0U;
    UITableView *table = TOWXDiscoverConversationTable();
    if (![table isKindOfClass:[UITableView class]]) {
        TOWXPublish(gSnapshotCount > 0 ? 670 : 630, gSnapshotCount, heartbeat);
        return;
    }

    BOOL changed = NO;
    NSUInteger captured = TOWXCaptureSnapshot(table, &changed);
    if (captured == 0) {
        TOWXPublish(gSnapshotCount > 0 ? 670 : 640, gSnapshotCount, heartbeat);
        return;
    }
    TOWXPublish(650, captured, changed || heartbeat);
}

static void TOWXTick(void) {
    @autoreleasepool {
        gTick += 1;
        if ((gTick % 5U) == 0U) TOWXHeavyTick();
    }
}

static void TOWXStart(void) {
    TOWXLog("TOWX|WX|P2A4|ADAPTER-START|v0.10.2|mode=standalone-optional+table-discovery+first15+direct-switch|max=15");
    TOWXLog("TOWX|WX|P2A4|STANDALONE-MISSING|v11|fallback=table-discovery|policy=standalone-not-required");

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
            TOWXLog("TOWX|WX|P2A4|OPEN-LISTENER-FAIL|v11|index=%lu|status=%u",
                    (unsigned long)index,
                    status);
        }
    }

    TOWXPublish(610, 0, YES);
    gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTimer) return;
    dispatch_source_set_timer(gTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 10U),
                              (uint64_t)(NSEC_PER_SEC / 100U));
    dispatch_source_set_event_handler(gTimer, ^{ TOWXTick(); });
    dispatch_resume(gTimer);
}

__attribute__((constructor)) static void TOWXGoldenAdapterV11Init(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXStart(); });
}
