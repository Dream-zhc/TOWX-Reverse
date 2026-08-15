#import "TOWXV11SplitIdentity.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11HostContext.h"
#import "TOWXV11Diagnostics.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSNotificationName const TOWXV11SplitIdentityDidChangeNotification = @"TOWXV11SplitIdentityDidChangeNotification";

static NSString * const kTOWXWeChatBundle = @"com.tencent.xin";
static NSString *gSplitBundle = nil;
static NSString *gSplitSource = @"unresolved";
static dispatch_source_t gSplitTimer = nil;
static BOOL gSplitStarted = NO;
static NSUInteger gUnresolvedLogTick = 0;

static BOOL TOWXSplitPlausibleBundle(NSString *value) {
    if (![value isKindOfClass:[NSString class]]) return NO;
    NSString *v = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (v.length < 3 || v.length > 220) return NO;
    if ([v rangeOfString:@"."].location == NSNotFound) return NO;
    if ([v rangeOfString:@"/"].location != NSNotFound || [v rangeOfString:@" "].location != NSNotFound) return NO;
    if ([v isEqualToString:@"com.apple.springboard"] ||
        [v hasPrefix:@"com.dream.towx"] ||
        [v hasPrefix:@"com.charlieleung.trollopen"]) return NO;
    return YES;
}

static BOOL TOWXSplitInstalledBundle(NSString *bundleID) {
    if (!TOWXSplitPlausibleBundle(bundleID)) return NO;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL selector = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![(id)proxyClass respondsToSelector:selector]) return YES;
    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, selector, bundleID);
        return proxy != nil;
    } @catch (__unused NSException *exception) {
        return NO;
    }
}

static id TOWXSplitSafeGetter(id object, NSString *name) {
    if (!object || name.length == 0) return nil;
    SEL selector = NSSelectorFromString(name);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return nil;
    const char *type = signature.methodReturnType;
    while (type && strchr("rnNoORV", *type)) type++;
    if (!type || (*type != '@' && *type != '#')) return nil;
    @try {
        return ((id (*)(id, SEL))objc_msgSend)(object, selector);
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSInteger TOWXSplitStringScore(NSString *sourceName, NSString *path) {
    NSString *lower = [[NSString stringWithFormat:@"%@ %@", sourceName ?: @"", path ?: @""] lowercaseString];
    NSInteger score = 120;
    if ([lower containsString:@"splitbundle"]) score += 500;
    if ([lower containsString:@"targetbundle"]) score += 470;
    if ([lower containsString:@"clientbundle"]) score += 440;
    if ([lower containsString:@"applicationbundle"]) score += 390;
    if ([lower containsString:@"bundleid"] || [lower containsString:@"bundleidentifier"]) score += 360;
    if ([lower containsString:@"targetapplication"]) score += 330;
    if ([lower containsString:@"clientapplication"]) score += 320;
    if ([lower containsString:@"embeddedapplication"]) score += 300;
    if ([lower containsString:@"displayidentifier"]) score += 210;
    if ([lower containsString:@"swipeselected"]) score += 180;
    if ([lower containsString:@"host"]) score -= 240;
    if ([lower containsString:@"springboard"]) score -= 300;
    return score;
}

static BOOL TOWXSplitRelevantObjectName(NSString *name) {
    NSString *lower = name.lowercaseString;
    if (lower.length == 0) return NO;
    static NSArray<NSString *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = @[@"split", @"bundle", @"application", @"client", @"target", @"host", @"floating", @"remote", @"scene", @"controller", @"window", @"content", @"current", @"selected"];
    });
    for (NSString *token in tokens) if ([lower containsString:token]) return YES;
    return NO;
}

static void TOWXSplitAddCandidate(NSMutableArray<NSDictionary *> *candidates,
                                  id value,
                                  NSString *source,
                                  NSString *path) {
    if (![value isKindOfClass:[NSString class]]) return;
    NSString *bundle = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!TOWXSplitInstalledBundle(bundle)) return;
    NSInteger score = TOWXSplitStringScore(source, path);
    NSString *host = TOWXV11HostBundleIdentifier();
    if (host.length && [bundle isEqualToString:host]) score -= 700;
    [candidates addObject:@{ @"bundle": bundle,
                             @"source": source ?: @"?",
                             @"path": path ?: @"?",
                             @"score": @(score) }];
}

static void TOWXSplitEnqueue(NSMutableArray<NSDictionary *> *queue,
                             id object,
                             NSString *path,
                             NSUInteger depth,
                             NSUInteger limit) {
    if (!object || queue.count >= limit) return;
    [queue addObject:@{ @"object": object,
                        @"path": path ?: @"?",
                        @"depth": @(depth) }];
}

