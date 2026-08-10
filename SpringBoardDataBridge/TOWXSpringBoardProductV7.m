#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <math.h>
#include <notify.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#define TOWX_LINK_READY "com.dream.towx.link.ready"
#define TOWX_LINK_ACK "com.dream.towx.link.openAck"
#define TOWX_LINK_GENERATION "com.dream.towx.link.generation"
#define TOWX_LINK_COUNT "com.dream.towx.link.count"
#define TOWX_LINK_STAGE "com.dream.towx.link.stage"
#define TOWX_LINK_ACK_INDEX "com.dream.towx.link.ackIndex"
#define TOWX_LINK_OPEN_PREFIX "com.dream.towx.link.open."
#define TOWX_MAX_RECENTS 6U
#define TOWX_VISIBLE_SLOTS 5U

static const char *kLogDir = "/var/mobile/TrollOpenJB";
static const char *kLogPath = "/var/mobile/TrollOpenJB/phase2a4-product.log";

static int gReadyToken = 0;
static int gAckToken = 0;
static int gGenerationToken = 0;
static int gCountToken = 0;
static int gStageToken = 0;
static int gAckIndexToken = 0;
static dispatch_source_t gUITimer;

static uint64_t gRemoteCount = 0;
static NSString *gWeChatExportDir = nil;
static UIImage *gAvatars[TOWX_MAX_RECENTS];
static NSDate *gAvatarMtimes[TOWX_MAX_RECENTS];
static BOOL gAvatarMissLogged[TOWX_MAX_RECENTS];
static unsigned int gTick = 0;
static NSInteger gSelectedIndex = NSNotFound;
static BOOL gTapInFlight = NO;

static UIView *gProductBar = nil;
static UIScrollView *gProductScroll = nil;
static UIButton *gButtons[TOWX_VISIBLE_SLOTS] = { nil, nil, nil, nil, nil };
static __weak UIView *gAnchorContainer = nil;
static __weak UIScrollView *gAnchorOriginalScroll = nil;
static __weak UIWindow *gAnchorWindow = nil;
static NSString *gAnchorWindowClass = nil;
static BOOL gBarVisibleState = NO;

static void TOWXEnsureLogDir(void) {
    (void)mkdir(kLogDir, 0755);
}

static void TOWXLog(const char *format, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char body[1200];
    va_list args;
    va_start(args, format);
    int bodyLength = vsnprintf(body, sizeof(body), format, args);
    va_end(args);
    if (bodyLength < 0) {
        close(fd);
        return;
    }
    char line[1400];
    int lineLength = snprintf(line, sizeof(line), "%lld %s\n", (long long)time(NULL), body);
    if (lineLength > 0) {
        size_t toWrite = MIN((size_t)lineLength, sizeof(line));
        (void)write(fd, line, toWrite);
    }
    close(fd);
}

static const char *TOWXStageName(uint64_t stage) {
    switch (stage) {
        case 410: return "GOLDEN-MISSING";
        case 420: return "GOLDEN-FOUND";
        case 430: return "CACHE-WAIT";
        case 440: return "AVATAR-WAIT";
        case 450: return "SNAPSHOT-READY";
        case 470: return "SNAPSHOT-HOLD";
        case 490: return "CACHE-BAD";
        default: return "UNKNOWN";
    }
}

static int TOWXRegisterState(const char *name, int *token) {
    uint32_t status = notify_register_check(name, token);
    if (status != NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|SB|P2A4|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
        return 0;
    }
    return 1;
}

static int TOWXReadToken(int token, uint64_t *value) {
    return notify_get_state(token, value) == NOTIFY_STATUS_OK;
}

static NSArray<UIWindow *> *TOWXAllWindows(void) {
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *window in application.windows ?: @[]) [set addObject:window];
    for (UIScene *scene in application.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows ?: @[]) [set addObject:window];
    }
    return set.array;
}

