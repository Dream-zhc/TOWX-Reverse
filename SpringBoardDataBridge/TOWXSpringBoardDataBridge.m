#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
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
static const char *kLogPath = "/var/mobile/TrollOpenJB/phase2a3-link.log";

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
static unsigned int gResolveTick = 0;
static unsigned int gBindSerial = 0;

static char kTOWXBoundIndexKey;
static char kTOWXTapKey;
static char kTOWXOriginalTextKey;

static void TOWXEnsureLogDir(void) {
    (void)mkdir(kLogDir, 0755);
}

static void TOWXLog(const char *format, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;

    char body[896];
    va_list args;
    va_start(args, format);
    int bodyLength = vsnprintf(body, sizeof(body), format, args);
    va_end(args);
    if (bodyLength < 0) {
        close(fd);
        return;
    }

    char line[1024];
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
        case 310: return "GOLDEN-MISSING";
        case 320: return "GOLDEN-FOUND";
        case 330: return "CACHE-WAIT";
        case 340: return "AVATAR-WAIT";
        case 350: return "AVATARS-EXPORTED";
        case 390: return "CACHE-BAD";
        default: return "UNKNOWN";
    }
}

static int TOWXRegisterState(const char *name, int *token) {
    uint32_t status = notify_register_check(name, token);
    if (status != NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|SB|LINK|STATE-REGISTER-FAIL|name=%s|status=%u", name, status);
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
            stringByAppendingPathComponent:@"TOWXLinkP2A3"];
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
                    stringByAppendingPathComponent:@"TOWXLinkP2A3"];
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
        TOWXLog("TOWX|SB|LINK|WECHAT-DIR|path=%s", gWeChatExportDir.UTF8String);
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
            continue;
        }
        NSString *path = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"avatar%lu.png", (unsigned long)index]];
        UIImage *image = [UIImage imageWithContentsOfFile:path];
        if (image != nil) {
            BOOL firstLoad = (gAvatars[index] == nil);
            gAvatars[index] = image;
            loaded += 1;
            if (firstLoad) {
                TOWXLog("TOWX|SB|LINK|AVATAR-LOAD-PASS|index=%lu|path=%s|size=%.0fx%.0f",
                        (unsigned long)index,
                        path.UTF8String,
                        image.size.width,
                        image.size.height);
            }
        } else {
            TOWXLog("TOWX|SB|LINK|AVATAR-LOAD-MISS|index=%lu|path=%s",
                    (unsigned long)index, path.UTF8String);
        }
    }
    return loaded;
}

static NSInteger TOWXIndexForLabel(UILabel *label) {
    NSNumber *bound = objc_getAssociatedObject(label, &kTOWXBoundIndexKey);
    if ([bound isKindOfClass:[NSNumber class]]) return bound.integerValue;

    NSString *text = label.text;
    if (text.length != 1) return NSNotFound;
    unichar c = [text characterAtIndex:0];
    if (c < 'A' || c > 'J') return NSNotFound;
    return (NSInteger)(c - 'A');
}

static UIScrollView *TOWXNearestScrollView(UIView *view) {
    UIView *cursor = view.superview;
    for (NSUInteger depth = 0; cursor != nil && depth < 8; depth++, cursor = cursor.superview) {
        if ([cursor isKindOfClass:[UIScrollView class]]) return (UIScrollView *)cursor;
    }
    return nil;
}

static NSUInteger TOWXCountLetterLabels(UIView *view) {
    NSUInteger count = 0;
    if ([view isKindOfClass:[UILabel class]]) {
        NSInteger index = TOWXIndexForLabel((UILabel *)view);
        if (index != NSNotFound && index >= 0 && index < 10) count += 1;
    }
    for (UIView *subview in view.subviews) count += TOWXCountLetterLabels(subview);
    return count;
}

@interface TOWXLinkTapTarget : NSObject
+ (instancetype)shared;
- (void)avatarTapped:(UITapGestureRecognizer *)recognizer;
@end

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
    if (index >= TOWX_MAX_RECENTS) return;

    char name[96];
    (void)snprintf(name, sizeof(name), "%s%lu", TOWX_LINK_OPEN_PREFIX, (unsigned long)index);
    notify_post(name);
    TOWXLog("TOWX|SB|LINK|TAP-SEND|index=%lu|notification=%s", (unsigned long)index, name);
}
@end

