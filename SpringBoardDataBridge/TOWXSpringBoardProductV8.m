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
#define TOWX_LINK_APP_ACTIVE "com.dream.towx.link.appActive"
#define TOWX_LINK_OPEN_PREFIX "com.dream.towx.link.open."
#define TOWX_MAX_RECENTS 6U

static const char *kLogDir = "/var/mobile/TrollOpenJB";
static const char *kLogPath = "/var/mobile/TrollOpenJB/phase2a4-product.log";

static int gReadyToken = 0;
static int gAckToken = 0;
static int gGenerationToken = 0;
static int gCountToken = 0;
static int gStageToken = 0;
static int gAckIndexToken = 0;
static int gAppActiveToken = 0;
static dispatch_source_t gUITimer;

static uint64_t gRemoteCount = 0;
static uint64_t gRemoteStage = 0;
static BOOL gWeChatActive = NO;
static NSString *gWeChatExportDir = nil;
static UIImage *gAvatars[TOWX_MAX_RECENTS];
static NSDate *gAvatarMtimes[TOWX_MAX_RECENTS];
static BOOL gAvatarMissLogged[TOWX_MAX_RECENTS];
static unsigned int gTick = 0;
static NSInteger gSelectedIndex = NSNotFound;
static BOOL gTapInFlight = NO;
static BOOL gLayoutDirty = YES;

static UIView *gProductBar = nil;
static UIScrollView *gProductScroll = nil;
static UIButton *gButtons[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };

static __weak UIScrollView *gSourceScroll = nil;
static __weak UIView *gSourceParent = nil;
static __weak UIWindow *gCurrentHostWindow = nil;
static __weak UIWindow *gLastMatchingVisibleWindow = nil;
static NSString *gHostWindowClass = nil;
static CGFloat gHostWindowLevel = 0.0;
static CGRect gCalibratedBarFrameInWindow = {{0,0},{0,0}};
static CGSize gCalibratedWindowSize = {0,0};
static BOOL gHasCalibration = NO;
static NSTimeInterval gLastMatchingVisibleAt = 0.0;
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

static NSUInteger TOWXLoadAvatars(BOOL *changedOut) {
    NSString *dir = TOWXResolveWeChatExportDir();
    if (dir.length == 0 || gRemoteCount == 0) return 0;
    NSUInteger loaded = 0;
    BOOL changed = NO;
    NSUInteger limited = MIN((NSUInteger)TOWX_MAX_RECENTS, (NSUInteger)gRemoteCount);
    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        if (index >= limited) {
            if (gAvatars[index] != nil) changed = YES;
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
            changed = YES;
            TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-PASS|index=%lu|path=%s|size=%.0fx%.0f",
                    (unsigned long)index, path.UTF8String, image.size.width, image.size.height);
        } else if (!gAvatarMissLogged[index]) {
            gAvatarMissLogged[index] = YES;
            TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-MISS|index=%lu|path=%s", (unsigned long)index, path.UTF8String);
        }
    }
    if (changedOut != NULL) *changedOut = changed;
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

static BOOL TOWXWindowVisible(UIWindow *window) {
    return window != nil && !window.hidden && window.alpha > 0.01 && window.bounds.size.width > 10.0 && window.bounds.size.height > 10.0;
}

static BOOL TOWXWindowMatchesCalibration(UIWindow *window) {
    if (!gHasCalibration || !TOWXWindowVisible(window) || gHostWindowClass.length == 0) return NO;
    if (![NSStringFromClass(window.class) isEqualToString:gHostWindowClass]) return NO;
    if (fabs(window.windowLevel - gHostWindowLevel) > 1.0) return NO;
    CGSize size = window.bounds.size;
    CGFloat direct = fabs(size.width - gCalibratedWindowSize.width) + fabs(size.height - gCalibratedWindowSize.height);
    CGFloat rotated = fabs(size.width - gCalibratedWindowSize.height) + fabs(size.height - gCalibratedWindowSize.width);
    return MIN(direct, rotated) < 80.0;
}

