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
#define TOWX_SESSION_GATE_CLASS @"TOJBClass022"

static const char *kLogDir = "/var/mobile/TrollOpenJB";
static const char *kLogPath = "/var/mobile/TrollOpenJB/phase2a4-product.log";

static int gReadyToken = 0, gAckToken = 0, gGenerationToken = 0, gCountToken = 0;
static int gStageToken = 0, gAckIndexToken = 0, gAppActiveToken = 0;
static dispatch_source_t gUITimer;

static uint64_t gRemoteCount = 0, gRemoteStage = 0;
static BOOL gWeChatActive = NO;
static NSString *gWeChatExportDir = nil;
static UIImage *gAvatars[TOWX_MAX_RECENTS];
static NSDate *gAvatarMtimes[TOWX_MAX_RECENTS];
static NSInteger gSelectedIndex = NSNotFound;
static NSTimeInterval gLastTapAt = 0;
static BOOL gBarVisible = NO;
static BOOL gUserScrolling = NO;

static UIView *gProductBar = nil;
static UIScrollView *gProductScroll = nil;
static UIView *gSlots[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };

static __weak UIScrollView *gSourceScroll = nil;
static __weak UIWindow *gSessionWindow = nil;
static __weak UIWindow *gHostWindow = nil;
static NSString *gHostWindowClass = nil;
static CGFloat gHostWindowLevel = 0.0;
static uint64_t gSessionEpoch = 0;
static uint64_t gGeometryEpoch = 0;

/* Stable fallback is derived from a real TrollOpen bar, but anchored to the host bottom. */
static BOOL gHasStableAnchor = NO;
static CGFloat gAnchorCenterXRatio = 0.5;
static CGFloat gAnchorWidthRatio = 0.70;
static CGFloat gAnchorHeightRatio = 0.075;
static CGFloat gAnchorBottomGapRatio = 0.09;
static CGSize gAnchorWindowSize = {0,0};

static void TOWXEnsureLogDir(void) { (void)mkdir(kLogDir, 0755); }
static void TOWXLog(const char *fmt, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    char body[1200];
    va_list args;
    va_start(args, fmt);
    int n = vsnprintf(body, sizeof(body), fmt, args);
    va_end(args);
    if (n >= 0) {
        char line[1400];
        int m = snprintf(line, sizeof(line), "%lld %s\n", (long long)time(NULL), body);
        if (m > 0) (void)write(fd, line, MIN((size_t)m, sizeof(line)));
    }
    close(fd);
}

static const char *TOWXStageName(uint64_t s) {
    switch (s) {
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
static int TOWXRegisterState(const char *name, int *token) { return notify_register_check(name, token) == NOTIFY_STATUS_OK; }
static int TOWXReadState(int token, uint64_t *value) { return notify_get_state(token, value) == NOTIFY_STATUS_OK; }

static NSArray<UIWindow *> *TOWXAllWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet<UIWindow *> *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *w in app.windows ?: @[]) [set addObject:w];
    for (UIScene *scene in app.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows ?: @[]) [set addObject:w];
    }
    return set.array;
}
static BOOL TOWXWindowVisible(UIWindow *w) {
    return w != nil && !w.hidden && w.alpha > 0.01 && w.bounds.size.width > 100.0 && w.bounds.size.height > 100.0;
}
static UIWindow *TOWXVisibleSessionWindow(void) {
    UIWindow *current = gSessionWindow;
    if (TOWXWindowVisible(current) && [NSStringFromClass(current.class) isEqualToString:TOWX_SESSION_GATE_CLASS]) return current;
    for (UIWindow *w in TOWXAllWindows()) {
        if (TOWXWindowVisible(w) && [NSStringFromClass(w.class) isEqualToString:TOWX_SESSION_GATE_CLASS]) return w;
    }
    return nil;
}

