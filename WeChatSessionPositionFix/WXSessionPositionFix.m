#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

#define WXPOSFIX_VERSION @"0.1.0"

@interface WXPositionState : NSObject
@property(nonatomic) BOOL valid;
@property(nonatomic) BOOL restoreActive;
@property(nonatomic) BOOL returnPending;
@property(nonatomic) CGPoint rawOffset;
@property(nonatomic) CGFloat savedContentHeight;
@property(nonatomic) CGFloat anchorDelta;
@property(nonatomic, strong) NSIndexPath *anchorIndexPath;
@property(nonatomic, copy) NSString *anchorUserName;
@property(nonatomic) NSUInteger generation;
@property(nonatomic) NSUInteger restoreTicket;
@property(nonatomic) NSUInteger restoreWrites;
@property(nonatomic) NSUInteger successfulRestores;
@end

@implementation WXPositionState
@end

static WXPositionState *gState;
static NSMutableArray<NSString *> *gLogs;
static __weak UIViewController *gMainVC;

static IMP gOrigMainViewDidLoad;
static IMP gOrigMainViewWillAppear;
static IMP gOrigMainViewDidAppear;
static IMP gOrigMainViewWillDisappear;
static IMP gOrigMainDidSelect;
static IMP gOrigMainReloadSessions;
static IMP gOrigMainResetTableViewOffset;
static IMP gOrigMainScrollWillBeginDragging;

static IMP gOrigChatViewDidLoad;
static IMP gOrigChatViewDidAppear;
static IMP gOrigChatViewWillDisappear;
static IMP gOrigChatViewDidDisappear;

static NSString *WXNowString(void) {
    static NSDateFormatter *formatter;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return [formatter stringFromDate:[NSDate date]];
}

static void WXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void WXLog(NSString *format, ...) {
    if (!format) return;

    va_list args;
    va_start(args, format);
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSString *line = [NSString stringWithFormat:@"[%@] %@", WXNowString(), body ?: @""];
    @synchronized (gLogs) {
        if (!gLogs) gLogs = [NSMutableArray array];
        [gLogs addObject:line];
        while (gLogs.count > 240) {
            [gLogs removeObjectAtIndex:0];
        }
    }
    NSLog(@"[WXPosFix] %@", body);
}

static NSString *WXStateSummary(void) {
    WXPositionState *s = gState;
    NSString *anchor = s.anchorIndexPath
        ? [NSString stringWithFormat:@"%ld/%ld",
           (long)s.anchorIndexPath.section, (long)s.anchorIndexPath.row]
        : @"-";
    return [NSString stringWithFormat:
            @"version=%@\nvalid=%@\nrestoreActive=%@\nreturnPending=%@\n"
            @"savedOffset=%.2f\nsavedContentHeight=%.2f\n"
            @"anchor=%@\nanchorUser=%@\nanchorDelta=%.2f\n"
            @"generation=%lu\nrestoreWrites=%lu\nsuccessfulRestores=%lu",
            WXPOSFIX_VERSION,
            s.valid ? @"YES" : @"NO",
            s.restoreActive ? @"YES" : @"NO",
            s.returnPending ? @"YES" : @"NO",
            s.rawOffset.y,
            s.savedContentHeight,
            anchor,
            s.anchorUserName ?: @"-",
            s.anchorDelta,
            (unsigned long)s.generation,
            (unsigned long)s.restoreWrites,
            (unsigned long)s.successfulRestores];
}

static NSString *WXFullLog(void) {
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    NSString *appVersion = info[@"CFBundleShortVersionString"] ?: @"?";
    NSString *build = info[@"CFBundleVersion"] ?: @"?";
    NSString *system = UIDevice.currentDevice.systemVersion ?: @"?";
    NSString *device = UIDevice.currentDevice.model ?: @"?";

    NSArray<NSString *> *lines;
    @synchronized (gLogs) {
        lines = [gLogs copy] ?: @[];
    }

    return [NSString stringWithFormat:
            @"WX Session Position Fix %@\n"
            @"app=%@ (%@)\n"
            @"system=%@ device=%@\n"
            @"mainVC=%@\n\n"
            @"STATE\n%@\n\n"
            @"EVENTS\n%@",
            WXPOSFIX_VERSION,
            appVersion,
            build,
            system,
            device,
            gMainVC ? NSStringFromClass(gMainVC.class) : @"-",
            WXStateSummary(),
            [lines componentsJoinedByString:@"\n"]];
}