static CGRect TOWXScaledCalibratedFrame(UIWindow *window) {
    if (!gHasCalibration || window == nil || gCalibratedWindowSize.width <= 1.0 || gCalibratedWindowSize.height <= 1.0) return CGRectZero;
    CGFloat sx = CGRectGetWidth(window.bounds) / gCalibratedWindowSize.width;
    CGFloat sy = CGRectGetHeight(window.bounds) / gCalibratedWindowSize.height;
    return CGRectMake(gCalibratedBarFrameInWindow.origin.x * sx,
                      gCalibratedBarFrameInWindow.origin.y * sy,
                      gCalibratedBarFrameInWindow.size.width * sx,
                      gCalibratedBarFrameInWindow.size.height * sy);
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
    if ([view isKindOfClass:[UILabel class]] && TOWXLabelLooksLikeOriginalSlot((UILabel *)view)) [labels addObject:(UILabel *)view];
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

static void TOWXSuppressOriginalScroll(UIScrollView *scroll) {
    if (scroll == nil) return;
    scroll.backgroundColor = UIColor.clearColor;
    scroll.layer.backgroundColor = UIColor.clearColor.CGColor;
    scroll.layer.borderWidth = 0.0;
    scroll.scrollEnabled = NO;
    scroll.userInteractionEnabled = NO;
    scroll.panGestureRecognizer.enabled = NO;
    for (UIView *subview in scroll.subviews) {
        subview.hidden = YES;
        subview.alpha = 0.0;
        subview.userInteractionEnabled = NO;
    }
}

@interface TOWXV8TapTarget : NSObject
+ (instancetype)shared;
- (void)avatarTapped:(UIButton *)button;
@end

static void TOWXLayoutProductBar(BOOL force);
static void TOWXEnsureProductBar(BOOL forceScan);
static void TOWXDetachProductBar(const char *reason);

static void TOWXCreateProductBar(void) {
    if (gProductBar != nil) return;
    gProductBar = [[UIView alloc] initWithFrame:CGRectZero];
    gProductBar.backgroundColor = UIColor.clearColor;
    gProductBar.layer.backgroundColor = UIColor.clearColor.CGColor;
    gProductBar.opaque = NO;
    gProductBar.clipsToBounds = NO;
    gProductBar.userInteractionEnabled = NO;

    gProductScroll = [[UIScrollView alloc] initWithFrame:CGRectZero];
    gProductScroll.backgroundColor = UIColor.clearColor;
    gProductScroll.opaque = NO;
    gProductScroll.clipsToBounds = YES;
    gProductScroll.showsHorizontalScrollIndicator = NO;
    gProductScroll.showsVerticalScrollIndicator = NO;
    gProductScroll.scrollEnabled = YES;
    gProductScroll.directionalLockEnabled = YES;
    gProductScroll.delaysContentTouches = NO;
    gProductScroll.canCancelContentTouches = YES;
    gProductScroll.bounces = YES;
    gProductScroll.decelerationRate = UIScrollViewDecelerationRateFast;
    gProductScroll.userInteractionEnabled = YES;
    [gProductBar addSubview:gProductScroll];

    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = (NSInteger)index;
        button.adjustsImageWhenHighlighted = NO;
        button.clipsToBounds = YES;
        button.backgroundColor = [UIColor colorWithWhite:0.42 alpha:0.13];
        [button addTarget:[TOWXV8TapTarget shared] action:@selector(avatarTapped:) forControlEvents:UIControlEventTouchUpInside];

        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.tag = 0x545750;
        imageView.userInteractionEnabled = NO;
        imageView.clipsToBounds = YES;
        [button addSubview:imageView];
        [gProductScroll addSubview:button];
        gButtons[index] = button;
        TOWXLog("TOWX|SB|P2A4|BAR-BIND|position=%lu|button=%p|source=v8-owned-scroll", (unsigned long)index, button);
    }
    TOWXLog("TOWX|SB|P2A4|PRODUCT-BAR-CREATE|bar=%p|ownership=springboard|touch=exclusive-product-scroll", gProductBar);
    TOWXLog("TOWX|SB|P2A4|TOUCH-OWNERSHIP|sourceScrollPan=disabled|productScroll=enabled");
}

static BOOL TOWXProductHostIsLive(void) {
    UIWindow *window = gCurrentHostWindow;
    return gProductBar != nil && gProductBar.superview != nil && TOWXWindowVisible(window) && gProductBar.window == window;
}

static void TOWXSetProductBarVisible(BOOL visible, const char *reason) {
    if (gProductBar == nil) return;
    BOOL shouldShow = visible && gWeChatActive && gRemoteCount > 0 && TOWXProductHostIsLive();
    gProductBar.hidden = !shouldShow;
    gProductBar.userInteractionEnabled = shouldShow;
    gProductScroll.userInteractionEnabled = shouldShow;
    if (gBarVisibleState != shouldShow) {
        gBarVisibleState = shouldShow;
        TOWXLog("TOWX|SB|P2A4|BAR-%s|reason=%s|window=%p|count=%llu|active=%d",
                shouldShow ? "SHOW" : "HIDE", reason ?: "unknown", gCurrentHostWindow,
                (unsigned long long)gRemoteCount, gWeChatActive ? 1 : 0);
    }
}

