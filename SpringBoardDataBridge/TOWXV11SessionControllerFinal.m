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
static NSUInteger gBundleProbeTick = 0;
static BOOL gMethodDiagnosticsLogged = NO;

static NSArray<UIWindow *> *TOWXV11AllWindowsV2(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in app.windows ?: @[]) if (window) [set addObject:window];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) if (window) [set addObject:window];
    }
    return set.array;
}

static BOOL TOWXV11SessionUsableV2(UIWindow *window) {
    return window && !window.hidden && window.alpha > 0.01 &&
           [NSStringFromClass(window.class) isEqualToString:TOWXV11_SESSION_CLASS] &&
           CGRectGetWidth(window.bounds) > 100.0 && CGRectGetHeight(window.bounds) > 100.0;
}

static UIWindow *TOWXV11FindSessionV2(void) {
    if (TOWXV11SessionUsableV2(gSessionWindow)) return gSessionWindow;
    UIWindow *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UIWindow *window in TOWXV11AllWindowsV2()) {
        if (!TOWXV11SessionUsableV2(window)) continue;
        CGFloat score = window.windowLevel * 100000.0 + CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds);
        if (window.isKeyWindow) score += 10000000.0;
        if (!best || score > bestScore) { best = window; bestScore = score; }
    }
    return best;
}

static UIInterfaceOrientation TOWXV11OrientationV2(UIWindow *window) {
    if (window.windowScene && window.windowScene.interfaceOrientation != UIInterfaceOrientationUnknown) return window.windowScene.interfaceOrientation;
    return CGRectGetWidth(window.bounds) > CGRectGetHeight(window.bounds) ? UIInterfaceOrientationLandscapeRight : UIInterfaceOrientationPortrait;
}

static BOOL TOWXV11PlausibleBundleV2(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *v = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (v.length < 3 || v.length > 220) return NO;
    if ([v rangeOfString:@"."].location == NSNotFound || [v rangeOfString:@"/"].location != NSNotFound || [v rangeOfString:@" "].location != NSNotFound) return NO;
    if ([v isEqualToString:@"com.apple.springboard"] || [v hasPrefix:@"com.dream.towx"] || [v hasPrefix:@"com.charlieleung.trollopen"]) return NO;
    return YES;
}

static BOOL TOWXV11InstalledBundleV2(NSString *bundleID) {
    if (!TOWXV11PlausibleBundleV2(bundleID)) return NO;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![(id)proxyClass respondsToSelector:selector]) return YES;
    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, selector, bundleID);
        return proxy != nil;
    } @catch (__unused NSException *exception) { return NO; }
}

static id TOWXV11SafeGetterV2(id object, NSString *name) {
    if (!object || !name.length) return nil;
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

static id TOWXV11ObjectIvarV2(id object, const char *name) {
    if (!object || !name) return nil;
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name);
        if (!ivar) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (!type || type[0] != '@') return nil;
        @try { return object_getIvar(object, ivar); }
        @catch (__unused NSException *exception) { return nil; }
    }
    return nil;
}

static void TOWXV11AddCandidateV2(NSMutableArray *out, id value, NSInteger score, NSString *path, NSString *source) {
    if (![value isKindOfClass:[NSString class]]) return;
    NSString *bundle = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!TOWXV11InstalledBundleV2(bundle)) return;
    [out addObject:@{ @"bundle": bundle, @"score": @(score), @"path": path ?: @"?", @"source": source ?: @"?" }];
}

static void TOWXV11LogRelevantMethodsV2(id object, NSString *path) {
    if (!object || gMethodDiagnosticsLogged) return;
    NSUInteger emitted = 0;
    for (Class cls = [object class]; cls && emitted < 24; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count && emitted < 24; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            if (![lower containsString:@"bundle"] && ![lower containsString:@"application"] && ![lower containsString:@"host"] && ![lower containsString:@"scene"] && ![lower containsString:@"split"]) continue;
            TOWXV11DiagLog("SESSION", "METHOD|path=%s|class=%s|selector=%s", path.UTF8String ?: "?", NSStringFromClass(cls).UTF8String ?: "?", name.UTF8String ?: "?");
            emitted++;
        }
        free(methods);
    }
    gMethodDiagnosticsLogged = YES;
}