static NSString *TOWXResolveExportDir(void) {
    if (gWeChatExportDir.length && [[NSFileManager defaultManager] fileExistsAtPath:gWeChatExportDir]) return gWeChatExportDir;
    gWeChatExportDir = nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL appSel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [(id)proxyClass respondsToSelector:appSel]) {
        id proxy = ((id(*)(id,SEL,id))objc_msgSend)((id)proxyClass, appSel, @"com.tencent.xin");
        SEL dataSel = NSSelectorFromString(@"dataContainerURL");
        if (proxy && [proxy respondsToSelector:dataSel]) {
            NSURL *url = ((id(*)(id,SEL))objc_msgSend)(proxy, dataSel);
            if ([url isKindOfClass:[NSURL class]]) {
                gWeChatExportDir = [[[[url path] stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"] copy];
            }
        }
    }
    if (!gWeChatExportDir.length) {
        NSString *root = @"/var/mobile/Containers/Data/Application";
        for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
            NSString *container = [root stringByAppendingPathComponent:item];
            NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
            if ([meta[@"MCMMetadataIdentifier"] isEqualToString:@"com.tencent.xin"]) {
                gWeChatExportDir = [[[[container stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"] copy] copy];
                break;
            }
        }
    }
    if (gWeChatExportDir.length) TOWXLog("TOWX|SB|P2A4|WECHAT-DIR|path=%s", gWeChatExportDir.UTF8String);
    return gWeChatExportDir;
}
static NSUInteger TOWXLoadAvatars(void) {
    NSString *dir = TOWXResolveExportDir();
    if (!dir.length || gRemoteCount == 0) return 0;
    NSUInteger loaded = 0;
    NSUInteger limit = MIN((NSUInteger)gRemoteCount, (NSUInteger)TOWX_MAX_RECENTS);
    for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
        if (i >= limit) { gAvatars[i] = nil; gAvatarMtimes[i] = nil; continue; }
        NSString *path = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png", (unsigned long)i]];
        NSDate *mtime = [[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] objectForKey:NSFileModificationDate];
        if (mtime && gAvatars[i] && [gAvatarMtimes[i] isEqualToDate:mtime]) { loaded++; continue; }
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image) {
            gAvatars[i] = image;
            gAvatarMtimes[i] = mtime;
            loaded++;
            TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-PASS|index=%lu|size=%.0fx%.0f", (unsigned long)i, image.size.width, image.size.height);
        }
    }
    return loaded;
}
static UIImage *TOWXPlaceholder(void) {
    static UIImage *img = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ img = [UIImage systemImageNamed:@"person.crop.circle.fill"]; });
    return img;
}

static BOOL TOWXLabelLooksOriginal(UILabel *label) {
    if (!label || label.text.length != 1) return NO;
    unichar c = [label.text characterAtIndex:0];
    if (c < 'A' || c > 'Z') return NO;
    CGFloat w = CGRectGetWidth(label.bounds), h = CGRectGetHeight(label.bounds);
    return w >= 30.0 && w <= 100.0 && h >= 30.0 && h <= 100.0 && fabs(w - h) < 24.0;
}
static void TOWXCollectLetters(UIView *view, NSMutableArray<UILabel *> *out) {
    if ([view isKindOfClass:[UILabel class]] && TOWXLabelLooksOriginal((UILabel *)view)) [out addObject:(UILabel *)view];
    for (UIView *v in view.subviews) TOWXCollectLetters(v, out);
}
static BOOL TOWXOriginalScrollCandidate(UIScrollView *scroll) {
    if (!scroll || scroll == gProductScroll) return NO;
    CGFloat w = CGRectGetWidth(scroll.bounds), h = CGRectGetHeight(scroll.bounds);
    if (w < 160.0 || h < 40.0 || h > 140.0) return NO;
    NSMutableArray<UILabel *> *letters = [NSMutableArray array];
    TOWXCollectLetters(scroll, letters);
    return letters.count >= 3 && letters.count <= 12;
}
static void TOWXSuppressOriginalScroll(UIScrollView *scroll) {
    if (!scroll) return;
    scroll.scrollEnabled = NO;
    scroll.userInteractionEnabled = NO;
    scroll.panGestureRecognizer.enabled = NO;
    scroll.backgroundColor = UIColor.clearColor;
    scroll.layer.backgroundColor = UIColor.clearColor.CGColor;
    scroll.hidden = YES;
    scroll.alpha = 0.0;
    for (UIView *v in scroll.subviews) {
        v.hidden = YES;
        v.alpha = 0.0;
        v.userInteractionEnabled = NO;
    }
}
static void TOWXCollectOriginalScrolls(UIView *view, NSMutableArray<UIScrollView *> *out) {
    if ([view isKindOfClass:[UIScrollView class]] && TOWXOriginalScrollCandidate((UIScrollView *)view)) [out addObject:(UIScrollView *)view];
    for (UIView *v in view.subviews) TOWXCollectOriginalScrolls(v, out);
}

@interface TOWXV10Interaction : NSObject <UIScrollViewDelegate>
+ (instancetype)shared;
- (void)slotTap:(UITapGestureRecognizer *)tap;
@end

static void TOWXLayoutBar(void);
static void TOWXEnsureBar(BOOL forceFreshScan);
static BOOL TOWXFindFreshGeometry(BOOL updateAnchor);

static BOOL TOWXProductIsScrolling(void) {
    return gUserScrolling || gProductScroll.tracking || gProductScroll.dragging || gProductScroll.decelerating;
}

static void TOWXCreateBar(void) {
    if (gProductBar) return;
    gProductBar = [[UIView alloc] initWithFrame:CGRectZero];
    gProductBar.backgroundColor = UIColor.clearColor;
    gProductBar.opaque = NO;
    gProductBar.clipsToBounds = NO;

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
    gProductScroll.bounces = NO;
    gProductScroll.alwaysBounceHorizontal = NO;
    gProductScroll.alwaysBounceVertical = NO;
    gProductScroll.decelerationRate = UIScrollViewDecelerationRateNormal;
    gProductScroll.scrollsToTop = NO;
    if (@available(iOS 11.0, *)) gProductScroll.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    gProductScroll.delegate = [TOWXV10Interaction shared];
    [gProductBar addSubview:gProductScroll];

    for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
        UIView *slot = [[UIView alloc] initWithFrame:CGRectZero];
        slot.tag = (NSInteger)i;
        slot.clipsToBounds = YES;
        slot.backgroundColor = [UIColor colorWithWhite:0.45 alpha:0.07];
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectZero];
        iv.tag = 0x545750;
        iv.clipsToBounds = YES;
        iv.userInteractionEnabled = NO;
        [slot addSubview:iv];
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[TOWXV10Interaction shared] action:@selector(slotTap:)];
        tap.cancelsTouchesInView = YES;
        [tap requireGestureRecognizerToFail:gProductScroll.panGestureRecognizer];
        [slot addGestureRecognizer:tap];
        [gProductScroll addSubview:slot];
        gSlots[i] = slot;
        TOWXLog("TOWX|SB|P2A4|BAR-BIND|position=%lu|source=v10-pan-first", (unsigned long)i);
    }
    TOWXLog("TOWX|SB|P2A4|PRODUCT-BAR-CREATE|ownership=fresh-session-host|gesture=pan-first|bounce=off");
    TOWXLog("TOWX|SB|P2A4|TOUCH-OWNERSHIP|tapRequiresPanFailure=yes|delaysContentTouches=no|layoutDuringScroll=no");
}

