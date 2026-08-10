#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
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
static BOOL gAvatarMissLogged[TOWX_MAX_RECENTS];
static unsigned int gResolveTick = 0;
static unsigned int gBindSerial = 0;
static NSInteger gSelectedIndex = NSNotFound;

static UIView *gRememberedBarContainer = nil;
static __weak UIView *gRememberedBarParent = nil;
static CGRect gRememberedBarFrame;

static char kTOWXBoundIndexKey;
static char kTOWXTapKey;
static char kTOWXBlurKey;
static char kTOWXStyledKey;

static void TOWXEnsureLogDir(void) {
    (void)mkdir(kLogDir, 0755);
}

static void TOWXLog(const char *format, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    char body[1024];
    va_list args;
    va_start(args, format);
    int bodyLength = vsnprintf(body, sizeof(body), format, args);
    va_end(args);
    if (bodyLength < 0) {
        close(fd);
        return;
    }

    char line[1152];
    time_t now = time(NULL);
    int lineLength = snprintf(line, sizeof(line), "%lld %s\n", (long long)now, body);
    if (lineLength > 0) {
        size_t toWrite = (size_t)lineLength;
        if (toWrite > sizeof(line)) toWrite = sizeof(line);
        (void)write(fd, line, toWrite);
    }
    close(fd);
}

static const char *TOWXStageName(uint64_t stage) {
    switch (stage) {
        case 410: return "GOLDEN-MISSING";
        case 420: return "GOLDEN-FOUND";
        case 430: return "SNAPSHOT-WAIT";
        case 440: return "AVATAR-WAIT";
        case 450: return "SNAPSHOT-READY";
        case 470: return "SNAPSHOT-HOLD";
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

static NSString *TOWXResolveViaLaunchServices(void) {
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL appSel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass == Nil || ![(id)proxyClass respondsToSelector:appSel]) return nil;

    id proxy = ((id (*)(id, SEL, id))objc_msgSend)((id)proxyClass, appSel, @"com.tencent.xin");
    if (proxy == nil) return nil;

    SEL dataSel = NSSelectorFromString(@"dataContainerURL");
    if (![proxy respondsToSelector:dataSel]) return nil;
    NSURL *url = ((id (*)(id, SEL))objc_msgSend)(proxy, dataSel);
    if (![url isKindOfClass:[NSURL class]]) return nil;
    return [[[url path] stringByAppendingPathComponent:@"Library/Caches"]
            stringByAppendingPathComponent:@"TOWXLinkP2A4"];
}

static NSString *TOWXResolveViaMetadata(void) {
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray<NSString *> *items = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil];
    for (NSString *item in items) {
        NSString *container = [root stringByAppendingPathComponent:item];
        NSString *metaPath = [container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:metaPath];
        NSString *identifier = meta[@"MCMMetadataIdentifier"];
        if ([identifier isEqualToString:@"com.tencent.xin"]) {
            return [[container stringByAppendingPathComponent:@"Library/Caches"]
                    stringByAppendingPathComponent:@"TOWXLinkP2A4"];
        }
    }
    return nil;
}

static NSString *TOWXResolveWeChatExportDir(void) {
    if (gWeChatExportDir.length > 0) return gWeChatExportDir;
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
    if (dir.length == 0) return 0;

    NSUInteger loaded = 0;
    NSUInteger limited = MIN((NSUInteger)TOWX_MAX_RECENTS, (NSUInteger)gRemoteCount);
    for (NSUInteger index = 0; index < TOWX_MAX_RECENTS; index++) {
        if (index >= limited) {
            gAvatars[index] = nil;
            gAvatarMissLogged[index] = NO;
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image != nil) {
            BOOL firstLoad = (gAvatars[index] == nil);
            gAvatars[index] = image;
            gAvatarMissLogged[index] = NO;
            loaded += 1;
            if (firstLoad) {
                TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-PASS|index=%lu|path=%s|size=%.0fx%.0f",
                        (unsigned long)index,
                        path.UTF8String,
                        image.size.width,
                        image.size.height);
            }
        } else if (!gAvatarMissLogged[index]) {
            gAvatarMissLogged[index] = YES;
            TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-MISS|index=%lu|path=%s",
                    (unsigned long)index, path.UTF8String);
        }
    }
    return loaded;
}

static BOOL TOWXAncestorsAboveViewAreVisible(UIView *view) {
    if (view == nil || view.window == nil) return NO;
    UIView *cursor = view.superview;
    while (cursor != nil) {
        if (cursor.hidden || cursor.alpha <= 0.01) return NO;
        cursor = cursor.superview;
    }
    return YES;
}

static BOOL TOWXLabelHasSlotShape(UILabel *label) {
    CGFloat width = CGRectGetWidth(label.bounds);
    CGFloat height = CGRectGetHeight(label.bounds);
    if (width < 32.0 || width > 96.0 || height < 32.0 || height > 96.0) return NO;
    return fabs(width - height) <= 20.0;
}

