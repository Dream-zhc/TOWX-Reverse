#import "WXIFMainFrameFix.h"
#import "WXIFSettings.h"
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const NSTimeInterval WXIFReturnWindowSeconds = 4.0;
static const CGFloat WXIFMinimumSavedDistance = 120.0;

@interface WXIFMainFrameState : NSObject
@property (nonatomic) Class targetClass;
@property (nonatomic, copy) NSString *targetClassName;
@property (nonatomic, copy) NSString *candidateSummary;
@property (nonatomic, copy) NSString *hookSummary;
@property (nonatomic, weak) UIViewController *mainController;
@property (nonatomic, weak) UITableView *mainTable;
@property (nonatomic) BOOL hasSavedOffset;
@property (nonatomic) CGFloat savedOffsetY;
@property (nonatomic) CGFloat savedTopY;
@property (nonatomic) BOOL armed;
@property (nonatomic) BOOL returnConfirmed;
@property (nonatomic) NSTimeInterval returnUntil;
@property (nonatomic) BOOL internalWrite;
@property (nonatomic) NSUInteger cycle;
@property (nonatomic) NSUInteger reloadSessionCalls;
@property (nonatomic) NSUInteger reloadDataCalls;
@property (nonatomic) NSUInteger blockedOffsetCalls;
@property (nonatomic) NSUInteger blockedScrollCalls;
@property (nonatomic) NSUInteger restoreWrites;
@property (nonatomic) NSUInteger restoreSuccesses;
@property (nonatomic, copy) NSString *lastEvent;
@end

@implementation WXIFMainFrameState
@end

static WXIFMainFrameState *WXIFState(void) {
    static WXIFMainFrameState *state;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        state = [WXIFMainFrameState new];
        state.targetClassName = @"未定位";
        state.candidateSummary = @"-";
        state.hookSummary = @"等待安装";
        state.lastEvent = @"等待定位微信主会话控制器";
    });
    return state;
}

static BOOL WXIFIsSubclassOfClass(Class cls, Class parent) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        if (current == parent) return YES;
    }
    return NO;
}

static BOOL WXIFClassHasIvarNamed(Class cls, const char *name) {
    for (Class current = cls; current != Nil; current = class_getSuperclass(current)) {
        if (class_getInstanceVariable(current, name) != NULL) return YES;
    }
    return NO;
}

static BOOL WXIFClassHasReloadSessionMethod(Class cls) {
    for (Class current = cls; current != Nil && current != UIViewController.class; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        BOOL found = NO;
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i])).lowercaseString;
            if ([name containsString:@"reloadsession"]) {
                found = YES;
                break;
            }
        }
        free(methods);
        if (found) return YES;
    }
    return NO;
}

static NSInteger WXIFScoreCandidateClass(Class cls) {
    if (!WXIFIsSubclassOfClass(cls, UIViewController.class)) return 0;
    NSString *name = NSStringFromClass(cls);
    NSString *lower = name.lowercaseString;
    NSInteger score = 0;
    if ([name isEqualToString:@"NewMainFrameViewController"]) score += 500;
    if ([lower containsString:@"mainframe"]) score += 140;
    if ([lower containsString:@"chatlist"]) score += 90;
    if ([lower containsString:@"session"]) score += 50;
    if ([lower containsString:@"conversation"]) score += 45;
    if (WXIFClassHasIvarNamed(cls, "m_tableView")) score += 140;
    if ([cls instancesRespondToSelector:NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:")]) score += 80;
    if (WXIFClassHasReloadSessionMethod(cls)) score += 120;
    return score;
}

static Class WXIFDiscoverTargetClass(void) {
    WXIFMainFrameState *state = WXIFState();
    Class exact = NSClassFromString(@"NewMainFrameViewController");
    if (exact != Nil && WXIFIsSubclassOfClass(exact, UIViewController.class)) {
        state.candidateSummary = @"NewMainFrameViewController(精确命中)";
        return exact;
    }

    int count = objc_getClassList(NULL, 0);
    if (count <= 0) return Nil;
    Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
    count = objc_getClassList(classes, count);
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    Class bestClass = Nil;
    NSInteger bestScore = 0;
    for (int i = 0; i < count; i++) {
        Class cls = classes[i];
        NSInteger score = WXIFScoreCandidateClass(cls);
        if (score < 100) continue;
        NSString *name = NSStringFromClass(cls);
        [candidates addObject:@{@"name": name, @"score": @(score)}];
        if (score > bestScore) {
            bestScore = score;
            bestClass = cls;
        }
    }
    free(classes);
    [candidates sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [b[@"score"] compare:a[@"score"]];
    }];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < MIN((NSUInteger)5, candidates.count); i++) {
        NSDictionary *item = candidates[i];
        [parts addObject:[NSString stringWithFormat:@"%@(%@)", item[@"name"], item[@"score"]]];
    }
    state.candidateSummary = parts.count ? [parts componentsJoinedByString:@", "] : @"无候选";
    return bestScore >= 180 ? bestClass : Nil;
}

