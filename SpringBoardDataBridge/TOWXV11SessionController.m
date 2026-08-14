#import "TOWXV11SessionController.h"

#import <objc/message.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define TOWXV11_SESSION_CLASS @"TOJBClass022"
#define TOWXV11_WECHAT_BUNDLE @"com.tencent.xin"

NSNotificationName const TOWXV11SessionDidBeginNotification = @"com.dream.towx.v11.session.begin";
NSNotificationName const TOWXV11SessionDidEndNotification = @"com.dream.towx.v11.session.end";
NSNotificationName const TOWXV11SessionDidChangeNotification = @"com.dream.towx.v11.session.change";

static const char *kTOWXV11LogDir = "/var/mobile/TrollOpenJB";
static const char *kTOWXV11LogPath = "/var/mobile/TrollOpenJB/phase2a4-product.log";

static __weak UIWindow *gTOWXV11SessionWindow = nil;
static NSString *gTOWXV11SessionBundleID = nil;
static uint64_t gTOWXV11SessionEpoch = 0;
static BOOL gTOWXV11SessionVisible = NO;
static UIInterfaceOrientation gTOWXV11SessionOrientation = UIInterfaceOrientationUnknown;
static dispatch_source_t gTOWXV11SessionWatchdog = nil;
static NSUInteger gTOWXV11ProbeLines = 0;

static void TOWXV11EnsureLogDir(void) {
    (void)mkdir(kTOWXV11LogDir, 0755);
}

static void TOWXV11Log(const char *fmt, ...) {
    TOWXV11EnsureLogDir();
    int fd = open(kTOWXV11LogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    char body[1400];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(body, sizeof(body), fmt, args);
    va_end(args);
    if (n >= 0) {
        char line[1600];
        int m = snprintf(line, sizeof(line), "%lld %s\n", (long long)time(NULL), body);
        if (m > 0) {
            size_t length = MIN((size_t)m, sizeof(line));
            (void)write(fd, line, length);
        }
    }
    close(fd);
}

static NSArray<UIWindow *> *TOWXV11AllWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in app.windows ?: @[]) {
        if (window) [set addObject:window];
    }
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) {
            if (window) [set addObject:window];
        }
    }
    return set.array;
}

static BOOL TOWXV11SessionWindowUsable(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;
    if (![NSStringFromClass(window.class) isEqualToString:TOWXV11_SESSION_CLASS]) return NO;
    return CGRectGetWidth(window.bounds) > 100.0 && CGRectGetHeight(window.bounds) > 100.0;
}

static UIWindow *TOWXV11FindSessionWindow(void) {
    UIWindow *current = gTOWXV11SessionWindow;
    if (TOWXV11SessionWindowUsable(current)) return current;

    UIWindow *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;
    for (UIWindow *window in TOWXV11AllWindows()) {
        if (!TOWXV11SessionWindowUsable(window)) continue;
        CGFloat area = CGRectGetWidth(window.bounds) * CGRectGetHeight(window.bounds);
        CGFloat score = window.windowLevel * 100000.0 + area;
        if (window.isKeyWindow) score += 10000000.0;
        if (!best || score > bestScore) {
            best = window;
            bestScore = score;
        }
    }
    return best;
}

static UIInterfaceOrientation TOWXV11OrientationForWindow(UIWindow *window) {
    if (!window) return UIInterfaceOrientationUnknown;
    UIWindowScene *scene = window.windowScene;
    if (scene && scene.interfaceOrientation != UIInterfaceOrientationUnknown) {
        return scene.interfaceOrientation;
    }
    CGSize size = window.bounds.size;
    if (size.width > size.height) return UIInterfaceOrientationLandscapeRight;
    if (size.height > 0.0) return UIInterfaceOrientationPortrait;
    return UIInterfaceOrientationUnknown;
}

static BOOL TOWXV11LooksLikeBundleID(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *candidate = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (candidate.length < 3 || candidate.length > 220) return NO;
    if ([candidate rangeOfString:@"."].location == NSNotFound) return NO;
    if ([candidate rangeOfString:@"/"].location != NSNotFound) return NO;
    if ([candidate rangeOfString:@" "].location != NSNotFound) return NO;
    if ([candidate caseInsensitiveCompare:@"com.apple.springboard"] == NSOrderedSame) return NO;
    if ([candidate hasPrefix:@"com.dream.towx"]) return NO;
    if ([candidate hasPrefix:@"com.charlieleung.trollopen"]) return NO;
    return YES;
}