static BOOL TOWXLabelLooksLikeOriginalSlot(UILabel *label) {
    if (!TOWXLabelHasSlotShape(label)) return NO;
    NSNumber *bound = objc_getAssociatedObject(label, &kTOWXBoundIndexKey);
    if ([bound isKindOfClass:[NSNumber class]]) return YES;
    NSString *text = label.text;
    if (text.length != 1) return NO;
    unichar value = [text characterAtIndex:0];
    return value >= 'A' && value <= 'Z';
}

static void TOWXCollectSlotLabels(UIView *view, NSMutableArray<UILabel *> *labels) {
    if ([view isKindOfClass:[UILabel class]] && TOWXLabelLooksLikeOriginalSlot((UILabel *)view)) {
        [labels addObject:(UILabel *)view];
    }
    for (UIView *subview in view.subviews) {
        TOWXCollectSlotLabels(subview, labels);
    }
}

@interface TOWXLinkTapTarget : NSObject
+ (instancetype)shared;
- (void)avatarTapped:(UITapGestureRecognizer *)recognizer;
@end

static NSUInteger TOWXBindCurrentBars(void);

@implementation TOWXLinkTapTarget
+ (instancetype)shared {
    static TOWXLinkTapTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [TOWXLinkTapTarget new]; });
    return target;
}

- (void)avatarTapped:(UITapGestureRecognizer *)recognizer {
    UIView *view = recognizer.view;
    NSNumber *number = view ? objc_getAssociatedObject(view, &kTOWXBoundIndexKey) : nil;
    if (![number isKindOfClass:[NSNumber class]]) return;
    NSUInteger index = number.unsignedIntegerValue;
    if (index >= TOWX_MAX_RECENTS || index >= gRemoteCount) return;

    gSelectedIndex = (NSInteger)index;
    char name[96];
    (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
    notify_post(name);
    TOWXLog("TOWX|SB|P2A4|TAP-SEND|index=%lu|notification=%s", (unsigned long)index, name);
    (void)TOWXBindCurrentBars();
}
@end

static UIView *TOWXBarContainer(UIScrollView *scroll) {
    UIView *parent = scroll.superview;
    if (parent == nil) return scroll;
    CGFloat height = CGRectGetHeight(parent.bounds);
    CGFloat width = CGRectGetWidth(parent.bounds);
    if (height >= 42.0 && height <= 140.0 && width >= 160.0) return parent;
    return scroll;
}

static void TOWXRememberBar(UIScrollView *scroll) {
    UIView *container = TOWXBarContainer(scroll);
    if (container == nil) return;
    if (gRememberedBarContainer != container) {
        gRememberedBarContainer = container;
        gRememberedBarParent = container.superview;
        gRememberedBarFrame = container.frame;
        TOWXLog("TOWX|SB|P2A4|BAR-REMEMBER|container=%p|parent=%p|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                container,
                container.superview,
                container.frame.origin.x,
                container.frame.origin.y,
                container.frame.size.width,
                container.frame.size.height);
    } else {
        gRememberedBarFrame = container.frame;
    }
}

static void TOWXStyleBar(UIScrollView *scroll) {
    UIView *container = TOWXBarContainer(scroll);
    if (container == nil) return;
    if (!TOWXAncestorsAboveViewAreVisible(container)) return;

    scroll.hidden = NO;
    scroll.alpha = 1.0;
    scroll.backgroundColor = UIColor.clearColor;
    scroll.userInteractionEnabled = YES;
    container.hidden = NO;
    container.alpha = 1.0;
    container.backgroundColor = UIColor.clearColor;
    container.userInteractionEnabled = YES;

    CGFloat radius = MIN(30.0, MAX(18.0, CGRectGetHeight(container.bounds) * 0.34));
    container.layer.cornerRadius = radius;
    container.layer.borderWidth = 0.6;
    container.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.38].CGColor;
    container.clipsToBounds = YES;

    UIVisualEffectView *blur = objc_getAssociatedObject(container, &kTOWXBlurKey);
    if (![blur isKindOfClass:[UIVisualEffectView class]]) {
        UIBlurEffect *effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialLight];
        blur = [[UIVisualEffectView alloc] initWithEffect:effect];
        blur.userInteractionEnabled = NO;
        blur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        blur.layer.cornerRadius = radius;
        blur.clipsToBounds = YES;
        blur.contentView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
        [container insertSubview:blur atIndex:0];
        objc_setAssociatedObject(container, &kTOWXBlurKey, blur, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(container, &kTOWXStyledKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TOWXLog("TOWX|SB|P2A4|BAR-STYLE|container=%p|mode=systemMaterialLight", container);
    }
    blur.frame = container.bounds;
    blur.layer.cornerRadius = radius;
    [container sendSubviewToBack:blur];

    if (container.superview != nil) {
        [container.superview bringSubviewToFront:container];
    }
    TOWXRememberBar(scroll);
}

static UIImage *TOWXPlaceholderImage(void) {
    static UIImage *image = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        image = [UIImage systemImageNamed:@"person.crop.circle.fill"];
    });
    return image;
}

