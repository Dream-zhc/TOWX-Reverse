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

static const char *kLogDir = "/var/mobile/TrollOpenJB";
static const char *kLogPath = "/var/mobile/TrollOpenJB/phase2a4-product.log";

static int gReadyToken = 0, gAckToken = 0, gGenerationToken = 0, gCountToken = 0, gStageToken = 0, gAckIndexToken = 0;
static dispatch_source_t gUITimer;
static uint64_t gRemoteCount = 0;
static NSString *gWeChatExportDir = nil;
static UIImage *gAvatars[TOWX_MAX_RECENTS];
static NSDate *gAvatarMtimes[TOWX_MAX_RECENTS];
static BOOL gAvatarMissLogged[TOWX_MAX_RECENTS];
static unsigned int gTick = 0;
static NSInteger gSelectedIndex = NSNotFound;

static UIView *gProductBar = nil;
static UIScrollView *gProductScroll = nil;
static UIButton *gButtons[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };
static __weak UIView *gAnchorParent = nil;
static __weak UIWindow *gAnchorWindow = nil;
static CGRect gAnchorFrameInParent, gAnchorFrameInWindow;
static CGSize gAnchorWindowSize;
static CGFloat gAnchorWindowLevel = 0.0;
static NSString *gAnchorWindowClass = nil;
static NSString *gAnchorParentClass = nil;

static void TOWXEnsureLogDir(void) { (void)mkdir(kLogDir, 0755); }

static void TOWXLog(const char *format, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char body[1100];
    va_list args;
    va_start(args, format);
    int bodyLength = vsnprintf(body, sizeof(body), format, args);
    va_end(args);
    if (bodyLength < 0) { close(fd); return; }
    char line[1280];
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

static int TOWXReadToken(int token, uint64_t *value) { return notify_get_state(token, value) == NOTIFY_STATUS_OK; }

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
    NSUInteger loaded = 0, limited = MIN((NSUInteger)TOWX_MAX_RECENTS, (NSUInteger)gRemoteCount);
    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        if (index >= limited) {
            gAvatars[index] = nil; gAvatarMtimes[index] = nil; gAvatarMissLogged[index] = NO; continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
        NSDate *mtime = attrs[NSFileModificationDate];
        if (mtime != nil && gAvatars[index] != nil && [gAvatarMtimes[index] isEqualToDate:mtime]) { loaded += 1; continue; }
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image != nil) {
            gAvatars[index] = image; gAvatarMtimes[index] = mtime; gAvatarMissLogged[index] = NO; loaded += 1;
            TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-PASS|index=%lu|path=%s|size=%.0fx%.0f", (unsigned long)index, path.UTF8String, image.size.width, image.size.height);
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
    dispatch_once(&onceToken, ^{ image = [UIImage systemImageNamed:@"person.crop.circle.fill"]; });
    return image;
}

@interface TOWXLinkTapTarget : NSObject
+ (instancetype)shared;
- (void)avatarButtonTapped:(UIButton *)button;
@end

static void TOWXLayoutProductBar(void);
static void TOWXEnsureProductBar(void);

@implementation TOWXLinkTapTarget
+ (instancetype)shared {
    static TOWXLinkTapTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [TOWXLinkTapTarget new]; });
    return target;
}
- (void)avatarButtonTapped:(UIButton *)button {
    NSUInteger index = (NSUInteger)button.tag;
    if (index >= TOWX_MAX_RECENTS || index >= gRemoteCount) return;
    gSelectedIndex = (NSInteger)index;
    char name[96];
    (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
    notify_post(name);
    TOWXLog("TOWX|SB|P2A4|TAP-SEND|index=%lu|notification=%s", (unsigned long)index, name);
    TOWXLayoutProductBar();
}
@end

static void TOWXCreateProductBar(void) {
    if (gProductBar != nil) return;
    gProductBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 360, 92)];
    gProductBar.opaque = NO;
    gProductBar.clipsToBounds = YES;
    gProductBar.userInteractionEnabled = YES;
    gProductScroll = [[UIScrollView alloc] initWithFrame:gProductBar.bounds];
    gProductScroll.backgroundColor = UIColor.clearColor;
    gProductScroll.showsHorizontalScrollIndicator = NO;
    gProductScroll.showsVerticalScrollIndicator = NO;
    gProductScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [gProductBar addSubview:gProductScroll];
    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tag = (NSInteger)index;
        button.adjustsImageWhenHighlighted = NO;
        button.backgroundColor = UIColor.tertiarySystemFillColor;
        button.clipsToBounds = YES;
        [button addTarget:[TOWXLinkTapTarget shared] action:@selector(avatarButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
        UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        imageView.tag = 0x545750;
        imageView.userInteractionEnabled = NO;
        imageView.clipsToBounds = YES;
        [button addSubview:imageView];
        [gProductScroll addSubview:button];
        gButtons[index] = button;
        TOWXLog("TOWX|SB|P2A4|BAR-BIND|position=%lu|button=%p|source=owned-product-bar", (unsigned long)index, button);
    }
    TOWXLog("TOWX|SB|P2A4|PRODUCT-BAR-CREATE|bar=%p|ownership=springboard", gProductBar);
}