static UIViewController *WXTopController(void) {
    UIWindow *window = nil;

    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:UIWindowScene.class]) continue;

            UIWindowScene *windowScene = (UIWindowScene *)scene;
            for (UIWindow *candidate in windowScene.windows) {
                if (candidate.isKeyWindow) {
                    window = candidate;
                    break;
                }
                if (!window && !candidate.hidden && candidate.alpha > 0.01) {
                    window = candidate;
                }
            }
            if (window.isKeyWindow) break;
        }
    }

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (!window) window = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop

    UIViewController *vc = window.rootViewController;
    for (NSUInteger i = 0; i < 20 && vc; i++) {
        UIViewController *next = nil;

        if (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
            next = vc.presentedViewController;
        } else if ([vc isKindOfClass:UINavigationController.class]) {
            next = ((UINavigationController *)vc).visibleViewController;
        } else if ([vc isKindOfClass:UITabBarController.class]) {
            next = ((UITabBarController *)vc).selectedViewController;
        } else if ([vc isKindOfClass:UISplitViewController.class]) {
            next = ((UISplitViewController *)vc).viewControllers.lastObject;
        }

        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

static void WXPresentLog(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = WXTopController();
        if (!top) return;

        NSString *full = WXFullLog();
        NSString *preview = full;
        if (preview.length > 9000) {
            preview = [preview substringFromIndex:preview.length - 9000];
            preview = [@"…\n" stringByAppendingString:preview];
        }

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:
                [NSString stringWithFormat:@"WX Position Fix %@", WXPOSFIX_VERSION]
                                            message:preview
                                     preferredStyle:UIAlertControllerStyleAlert];

        [alert addAction:[UIAlertAction actionWithTitle:@"复制全部"
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = full;
            WXLog(@"LOG copied length=%lu", (unsigned long)full.length);
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"清空"
                                                  style:UIAlertActionStyleDestructive
                                                handler:^(__unused UIAlertAction *action) {
            @synchronized (gLogs) {
                [gLogs removeAllObjects];
            }
            WXLog(@"LOG cleared");
        }]];

        [alert addAction:[UIAlertAction actionWithTitle:@"关闭"
                                                  style:UIAlertActionStyleCancel
                                                handler:nil]];

        [top presentViewController:alert animated:YES completion:nil];
    });
}

@interface WXLogGestureTarget : NSObject
+ (instancetype)shared;
- (void)handle:(UILongPressGestureRecognizer *)gesture;
@end

@implementation WXLogGestureTarget
+ (instancetype)shared {
    static WXLogGestureTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        target = [WXLogGestureTarget new];
    });
    return target;
}

- (void)handle:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) {
        WXLog(@"GESTURE open log source=%@", NSStringFromClass(gesture.view.class));
        WXPresentLog();
    }
}
@end

static char kWXLogGestureKey;

static void WXInstallLogGesture(UIViewController *vc) {
    if (!vc || !vc.isViewLoaded || !vc.view) return;
    if (objc_getAssociatedObject(vc, &kWXLogGestureKey)) return;

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc] initWithTarget:WXLogGestureTarget.shared
                                                     action:@selector(handle:)];
    gesture.minimumPressDuration = 0.8;
    gesture.numberOfTouchesRequired = 2;
    gesture.cancelsTouchesInView = NO;
    gesture.delaysTouchesBegan = NO;
    gesture.delaysTouchesEnded = NO;

    [vc.view addGestureRecognizer:gesture];
    objc_setAssociatedObject(vc, &kWXLogGestureKey, gesture,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    WXLog(@"GESTURE installed vc=%@", NSStringFromClass(vc.class));
}

static id WXSendId(id obj, SEL sel) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(obj, sel);
}

static id WXSendId1(id obj, SEL sel, id arg) {
    if (!obj || !sel || ![obj respondsToSelector:sel]) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(obj, sel, arg);
}

static UITableView *WXFindTableInView(UIView *view, NSUInteger depth) {
    if (!view || depth > 10) return nil;

    if ([view isKindOfClass:UITableView.class]) {
        NSString *name = NSStringFromClass(view.class);
        if ([name containsString:@"MainFrame"] || [name containsString:@"Session"]) {
            return (UITableView *)view;
        }
    }

    for (UIView *subview in view.subviews) {
        UITableView *table = WXFindTableInView(subview, depth + 1);
        if (table) return table;
    }
    return nil;
}

