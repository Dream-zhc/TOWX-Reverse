#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

#define TOWX_LINK_READY "com.dream.towx.link.ready"
#define TOWX_LINK_APP_ACTIVE "com.dream.towx.link.appActive"
#define TOWX_GOLDEN_IMAGE "TOWXWeChatStandalone.dylib"
#define TOWX_GOLDEN_BAR_OFFSET ((uintptr_t)0x4050)

static uintptr_t gV8GoldenBase = 0;
static int gV8ActiveToken = 0;
static dispatch_source_t gV8GuardTimer;
static BOOL gV8HooksInstalled = NO;

static IMP gOrigDidMoveToWindow = NULL;
static IMP gOrigDidMoveToSuperview = NULL;
static IMP gOrigLayoutSubviews = NULL;
static IMP gOrigSetHidden = NULL;

static uintptr_t TOWXV8FindGoldenBase(void) {
    for (uint32_t index = 0; index < _dyld_image_count(); index++) {
        const char *name = _dyld_get_image_name(index);
        if (name == NULL || strstr(name, TOWX_GOLDEN_IMAGE) == NULL) continue;
        const struct mach_header *header = _dyld_get_image_header(index);
        if (header != NULL) return (uintptr_t)header;
    }
    return 0;
}

static UIView *TOWXV8GoldenBar(void) {
    if (gV8GoldenBase == 0) gV8GoldenBase = TOWXV8FindGoldenBase();
    if (gV8GoldenBase == 0) return nil;
    uintptr_t raw = *(volatile uintptr_t *)(gV8GoldenBase + TOWX_GOLDEN_BAR_OFFSET);
    if (raw == 0) return nil;
    id object = (__bridge id)(void *)raw;
    return [object isKindOfClass:[UIView class]] ? (UIView *)object : nil;
}

static BOOL TOWXV8IsGoldenBar(id object) {
    UIView *bar = TOWXV8GoldenBar();
    return bar != nil && object == bar;
}

static void TOWXV8ForceInterfaceOnly(UIView *bar) {
    if (bar == nil) return;
    bar.userInteractionEnabled = NO;
    bar.layer.opacity = 0.0f;
    if (!bar.hidden) {
        if (gOrigSetHidden != NULL) ((void (*)(id, SEL, BOOL))gOrigSetHidden)(bar, @selector(setHidden:), YES);
        else bar.hidden = YES;
    }
    if (bar.alpha != 0.0) bar.alpha = 0.0;
}

static void TOWXV8DidMoveToWindow(id self, SEL _cmd) {
    if (gOrigDidMoveToWindow != NULL) ((void (*)(id, SEL))gOrigDidMoveToWindow)(self, _cmd);
    if (TOWXV8IsGoldenBar(self)) TOWXV8ForceInterfaceOnly((UIView *)self);
}

static void TOWXV8DidMoveToSuperview(id self, SEL _cmd) {
    if (gOrigDidMoveToSuperview != NULL) ((void (*)(id, SEL))gOrigDidMoveToSuperview)(self, _cmd);
    if (TOWXV8IsGoldenBar(self)) TOWXV8ForceInterfaceOnly((UIView *)self);
}

static void TOWXV8LayoutSubviews(id self, SEL _cmd) {
    if (gOrigLayoutSubviews != NULL) ((void (*)(id, SEL))gOrigLayoutSubviews)(self, _cmd);
    if (TOWXV8IsGoldenBar(self)) TOWXV8ForceInterfaceOnly((UIView *)self);
}

static void TOWXV8SetHidden(id self, SEL _cmd, BOOL hidden) {
    if (TOWXV8IsGoldenBar(self)) hidden = YES;
    if (gOrigSetHidden != NULL) ((void (*)(id, SEL, BOOL))gOrigSetHidden)(self, _cmd, hidden);
}

static void TOWXV8InstallHooks(void) {
    if (gV8HooksInstalled) return;
    Class cls = [UIView class];
    Method didMoveWindow = class_getInstanceMethod(cls, @selector(didMoveToWindow));
    Method didMoveSuperview = class_getInstanceMethod(cls, @selector(didMoveToSuperview));
    Method layout = class_getInstanceMethod(cls, @selector(layoutSubviews));
    Method setHidden = class_getInstanceMethod(cls, @selector(setHidden:));
    if (didMoveWindow != NULL) {
        gOrigDidMoveToWindow = method_getImplementation(didMoveWindow);
        method_setImplementation(didMoveWindow, (IMP)TOWXV8DidMoveToWindow);
    }
    if (didMoveSuperview != NULL) {
        gOrigDidMoveToSuperview = method_getImplementation(didMoveSuperview);
        method_setImplementation(didMoveSuperview, (IMP)TOWXV8DidMoveToSuperview);
    }
    if (layout != NULL) {
        gOrigLayoutSubviews = method_getImplementation(layout);
        method_setImplementation(layout, (IMP)TOWXV8LayoutSubviews);
    }
    if (setHidden != NULL) {
        gOrigSetHidden = method_getImplementation(setHidden);
        method_setImplementation(setHidden, (IMP)TOWXV8SetHidden);
    }
    gV8HooksInstalled = YES;
    NSLog(@"TOWX|WX|V8-GUARD|HOOKS-READY|interface-only");
}

static void TOWXV8PublishActive(BOOL active, NSString *reason) {
    if (gV8ActiveToken == 0) return;
    (void)notify_set_state(gV8ActiveToken, active ? 1 : 0);
    notify_post(TOWX_LINK_READY);
    NSLog(@"TOWX|WX|V8-GUARD|APP-ACTIVE|value=%d|reason=%@", active ? 1 : 0, reason ?: @"unknown");
}

static BOOL TOWXV8ApplicationIsActive(void) {
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

static void TOWXV8InstallLifecycle(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV8PublishActive(YES, @"app-active");
    }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV8PublishActive(NO, @"app-resign");
    }];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV8PublishActive(TOWXV8ApplicationIsActive(), @"scene-active");
    }];
    [center addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXV8PublishActive(NO, @"scene-deactivate");
    }];
}

static void TOWXV8StartGuardTimer(void) {
    gV8GuardTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gV8GuardTimer == nil) return;
    dispatch_source_set_timer(gV8GuardTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 20U),
                              (uint64_t)(NSEC_PER_SEC / 200U));
    dispatch_source_set_event_handler(gV8GuardTimer, ^{
        UIView *bar = TOWXV8GoldenBar();
        if (bar != nil) TOWXV8ForceInterfaceOnly(bar);
    });
    dispatch_resume(gV8GuardTimer);
}

__attribute__((constructor)) static void TOWXV8GuardInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        uint32_t status = notify_register_check(TOWX_LINK_APP_ACTIVE, &gV8ActiveToken);
        if (status != NOTIFY_STATUS_OK) {
            NSLog(@"TOWX|WX|V8-GUARD|ACTIVE-REGISTER-FAIL|status=%u", status);
            return;
        }
        gV8GoldenBase = TOWXV8FindGoldenBase();
        TOWXV8InstallHooks();
        TOWXV8InstallLifecycle();
        TOWXV8StartGuardTimer();
        TOWXV8PublishActive(TOWXV8ApplicationIsActive(), @"startup");
        UIView *bar = TOWXV8GoldenBar();
        if (bar != nil) TOWXV8ForceInterfaceOnly(bar);
        NSLog(@"TOWX|WX|V8-GUARD|LOADED|v0.8.0|mode=interface-only+active-signal+preframe-hide");
    });
}
