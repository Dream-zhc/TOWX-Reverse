#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#define TOWX_LINK_READY "com.dream.towx.link.ready"
#define TOWX_LINK_APP_ACTIVE "com.dream.towx.link.appActive"
#define TOWX_GOLDEN_IMAGE "TOWXWeChatStandalone.dylib"
#define TOWX_GOLDEN_BAR_OFFSET ((uintptr_t)0x4050)
#define TOWX_GOLDEN_BADGE_OFFSET ((uintptr_t)0x4060)

static uintptr_t gV9GoldenBase = 0;
static int gV9ActiveToken = 0;
static dispatch_source_t gV9GuardTimer;
static BOOL gV9HooksInstalled = NO;
static BOOL gV9BarLogged = NO;
static BOOL gV9BadgeLogged = NO;

static IMP gOrigDidMoveToWindow = NULL;
static IMP gOrigDidMoveToSuperview = NULL;
static IMP gOrigSetHidden = NULL;
static IMP gOrigSetAlpha = NULL;

static uintptr_t TOWXV9FindGoldenBase(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == NULL || strstr(name, TOWX_GOLDEN_IMAGE) == NULL) continue;
        const struct mach_header *header = _dyld_get_image_header(index);
        if (header != NULL) return (uintptr_t)header;
    }
    return 0;
}

static UIView *TOWXV9GoldenViewAtOffset(uintptr_t offset) {
    if (gV9GoldenBase == 0) gV9GoldenBase = TOWXV9FindGoldenBase();
    if (gV9GoldenBase == 0) return nil;
    uintptr_t raw = *(volatile uintptr_t *)(gV9GoldenBase + offset);
    if (raw == 0) return nil;
    id object = (__bridge id)(void *)raw;
    return [object isKindOfClass:[UIView class]] ? (UIView *)object : nil;
}

static UIView *TOWXV9GoldenBar(void) {
    return TOWXV9GoldenViewAtOffset(TOWX_GOLDEN_BAR_OFFSET);
}

static UIView *TOWXV9GoldenBadge(void) {
    return TOWXV9GoldenViewAtOffset(TOWX_GOLDEN_BADGE_OFFSET);
}

static int TOWXV9DebugKind(id object) {
    if (object == nil) return 0;
    UIView *bar = TOWXV9GoldenBar();
    if (bar != nil && object == bar) return 1;
    UIView *badge = TOWXV9GoldenBadge();
    if (badge != nil && object == badge) return 2;
    return 0;
}

static void TOWXV9ForceInterfaceOnly(UIView *view, int kind) {
    if (view == nil || kind == 0) return;
    view.userInteractionEnabled = NO;
    view.layer.opacity = 0.0f;
    if (!view.hidden) {
        if (gOrigSetHidden != NULL) ((void (*)(id, SEL, BOOL))gOrigSetHidden)(view, @selector(setHidden:), YES);
        else view.hidden = YES;
    }
    if (view.alpha != 0.0) {
        if (gOrigSetAlpha != NULL) ((void (*)(id, SEL, CGFloat))gOrigSetAlpha)(view, @selector(setAlpha:), 0.0);
        else view.alpha = 0.0;
    }

    if (kind == 1 && !gV9BarLogged) {
        gV9BarLogged = YES;
        NSLog(@"TOWX|WX|V9-GUARD|SUPPRESS|kind=recent-avatar-strip|view=%p", view);
    } else if (kind == 2 && !gV9BadgeLogged) {
        gV9BadgeLogged = YES;
        NSLog(@"TOWX|WX|V9-GUARD|SUPPRESS|kind=towx-badge|view=%p", view);
    }
}

static void TOWXV9SuppressKnownDebugViews(void) {
    UIView *bar = TOWXV9GoldenBar();
    if (bar != nil) TOWXV9ForceInterfaceOnly(bar, 1);
    UIView *badge = TOWXV9GoldenBadge();
    if (badge != nil) TOWXV9ForceInterfaceOnly(badge, 2);
}

static void TOWXV9DidMoveToWindow(id self, SEL _cmd) {
    if (gOrigDidMoveToWindow != NULL) ((void (*)(id, SEL))gOrigDidMoveToWindow)(self, _cmd);
    int kind = TOWXV9DebugKind(self);
    if (kind != 0) TOWXV9ForceInterfaceOnly((UIView *)self, kind);
}

static void TOWXV9DidMoveToSuperview(id self, SEL _cmd) {
    if (gOrigDidMoveToSuperview != NULL) ((void (*)(id, SEL))gOrigDidMoveToSuperview)(self, _cmd);
    int kind = TOWXV9DebugKind(self);
    if (kind != 0) TOWXV9ForceInterfaceOnly((UIView *)self, kind);
}

