#import "WXIFConversationFix.h"
#import "WXIFSettings.h"
#import <UIKit/UIKit.h>
#import <stdint.h>

static const NSTimeInterval WXIFMonitorInterval = 0.12;
static const NSTimeInterval WXIFRestoreWindowDuration = 3.0;
static const NSTimeInterval WXIFMaximumReturnDelay = 600.0;
static const CGFloat WXIFMinimumRestorableDistance = 120.0;

static NSArray<UIWindow *> *WXIFWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    if (windows.count == 0) {
        [windows addObjectsFromArray:application.windows];
    }
    return windows;
}

static UITabBar *WXIFFindVisibleTabBar(UIView *view) {
    if ([view isKindOfClass:UITabBar.class] && !view.hidden && view.alpha > 0.05 && view.window != nil) {
        return (UITabBar *)view;
    }
    for (UIView *subview in view.subviews) {
        UITabBar *found = WXIFFindVisibleTabBar(subview);
        if (found != nil) return found;
    }
    return nil;
}

static NSInteger WXIFVisibleSelectedTabIndex(void) {
    for (UIWindow *window in WXIFWindows()) {
        if (window.hidden || window.alpha <= 0.05) continue;
        UITabBar *tabBar = WXIFFindVisibleTabBar(window);
        if (tabBar == nil || tabBar.selectedItem == nil) continue;
        NSUInteger index = [tabBar.items indexOfObject:tabBar.selectedItem];
        if (index != NSNotFound) return (NSInteger)index;
    }
    return -1;
}

static NSUInteger WXIFAvatarCandidateCountInView(UIView *view, NSUInteger limit) {
    if (limit == 0) return 0;
    NSUInteger count = 0;
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        CGFloat width = CGRectGetWidth(imageView.bounds);
        CGFloat height = CGRectGetHeight(imageView.bounds);
        CGFloat delta = width - height;
        if (delta < 0) delta = -delta;
        if (imageView.image != nil && !imageView.hidden && imageView.alpha > 0.05 &&
            width >= 28.0 && width <= 82.0 && height >= 28.0 && height <= 82.0 && delta <= 14.0) {
            count += 1;
            if (count >= limit) return count;
        }
    }
    for (UIView *subview in view.subviews) {
        NSUInteger remaining = limit - count;
        NSUInteger nested = WXIFAvatarCandidateCountInView(subview, remaining);
        count += nested;
        if (count >= limit) break;
    }
    return count;
}

static void WXIFCollectVisibleTables(UIView *view, NSMutableArray<UITableView *> *tables) {
    if ([view isKindOfClass:UITableView.class] && !view.hidden && view.alpha > 0.05 && view.window != nil) {
        UITableView *table = (UITableView *)view;
        if (CGRectGetWidth(table.bounds) >= 250.0 && CGRectGetHeight(table.bounds) >= 240.0 && table.visibleCells.count >= 2) {
            [tables addObject:table];
        }
    }
    for (UIView *subview in view.subviews) {
        WXIFCollectVisibleTables(subview, tables);
    }
}

static UITableView *WXIFBestConversationTable(void) {
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    for (UIWindow *window in WXIFWindows()) {
        if (window.hidden || window.alpha <= 0.05) continue;
        WXIFCollectVisibleTables(window, tables);
    }

    UITableView *best = nil;
    double bestScore = 0;
    for (UITableView *table in tables) {
        NSUInteger visibleCount = table.visibleCells.count;
        NSUInteger avatarCount = 0;
        for (UITableViewCell *cell in table.visibleCells) {
            avatarCount += WXIFAvatarCandidateCountInView(cell.contentView, 2);
            if (avatarCount >= 10) break;
        }
        double area = CGRectGetWidth(table.bounds) * CGRectGetHeight(table.bounds);
        double scrollBonus = table.contentSize.height > CGRectGetHeight(table.bounds) + 60.0 ? 100000.0 : 0.0;
        double score = area + (double)visibleCount * 50000.0 + (double)avatarCount * 150000.0 + scrollBonus;
        if (score > bestScore) {
            bestScore = score;
            best = table;
        }
    }
    return best;
}

static NSString *WXIFOwnerClassName(UITableView *table) {
    UIResponder *responder = table;
    for (NSUInteger depth = 0; depth < 24 && responder != nil; depth += 1) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:UIViewController.class]) {
            return NSStringFromClass(responder.class) ?: @"?";
        }
    }
    return @"?";
}

