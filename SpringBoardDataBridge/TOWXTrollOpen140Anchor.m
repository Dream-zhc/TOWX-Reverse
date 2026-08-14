#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <dispatch/dispatch.h>

#define TOWX140_SESSION_CLASS @"TOJBClass022"

static __weak UIScrollView *gTOWX140Anchor = nil;
static __weak UIWindow *gTOWX140Window = nil;
static dispatch_source_t gTOWX140Timer = nil;

static NSArray<UIWindow *> *TOWX140AllWindows(void) {
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

static BOOL TOWX140WindowIsUsable(UIWindow *window) {
    if (!window || window.hidden || window.alpha <= 0.01) return NO;
    if (![NSStringFromClass(window.class) isEqualToString:TOWX140_SESSION_CLASS]) return NO;
    return CGRectGetWidth(window.bounds) > 100.0 && CGRectGetHeight(window.bounds) > 100.0;
}

static UIWindow *TOWX140SessionWindow(void) {
    UIWindow *current = gTOWX140Window;
    if (TOWX140WindowIsUsable(current)) return current;
    for (UIWindow *window in TOWX140AllWindows()) {
        if (TOWX140WindowIsUsable(window)) return window;
    }
    return nil;
}

static UIScrollView *TOWX140CreateAnchor(void) {
    UIScrollView *scroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    scroll.userInteractionEnabled = NO;
    scroll.scrollEnabled = NO;
    scroll.hidden = YES;
    scroll.alpha = 0.0;
    scroll.backgroundColor = UIColor.clearColor;
    scroll.tag = 0x140140;

    for (NSUInteger i = 0; i < 5; i++) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8.0 + (CGFloat)i * 44.0, 4.0, 40.0, 40.0)];
        label.text = [NSString stringWithFormat:@"%c", (int)('A' + i)];
        label.textAlignment = NSTextAlignmentCenter;
        label.hidden = YES;
        label.alpha = 0.0;
        label.userInteractionEnabled = NO;
        [scroll addSubview:label];
    }
    return scroll;
}

static CGRect TOWX140AnchorFrame(UIWindow *window) {
    CGFloat width = CGRectGetWidth(window.bounds);
    CGFloat height = CGRectGetHeight(window.bounds);
    if (width <= 100.0 || height <= 100.0) return CGRectZero;

    CGFloat barWidth = width * 0.70;
    barWidth = MIN(MAX(barWidth, 180.0), MAX(180.0, width - 8.0));

    CGFloat barHeight = height * 0.075;
    barHeight = MIN(MAX(barHeight, 48.0), 72.0);

    CGFloat bottomGap = MAX(12.0, height * 0.09);
    CGFloat x = floor((width - barWidth) * 0.5);
    CGFloat y = height - bottomGap - barHeight;
    x = MAX(4.0, MIN(x, width - barWidth - 4.0));
    y = MAX(0.0, MIN(y, height - barHeight));
    return CGRectMake(x, y, barWidth, barHeight);
}

static void TOWX140DetachAnchor(void) {
    UIScrollView *anchor = gTOWX140Anchor;
    if (anchor.superview) [anchor removeFromSuperview];
    gTOWX140Anchor = nil;
    gTOWX140Window = nil;
}

static void TOWX140EnsureAnchor(void) {
    UIWindow *window = TOWX140SessionWindow();
    if (!window) {
        TOWX140DetachAnchor();
        return;
    }

    CGRect frame = TOWX140AnchorFrame(window);
    if (CGRectGetWidth(frame) < 160.0 || CGRectGetHeight(frame) < 40.0) return;

    UIScrollView *anchor = gTOWX140Anchor;
    if (!anchor) {
        anchor = TOWX140CreateAnchor();
        gTOWX140Anchor = anchor;
    }
    if (anchor.superview != window) {
        [anchor removeFromSuperview];
        [window addSubview:anchor];
    }

    anchor.frame = frame;
    anchor.hidden = YES;
    anchor.alpha = 0.0;
    anchor.userInteractionEnabled = NO;
    gTOWX140Window = window;
}

static void TOWX140StartTimer(void) {
    if (gTOWX140Timer) return;
    gTOWX140Timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gTOWX140Timer) return;
    dispatch_source_set_timer(gTOWX140Timer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              NSEC_PER_SEC / 4,
                              NSEC_PER_SEC / 40);
    dispatch_source_set_event_handler(gTOWX140Timer, ^{
        TOWX140EnsureAnchor();
    });
    dispatch_resume(gTOWX140Timer);
}

__attribute__((constructor)) static void TOWXTrollOpen140AnchorInit(void) {
    NSLog(@"TOWX|SB|140ANCHOR|LOADED|v0.1|sessionClass=%@", TOWX140_SESSION_CLASS);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIWindowDidBecomeVisibleNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            TOWX140EnsureAnchor();
        }];
        [center addObserverForName:UIWindowDidBecomeHiddenNotification
                            object:nil
                             queue:NSOperationQueue.mainQueue
                        usingBlock:^(__unused NSNotification *note) {
            TOWX140EnsureAnchor();
        }];
        TOWX140EnsureAnchor();
        TOWX140StartTimer();
    });
}