static NSString *TOWXV11ResolveBundleV2(UIWindow *window, NSString **sourceOut) {
    if (!window) return nil;
    static NSArray<NSDictionary *> *stringSelectors = nil;
    static NSArray<NSString *> *objectSelectors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stringSelectors = @[
            @{@"name":@"splitBundleID", @"score":@150},
            @{@"name":@"bundleID", @"score":@140},
            @{@"name":@"applicationBundleID", @"score":@135},
            @{@"name":@"bundleIdentifier", @"score":@130},
            @{@"name":@"embeddedApplicationIdentifier", @"score":@125},
            @{@"name":@"applicationIdentifier", @"score":@120},
            @{@"name":@"displayIdentifier", @"score":@90},
            @{@"name":@"swipeSelectedBundleID", @"score":@70}
        ];
        objectSelectors = @[
            @"rootViewController", @"presentedViewController", @"parentViewController", @"childViewControllers", @"children",
            @"floatingHostViewController", @"hostViewController", @"floatingWindow", @"currentVisibleFloatingWindow",
            @"application", @"targetApplication", @"clientApplication", @"scene", @"applicationScene", @"sceneHandle",
            @"applicationSceneHandle", @"owningScene", @"windowScene", @"pipSceneHandle"
        ];
    });

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray arrayWithObject:@{ @"object": window, @"path": @"window", @"depth": @0 }];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    NSUInteger cursor = 0;
    const NSUInteger maxObjects = 40;

    while (cursor < queue.count && cursor < maxObjects) {
        NSDictionary *item = queue[cursor++];
        id object = item[@"object"];
        NSString *path = item[@"path"];
        NSUInteger depth = [item[@"depth"] unsignedIntegerValue];
        if (!object) continue;

        if ([object isKindOfClass:[NSArray class]]) {
            NSUInteger idx = 0;
            for (id child in (NSArray *)object) {
                if (idx >= 10 || queue.count >= maxObjects) break;
                [queue addObject:@{ @"object": child, @"path": [path stringByAppendingFormat:@"[%lu]", (unsigned long)idx], @"depth": @(depth) }];
                idx++;
            }
            continue;
        }

        NSValue *pointer = [NSValue valueWithPointer:(__bridge const void *)(object)];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];

        for (NSDictionary *descriptor in stringSelectors) {
            NSString *name = descriptor[@"name"];
            TOWXV11AddCandidateV2(candidates, TOWXV11SafeGetterV2(object, name), [descriptor[@"score"] integerValue], path, name);
        }
        TOWXV11AddCandidateV2(candidates, TOWXV11ObjectIvarV2(object, "_bundleID"), 145, path, @"ivar:_bundleID");
        TOWXV11AddCandidateV2(candidates, TOWXV11ObjectIvarV2(object, "_applicationBundleID"), 136, path, @"ivar:_applicationBundleID");

        if (depth >= 3) continue;
        for (NSString *name in objectSelectors) {
            if (queue.count >= maxObjects) break;
            id child = TOWXV11SafeGetterV2(object, name);
            if (!child || child == object) continue;
            [queue addObject:@{ @"object": child, @"path": [path stringByAppendingFormat:@".%@", name], @"depth": @(depth + 1) }];
        }
    }

    NSDictionary *best = nil;
    for (NSDictionary *candidate in candidates) {
        if (!best || [candidate[@"score"] integerValue] > [best[@"score"] integerValue]) best = candidate;
    }
    if (!best) {
        if (sourceOut) *sourceOut = @"unresolved";
        TOWXV11DiagLog("SESSION", "BUNDLE|bundle=?|source=unresolved|objects=%lu|windowClass=%s|rootClass=%s",
                       (unsigned long)visited.count,
                       NSStringFromClass(window.class).UTF8String ?: "?",
                       NSStringFromClass(window.rootViewController.class).UTF8String ?: "?");
        TOWXV11LogRelevantMethodsV2(window, @"window");
        return nil;
    }

    NSString *bundle = best[@"bundle"];
    NSString *source = [NSString stringWithFormat:@"%@:%@", best[@"path"] ?: @"?", best[@"source"] ?: @"?"];
    if (sourceOut) *sourceOut = source;
    TOWXV11DiagLog("SESSION", "BUNDLE|bundle=%s|source=%s|score=%ld|objects=%lu",
                   bundle.UTF8String ?: "?", source.UTF8String ?: "?", (long)[best[@"score"] integerValue], (unsigned long)visited.count);
    return bundle;
}

UIWindow *TOWXV11CurrentSessionWindow(void) { return gSessionWindow; }
NSString *TOWXV11CurrentSessionBundleIdentifier(void) { return gSessionBundleID; }
uint64_t TOWXV11CurrentSessionEpoch(void) { return gSessionEpoch; }
BOOL TOWXV11SessionIsVisible(void) { return gSessionVisible && TOWXV11SessionUsableV2(gSessionWindow); }
BOOL TOWXV11SessionIsWeChat(void) { return [gSessionBundleID isEqualToString:TOWXV11_WECHAT_BUNDLE]; }
UIInterfaceOrientation TOWXV11CurrentSessionOrientation(void) { return gSessionOrientation; }

