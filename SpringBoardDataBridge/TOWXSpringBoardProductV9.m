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

static UIView *gProductBar = nil;
static UIScrollView *gProductScroll = nil;
static UIView *gSlots[TOWX_MAX_RECENTS] = { nil, nil, nil, nil, nil, nil };

static __weak UIScrollView *gSourceScroll = nil;
static __weak UIWindow *gLastHostWindow = nil;
static NSString *gHostWindowClass = nil;
static CGFloat gHostWindowLevel = 0;
static CGSize gCalibrationWindowSize = {0,0};
static CGRect gCalibrationFrameInWindow = {{0,0},{0,0}};
static BOOL gHasCalibration = NO;

static void TOWXEnsureLogDir(void) { (void)mkdir(kLogDir, 0755); }
static void TOWXLog(const char *fmt, ...) {
    TOWXEnsureLogDir();
    int fd = open(kLogPath, O_WRONLY | O_CREAT | O_APPEND, 0644); if (fd < 0) return;
    char body[1200]; va_list args; va_start(args, fmt); int n = vsnprintf(body, sizeof(body), fmt, args); va_end(args);
    if (n >= 0) { char line[1400]; int m = snprintf(line, sizeof(line), "%lld %s\n", (long long)time(NULL), body); if (m > 0) (void)write(fd, line, MIN((size_t)m, sizeof(line))); }
    close(fd);
}

static const char *TOWXStageName(uint64_t s) {
    switch (s) { case 410:return "GOLDEN-MISSING"; case 420:return "GOLDEN-FOUND"; case 430:return "CACHE-WAIT"; case 440:return "AVATAR-WAIT"; case 450:return "SNAPSHOT-READY"; case 470:return "SNAPSHOT-HOLD"; case 490:return "CACHE-BAD"; default:return "UNKNOWN"; }
}
static int TOWXRegisterState(const char *name, int *token) { return notify_register_check(name, token) == NOTIFY_STATUS_OK; }
static int TOWXReadState(int token, uint64_t *value) { return notify_get_state(token, value) == NOTIFY_STATUS_OK; }

static NSArray<UIWindow *> *TOWXAllWindows(void) {
    UIApplication *app = UIApplication.sharedApplication;
    NSMutableOrderedSet *set = [NSMutableOrderedSet orderedSet];
    for (UIWindow *w in app.windows ?: @[]) [set addObject:w];
    for (UIScene *scene in app.connectedScenes) if ([scene isKindOfClass:[UIWindowScene class]]) for (UIWindow *w in ((UIWindowScene *)scene).windows ?: @[]) [set addObject:w];
    return set.array;
}
static BOOL TOWXWindowVisible(UIWindow *w) { return w && !w.hidden && w.alpha > 0.01 && w.bounds.size.width > 100 && w.bounds.size.height > 100; }
static BOOL TOWXSessionGateVisible(void) {
    for (UIWindow *w in TOWXAllWindows()) if (TOWXWindowVisible(w) && [NSStringFromClass(w.class) isEqualToString:TOWX_SESSION_GATE_CLASS]) return YES;
    return NO;
}