static void WXIFCollectTables(UIView *view, NSMutableArray<UITableView *> *tables) {
    if ([view isKindOfClass:UITableView.class]) [tables addObject:(UITableView *)view];
    for (UIView *subview in view.subviews) WXIFCollectTables(subview, tables);
}

static UITableView *WXIFResolveMainTable(UIViewController *controller) {
    if (controller == nil) return nil;
    id value = nil;
    @try {
        value = [controller valueForKey:@"m_tableView"];
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    if ([value isKindOfClass:UITableView.class]) return value;

    if (!controller.isViewLoaded) return nil;
    NSMutableArray<UITableView *> *tables = [NSMutableArray array];
    WXIFCollectTables(controller.view, tables);
    UITableView *best = nil;
    CGFloat bestArea = 0;
    for (UITableView *table in tables) {
        CGFloat area = CGRectGetWidth(table.bounds) * CGRectGetHeight(table.bounds);
        if (area > bestArea) {
            bestArea = area;
            best = table;
        }
    }
    return best;
}

static void WXIFTrackController(id controller) {
    if (![controller isKindOfClass:UIViewController.class]) return;
    WXIFMainFrameState *state = WXIFState();
    state.mainController = controller;
    UITableView *table = WXIFResolveMainTable(controller);
    if (table != nil) state.mainTable = table;
}

static BOOL WXIFUserInteracting(UITableView *table) {
    if (table == nil) return NO;
    UIGestureRecognizerState pan = table.panGestureRecognizer.state;
    return table.dragging || table.tracking || pan == UIGestureRecognizerStateBegan || pan == UIGestureRecognizerStateChanged;
}

static CGFloat WXIFTopY(UITableView *table) {
    return -table.adjustedContentInset.top;
}

static BOOL WXIFValidTargetForTable(UITableView *table, CGFloat *targetOut) {
    WXIFMainFrameState *state = WXIFState();
    if (!state.hasSavedOffset || table == nil) return NO;
    CGFloat topY = WXIFTopY(table);
    CGFloat maxY = table.contentSize.height - CGRectGetHeight(table.bounds) + table.adjustedContentInset.bottom;
    if (maxY < topY) maxY = topY;
    CGFloat target = MIN(state.savedOffsetY, maxY);
    if (target <= topY + WXIFMinimumSavedDistance) return NO;
    if (targetOut != NULL) *targetOut = target;
    return YES;
}

static void WXIFCaptureOffset(UITableView *table, NSString *event) {
    if (table == nil) return;
    WXIFMainFrameState *state = WXIFState();
    CGFloat topY = WXIFTopY(table);
    CGFloat y = table.contentOffset.y;
    state.savedTopY = topY;
    state.hasSavedOffset = y > topY + WXIFMinimumSavedDistance;
    state.savedOffsetY = y;
    if (event.length > 0) state.lastEvent = event;
}

static BOOL WXIFReturnActive(void) {
    WXIFMainFrameState *state = WXIFState();
    return [WXIFSettings conversationPositionFixEnabled] && state.armed &&
           state.returnUntil > NSDate.date.timeIntervalSinceReferenceDate;
}

static void WXIFBeginReturnWindow(BOOL confirmed, NSString *event) {
    WXIFMainFrameState *state = WXIFState();
    if (!state.armed || !state.hasSavedOffset) return;
    state.returnUntil = NSDate.date.timeIntervalSinceReferenceDate + WXIFReturnWindowSeconds;
    if (confirmed) state.returnConfirmed = YES;
    if (event.length > 0) state.lastEvent = event;
}

static UITableView *WXIFCurrentMainTable(void) {
    WXIFMainFrameState *state = WXIFState();
    UITableView *table = state.mainTable;
    if (table != nil) return table;
    table = WXIFResolveMainTable(state.mainController);
    if (table != nil) state.mainTable = table;
    return table;
}

static void WXIFPerformRestore(NSString *reason) {
    if (!WXIFReturnActive()) return;
    WXIFMainFrameState *state = WXIFState();
    UITableView *table = WXIFCurrentMainTable();
    if (table == nil) {
        state.lastEvent = @"返回窗口已开启，但尚未解析到 m_tableView";
        return;
    }
    if (WXIFUserInteracting(table)) {
        state.armed = NO;
        state.returnUntil = 0;
        state.lastEvent = @"检测到用户手动滚动，结束本次保护";
        return;
    }
    CGFloat target = 0;
    if (!WXIFValidTargetForTable(table, &target)) {
        state.lastEvent = @"主会话表尚未完成布局，等待下一次恢复";
        return;
    }
    CGFloat current = table.contentOffset.y;
    if (fabs(current - target) <= 18.0) return;
    state.internalWrite = YES;
    [table setContentOffset:CGPointMake(table.contentOffset.x, target) animated:NO];
    state.internalWrite = NO;
    [table layoutIfNeeded];
    state.restoreWrites += 1;
    if (fabs(table.contentOffset.y - target) <= 40.0) state.restoreSuccesses += 1;
    state.lastEvent = [NSString stringWithFormat:@"%@：%.0f → %.0f", reason ?: @"恢复", current, table.contentOffset.y];
}

static void WXIFScheduleRestoreSeries(NSString *reason) {
    WXIFMainFrameState *state = WXIFState();
    NSUInteger cycle = state.cycle;
    NSArray<NSNumber *> *delays = @[@0.0, @0.01, @0.03, @0.08, @0.16, @0.30, @0.60, @1.0, @1.8, @2.8, @3.7];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (WXIFState().cycle != cycle) return;
            WXIFPerformRestore(reason);
        });
    }
}