static void TOWXBindLabel(UILabel *label, NSUInteger index) {
    if (index >= TOWX_MAX_RECENTS) {
        label.text = @"";
        label.hidden = YES;
        label.userInteractionEnabled = NO;
        return;
    }

    BOOL available = index < gRemoteCount;
    NSNumber *oldBound = objc_getAssociatedObject(label, &kTOWXBoundIndexKey);
    BOOL firstBind = ![oldBound isKindOfClass:[NSNumber class]];
    objc_setAssociatedObject(label, &kTOWXBoundIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    label.text = @"";
    label.hidden = !available;
    label.alpha = available ? 1.0 : 0.0;
    label.backgroundColor = UIColor.clearColor;
    label.layer.cornerRadius = MIN(CGRectGetWidth(label.bounds), CGRectGetHeight(label.bounds)) * 0.5;
    label.clipsToBounds = NO;
    label.userInteractionEnabled = available;

    if (firstBind) {
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[TOWXLinkTapTarget shared]
                                                                              action:@selector(avatarTapped:)];
        tap.cancelsTouchesInView = YES;
        [label addGestureRecognizer:tap];
        objc_setAssociatedObject(label, &kTOWXTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gBindSerial += 1;
        TOWXLog("TOWX|SB|P2A4|BAR-BIND|serial=%u|position=%lu|label=%p|original=%s",
                gBindSerial,
                (unsigned long)index,
                label,
                oldBound ? "bound" : "letter");
    }

    NSInteger imageTag = 0x545740;
    UIImageView *imageView = (UIImageView *)[label viewWithTag:imageTag];
    if (![imageView isKindOfClass:[UIImageView class]]) {
        imageView = [[UIImageView alloc] initWithFrame:CGRectInset(label.bounds, 4.0, 4.0)];
        imageView.tag = imageTag;
        imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        imageView.clipsToBounds = YES;
        imageView.userInteractionEnabled = NO;
        [label addSubview:imageView];
    }

    imageView.frame = CGRectInset(label.bounds, 4.0, 4.0);
    imageView.layer.cornerRadius = MAX(0.0, MIN(CGRectGetWidth(imageView.bounds), CGRectGetHeight(imageView.bounds)) * 0.5);
    imageView.layer.borderWidth = (gSelectedIndex == (NSInteger)index) ? 2.2 : 1.2;
    imageView.layer.borderColor = (gSelectedIndex == (NSInteger)index ? UIColor.systemGreenColor : [UIColor colorWithWhite:1.0 alpha:0.78]).CGColor;
    imageView.backgroundColor = UIColor.secondarySystemFillColor;

    UIImage *avatar = gAvatars[index];
    UIImage *nextImage = avatar ?: TOWXPlaceholderImage();
    BOOL changed = imageView.image != nextImage;
    imageView.image = nextImage;
    if (avatar != nil) {
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.tintColor = nil;
    } else {
        imageView.contentMode = UIViewContentModeScaleAspectFit;
        imageView.tintColor = UIColor.tertiaryLabelColor;
    }

    if (changed && available) {
        imageView.alpha = 0.55;
        [UIView animateWithDuration:0.18 animations:^{
            imageView.alpha = 1.0;
        }];
    } else {
        imageView.alpha = 1.0;
    }
}

static BOOL TOWXBindCandidateScrollView(UIScrollView *scroll) {
    CGFloat height = CGRectGetHeight(scroll.bounds);
    CGFloat width = CGRectGetWidth(scroll.bounds);
    if (height < 40.0 || height > 135.0 || width < 160.0) return NO;

    NSMutableArray<UILabel *> *labels = [NSMutableArray array];
    TOWXCollectSlotLabels(scroll, labels);
    if (labels.count < 3 || labels.count > 12) return NO;

    [labels sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
        CGRect frameA = [a convertRect:a.bounds toView:scroll];
        CGRect frameB = [b convertRect:b.bounds toView:scroll];
        CGFloat delta = CGRectGetMidX(frameA) - CGRectGetMidX(frameB);
        if (fabs(delta) < 0.5) return NSOrderedSame;
        return delta < 0.0 ? NSOrderedAscending : NSOrderedDescending;
    }];

    TOWXStyleBar(scroll);
    NSUInteger position = 0;
    for (UILabel *label in labels) {
        TOWXBindLabel(label, position);
        position += 1;
    }
    return YES;
}