static void TOWXAttachProductBar(UIView *parent, CGRect frame, UIWindow *window, const char *mode) {
    if (parent == nil || window == nil || !TOWXWindowVisible(window)) return;
    TOWXCreateProductBar();
    BOOL moved = gProductBar.superview != parent || gCurrentHostWindow != window;
    if (moved) {
        [gProductBar removeFromSuperview];
        gProductBar.frame = frame;
        [parent addSubview:gProductBar];
        gCurrentHostWindow = window;
        TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|mode=%s|bar=%p|parent=%p|window=%p|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                mode ?: "unknown", gProductBar, parent, window,
                frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    } else if (!CGRectEqualToRect(gProductBar.frame, frame)) {
        gProductBar.frame = frame;
        gLayoutDirty = YES;
    }
    [parent bringSubviewToFront:gProductBar];
    gLayoutDirty = YES;
    TOWXLayoutProductBar(NO);
}

static void TOWXDetachProductBar(const char *reason) {
    if (gProductBar == nil) return;
    TOWXSetProductBarVisible(NO, reason);
    if (gProductBar.superview != nil) {
        [gProductBar removeFromSuperview];
        TOWXLog("TOWX|SB|P2A4|BAR-DETACH|reason=%s", reason ?: "unknown");
    }
    gCurrentHostWindow = nil;
}

static void TOWXLayoutProductBar(BOOL force) {
    if (gProductBar == nil || gProductScroll == nil || !TOWXProductHostIsLive()) return;
    if (!force && !gLayoutDirty && (gProductScroll.dragging || gProductScroll.decelerating)) return;
    if (!force && (gProductScroll.dragging || gProductScroll.decelerating)) return;

    gProductBar.backgroundColor = UIColor.clearColor;
    gProductBar.layer.backgroundColor = UIColor.clearColor.CGColor;
    gProductBar.layer.borderWidth = 0.0;
    gProductBar.layer.cornerRadius = 0.0;
    gProductScroll.frame = gProductBar.bounds;

    NSUInteger count = MIN((NSUInteger)TOWX_MAX_RECENTS, (NSUInteger)gRemoteCount);
    TOWXSetProductBarVisible(count > 0, count > 0 ? "host-live" : "count-zero");
    if (count == 0) return;

    CGFloat width = CGRectGetWidth(gProductBar.bounds);
    CGFloat height = CGRectGetHeight(gProductBar.bounds);
    if (width <= 1.0 || height <= 1.0) return;

    CGFloat diameter = MIN(52.0, MAX(42.0, height - 10.0));
    CGFloat spacing = 8.0;
    CGFloat totalWidth = diameter * count + spacing * (count > 0 ? count - 1 : 0);
    CGFloat contentWidth = MAX(width, totalWidth + 16.0);
    CGFloat left = totalWidth <= width - 16.0 ? floor((width - totalWidth) * 0.5) : 8.0;
    CGFloat y = floor((height - diameter) * 0.5);

    gProductScroll.contentSize = CGSizeMake(contentWidth, height);
    gProductScroll.alwaysBounceHorizontal = contentWidth > width + 1.0;
    if (!gProductScroll.dragging && !gProductScroll.decelerating) {
        CGFloat maxOffset = MAX(0.0, contentWidth - width);
        if (gProductScroll.contentOffset.x > maxOffset) gProductScroll.contentOffset = CGPointMake(maxOffset, 0);
    }

    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        UIButton *button = gButtons[index];
        BOOL available = index < count;
        button.hidden = !available;
        button.enabled = available && !gTapInFlight;
        if (!available) continue;

        button.frame = CGRectMake(left + index * (diameter + spacing), y, diameter, diameter);
        button.layer.cornerRadius = diameter * 0.5;
        button.layer.borderWidth = (gSelectedIndex == (NSInteger)index) ? 2.2 : 0.8;
        button.layer.borderColor = (gSelectedIndex == (NSInteger)index
                                    ? UIColor.systemGreenColor
                                    : [UIColor colorWithWhite:0.68 alpha:0.55]).CGColor;
        button.backgroundColor = [UIColor colorWithWhite:0.42 alpha:0.13];

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
            imageView.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.10];
            imageView.alpha = 0.55;
        }
    }

    static BOOL styleLogged = NO;
    if (!styleLogged) {
        styleLogged = YES;
        TOWXLog("TOWX|SB|P2A4|BAR-STYLE|bar=%p|mode=transparent+subtle-gray-avatar-backs", gProductBar);
    }
    gLayoutDirty = NO;
}