@interface WXIFConversationMonitor : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, weak) UITableView *cachedTable;
@property (nonatomic) uintptr_t lastTablePointer;
@property (nonatomic) BOOL listVisibleLastTick;
@property (nonatomic) BOOL listDetected;
@property (nonatomic) BOOL hasSavedOffset;
@property (nonatomic) CGFloat savedOffsetY;
@property (nonatomic) CGFloat savedTopY;
@property (nonatomic) CGFloat currentOffsetY;
@property (nonatomic) BOOL hasCurrentOffset;
@property (nonatomic) NSTimeInterval lastListSeenAt;
@property (nonatomic) NSTimeInterval leftListAt;
@property (nonatomic) NSTimeInterval lastSavedAt;
@property (nonatomic) BOOL armed;
@property (nonatomic) BOOL restoreWindow;
@property (nonatomic) NSTimeInterval armedAt;
@property (nonatomic) NSTimeInterval restoreUntil;
@property (nonatomic) BOOL didRestoreThisCycle;
@property (nonatomic) BOOL otherTabDeparture;
@property (nonatomic) BOOL wasInactive;
@property (nonatomic) NSInteger tabIndex;
@property (nonatomic) NSUInteger detectionCount;
@property (nonatomic) NSUInteger successfulReturnCount;
@property (nonatomic) NSUInteger restoreWriteCount;
@property (nonatomic, copy) NSString *lastEvent;
@property (nonatomic, copy) NSString *tableClassName;
@property (nonatomic, copy) NSString *ownerClassName;
@end

@implementation WXIFConversationMonitor

+ (instancetype)sharedMonitor {
    static WXIFConversationMonitor *monitor;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        monitor = [WXIFConversationMonitor new];
        monitor.tabIndex = -1;
        monitor.lastEvent = @"等待识别会话列表";
        monitor.tableClassName = @"-";
        monitor.ownerClassName = @"-";
    });
    return monitor;
}

- (void)start {
    if (self.timer != nil) return;
    self.timer = [NSTimer timerWithTimeInterval:WXIFMonitorInterval
                                         target:self
                                       selector:@selector(tick:)
                                       userInfo:nil
                                        repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self.timer fire];
}

- (BOOL)isCachedTableUsable {
    UITableView *table = self.cachedTable;
    return table != nil && table.window != nil && !table.hidden && table.alpha > 0.05 &&
           CGRectGetWidth(table.bounds) >= 250.0 && CGRectGetHeight(table.bounds) >= 240.0 &&
           table.visibleCells.count >= 2;
}

- (void)cancelTransientRestoreWithEvent:(NSString *)event {
    self.armed = NO;
    self.restoreWindow = NO;
    self.restoreUntil = 0;
    self.didRestoreThisCycle = NO;
    if (event.length > 0) self.lastEvent = event;
}

- (void)saveCurrentPositionFromTable:(UITableView *)table now:(NSTimeInterval)now {
    CGFloat topY = -table.adjustedContentInset.top;
    CGFloat currentY = table.contentOffset.y;
    self.currentOffsetY = currentY;
    self.hasCurrentOffset = YES;
    self.savedTopY = topY;
    self.lastSavedAt = now;

    if (currentY > topY + WXIFMinimumRestorableDistance) {
        self.hasSavedOffset = YES;
        self.savedOffsetY = currentY;
    } else {
        self.hasSavedOffset = NO;
        self.savedOffsetY = currentY;
    }
}

- (BOOL)userIsInteractingWithTable:(UITableView *)table {
    UIGestureRecognizerState panState = table.panGestureRecognizer.state;
    return table.dragging || table.tracking || panState == UIGestureRecognizerStateBegan || panState == UIGestureRecognizerStateChanged;
}