static void TOWXDetachBar(const char *reason) {
    if (!gProductBar) return;
    if (gBarVisible) TOWXLog("TOWX|SB|P2A4|BAR-HIDE|reason=%s", reason ?: "unknown");
    gBarVisible = NO;
    gProductBar.hidden = YES;
    gProductBar.userInteractionEnabled = NO;
    gProductScroll.userInteractionEnabled = NO;
    if (gProductBar.superview) {
        [gProductBar removeFromSuperview];
        TOWXLog("TOWX|SB|P2A4|BAR-DETACH|reason=%s", reason ?: "unknown");
    }
    gHostWindow = nil;
}

static CGRect TOWXFallbackFrame(UIWindow *window) {
    if (!gHasStableAnchor || !window) return CGRectZero;
    CGFloat ww = CGRectGetWidth(window.bounds), wh = CGRectGetHeight(window.bounds);
    if (ww < 100.0 || wh < 100.0) return CGRectZero;
    CGFloat width = gAnchorWidthRatio * ww;
    CGFloat height = gAnchorHeightRatio * wh;
    width = MIN(MAX(width, 160.0), MAX(160.0, ww - 8.0));
    height = MIN(MAX(height, 40.0), 100.0);
    CGFloat centerX = gAnchorCenterXRatio * ww;
    CGFloat x = centerX - width * 0.5;
    x = MAX(4.0, MIN(x, ww - width - 4.0));
    CGFloat bottomGap = gAnchorBottomGapRatio * wh;
    CGFloat y = wh - bottomGap - height;
    y = MAX(0.0, MIN(y, wh - height));
    return CGRectMake(x, y, width, height);
}