static BOOL TOWXV11BundleIsInstalled(NSString *bundleID) {
    if (!TOWXV11LooksLikeBundleID(bundleID)) return NO;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![(id)proxyClass respondsToSelector:selector]) {
        /* Diagnostic fallback: keep a plausible identifier if LaunchServices is unavailable. */
        return YES;
    }
    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, selector, bundleID);
        return proxy != nil;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id TOWXV11SafeObjectGetter(id object, NSString *selectorName) {
    if (!object || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;

    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return nil;
    const char *returnType = signature.methodReturnType;
    if (!returnType) return nil;
    while (*returnType == 'r' || *returnType == 'n' || *returnType == 'N' ||
           *returnType == 'o' || *returnType == 'O' || *returnType == 'R' || *returnType == 'V') {
        returnType++;
    }
    if (*returnType != '@' && *returnType != '#') return nil;

    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (NSException *exception) {
        if (gTOWXV11ProbeLines < 80) {
            gTOWXV11ProbeLines++;
            TOWXV11Log("TOWX|V11|SESSION|PROBE-EXCEPTION|class=%s|selector=%s|name=%s",
                       NSStringFromClass([object class]).UTF8String ?: "?",
                       selectorName.UTF8String ?: "?",
                       exception.name.UTF8String ?: "?");
        }
        return nil;
    }
}

static id TOWXV11ObjectIvar(id object, NSString *ivarName) {
    if (!object || ivarName.length == 0) return nil;
    Class cls = object_getClass(object);
    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, ivarName.UTF8String);
        if (ivar) {
            const char *type = ivar_getTypeEncoding(ivar);
            if (type && type[0] == '@') {
                @try {
                    return object_getIvar(object, ivar);
                } @catch (__unused NSException *exception) {
                    return nil;
                }
            }
            return nil;
        }
        cls = class_getSuperclass(cls);
    }
    return nil;
}

static void TOWXV11AddBundleCandidate(NSMutableArray<NSDictionary *> *candidates,
                                     NSString *value,
                                     NSInteger score,
                                     NSString *source,
                                     NSString *objectPath,
                                     NSString *className) {
    if (![value isKindOfClass:[NSString class]]) return;
    NSString *bundleID = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL installed = TOWXV11BundleIsInstalled(bundleID);

    if (gTOWXV11ProbeLines < 80) {
        gTOWXV11ProbeLines++;
        TOWXV11Log("TOWX|V11|SESSION|PROBE|path=%s|class=%s|source=%s|value=%s|installed=%d|score=%ld",
                   objectPath.UTF8String ?: "?",
                   className.UTF8String ?: "?",
                   source.UTF8String ?: "?",
                   bundleID.UTF8String ?: "?",
                   installed ? 1 : 0,
                   (long)score);
    }

    if (!installed) return;
    [candidates addObject:@{
        @"bundle": bundleID,
        @"score": @(score),
        @"source": source ?: @"?",
        @"path": objectPath ?: @"?",
        @"class": className ?: @"?"
    }];
}

