#import "TOWXV11KeyboardState.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

NSNotificationName const TOWXV11KeyboardStateDidChangeNotification = @"TOWXV11KeyboardStateDidChangeNotification";

static BOOL gKeyboardStarted = NO;
static BOOL gKeyboardVisible = NO;
static CGRect gKeyboardFrame = {{0,0},{0,0}};
static NSString *gKeyboardSource = @"none";
static BOOL gKeyboardNotificationVisible = NO;
static CGRect gKeyboardNotificationFrame = {{0,0},{0,0}};

static BOOL TOWXKeyboardFiniteRect(CGRect rect) {
    return isfinite(rect.origin.x) && isfinite(rect.origin.y) &&
           isfinite(rect.size.width) && isfinite(rect.size.height) &&
           rect.size.width > 1.0 && rect.size.height > 1.0;
}

static id<UICoordinateSpace> TOWXKeyboardCoordinateSpace(void) {
    UIWindow *session = TOWXV11CurrentSessionWindow();
    if (session.screen) return session.screen.coordinateSpace;
    if (UIScreen.mainScreen) return UIScreen.mainScreen.coordinateSpace;
    if (session.windowScene) return session.windowScene.coordinateSpace;
    return nil;
}

static CGRect TOWXKeyboardScreenBounds(void) {
    id<UICoordinateSpace> space = TOWXKeyboardCoordinateSpace();
    return space ? space.bounds : UIScreen.mainScreen.bounds;
}

static BOOL TOWXKeyboardNameSignal(NSString *name) {
    if (name.length == 0) return NO;
    static NSArray<NSString *> *tokens;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        tokens = @[@"UIInputSetHostView",
                   @"UIInputSetContainerView",
                   @"UIKeyboard",
                   @"RemoteKeyboard",
                   @"KeyboardLayout",
                   @"KeyboardDock",
                   @"InputSetHost",
                   @"InputSetContainer"];
    });
    for (NSString *token in tokens) {
        if ([name rangeOfString:token options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

/*
 * Fix6b: a keyboard candidate must look like an on-screen keyboard, not merely
 * contain a UIKit input-host class. SpringBoard/TrollOpen can keep a full-screen
 * UIInputSetHostView alive even when no keyboard is visible. That full-screen host
 * was the reason Fix6 permanently reported keyboard=1.
 */
static BOOL TOWXKeyboardRectVisibleOnScreen(CGRect rect) {
    if (!TOWXKeyboardFiniteRect(rect)) return NO;
    CGRect screen = TOWXKeyboardScreenBounds();
    if (!TOWXKeyboardFiniteRect(screen)) return NO;

    CGRect inter = CGRectIntersection(rect, screen);
    if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) return NO;

    CGFloat sw = MAX(1.0, CGRectGetWidth(screen));
    CGFloat sh = MAX(1.0, CGRectGetHeight(screen));
    CGFloat iw = CGRectGetWidth(inter);
    CGFloat ih = CGRectGetHeight(inter);
    if (iw < 120.0 || ih < 80.0) return NO;

    CGFloat widthRatio = iw / sw;
    CGFloat heightRatio = ih / sh;
    CGFloat areaRatio = (iw * ih) / (sw * sh);

    /* Hard reject full-screen / near-full-screen input-host containers. */
    if (widthRatio >= 0.92 && heightRatio >= 0.70) return NO;
    if (heightRatio >= 0.62) return NO;
    if (areaRatio >= 0.56) return NO;

    CGFloat bottomGap = fabs(CGRectGetMaxY(screen) - CGRectGetMaxY(inter));
    CGFloat bottomTolerance = MAX(36.0, sh * 0.08);

    /* Standard docked keyboard: broad and attached to the screen bottom. */
    BOOL docked = widthRatio >= 0.62 &&
                  heightRatio >= 0.10 &&
                  heightRatio <= 0.60 &&
                  bottomGap <= bottomTolerance;

    /* Floating keyboard: smaller than the screen in both dimensions. */
    BOOL floating = widthRatio >= 0.28 && widthRatio <= 0.90 &&
                    heightRatio >= 0.12 && heightRatio <= 0.58 &&
                    areaRatio <= 0.45;

    return docked || floating;
}

static void TOWXKeyboardSetState(BOOL visible, CGRect frame, NSString *source) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXKeyboardSetState(visible, frame, source); });
        return;
    }
    NSString *resolvedSource = source.length ? source : @"unknown";
    BOOL changed = (gKeyboardVisible != visible) ||
                   (visible && !CGRectEqualToRect(gKeyboardFrame, frame)) ||
                   ![gKeyboardSource isEqualToString:resolvedSource];
    gKeyboardVisible = visible;
    gKeyboardFrame = visible ? frame : CGRectZero;
    gKeyboardSource = [resolvedSource copy];
    if (!changed) return;

    TOWXV11DiagLog("KEYBOARD", "STATE|fix=6b|visible=%d|source=%s|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                   visible ? 1 : 0,
                   resolvedSource.UTF8String ?: "?",
                   gKeyboardFrame.origin.x, gKeyboardFrame.origin.y,
                   gKeyboardFrame.size.width, gKeyboardFrame.size.height);
    [NSNotificationCenter.defaultCenter postNotificationName:TOWXV11KeyboardStateDidChangeNotification object:nil];
}