static BOOL TOWXHostWindowMatches(UIWindow *window) {
    if (!window || !TOWXWindowVisible(window) || !gHostWindowClass.length) return NO;
    if (![NSStringFromClass(window.class) isEqualToString:gHostWindowClass]) return NO;
    return fabs(window.windowLevel - gHostWindowLevel) <= 1.0;
}
static UIWindow *TOWXFindHostWindow(void) {
    UIWindow *current = gHostWindow;
    if (TOWXHostWindowMatches(current)) return current;
    UIWindow *best = nil;
    CGFloat bestScore = CGFLOAT_MAX;
    for (UIWindow *w in TOWXAllWindows()) {
        if (!TOWXHostWindowMatches(w)) continue;
        CGFloat score = 0.0;
        if (gAnchorWindowSize.width > 1.0 && gAnchorWindowSize.height > 1.0) {
            score = fabs(w.bounds.size.width - gAnchorWindowSize.width) + fabs(w.bounds.size.height - gAnchorWindowSize.height);
        }
        if (!best || score < bestScore) { best = w; bestScore = score; }
    }
    return best;
}

static void TOWXAttachToWindow(UIWindow *window, CGRect frame, const char *mode) {
    if (!window || !TOWXWindowVisible(window) || CGRectGetWidth(frame) < 160.0 || CGRectGetHeight(frame) < 40.0) return;
    TOWXCreateBar();
    BOOL moved = gProductBar.superview != window;
    BOOL frameChanged = !CGRectEqualToRect(gProductBar.frame, frame);
    if (moved) {
        [gProductBar removeFromSuperview];
        [window addSubview:gProductBar];
    }
    if (frameChanged) gProductBar.frame = frame;
    if (moved || frameChanged) {
        TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|mode=%s|window=%p|epoch=%llu|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                mode ?: "host", window, (unsigned long long)gSessionEpoch,
                frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    [window bringSubviewToFront:gProductBar];
    gHostWindow = window;
    BOOL shouldShow = gWeChatActive && gRemoteCount > 0 && TOWXVisibleSessionWindow() != nil;
    gProductBar.hidden = !shouldShow;
    gProductBar.userInteractionEnabled = shouldShow;
    gProductScroll.userInteractionEnabled = shouldShow;
    if (shouldShow && !gBarVisible) {
        TOWXLog("TOWX|SB|P2A4|BAR-SHOW|reason=%s|epoch=%llu|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                mode ?: "host", (unsigned long long)gSessionEpoch,
                frame.origin.x, frame.origin.y, frame.size.width, frame.size.height);
    }
    gBarVisible = shouldShow;
    if (!TOWXProductIsScrolling()) TOWXLayoutBar();
}

static BOOL TOWXFindFreshGeometry(BOOL updateAnchor) {
    UIWindow *session = TOWXVisibleSessionWindow();
    if (!session) return NO;

    UIScrollView *bestScroll = nil;
    UIWindow *bestWindow = nil;
    CGRect bestFrame = CGRectZero;
    CGFloat bestScore = -CGFLOAT_MAX;

    for (UIWindow *window in TOWXAllWindows()) {
        if (!TOWXWindowVisible(window)) continue;
        NSString *cls = NSStringFromClass(window.class);
        if (gHostWindowClass.length > 0) {
            if (![cls isEqualToString:gHostWindowClass]) continue;
            if (fabs(window.windowLevel - gHostWindowLevel) > 1.0) continue;
        } else if ([cls rangeOfString:@"TOJB"].location == NSNotFound && window.windowLevel < 20.0) {
            continue;
        }

        NSMutableArray<UIScrollView *> *candidates = [NSMutableArray array];
        TOWXCollectOriginalScrolls(window, candidates);
        for (UIScrollView *scroll in candidates) {
            CGRect frame = [scroll convertRect:scroll.bounds toView:window];
            if (CGRectGetWidth(frame) < 160.0 || CGRectGetHeight(frame) < 40.0 || CGRectGetHeight(frame) > 140.0) continue;
            if (CGRectGetMaxY(frame) < CGRectGetHeight(window.bounds) * 0.45) continue;
            CGFloat score = CGRectGetMaxY(frame) * 4.0 + CGRectGetWidth(frame);
            if (score > bestScore) {
                bestScore = score;
                bestScroll = scroll;
                bestWindow = window;
                bestFrame = frame;
            }
        }
    }

    if (!bestScroll || !bestWindow) return NO;

    TOWXSuppressOriginalScroll(bestScroll);
    gSourceScroll = bestScroll;
    gHostWindow = bestWindow;
    gHostWindowClass = [NSStringFromClass(bestWindow.class) copy];
    gHostWindowLevel = bestWindow.windowLevel;
    gGeometryEpoch = gSessionEpoch;

    if (updateAnchor || !gHasStableAnchor) {
        CGFloat ww = CGRectGetWidth(bestWindow.bounds), wh = CGRectGetHeight(bestWindow.bounds);
        if (ww > 1.0 && wh > 1.0) {
            gAnchorCenterXRatio = CGRectGetMidX(bestFrame) / ww;
            gAnchorWidthRatio = CGRectGetWidth(bestFrame) / ww;
            gAnchorHeightRatio = CGRectGetHeight(bestFrame) / wh;
            gAnchorBottomGapRatio = MAX(0.0, wh - CGRectGetMaxY(bestFrame)) / wh;
            gAnchorWindowSize = bestWindow.bounds.size;
            gHasStableAnchor = YES;
        }
    }

    TOWXLog("TOWX|SB|P2A4|FRESH-GEOMETRY|epoch=%llu|scroll=%p|window=%p|class=%s|frame={{%.1f,%.1f},{%.1f,%.1f}}|bottomRatio=%.4f",
            (unsigned long long)gSessionEpoch, bestScroll, bestWindow,
            gHostWindowClass.UTF8String ?: "?",
            bestFrame.origin.x, bestFrame.origin.y, bestFrame.size.width, bestFrame.size.height,
            gAnchorBottomGapRatio);

    if (gWeChatActive && gRemoteCount > 0) TOWXAttachToWindow(bestWindow, bestFrame, "fresh-session-geometry");
    return YES;
}

static void TOWXKeepOriginalHidden(void) {
    UIScrollView *source = gSourceScroll;
    if (source) TOWXSuppressOriginalScroll(source);
}

static void TOWXLayoutBar(void) {
    if (!gProductBar || !gProductBar.superview || TOWXProductIsScrolling()) return;
    NSUInteger count = MIN((NSUInteger)gRemoteCount, (NSUInteger)TOWX_MAX_RECENTS);
    CGFloat width = CGRectGetWidth(gProductBar.bounds), height = CGRectGetHeight(gProductBar.bounds);
    if (width < 2.0 || height < 2.0) return;

    gProductBar.backgroundColor = UIColor.clearColor;
    gProductScroll.frame = gProductBar.bounds;

    CGFloat diameter = MIN(52.0, MAX(42.0, height - 10.0));
    CGFloat spacing = 8.0;
    CGFloat total = diameter * count + spacing * (count ? count - 1 : 0);
    CGFloat content = MAX(width, total + 16.0);
    CGFloat left = (total <= width - 16.0) ? floor((width - total) / 2.0) : 8.0;
    CGFloat y = floor((height - diameter) / 2.0);

    gProductScroll.contentSize = CGSizeMake(content, height);
    gProductScroll.contentInset = UIEdgeInsetsZero;
    gProductScroll.alwaysBounceHorizontal = NO;
    gProductScroll.bounces = NO;

    CGFloat maxOffset = MAX(0.0, content - width);
    CGFloat currentOffset = gProductScroll.contentOffset.x;
    if (currentOffset < 0.0 || currentOffset > maxOffset) {
        gProductScroll.contentOffset = CGPointMake(MAX(0.0, MIN(currentOffset, maxOffset)), 0.0);
    }

    for (NSUInteger i = 0; i < TOWX_MAX_RECENTS; i++) {
        UIView *slot = gSlots[i];
        BOOL available = i < count;
        slot.hidden = !available;
        if (!available) continue;
        slot.frame = CGRectMake(left + i * (diameter + spacing), y, diameter, diameter);
        slot.layer.cornerRadius = diameter / 2.0;
        slot.layer.borderWidth = (gSelectedIndex == (NSInteger)i) ? 2.2 : 0.8;
        slot.layer.borderColor = (gSelectedIndex == (NSInteger)i ? UIColor.systemGreenColor : [UIColor colorWithWhite:0.68 alpha:0.5]).CGColor;
        UIImageView *iv = (UIImageView *)[slot viewWithTag:0x545750];
        iv.frame = CGRectInset(slot.bounds, 2.0, 2.0);
        iv.layer.cornerRadius = CGRectGetWidth(iv.bounds) / 2.0;
        UIImage *img = gAvatars[i];
        iv.image = img ?: TOWXPlaceholder();
        iv.contentMode = img ? UIViewContentModeScaleAspectFill : UIViewContentModeScaleAspectFit;
        iv.tintColor = img ? nil : UIColor.tertiaryLabelColor;
        iv.alpha = img ? 1.0 : 0.5;
    }

    static BOOL once = NO;
    if (!once) {
        once = YES;
        TOWXLog("TOWX|SB|P2A4|BAR-STYLE|mode=transparent-no-panel|edgeBounce=off|deceleration=normal");
    }
}

@implementation TOWXV10Interaction
+ (instancetype)shared {
    static TOWXV10Interaction *x;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ x = [self new]; });
    return x;
}
- (void)slotTap:(UITapGestureRecognizer *)tap {
    if (tap.state != UIGestureRecognizerStateRecognized || !gBarVisible || !gWeChatActive || TOWXVisibleSessionWindow() == nil) return;
    if (TOWXProductIsScrolling()) return;
    NSUInteger index = (NSUInteger)tap.view.tag;
    if (index >= MIN((NSUInteger)gRemoteCount, (NSUInteger)TOWX_MAX_RECENTS)) return;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - gLastTapAt < 0.16) return;
    gLastTapAt = now;
    char name[96];
    snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
    notify_post(name);
    TOWXLog("TOWX|SB|P2A4|TAP-SEND|index=%lu|gesture=tap-after-pan-failed", (unsigned long)index);
}
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    (void)scrollView;
    gUserScrolling = YES;
    TOWXLog("TOWX|SB|P2A4|SCROLL-BEGIN");
}
- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    (void)scrollView;
    if (!decelerate) {
        gUserScrolling = NO;
        TOWXLog("TOWX|SB|P2A4|SCROLL-END|decelerate=0");
        TOWXEnsureBar(NO);
        TOWXLayoutBar();
    }
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    (void)scrollView;
    gUserScrolling = NO;
    TOWXLog("TOWX|SB|P2A4|SCROLL-END|decelerate=1");
    TOWXEnsureBar(NO);
    TOWXLayoutBar();
}
- (void)scrollViewWillEndDragging:(UIScrollView *)scrollView
                     withVelocity:(CGPoint)velocity
              targetContentOffset:(inout CGPoint *)targetContentOffset {
    (void)velocity;
    CGFloat maxX = MAX(0.0, scrollView.contentSize.width - CGRectGetWidth(scrollView.bounds));
    targetContentOffset->x = MAX(0.0, MIN(targetContentOffset->x, maxX));
    targetContentOffset->y = 0.0;
}
@end

