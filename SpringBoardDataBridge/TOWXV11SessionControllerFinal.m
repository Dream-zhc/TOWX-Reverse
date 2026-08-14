#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

#import <objc/message.h>
#import <objc/runtime.h>

#define TOWXV11_SESSION_CLASS @"TOJBClass022"
#define TOWXV11_WECHAT_BUNDLE @"com.tencent.xin"

NSNotificationName const TOWXV11SessionDidBeginNotification = @"com.dream.towx.v11.session.begin";
NSNotificationName const TOWXV11SessionDidEndNotification = @"com.dream.towx.v11.session.end";
NSNotificationName const TOWXV11SessionDidChangeNotification = @"com.dream.towx.v11.session.change";

static __weak UIWindow *gSessionWindow = nil;
static NSString *gSessionBundleID = nil;
static uint64_t gSessionEpoch = 0;
static BOOL gSessionVisible = NO;
static UIInterfaceOrientation gSessionOrientation = UIInterfaceOrientationUnknown;
static dispatch_source_t gSessionWatchdog = nil;
static NSUInteger gUnresolvedWatchdogTicks = 0;
static BOOL gVerboseProbeLogged = NO;

static NSArray<UIWindow *> *TOWXV11AllWindowsFinal(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in app.windows ?: @[]) if (window) [set addObject:window];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) if (window) [set addObject:window];
    }
    return set.array;
}

static BOOL TOWXV11UsableSessionWindow(UIWindow *window) {
    return window && !window.hidden && window.alpha > 0.01 &&
           [NSStringFromClass(window.class) isEqualToString:TOWXV11_SESSION_CLASS] &&
           CGRectGetWidth(window.bounds) > 100.0 && CGRectGetHeight(window.bounds) > 100.0;
}

static UIWindow *TOWXV11FindSessionFinal(void) {
    if (TOWXV11UsableSessionWindow(gSessionWindow)) return gSessionWindow;
    UIWindow *best = nil;
    CGFloat score = -CGFLOAT_MAX;
    for (UIWindow *window in TOWXV11AllWindowsFinal()) {
        if (!TOWXV11UsableSessionWindow(window)) continue;
        CGFloat candidate = window.windowLevel * 100000.0 + CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds);
        if (candidate > score) { best = window; score = candidate; }
    }
    return best;
}

static UIInterfaceOrientation TOWXV11OrientationFinal(UIWindow *window) {
    if (window.windowScene && window.windowScene.interfaceOrientation != UIInterfaceOrientationUnknown) return window.windowScene.interfaceOrientation;
    return CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds) ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
}

static BOOL TOWXV11PlausibleBundle(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    if (value.length < 3 || value.length > 220) return NO;
    if ([value rangeOfString:@"."].location == NSNotFound || [value rangeOfString:@"/"].location != NSNotFound || [value rangeOfString:@" "].location != NSNotFound) return NO;
    if ([value isEqualToString:@"com.apple.springboard"] || [value hasPrefix:@"com.dream.towx"] || [value hasPrefix:@"com.charlieleung.trollopen"]) return NO;
    return YES;
}

static BOOL TOWXV11InstalledBundle(NSString *bundleID) {
    if (!TOWXV11PlausibleBundle(bundleID)) return NO;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![(id)proxyClass respondsToSelector:selector]) return YES;
    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, selector, bundleID);
        return proxy != nil;
    } @catch (__unused NSException *exception) { return NO; }
}

