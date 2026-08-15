#import "TOWXV11SplitIdentity.h"
#import "TOWXV11SessionController.h"
#import "TOWXV11Diagnostics.h"

__attribute__((constructor)) static void TOWXV11SplitIdentityBridgeInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        TOWXV11SplitIdentityStart();
        [NSNotificationCenter.defaultCenter addObserverForName:TOWXV11SplitIdentityDidChangeNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *note) {
            UIWindow *session = TOWXV11CurrentSessionWindow();
            TOWXV11DiagLog("SPLIT", "SYNC-AVATAR|fix=7|bundle=%s|source=%s",
                           TOWXV11SplitBundleIdentifier().UTF8String ?: "?",
                           TOWXV11SplitBundleSource().UTF8String ?: "?");
            [NSNotificationCenter.defaultCenter postNotificationName:TOWXV11SessionDidChangeNotification
                                                                object:session
                                                              userInfo:@{ @"epoch": @(TOWXV11CurrentSessionEpoch()),
                                                                          @"visible": @(TOWXV11SessionIsVisible()),
                                                                          @"bundleID": TOWXV11SplitBundleIdentifier() ?: @"" }];
        }];
    });
}