static void TOWXBeginSession(UIWindow *window, const char *reason) {
    if (!window) return;
    if (gSessionWindow == window && gSessionEpoch != 0) return;
    gSessionWindow = window;
    gSessionEpoch += 1;
    gGeometryEpoch = 0;
    gSourceScroll = nil;
    TOWXDetachBar("new-session");
    TOWXLog("TOWX|SB|P2A4|SESSION-BEGIN|epoch=%llu|reason=%s|window=%p",
            (unsigned long long)gSessionEpoch, reason ?: "unknown", window);

    (void)TOWXFindFreshGeometry(YES);
    const uint64_t delaysMs[] = { 20, 70, 160, 320, 620 };
    for (NSUInteger i = 0; i < sizeof(delaysMs)/sizeof(delaysMs[0]); i++) {
        uint64_t epoch = gSessionEpoch;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delaysMs[i] * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
            if (epoch != gSessionEpoch || TOWXVisibleSessionWindow() == nil) return;
            if (gGeometryEpoch != epoch) (void)TOWXFindFreshGeometry(YES);
            else TOWXKeepOriginalHidden();
            TOWXEnsureBar(NO);
        });
    }
}

static void TOWXEnsureBar(BOOL forceFreshScan) {
    UIWindow *session = TOWXVisibleSessionWindow();
    if (!session) {
        TOWXDetachBar("small-window-session-gone");
        return;
    }
    if (session != gSessionWindow) TOWXBeginSession(session, "ensure-detected-new-session");

    /* Original A/B/C/D/E must never be user-visible, even before WeChat starts. */
    if (forceFreshScan || gGeometryEpoch != gSessionEpoch || gSourceScroll == nil) {
        (void)TOWXFindFreshGeometry(gGeometryEpoch != gSessionEpoch);
    } else {
        TOWXKeepOriginalHidden();
    }

    if (!gWeChatActive || gRemoteCount == 0) {
        TOWXDetachBar(!gWeChatActive ? "wechat-inactive-no-placeholders" : "count-zero-no-placeholders");
        return;
    }
    if (TOWXProductIsScrolling()) return;

    if (gGeometryEpoch == gSessionEpoch) {
        UIScrollView *source = gSourceScroll;
        UIWindow *window = source.window;
        if (source && TOWXWindowVisible(window)) {
            CGRect frame = [source convertRect:source.bounds toView:window];
            if (CGRectGetWidth(frame) >= 160.0 && CGRectGetHeight(frame) >= 40.0) {
                TOWXSuppressOriginalScroll(source);
                TOWXAttachToWindow(window, frame, "fresh-source-live");
                return;
            }
        }
    }

    UIWindow *host = TOWXFindHostWindow();
    CGRect fallback = TOWXFallbackFrame(host);
    if (host && CGRectGetWidth(fallback) >= 160.0 && CGRectGetHeight(fallback) >= 40.0) {
        TOWXAttachToWindow(host, fallback, "bottom-anchored-fallback");
        return;
    }
    TOWXDetachBar("session-geometry-missing");
}