static void WXIFScheduleFinish(NSUInteger cycle) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        WXIFMainFrameState *state = WXIFState();
        if (state.cycle != cycle || !state.returnConfirmed) return;
        NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
        if (now < state.returnUntil) {
            WXIFScheduleFinish(cycle);
            return;
        }
        UITableView *table = WXIFCurrentMainTable();
        if (table != nil) WXIFCaptureOffset(table, nil);
        state.armed = NO;
        state.returnConfirmed = NO;
        state.returnUntil = 0;
        state.lastEvent = @"返回保护窗口结束";
    });
}

static BOOL WXIFTrackedTable(UITableView *table) {
    WXIFMainFrameState *state = WXIFState();
    if (table == nil) return NO;
    if (table == state.mainTable) return YES;
    UIViewController *controller = state.mainController;
    if (controller != nil && controller.isViewLoaded && [table isDescendantOfView:controller.view]) {
        UITableView *resolved = WXIFResolveMainTable(controller);
        if (resolved == table) {
            state.mainTable = table;
            return YES;
        }
    }
    return NO;
}

static IMP WXIFSetContentOffsetOriginal = NULL;
static IMP WXIFSetContentOffsetAnimatedOriginal = NULL;
static IMP WXIFScrollToRowOriginal = NULL;
static IMP WXIFReloadDataOriginal = NULL;
static IMP WXIFDidSelectOriginal = NULL;
static IMP WXIFViewWillAppearOriginal = NULL;
static IMP WXIFViewDidAppearOriginal = NULL;
static NSMutableDictionary<NSString *, NSValue *> *WXIFReloadOriginals;

