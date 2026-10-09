/*
 * F-08 persisted badge-count store, recovered from CraneSB 0xA860,
 * 0xA990, 0xAC68, 0xACD0, 0xAE20 and 0x11BB8.
 *
 * Store shape: app bundle identifier -> container identifier -> NSNumber.
 * Notification hooks that call CRBadgeStoreSetContainerCount are not yet wired.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
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

/* 0xBB04 / 0xFBB4 / 0xFCA8: the per-container identity is carried
 * by the notification save thread, not inferred from the active container. */
static IMP gCRBadgeQueueSetterOriginal;
static IMP gCRBadgePrivateSetterOriginal;

static BOOL CRBadgeRedirectionEnabled(NSString *appID)
{
    if (!appID.length)
        return NO;
    CraneManager *manager = CraneManager.sharedManager;
    NSArray *containers =
        [manager containerIdentifiersOfApplicationWithIdentifier:appID];
    if (containers.count < 2)
        return NO;
    id global = [manager preferenceValueForKey:@"notificationsSupportEnabled"];
    if (global && ![global boolValue])
        return NO;
    NSDictionary *settings =
        [manager applicationSettingsForApplicationWithIdentifier:appID];
    id perApp = settings[@"separateNotificationRegistrationsEnabled"];
    return !perApp || [perApp boolValue];
}

static NSInteger CRBadgeAggregateCount(NSString *appID)
{
    NSArray *containers = [CraneManager.sharedManager
        containerIdentifiersOfApplicationWithIdentifier:appID];
    NSInteger total = 0;
    for (NSString *identifier in containers) {
        NSInteger count = CRBadgeStoreContainerCount(appID, identifier, NO);
        if (count > 0)
            total += count;
    }
    return total;
}

static void CRBadgePrivateSet(id self, SEL cmd, NSNumber *number,
                              NSString *appID, id completion, IMP originalIMP)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))originalIMP;
    if (!original)
        return;
    if (!CRBadgeRedirectionEnabled(appID)) {
        original(self, cmd, number, appID, completion);
        return;
    }

    id containerID = [NSThread currentThread].threadDictionary[
        @"saveNotification_containerID"];
    if ([containerID isKindOfClass:[NSString class]] &&
        [containerID length] && [number respondsToSelector:@selector(integerValue)]) {
        CRBadgeStoreSetContainerCount(appID, containerID,
                                     [number integerValue]);
    }

    NSNumber *aggregate = @(CRBadgeAggregateCount(appID));
    original(self, cmd, aggregate, appID, completion);
}

static void CRBadgeQueueSet(id self, SEL cmd, NSNumber *number,
                            NSString *appID, id completion)
{
    CRBadgePrivateSet(self, cmd, number, appID, completion,
                      gCRBadgeQueueSetterOriginal);
}

static void CRBadgeNonQueueSet(id self, SEL cmd, NSNumber *number,
                               NSString *appID, id completion)
{
    CRBadgePrivateSet(self, cmd, number, appID, completion,
                      gCRBadgePrivateSetterOriginal);
}

void CRInitBadgeRepositoryHooks(void)
{
    Class repository = NSClassFromString(@"UNSNotificationRepository");
    if (!repository)
        repository = NSClassFromString(@"UNCLocalNotificationRepository");
    if (!repository)
        return;
    SEL queued = NSSelectorFromString(
        @"_queue_setBadgeNumber:forBundleIdentifier:withCompletionHandler:");
    SEL nonQueued = NSSelectorFromString(
        @"_setBadgeNumber:forBundleIdentifier:withCompletionHandler:");
    if ([repository instancesRespondToSelector:queued])
        MSHookMessageEx(repository, queued, (IMP)CRBadgeQueueSet,
                        &gCRBadgeQueueSetterOriginal);
    if ([repository instancesRespondToSelector:nonQueued])
        MSHookMessageEx(repository, nonQueued, (IMP)CRBadgeNonQueueSet,
                        &gCRBadgePrivateSetterOriginal);
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