static void TOWXV11ProbeObject(id object,
                               NSString *path,
                               NSUInteger depth,
                               NSMutableSet<NSValue *> *visited,
                               NSMutableArray<NSDictionary *> *candidates) {
    if (!object || depth > 4) return;

    if ([object isKindOfClass:[NSArray class]]) {
        NSUInteger index = 0;
        for (id value in (NSArray *)object) {
            if (index >= 12) break;
            TOWXV11ProbeObject(value,
                               [path stringByAppendingFormat:@"[%lu]", (unsigned long)index],
                               depth + 1,
                               visited,
                               candidates);
            index++;
        }
        return;
    }

    NSValue *pointer = [NSValue valueWithPointer:(__bridge const void *)(object)];
    if ([visited containsObject:pointer]) return;
    [visited addObject:pointer];

    NSString *className = NSStringFromClass([object class]) ?: @"?";

    static NSArray<NSDictionary *> *stringSelectors = nil;
    static NSArray<NSDictionary *> *objectSelectors = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stringSelectors = @[
            @{@"name": @"bundleID", @"score": @120},
            @{@"name": @"applicationBundleID", @"score": @118},
            @{@"name": @"bundleIdentifier", @"score": @116},
            @{@"name": @"embeddedApplicationIdentifier", @"score": @114},
            @{@"name": @"applicationIdentifier", @"score": @112},
            @{@"name": @"displayIdentifier", @"score": @92}
        ];
        objectSelectors = @[
            @{@"name": @"rootViewController"},
            @{@"name": @"presentedViewController"},
            @{@"name": @"parentViewController"},
            @{@"name": @"childViewControllers"},
            @{@"name": @"children"},
            @{@"name": @"floatingHostViewController"},
            @{@"name": @"hostViewController"},
            @{@"name": @"floatingWindow"},
            @{@"name": @"currentVisibleFloatingWindow"},
            @{@"name": @"application"},
            @{@"name": @"targetApplication"},
            @{@"name": @"clientApplication"},
            @{@"name": @"scene"},
            @{@"name": @"applicationScene"},
            @{@"name": @"sceneHandle"},
            @{@"name": @"applicationSceneHandle"},
            @{@"name": @"owningScene"},
            @{@"name": @"windowScene"}
        ];
    });

    for (NSDictionary *descriptor in stringSelectors) {
        NSString *selectorName = descriptor[@"name"];
        id value = TOWXV11SafeObjectGetter(object, selectorName);
        if ([value isKindOfClass:[NSString class]]) {
            TOWXV11AddBundleCandidate(candidates,
                                     value,
                                     [descriptor[@"score"] integerValue],
                                     selectorName,
                                     path,
                                     className);
        }
    }

    /* TrollOpen 1.4.0 contains an NSString _bundleID ivar in its private classes. */
    id rawBundle = TOWXV11ObjectIvar(object, @"_bundleID");
    if ([rawBundle isKindOfClass:[NSString class]]) {
        TOWXV11AddBundleCandidate(candidates, rawBundle, 119, @"ivar:_bundleID", path, className);
    }

    if (depth == 4) return;
    for (NSDictionary *descriptor in objectSelectors) {
        NSString *selectorName = descriptor[@"name"];
        id child = TOWXV11SafeObjectGetter(object, selectorName);
        if (!child || child == object) continue;
        NSString *childPath = [path stringByAppendingFormat:@".%@", selectorName];
        TOWXV11ProbeObject(child, childPath, depth + 1, visited, candidates);
    }
}

static void TOWXV11LogRelevantMethods(id object, NSString *path) {
    if (!object) return;
    NSUInteger emitted = 0;
    Class cls = [object class];
    while (cls && emitted < 24) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count && emitted < 24; i++) {
            SEL selector = method_getName(methods[i]);
            NSString *name = NSStringFromSelector(selector);
            NSString *lower = name.lowercaseString;
            BOOL relevant = [lower containsString:@"bundle"] ||
                            [lower containsString:@"application"] ||
                            [lower containsString:@"scene"] ||
                            [lower containsString:@"host"];
            if (!relevant) continue;
            TOWXV11Log("TOWX|V11|SESSION|METHOD|path=%s|class=%s|selector=%s",
                       path.UTF8String ?: "?",
                       NSStringFromClass(cls).UTF8String ?: "?",
                       name.UTF8String ?: "?");
            emitted++;
        }
        free(methods);
        cls = class_getSuperclass(cls);
    }
}