static NSString *TOWXResolveViaLaunchServices(void) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL appSel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass == Nil || ![(id)proxyClass respondsToSelector:appSel]) return nil;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, appSel, @"com.tencent.xin");
    SEL dataSel = NSSelectorFromString(@"dataContainerURL");
    if (proxy == nil || ![proxy respondsToSelector:dataSel]) return nil;
    NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, dataSel);
    if (![url isKindOfClass:[NSURL class]]) return nil;
    return [[[url path] stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"];
}

static NSString *TOWXResolveViaMetadata(void) {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
        NSString *container = [root stringByAppendingPathComponent:item];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([meta[@"MCMMetadataIdentifier"] isEqualToString:@"com.tencent.xin"]) {
            return [[container stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"];
        }
    }
    return nil;
}

static NSString *TOWXResolveWeChatExportDir(void) {
    if (gWeChatExportDir.length > 0 && [[NSFileManager defaultManager] fileExistsAtPath:gWeChatExportDir]) return gWeChatExportDir;
    gWeChatExportDir = nil;
    NSString *dir = TOWXResolveViaLaunchServices();
    if (dir.length == 0) dir = TOWXResolveViaMetadata();
    if (dir.length > 0) {
        gWeChatExportDir = [dir copy];
        TOWXLog("TOWX|SB|P2A4|WECHAT-DIR|path=%s", gWeChatExportDir.UTF8String);
    }
    return gWeChatExportDir;
}

static NSUInteger TOWXLoadAvatars(void) {
    NSString *dir = TOWXResolveWeChatExportDir();
    if (dir.length == 0 || gRemoteCount == 0) return 0;
    NSUInteger loaded = 0;
    NSUInteger limited = MIN((NSUInteger)TOWX_MAX_RECENTS, (NSUInteger)gRemoteCount);
    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        if (index >= limited) {
            gAvatars[index] = nil;
            gAvatarMtimes[index] = nil;
            gAvatarMissLogged[index] = NO;
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        if (mtime != nil && gAvatars[index] != nil && [gAvatarMtimes[index] isEqualToDate:mtime]) {
            loaded += 1;
            continue;
        }
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image != nil) {
            gAvatars[index] = image;
            gAvatarMtimes[index] = mtime;
            gAvatarMissLogged[index] = NO;
            loaded += 1;
            TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-PASS|index=%lu|path=%s|size=%.0fx%.0f",
                    (unsigned long)index, path.UTF8String, image.size.width, image.size.height);
        } else if (!gAvatarMissLogged[index]) {
            gAvatarMissLogged[index] = YES;
            TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-MISS|index=%lu|path=%s", (unsigned long)index, path.UTF8String);
        }
    }
    return loaded;
}

static UIImage *TOWXPlaceholderImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    });
    return image;
}

static BOOL TOWXViewHierarchyVisible(UIView *view) {
    if (view == nil || view.window == nil || view.hidden || view.alpha <= 0.01) return NO;
    UIWindow *window = view.window;
    if (window.hidden || window.alpha <= 0.01) return NO;
    UIView *cursor = view.superview;
    while (cursor != nil && cursor != window) {
        if (cursor.hidden || cursor.alpha <= 0.01) return NO;
        cursor = cursor.superview;
    }
    CGRect frameInWindow = [view convertRect:view.bounds toView:window];
    CGRect intersection = CGRectIntersection(frameInWindow, window.bounds);
    if (CGRectIsNull(intersection) || CGRectIsEmpty(intersection)) return NO;
    return CGRectGetWidth(intersection) >= 24.0 && CGRectGetHeight(intersection) >= 24.0;
}

static BOOL TOWXAnchorIsVisible(void) {
    UIView *anchor = gAnchorContainer;
    if (anchor == nil || !TOWXViewHierarchyVisible(anchor)) return NO;
    if (gProductBar == nil || gProductBar.superview != anchor) return NO;
    return YES;
}

static void TOWXSetProductBarVisible(BOOL visible, const char *reason) {
    if (gProductBar == nil) return;
    BOOL shouldShow = visible && gRemoteCount > 0;
    gProductBar.hidden = !shouldShow;
    gProductBar.userInteractionEnabled = shouldShow && !gTapInFlight;
    if (gBarVisibleState != shouldShow) {
        gBarVisibleState = shouldShow;
        TOWXLog("TOWX|SB|P2A4|BAR-%s|reason=%s|anchor=%p|window=%p|count=%llu",
                shouldShow ? "SHOW" : "HIDE",
                reason ?: "unknown",
                gAnchorContainer,
                gAnchorContainer.window,
                (unsigned long long)gRemoteCount);
    }
}