@implementation TOWXV8TapTarget
+ (instancetype)shared {
    static TOWXV8TapTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [TOWXV8TapTarget new]; });
    return target;
}

- (void)avatarTapped:(UIButton *)button {
    if (!gBarVisibleState || !gWeChatActive || !TOWXProductHostIsLive()) return;
    if (gProductScroll.dragging || gProductScroll.decelerating) return;
    NSUInteger index = (NSUInteger)button.tag;
    NSUInteger count = MIN((NSUInteger)TOWX_MAX_RECENTS, (NSUInteger)gRemoteCount);
    if (index >= count) return;
    if (gTapInFlight) {
        TOWXLog("TOWX|SB|P2A4|TAP-DEBOUNCE|index=%lu", (unsigned long)index);
        return;
    }

    gTapInFlight = YES;
    gLayoutDirty = YES;
    char name[96];
    (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
    notify_post(name);
    TOWXLog("TOWX|SB|P2A4|TAP-SEND|index=%lu|notification=%s", (unsigned long)index, name);
    TOWXLayoutProductBar(NO);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(600 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (!gTapInFlight) return;
        gTapInFlight = NO;
        gLayoutDirty = YES;
        TOWXLog("TOWX|SB|P2A4|TAP-TIMEOUT|index=%lu", (unsigned long)index);
        TOWXLayoutProductBar(NO);
    });
}
@end

static BOOL TOWXCalibrateFromOriginalScroll(UIScrollView *scroll) {
    if (!TOWXOriginalBarCandidate(scroll) || scroll.window == nil) return NO;
    UIWindow *window = scroll.window;
    UIView *parent = scroll.superview ?: window;
    CGRect frameInWindow = [scroll convertRect:scroll.bounds toView:window];
    CGRect frameInParent = parent == window ? frameInWindow : [parent convertRect:frameInWindow fromView:window];
    if (frameInWindow.size.width < 160.0 || frameInWindow.size.height < 40.0) return NO;

    gSourceScroll = scroll;
    gSourceParent = parent;
    gCurrentHostWindow = window;
    gLastMatchingVisibleWindow = window;
    gLastMatchingVisibleAt = [NSDate timeIntervalSinceReferenceDate];
    gHostWindowClass = [NSStringFromClass(window.class) copy];
    gHostWindowLevel = window.windowLevel;
    gCalibratedBarFrameInWindow = frameInWindow;
    gCalibratedWindowSize = window.bounds.size;
    gHasCalibration = YES;

    TOWXSuppressOriginalScroll(scroll);
    TOWXAttachProductBar(parent, frameInParent, window, "sibling-anchor");
    TOWXLog("TOWX|SB|P2A4|BAR-CALIBRATE|scroll=%p|parent=%p|window=%p|windowClass=%s|level=%.1f|frameInWindow={{%.1f,%.1f},{%.1f,%.1f}}",
            scroll, parent, window, gHostWindowClass.UTF8String ?: "?", window.windowLevel,
            frameInWindow.origin.x, frameInWindow.origin.y, frameInWindow.size.width, frameInWindow.size.height);
    return YES;
}

static BOOL TOWXScanOriginalBarInView(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]] && TOWXOriginalBarCandidate((UIScrollView *)view)) {
        if (TOWXCalibrateFromOriginalScroll((UIScrollView *)view)) return YES;
    }
    for (UIView *subview in view.subviews) {
        if (TOWXScanOriginalBarInView(subview)) return YES;
    }
    return NO;
}

static BOOL TOWXScanForOriginalBar(void) {
    for (UIWindow *window in TOWXAllWindows()) {
        if (!TOWXWindowVisible(window)) continue;
        if (gHasCalibration && !TOWXWindowMatchesCalibration(window)) continue;
        if (TOWXScanOriginalBarInView(window)) return YES;
    }
    return NO;
}

