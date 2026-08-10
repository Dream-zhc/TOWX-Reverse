#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <notify.h>
#import <math.h>
#import <stdint.h>
#import <stdio.h>

#define TOWX_P2A1_READY "com.dream.towx.p2a1.ready"
#define TOWX_P2A1_GENERATION "com.dream.towx.p2a1.generation"
#define TOWX_P2A1_COUNT "com.dream.towx.p2a1.count"
#define TOWX_P2A1_STAGE "com.dream.towx.p2a1.stage"

// Diagnostic stage codes consumed by SpringBoardDataBridge.
enum {
    TOWXStageStart = 100,
    TOWXStageTabMiss = 110,
    TOWXStageTableMiss = 120,
    TOWXStageCount = 130,
    TOWXStageException = 190,
};

static dispatch_queue_t gTOWXLogQueue;
static NSString *gTOWXLogPath;

static void TOWXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1,2);
static void TOWXLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"%@", body);

    if (gTOWXLogQueue == nil || gTOWXLogPath.length == 0) {
        return;
    }
    NSString *line = [NSString stringWithFormat:@"%.3f %@\n", NSDate.date.timeIntervalSince1970, body];
    NSString *path = gTOWXLogPath;
    dispatch_async(gTOWXLogQueue, ^{
        NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length == 0) return;
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm fileExistsAtPath:path]) {
            [data writeToFile:path atomically:YES];
            return;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
        if (handle == nil) return;
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
        }
    });
}

static void TOWXSetupLogging(void) {
    if (gTOWXLogQueue != nil) return;
    gTOWXLogQueue = dispatch_queue_create("com.dream.towx.p2a1.wechat.log", DISPATCH_QUEUE_SERIAL);
    NSArray<NSString *> *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString *dir = caches.firstObject ?: NSTemporaryDirectory();
    gTOWXLogPath = [dir stringByAppendingPathComponent:@"TOWX-P2A1-WeChat.log"];
}

static NSArray<UIWindow *> *TOWXWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *result = [NSMutableArray array];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        [result addObjectsFromArray:((UIWindowScene *)scene).windows];
    }
    if (result.count == 0) {
        [result addObjectsFromArray:application.windows];
    }
    return result;
}

static UITabBar *TOWXFindTabBarInView(UIView *view) {
    if ([view isKindOfClass:UITabBar.class] && !view.hidden && view.alpha > 0.01) {
        return (UITabBar *)view;
    }
    for (UIView *subview in view.subviews) {
        UITabBar *found = TOWXFindTabBarInView(subview);
        if (found != nil) return found;
    }
    return nil;
}

static BOOL TOWXIsMessagesTabVisible(void) {
    for (UIWindow *window in TOWXWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        UITabBar *tabBar = TOWXFindTabBarInView(window);
        if (tabBar == nil || tabBar.items.count == 0 || tabBar.selectedItem == nil) continue;
        NSUInteger selectedIndex = [tabBar.items indexOfObject:tabBar.selectedItem];
        if (selectedIndex == 0) return YES;
    }
    return NO;
}

static void TOWXCollectTables(UIView *view, NSMutableArray<UITableView *> *tables) {
    if ([view isKindOfClass:UITableView.class] && !view.hidden && view.alpha > 0.01) {
        [tables addObject:(UITableView *)view];
    }
    for (UIView *subview in view.subviews) {
        TOWXCollectTables(subview, tables);
    }
}

static BOOL TOWXViewContainsAvatarCandidate(UIView *view) {
    if ([view isKindOfClass:UIImageView.class]) {
        UIImageView *imageView = (UIImageView *)view;
        CGFloat width = CGRectGetWidth(imageView.bounds);
        CGFloat height = CGRectGetHeight(imageView.bounds);
        if (imageView.image != nil && !imageView.hidden && imageView.alpha > 0.05 &&
            width >= 30.0 && width <= 80.0 && height >= 30.0 && height <= 80.0 &&
            fabs(width - height) <= 12.0) {
            return YES;
        }
    }
    for (UIView *subview in view.subviews) {
        if (TOWXViewContainsAvatarCandidate(subview)) return YES;
    }
    return NO;
}

static NSUInteger TOWXCandidateRowCount(UITableView *table) {
    NSUInteger count = 0;
    for (UITableViewCell *cell in table.visibleCells) {
        if (TOWXViewContainsAvatarCandidate(cell.contentView)) count++;
    }
    return count;
}

static NSUInteger TOWXBestRecentVisibleCount(void) {
    NSUInteger bestCount = 0;
    for (UIWindow *window in TOWXWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        NSMutableArray<UITableView *> *tables = [NSMutableArray array];
        TOWXCollectTables(window, tables);
        for (UITableView *table in tables) {
            if (CGRectGetHeight(table.bounds) < 180.0 || CGRectGetWidth(table.bounds) < 250.0) continue;
            NSUInteger count = TOWXCandidateRowCount(table);
            if (count > bestCount) bestCount = count;
        }
    }
    return MIN((NSUInteger)6, bestCount);
}

