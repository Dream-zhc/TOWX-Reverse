#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <math.h>
#import <stdint.h>
#import <stdio.h>

#define TOWX_P2A_READY "com.dream.towx.p2a.ready"
#define TOWX_P2A_GENERATION "com.dream.towx.p2a.generation"
#define TOWX_P2A_COUNT "com.dream.towx.p2a.count"
#define TOWX_P2A_AVATAR0_LENGTH "com.dream.towx.p2a.avatar0.length"
#define TOWX_P2A_AVATAR0_HASH "com.dream.towx.p2a.avatar0.hash"
#define TOWX_P2A_CHUNK_PREFIX "com.dream.towx.p2a.avatar0.chunk."
#define TOWX_P2A_MAX_BYTES 4096U
#define TOWX_OPEN_RECENT_PREFIX "com.dream.towx.openRecent."

static uint64_t TOWXFNV1a64(const uint8_t *bytes, NSUInteger length) {
    uint64_t value = UINT64_C(1469598103934665603);
    for (NSUInteger i = 0; i < length; i++) {
        value ^= (uint64_t)bytes[i];
        value *= UINT64_C(1099511628211);
    }
    return value;
}

static BOOL TOWXSetState(const char *name, uint64_t value) {
    int token = 0;
    uint32_t status = notify_register_check(name, &token);
    if (status != NOTIFY_STATUS_OK) {
        return NO;
    }
    status = notify_set_state(token, value);
    (void)notify_cancel(token);
    return status == NOTIFY_STATUS_OK;
}

static NSArray<UIWindow *> *TOWXWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSArray<UIWindow *> *windows = application.windows;
    if (windows.count > 0) {
        return windows;
    }
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) {
            continue;
        }
        [result addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    return result;
}

static UITabBar *TOWXFindTabBarInView(UIView *view) {
    if ([view isKindOfClass:UITabBar.class] && !view.hidden && view.alpha > 0.01) {
        return (UITabBar *)view;
    }
    for (UIView *subview in view.subviews) {
        UITabBar *tabBar = TOWXFindTabBarInView(subview);
        if (tabBar != nil) {
            return tabBar;
        }
    }
    return nil;
}

static void TOWXCollectTables(UIView *view, NSMutableArray<UITableView *> *tables) {
    if ([view isKindOfClass:UITableView.class] && !view.hidden && view.alpha > 0.01) {
        [tables addObject:(UITableView *)view];
    }
    for (UIView *subview in view.subviews) {
        TOWXCollectTables(subview, tables);
    }
}

static UIImageView *TOWXBestAvatarView(UIView *view, UIImageView *best, CGFloat *bestScore) {
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        CGFloat width = CGRectGetWidth(imageView.bounds);
        CGFloat height = CGRectGetHeight(imageView.bounds);
        if (imageView.image != nil && !imageView.hidden && imageView.alpha > 0.05 &&
            width >= 30.0 && width <= 80.0 && height >= 30.0 && height <= 80.0) {
            CGFloat squarePenalty = fabs(width - height);
            CGFloat sizePenalty = fabs(MAX(width, height) - 48.0);
            CGFloat score = 1000.0 - squarePenalty * 8.0 - sizePenalty;
            if (score > *bestScore) {
                best = imageView;
                *bestScore = score;
            }
        }
    }
    for (UIView *subview in view.subviews) {
        best = TOWXBestAvatarView(subview, best, bestScore);
    }
    return best;
}

static UITabBar *TOWXVisibleMainTabBar(void) {
    for (UIWindow *window in TOWXWindows()) {
        if (window.hidden || window.alpha <= 0.01) {
            continue;
        }
        UITabBar *tabBar = TOWXFindTabBarInView(window);
        if (tabBar == nil || tabBar.items.count == 0 || tabBar.selectedItem == nil) {
            continue;
        }
        NSUInteger selectedIndex = [tabBar.items indexOfObject:tabBar.selectedItem];
        if (selectedIndex == 0) {
            return tabBar;
        }
    }
    return nil;
}