static NSString *TOWXSplitResolve(NSString **sourceOut, NSUInteger *objectsOut) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (!session || !TOWXV11SessionIsVisible()) {
        if (sourceOut) *sourceOut = @"session-gone";
        if (objectsOut) *objectsOut = 0;
        return nil;
    }

    static NSArray<NSDictionary *> *stringSelectors;
    static NSArray<NSString *> *objectSelectors;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        stringSelectors = @[
            @{@"name": @"splitBundleID", @"bonus": @800},
            @{@"name": @"targetBundleID", @"bonus": @760},
            @{@"name": @"clientBundleID", @"bonus": @720},
            @{@"name": @"applicationBundleID", @"bonus": @620},
            @{@"name": @"bundleID", @"bonus": @600},
            @{@"name": @"bundleIdentifier", @"bonus": @560},
            @{@"name": @"applicationIdentifier", @"bonus": @480},
            @{@"name": @"embeddedApplicationIdentifier", @"bonus": @460},
            @{@"name": @"displayIdentifier", @"bonus": @320},
            @{@"name": @"swipeSelectedBundleID", @"bonus": @260}
        ];
        objectSelectors = @[
            @"rootViewController", @"presentedViewController", @"parentViewController", @"childViewControllers", @"children",
            @"floatingHostViewController", @"hostViewController", @"floatingWindow", @"currentVisibleFloatingWindow",
            @"targetApplication", @"clientApplication", @"application", @"scene", @"applicationScene", @"sceneHandle",
            @"applicationSceneHandle", @"owningScene", @"windowScene", @"contentViewController", @"remoteViewController",
            @"selectedViewController", @"visibleViewController", @"topViewController"
        ];
    });

    const NSUInteger maxObjects = 96;
    NSMutableArray<NSDictionary *> *queue = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableSet<NSValue *> *visited = [NSMutableSet set];
    TOWXSplitEnqueue(queue, session, @"session", 0, maxObjects);
    if (session.rootViewController) TOWXSplitEnqueue(queue, session.rootViewController, @"session.root", 0, maxObjects);

    NSUInteger cursor = 0;
    while (cursor < queue.count && cursor < maxObjects) {
        NSDictionary *item = queue[cursor++];
        id object = item[@"object"];
        NSString *path = item[@"path"];
        NSUInteger depth = [item[@"depth"] unsignedIntegerValue];
        if (!object) continue;

        if ([object isKindOfClass:[NSArray class]] || [object isKindOfClass:[NSSet class]]) {
            NSArray *values = [object isKindOfClass:[NSArray class]] ? (NSArray *)object : [(NSSet *)object allObjects];
            NSUInteger idx = 0;
            for (id child in values) {
                if (idx >= 16) break;
                TOWXSplitEnqueue(queue, child, [path stringByAppendingFormat:@"[%lu]", (unsigned long)idx], depth, maxObjects);
                idx++;
            }
            continue;
        }
        if ([object isKindOfClass:[NSDictionary class]]) {
            NSUInteger idx = 0;
            for (id child in [(NSDictionary *)object allValues]) {
                if (idx >= 16) break;
                TOWXSplitEnqueue(queue, child, [path stringByAppendingFormat:@".value[%lu]", (unsigned long)idx], depth, maxObjects);
                idx++;
            }
            continue;
        }

        NSValue *pointer = [NSValue valueWithPointer:(__bridge const void *)(object)];
        if ([visited containsObject:pointer]) continue;
        [visited addObject:pointer];

        for (NSDictionary *descriptor in stringSelectors) {
            NSString *name = descriptor[@"name"];
            id value = TOWXSplitSafeGetter(object, name);
            if ([value isKindOfClass:[NSString class]]) {
                NSString *bundle = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (TOWXSplitInstalledBundle(bundle)) {
                    NSInteger score = TOWXSplitStringScore(name, path) + [descriptor[@"bonus"] integerValue];
                    NSString *host = TOWXV11HostBundleIdentifier();
                    if (host.length && [bundle isEqualToString:host]) score -= 700;
                    [candidates addObject:@{ @"bundle": bundle, @"source": name, @"path": path, @"score": @(score) }];
                }
            }
        }

        for (Class cls = [object class]; cls && cls != [NSObject class]; cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);
            for (unsigned int i = 0; i < count; i++) {
                Ivar ivar = ivars[i];
                const char *type = ivar_getTypeEncoding(ivar);
                const char *rawName = ivar_getName(ivar);
                if (!type || type[0] != '@' || !rawName) continue;
                NSString *name = [NSString stringWithUTF8String:rawName];
                if (!TOWXSplitRelevantObjectName(name)) continue;
                id value = nil;
                @try { value = object_getIvar(object, ivar); }
                @catch (__unused NSException *exception) { value = nil; }
                if (!value || value == object) continue;
                NSString *ivarPath = [path stringByAppendingFormat:@".%@", name];
                if ([value isKindOfClass:[NSString class]]) {
                    TOWXSplitAddCandidate(candidates, value, [@"ivar:" stringByAppendingString:name], ivarPath);
                } else if (depth < 4) {
                    TOWXSplitEnqueue(queue, value, ivarPath, depth + 1, maxObjects);
                }
            }
            free(ivars);
        }

        if (depth < 4) {
            for (NSString *selectorName in objectSelectors) {
                id child = TOWXSplitSafeGetter(object, selectorName);
                if (!child || child == object) continue;
                TOWXSplitEnqueue(queue, child, [path stringByAppendingFormat:@".%@", selectorName], depth + 1, maxObjects);
            }
        }
    }

    NSDictionary *best = nil;
    for (NSDictionary *candidate in candidates) {
        if (!best || [candidate[@"score"] integerValue] > [best[@"score"] integerValue]) best = candidate;
    }
    if (objectsOut) *objectsOut = visited.count;
    if (!best || [best[@"score"] integerValue] < 250) {
        if (sourceOut) *sourceOut = @"unresolved";
        return nil;
    }

    NSString *bundle = best[@"bundle"];
    NSString *source = [NSString stringWithFormat:@"%@:%@:%ld",
                        best[@"path"] ?: @"?",
                        best[@"source"] ?: @"?",
                        (long)[best[@"score"] integerValue]];
    if (sourceOut) *sourceOut = source;
    return bundle;
}