static NSString *TOWXResolveExportDir(void) {
    if (gWeChatExportDir.length && [[NSFileManager defaultManager] fileExistsAtPath:gWeChatExportDir]) return gWeChatExportDir;
    gWeChatExportDir = nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy"); SEL appSel = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (proxyClass && [(id)proxyClass respondsToSelector:appSel]) {
        id proxy = ((id(*)(id,SEL,id))objc_msgSend)((id)proxyClass, appSel, @"com.tencent.xin");
        SEL dataSel = NSSelectorFromString(@"dataContainerURL");
        if (proxy && [proxy respondsToSelector:dataSel]) {
            NSURL *url = ((id(*)(id,SEL))objc_msgSend)(proxy, dataSel);
            if ([url isKindOfClass:[NSURL class]]) gWeChatExportDir = [[[[url path] stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"] copy];
        }
    }
    if (!gWeChatExportDir.length) {
        NSString *root=@"/var/mobile/Containers/Data/Application";
        for (NSString *item in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:root error:nil]) {
            NSString *container=[root stringByAppendingPathComponent:item];
            NSDictionary *meta=[NSDictionary dictionaryWithContentsOfFile:[container stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
            if ([meta[@"MCMMetadataIdentifier"] isEqualToString:@"com.tencent.xin"]) { gWeChatExportDir=[[[container stringByAppendingPathComponent:@"Library/Caches"] stringByAppendingPathComponent:@"TOWXLinkP2A4"] copy]; break; }
        }
    }
    if (gWeChatExportDir.length) TOWXLog("TOWX|SB|P2A4|WECHAT-DIR|path=%s", gWeChatExportDir.UTF8String);
    return gWeChatExportDir;
}
static NSUInteger TOWXLoadAvatars(void) {
    NSString *dir=TOWXResolveExportDir(); if (!dir.length || gRemoteCount==0) return 0;
    NSUInteger loaded=0, limit=MIN((NSUInteger)gRemoteCount,(NSUInteger)TOWX_MAX_RECENTS);
    for (NSUInteger i=0;i<TOWX_MAX_RECENTS;i++) {
        if (i>=limit) { gAvatars[i]=nil; gAvatarMtimes[i]=nil; continue; }
        NSString *path=[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"avatar%lu.png",(unsigned long)i]];
        NSDate *mtime=[[[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] objectForKey:NSFileModificationDate];
        if (mtime && gAvatars[i] && [gAvatarMtimes[i] isEqualToDate:mtime]) { loaded++; continue; }
        UIImage *image=[UIImage imageWithContentsOfFile:path];
        if (image) { gAvatars[i]=image; gAvatarMtimes[i]=mtime; loaded++; TOWXLog("TOWX|SB|P2A4|AVATAR-LOAD-PASS|index=%lu|size=%.0fx%.0f",(unsigned long)i,image.size.width,image.size.height); }
    }
    return loaded;
}
static UIImage *TOWXPlaceholder(void) { static UIImage *img=nil; static dispatch_once_t once; dispatch_once(&once,^{ img=[UIImage systemImageNamed:@"person.crop.circle.fill"]; }); return img; }

static BOOL TOWXLabelLooksOriginal(UILabel *label) {
    if (!label || label.text.length!=1) return NO; unichar c=[label.text characterAtIndex:0]; if (c<'A'||c>'Z') return NO;
    CGFloat w=CGRectGetWidth(label.bounds),h=CGRectGetHeight(label.bounds); return w>=30&&w<=100&&h>=30&&h<=100&&fabs(w-h)<24;
}
static void TOWXCollectLetters(UIView *view, NSMutableArray *out) { if ([view isKindOfClass:[UILabel class]]&&TOWXLabelLooksOriginal((UILabel *)view)) [out addObject:view]; for (UIView *v in view.subviews) TOWXCollectLetters(v,out); }
static BOOL TOWXOriginalScrollCandidate(UIScrollView *scroll) {
    if (!scroll || scroll==gProductScroll) return NO; CGFloat w=CGRectGetWidth(scroll.bounds),h=CGRectGetHeight(scroll.bounds); if (w<160||h<40||h>140) return NO;
    NSMutableArray *letters=[NSMutableArray array]; TOWXCollectLetters(scroll,letters); return letters.count>=3&&letters.count<=12;
}
static void TOWXSuppressOriginalScroll(UIScrollView *scroll) {
    if (!scroll) return; scroll.scrollEnabled=NO; scroll.userInteractionEnabled=NO; scroll.panGestureRecognizer.enabled=NO; scroll.backgroundColor=UIColor.clearColor;
    for (UIView *v in scroll.subviews) { v.hidden=YES; v.alpha=0; v.userInteractionEnabled=NO; }
}

@interface TOWXV9TapTarget : NSObject
+ (instancetype)shared;
- (void)slotTap:(UITapGestureRecognizer *)tap;
@end

static void TOWXLayoutBar(void);
static void TOWXEnsureBar(BOOL scanIfNeeded);

static void TOWXCreateBar(void) {
    if (gProductBar) return;
    gProductBar=[[UIView alloc] initWithFrame:CGRectZero]; gProductBar.backgroundColor=UIColor.clearColor; gProductBar.opaque=NO; gProductBar.clipsToBounds=NO;
    gProductScroll=[[UIScrollView alloc] initWithFrame:CGRectZero]; gProductScroll.backgroundColor=UIColor.clearColor; gProductScroll.opaque=NO; gProductScroll.clipsToBounds=YES;
    gProductScroll.showsHorizontalScrollIndicator=NO; gProductScroll.showsVerticalScrollIndicator=NO; gProductScroll.scrollEnabled=YES; gProductScroll.directionalLockEnabled=YES;
    gProductScroll.delaysContentTouches=YES; gProductScroll.canCancelContentTouches=YES; gProductScroll.bounces=YES; gProductScroll.decelerationRate=UIScrollViewDecelerationRateFast;
    [gProductBar addSubview:gProductScroll];
    for (NSUInteger i=0;i<TOWX_MAX_RECENTS;i++) {
        UIView *slot=[[UIView alloc] initWithFrame:CGRectZero]; slot.tag=(NSInteger)i; slot.clipsToBounds=YES; slot.backgroundColor=[UIColor colorWithWhite:0.45 alpha:0.08];
        UIImageView *iv=[[UIImageView alloc] initWithFrame:CGRectZero]; iv.tag=0x545750; iv.clipsToBounds=YES; iv.userInteractionEnabled=NO; [slot addSubview:iv];
        UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:[TOWXV9TapTarget shared] action:@selector(slotTap:)]; tap.cancelsTouchesInView=YES;
        [tap requireGestureRecognizerToFail:gProductScroll.panGestureRecognizer]; [slot addGestureRecognizer:tap]; [gProductScroll addSubview:slot]; gSlots[i]=slot;
        TOWXLog("TOWX|SB|P2A4|BAR-BIND|position=%lu|source=v9-tap-after-pan",(unsigned long)i);
    }
    TOWXLog("TOWX|SB|P2A4|PRODUCT-BAR-CREATE|ownership=host-window|gesture=pan-first");
    TOWXLog("TOWX|SB|P2A4|TOUCH-OWNERSHIP|tapRequiresPanFailure=yes|delaysContentTouches=yes|scrollAlwaysEnabled=yes");
}

static CGRect TOWXScaledFrame(UIWindow *window) {
    if (!gHasCalibration||!window||gCalibrationWindowSize.width<1||gCalibrationWindowSize.height<1) return CGRectZero;
    CGFloat sx=CGRectGetWidth(window.bounds)/gCalibrationWindowSize.width, sy=CGRectGetHeight(window.bounds)/gCalibrationWindowSize.height;
    return CGRectMake(gCalibrationFrameInWindow.origin.x*sx,gCalibrationFrameInWindow.origin.y*sy,gCalibrationFrameInWindow.size.width*sx,gCalibrationFrameInWindow.size.height*sy);
}
static BOOL TOWXHostMatches(UIWindow *w) {
    if (!gHasCalibration||!TOWXWindowVisible(w)||!gHostWindowClass.length) return NO;
    if (![NSStringFromClass(w.class) isEqualToString:gHostWindowClass]) return NO;
    if (fabs(w.windowLevel-gHostWindowLevel)>1.0) return NO;
    return YES;
}
static UIWindow *TOWXFindHostWindow(void) {
    UIWindow *last=gLastHostWindow; if (TOWXHostMatches(last)) return last;
    UIWindow *best=nil; CGFloat bestScore=CGFLOAT_MAX;
    for (UIWindow *w in TOWXAllWindows()) if (TOWXHostMatches(w)) {
        CGFloat score=fabs(w.bounds.size.width-gCalibrationWindowSize.width)+fabs(w.bounds.size.height-gCalibrationWindowSize.height);
        if (!best||score<bestScore) { best=w; bestScore=score; }
    }
    return best;
}
static void TOWXDetachBar(const char *reason) {
    if (!gProductBar) return; if (gBarVisible) TOWXLog("TOWX|SB|P2A4|BAR-HIDE|reason=%s",reason?:"unknown"); gBarVisible=NO;
    gProductBar.hidden=YES; gProductBar.userInteractionEnabled=NO; if (gProductBar.superview) { [gProductBar removeFromSuperview]; TOWXLog("TOWX|SB|P2A4|BAR-DETACH|reason=%s",reason?:"unknown"); }
}
static void TOWXAttachToHost(UIWindow *window,const char *mode) {
    if (!window||!TOWXWindowVisible(window)) return; CGRect frame=TOWXScaledFrame(window); if (CGRectGetWidth(frame)<160||CGRectGetHeight(frame)<40) return;
    TOWXCreateBar(); if (gProductBar.superview!=window) { [gProductBar removeFromSuperview]; [window addSubview:gProductBar]; }
    gProductBar.frame=frame; [window bringSubviewToFront:gProductBar]; gLastHostWindow=window;
    BOOL shouldShow=gWeChatActive&&gRemoteCount>0&&TOWXSessionGateVisible(); gProductBar.hidden=!shouldShow; gProductBar.userInteractionEnabled=shouldShow; gProductScroll.userInteractionEnabled=shouldShow;
    if (shouldShow&&!gBarVisible) TOWXLog("TOWX|SB|P2A4|BAR-SHOW|reason=%s|window=%p|frame={{%.1f,%.1f},{%.1f,%.1f}}",mode?:"host",window,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height);
    gBarVisible=shouldShow; TOWXLog("TOWX|SB|P2A4|BAR-RESTORE|mode=%s|window=%p|frame={{%.1f,%.1f},{%.1f,%.1f}}",mode?:"host",window,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height); TOWXLayoutBar();
}

static BOOL TOWXCalibrateFromScroll(UIScrollView *scroll) {
    if (!TOWXOriginalScrollCandidate(scroll)||!scroll.window) return NO; UIWindow *window=scroll.window; CGRect frame=[scroll convertRect:scroll.bounds toView:window];
    if (CGRectGetWidth(frame)<160||CGRectGetHeight(frame)<40) return NO;
    gSourceScroll=scroll; gHostWindowClass=[NSStringFromClass(window.class) copy]; gHostWindowLevel=window.windowLevel; gCalibrationWindowSize=window.bounds.size; gCalibrationFrameInWindow=frame; gHasCalibration=YES; gLastHostWindow=window;
    TOWXSuppressOriginalScroll(scroll); TOWXLog("TOWX|SB|P2A4|BAR-CALIBRATE|window=%p|windowClass=%s|level=%.1f|frameInWindow={{%.1f,%.1f},{%.1f,%.1f}}",window,gHostWindowClass.UTF8String?:"?",window.windowLevel,frame.origin.x,frame.origin.y,frame.size.width,frame.size.height);
    TOWXAttachToHost(window,"first-calibration-direct-window"); return YES;
}
static BOOL TOWXScanView(UIView *view) { if ([view isKindOfClass:[UIScrollView class]]&&TOWXCalibrateFromScroll((UIScrollView *)view)) return YES; for (UIView *v in view.subviews) if (TOWXScanView(v)) return YES; return NO; }
static BOOL TOWXScanOriginal(void) { for (UIWindow *w in TOWXAllWindows()) if (TOWXWindowVisible(w)&&TOWXScanView(w)) return YES; return NO; }

static void TOWXLayoutBar(void) {
    if (!gProductBar||!gProductBar.superview) return; NSUInteger count=MIN((NSUInteger)gRemoteCount,(NSUInteger)TOWX_MAX_RECENTS); CGFloat width=CGRectGetWidth(gProductBar.bounds),height=CGRectGetHeight(gProductBar.bounds); if (width<2||height<2) return;
    gProductBar.backgroundColor=UIColor.clearColor; gProductScroll.frame=gProductBar.bounds; CGFloat diameter=MIN(52.0,MAX(42.0,height-10.0)),spacing=8.0,total=diameter*count+spacing*(count?count-1:0),content=MAX(width,total+16.0),left=(total<=width-16.0)?floor((width-total)/2.0):8.0,y=floor((height-diameter)/2.0);
    gProductScroll.contentSize=CGSizeMake(content,height); gProductScroll.alwaysBounceHorizontal=content>width+1.0;
    for (NSUInteger i=0;i<TOWX_MAX_RECENTS;i++) { UIView *slot=gSlots[i]; BOOL available=i<count; slot.hidden=!available; if (!available) continue; slot.frame=CGRectMake(left+i*(diameter+spacing),y,diameter,diameter); slot.layer.cornerRadius=diameter/2.0; slot.layer.borderWidth=(gSelectedIndex==(NSInteger)i)?2.2:0.8; slot.layer.borderColor=(gSelectedIndex==(NSInteger)i?UIColor.systemGreenColor:[UIColor colorWithWhite:0.68 alpha:0.5]).CGColor; UIImageView *iv=(UIImageView *)[slot viewWithTag:0x545750]; iv.frame=CGRectInset(slot.bounds,2,2); iv.layer.cornerRadius=CGRectGetWidth(iv.bounds)/2.0; UIImage *img=gAvatars[i]; iv.image=img?:TOWXPlaceholder(); iv.contentMode=img?UIViewContentModeScaleAspectFill:UIViewContentModeScaleAspectFit; iv.tintColor=img?nil:UIColor.tertiaryLabelColor; iv.alpha=img?1.0:0.5; }
    static BOOL once=NO; if (!once) { once=YES; TOWXLog("TOWX|SB|P2A4|BAR-STYLE|mode=transparent-no-panel"); }
}

@implementation TOWXV9TapTarget
+ (instancetype)shared { static id x; static dispatch_once_t once; dispatch_once(&once,^{x=[self new];}); return x; }
- (void)slotTap:(UITapGestureRecognizer *)tap {
    if (tap.state!=UIGestureRecognizerStateRecognized||!gBarVisible||!gWeChatActive||!TOWXSessionGateVisible()) return;
    NSUInteger index=(NSUInteger)tap.view.tag; if (index>=MIN((NSUInteger)gRemoteCount,(NSUInteger)TOWX_MAX_RECENTS)) return;
    NSTimeInterval now=[NSDate timeIntervalSinceReferenceDate]; if (now-gLastTapAt<0.18) { TOWXLog("TOWX|SB|P2A4|TAP-DEBOUNCE|index=%lu",(unsigned long)index); return; } gLastTapAt=now;
    char name[96]; snprintf(name,sizeof(name),"%s%lu",TOWX_LINK_OPEN_PREFIX,(unsigned long)index); notify_post(name); TOWXLog("TOWX|SB|P2A4|TAP-SEND|index=%lu|gesture=tap-after-pan-failed",(unsigned long)index);
}
@end

static void TOWXEnsureBar(BOOL scanIfNeeded) {
    BOOL session=TOWXSessionGateVisible();
    if (!gWeChatActive||gRemoteCount==0||!session) { TOWXDetachBar(!session?"small-window-session-gone":(!gWeChatActive?"wechat-inactive":"count-zero")); return; }
    if (!gHasCalibration) { if (scanIfNeeded||1) (void)TOWXScanOriginal(); if (!gHasCalibration) return; }
    UIScrollView *source=gSourceScroll; if (source&&source.window&&TOWXWindowVisible(source.window)) { CGRect f=[source convertRect:source.bounds toView:source.window]; if (CGRectGetWidth(f)>=160&&CGRectGetHeight(f)>=40) { TOWXSuppressOriginalScroll(source); gCalibrationFrameInWindow=f; gCalibrationWindowSize=source.window.bounds.size; gLastHostWindow=source.window; } else { gSourceScroll=nil; TOWXLog("TOWX|SB|P2A4|STALE-SOURCE-DROP|frame={{%.1f,%.1f},{%.1f,%.1f}}",f.origin.x,f.origin.y,f.size.width,f.size.height); } }
    UIWindow *host=TOWXFindHostWindow(); if (host) TOWXAttachToHost(host,"session-host-window"); else TOWXDetachBar("host-window-missing");
}

static void TOWXHandleReady(void) {
    uint64_t gen=0,count=0,stage=0,active=0; if (!TOWXReadState(gGenerationToken,&gen)||!TOWXReadState(gCountToken,&count)||!TOWXReadState(gStageToken,&stage)) return; (void)TOWXReadState(gAppActiveToken,&active);
    gRemoteCount=MIN(count,(uint64_t)TOWX_MAX_RECENTS); gRemoteStage=stage; gWeChatActive=active!=0;
    TOWXLog("TOWX|SB|P2A4|READY-RECV|generation=%llu|stage=%llu|stageName=%s|count=%llu|wechatActive=%d",(unsigned long long)gen,(unsigned long long)stage,TOWXStageName(stage),(unsigned long long)count,gWeChatActive?1:0);
    dispatch_async(dispatch_get_main_queue(),^{ NSUInteger loaded=(gRemoteCount>0)?TOWXLoadAvatars():0; TOWXEnsureBar(YES); TOWXLog("TOWX|SB|P2A4|SYNC|count=%llu|loaded=%lu|bar=%s|session=%s|host=%s|stage=%llu",(unsigned long long)gRemoteCount,(unsigned long)loaded,gBarVisible?"visible":"hidden",TOWXSessionGateVisible()?"live":"gone",TOWXFindHostWindow()?"ready":"missing",(unsigned long long)gRemoteStage); });
}
static void TOWXHandleAck(void) { uint64_t index=UINT64_MAX; if (!TOWXReadState(gAckIndexToken,&index)) return; gSelectedIndex=index<TOWX_MAX_RECENTS?(NSInteger)index:NSNotFound; TOWXLog("TOWX|SB|P2A4|OPEN-ACK|index=%llu",(unsigned long long)index); dispatch_async(dispatch_get_main_queue(),^{TOWXLayoutBar();}); }

static void TOWXWindowVisible(UIWindow *window) {
    NSString *cls=window?NSStringFromClass(window.class):@""; TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=window-visible|window=%p|class=%s|level=%.1f",window,cls.UTF8String?:"nil",window?window.windowLevel:0);
    if ([cls isEqualToString:TOWX_SESSION_GATE_CLASS]) { TOWXLog("TOWX|SB|P2A4|SESSION-GATE|state=visible|window=%p",window); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,60*NSEC_PER_MSEC),dispatch_get_main_queue(),^{TOWXEnsureBar(YES);}); dispatch_after(dispatch_time(DISPATCH_TIME_NOW,220*NSEC_PER_MSEC),dispatch_get_main_queue(),^{TOWXEnsureBar(YES);}); }
}
static void TOWXWindowHidden(UIWindow *window) {
    NSString *cls=window?NSStringFromClass(window.class):@""; TOWXLog("TOWX|SB|P2A4|LIFECYCLE|reason=window-hidden|window=%p|class=%s",window,cls.UTF8String?:"nil"); if ([cls isEqualToString:TOWX_SESSION_GATE_CLASS]) { TOWXLog("TOWX|SB|P2A4|SESSION-GATE|state=hidden|window=%p",window); TOWXDetachBar("session-gate-hidden"); }
}
static void TOWXInstallLifecycle(void) {
    NSNotificationCenter *c=NSNotificationCenter.defaultCenter;
    [c addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){TOWXWindowVisible([n.object isKindOfClass:[UIWindow class]]?(UIWindow *)n.object:nil);}];
    [c addObserverForName:UIWindowDidBecomeHiddenNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n){TOWXWindowHidden([n.object isKindOfClass:[UIWindow class]]?(UIWindow *)n.object:nil);}];
    [c addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *n){TOWXEnsureBar(YES);}];
}
static void TOWXStartTimer(void) {
    gUITimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue()); if (!gUITimer) return;
    dispatch_source_set_timer(gUITimer,dispatch_time(DISPATCH_TIME_NOW,0),NSEC_PER_SEC/5,NSEC_PER_SEC/50);
    dispatch_source_set_event_handler(gUITimer,^{ static unsigned tick=0; tick++; if (tick%10==0&&gRemoteCount>0) (void)TOWXLoadAvatars(); TOWXEnsureBar((tick%5)==0&&!gHasCalibration); }); dispatch_resume(gUITimer);
}