static NSArray<NSDictionary *> *TOWXRowsForTable(UITableView *table) {
    NSMutableArray<NSDictionary *> *rows = [NSMutableArray array];
    for (UITableViewCell *cell in table.visibleCells) {
        NSIndexPath *indexPath = [table indexPathForCell:cell];
        if (indexPath == nil) {
            continue;
        }
        CGFloat bestScore = -CGFLOAT_MAX;
        UIImageView *avatarView = TOWXBestAvatarView(cell.contentView, nil, &bestScore);
        if (avatarView.image == nil) {
            continue;
        }
        [rows addObject:@{ @"indexPath": indexPath, @"image": avatarView.image }];
    }
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        NSIndexPath *a = lhs[@"indexPath"];
        NSIndexPath *b = rhs[@"indexPath"];
        if (a.section != b.section) {
            return a.section < b.section ? NSOrderedAscending : NSOrderedDescending;
        }
        if (a.row != b.row) {
            return a.row < b.row ? NSOrderedAscending : NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    return rows;
}

static UITableView *TOWXBestRecentTable(NSArray<NSDictionary *> **outRows) {
    UITableView *bestTable = nil;
    NSArray<NSDictionary *> *bestRows = nil;
    NSInteger bestScore = NSIntegerMin;

    for (UIWindow *window in TOWXWindows()) {
        if (window.hidden || window.alpha <= 0.01) {
            continue;
        }
        NSMutableArray<UITableView *> *tables = [NSMutableArray array];
        TOWXCollectTables(window, tables);
        for (UITableView *table in tables) {
            if (CGRectGetHeight(table.bounds) < 180.0 || CGRectGetWidth(table.bounds) < 250.0) {
                continue;
            }
            NSArray<NSDictionary *> *rows = TOWXRowsForTable(table);
            if (rows.count == 0) {
                continue;
            }
            NSInteger score = (NSInteger)rows.count * 1000 + (NSInteger)CGRectGetHeight(table.bounds);
            if (score > bestScore) {
                bestScore = score;
                bestTable = table;
                bestRows = rows;
            }
        }
    }

    if (outRows != NULL) {
        *outRows = bestRows;
    }
    return bestTable;
}

static NSData *TOWXJPEGData(UIImage *image, CGSize size, CGFloat quality) {
    UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
    [image drawInRect:(CGRect){ .origin = CGPointZero, .size = size }];
    UIImage *scaled = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    if (scaled == nil) {
        return nil;
    }
    return UIImageJPEGRepresentation(scaled, quality);
}

@interface TOWXRuntimeController : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, weak) UITableView *recentTable;
@property (nonatomic, copy) NSArray<NSIndexPath *> *recentIndexPaths;
@property (nonatomic) uint64_t generation;
@property (nonatomic) uint64_t lastHash;
@property (nonatomic) NSUInteger lastCount;
@end

@implementation TOWXRuntimeController

+ (instancetype)sharedController {
    static TOWXRuntimeController *controller = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        controller = [TOWXRuntimeController new];
    });
    return controller;
}