static BOOL TOWXRestoreCalibratedWindow(UIWindow *window, const char *reason) {
    if (!gHasCalibration || !gWeChatActive || !TOWXWindowMatchesCalibration(window)) return NO;
    CGRect frame = TOWXScaledCalibratedFrame(window);
    if (CGRectGetWidth(frame) < 160.0 || CGRectGetHeight(frame) < 40.0) return NO;
    gLastMatchingVisibleWindow = window;
    gLastMatchingVisibleAt = [NSDate timeIntervalSinceReferenceDate];
    TOWXAttachProductBar(window, frame, window, "calibrated-window");
    TOWXLog("TOWX|SB|P2A4|CALIBRATED-RESTORE|reason=%s|window=%p|class=%s|frame={{%.1f,%.1f},{%.1f,%.1f}}",
            reason ?: "unknown", window, NSStringFromClass(window.class).UTF8String ?: "?",
            frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    return YES;
}

static UIWindow *TOWXFindMatchingVisibleWindow(void) {
    if (!gHasCalibration) return nil;
    UIWindow *best = nil;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    UIWindow *recent = gLastMatchingVisibleWindow;
    if (recent != nil && TOWXWindowMatchesCalibration(recent) && (now - gLastMatchingVisibleAt) < 8.0) return recent;
    for (UIWindow *window in TOWXAllWindows()) {
        if (TOWXWindowMatchesCalibration(window)) {
            if (best != nil) return nil;
            best = window;
        }
    }
    return best;
}

static void TOWXEnsureProductBar(BOOL forceScan) {
    if (!gWeChatActive || gRemoteCount == 0) {
        TOWXDetachProductBar(!gWeChatActive ? "wechat-inactive" : "count-zero");
        return;
    }

    UIScrollView *source = gSourceScroll;
    if (source != nil && TOWXWindowVisible(source.window) && !source.hidden && source.alpha > 0.01) {
        TOWXSuppressOriginalScroll(source);
        UIView *parent = source.superview ?: source.window;
        UIWindow *window = source.window;
        CGRect frameInWindow = [source convertRect:source.bounds toView:window];
        CGRect frameInParent = parent == window ? frameInWindow : [parent convertRect:frameInWindow fromView:window];
        TOWXAttachProductBar(parent, frameInParent, window, "sibling-live");
        TOWXLayoutProductBar(NO);
        return;
    }

    if (forceScan && TOWXScanForOriginalBar()) return;

    UIWindow *current = gCurrentHostWindow;
    if (TOWXWindowMatchesCalibration(current)) {
        if (gProductBar.superview == nil) (void)TOWXRestoreCalibratedWindow(current, "current-window");
        TOWXSetProductBarVisible(YES, "current-window-live");
        TOWXLayoutProductBar(NO);
        return;
    }

    UIWindow *candidate = TOWXFindMatchingVisibleWindow();
    if (candidate != nil && TOWXRestoreCalibratedWindow(candidate, "matching-visible-window")) return;

    TOWXDetachProductBar("no-wechat-small-window");
}

static void TOWXHandleReady(void) {
    uint64_t generation = 0, count = 0, stage = 0, active = 0;
    if (!TOWXReadToken(gGenerationToken, &generation) ||
        !TOWXReadToken(gCountToken, &count) ||
        !TOWXReadToken(gStageToken, &stage)) {
        TOWXLog("TOWX|SB|P2A4|STATE-READ-FAIL");
        return;
    }
    (void)TOWXReadToken(gAppActiveToken, &active);

    BOOL oldActive = gWeChatActive;
    uint64_t oldCount = gRemoteCount;
    gWeChatActive = active != 0;
    gRemoteCount = MIN((uint64_t)TOWX_MAX_RECENTS, count);
    gRemoteStage = stage;
    if (oldActive != gWeChatActive || oldCount != gRemoteCount) gLayoutDirty = YES;

    TOWXLog("TOWX|SB|P2A4|READY-RECV|generation=%llu|stage=%llu|stageName=%s|count=%llu|wechatActive=%d",
            (unsigned long long)generation, (unsigned long long)stage, TOWXStageName(stage),
            (unsigned long long)count, gWeChatActive ? 1 : 0);

    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL imageChanged = NO;
        NSUInteger loaded = 0;
        if (gRemoteCount > 0 && (stage == 450 || stage == 440 || stage == 470)) loaded = TOWXLoadAvatars(&imageChanged);
        if (imageChanged) gLayoutDirty = YES;
        TOWXEnsureProductBar(gWeChatActive && (!gHasCalibration || oldActive != gWeChatActive));
        TOWXLog("TOWX|SB|P2A4|SYNC|count=%llu|loaded=%lu|bar=%s|host=%s|stage=%llu|active=%d",
                (unsigned long long)gRemoteCount, (unsigned long)loaded,
                gBarVisibleState ? "visible" : "hidden",
                TOWXProductHostIsLive() ? "live" : "missing",
                (unsigned long long)stage, gWeChatActive ? 1 : 0);
    });
}