static void TOWXV9SetHidden(id self, SEL _cmd, BOOL hidden) {
    if (TOWXV9DebugKind(self) != 0) hidden = YES;
    if (gOrigSetHidden != NULL) ((void (*)(id, SEL, BOOL))gOrigSetHidden)(self, _cmd, hidden);
}

static void TOWXV9SetAlpha(id self, SEL _cmd, CGFloat alpha) {
    if (TOWXV9DebugKind(self) != 0) alpha = 0.0;
    if (gOrigSetAlpha != NULL) ((void (*)(id, SEL, CGFloat))gOrigSetAlpha)(self, _cmd, alpha);
}

static void TOWXV9InstallHooks(void) {
    if (gV9HooksInstalled) return;
    Class cls = [UIView class];
    Method didMoveWindow = class_getInstanceMethod(cls, @selector(didMoveToWindow));
    Method didMoveSuperview = class_getInstanceMethod(cls, @selector(didMoveToSuperview));
    Method setHidden = class_getInstanceMethod(cls, @selector(setHidden:));
    Method setAlpha = class_getInstanceMethod(cls, @selector(setAlpha:));

    if (didMoveWindow != NULL) {
        gOrigDidMoveToWindow = method_getImplementation(didMoveWindow);
        method_setImplementation(didMoveWindow, (IMP)TOWXV9DidMoveToWindow);
    }
    if (didMoveSuperview != NULL) {
        gOrigDidMoveToSuperview = method_getImplementation(didMoveSuperview);
        method_setImplementation(didMoveSuperview, (IMP)TOWXV9DidMoveToSuperview);
    }
    if (setHidden != NULL) {
        gOrigSetHidden = method_getImplementation(setHidden);
        method_setImplementation(setHidden, (IMP)TOWXV9SetHidden);
    }
    if (setAlpha != NULL) {
        gOrigSetAlpha = method_getImplementation(setAlpha);
        method_setImplementation(setAlpha, (IMP)TOWXV9SetAlpha);
    }
    gV9HooksInstalled = YES;
    NSLog(@"TOWX|WX|V9-GUARD|HOOKS-READY|interface-only|badge-off");
}

static BOOL TOWXV9ApplicationIsActive(void) {
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

static void TOWXV9PublishActive(BOOL active, NSString *reason) {
    if (gV9ActiveToken == 0) return;
    (void)notify_set_state(gV9ActiveToken, active ? 1 : 0);
    notify_post(TOWX_LINK_READY);
    NSLog(@"TOWX|WX|V9-GUARD|APP-ACTIVE|value=%d|reason=%@", active ? 1 : 0, reason ?: @"unknown");
}

static void TOWXV9InstallLifecycle(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV9SuppressKnownDebugViews();
        TOWXV9PublishActive(YES, @"app-active");
    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV9PublishActive(NO, @"app-resign");
    }];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV9SuppressKnownDebugViews();
        TOWXV9PublishActive(TOWXV9ApplicationIsActive(), @"scene-active");
    }];
    [center addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV9PublishActive(NO, @"scene-deactivate");
    }];
}

static void TOWXV9StartGuardTimer(void) {
    gV9GuardTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gV9GuardTimer == nil) return;
    dispatch_source_set_timer(gV9GuardTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 10U),
                              (uint64_t)(NSEC_PER_SEC / 100U));
    dispatch_source_set_event_handler(gV9GuardTimer, ^{
        TOWXV9SuppressKnownDebugViews();
    });
    dispatch_resume(gV9GuardTimer);
}

__attribute__((constructor)) static void TOWXV9GuardInit(void) {
    /* Install UIView interception immediately so the golden debug controls cannot win a first-frame race. */
    gV9GoldenBase = TOWXV9FindGoldenBase();
    TOWXV9InstallHooks();

    dispatch_async(dispatch_get_main_queue(), ^{
        uint32_t status = notify_register_check(TOWX_LINK_APP_ACTIVE, &gV9ActiveToken);
        if (status != NOTIFY_STATUS_OK) {
            NSLog(@"TOWX|WX|V9-GUARD|ACTIVE-REGISTER-FAIL|status=%u", status);
            return;
        }
        TOWXV9InstallLifecycle();
        TOWXV9StartGuardTimer();
        TOWXV9SuppressKnownDebugViews();
        TOWXV9PublishActive(TOWXV9ApplicationIsActive(), @"startup");
        NSLog(@"TOWX|WX|V9-GUARD|LOADED|v0.9.0|mode=interface-only+badge-off+active-signal+preframe-hide");
    });
}