static void TOWXKeyboardConsiderView(UIView *view,
                                     id<UICoordinateSpace> coordinateSpace,
                                     NSUInteger depth,
                                     CGRect *bestRect,
                                     CGFloat *bestArea,
                                     NSString * __strong *bestName) {
    if (!view || !coordinateSpace || depth > 10 || view.hidden || view.alpha <= 0.02) return;
    NSString *name = NSStringFromClass(view.class);
    if (TOWXKeyboardNameSignal(name)) {
        @try {
            CGRect rect = [view convertRect:view.bounds toCoordinateSpace:coordinateSpace];
            if (TOWXKeyboardRectVisibleOnScreen(rect)) {
                CGRect inter = CGRectIntersection(rect, TOWXKeyboardScreenBounds());
                CGFloat area = CGRectIsNull(inter) ? 0.0 : CGRectGetWidth(inter) * CGRectGetHeight(inter);
                if (area > *bestArea) {
                    *bestArea = area;
                    *bestRect = rect;
                    if (bestName) *bestName = name;
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
    for (UIView *child in view.subviews) {
        TOWXKeyboardConsiderView(child, coordinateSpace, depth + 1, bestRect, bestArea, bestName);
    }
}

static NSArray<UIWindow *> *TOWXKeyboardAllWindows(void) {
    NSMutableOrderedSet<UIWindow *> *windows = [NSMutableOrderedSet orderedSet];
    UIApplication *app = UIApplication.sharedApplication;
    for (UIWindow *window in app.windows ?: @[]) if (window) [windows addObject:window];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) if (window) [windows addObject:window];
    }
    return windows.array;
}

void TOWXV11KeyboardRefresh(const char *reason) {
    if (!NSThread.isMainThread) {
        NSString *copy = reason ? [NSString stringWithUTF8String:reason] : @"refresh";
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardRefresh(copy.UTF8String); });
        return;
    }

    /* A valid UIKit keyboard notification is authoritative while it is visible. */
    if (gKeyboardNotificationVisible && TOWXKeyboardRectVisibleOnScreen(gKeyboardNotificationFrame)) {
        NSString *source = [NSString stringWithFormat:@"notification-latched:%s", reason ?: "refresh"];
        TOWXKeyboardSetState(YES, gKeyboardNotificationFrame, source);
        return;
    }

    id<UICoordinateSpace> coordinateSpace = TOWXKeyboardCoordinateSpace();
    if (!coordinateSpace) {
        TOWXKeyboardSetState(NO, CGRectZero, @"no-coordinate-space");
        return;
    }

    CGRect bestRect = CGRectZero;
    CGFloat bestArea = 0.0;
    NSString *bestName = nil;
    for (UIWindow *window in TOWXKeyboardAllWindows()) {
        if (window.hidden || window.alpha <= 0.02) continue;
        UIWindow *session = TOWXV11CurrentSessionWindow();
        if (session.screen && window.screen && session.screen != window.screen) continue;

        NSString *windowName = NSStringFromClass(window.class);
        if (TOWXKeyboardNameSignal(windowName)) {
            @try {
                CGRect rect = [window convertRect:window.bounds toCoordinateSpace:coordinateSpace];
                if (TOWXKeyboardRectVisibleOnScreen(rect)) {
                    CGRect inter = CGRectIntersection(rect, TOWXKeyboardScreenBounds());
                    CGFloat area = CGRectIsNull(inter) ? 0.0 : CGRectGetWidth(inter) * CGRectGetHeight(inter);
                    if (area > bestArea) {
                        bestArea = area;
                        bestRect = rect;
                        bestName = windowName;
                    }
                }
            } @catch (__unused NSException *exception) {
            }
        }
        TOWXKeyboardConsiderView(window, coordinateSpace, 0, &bestRect, &bestArea, &bestName);
    }

    NSString *source = nil;
    if (bestArea > 0.0) {
        source = [NSString stringWithFormat:@"window-scan:%s:%@", reason ?: "refresh", bestName ?: @"?"];
        TOWXKeyboardSetState(YES, bestRect, source);
    } else {
        source = [NSString stringWithFormat:@"window-scan-clear:%s", reason ?: "refresh"];
        TOWXKeyboardSetState(NO, CGRectZero, source);
    }
}