@interface TOWXLinkTapTarget : NSObject
+ (instancetype)shared;
- (void)avatarButtonTapped:(UIButton *)button;
@end

static void TOWXLayoutProductBar(void);
static void TOWXEnsureProductBar(BOOL forceScan);

@implementation TOWXLinkTapTarget
+ (instancetype)shared {
    static TOWXLinkTapTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [TOWXLinkTapTarget new]; });
    return target;
}

- (void)avatarButtonTapped:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (!TOWXAnchorIsVisible()) {
        TOWXSetProductBarVisible(NO, "tap-without-anchor");
        return;
    }
    NSUInteger count = MIN((NSUInteger)TOWX_VISIBLE_SLOTS, (NSUInteger)gRemoteCount);
    if (index >= count) return;
    if (gTapInFlight) {
        TOWXLog("TOWX|SB|P2A4|TAP-DEBOUNCE|index=%lu", (unsigned long)index);
        return;
    }

    gTapInFlight = YES;
    char name[96];
    (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
    notify_post(name);
    TOWXLog("TOWX|SB|P2A4|TAP-SEND|index=%lu|notification=%s", (unsigned long)index, name);
    TOWXLayoutProductBar();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(850 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (!gTapInFlight) return;
        gTapInFlight = NO;
        TOWXLog("TOWX|SB|P2A4|TAP-TIMEOUT|index=%lu", (unsigned long)index);
        TOWXLayoutProductBar();
    });
}
@end

static void TOWXCreateProductBar(void) {
    if (gProductBar != nil) return;
    gProductBar = [[UIView alloc] initWithFrame:CGRectZero];
    gProductBar.backgroundColor = UIColor.clearColor;
    gProductBar.opaque = NO;
    gProductBar.clipsToBounds = NO;
    gProductBar.userInteractionEnabled = NO;

    gProductScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    gProductScroll.backgroundColor = UIColor.clearColor;
    gProductScroll.opaque = NO;
    gProductScroll.showsHorizontalScrollIndicator = NO;
    gProductScroll.showsVerticalScrollIndicator = NO;
    gProductScroll.scrollEnabled = NO;
    gProductScroll.userInteractionEnabled = YES;
    gProductScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gProductBar addSubview:gProductScroll];

    for (NSUInteger index = 0; index < TOWX_VISIBLE_SLOTS; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = (NSInteger)index;
        button.adjustsImageWhenHighlighted = NO;
        button.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.12];
        button.clipsToBounds = YES;
        [button addTarget:[TOWXLinkTapTarget shared] action:@selector(avatarButtonTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.tag = 0x545750;
        imageView.userInteractionEnabled = NO;
        imageView.clipsToBounds = YES;
        [button addSubview:imageView];
        [gProductScroll addSubview:button];
        gButtons[index] = button;
        TOWXLog("TOWX|SB|P2A4|BAR-BIND|position=%lu|button=%p|source=anchor-child-product-bar", (unsigned long)index, button);
    }
    TOWXLog("TOWX|SB|P2A4|PRODUCT-BAR-CREATE|bar=%p|ownership=springboard|lifetime=anchor-child", gProductBar);
}