static UITableView *WXMainTable(id vc) {
    if (!vc) return nil;

    SEL getter = NSSelectorFromString(@"m_tableView");
    id value = WXSendId(vc, getter);
    if ([value isKindOfClass:UITableView.class]) {
        return value;
    }

    @try {
        value = [vc valueForKey:@"m_tableView"];
        if ([value isKindOfClass:UITableView.class]) {
            return value;
        }
    } @catch (__unused NSException *exception) {
    }

    if ([vc isKindOfClass:UIViewController.class]) {
        UIViewController *controller = (UIViewController *)vc;
        if (controller.isViewLoaded) {
            return WXFindTableInView(controller.view, 0);
        }
    }
    return nil;
}

static NSString *WXSessionUserName(id session) {
    if (!session) return nil;

    NSArray<NSString *> *selectors = @[
        @"m_nsUserName",
        @"userName",
        @"username",
        @"sessionUserName",
        @"getContactUserName"
    ];

    for (NSString *name in selectors) {
        id value = WXSendId(session, NSSelectorFromString(name));
        if ([value isKindOfClass:NSString.class] && ((NSString *)value).length > 0) {
            return value;
        }
    }
    return nil;
}

static NSIndexPath *WXTopVisibleIndexPath(UITableView *table) {
    NSArray<NSIndexPath *> *visible = table.indexPathsForVisibleRows;
    if (visible.count == 0) return nil;

    NSIndexPath *best = nil;
    CGFloat bestY = CGFLOAT_MAX;
    for (NSIndexPath *path in visible) {
        CGRect rect = [table rectForRowAtIndexPath:path];
        if (CGRectGetMinY(rect) < bestY) {
            bestY = CGRectGetMinY(rect);
            best = path;
        }
    }
    return best;
}

static BOOL WXIndexPathValid(UITableView *table, NSIndexPath *path) {
    if (!table || !path) return NO;
    NSInteger sections = table.numberOfSections;
    if (path.section >= sections) return NO;
    NSInteger rows = [table numberOfRowsInSection:path.section];
    return path.row < rows;
}

static NSIndexPath *WXCurrentAnchorPath(id vc, UITableView *table) {
    WXPositionState *s = gState;

    if (s.anchorUserName.length > 0) {
        SEL lookup = NSSelectorFromString(@"indexPathOfSessionUserName:");
        id value = WXSendId1(vc, lookup, s.anchorUserName);
        if ([value isKindOfClass:NSIndexPath.class] && WXIndexPathValid(table, value)) {
            return value;
        }
    }

    if (WXIndexPathValid(table, s.anchorIndexPath)) {
        return s.anchorIndexPath;
    }
    return nil;
}

static void WXCapture(id vc, NSString *reason) {
    if (!vc) return;

    UITableView *table = WXMainTable(vc);
    if (!table) {
        WXLog(@"CAPTURE skip reason=%@ table=nil vc=%@",
              reason, NSStringFromClass([vc class]));
        return;
    }

    NSIndexPath *anchor = WXTopVisibleIndexPath(table);
    NSString *userName = nil;
    CGFloat delta = 0.0;

    if (anchor) {
        SEL sessionSel = NSSelectorFromString(@"logicGetSessionAtIndexPath:");
        id session = WXSendId1(vc, sessionSel, anchor);
        userName = WXSessionUserName(session);

        CGRect rect = [table rectForRowAtIndexPath:anchor];
        delta = CGRectGetMinY(rect) - table.contentOffset.y;
    }

    gState.rawOffset = table.contentOffset;
    gState.savedContentHeight = table.contentSize.height;
    gState.anchorIndexPath = anchor;
    gState.anchorUserName = userName;
    gState.anchorDelta = delta;
    gState.valid = YES;
    gState.restoreActive = NO;
    gState.returnPending = YES;
    gState.generation += 1;
    gState.restoreTicket += 1;

    WXLog(@"CAPTURE reason=%@ table=%@ y=%.2f contentH=%.2f anchor=%@ user=%@ delta=%.2f",
          reason,
          NSStringFromClass(table.class),
          table.contentOffset.y,
          table.contentSize.height,
          anchor ? [NSString stringWithFormat:@"%ld/%ld",
                    (long)anchor.section, (long)anchor.row] : @"-",
          userName ?: @"-",
          delta);
}