- (void)start {
    if (self.timer != nil) {
        return;
    }
    for (NSUInteger index = 0; index < 6; index++) {
        char name[96];
        (void)snprintf(name, sizeof(name), "%s%lu", TOWX_OPEN_RECENT_PREFIX, (unsigned long)index);
        int token = 0;
        NSString *notificationName = [NSString stringWithUTF8String:name];
        uint32_t status = notify_register_dispatch(notificationName.UTF8String, &token, dispatch_get_main_queue(), ^(int incomingToken) {
            (void)incomingToken;
            [self openRecentAtIndex:index];
        });
        if (status != NOTIFY_STATUS_OK) {
            NSLog(@"TOWX|WX|P2A|OPEN-LISTENER-FAIL|index=%lu|status=%u", (unsigned long)index, status);
        }
    }
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [self tick:self.timer];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    @autoreleasepool {
        if (TOWXVisibleMainTabBar() == nil) {
            return;
        }

        NSArray<NSDictionary *> *rows = nil;
        UITableView *table = TOWXBestRecentTable(&rows);
        if (table == nil || rows.count == 0) {
            return;
        }

        NSMutableArray<NSIndexPath *> *indexPaths = [NSMutableArray arrayWithCapacity:MIN((NSUInteger)6, rows.count)];
        for (NSUInteger index = 0; index < MIN((NSUInteger)6, rows.count); index++) {
            [indexPaths addObject:rows[index][@"indexPath"]];
        }
        self.recentTable = table;
        self.recentIndexPaths = indexPaths;

        UIImage *avatar0 = rows.firstObject[@"image"];
        NSData *jpeg = TOWXJPEGData(avatar0, CGSizeMake(32.0, 32.0), 0.62);
        if (jpeg.length == 0 || jpeg.length > TOWX_P2A_MAX_BYTES) {
            jpeg = TOWXJPEGData(avatar0, CGSizeMake(24.0, 24.0), 0.45);
        }
        if (jpeg.length == 0 || jpeg.length > TOWX_P2A_MAX_BYTES) {
            NSLog(@"TOWX|WX|P2A|AVATAR0-ENCODE-FAIL|bytes=%lu", (unsigned long)jpeg.length);
            return;
        }

        uint64_t hash = TOWXFNV1a64(jpeg.bytes, jpeg.length);
        NSUInteger count = indexPaths.count;
        if (hash == self.lastHash && count == self.lastCount) {
            return;
        }

        const uint8_t *bytes = jpeg.bytes;
        NSUInteger chunkCount = (jpeg.length + 7U) / 8U;
        for (NSUInteger chunkIndex = 0; chunkIndex < chunkCount; chunkIndex++) {
            uint64_t state = 0;
            for (NSUInteger byteIndex = 0; byteIndex < 8U; byteIndex++) {
                NSUInteger inputIndex = chunkIndex * 8U + byteIndex;
                if (inputIndex >= jpeg.length) {
                    break;
                }
                state |= ((uint64_t)bytes[inputIndex]) << (byteIndex * 8U);
            }
            char chunkName[128];
            (void)snprintf(chunkName, sizeof(chunkName), "%s%04lu", TOWX_P2A_CHUNK_PREFIX, (unsigned long)chunkIndex);
            if (!TOWXSetState(chunkName, state)) {
                NSLog(@"TOWX|WX|P2A|CHUNK-WRITE-FAIL|chunk=%lu", (unsigned long)chunkIndex);
                return;
            }
        }

        self.generation += 1;
        if (!TOWXSetState(TOWX_P2A_COUNT, count) ||
            !TOWXSetState(TOWX_P2A_AVATAR0_LENGTH, jpeg.length) ||
            !TOWXSetState(TOWX_P2A_AVATAR0_HASH, hash) ||
            !TOWXSetState(TOWX_P2A_GENERATION, self.generation)) {
            NSLog(@"TOWX|WX|P2A|META-WRITE-FAIL");
            return;
        }

        self.lastHash = hash;
        self.lastCount = count;
        notify_post(TOWX_P2A_READY);
        NSLog(@"TOWX|WX|P2A|PUSH|generation=%llu|count=%lu|bytes=%lu|hash=%016llx",
              (unsigned long long)self.generation,
              (unsigned long)count,
              (unsigned long)jpeg.length,
              (unsigned long long)hash);
    }
}

- (void)openRecentAtIndex:(NSUInteger)index {
    if (index >= self.recentIndexPaths.count || self.recentTable == nil) {
        NSLog(@"TOWX|WX|P2A|OPEN-MISS|index=%lu", (unsigned long)index);
        return;
    }
    NSIndexPath *indexPath = self.recentIndexPaths[index];
    id<UITableViewDelegate> delegate = self.recentTable.delegate;
    if ([delegate respondsToSelector:@selector(tableView:didSelectRowAtIndexPath:)]) {
        [delegate tableView:self.recentTable didSelectRowAtIndexPath:indexPath];
        NSLog(@"TOWX|WX|P2A|OPEN-SENT|index=%lu|section=%ld|row=%ld",
              (unsigned long)index, (long)indexPath.section, (long)indexPath.row);
    } else {
        NSLog(@"TOWX|WX|P2A|OPEN-NO-DELEGATE|index=%lu", (unsigned long)index);
    }
}

@end

__attribute__((constructor)) static void TOWXWeChatBackendInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSLog(@"TOWX|WX|P2A|LOADED|v0.2.0");
        [[TOWXRuntimeController sharedController] performSelector:@selector(start) withObject:nil afterDelay:1.5];
    });
}