static void TOWXLayoutProductBar(void) {
    if (gProductBar == nil || gProductScroll == nil) return;
    UIView *anchor = gAnchorContainer;
    BOOL anchorVisible = TOWXAnchorIsVisible();
    if (!anchorVisible) {
        TOWXSetProductBarVisible(NO, "anchor-not-visible");
        return;
    }

    gProductBar.frame = anchor.bounds;
    gProductScroll.frame = gProductBar.bounds;
    gProductBar.backgroundColor = UIColor.clearColor;
    gProductBar.layer.backgroundColor = UIColor.clearColor.CGColor;
    gProductBar.layer.borderWidth = 0.0;
    gProductBar.layer.cornerRadius = 0.0;
    gProductBar.layer.masksToBounds = NO;

    static BOOL styleLogged = NO;
    if (!styleLogged) {
        styleLogged = YES;
        TOWXLog("TOWX|SB|P2A4|BAR-STYLE|bar=%p|mode=transparent-anchor-child", gProductBar);
    }

    NSUInteger count = MIN((NSUInteger)TOWX_VISIBLE_SLOTS, (NSUInteger)gRemoteCount);
    TOWXSetProductBarVisible(count > 0, count > 0 ? "anchor-visible" : "count-zero");
    if (count == 0) return;

    CGFloat width = CGRectGetWidth(gProductBar.bounds);
    CGFloat height = CGRectGetHeight(gProductBar.bounds);
    if (width <= 1.0 || height <= 1.0) return;

    CGFloat spacing = 8.0;
    CGFloat maxDiameterByWidth = floor((width - 16.0 - spacing * (count > 0 ? count - 1 : 0)) / MAX((CGFloat)count, 1.0));
    CGFloat diameter = MIN(52.0, MIN(height - 10.0, maxDiameterByWidth));
    diameter = MAX(40.0, diameter);
    CGFloat totalWidth = diameter * count + spacing * (count > 0 ? count - 1 : 0);
    CGFloat left = floor((width - totalWidth) * 0.5);
    CGFloat y = floor((height - diameter) * 0.5);
    gProductScroll.contentSize = CGSizeMake(width, height);

    for (NSUInteger index = 0; index < TOWX_VISIBLE_SLOTS; index++) {
        UIButton *button = gButtons[index];
        BOOL available = index < count;
        button.hidden = !available;
        button.enabled = available && !gTapInFlight && anchorVisible;
        if (!available) continue;

        button.frame = CGRectMake(left + index * (diameter + spacing), y, diameter, diameter);
        button.layer.cornerRadius = diameter * 0.5;
        button.layer.borderWidth = (gSelectedIndex == (NSInteger)index) ? 2.2 : 0.8;
        button.layer.borderColor = (gSelectedIndex == (NSInteger)index
                                    ? UIColor.systemGreenColor
                                    : [UIColor colorWithWhite:0.65 alpha:0.55]).CGColor;
        button.backgroundColor = [UIColor colorWithWhite:0.35 alpha:0.10];

        UIImageView *imageView = (UIImageView *)[button viewWithTag:0x545750];
        imageView.frame = CGRectInset(button.bounds, 2.0, 2.0);
        imageView.layer.cornerRadius = CGRectGetWidth(imageView.bounds) * 0.5;
        UIImage *avatar = gAvatars[index];
        imageView.image = avatar ?: TOWXPlaceholderImage();
        if (avatar != nil) {
            imageView.contentMode = UIViewContentModeScaleAspectFill;
            imageView.tintColor = nil;
            imageView.backgroundColor = UIColor.clearColor;
            imageView.alpha = 1.0;
        } else {
            imageView.contentMode = UIViewContentModeScaleAspectFit;
            imageView.tintColor = UIColor.tertiaryLabelColor;
            imageView.backgroundColor = [UIColor colorWithWhite:0.5 alpha:0.10];
            imageView.alpha = 0.55;
        }
    }
}

static BOOL TOWXLabelLooksLikeOriginalSlot(UILabel *label) {
    CGFloat width = CGRectGetWidth(label.bounds), height = CGRectGetHeight(label.bounds);
    if (width < 32.0 || width > 96.0 || height < 32.0 || height > 96.0 || fabs(width - height) > 20.0) return NO;
    NSString *text = label.text;
    if (text.length != 1) return NO;
    unichar c = [text characterAtIndex:0];
    return c >= 'A' && c <= 'Z';
}

static void TOWXCollectOriginalLabels(UIView *view, NSMutableArray<UILabel *> *labels) {
    if ([view isKindOfClass:[UILabel class]] && TOWXLabelLooksLikeOriginalSlot((UILabel *)view)) {
        [labels addObject:(UILabel *)view];
    }
    for (UIView *subview in view.subviews) TOWXCollectOriginalLabels(subview, labels);
}

static BOOL TOWXOriginalBarCandidate(UIScrollView *scroll) {
    if (scroll == nil || scroll == gProductScroll || [scroll isDescendantOfView:gProductBar]) return NO;
    CGFloat width = CGRectGetWidth(scroll.bounds), height = CGRectGetHeight(scroll.bounds);
    if (width < 160.0 || height < 40.0 || height > 135.0) return NO;
    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    TOWXCollectOriginalLabels(scroll, labels);
    return labels.count >= 3 && labels.count <= 12;
}