static CGFloat WXClampOffsetY(UITableView *table, CGFloat y) {
    UIEdgeInsets inset = table.adjustedContentInset;
    CGFloat minY = -inset.top;
    CGFloat maxY = MAX(minY, table.contentSize.height - table.bounds.size.height + inset.bottom);
    return MIN(MAX(y, minY), maxY);
}

static BOOL WXRestoreOnce(id vc, NSString *reason, NSUInteger pass) {
    if (!vc || !gState.valid || !gState.restoreActive) return NO;

    UITableView *table = WXMainTable(vc);
    if (!table) {
        WXLog(@"RESTORE pass=%lu reason=%@ skip table=nil",
              (unsigned long)pass, reason);
        return NO;
    }

    if (table.dragging || table.decelerating || table.tracking) {
        gState.restoreActive = NO;
        gState.returnPending = NO;
        gState.restoreTicket += 1;
        WXLog(@"RESTORE cancel pass=%lu reason=%@ user-interacting y=%.2f",
              (unsigned long)pass, reason, table.contentOffset.y);
        return NO;
    }

    [table layoutIfNeeded];

    CGFloat beforeY = table.contentOffset.y;
    CGFloat targetY = gState.rawOffset.y;
    NSIndexPath *targetPath = WXCurrentAnchorPath(vc, table);
    NSString *targetSource = @"raw";

    if (targetPath) {
        CGRect rect = [table rectForRowAtIndexPath:targetPath];
        if (!CGRectIsNull(rect) && !CGRectIsInfinite(rect)) {
            targetY = CGRectGetMinY(rect) - gState.anchorDelta;
            targetSource = gState.anchorUserName.length > 0 ? @"username" : @"indexPath";
        }
    }

    targetY = WXClampOffsetY(table, targetY);
    CGFloat diff = fabs(beforeY - targetY);

    if (diff > 0.5) {
        [UIView performWithoutAnimation:^{
            [table setContentOffset:CGPointMake(table.contentOffset.x, targetY) animated:NO];
            [table layoutIfNeeded];
        }];
        gState.restoreWrites += 1;
    }

    CGFloat afterY = table.contentOffset.y;
    BOOL success = fabs(afterY - targetY) <= 1.5;
    if (success) {
        gState.successfulRestores += 1;
    }

    WXLog(@"RESTORE pass=%lu reason=%@ source=%@ path=%@ before=%.2f target=%.2f after=%.2f diff=%.2f contentH=%.2f success=%@",
          (unsigned long)pass,
          reason,
          targetSource,
          targetPath ? [NSString stringWithFormat:@"%ld/%ld",
                        (long)targetPath.section, (long)targetPath.row] : @"-",
          beforeY,
          targetY,
          afterY,
          diff,
          table.contentSize.height,
          success ? @"YES" : @"NO");

    return success;
}

static void WXBeginRestore(id vc, NSString *reason) {
    if (!vc || !gState.valid || !gState.returnPending) {
        WXLog(@"RESTORE begin skip reason=%@ valid=%@ vc=%@",
              reason,
              gState.valid ? @"YES" : @"NO",
              vc ? NSStringFromClass([vc class]) : @"nil");
        return;
    }

    gState.restoreActive = YES;
    gState.restoreTicket += 1;

    NSUInteger ticket = gState.restoreTicket;
    NSUInteger generation = gState.generation;
    __weak id weakVC = vc;

    WXLog(@"RESTORE begin reason=%@ ticket=%lu generation=%lu savedY=%.2f user=%@",
          reason,
          (unsigned long)ticket,
          (unsigned long)generation,
          gState.rawOffset.y,
          gState.anchorUserName ?: @"-");

    const NSTimeInterval delays[] = {0.0, 0.03, 0.08, 0.16, 0.32, 0.55, 0.90};
    const NSUInteger count = sizeof(delays) / sizeof(delays[0]);

    for (NSUInteger i = 0; i < count; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                     (int64_t)(delays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (ticket != gState.restoreTicket) return;
            if (generation != gState.generation) return;
            if (!gState.restoreActive) return;

            id strongVC = weakVC;
            if (!strongVC) return;
            WXRestoreOnce(strongVC, reason, i + 1);
        });
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (ticket != gState.restoreTicket) return;
        if (generation != gState.generation) return;
        gState.restoreActive = NO;
        gState.returnPending = NO;
        UITableView *finalTable = WXMainTable(weakVC);
        CGFloat finalY = finalTable ? finalTable.contentOffset.y : 0.0;
        WXLog(@"RESTORE end reason=%@ ticket=%lu finalY=%.2f",
              reason,
              (unsigned long)ticket,
              finalY);
    });
}