static BOOL TOWXLabelLooksLikeAvatarSlot(UILabel *label) {
    CGRect bounds = label.bounds;
    CGFloat width = CGRectGetWidth(bounds);
    CGFloat height = CGRectGetHeight(bounds);
    if (width < 32.0 || width > 90.0 || height < 32.0 || height > 90.0) return NO;
    if (fabs(width - height) > 18.0) return NO;
    UIScrollView *scroll = TOWXNearestScrollView(label);
    if (scroll == nil) return NO;
    if (CGRectGetHeight(scroll.bounds) < 40.0 || CGRectGetHeight(scroll.bounds) > 130.0) return NO;
    if (CGRectGetWidth(scroll.bounds) < 160.0) return NO;
    return TOWXCountLetterLabels(scroll) >= 3;
}

static void TOWXBindLabel(UILabel *label, NSUInteger index) {
    if (index >= TOWX_MAX_RECENTS || gAvatars[index] == nil) return;

    NSNumber *bound = objc_getAssociatedObject(label, &kTOWXBoundIndexKey);
    if (bound == nil) {
        objc_setAssociatedObject(label, &kTOWXBoundIndexKey, @(index), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(label, &kTOWXOriginalTextKey, label.text ?: @"", OBJC_ASSOCIATION_COPY_NONATOMIC);
        label.userInteractionEnabled = YES;
        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:[TOWXLinkTapTarget shared]
                                                                              action:@selector(avatarTapped:)];
        tap.cancelsTouchesInView = YES;
        [label addGestureRecognizer:tap];
        objc_setAssociatedObject(label, &kTOWXTapKey, tap, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gBindSerial += 1;
        TOWXLog("TOWX|SB|LINK|BAR-BIND|serial=%u|index=%lu|label=%p|frame={{%.1f,%.1f},{%.1f,%.1f}}",
                gBindSerial,
                (unsigned long)index,
                label,
                label.frame.origin.x,
                label.frame.origin.y,
                label.frame.size.width,
                label.frame.size.height);
    }

    label.text = @"";
    NSInteger imageTag = (NSInteger)(0x545700U + index);
    UIImageView *imageView = (UIImageView *)[label viewWithTag:imageTag];
    if (![imageView isKindOfClass:[UIImageView class]]) {
        imageView = [[UIImageView alloc] initWithFrame:CGRectInset(label.bounds, 3.0, 3.0)];
        imageView.tag = imageTag;
        imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        imageView.contentMode = UIViewContentModeScaleAspectFill;
        imageView.clipsToBounds = YES;
        imageView.userInteractionEnabled = NO;
        [label addSubview:imageView];
    }
    imageView.frame = CGRectInset(label.bounds, 3.0, 3.0);
    imageView.layer.cornerRadius = MAX(0.0, MIN(CGRectGetWidth(imageView.bounds), CGRectGetHeight(imageView.bounds)) * 0.5);
    imageView.image = gAvatars[index];
}

static void TOWXScanView(UIView *view) {
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        NSInteger index = TOWXIndexForLabel(label);
        if (index != NSNotFound && index >= 0 && index < (NSInteger)TOWX_MAX_RECENTS &&
            TOWXLabelLooksLikeAvatarSlot(label)) {
            TOWXBindLabel(label, (NSUInteger)index);
        }
    }
    for (UIView *subview in view.subviews) TOWXScanView(subview);
}