static void TOWXLayoutProductBar(void) {
    if (gProductBar == nil || gProductScroll == nil) return;
    CGFloat width = CGRectGetWidth(gProductBar.bounds), height = CGRectGetHeight(gProductBar.bounds);
    if (width <= 1.0 || height <= 1.0) return;
    /* Stable native dynamic color: no UIVisualEffectView, so first frame is fully rendered. */
    gProductBar.backgroundColor = UIColor.secondarySystemBackgroundColor;
    gProductBar.layer.cornerRadius = MIN(30.0, height * 0.34);
    gProductBar.layer.borderWidth = 0.5;
    gProductBar.layer.borderColor = UIColor.separatorColor.CGColor;
    gProductBar.layer.masksToBounds = YES;
    static BOOL styledLogged = NO;
    if (!styledLogged) { styledLogged = YES; TOWXLog("TOWX|SB|P2A4|BAR-STYLE|bar=%p|mode=system-dynamic-solid", gProductBar); }

    NSUInteger count = MIN((NSUInteger)TOWX_MAX_RECENTS, (NSUInteger)gRemoteCount);
    gProductBar.hidden = (count == 0 || gProductBar.superview == nil || gProductBar.window == nil);
    if (count == 0) return;
    CGFloat diameter = MIN(58.0, MAX(44.0, height - 24.0));
    CGFloat spacing = 14.0;
    CGFloat totalWidth = diameter * count + spacing * (count > 0 ? count - 1 : 0);
    CGFloat left = totalWidth < width - 24.0 ? floor((width - totalWidth) * 0.5) : 12.0;
    CGFloat y = floor((height - diameter) * 0.5);
    CGFloat contentWidth = MAX(width, left * 2.0 + totalWidth);
    gProductScroll.frame = gProductBar.bounds;
    gProductScroll.contentSize = CGSizeMake(contentWidth, height);
    gProductScroll.alwaysBounceHorizontal = contentWidth > width + 1.0;

    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        UIButton *button = gButtons[index];
        BOOL available = index < count;
        button.hidden = !available;
        button.enabled = available;
        if (!available) continue;
        button.frame = CGRectMake(left + index * (diameter + spacing), y, diameter, diameter);
        button.layer.cornerRadius = diameter * 0.5;
        button.layer.borderWidth = (gSelectedIndex == (NSInteger)index) ? 2.5 : 0.8;
        button.layer.borderColor = (gSelectedIndex == (NSInteger)index ? UIColor.systemGreenColor : UIColor.separatorColor).CGColor;
        UIImageView *imageView = (UIImageView *)[button viewWithTag:0x545750];
        imageView.frame = CGRectInset(button.bounds, 3.0, 3.0);
        imageView.layer.cornerRadius = CGRectGetWidth(imageView.bounds) * 0.5;
        UIImage *avatar = gAvatars[index];
        imageView.image = avatar ?: TOWXPlaceholderImage();
        if (avatar != nil) {
            imageView.contentMode = UIViewContentModeScaleAspectFill; imageView.tintColor = nil; imageView.backgroundColor = UIColor.clearColor; imageView.alpha = 1.0;
        } else {
            imageView.contentMode = UIViewContentModeScaleAspectFit; imageView.tintColor = UIColor.tertiaryLabelColor; imageView.backgroundColor = UIColor.tertiarySystemFillColor; imageView.alpha = 0.55;
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
    if ([view isKindOfClass:[UILabel class]] && TOWXLabelLooksLikeOriginalSlot((UILabel *)view)) [labels addObject:(UILabel *)view];
    for (UIView *subview in view.subviews) TOWXCollectOriginalLabels(subview, labels);
}

static BOOL TOWXOriginalBarCandidate(UIScrollView *scroll) {
    if (scroll == gProductScroll || [scroll isDescendantOfView:gProductBar]) return NO;
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

static void TOWXAdoptOriginalBar(UIScrollView *scroll) {
    UIView *original = TOWXOriginalBarContainer(scroll);
    UIView *parent = original.superview;
    UIWindow *window = original.window ?: parent.window;
    if (parent == nil || window == nil) return;
    TOWXCreateProductBar();
    CGRect frame = original.frame;
    CGRect frameInWindow = [parent convertRect:frame toView:window];
    BOOL anchorChanged = (gAnchorParent != parent || gAnchorWindow != window || !CGRectEqualToRect(gAnchorFrameInParent, frame));
    gAnchorParent = parent;
    gAnchorWindow = window;
    gAnchorFrameInParent = frame;
    gAnchorFrameInWindow = frameInWindow;
    gAnchorWindowSize = window.bounds.size;
    gAnchorWindowLevel = window.windowLevel;
    gAnchorWindowClass = NSStringFromClass(window.class);
    gAnchorParentClass = NSStringFromClass(parent.class);

    /* TrollOpen's one-shot placeholder becomes only an anchor; our owned bar is the product UI. */
    original.hidden = YES;
    original.alpha = 0.0;
    original.userInteractionEnabled = NO;
    if (gProductBar.superview != parent) {
        [gProductBar removeFromSuperview];
        gProductBar.frame = frame;
        [parent addSubview:gProductBar];
        TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|mode=adopt-anchor|bar=%p|parent=%p|window=%p", gProductBar, parent, window);
    } else gProductBar.frame = frame;
    [parent bringSubviewToFront:gProductBar];
    if (anchorChanged) {
        TOWXLog("TOWX|SB|P2A4|BAR-ANCHOR|original=%p|parent=%p|parentClass=%s|window=%p|windowClass=%s|level=%.1f|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                original, parent, gAnchorParentClass.UTF8String ?: "?", window, gAnchorWindowClass.UTF8String ?: "?", window.windowLevel,
                frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    TOWXLayoutProductBar();
}

static BOOL TOWXScanAndAdoptOriginalBar(UIView *view) {
    if ([view isKindOfClass:[UIScrollView class]] && TOWXOriginalBarCandidate((UIScrollView *)view)) {
        TOWXAdoptOriginalBar((UIScrollView *)view);
        return YES;
    }
    for (UIView *subview in view.subviews) if (TOWXScanAndAdoptOriginalBar(subview)) return YES;
    return NO;
}

static UIWindow *TOWXFindReplacementAnchorWindow(void) {
    if (gAnchorWindowClass.length == 0) return nil;
    UIWindow *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (UIWindow *window in TOWXAllWindows()) {
        if (window.hidden || window.alpha <= 0.01 || ![NSStringFromClass(window.class) isEqualToString:gAnchorWindowClass]) continue;
        CGFloat levelDelta = fabs(window.windowLevel - gAnchorWindowLevel);
        CGFloat sizeDelta = fabs(CGRectGetWidth(window.bounds) - gAnchorWindowSize.width) + fabs(CGRectGetHeight(window.bounds) - gAnchorWindowSize.height);
        CGFloat score = levelDelta * 100.0 + sizeDelta;
        if (score < bestScore) { bestScore = score; best = window; }
    }
    return best;
}

static BOOL TOWXProductBarHasLiveAnchor(void) {
    UIWindow *window = gProductBar.window;
    return gProductBar != nil && gProductBar.superview != nil && window != nil && !window.hidden && window.alpha > 0.01;
}

static void TOWXRestoreOwnedBar(void) {
    TOWXCreateProductBar();
    UIView *parent = gAnchorParent;
    if (parent != nil && parent.window != nil && !parent.hidden && parent.alpha > 0.01) {
        if (gProductBar.superview != parent) {
            [gProductBar removeFromSuperview]; gProductBar.frame = gAnchorFrameInParent; [parent addSubview:gProductBar];
            TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|mode=remembered-parent|bar=%p|parent=%p", gProductBar, parent);
        } else gProductBar.frame = gAnchorFrameInParent;
        [parent bringSubviewToFront:gProductBar];
        TOWXLayoutProductBar();
        return;
    }

    UIWindow *window = gAnchorWindow;
    if (window == nil || window.hidden || window.alpha <= 0.01) window = TOWXFindReplacementAnchorWindow();
    if (window != nil && !window.hidden && window.alpha > 0.01) {
        if (gProductBar.superview != window) {
            [gProductBar removeFromSuperview]; gProductBar.frame = gAnchorFrameInWindow; [window addSubview:gProductBar];
            TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|mode=window-fallback|bar=%p|window=%p|class=%s", gProductBar, window, NSStringFromClass(window.class).UTF8String ?: "?");
        } else gProductBar.frame = gAnchorFrameInWindow;
        [window bringSubviewToFront:gProductBar];
        TOWXLayoutProductBar();
    } else gProductBar.hidden = YES;
}

static void TOWXEnsureProductBar(void) {
    BOOL healthy = TOWXProductBarHasLiveAnchor();
    if (!healthy || (gTick % 8U) == 0U) {
        for (UIWindow *window in TOWXAllWindows()) {
            if (window.hidden || window.alpha <= 0.01) continue;
            if (TOWXScanAndAdoptOriginalBar(window)) { healthy = YES; break; }
        }
    }
    if (!healthy) TOWXRestoreOwnedBar();
    else TOWXLayoutProductBar();
}

static void TOWXHandleReady(void) {
    uint64_t generation = 0, count = 0, stage = 0;
    if (!TOWXReadToken(gGenerationToken, &generation) || !TOWXReadToken(gCountToken, &count) || !TOWXReadToken(gStageToken, &stage)) {
        TOWXLog("TOWX|SB|P2A4|STATE-READ-FAIL"); return;
    }
    gRemoteCount = MIN((uint64_t)TOWX_MAX_RECENTS, count);
    TOWXLog("TOWX|SB|P2A4|READY-RECV|generation=%llu|stage=%llu|stageName=%s|count=%llu",
            (unsigned long long)generation, (unsigned long long)stage, TOWXStageName(stage), (unsigned long long)count);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger loaded = 0;
        if (gRemoteCount > 0 && (stage == 450 || stage == 440 || stage == 470)) loaded = TOWXLoadAvatars();
        TOWXEnsureProductBar();
        TOWXLog("TOWX|SB|P2A4|SYNC|count=%llu|loaded=%lu|bar=%s|stage=%llu",
                (unsigned long long)gRemoteCount, (unsigned long)loaded, TOWXProductBarHasLiveAnchor() ? "live" : "missing", (unsigned long long)stage);
    });
}

static void TOWXHandleAck(void) {
    uint64_t index = UINT64_MAX;
    if (TOWXReadToken(gAckIndexToken, &index)) {
        gSelectedIndex = index < TOWX_MAX_RECENTS ? (NSInteger)index : NSNotFound;
        TOWXLog("TOWX|SB|P2A4|OPEN-ACK|index=%llu", (unsigned long long)index);
        dispatch_async(dispatch_get_main_queue(), ^{ TOWXLayoutProductBar(); });
    }
}

static void TOWXScheduleLifecycleRebind(NSString *reason) {
    TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=%s", reason.UTF8String ?: "unknown");
    dispatch_async(dispatch_get_main_queue(), ^{ TOWXEnsureProductBar(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ TOWXEnsureProductBar(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ TOWXEnsureProductBar(); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 700 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ TOWXEnsureProductBar(); });
}

static void TOWXInstallLifecycleObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { TOWXScheduleLifecycleRebind(@"window-visible"); }];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { TOWXScheduleLifecycleRebind(@"scene-active"); }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { TOWXScheduleLifecycleRebind(@"app-active"); }];
}

static void TOWXStartUITimer(void) {
    gUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gUITimer == nil) return;
    dispatch_source_set_timer(gUITimer, dispatch_time(DISPATCH_TIME_NOW, 0), (uint64_t)(NSEC_PER_SEC / 4U), (uint64_t)(NSEC_PER_SEC / 40U));
    dispatch_source_set_event_handler(gUITimer, ^{
        gTick += 1;
        if (gWeChatExportDir.length == 0 && (gTick % 4U) == 0U) (void)TOWXResolveWeChatExportDir();
        if (gRemoteCount > 0 && (gTick % 2U) == 0U) (void)TOWXLoadAvatars();
        TOWXEnsureProductBar();
    });
    dispatch_resume(gUITimer);
}