- (void)attemptRestoreOnTable:(UITableView *)table now:(NSTimeInterval)now {
    if (!self.armed || !self.restoreWindow) return;
    if (now > self.restoreUntil) {
        BOOL restored = self.didRestoreThisCycle;
        [self cancelTransientRestoreWithEvent:restored ? @"修复窗口结束，位置已保持" : @"返回后位置正常，无需修复"];
        [self saveCurrentPositionFromTable:table now:now];
        return;
    }

    if ([self userIsInteractingWithTable:table]) {
        [self cancelTransientRestoreWithEvent:@"检测到手动滚动，停止本次恢复"];
        [self saveCurrentPositionFromTable:table now:now];
        return;
    }

    CGFloat topY = -table.adjustedContentInset.top;
    CGFloat currentY = table.contentOffset.y;
    self.currentOffsetY = currentY;
    self.hasCurrentOffset = YES;

    CGFloat maxY = table.contentSize.height - CGRectGetHeight(table.bounds) + table.adjustedContentInset.bottom;
    if (maxY < topY) maxY = topY;
    CGFloat targetY = self.savedOffsetY;
    if (targetY > maxY) targetY = maxY;

    if (targetY <= topY + WXIFMinimumRestorableDistance) {
        self.lastEvent = @"等待会话列表完成布局";
        return;
    }

    if (currentY <= topY + 100.0) {
        CGFloat beforeY = currentY;
        [table setContentOffset:CGPointMake(table.contentOffset.x, targetY) animated:NO];
        [table layoutIfNeeded];
        CGFloat afterY = table.contentOffset.y;
        self.currentOffsetY = afterY;
        self.restoreWriteCount += 1;

        if (afterY > topY + 80.0) {
            if (!self.didRestoreThisCycle) {
                self.didRestoreThisCycle = YES;
                self.successfulReturnCount += 1;
            }
            self.lastEvent = [NSString stringWithFormat:@"已恢复 %.0f → %.0f", beforeY, afterY];
        } else {
            self.lastEvent = @"已尝试恢复，但列表仍在顶部";
        }
    }
}

- (void)beginReturnWindowAt:(NSTimeInterval)now event:(NSString *)event {
    if (!self.hasSavedOffset) return;
    self.armed = YES;
    self.restoreWindow = YES;
    self.armedAt = self.armedAt > 0 ? self.armedAt : now;
    self.restoreUntil = now + WXIFRestoreWindowDuration;
    self.didRestoreThisCycle = NO;
    self.lastEvent = event;
}

- (void)handleVisibleConversationTable:(UITableView *)table now:(NSTimeInterval)now {
    uintptr_t pointer = (uintptr_t)(__bridge void *)table;
    BOOL returningAfterGap = !self.listVisibleLastTick;
    BOOL tableReplaced = self.listVisibleLastTick && self.lastTablePointer != 0 && self.lastTablePointer != pointer;

    if (returningAfterGap || tableReplaced) {
        self.detectionCount += 1;
    }

    if (returningAfterGap && self.hasSavedOffset && !self.otherTabDeparture && self.leftListAt > 0 &&
        now - self.leftListAt <= WXIFMaximumReturnDelay) {
        [self beginReturnWindowAt:now event:@"会话列表重新出现，检查是否跳顶"];
    } else if (tableReplaced && self.hasSavedOffset && !self.otherTabDeparture) {
        [self beginReturnWindowAt:now event:@"检测到会话列表重建，检查位置"];
    }

    self.listVisibleLastTick = YES;
    self.listDetected = YES;
    self.cachedTable = table;
    self.lastTablePointer = pointer;
    self.lastListSeenAt = now;
    self.otherTabDeparture = NO;
    self.tableClassName = NSStringFromClass(table.class) ?: @"?";
    self.ownerClassName = WXIFOwnerClassName(table);
    self.currentOffsetY = table.contentOffset.y;
    self.hasCurrentOffset = YES;

    if (self.armed) {
        if (!self.restoreWindow) {
            [self beginReturnWindowAt:now event:@"已返回会话列表，进入修复窗口"];
        }
        [self attemptRestoreOnTable:table now:now];
    } else {
        [self saveCurrentPositionFromTable:table now:now];
        if (returningAfterGap && self.lastEvent.length == 0) {
            self.lastEvent = @"已识别会话列表";
        }
    }
}

- (void)handleConversationListMissingAt:(NSTimeInterval)now tabIndex:(NSInteger)tabIndex {
    self.listDetected = NO;
    self.hasCurrentOffset = NO;
    self.cachedTable = nil;

    if (self.listVisibleLastTick) {
        self.listVisibleLastTick = NO;
        self.leftListAt = now;
        self.restoreWindow = NO;
        self.restoreUntil = 0;
        self.didRestoreThisCycle = NO;

        if (tabIndex >= 0 && tabIndex != 0) {
            self.otherTabDeparture = YES;
            self.armed = NO;
            self.armedAt = 0;
            self.lastEvent = @"切换到其他标签，不触发恢复";
        } else if (self.hasSavedOffset) {
            self.otherTabDeparture = NO;
            self.armed = YES;
            self.armedAt = now;
            self.lastEvent = [NSString stringWithFormat:@"会话列表离屏，已保存 Y=%.0f", self.savedOffsetY];
        } else {
            self.otherTabDeparture = NO;
            self.armed = NO;
            self.armedAt = 0;
            self.lastEvent = @"会话列表离屏，但当前位置无需保存";
        }
        return;
    }

    if (tabIndex >= 0 && tabIndex != 0) {
        self.otherTabDeparture = YES;
        [self cancelTransientRestoreWithEvent:@"当前不在消息标签"];
        return;
    }

    if (self.armed && self.armedAt > 0 && now - self.armedAt > WXIFMaximumReturnDelay) {
        self.armedAt = 0;
        [self cancelTransientRestoreWithEvent:@"等待返回超时，已放弃旧位置"];
    }
}