static BOOL WXInstallMethodHook(Class cls, SEL sel, IMP replacement, IMP *originalOut) {
    if (!cls || !sel || !replacement || !originalOut) return NO;

    Method inheritedOrOwn = class_getInstanceMethod(cls, sel);
    if (!inheritedOrOwn) {
        WXLog(@"HOOK missing class=%@ sel=%@",
              NSStringFromClass(cls), NSStringFromSelector(sel));
        return NO;
    }

    IMP original = method_getImplementation(inheritedOrOwn);
    const char *types = method_getTypeEncoding(inheritedOrOwn);
    *originalOut = original;

    if (class_addMethod(cls, sel, replacement, types)) {
        WXLog(@"HOOK add override class=%@ sel=%@",
              NSStringFromClass(cls), NSStringFromSelector(sel));
        return YES;
    }

    Method own = class_getInstanceMethod(cls, sel);
    if (!own) return NO;

    method_setImplementation(own, replacement);
    WXLog(@"HOOK replace class=%@ sel=%@",
          NSStringFromClass(cls), NSStringFromSelector(sel));
    return YES;
}

static void WXMain_viewDidLoad(id self, SEL _cmd) {
    ((void (*)(id, SEL))gOrigMainViewDidLoad)(self, _cmd);

    if ([self isKindOfClass:UIViewController.class]) {
        gMainVC = self;
        WXInstallLogGesture((UIViewController *)self);
    }

    UITableView *table = WXMainTable(self);
    WXLog(@"MAIN viewDidLoad vc=%@ table=%@ y=%.2f",
          NSStringFromClass([self class]),
          table ? NSStringFromClass(table.class) : @"nil",
          table ? table.contentOffset.y : 0.0);
}

static void WXMain_viewWillAppear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gOrigMainViewWillAppear)(self, _cmd, animated);
    gMainVC = self;
    if ([self isKindOfClass:UIViewController.class]) {
        WXInstallLogGesture((UIViewController *)self);
    }
    WXLog(@"MAIN viewWillAppear animated=%@", animated ? @"YES" : @"NO");
    WXBeginRestore(self, @"main.viewWillAppear");
}

static void WXMain_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gOrigMainViewDidAppear)(self, _cmd, animated);
    gMainVC = self;
    WXLog(@"MAIN viewDidAppear animated=%@", animated ? @"YES" : @"NO");
    WXBeginRestore(self, @"main.viewDidAppear");
}

static void WXMain_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    WXCapture(self, @"main.viewWillDisappear");
    WXLog(@"MAIN viewWillDisappear animated=%@", animated ? @"YES" : @"NO");
    ((void (*)(id, SEL, BOOL))gOrigMainViewWillDisappear)(self, _cmd, animated);
}

static void WXMain_didSelect(id self, SEL _cmd, id tableView, id indexPath) {
    WXCapture(self, @"main.didSelect");
    WXLog(@"MAIN didSelect path=%@ table=%@",
          indexPath,
          tableView ? NSStringFromClass([tableView class]) : @"nil");

    ((void (*)(id, SEL, id, id))gOrigMainDidSelect)(self, _cmd, tableView, indexPath);
}

static void WXMain_reloadSessions(id self, SEL _cmd) {
    UITableView *table = WXMainTable(self);
    CGFloat before = table ? table.contentOffset.y : 0.0;
    WXLog(@"MAIN reloadSessions before=%.2f active=%@",
          before, gState.restoreActive ? @"YES" : @"NO");

    ((void (*)(id, SEL))gOrigMainReloadSessions)(self, _cmd);

    table = WXMainTable(self);
    WXLog(@"MAIN reloadSessions after=%.2f",
          table ? table.contentOffset.y : 0.0);

    if (gState.returnPending || gState.restoreActive) {
        WXBeginRestore(self, @"main.reloadSessions");
    }
}