static UIView *TOWXOriginalBarContainer(UIScrollView *scroll) {
    UIView *parent = scroll.superview;
    if (parent == nil) return scroll;
    CGFloat width = CGRectGetWidth(parent.bounds), height = CGRectGetHeight(parent.bounds);
    return (width >= 160.0 && height >= 42.0 && height <= 145.0) ? parent : scroll;
}

static void TOWXSuppressOriginalPlaceholderSubviews(UIView *container) {
    if (container == nil) return;
    container.backgroundColor = UIColor.clearColor;
    container.layer.backgroundColor = UIColor.clearColor.CGColor;
    container.layer.borderWidth = 0.0;
    container.userInteractionEnabled = YES;
    for (UIView *subview in container.subviews) {
        if (subview == gProductBar) continue;
        subview.hidden = YES;
        subview.alpha = 0.0;
        subview.userInteractionEnabled = NO;
    }
}

static BOOL TOWXTryAdoptOriginalBar(UIScrollView *scroll) {
    UIView *container = TOWXOriginalBarContainer(scroll);
    UIWindow *window = container.window;
    if (container == nil || window == nil || !TOWXViewHierarchyVisible(container)) return NO;

    if (gAnchorWindowClass.length > 0 && ![NSStringFromClass(window.class) isEqualToString:gAnchorWindowClass]) return NO;

    TOWXCreateProductBar();
    BOOL changed = (gAnchorContainer != container || gAnchorWindow != window || gProductBar.superview != container);
    gAnchorContainer = container;
    gAnchorOriginalScroll = scroll;
    gAnchorWindow = window;
    if (gAnchorWindowClass.length == 0) gAnchorWindowClass = [NSStringFromClass(window.class) copy];

    TOWXSuppressOriginalPlaceholderSubviews(container);
    if (gProductBar.superview != container) {
        [gProductBar removeFromSuperview];
        gProductBar.frame = container.bounds;
        gProductBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [container addSubview:gProductBar];
        TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|mode=anchor-child|bar=%p|container=%p|window=%p",
                gProductBar, container, window);
    }
    [container bringSubviewToFront:gProductBar];

    if (changed) {
        TOWXLog("TOWX|SB|P2A4|BAR-ANCHOR|container=%p|scroll=%p|window=%p|windowClass=%s|level=%.1f|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                container,
                scroll,
                window,
                NSStringFromClass(window.class).UTF8String ?: "?",
                window.windowLevel,
                container.frame.origin.x,
                container.frame.origin.y,
                container.frame.size.width,
                container.frame.size.height);
    }
    TOWXLayoutProductBar();
    return YES;
}

static BOOL TOWXScanAndAdoptOriginalBar(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]] && TOWXOriginalBarCandidate((UIScrollView *)view)) {
        if (TOWXTryAdoptOriginalBar((UIScrollView *)view)) return YES;
    }
    for (UIView *subview in view.subviews) {
        if (TOWXScanAndAdoptOriginalBar(subview)) return YES;
    }
    return NO;
}

static BOOL TOWXScanVisibleAnchorWindows(void) {
    for (UIWindow *window in TOWXAllWindows()) {
        if (window.hidden || window.alpha <= 0.01) continue;
        if (gAnchorWindowClass.length > 0 && ![NSStringFromClass(window.class) isEqualToString:gAnchorWindowClass]) continue;
        if (TOWXScanAndAdoptOriginalBar(window)) return YES;
    }
    return NO;
}

static void TOWXEnsureProductBar(BOOL forceScan) {
    if (TOWXAnchorIsVisible()) {
        TOWXSuppressOriginalPlaceholderSubviews(gAnchorContainer);
        TOWXLayoutProductBar();
        return;
    }

    TOWXSetProductBarVisible(NO, "no-visible-anchor");
    if (forceScan || (gTick % 5U) == 0U) {
        if (TOWXScanVisibleAnchorWindows()) return;
    }
}