static void WXIFSetContentOffsetHook(UIScrollView *self, SEL _cmd, CGPoint point) {
    typedef void (*Fn)(id, SEL, CGPoint);
    Fn original = (Fn)WXIFSetContentOffsetOriginal;
    WXIFMainFrameState *state = WXIFState();
    if (!original) return;
    if (state.internalWrite || ![self isKindOfClass:UITableView.class] || !WXIFReturnActive() ||
        !WXIFTrackedTable((UITableView *)self) || WXIFUserInteracting((UITableView *)self)) {
        original(self, _cmd, point);
        return;
    }
    UITableView *table = (UITableView *)self;
    CGFloat target = 0;
    CGFloat topY = WXIFTopY(table);
    if (point.y <= topY + 55.0 && WXIFValidTargetForTable(table, &target)) {
        state.blockedOffsetCalls += 1;
        state.lastEvent = [NSString stringWithFormat:@"拦截 setContentOffset 顶部 %.0f → %.0f", point.y, target];
        point.y = target;
        state.internalWrite = YES;
        original(self, _cmd, point);
        state.internalWrite = NO;
        return;
    }
    original(self, _cmd, point);
}

static void WXIFSetContentOffsetAnimatedHook(UIScrollView *self, SEL _cmd, CGPoint point, BOOL animated) {
    typedef void (*Fn)(id, SEL, CGPoint, BOOL);
    Fn original = (Fn)WXIFSetContentOffsetAnimatedOriginal;
    WXIFMainFrameState *state = WXIFState();
    if (!original) return;
    if (state.internalWrite || ![self isKindOfClass:UITableView.class] || !WXIFReturnActive() ||
        !WXIFTrackedTable((UITableView *)self) || WXIFUserInteracting((UITableView *)self)) {
        original(self, _cmd, point, animated);
        return;
    }
    UITableView *table = (UITableView *)self;
    CGFloat target = 0;
    CGFloat topY = WXIFTopY(table);
    if (point.y <= topY + 55.0 && WXIFValidTargetForTable(table, &target)) {
        state.blockedOffsetCalls += 1;
        state.lastEvent = [NSString stringWithFormat:@"拦截 animated offset 顶部 %.0f → %.0f", point.y, target];
        point.y = target;
        state.internalWrite = YES;
        original(self, _cmd, point, NO);
        state.internalWrite = NO;
        return;
    }
    original(self, _cmd, point, animated);
}

static void WXIFScrollToRowHook(UITableView *self, SEL _cmd, NSIndexPath *indexPath, UITableViewScrollPosition position, BOOL animated) {
    typedef void (*Fn)(id, SEL, NSIndexPath *, UITableViewScrollPosition, BOOL);
    Fn original = (Fn)WXIFScrollToRowOriginal;
    if (!original) return;
    WXIFMainFrameState *state = WXIFState();
    BOOL topRequest = indexPath != nil && indexPath.section == 0 && indexPath.row == 0;
    if (WXIFReturnActive() && WXIFTrackedTable(self) && !WXIFUserInteracting(self) && topRequest && state.hasSavedOffset) {
        state.blockedScrollCalls += 1;
        state.lastEvent = @"拦截主会话表 scrollToRow(section=0,row=0)";
        WXIFScheduleRestoreSeries(@"scrollToRow 后恢复");
        return;
    }
    original(self, _cmd, indexPath, position, animated);
}

static void WXIFReloadDataHook(UITableView *self, SEL _cmd) {
    typedef void (*Fn)(id, SEL);
    Fn original = (Fn)WXIFReloadDataOriginal;
    if (!original) return;
    WXIFMainFrameState *state = WXIFState();
    BOOL tracked = WXIFTrackedTable(self);
    if (tracked && state.armed && state.hasSavedOffset) {
        state.reloadDataCalls += 1;
        WXIFBeginReturnWindow(NO, @"主会话表 reloadData，开启保护窗口");
    }
    original(self, _cmd);
    if (tracked && state.armed) WXIFScheduleRestoreSeries(@"reloadData 后恢复");
}

static void WXIFDidSelectHook(id self, SEL _cmd, UITableView *table, NSIndexPath *indexPath) {
    typedef void (*Fn)(id, SEL, UITableView *, NSIndexPath *);
    Fn original = (Fn)WXIFDidSelectOriginal;
    WXIFMainFrameState *state = WXIFState();
    WXIFTrackController(self);
    UITableView *mainTable = WXIFResolveMainTable(self);
    if (mainTable == nil && [table isKindOfClass:UITableView.class]) mainTable = table;
    if (mainTable != nil) {
        state.mainTable = mainTable;
        WXIFCaptureOffset(mainTable, nil);
        if (state.hasSavedOffset) {
            state.cycle += 1;
            state.armed = YES;
            state.returnConfirmed = NO;
            state.returnUntil = 0;
            state.lastEvent = [NSString stringWithFormat:@"进入聊天前保存 Y=%.0f，row=%ld", state.savedOffsetY, (long)indexPath.row];
        }
    }
    if (original) original(self, _cmd, table, indexPath);
}