static void TOWXHandleReady(void) {
    uint64_t gen = 0, count = 0, stage = 0, active = 0;
    if (!TOWXReadState(gGenerationToken, &gen) || !TOWXReadState(gCountToken, &count) || !TOWXReadState(gStageToken, &stage)) return;
    (void)TOWXReadState(gAppActiveToken, &active);
    gRemoteCount = MIN(count, (uint64_t)TOWX_MAX_RECENTS);
    gRemoteStage = stage;
    gWeChatActive = active != 0;
    TOWXLog("TOWX|SB|P2A4|READY-RECV|generation=%llu|stage=%llu|stageName=%s|count=%llu|wechatActive=%d",
            (unsigned long long)gen, (unsigned long long)stage, TOWXStageName(stage),
            (unsigned long long)count, gWeChatActive ? 1 : 0);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSUInteger loaded = gRemoteCount > 0 ? TOWXLoadAvatars() : 0;
        if (!TOWXProductIsScrolling()) TOWXEnsureBar(NO);
        else if (TOWXVisibleSessionWindow() == nil || !gWeChatActive) TOWXDetachBar("state-changed-during-scroll");
        TOWXLog("TOWX|SB|P2A4|SYNC|count=%llu|loaded=%lu|bar=%s|session=%s|geometryEpoch=%llu|sessionEpoch=%llu|stage=%llu",
                (unsigned long long)gRemoteCount, (unsigned long)loaded,
                gBarVisible ? "visible" : "hidden",
                TOWXVisibleSessionWindow() ? "live" : "gone",
                (unsigned long long)gGeometryEpoch,
                (unsigned long long)gSessionEpoch,
                (unsigned long long)gRemoteStage);
    });
}
static void TOWXHandleAck(void) {
    uint64_t index = UINT64_MAX;
    if (!TOWXReadState(gAckIndexToken, &index)) return;
    gSelectedIndex = index < TOWX_MAX_RECENTS ? (NSInteger)index : NSNotFound;
    TOWXLog("TOWX|SB|P2A4|OPEN-ACK|index=%llu", (unsigned long long)index);
    dispatch_async(dispatch_get_main_queue(), ^{ if (!TOWXProductIsScrolling()) TOWXLayoutBar(); });
}