static void WXMain_resetTableViewOffset(id self, SEL _cmd, id arg) {
    UITableView *table = WXMainTable(self);
    CGFloat before = table ? table.contentOffset.y : 0.0;
    WXLog(@"MAIN resetTableViewOffset before=%.2f arg=%@", before, arg);

    ((void (*)(id, SEL, id))gOrigMainResetTableViewOffset)(self, _cmd, arg);

    table = WXMainTable(self);
    WXLog(@"MAIN resetTableViewOffset after=%.2f",
          table ? table.contentOffset.y : 0.0);

    if (gState.returnPending || gState.restoreActive) {
        WXBeginRestore(self, @"main.resetTableViewOffset");
    }
}

static void WXMain_scrollWillBeginDragging(id self, SEL _cmd, id scrollView) {
    gState.restoreActive = NO;
    gState.returnPending = NO;
    gState.restoreTicket += 1;

    WXLog(@"MAIN userDrag cancel restore y=%.2f",
          [scrollView respondsToSelector:@selector(contentOffset)]
              ? ((UIScrollView *)scrollView).contentOffset.y
              : 0.0);

    ((void (*)(id, SEL, id))gOrigMainScrollWillBeginDragging)(self, _cmd, scrollView);
}

static void WXChat_viewDidLoad(id self, SEL _cmd) {
    ((void (*)(id, SEL))gOrigChatViewDidLoad)(self, _cmd);

    if ([self isKindOfClass:UIViewController.class]) {
        WXInstallLogGesture((UIViewController *)self);
    }
    WXLog(@"CHAT viewDidLoad vc=%@", NSStringFromClass([self class]));
}

static void WXChat_viewDidAppear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gOrigChatViewDidAppear)(self, _cmd, animated);

    if ([self isKindOfClass:UIViewController.class]) {
        WXInstallLogGesture((UIViewController *)self);
    }

    if (!gState.returnPending && gMainVC) {
        WXCapture(gMainVC, @"chat.viewDidAppear.backfill");
    }

    WXLog(@"CHAT viewDidAppear vc=%@ animated=%@ savedValid=%@ savedY=%.2f",
          NSStringFromClass([self class]),
          animated ? @"YES" : @"NO",
          gState.valid ? @"YES" : @"NO",
          gState.rawOffset.y);
}

static void WXChat_viewWillDisappear(id self, SEL _cmd, BOOL animated) {
    WXLog(@"CHAT viewWillDisappear vc=%@ animated=%@ -> request restore",
          NSStringFromClass([self class]),
          animated ? @"YES" : @"NO");

    ((void (*)(id, SEL, BOOL))gOrigChatViewWillDisappear)(self, _cmd, animated);

    UIViewController *main = gMainVC;
    if (main) {
        WXBeginRestore(main, @"chat.viewWillDisappear");
    }
}

static void WXChat_viewDidDisappear(id self, SEL _cmd, BOOL animated) {
    ((void (*)(id, SEL, BOOL))gOrigChatViewDidDisappear)(self, _cmd, animated);

    WXLog(@"CHAT viewDidDisappear vc=%@ animated=%@ -> request restore",
          NSStringFromClass([self class]),
          animated ? @"YES" : @"NO");

    UIViewController *main = gMainVC;
    if (main) {
        WXBeginRestore(main, @"chat.viewDidDisappear");
    }
}

static BOOL gMainHooksInstalled = NO;
static BOOL gChatHooksInstalled = NO;