static void WXIFViewWillAppearHook(id self, SEL _cmd, BOOL animated) {
    typedef void (*Fn)(id, SEL, BOOL);
    Fn original = (Fn)WXIFViewWillAppearOriginal;
    WXIFTrackController(self);
    WXIFMainFrameState *state = WXIFState();
    if (state.armed && state.hasSavedOffset) {
        WXIFBeginReturnWindow(YES, @"主会话页 viewWillAppear，提前保护返回位置");
    }
    if (original) original(self, _cmd, animated);
    WXIFTrackController(self);
    if (state.armed) WXIFScheduleRestoreSeries(@"viewWillAppear 后恢复");
}

static void WXIFViewDidAppearHook(id self, SEL _cmd, BOOL animated) {
    typedef void (*Fn)(id, SEL, BOOL);
    Fn original = (Fn)WXIFViewDidAppearOriginal;
    WXIFTrackController(self);
    WXIFMainFrameState *state = WXIFState();
    if (state.armed && state.hasSavedOffset) WXIFBeginReturnWindow(YES, @"主会话页 viewDidAppear，延长保护窗口");
    if (original) original(self, _cmd, animated);
    WXIFTrackController(self);
    if (state.armed) {
        WXIFScheduleRestoreSeries(@"viewDidAppear 后恢复");
        WXIFScheduleFinish(state.cycle);
    } else {
        UITableView *table = WXIFCurrentMainTable();
        if (table != nil) WXIFCaptureOffset(table, @"主会话页已就绪");
    }
}

static void WXIFReloadSessionHook(id self, SEL _cmd) {
    typedef void (*Fn)(id, SEL);
    WXIFMainFrameState *state = WXIFState();
    WXIFTrackController(self);
    state.reloadSessionCalls += 1;
    if (state.armed && state.hasSavedOffset) WXIFBeginReturnWindow(NO, [NSString stringWithFormat:@"%@ 调用，保护主列表", NSStringFromSelector(_cmd)]);
    Fn original = (Fn)[WXIFReloadOriginals[NSStringFromSelector(_cmd)] pointerValue];
    if (original) original(self, _cmd);
    WXIFTrackController(self);
    if (state.armed) WXIFScheduleRestoreSeries([NSString stringWithFormat:@"%@ 后恢复", NSStringFromSelector(_cmd)]);
}

static IMP WXIFInstallInstanceHook(Class cls, SEL selector, IMP replacement) {
    Method method = class_getInstanceMethod(cls, selector);
    if (method == NULL) return NULL;
    IMP original = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    if (class_addMethod(cls, selector, replacement, types)) return original;
    class_replaceMethod(cls, selector, replacement, types);
    return original;
}

static void WXIFInstallBaseTableHooks(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        WXIFSetContentOffsetOriginal = WXIFInstallInstanceHook(UIScrollView.class, @selector(setContentOffset:), (IMP)WXIFSetContentOffsetHook);
        WXIFSetContentOffsetAnimatedOriginal = WXIFInstallInstanceHook(UIScrollView.class, @selector(setContentOffset:animated:), (IMP)WXIFSetContentOffsetAnimatedHook);
        WXIFScrollToRowOriginal = WXIFInstallInstanceHook(UITableView.class, @selector(scrollToRowAtIndexPath:atScrollPosition:animated:), (IMP)WXIFScrollToRowHook);
        WXIFReloadDataOriginal = WXIFInstallInstanceHook(UITableView.class, @selector(reloadData), (IMP)WXIFReloadDataHook);
    });
}