__attribute__((constructor)) static void TOWXV9Init(void) {
    TOWXLog("TOWX|SB|P2A4|LOADED|v0.9.0|mode=session-gate+direct-host-window+pan-first+transparent");
    if (!TOWXRegisterState(TOWX_LINK_GENERATION,&gGenerationToken)||!TOWXRegisterState(TOWX_LINK_COUNT,&gCountToken)||!TOWXRegisterState(TOWX_LINK_STAGE,&gStageToken)||!TOWXRegisterState(TOWX_LINK_ACK_INDEX,&gAckIndexToken)||!TOWXRegisterState(TOWX_LINK_APP_ACTIVE,&gAppActiveToken)) return;
    dispatch_queue_t q=dispatch_queue_create("com.dream.towx.p2a4.receiver.v9",DISPATCH_QUEUE_SERIAL);
    notify_register_dispatch(TOWX_LINK_READY,&gReadyToken,q,^(int t){(void)t;TOWXHandleReady();}); notify_register_dispatch(TOWX_LINK_ACK,&gAckToken,q,^(int t){(void)t;TOWXHandleAck();}); TOWXLog("TOWX|SB|P2A4|LISTENERS-READY");
    dispatch_async(dispatch_get_main_queue(),^{TOWXInstallLifecycle();TOWXStartTimer();TOWXEnsureBar(YES);});
}
