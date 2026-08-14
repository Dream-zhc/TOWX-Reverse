#import "TOWXV11HostContext.h"
#import "TOWXV11Diagnostics.h"

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#include <string.h>

NSNotificationName const TOWXV11HostContextDidChangeNotification = @"com.dream.towx.v11.host.change";

static NSString *gTOWXV11HostBundleID = nil;
static NSString *gTOWXV11HostSource = @"unresolved";
static dispatch_source_t gTOWXV11HostWatchdog = nil;
static BOOL gTOWXV11HostMethodsLogged = NO;

static id TOWXV11HostSafeGetter(id object, NSString *selectorName) {
    if (!object || !selectorName.length) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![object respondsToSelector:selector]) return nil;
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) return nil;
    const char *type = signature.methodReturnType;
    while (type && strchr("rnNoORV", *type)) type++;
    if (!type || (*type != '@' && *type != '#')) return nil;
    @try { return ((id (*)(id, SEL))objc_msgSend)(object, selector); }
    @catch (__unused NSException *exception) { return nil; }
}

static id TOWXV11HostSharedInstance(Class cls) {
    if (!cls) return nil;
    for (NSString *name in @[@"sharedInstance", @"sharedInstanceIfExists", @"sharedWorkspace"]) {
        id value = TOWXV11HostSafeGetter((id)cls, name);
        if (value) return value;
    }
    return nil;
}

static NSString *TOWXV11BundleFromApplicationObject(id object) {
    if (!object) return nil;
    for (NSString *selectorName in @[@"bundleIdentifier", @"bundleID", @"displayIdentifier", @"applicationBundleIdentifier"]) {
        id value = TOWXV11HostSafeGetter(object, selectorName);
        if ([value isKindOfClass:[NSString class]] && [(NSString *)value length]) return value;
    }
    return nil;
}

static void TOWXV11LogWorkspaceMethodsOnce(id workspace) {
    if (!workspace || gTOWXV11HostMethodsLogged) return;
    gTOWXV11HostMethodsLogged = YES;
    NSUInteger emitted = 0;
    for (Class cls = [workspace class]; cls && emitted < 32; cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count && emitted < 32; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            if (![lower containsString:@"current"] && ![lower containsString:@"front"] &&
                ![lower containsString:@"application"] && ![lower containsString:@"focused"]) continue;
            TOWXV11DiagLog("HOST", "METHOD|class=%s|selector=%s",
                           NSStringFromClass(cls).UTF8String ?: "?",
                           name.UTF8String ?: "?");
            emitted++;
        }
        free(methods);
    }
}

static NSString *TOWXV11ResolveHostBundle(NSString **sourceOut) {
    Class workspaceClass = NSClassFromString(@"SBMainWorkspace");
    id workspace = TOWXV11HostSharedInstance(workspaceClass);
    if (workspace) {
        for (NSString *selectorName in @[@"currentApplication", @"focusedApplication", @"frontmostApplication", @"frontMostApplication"]) {
            id app = TOWXV11HostSafeGetter(workspace, selectorName);
            NSString *bundle = TOWXV11BundleFromApplicationObject(app);
            if (bundle.length) {
                if (sourceOut) *sourceOut = [NSString stringWithFormat:@"SBMainWorkspace.%@", selectorName];
                return bundle;
            }
        }
        TOWXV11LogWorkspaceMethodsOnce(workspace);
    }

    UIApplication *springBoard = UIApplication.sharedApplication;
    for (NSString *selectorName in @[@"_accessibilityFrontMostApplication", @"frontMostApplication", @"frontmostApplication"]) {
        id app = TOWXV11HostSafeGetter(springBoard, selectorName);
        NSString *bundle = TOWXV11BundleFromApplicationObject(app);
        if (bundle.length) {
            if (sourceOut) *sourceOut = [NSString stringWithFormat:@"SpringBoard.%@", selectorName];
            return bundle;
        }
    }

    if (sourceOut) *sourceOut = @"unresolved";
    return nil;
}

NSString *TOWXV11HostBundleIdentifier(void) { return gTOWXV11HostBundleID; }
NSString *TOWXV11HostBundleSource(void) { return gTOWXV11HostSource ?: @"unresolved"; }

void TOWXV11RefreshHostContext(const char *reason) {
    if (!NSThread.isMainThread) {
        NSString *r = reason ? [NSString stringWithUTF8String:reason] : @"async";
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11RefreshHostContext(r.UTF8String); });
        return;
    }

    NSString *source = nil;
    NSString *bundle = TOWXV11ResolveHostBundle(&source);
    BOOL changed = !((bundle == nil && gTOWXV11HostBundleID == nil) || [bundle isEqualToString:gTOWXV11HostBundleID]) ||
                   ![source ?: @"unresolved" isEqualToString:gTOWXV11HostSource ?: @"unresolved"];
    if (!changed) return;

    gTOWXV11HostBundleID = [bundle copy];
    gTOWXV11HostSource = [source ?: @"unresolved" copy];
    TOWXV11DiagLog("HOST", "STATE|reason=%s|bundle=%s|source=%s",
                   reason ?: "?",
                   bundle.length ? bundle.UTF8String : "?",
                   gTOWXV11HostSource.UTF8String ?: "?");
    [[NSNotificationCenter defaultCenter] postNotificationName:TOWXV11HostContextDidChangeNotification object:nil];
}

static void TOWXV11StartHostWatchdog(void) {
    if (gTOWXV11HostWatchdog) return;
    gTOWXV11HostWatchdog = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTOWXV11HostWatchdog) return;
    dispatch_source_set_timer(gTOWXV11HostWatchdog,
                              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                              NSEC_PER_SEC,
                              NSEC_PER_SEC / 5);
    dispatch_source_set_event_handler(gTOWXV11HostWatchdog, ^{ TOWXV11RefreshHostContext("watchdog"); });
    dispatch_resume(gTOWXV11HostWatchdog);
}

__attribute__((constructor)) static void TOWXV11HostContextInit(void) {
    TOWXV11DiagLog("HOST", "LOADED|Smooth1-FIX1|underlying-workspace-context");
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXV11RefreshHostContext("constructor");
        TOWXV11StartHostWatchdog();
    });
}