static CGRect TOWXKeyboardFrameFromNotification(NSNotification *note) {
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    return [value isKindOfClass:[NSValue class]] ? value.CGRectValue : CGRectZero;
}

static void TOWXKeyboardHandleWillShow(NSNotification *note) {
    CGRect frame = TOWXKeyboardFrameFromNotification(note);
    if (TOWXKeyboardRectVisibleOnScreen(frame)) {
        gKeyboardNotificationVisible = YES;
        gKeyboardNotificationFrame = frame;
        TOWXKeyboardSetState(YES, frame, @"UIKeyboardWillShow");
        return;
    }

    /* Never substitute the entire screen for an invalid keyboard frame. */
    gKeyboardNotificationVisible = NO;
    gKeyboardNotificationFrame = CGRectZero;
    TOWXKeyboardSetState(NO, CGRectZero, @"UIKeyboardWillShow-invalid");
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardRefresh("will-show-invalid"); });
}

static void TOWXKeyboardHandleDidShow(NSNotification *note) {
    CGRect frame = TOWXKeyboardFrameFromNotification(note);
    if (TOWXKeyboardRectVisibleOnScreen(frame)) {
        gKeyboardNotificationVisible = YES;
        gKeyboardNotificationFrame = frame;
        TOWXKeyboardSetState(YES, frame, @"UIKeyboardDidShow");
        return;
    }

    gKeyboardNotificationVisible = NO;
    gKeyboardNotificationFrame = CGRectZero;
    TOWXV11KeyboardRefresh("did-show-invalid");
}

static void TOWXKeyboardHandleFrameChange(NSNotification *note) {
    CGRect frame = TOWXKeyboardFrameFromNotification(note);
    if (TOWXKeyboardRectVisibleOnScreen(frame)) {
        gKeyboardNotificationVisible = YES;
        gKeyboardNotificationFrame = frame;
        TOWXKeyboardSetState(YES, frame, @"UIKeyboardFrameChange");
        return;
    }

    /* Frame moved off-screen or became non-keyboard-sized: clear immediately. */
    gKeyboardNotificationVisible = NO;
    gKeyboardNotificationFrame = CGRectZero;
    TOWXKeyboardSetState(NO, CGRectZero, @"UIKeyboardFrameChange-hidden");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        TOWXV11KeyboardRefresh("frame-change-hidden");
    });
}

void TOWXV11KeyboardStartObserving(void) {
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardStartObserving(); });
        return;
    }
    if (gKeyboardStarted) return;
    gKeyboardStarted = YES;

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIKeyboardWillShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        TOWXKeyboardHandleWillShow(note);
    }];
    [center addObserverForName:UIKeyboardDidShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        TOWXKeyboardHandleDidShow(note);
    }];
    [center addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        TOWXKeyboardHandleFrameChange(note);
    }];
    [center addObserverForName:UIKeyboardDidChangeFrameNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        TOWXKeyboardHandleFrameChange(note);
    }];
    [center addObserverForName:UIKeyboardDidHideNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        /* DidHide is authoritative: clear first, then use strict scan only as fallback. */
        gKeyboardNotificationVisible = NO;
        gKeyboardNotificationFrame = CGRectZero;
        TOWXKeyboardSetState(NO, CGRectZero, @"UIKeyboardDidHide");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TOWXV11KeyboardRefresh("did-hide-delayed");
        });
    }];
    [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        UIWindow *window = [note.object isKindOfClass:[UIWindow class]] ? note.object : nil;
        if (!window) return;
        NSString *name = NSStringFromClass(window.class);
        __block BOOL subtreeSignal = TOWXKeyboardNameSignal(name);
        if (!subtreeSignal) {
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
            NSUInteger visited = 0;
            while (stack.count && visited < 80 && !subtreeSignal) {
                UIView *view = stack.lastObject;
                [stack removeLastObject];
                visited += 1;
                if (TOWXKeyboardNameSignal(NSStringFromClass(view.class))) { subtreeSignal = YES; break; }
                for (UIView *child in view.subviews) [stack addObject:child];
            }
        }
        if (!subtreeSignal) return;
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardRefresh("window-visible"); });
    }];
    [center addObserverForName:UIWindowDidBecomeHiddenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (!gKeyboardVisible && !gKeyboardNotificationVisible) return;
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardRefresh("window-hidden"); });
    }];

    TOWXV11DiagLog("KEYBOARD", "LOADED|Smooth1-FIX6B|strict-geometry+fullscreen-host-reject+did-hide-reset");
    TOWXV11KeyboardRefresh("startup");
}

BOOL TOWXV11KeyboardVisible(void) { return gKeyboardVisible; }
CGRect TOWXV11KeyboardFrame(void) { return gKeyboardFrame; }
NSString *TOWXV11KeyboardSource(void) { return gKeyboardSource ?: @"none"; }
