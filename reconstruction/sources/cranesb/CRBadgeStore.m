/*
 * F-08 persisted badge-count store, recovered from CraneSB 0xA860,
 * 0xA990, 0xAC68, 0xACD0, 0xAE20 and 0x11BB8.
 *
 * Store shape: app bundle identifier -> container identifier -> NSNumber.
 * Notification hooks that call CRBadgeStoreSetContainerCount are not yet wired.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"

void CRBadgeStoreSetContainerCount(NSString *appID, NSString *containerID, NSInteger count);

static NSMutableDictionary *gCRBadgeStore;
static NSObject *gCRBadgeStoreLock;

static NSString *CRBadgeStorePath(void)
{
    return CRJailbreakRootPath(CR_BADGE_STORE_PATH);
}

void CRBadgeStoreInitialize(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gCRBadgeStoreLock = [NSObject new];
        NSDictionary *saved =
            [NSDictionary dictionaryWithContentsOfFile:CRBadgeStorePath()];
        gCRBadgeStore = [saved isKindOfClass:[NSDictionary class]]
            ? [saved mutableCopy] : [NSMutableDictionary new];
    });
}

NSInteger CRBadgeStoreContainerCount(NSString *appID,
                                    NSString *containerID,
                                    BOOL validateContainer)
{
    if (!appID.length || !containerID.length)
        return 0;
    if (validateContainer) {
        NSArray *identifiers = [CraneManager.sharedManager
            containerIdentifiersOfApplicationWithIdentifier:appID];
        if (![identifiers containsObject:containerID])
            return 0;
    }
    CRBadgeStoreInitialize();
    @synchronized (gCRBadgeStoreLock) {
        NSDictionary *counts = gCRBadgeStore[appID];
        id value = [counts isKindOfClass:[NSDictionary class]]
            ? counts[containerID] : nil;
        return [value respondsToSelector:@selector(integerValue)]
            ? [value integerValue] : 0;
    }
}

/* CraneSB 0x10BEC/0x10CB0: notification-listener badge lifecycle RPCs. */
static void CRSwitchContainerBadges(id self, SEL cmd, NSString *first,
                                   NSString *second, NSString *appID)
{
    (void)self; (void)cmd;
    if (!first.length || !second.length || !appID.length)
        return;
    NSInteger firstCount = CRBadgeStoreContainerCount(appID, first, NO);
    NSInteger secondCount = CRBadgeStoreContainerCount(appID, second, NO);
    CRBadgeStoreSetContainerCount(appID, second, firstCount);
    CRBadgeStoreSetContainerCount(appID, first, secondCount);
}

static void CRResetContainerBadge(id self, SEL cmd, NSString *containerID,
                                  NSString *appID)
{
    (void)self; (void)cmd;
    if (containerID.length && appID.length)
        CRBadgeStoreSetContainerCount(appID, containerID, 0);
}

void CRInitBadgeListenerMethods(void)
{
    Class listener = NSClassFromString(
        @"UNSUserNotificationServerConnectionListener");
    if (!listener)
        return;
    class_addMethod(listener,
        NSSelectorFromString(@"crane_switchBadgesOfContainerWithIdentifier:andContainerWithIdentifier:ofApplicationWithIdentifier:"),
        (IMP)CRSwitchContainerBadges, "v@:@@@");
    class_addMethod(listener,
        NSSelectorFromString(@"crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:"),
        (IMP)CRResetContainerBadge, "v@:@@");
}

void CRBadgeStoreSetContainerCount(NSString *appID,
                                   NSString *containerID,
                                   NSInteger count)
{
    if (!appID.length || !containerID.length)
        return;
    CRBadgeStoreInitialize();
    @synchronized (gCRBadgeStoreLock) {
        NSDictionary *previous = gCRBadgeStore[appID];
        NSMutableDictionary *counts =
            [previous isKindOfClass:[NSDictionary class]]
                ? [previous mutableCopy] : [NSMutableDictionary new];
        if (count != 0)
            counts[containerID] = @(count);
        else
            [counts removeObjectForKey:containerID];
        gCRBadgeStore[appID] = [counts copy];
        [gCRBadgeStore writeToFile:CRBadgeStorePath() atomically:YES];
    }
}
