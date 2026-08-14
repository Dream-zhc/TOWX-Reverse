#import "TOWXV11KeyboardState.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

NSNotificationName const TOWXV11KeyboardStateDidChangeNotification = @"TOWXV11KeyboardStateDidChangeNotification";

static BOOL gKeyboardStarted = NO;
static BOOL gKeyboardVisible = NO;
static CGRect gKeyboardFrame = {{0,0},{0,0}};
static NSString *gKeyboardSource = @"none";

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

static BOOL TOWXKeyboardRectVisibleOnScreen(CGRect rect) {
    if (!TOWXKeyboardFiniteRect(rect)) return NO;
    CGRect screen = TOWXKeyboardScreenBounds();
    if (!TOWXKeyboardFiniteRect(screen)) return NO;
    CGRect inter = CGRectIntersection(rect, screen);
    if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) return NO;
    CGFloat iw = CGRectGetWidth(inter), ih = CGRectGetHeight(inter);
    CGFloat screenArea = MAX(1.0, CGRectGetWidth(screen) * CGRectGetHeight(screen));
    CGFloat area = iw * ih;
    if (ih < 90.0 || iw < 120.0) return NO;
    return area / screenArea >= 0.055;
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

    TOWXV11DiagLog("KEYBOARD", "STATE|fix=6|visible=%d|source=%s|frame={{%.1f,%.1f},{%.1f,%.1f}}",
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
                                     CGFloat *bestArea) {
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
                }
            }
        } @catch (__unused NSException *exception) {
        }
    }
    for (UIView *child in view.subviews) {
        TOWXKeyboardConsiderView(child, coordinateSpace, depth + 1, bestRect, bestArea);
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

    id<UICoordinateSpace> coordinateSpace = TOWXKeyboardCoordinateSpace();
    if (!coordinateSpace) {
        TOWXKeyboardSetState(NO, CGRectZero, @"no-coordinate-space");
        return;
    }

    CGRect bestRect = CGRectZero;
    CGFloat bestArea = 0.0;
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
                    if (area > bestArea) { bestArea = area; bestRect = rect; }
                }
            } @catch (__unused NSException *exception) {
            }
        }
        TOWXKeyboardConsiderView(window, coordinateSpace, 0, &bestRect, &bestArea);
    }

    NSString *source = [NSString stringWithFormat:@"window-scan:%s", reason ?: "refresh"];
    TOWXKeyboardSetState(bestArea > 0.0, bestRect, source);
}

static CGRect TOWXKeyboardFrameFromNotification(NSNotification *note) {
    NSValue *value = note.userInfo[UIKeyboardFrameEndUserInfoKey];
    return [value isKindOfClass:[NSValue class]] ? value.CGRectValue : CGRectZero;
}

static void TOWXKeyboardHandleWillShow(NSNotification *note) {
    CGRect frame = TOWXKeyboardFrameFromNotification(note);
    if (!TOWXKeyboardRectVisibleOnScreen(frame)) frame = TOWXKeyboardScreenBounds();
    TOWXKeyboardSetState(YES, frame, @"UIKeyboardWillShow");
}

static void TOWXKeyboardHandleDidShow(NSNotification *note) {
    CGRect frame = TOWXKeyboardFrameFromNotification(note);
    if (!TOWXKeyboardRectVisibleOnScreen(frame)) {
        TOWXV11KeyboardRefresh("did-show");
        return;
    }
    TOWXKeyboardSetState(YES, frame, @"UIKeyboardDidShow");
}

static void TOWXKeyboardHandleFrameChange(NSNotification *note) {
    CGRect frame = TOWXKeyboardFrameFromNotification(note);
    if (TOWXKeyboardRectVisibleOnScreen(frame)) {
        TOWXKeyboardSetState(YES, frame, @"UIKeyboardFrameChange");
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardRefresh("frame-change"); });
    }
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
        dispatch_async(dispatch_get_main_queue(), ^{
            TOWXV11KeyboardRefresh("did-hide");
            if (!gKeyboardVisible) TOWXKeyboardSetState(NO, CGRectZero, @"UIKeyboardDidHide");
        });
    }];
    [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        UIWindow *window = [note.object isKindOfClass:[UIWindow class]] ? note.object : nil;
        NSString *name = window ? NSStringFromClass(window.class) : @"";
        if (!TOWXKeyboardNameSignal(name)) {
            __block BOOL subtreeSignal = NO;
            NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window ?: [UIView new]];
            NSUInteger visited = 0;
            while (stack.count && visited < 80 && !subtreeSignal) {
                UIView *view = stack.lastObject;
                [stack removeLastObject];
                visited += 1;
                if (TOWXKeyboardNameSignal(NSStringFromClass(view.class))) { subtreeSignal = YES; break; }
                for (UIView *child in view.subviews) [stack addObject:child];
            }
            if (!subtreeSignal) return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardRefresh("window-visible"); });
    }];
    [center addObserverForName:UIWindowDidBecomeHiddenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        if (!gKeyboardVisible) return;
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXV11KeyboardRefresh("window-hidden"); });
    }];

    TOWXV11DiagLog("KEYBOARD", "LOADED|Smooth1-FIX6|keyboard-avatar-mutual-exclusion|notifications+window-scan");
    TOWXV11KeyboardRefresh("startup");
}

BOOL TOWXV11KeyboardVisible(void) { return gKeyboardVisible; }
CGRect TOWXV11KeyboardFrame(void) { return gKeyboardFrame; }
NSString *TOWXV11KeyboardSource(void) { return gKeyboardSource ?: @"none"; }