static void TOWXHandleReady(void) {
    uint64_t generation = 0, count = 0, stage = 0;
    if (!TOWXReadToken(gGenerationToken, &generation) ||
        !TOWXReadToken(gCountToken, &count) ||
        !TOWXReadToken(gStageToken, &stage)) {
        TOWXLog("TOWX|SB|P2A4|STATE-READ-FAIL");
        return;
    }

    gRemoteCount = MIN((uint64_t)TOWX_MAX_RECENTS, count);
    TOWXLog("TOWX|SB|P2A4|READY-RECV|generation=%llu|stage=%llu|stageName=%s|count=%llu",
            (unsigned long long)generation,
            (unsigned long long)stage,
            TOWXStageName(stage),
            (unsigned long long)count);

    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger loaded = 0;
        if (gRemoteCount > 0 && (stage == 450 || stage == 440)) loaded = TOWXLoadAvatars();
        TOWXEnsureProductBar(NO);
        TOWXLog("TOWX|SB|P2A4|SYNC|count=%llu|loaded=%lu|bar=%s|anchor=%s|stage=%llu",
                (unsigned long long)gRemoteCount,
                (unsigned long)loaded,
                gBarVisibleState ? "visible" : "hidden",
                TOWXAnchorIsVisible() ? "visible" : "missing",
                (unsigned long long)stage);
    });
}

static void TOWXHandleAck(void) {
    uint64_t index = UINT64_MAX;
    if (!TOWXReadToken(gAckIndexToken, &index)) return;
    gTapInFlight = NO;
    gSelectedIndex = index < TOWX_VISIBLE_SLOTS ? (NSInteger)index : NSNotFound;
    TOWXLog("TOWX|SB|P2A4|OPEN-ACK|index=%llu", (unsigned long long)index);
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXLayoutProductBar();
    });
}

static void TOWXScheduleLifecycleRebind(NSString *reason) {
    TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=%s", reason.UTF8String ?: "unknown");
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXEnsureProductBar(YES); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ TOWXEnsureProductBar(YES); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(350 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ TOWXEnsureProductBar(YES); });
}

static void TOWXInstallLifecycleObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIWindowDidBecomeVisibleNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXScheduleLifecycleRebind(@"window-visible");
    }];
    [center addObserverForName:UIWindowDidBecomeHiddenNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXScheduleLifecycleRebind(@"window-hidden");
    }];
    [center addObserverForName:UISceneDidActivateNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXScheduleLifecycleRebind(@"scene-active");
    }];
    [center addObserverForName:UISceneWillDeactivateNotification
                        object:nil
                         queue:NSOperationQueue.mainQueue
                    usingBlock:^(__unused NSNotification *note) {
        TOWXScheduleLifecycleRebind(@"scene-deactivate");
    }];
}

static void TOWXStartUITimer(void) {
    gUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gUITimer == nil) return;
    dispatch_source_set_timer(gUITimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 10U),
                              (uint64_t)(NSEC_PER_SEC / 100U));
    dispatch_source_set_event_handler(gUITimer, ^{
        gTick += 1;
        if (gWeChatExportDir.length == 0 && (gTick % 10U) == 0U) (void)TOWXResolveWeChatExportDir();
        if (gRemoteCount > 0 && (gTick % 20U) == 0U) (void)TOWXLoadAvatars();
        TOWXEnsureProductBar(NO);
    });
    dispatch_resume(gUITimer);
}

__attribute__((constructor)) static void TOWXSpringBoardDataBridgeInit(void) {
    TOWXLog("TOWX|SB|P2A4|LOADED|v0.7.0|mode=anchor-child+transparent+identity-locked+no-window-fallback");
    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) return;

    dispatch_queue_t queue = dispatch_queue_create("com.dream.towx.p2a4.receiver.v7", DISPATCH_QUEUE_SERIAL);
    uint32_t readyStatus = notify_register_dispatch(TOWX_LINK_READY, &gReadyToken, queue, ^(int token) {
        (void)token;
        TOWXHandleReady();
    });
    uint32_t ackStatus = notify_register_dispatch(TOWX_LINK_ACK, &gAckToken, queue, ^(int token) {
        (void)token;
        TOWXHandleAck();
    });
    if (readyStatus == NOTIFY_STATUS_OK && ackStatus == NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|SB|P2A4|LISTENERS-READY");
    } else {
        TOWXLog("TOWX|SB|P2A4|LISTENER-FAIL|ready=%u|ack=%u", readyStatus, ackStatus);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXInstallLifecycleObservers();
        TOWXStartUITimer();
        TOWXEnsureProductBar(YES);
    });
}