void TOWXV11SplitIdentityRefresh(const char *reason) {
    if (!NSThread.isMainThread) {
        NSString *copy = reason ? [NSString stringWithUTF8String:reason] : @"async";
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11SplitIdentityRefresh(copy.UTF8String); });
        return;
    }

    NSString *source = nil;
    NSUInteger objects = 0;
    NSString *bundle = TOWXSplitResolve(&source, &objects);
    BOOL changed = ![(bundle ?: @"") isEqualToString:(gSplitBundle ?: @"")] ||
                   ![(source ?: @"") isEqualToString:(gSplitSource ?: @"")];
    NSString *old = gSplitBundle ?: @"";
    gSplitBundle = [bundle copy];
    gSplitSource = [source ?: @"unresolved" copy];

    if (bundle.length || changed || (++gUnresolvedLogTick % 6U) == 0U) {
        TOWXV11DiagLog("SPLIT", "STATE|fix=7|reason=%s|old=%s|bundle=%s|source=%s|objects=%lu|host=%s",
                       reason ?: "?",
                       old.length ? old.UTF8String : "?",
                       gSplitBundle.length ? gSplitBundle.UTF8String : "?",
                       gSplitSource.UTF8String ?: "?",
                       (unsigned long)objects,
                       TOWXV11HostBundleIdentifier().UTF8String ?: "?");
    }
    if (changed) {
        [NSNotificationCenter.defaultCenter postNotificationName:TOWXV11SplitIdentityDidChangeNotification object:nil];
    }
}

void TOWXV11SplitIdentityStart(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11SplitIdentityStart(); });
        return;
    }
    if (gSplitStarted) return;
    gSplitStarted = YES;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:TOWXV11SessionDidBeginNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11SplitIdentityRefresh("session-begin");
    }];
    [center addObserverForName:TOWXV11SessionDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11SplitIdentityRefresh("session-change");
    }];
    [center addObserverForName:TOWXV11SessionDidEndNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV11SplitIdentityRefresh("session-end");
    }];

    gSplitTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(gSplitTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 350 * NSEC_PER_MSEC),
                              900 * NSEC_PER_MSEC,
                              120 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gSplitTimer, ^{ TOWXV11SplitIdentityRefresh("watchdog"); });
    dispatch_resume(gSplitTimer);

    TOWXV11DiagLog("SPLIT", "LOADED|Smooth1-FIX7|strict-split-identity|dynamic-getters+ivars|fail-closed");
    TOWXV11SplitIdentityRefresh("startup");
}

NSString *TOWXV11SplitBundleIdentifier(void) { return gSplitBundle; }
NSString *TOWXV11SplitBundleSource(void) { return gSplitSource ?: @"unresolved"; }
BOOL TOWXV11SplitIsWeChat(void) { return [gSplitBundle isEqualToString:kTOWXWeChatBundle]; }