static void TOWXBindCurrentBars(void) {
    UIApplication *application = [UIApplication sharedApplication];
    NSArray<UIWindow *> *windows = application.windows;
    if (windows.count == 0) {
        NSMutableArray<UIWindow *> *result = [NSMutableArray array];
        for (UIScene *scene in application.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [result addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        windows = result;
    }

    for (UIWindow *window in windows) {
        if (window.hidden || window.alpha <= 0.01) continue;
        TOWXScanView(window);
    }
}

static void TOWXHandleReady(void) {
    uint64_t generation = 0;
    uint64_t count = 0;
    uint64_t stage = 0;
    if (!TOWXReadToken(gGenerationToken, &generation) ||
        !TOWXReadToken(gCountToken, &count) ||
        !TOWXReadToken(gStageToken, &stage)) {
        TOWXLog("TOWX|SB|LINK|STATE-READ-FAIL");
        return;
    }

    gRemoteCount = MIN((uint64_t)TOWX_MAX_RECENTS, count);
    TOWXLog("TOWX|SB|LINK|READY-RECV|generation=%llu|stage=%llu|stageName=%s|count=%llu",
            (unsigned long long)generation,
            (unsigned long long)stage,
            TOWXStageName(stage),
            (unsigned long long)count);

    dispatch_async(dispatch_get_main_queue(), ^{
        if (stage == 350 && gRemoteCount > 0) {
            NSUInteger loaded = TOWXLoadAvatars();
            TOWXLog("TOWX|SB|LINK|AVATAR-BATCH|count=%llu|loaded=%lu",
                    (unsigned long long)gRemoteCount, (unsigned long)loaded);
            TOWXBindCurrentBars();
        }
    });
}

static void TOWXHandleAck(void) {
    uint64_t index = UINT64_MAX;
    if (TOWXReadToken(gAckIndexToken, &index)) {
        TOWXLog("TOWX|SB|LINK|OPEN-ACK|index=%llu", (unsigned long long)index);
    } else {
        TOWXLog("TOWX|SB|LINK|OPEN-ACK-READ-FAIL");
    }
}

static void TOWXStartUITimer(void) {
    gUITimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    if (gUITimer == nil) {
        TOWXLog("TOWX|SB|LINK|UI-TIMER-FAIL");
        return;
    }
    dispatch_source_set_timer(gUITimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(NSEC_PER_SEC / 2),
                              (uint64_t)(NSEC_PER_SEC / 20));
    dispatch_source_set_event_handler(gUITimer, ^{
        gResolveTick += 1;
        if (gWeChatExportDir.length == 0 && (gResolveTick % 4U) == 0U) {
            (void)TOWXResolveWeChatExportDir();
        }
        if (gRemoteCount > 0) {
            (void)TOWXLoadAvatars();
            TOWXBindCurrentBars();
        }
    });
    dispatch_resume(gUITimer);
}

__attribute__((constructor)) static void TOWXSpringBoardDataBridgeInit(void) {
    TOWXLog("TOWX|SB|LINK|LOADED|v0.3.0|mode=golden0.6-filelink+darwin-click");

    if (!TOWXRegisterState(TOWX_LINK_GENERATION, &gGenerationToken) ||
        !TOWXRegisterState(TOWX_LINK_COUNT, &gCountToken) ||
        !TOWXRegisterState(TOWX_LINK_STAGE, &gStageToken) ||
        !TOWXRegisterState(TOWX_LINK_ACK_INDEX, &gAckIndexToken)) {
        TOWXLog("TOWX|SB|LINK|INIT-ABORT|state-registration");
        return;
    }

    dispatch_queue_t queue = dispatch_queue_create("com.dream.towx.link.receiver", DISPATCH_QUEUE_SERIAL);
    uint32_t readyStatus = notify_register_dispatch(TOWX_LINK_READY, &gReadyToken, queue, ^(int token) {
        (void)token;
        TOWXHandleReady();
    });
    uint32_t ackStatus = notify_register_dispatch(TOWX_LINK_ACK, &gAckToken, queue, ^(int token) {
        (void)token;
        TOWXHandleAck();
    });
    if (readyStatus == NOTIFY_STATUS_OK && ackStatus == NOTIFY_STATUS_OK) {
        TOWXLog("TOWX|SB|LINK|LISTENERS-READY");
    } else {
        TOWXLog("TOWX|SB|LINK|LISTENER-FAIL|ready=%u|ack=%u", readyStatus, ackStatus);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXStartUITimer();
    });
}