static NSUInteger TOWXScanForBars(UIView *view) {
    NSUInteger found = 0;
    if ([view isKindOfClass:[UIScrollView class]]) {
        if (TOWXBindCandidateScrollView((UIScrollView *)view)) found += 1;
    }
    for (UIView *subview in view.subviews) {
        found += TOWXScanForBars(subview);
    }
    return found;
}

static BOOL TOWXRestoreRememberedBar(void) {
    UIView *container = gRememberedBarContainer;
    UIView *parent = gRememberedBarParent;
    if (container == nil || parent == nil || parent.window == nil || !TOWXAncestorsAboveViewAreVisible(parent)) return NO;

    if (container.superview == nil) {
        container.frame = gRememberedBarFrame;
        [parent addSubview:container];
        TOWXLog("TOWX|SB|P2A4|BAR-REATTACH|container=%p|parent=%p", container, parent);
    }
    container.hidden = NO;
    container.alpha = 1.0;
    [parent bringSubviewToFront:container];
    TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|container=%p|parent=%p", container, parent);
    return YES;
}

static NSUInteger TOWXBindCurrentBars(void) {
    if (gRemoteCount == 0) return 0;
    UIApplication *application = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    [windows addObjectsFromArray:application.windows ?: @[]];
    if (windows.count == 0) {
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows ?: @[]];
            }
        }
    }

    NSUInteger found = 0;
    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0.01) continue;
        found += TOWXScanForBars(window);
    }
    if (found == 0) {
        (void)TOWXRestoreRememberedBar();
    }
    return found;
}

static void TOWXHandleReady(void) {
    uint64_t generation = 0;
    uint64_t count = 0;
    uint64_t stage = 0;
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
        if ((stage == 450 || stage == 470) && gRemoteCount > 0) {
            NSUInteger loaded = TOWXLoadAvatars();
            NSUInteger bars = TOWXBindCurrentBars();
            TOWXLog("TOWX|SB|P2A4|SYNC|count=%llu|loaded=%lu|bars=%lu|mode=%s",
                    (unsigned long long)gRemoteCount,
                    (unsigned long)loaded,
                    (unsigned long)bars,
                    stage == 450 ? "refresh" : "hold");
        }
    });
}

static void TOWXHandleAck(void) {
    uint64_t index = UINT64_MAX;
    if (TOWXReadToken(gAckIndexToken, &index)) {
        gSelectedIndex = index < TOWX_MAX_RECENTS ? (NSInteger)index : NSNotFound;
        TOWXLog("TOWX|SB|P2A4|OPEN-ACK|index=%llu", (unsigned long long)index);
        dispatch_async(dispatch_get_main_queue(), ^{
            (void)TOWXBindCurrentBars();
        });
    } else {
        TOWXLog("TOWX|SB|P2A4|OPEN-ACK-READ-FAIL");
    }
}

static void TOWXScheduleLifecycleRebind(NSString *reason) {
    TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=%s", reason.UTF8String ?: "unknown");
    dispatch_async(dispatch_get_main_queue(), ^{
        (void)TOWXBindCurrentBars();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        (void)TOWXBindCurrentBars();
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(550 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        (void)TOWXBindCurrentBars();
    });
}

static void TOWXInstallLifecycleObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXScheduleLifecycleRebind(@"window-visible");
    }];
    [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXScheduleLifecycleRebind(@"scene-active");
    }];
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
        TOWXScheduleLifecycleRebind(@"app-active");
    }];
}

static void TOWXStartUITimer(void) {
    gUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gUITimer == nil) {
        TOWXLog("TOWX|SB|P2A4|UI-TIMER-FAIL");
        return;
    }
    dispatch_source_set_timer(gUITimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC * 2U / 5U),
                              (uint64_t)(NSEC_PER_SEC / 25U));
    dispatch_source_set_event_handler(gUITimer, ^{
        gResolveTick += 1;
        if (gWeChatExportDir.length == 0 && (gResolveTick % 5U) == 0U) {
            (void)TOWXResolveWeChatExportDir();
        }
        if (gRemoteCount > 0) {
            if ((gResolveTick % 3U) == 0U) (void)TOWXLoadAvatars();
            (void)TOWXBindCurrentBars();
        }
    });
    dispatch_resume(gUITimer);
}

__attribute__((constructor)) static void TOWXSpringBoardDataBridgeInit(void) {
    TOWXLog("TOWX|SB|P2A4|LOADED|v0.4.0|mode=snapshot+position-slots+glass+lifecycle");

    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) {
        TOWXLog("TOWX|SB|P2A4|INIT-ABORT|state-registration");
        return;
    }

    dispatch_queue_t queue = dispatch_queue_create("com.dream.towx.p2a4.receiver", DISPATCH_QUEUE_SERIAL);
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
    });
}