static NSString *TOWXV11ResolveBundleIdentifier(UIWindow *window, NSString **sourceOut) {
    if (!window) return nil;
    gTOWXV11ProbeLines = 0;

    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    TOWXV11ProbeObject(window, @"sessionWindow", 0, visited, candidates);

    NSDictionary *best = nil;
    for (NSDictionary *candidate in candidates) {
        if (!best || [candidate[@"score"] integerValue] > [best[@"score"] integerValue]) {
            best = candidate;
        }
    }

    if (!best) {
        TOWXV11Log("TOWX|V11|SESSION|BUNDLE|bundle=?|source=unresolved|windowClass=%s|rootClass=%s",
                   NSStringFromClass(window.class).UTF8String ?: "?",
                   NSStringFromClass(window.rootViewController.class).UTF8String ?: "?");
        TOWXV11LogRelevantMethods(window, @"sessionWindow");
        TOWXV11LogRelevantMethods(window.rootViewController, @"sessionWindow.rootViewController");
        if (sourceOut) *sourceOut = @"unresolved";
        return nil;
    }

    NSString *bundleID = best[@"bundle"];
    NSString *source = [NSString stringWithFormat:@"%@:%@:%@",
                        best[@"path"] ?: @"?",
                        best[@"class"] ?: @"?",
                        best[@"source"] ?: @"?"];
    if (sourceOut) *sourceOut = source;
    TOWXV11Log("TOWX|V11|SESSION|BUNDLE|bundle=%s|source=%s|score=%ld",
               bundleID.UTF8String ?: "?",
               source.UTF8String ?: "?",
               (long)[best[@"score"] integerValue]);
    return bundleID;
}

UIWindow *TOWXV11CurrentSessionWindow(void) {
    return gTOWXV11SessionWindow;
}

NSString *TOWXV11CurrentSessionBundleIdentifier(void) {
    return gTOWXV11SessionBundleID;
}

uint64_t TOWXV11CurrentSessionEpoch(void) {
    return gTOWXV11SessionEpoch;
}

BOOL TOWXV11SessionIsVisible(void) {
    return gTOWXV11SessionVisible && TOWXV11SessionWindowUsable(gTOWXV11SessionWindow);
}

BOOL TOWXV11SessionIsWeChat(void) {
    return [gTOWXV11SessionBundleID isEqualToString:TOWXV11_WECHAT_BUNDLE];
}

UIInterfaceOrientation TOWXV11CurrentSessionOrientation(void) {
    return gTOWXV11SessionOrientation;
}

static void TOWXV11PublishChange(NSNotificationName notificationName, UIWindow *window) {
    [[NSNotificationCenter defaultCenter] postNotificationName:notificationName
                                                        object:window
                                                      userInfo:@{
        @"epoch": @(gTOWXV11SessionEpoch),
        @"visible": @(gTOWXV11SessionVisible),
        @"bundleID": gTOWXV11SessionBundleID ?: @"",
        @"orientation": @(gTOWXV11SessionOrientation)
    }];
}