- (void)tick:(NSTimer *)timer {
    (void)timer;

    if (![WXIFSettings conversationPositionFixEnabled]) {
        self.listDetected = NO;
        self.listVisibleLastTick = NO;
        self.cachedTable = nil;
        self.hasCurrentOffset = NO;
        [self cancelTransientRestoreWithEvent:@"会话列表位置修复已关闭"];
        return;
    }

    UIApplication *application = UIApplication.sharedApplication;
    if (application.applicationState != UIApplicationStateActive) {
        self.wasInactive = YES;
        self.listDetected = NO;
        self.listVisibleLastTick = NO;
        self.cachedTable = nil;
        self.hasCurrentOffset = NO;
        self.otherTabDeparture = YES;
        [self cancelTransientRestoreWithEvent:@"微信不在前台，暂停监视"];
        return;
    }

    if (self.wasInactive) {
        self.wasInactive = NO;
        self.otherTabDeparture = YES;
        self.listVisibleLastTick = NO;
        self.lastEvent = @"微信回到前台，重新识别会话列表";
    }

    NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
    NSInteger tabIndex = WXIFVisibleSelectedTabIndex();
    self.tabIndex = tabIndex;

    if (tabIndex >= 0 && tabIndex != 0) {
        [self handleConversationListMissingAt:now tabIndex:tabIndex];
        return;
    }

    UITableView *table = nil;
    if (tabIndex == 0) {
        if ([self isCachedTableUsable]) {
            table = self.cachedTable;
        } else {
            table = WXIFBestConversationTable();
        }
    }

    if (table != nil) {
        [self handleVisibleConversationTable:table now:now];
    } else {
        [self handleConversationListMissingAt:now tabIndex:tabIndex];
    }
}

- (NSString *)tabDescription {
    if (self.tabIndex < 0) return @"底栏不可见";
    if (self.tabIndex == 0) return @"消息";
    return [NSString stringWithFormat:@"第 %ld 项", (long)self.tabIndex + 1];
}

- (NSString *)stateDescription {
    if (![WXIFSettings conversationPositionFixEnabled]) return @"已关闭";
    if (self.restoreWindow) return @"恢复窗口";
    if (self.armed) return @"等待返回";
    if (self.listDetected) return @"正在记录";
    return @"等待识别";
}

- (NSDictionary<NSString *, NSString *> *)snapshot {
    NSString *saved = self.hasSavedOffset ? [NSString stringWithFormat:@"%.0f pt", self.savedOffsetY] : @"无";
    NSString *current = self.hasCurrentOffset ? [NSString stringWithFormat:@"%.0f pt", self.currentOffsetY] : @"-";
    return @{
        @"detected": self.listDetected ? @"已识别" : @"未识别",
        @"tab": [self tabDescription],
        @"saved": saved,
        @"current": current,
        @"state": [self stateDescription],
        @"restores": [NSString stringWithFormat:@"%lu", (unsigned long)self.successfulReturnCount],
        @"writes": [NSString stringWithFormat:@"%lu", (unsigned long)self.restoreWriteCount],
        @"table": self.tableClassName ?: @"-",
        @"owner": self.ownerClassName ?: @"-",
        @"event": self.lastEvent ?: @"-",
    };
}

@end

@implementation WXIFConversationFix

+ (void)startMonitoring {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[WXIFConversationMonitor sharedMonitor] start];
    });
}

+ (NSDictionary<NSString *, NSString *> *)diagnosticSnapshot {
    if (![NSThread isMainThread]) {
        __block NSDictionary<NSString *, NSString *> *snapshot = nil;
        dispatch_sync(dispatch_get_main_queue(), ^{
            snapshot = [[WXIFConversationMonitor sharedMonitor] snapshot];
        });
        return snapshot ?: @{};
    }
    return [[WXIFConversationMonitor sharedMonitor] snapshot];
}

@end