static void TOWXHandleAck(void) {
    uint64_t index = UINT64_MAX;
    if (!TOWXReadToken(gAckIndexToken, &index)) return;
    gTapInFlight = NO;
    gSelectedIndex = index < TOWX_MAX_RECENTS ? (NSInteger)index : NSNotFound;
    gLayoutDirty = YES;
    TOWXLog("TOWX|SB|P2A4|OPEN-ACK|index=%llu", (unsigned long long)index);
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXLayoutProductBar(NO); });
}

static void TOWXHandleWindowVisible(UIWindow *window) {
    TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=window-visible|window=%p|class=%s|level=%.1f",
            window, window != nil ? NSStringFromClass(window.class).UTF8String : "nil", window != nil ? window.windowLevel : 0.0);
    if (window == nil) return;

    if (gHasCalibration && TOWXWindowMatchesCalibration(window)) {
        gLastMatchingVisibleWindow = window;
        gLastMatchingVisibleAt = [NSDate timeIntervalSinceReferenceDate];
        TOWXLog("TOWX|SB|P2A4|WINDOW-CANDIDATE|window=%p|class=%s|active=%d",
                window, NSStringFromClass(window.class).UTF8String ?: "?", gWeChatActive ? 1 : 0);
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(80 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        if (TOWXScanOriginalBarInView(window)) return;
        if (gWeChatActive && gHasCalibration && TOWXWindowMatchesCalibration(window)) {
            (void)TOWXRestoreCalibratedWindow(window, "window-visible");
        }
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(260 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        TOWXEnsureProductBar(NO);
    });
}

static void TOWXHandleWindowHidden(UIWindow *window) {
    TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=window-hidden|window=%p|class=%s",
            window, window != nil ? NSStringFromClass(window.class).UTF8String : "nil");
    if (window == nil) return;
    if (window == gCurrentHostWindow || gProductBar.window == window) {
        TOWXDetachProductBar("host-window-hidden");
    }
    if (window == gLastMatchingVisibleWindow) {
        gLastMatchingVisibleWindow = nil;
        gLastMatchingVisibleAt = 0.0;
    }
}

static void TOWXInstallLifecycleObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        TOWXHandleWindowVisible([note.object isKindOfClass:[UIWindow class]] ? (UIWindow *)note.object : nil);
    }];
    [center addObserverForName:UIWindowDidBecomeHiddenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        TOWXHandleWindowHidden([note.object isKindOfClass:[UIWindow class]] ? (UIWindow *)note.object : nil);
    }];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=scene-active");
        TOWXEnsureProductBar(NO);
    }];
    [center addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=scene-deactivate");
    }];
}

static void TOWXStartUITimer(void) {
    gUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gUITimer == nil) return;
    dispatch_source_set_timer(gUITimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 5U),
                              (uint64_t)(NSEC_PER_SEC / 50U));
    dispatch_source_set_event_handler(gUITimer, ^{
        gTick += 1;
        if (gWeChatExportDir.length == 0 && (gTick % 5U) == 0U) (void)TOWXResolveWeChatExportDir();
        if (gRemoteCount > 0 && (gTick % 10U) == 0U) {
            BOOL changed = NO;
            (void)TOWXLoadAvatars(&changed);
            if (changed) gLayoutDirty = YES;
        }
        if (!gProductScroll.dragging && !gProductScroll.decelerating) TOWXEnsureProductBar((gTick % 15U) == 0U && !gHasCalibration);
        else if (!gWeChatActive || !TOWXProductHostIsLive()) TOWXDetachProductBar("drag-host-lost");
    });
    dispatch_resume(gUITimer);
}

__attribute__((constructor)) static void TOWXSpringBoardDataBridgeInit(void) {
    TOWXLog("TOWX|SB|P2A4|LOADED|v0.8.0|mode=sibling-scroll+calibrated-second-open+wechat-active-gate+transparent");
    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken) ||
        !TOWXRegisterState(TOWX_LINK_APP_ACTIVE, &gAppActiveToken)) return;

    dispatch_queue_t queue = dispatch_queue_create("com.dream.towx.p2a4.receiver.v8", DISPATCH_QUEUE_SERIAL);
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