static id TOWXV11Getter(id object, NSString *name) {
    if (!object) return nil;
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return nil;
    const char *type = signature.methodReturnType;
    while (type && strchr("rnNoORV", *type)) type++;
    if (!type || (*type != '@' && *type != '#')) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id TOWXV11ObjectIvarFinal(id object, const char *name) {
    if (!object) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (ivar) {
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') return object_getIvar(object, ivar);
            return nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static void TOWXV11AddCandidate(NSMutableArray *candidates, id value, NSInteger score, NSString *source) {
    if (![value isKindOfClass:[NSString class]]) return;
    NSString *bundle = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!TOWXV11InstalledBundle(bundle)) return;
    [candidates addObject:@{ @"bundle": bundle, @"score": @(score), @"source": source ?: @"?" }];
}

static void TOWXV11ProbeFocusedObject(id object, NSString *path, NSMutableArray *candidates) {
    if (!object) return;
    NSArray *selectors = @[@"bundleID", @"applicationBundleID", @"bundleIdentifier", @"embeddedApplicationIdentifier", @"applicationIdentifier", @"displayIdentifier"];
    NSInteger score = 120;
    for (NSString *name in selectors) {
        TOWXV11AddCandidate(candidates, TOWXV11Getter(object, name), score--, [path stringByAppendingFormat:@".%@", name]);
    }
    TOWXV11AddCandidate(candidates, TOWXV11ObjectIvarFinal(object, "_bundleID"), 119, [path stringByAppendingString:@"._bundleID"]);
    TOWXV11AddCandidate(candidates, TOWXV11ObjectIvarFinal(object, "_applicationBundleID"), 118, [path stringByAppendingString:@"._applicationBundleID"]);
}

static void TOWXV11LogRelevantMethodsOnce(id object, NSString *path) {
    if (!object || gVerboseProbeLogged) return;
    NSUInteger emitted = 0;
    Class cls = [object class];
    while (cls && emitted < 20) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count && emitted < 20; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"bundle"] || [lower containsString:@"application"] || [lower containsString:@"host"] || [lower containsString:@"scene"]) {
                TOWXV11DiagLog("SESSION", "METHOD|path=%s|class=%s|selector=%s", path.UTF8String ?: "?", NSStringFromClass(cls).UTF8String ?: "?", name.UTF8String ?: "?");
                emitted++;
            }
        }
        free(methods);
        cls = class_getSuperclass(cls);
    }
}

static NSString *TOWXV11ResolveBundleFinal(UIWindow *window) {
    NSMutableArray *candidates = [NSMutableArray array];
    NSMutableArray *objects = [NSMutableArray array];
    if (window) [objects addObject:@[window, @"window"]];
    if (window.rootViewController) [objects addObject:@[window.rootViewController, @"root"]];

    NSArray *bridgeSelectors = @[@"floatingHostViewController", @"hostViewController", @"floatingWindow", @"currentVisibleFloatingWindow", @"application", @"targetApplication", @"clientApplication", @"presentedViewController"];
    NSArray *roots = [objects copy];
    for (NSArray *pair in roots) {
        id object = pair[0];
        NSString *path = pair[1];
        for (NSString *selector in bridgeSelectors) {
            id child = TOWXV11Getter(object, selector);
            if (child && child != object) [objects addObject:@[child, [path stringByAppendingFormat:@".%@", selector]]];
        }
    }

    NSUInteger limit = MIN(objects.count, (NSUInteger)18);
    for (NSUInteger i = 0; i < limit; i++) {
        NSArray *pair = objects[i];
        TOWXV11ProbeFocusedObject(pair[0], pair[1], candidates);
    }

    NSDictionary *best = nil;
    for (NSDictionary *candidate in candidates) if (!best || [candidate[@"score"] integerValue] > [best[@"score"] integerValue]) best = candidate;
    if (best) {
        TOWXV11DiagLog("SESSION", "BUNDLE|bundle=%s|source=%s|score=%ld", [best[@"bundle"] UTF8String] ?: "?", [best[@"source"] UTF8String] ?: "?", (long)[best[@"score"] integerValue]);
        return best[@"bundle"];
    }

    TOWXV11DiagLog("SESSION", "BUNDLE|bundle=?|source=unresolved|windowClass=%s|rootClass=%s", NSStringFromClass(window.class).UTF8String ?: "?", NSStringFromClass(window.rootViewController.class).UTF8String ?: "?");
    TOWXV11LogRelevantMethodsOnce(window, @"window");
    TOWXV11LogRelevantMethodsOnce(window.rootViewController, @"root");
    gVerboseProbeLogged = YES;
    return nil;
}

UIWindow *TOWXV11CurrentSessionWindow(void) { return gSessionWindow; }
NSString *TOWXV11CurrentSessionBundleIdentifier(void) { return gSessionBundleID; }
uint64_t TOWXV11CurrentSessionEpoch(void) { return gSessionEpoch; }
BOOL TOWXV11SessionIsVisible(void) { return gSessionVisible && TOWXV11UsableSessionWindow(gSessionWindow); }
BOOL TOWXV11SessionIsWeChat(void) { return [gSessionBundleID isEqualToString:TOWXV11_WECHAT_BUNDLE]; }
UIInterfaceOrientation TOWXV11CurrentSessionOrientation(void) { return gSessionOrientation; }