static void WXInstallMainHooks(void) {
    if (gMainHooksInstalled) return;

    Class cls = NSClassFromString(@"NewMainFrameViewController");
    if (!cls) {
        WXLog(@"HOOK wait NewMainFrameViewController missing");
        return;
    }

    BOOL ok = YES;
    ok &= WXInstallMethodHook(cls, @selector(viewDidLoad),
                              (IMP)WXMain_viewDidLoad, &gOrigMainViewDidLoad);
    ok &= WXInstallMethodHook(cls, @selector(viewWillAppear:),
                              (IMP)WXMain_viewWillAppear, &gOrigMainViewWillAppear);
    ok &= WXInstallMethodHook(cls, @selector(viewDidAppear:),
                              (IMP)WXMain_viewDidAppear, &gOrigMainViewDidAppear);
    ok &= WXInstallMethodHook(cls, @selector(viewWillDisappear:),
                              (IMP)WXMain_viewWillDisappear, &gOrigMainViewWillDisappear);

    SEL selectSel = NSSelectorFromString(@"tableView:didSelectRowAtIndexPath:");
    ok &= WXInstallMethodHook(cls, selectSel,
                              (IMP)WXMain_didSelect, &gOrigMainDidSelect);

    SEL reloadSel = NSSelectorFromString(@"reloadSessions");
    if (class_getInstanceMethod(cls, reloadSel)) {
        WXInstallMethodHook(cls, reloadSel,
                            (IMP)WXMain_reloadSessions, &gOrigMainReloadSessions);
    } else {
        WXLog(@"HOOK optional missing class=%@ sel=reloadSessions",
              NSStringFromClass(cls));
    }

    SEL resetSel = NSSelectorFromString(@"resetTableViewOffset:");
    if (class_getInstanceMethod(cls, resetSel)) {
        WXInstallMethodHook(cls, resetSel,
                            (IMP)WXMain_resetTableViewOffset,
                            &gOrigMainResetTableViewOffset);
    } else {
        WXLog(@"HOOK optional missing class=%@ sel=resetTableViewOffset:",
              NSStringFromClass(cls));
    }

    SEL dragSel = NSSelectorFromString(@"scrollViewWillBeginDragging:");
    if (class_getInstanceMethod(cls, dragSel)) {
        WXInstallMethodHook(cls, dragSel,
                            (IMP)WXMain_scrollWillBeginDragging,
                            &gOrigMainScrollWillBeginDragging);
    } else {
        WXLog(@"HOOK optional missing class=%@ sel=scrollViewWillBeginDragging:",
              NSStringFromClass(cls));
    }

    gMainHooksInstalled = YES;
    WXLog(@"HOOK main installed status=%@", ok ? @"FULL" : @"PARTIAL");
}

static void WXInstallChatHooks(void) {
    if (gChatHooksInstalled) return;

    NSArray<NSString *> *candidates = @[
        @"BaseMsgContentViewController",
        @"MMBaseMsgContentViewController"
    ];

    Class cls = Nil;
    for (NSString *name in candidates) {
        cls = NSClassFromString(name);
        if (cls) break;
    }

    if (!cls) {
        WXLog(@"HOOK wait chat controller missing candidates=%@", candidates);
        return;
    }

    BOOL ok = YES;
    ok &= WXInstallMethodHook(cls, @selector(viewDidLoad),
                              (IMP)WXChat_viewDidLoad, &gOrigChatViewDidLoad);
    ok &= WXInstallMethodHook(cls, @selector(viewDidAppear:),
                              (IMP)WXChat_viewDidAppear, &gOrigChatViewDidAppear);
    ok &= WXInstallMethodHook(cls, @selector(viewWillDisappear:),
                              (IMP)WXChat_viewWillDisappear, &gOrigChatViewWillDisappear);
    ok &= WXInstallMethodHook(cls, @selector(viewDidDisappear:),
                              (IMP)WXChat_viewDidDisappear, &gOrigChatViewDidDisappear);

    gChatHooksInstalled = YES;
    WXLog(@"HOOK chat class=%@ installed status=%@",
          NSStringFromClass(cls), ok ? @"FULL" : @"PARTIAL");
}

static void WXInstallHooksAttempt(NSUInteger attempt) {
    WXInstallMainHooks();
    WXInstallChatHooks();

    if (gMainHooksInstalled && gChatHooksInstalled) {
        WXLog(@"HOOK ready attempt=%lu", (unsigned long)attempt);
        return;
    }

    if (attempt >= 20) {
        WXLog(@"HOOK stop retries main=%@ chat=%@",
              gMainHooksInstalled ? @"YES" : @"NO",
              gChatHooksInstalled ? @"YES" : @"NO");
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        WXInstallHooksAttempt(attempt + 1);
    });
}

__attribute__((constructor))
static void WXSessionPositionFixInit(void) {
    @autoreleasepool {
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bundleID isEqualToString:@"com.tencent.xin"]) {
            return;
        }

        gState = [WXPositionState new];
        gLogs = [NSMutableArray array];

        WXLog(@"LOAD version=%@ bundle=%@ app=%@ system=%@",
              WXPOSFIX_VERSION,
              bundleID,
              NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"?",
              UIDevice.currentDevice.systemVersion ?: @"?");

        dispatch_async(dispatch_get_main_queue(), ^{
            WXInstallHooksAttempt(1);
        });
    }
}