static void TOWXHandleWindowVisible(UIWindow *window) {
    NSString *cls = window ? NSStringFromClass(window.class) : @"";
    if (!window) return;
    TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=window-visible|window=%p|class=%s|level=%.1f",
            window, cls.UTF8String ?: "nil", window.windowLevel);

    /* Suppress TrollOpen letters as soon as its windows materialize. */
    if ([cls rangeOfString:@"TOJB"].location != NSNotFound) (void)TOWXFindFreshGeometry(NO);

    if ([cls isEqualToString:TOWX_SESSION_GATE_CLASS]) {
        TOWXLog("TOWX|SB|P2A4|SESSION-GATE|state=visible|window=%p", window);
        TOWXBeginSession(window, "window-visible");
    }
}
static void TOWXHandleWindowHidden(UIWindow *window) {
    NSString *cls = window ? NSStringFromClass(window.class) : @"";
    if (!window) return;
    TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=window-hidden|window=%p|class=%s", window, cls.UTF8String ?: "nil");
    if ([cls isEqualToString:TOWX_SESSION_GATE_CLASS] && (window == gSessionWindow || TOWXVisibleSessionWindow() == nil)) {
        TOWXLog("TOWX|SB|P2A4|SESSION-GATE|state=hidden|window=%p|epoch=%llu", window, (unsigned long long)gSessionEpoch);
        TOWXDetachBar("session-gate-hidden");
        gSessionWindow = nil;
        gSourceScroll = nil;
        gGeometryEpoch = 0;
    }
}
static void TOWXInstallLifecycle(void) {
    NSNotificationCenter *c = NSNotificationCenter.defaultCenter;
    [c addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        TOWXHandleWindowVisible([n.object isKindOfClass:[UIWindow class]] ? (UIWindow *)n.object : nil);
    }];
    [c addObserverForName:UIWindowDidBecomeHiddenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        TOWXHandleWindowHidden([n.object isKindOfClass:[UIWindow class]] ? (UIWindow *)n.object : nil);
    }];
    [c addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n) {
        UIWindow *session = TOWXVisibleSessionWindow();
        if (session && session != gSessionWindow) TOWXBeginSession(session, "scene-active");
        else TOWXEnsureBar(YES);
    }];
}
static void TOWXStartTimer(void) {
    gUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (!gUITimer) return;
    dispatch_source_set_timer(gUITimer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC / 4, NSEC_PER_SEC / 40);
    dispatch_source_set_event_handler(gUITimer, ^{
        static unsigned tick = 0;
        tick++;

        UIWindow *session = TOWXVisibleSessionWindow();
        if (!session) {
            if (gBarVisible) TOWXDetachBar("timer-session-gone");
            return;
        }
        if (session != gSessionWindow) TOWXBeginSession(session, "timer-new-session");

        TOWXKeepOriginalHidden();
        if ((tick % 4U) == 0U && (gGeometryEpoch != gSessionEpoch || gSourceScroll == nil)) (void)TOWXFindFreshGeometry(YES);
        if ((tick % 8U) == 0U && gRemoteCount > 0) (void)TOWXLoadAvatars();

        /* Never relayout/reparent while the user's finger or deceleration owns the scroll. */
        if (TOWXProductIsScrolling()) return;
        TOWXEnsureBar(NO);
    });
    dispatch_resume(gUITimer);
}

__attribute__((constructor)) static void TOWXV10Init(void) {
    TOWXLog("TOWX|SB|P2A4|LOADED|v0.10.0|mode=fresh-session-geometry+placeholder-off+bottom-anchor+no-layout-during-scroll+edge-bounce-off");
    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken) ||
        !TOWXRegisterState(TOWX_LINK_APP_ACTIVE, &gAppActiveToken)) return;

    dispatch_queue_t q = dispatch_queue_create("com.dream.towx.p2a4.receiver.v10", DISPATCH_QUEUE_SERIAL);
    notify_register_dispatch(TOWX_LINK_READY, &gReadyToken, q, ^(int t) { (void)t; TOWXHandleReady(); });
    notify_register_dispatch(TOWX_LINK_ACK, &gAckToken, q, ^(int t) { (void)t; TOWXHandleAck(); });
    TOWXLog("TOWX|SB|P2A4|LISTENERS-READY");
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXInstallLifecycle();
        TOWXStartTimer();
        UIWindow *session = TOWXVisibleSessionWindow();
        if (session) TOWXBeginSession(session, "startup-existing-session");
    });
}
