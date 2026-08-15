#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#include <notify.h>
#include <stdint.h>

#define TOWX_LINK_READY "com.dream.towx.link.ready"
#define TOWX_LINK_APP_ACTIVE "com.dream.towx.link.appActive"

static int gActiveToken = 0;

static BOOL TOWXApplicationIsActive(void) {
    return UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
}

static void TOWXPublishActive(BOOL active, NSString *reason) {
    if (gActiveToken == 0) return;
    (void)notify_set_state(gActiveToken, active ? 1 : 0);
    notify_post(TOWX_LINK_READY);
    NSLog(@"TOWX|WX|PASSIVE-STATE|active=%d|reason=%@", active ? 1 : 0, reason ?: @"unknown");
}

__attribute__((constructor)) static void TOWXWeChatPassiveStateInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        uint32_t status = notify_register_check(TOWX_LINK_APP_ACTIVE, &gActiveToken);
        if (status != NOTIFY_STATUS_OK) {
            NSLog(@"TOWX|WX|PASSIVE-STATE|register-fail=%u", status);
            return;
        }

        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            TOWXPublishActive(YES, @"app-active");
        }];
        [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            TOWXPublishActive(NO, @"app-resign");
        }];
        [center addObserverForName:UISceneDidActivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            TOWXPublishActive(TOWXApplicationIsActive(), @"scene-active");
        }];
        [center addObserverForName:UISceneWillDeactivateNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) {
            TOWXPublishActive(NO, @"scene-deactivate");
        }];

        TOWXPublishActive(TOWXApplicationIsActive(), @"startup");
        NSLog(@"TOWX|WX|PASSIVE-STATE|LOADED|Fix8|global-uiview-hooks=0|guard-timer=0|lifecycle-only");
    });
}