@interface TOWXRuntimeController : NSObject
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic) int generationToken;
@property (nonatomic) int countToken;
@property (nonatomic) int stageToken;
@property (nonatomic) uint64_t generation;
@property (nonatomic) NSInteger lastPublishedCount;
@property (nonatomic) NSInteger lastPublishedStage;
@property (nonatomic) NSUInteger tickNumber;
@end

@implementation TOWXRuntimeController

+ (instancetype)sharedController {
    static TOWXRuntimeController *controller;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ controller = [TOWXRuntimeController new]; });
    return controller;
}

- (BOOL)registerStateName:(const char *)name token:(int *)token {
    uint32_t status = notify_register_check(name, token);
    if (status != NOTIFY_STATUS_OK) {
        TOWXLog(@"TOWX|WX|P2A1|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
        return NO;
    }
    return YES;
}

- (void)publishStage:(uint64_t)stage count:(uint64_t)count force:(BOOL)force {
    if (!force && self.lastPublishedStage == (NSInteger)stage && self.lastPublishedCount == (NSInteger)count) return;
    self.generation += 1;
    uint32_t s1 = notify_set_state(self.stageToken, stage);
    uint32_t s2 = notify_set_state(self.countToken, count);
    uint32_t s3 = notify_set_state(self.generationToken, self.generation);
    if (s1 != NOTIFY_STATUS_OK || s2 != NOTIFY_STATUS_OK || s3 != NOTIFY_STATUS_OK) {
        TOWXLog(@"TOWX|WX|P2A1|STATE-WRITE-FAIL|stage=%llu|count=%llu|statuses=%u,%u,%u",
                (unsigned long long)stage, (unsigned long long)count, s1, s2, s3);
        return;
    }
    self.lastPublishedStage = (NSInteger)stage;
    self.lastPublishedCount = (NSInteger)count;
    notify_post(TOWX_P2A1_READY);
    TOWXLog(@"TOWX|WX|P2A1|PUBLISH|generation=%llu|stage=%llu|count=%llu",
            (unsigned long long)self.generation,
            (unsigned long long)stage,
            (unsigned long long)count);
}

- (void)start {
    if (self.timer != nil) return;
    TOWXSetupLogging();
    self.lastPublishedCount = -1;
    self.lastPublishedStage = -1;
    TOWXLog(@"TOWX|WX|P2A1|LOADED|v0.2.1|log=%@", gTOWXLogPath);

    if (![self registerStateName:TOWX_P2A1_GENERATION token:&_generationToken] ||
        ![self registerStateName:TOWX_P2A1_COUNT token:&_countToken] ||
        ![self registerStateName:TOWX_P2A1_STAGE token:&_stageToken]) {
        TOWXLog(@"TOWX|WX|P2A1|START-ABORT|state-registration");
        return;
    }

    [self publishStage:TOWXStageStart count:0 force:YES];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:2.0 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [self tick:self.timer];
}

- (void)tick:(NSTimer *)timer {
    (void)timer;
    self.tickNumber += 1;
    @autoreleasepool {
        @try {
            TOWXLog(@"TOWX|WX|P2A1|TICK-BEGIN|n=%lu", (unsigned long)self.tickNumber);
            if (!TOWXIsMessagesTabVisible()) {
                TOWXLog(@"TOWX|WX|P2A1|TAB-MISS|n=%lu", (unsigned long)self.tickNumber);
                [self publishStage:TOWXStageTabMiss count:0 force:NO];
                return;
            }

            NSUInteger count = TOWXBestRecentVisibleCount();
            if (count == 0) {
                TOWXLog(@"TOWX|WX|P2A1|TABLE-MISS|n=%lu", (unsigned long)self.tickNumber);
                [self publishStage:TOWXStageTableMiss count:0 force:NO];
                return;
            }

            TOWXLog(@"TOWX|WX|P2A1|SCAN-OK|n=%lu|visibleRecent=%lu",
                    (unsigned long)self.tickNumber, (unsigned long)count);
            [self publishStage:TOWXStageCount count:count force:NO];
            TOWXLog(@"TOWX|WX|P2A1|TICK-END|n=%lu", (unsigned long)self.tickNumber);
        } @catch (NSException *exception) {
            TOWXLog(@"TOWX|WX|P2A1|EXCEPTION|name=%@|reason=%@", exception.name, exception.reason);
            [self publishStage:TOWXStageException count:0 force:YES];
        }
    }
}

- (void)dealloc {
    if (_generationToken != 0) notify_cancel(_generationToken);
    if (_countToken != 0) notify_cancel(_countToken);
    if (_stageToken != 0) notify_cancel(_stageToken);
}

@end

__attribute__((constructor)) static void TOWXWeChatBackendInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[TOWXRuntimeController sharedController] performSelector:@selector(start) withObject:nil afterDelay:3.0];
    });
}