__attribute__((constructor)) static void TOWXSpringBoardDataBridgeInit(void) {
    TOWXLog("TOWX|SB|P2A4|LOADED|v0.6.0|mode=owned-bar+cell-avatar-map+solid-system-bg+lifecycle");
    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) || !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) || !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) return;
    dispatch_queue_t queue = dispatch_queue_create("com.dream.towx.p2a4.receiver", DISPATCH_QUEUE_SERIAL);
    uint32_t readyStatus = notify_register_dispatch(TOWX_LINK_READY, &gReadyToken, queue, ^(int token) { (void)token; TOWXHandleReady(); });
    uint32_t ackStatus = notify_register_dispatch(TOWX_LINK_ACK, &gAckToken, queue, ^(int token) { (void)token; TOWXHandleAck(); });
    if (readyStatus == NOTIFY_STATUS_OK && ackStatus == NOTIFY_STATUS_OK) TOWXLog("TOWX|SB|P2A4|LISTENERS-READY");
    else TOWXLog("TOWX|SB|P2A4|LISTENER-FAIL|ready=%u|ack=%u", readyStatus, ackStatus);
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXInstallLifecycleObservers();
        TOWXCreateProductBar();
        TOWXEnsureProductBar();
        TOWXStartUITimer();
    });
}