static void TOWXV11Publish(NSNotificationName name, UIWindow *window) {
    [[NSNotificationCenter defaultCenter] postNotificationName:name object:window userInfo:@{
        @"epoch": @(gSessionEpoch), @"visible": @(gSessionVisible), @"bundleID": gSessionBundleID ?: @"", @"orientation": @(gSessionOrientation)
    }];
}

void TOWXV11RefreshSession(const char *reason) {
    if (!NSThread.isMainThread) {
        NSString *r = reason ? [NSString stringWithUTF8String:reason] : @"async";
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11RefreshSession(r.UTF8String); });
        return;
    }

    UIWindow *window = TOWXV11FindSessionFinal();
    UIWindow *previous = gSessionWindow;
    if (!window) {
        if (gSessionVisible || previous) {
            TOWXV11DiagLog("SESSION", "END|epoch=%llu|reason=%s|window=%p|bundle=%s", (unsigned long long)gSessionEpoch, reason ?: "?", previous, gSessionBundleID.UTF8String ?: "?");
            gSessionVisible = NO; gSessionWindow = nil; gSessionBundleID = nil; gSessionOrientation = UIInterfaceOrientationUnknown;
            TOWXV11Publish(TOWXV11SessionDidEndNotification, previous);
        }
        return;
    }

    BOOL newSession = previous != window || !gSessionVisible;
    if (newSession) {
        gSessionWindow = window; gSessionVisible = YES; gSessionEpoch += 1;
        gSessionOrientation = TOWXV11OrientationFinal(window);
        gUnresolvedWatchdogTicks = 0; gVerboseProbeLogged = NO;
        gSessionBundleID = [TOWXV11ResolveBundleFinal(window) copy];
        TOWXV11DiagLog("SESSION", "BEGIN|epoch=%llu|reason=%s|window=%p|class=%s|level=%.1f|frame={{%.1f,%.1f},{%.1f,%.1f}}", (unsigned long long)gSessionEpoch, reason ?: "?", window, NSStringFromClass(window.class).UTF8String ?: "?", window.windowLevel, window.frame.origin.x, window.frame.origin.y, window.frame.size.width, window.frame.size.height);
        TOWXV11DiagLog("SESSION", "ORIENTATION|epoch=%llu|value=%ld", (unsigned long long)gSessionEpoch, (long)gSessionOrientation);
        TOWXV11Publish(TOWXV11SessionDidBeginNotification, window);
        return;
    }

    BOOL changed = NO;
    UIInterfaceOrientation orientation = TOWXV11OrientationFinal(window);
    if (orientation != gSessionOrientation) {
        gSessionOrientation = orientation; changed = YES;
        TOWXV11DiagLog("SESSION", "ORIENTATION|epoch=%llu|value=%ld|reason=%s", (unsigned long long)gSessionEpoch, (long)orientation, reason ?: "?");
    }

    if (!gSessionBundleID.length) {
        BOOL allowRetry = !(reason && strcmp(reason, "watchdog") == 0);
        if (!allowRetry) { gUnresolvedWatchdogTicks += 1; allowRetry = (gUnresolvedWatchdogTicks % 3U) == 0U; }
        if (allowRetry) {
            NSString *bundle = TOWXV11ResolveBundleFinal(window);
            if (bundle.length) { gSessionBundleID = [bundle copy]; changed = YES; }
        }
    }
    if (changed) TOWXV11Publish(TOWXV11SessionDidChangeNotification, window);
}

static void TOWXV11InstallSessionObserversFinal(void) {
    NSNotificationCenter *c = NSNotificationCenter.defaultCenter;
    [c addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("window-visible"); }];
    [c addObserverForName:UIWindowDidBecomeHiddenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("window-hidden"); }];
    [c addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("scene-active"); }];
    [c addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("scene-deactivate"); }];
}

static void TOWXV11StartSessionWatchdogFinal(void) {
    gSessionWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gSessionWatchdog, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(gSessionWatchdog, ^{ TOWXV11RefreshSession("watchdog"); });
    dispatch_resume(gSessionWatchdog);
}

__attribute__((constructor)) static void TOWXV11SessionControllerFinalInit(void) {
    TOWXV11DiagLog("SESSION", "LOADED|Smooth1-FINAL|focused-bundle-probe+2s-watchdog");
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXV11InstallSessionObserversFinal();
        TOWXV11RefreshSession("constructor");
        TOWXV11StartSessionWatchdogFinal();
    });
}