static BOOL WXIFInstallTargetHooks(void) {
    WXIFMainFrameState *state = WXIFState();
    if (state.targetClass != Nil) return YES;
    Class target = WXIFDiscoverTargetClass();
    if (target == Nil) {
        state.targetClassName = @"未定位";
        state.hookSummary = @"未安装：等待 MainFrame/Session 候选";
        return NO;
    }
    state.targetClass = target;
    state.targetClassName = NSStringFromClass(target);

    WXIFDidSelectOriginal = WXIFInstallInstanceHook(target, NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:"), (IMP)WXIFDidSelectHook);
    WXIFViewWillAppearOriginal = WXIFInstallInstanceHook(target, @selector(viewWillAppear:), (IMP)WXIFViewWillAppearHook);
    WXIFViewDidAppearOriginal = WXIFInstallInstanceHook(target, @selector(viewDidAppear:), (IMP)WXIFViewDidAppearHook);

    WXIFReloadOriginals = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (Class current = target; current != Nil && current != UIViewController.class; current = class_getSuperclass(current)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            Method method = methods[i];
            SEL selector = method_getName(method);
            NSString *name = NSStringFromSelector(selector);
            if (![name.lowercaseString containsString:@"reloadsession"] || [seen containsObject:name]) continue;
            if (method_getNumberOfArguments(method) != 2) continue;
            const char *returnType = method_copyReturnType(method);
            BOOL isVoid = returnType != NULL && returnType[0] == 'v';
            free((void *)returnType);
            if (!isVoid) continue;
            [seen addObject:name];
            IMP original = WXIFInstallInstanceHook(target, selector, (IMP)WXIFReloadSessionHook);
            if (original != NULL) WXIFReloadOriginals[name] = [NSValue valueWithPointer:original];
        }
        free(methods);
    }
    state.hookSummary = [NSString stringWithFormat:@"已安装：didSelect=%@，reloadSession=%lu", WXIFDidSelectOriginal ? @"是" : @"否", (unsigned long)WXIFReloadOriginals.count];
    state.lastEvent = [NSString stringWithFormat:@"已锁定微信主会话控制器 %@", state.targetClassName];
    return YES;
}

@implementation WXIFMainFrameFix

+ (void)start {
    WXIFInstallBaseTableHooks();
    __block NSUInteger attempts = 0;
    __block void (^retry)(void) = nil;
    retry = ^{
        attempts += 1;
        if (WXIFInstallTargetHooks() || attempts >= 40) {
            if (WXIFState().targetClass == Nil) WXIFState().lastEvent = @"40 次运行时扫描仍未定位主会话控制器";
            retry = nil;
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), retry);
    };
    retry();
}

+ (NSDictionary<NSString *,NSString *> *)diagnosticSnapshot {
    WXIFMainFrameState *state = WXIFState();
    UITableView *table = WXIFCurrentMainTable();
    NSString *saved = state.hasSavedOffset ? [NSString stringWithFormat:@"%.0f", state.savedOffsetY] : @"无";
    NSString *current = table ? [NSString stringWithFormat:@"%.0f", table.contentOffset.y] : @"无";
    NSString *phase = @"待命";
    if (state.armed && !WXIFReturnActive()) phase = @"已保存，等待返回";
    if (WXIFReturnActive()) phase = state.returnConfirmed ? @"返回保护窗口" : @"reload 保护窗口";
    NSString *tableName = table ? NSStringFromClass(table.class) : @"-";
    NSString *ownerName = state.mainController ? NSStringFromClass(state.mainController.class) : @"-";
    return @{
        @"target": state.targetClassName ?: @"-",
        @"hooks": state.hookSummary ?: @"-",
        @"saved": saved,
        @"current": current,
        @"state": phase,
        @"reloads": [NSString stringWithFormat:@"session=%lu / table=%lu", (unsigned long)state.reloadSessionCalls, (unsigned long)state.reloadDataCalls],
        @"blockedOffsets": [NSString stringWithFormat:@"%lu", (unsigned long)state.blockedOffsetCalls],
        @"blockedScrolls": [NSString stringWithFormat:@"%lu", (unsigned long)state.blockedScrollCalls],
        @"writes": [NSString stringWithFormat:@"%lu / success %lu", (unsigned long)state.restoreWrites, (unsigned long)state.restoreSuccesses],
        @"table": tableName,
        @"owner": ownerName,
        @"candidates": state.candidateSummary ?: @"-",
        @"event": state.lastEvent ?: @"-",
    };
}

@end