static void TOWXV11PublishV2(NSNotificationName name, UIWindow *window) {
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

    UIWindow *window = TOWXV11FindSessionV2();
    UIWindow *previous = gSessionWindow;
    if (!window) {
        if (gSessionVisible || previous) {
            TOWXV11DiagLog("SESSION", "END|epoch=%llu|reason=%s|window=%p|bundle=%s", (unsigned long long)gSessionEpoch, reason ?: "?", previous, gSessionBundleID.UTF8String ?: "?");
            gSessionVisible = NO; gSessionWindow = nil; gSessionBundleID = nil; gSessionOrientation = UIInterfaceOrientationUnknown;
            TOWXV11PublishV2(TOWXV11SessionDidEndNotification, previous);
        }
        return;
    }

    BOOL newSession = previous != window || !gSessionVisible;
    if (newSession) {
        gSessionWindow = window; gSessionVisible = YES; gSessionEpoch += 1; gBundleProbeTick = 0; gMethodDiagnosticsLogged = NO;
        gSessionOrientation = TOWXV11OrientationV2(window);
        NSString *source = nil;
        gSessionBundleID = [TOWXV11ResolveBundleV2(window, &source) copy];
        TOWXV11DiagLog("SESSION", "BEGIN|epoch=%llu|reason=%s|window=%p|class=%s|level=%.1f|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                       (unsigned long long)gSessionEpoch, reason ?: "?", window, NSStringFromClass(window.class).UTF8String ?: "?", window.windowLevel,
                       window.frame.origin.x, window.frame.origin.y, window.frame.size.width, window.frame.size.height);
        TOWXV11DiagLog("SESSION", "ORIENTATION|epoch=%llu|value=%ld", (unsigned long long)gSessionEpoch, (long)gSessionOrientation);
        TOWXV11PublishV2(TOWXV11SessionDidBeginNotification, window);
        return;
    }

    BOOL changed = NO;
    UIInterfaceOrientation orientation = TOWXV11OrientationV2(window);
    if (orientation != gSessionOrientation) {
        gSessionOrientation = orientation; changed = YES;
        TOWXV11DiagLog("SESSION", "ORIENTATION|epoch=%llu|value=%ld|reason=%s", (unsigned long long)gSessionEpoch, (long)orientation, reason ?: "?");
    }

    BOOL watchdog = reason && strcmp(reason, "watchdog") == 0;
    gBundleProbeTick += 1;
    BOOL probeBundle = !watchdog || !gSessionBundleID.length || (gBundleProbeTick % 2U) == 0U;
    if (probeBundle) {
        NSString *source = nil;
        NSString *bundle = TOWXV11ResolveBundleV2(window, &source);
        BOOL bundleChanged = (bundle.length || gSessionBundleID.length) && ![(bundle ?: @"") isEqualToString:(gSessionBundleID ?: @"")];
        if (bundleChanged) {
            NSString *old = gSessionBundleID ?: @"";
            gSessionBundleID = [bundle copy];
            changed = YES;
            TOWXV11DiagLog("SESSION", "BUNDLE-CHANGE|epoch=%llu|old=%s|new=%s|source=%s|reason=%s",
                           (unsigned long long)gSessionEpoch,
                           old.length ? old.UTF8String : "?",
                           gSessionBundleID.length ? gSessionBundleID.UTF8String : "?",
                           source.UTF8String ?: "?", reason ?: "?");
        }
    }

    if (changed) TOWXV11PublishV2(TOWXV11SessionDidChangeNotification, window);
}

static void TOWXV11InstallSessionObserversV2(void) {
    NSNotificationCenter *c = NSNotificationCenter.defaultCenter;
    [c addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("window-visible"); }];
    [c addObserverForName:UIWindowDidBecomeHiddenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("window-hidden"); }];
    [c addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("scene-active"); }];
    [c addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) { TOWXV11RefreshSession("scene-deactivate"); }];
}

static void TOWXV11StartSessionWatchdogV2(void) {
    gSessionWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gSessionWatchdog, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(gSessionWatchdog, ^{ TOWXV11RefreshSession("watchdog"); });
    dispatch_resume(gSessionWatchdog);
}

__attribute__((constructor)) static void TOWXV11SessionControllerV2Init(void) {
    TOWXV11DiagLog("SESSION", "LOADED|Smooth1-FINAL2|bundle-bfs+splitBundleID+bundle-change-detect+2s-watchdog");
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXV11InstallSessionObserversV2();
        TOWXV11RefreshSession("constructor");
        TOWXV11StartSessionWatchdogV2();
    });
}