void TOWXV11RefreshSession(const char *reason) {
    if (![NSThread isMainThread]) {
        NSString *reasonString = reason ? [NSString stringWithUTF8String:reason] : @"async";
        dispatch_async(dispatch_get_main_queue(), ^{
            TOWXV11RefreshSession(reasonString.UTF8String);
        });
        return;
    }

    UIWindow *window = TOWXV11FindSessionWindow();
    UIWindow *previous = gTOWXV11SessionWindow;

    if (!window) {
        if (gTOWXV11SessionVisible || previous) {
            TOWXV11Log("TOWX|V11|SESSION|END|epoch=%llu|reason=%s|window=%p|bundle=%s",
                       (unsigned long long)gTOWXV11SessionEpoch,
                       reason ?: "unknown",
                       previous,
                       gTOWXV11SessionBundleID.UTF8String ?: "?");
            gTOWXV11SessionVisible = NO;
            gTOWXV11SessionWindow = nil;
            gTOWXV11SessionBundleID = nil;
            gTOWXV11SessionOrientation = UIInterfaceOrientationUnknown;
            TOWXV11PublishChange(TOWXV11SessionDidEndNotification, previous);
        }
        return;
    }

    BOOL newSession = previous != window || !gTOWXV11SessionVisible;
    if (newSession) {
        gTOWXV11SessionWindow = window;
        gTOWXV11SessionVisible = YES;
        gTOWXV11SessionEpoch += 1;
        gTOWXV11SessionOrientation = TOWXV11OrientationForWindow(window);
        NSString *source = nil;
        gTOWXV11SessionBundleID = [TOWXV11ResolveBundleIdentifier(window, &source) copy];

        TOWXV11Log("TOWX|V11|SESSION|BEGIN|epoch=%llu|reason=%s|window=%p|class=%s|level=%.1f|bounds={{%.1f,%.1f},{%.1f,%.1f}}",
                   (unsigned long long)gTOWXV11SessionEpoch,
                   reason ?: "unknown",
                   window,
                   NSStringFromClass(window.class).UTF8String ?: "?",
                   window.windowLevel,
                   window.bounds.origin.x,
                   window.bounds.origin.y,
                   window.bounds.size.width,
                   window.bounds.size.height);
        TOWXV11Log("TOWX|V11|SESSION|ORIENTATION|epoch=%llu|value=%ld",
                   (unsigned long long)gTOWXV11SessionEpoch,
                   (long)gTOWXV11SessionOrientation);
        TOWXV11Log("TOWX|V11|SESSION|GATE|epoch=%llu|showCandidate=%d|reason=%s|bundle=%s",
                   (unsigned long long)gTOWXV11SessionEpoch,
                   (gTOWXV11SessionBundleID.length > 0 && !TOWXV11SessionIsWeChat()) ? 1 : 0,
                   TOWXV11SessionIsWeChat() ? "session-is-wechat" : (gTOWXV11SessionBundleID.length ? "non-wechat-session" : "bundle-unresolved"),
                   gTOWXV11SessionBundleID.UTF8String ?: "?");
        TOWXV11PublishChange(TOWXV11SessionDidBeginNotification, window);
        return;
    }

    BOOL changed = NO;
    UIInterfaceOrientation orientation = TOWXV11OrientationForWindow(window);
    if (orientation != gTOWXV11SessionOrientation) {
        gTOWXV11SessionOrientation = orientation;
        changed = YES;
        TOWXV11Log("TOWX|V11|SESSION|ORIENTATION|epoch=%llu|value=%ld|reason=%s",
                   (unsigned long long)gTOWXV11SessionEpoch,
                   (long)orientation,
                   reason ?: "unknown");
    }

    /* Retry unresolved bundle IDs on lifecycle/watchdog events, but keep this off hot UI paths. */
    if (gTOWXV11SessionBundleID.length == 0) {
        NSString *source = nil;
        NSString *bundleID = TOWXV11ResolveBundleIdentifier(window, &source);
        if (bundleID.length > 0) {
            gTOWXV11SessionBundleID = [bundleID copy];
            changed = YES;
            TOWXV11Log("TOWX|V11|SESSION|GATE|epoch=%llu|showCandidate=%d|reason=%s|bundle=%s",
                       (unsigned long long)gTOWXV11SessionEpoch,
                       TOWXV11SessionIsWeChat() ? 0 : 1,
                       TOWXV11SessionIsWeChat() ? "session-is-wechat" : "non-wechat-session",
                       gTOWXV11SessionBundleID.UTF8String ?: "?");
        }
    }

    if (changed) TOWXV11PublishChange(TOWXV11SessionDidChangeNotification, window);
}

static void TOWXV11InstallObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIWindowDidBecomeVisibleNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshSession("window-visible");
    }];
    [center addObserverForName:UIWindowDidBecomeHiddenNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshSession("window-hidden");
    }];
    [center addObserverForName:UISceneDidActivateNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshSession("scene-active");
    }];
    [center addObserverForName:UISceneWillDeactivateNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshSession("scene-deactivate");
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXV11RefreshSession("app-active");
    }];
}

static void TOWXV11StartWatchdog(void) {
    if (gTOWXV11SessionWatchdog) return;
    gTOWXV11SessionWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTOWXV11SessionWatchdog) return;
    dispatch_source_set_timer(gTOWXV11SessionWatchdog,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC,
                              NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(gTOWXV11SessionWatchdog, ^{
        TOWXV11RefreshSession("watchdog");
    });
    dispatch_resume(gTOWXV11SessionWatchdog);
}

__attribute__((constructor)) static void TOWXV11SessionControllerInit(void) {
    TOWXV11Log("TOWX|SB|V11|LOADED|Smooth1-S1|SESSION-CONTROLLER|mode=diagnostic-sidecar");
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXV11InstallObservers();
        TOWXV11RefreshSession("constructor");
        TOWXV11StartWatchdog();
    });
}
