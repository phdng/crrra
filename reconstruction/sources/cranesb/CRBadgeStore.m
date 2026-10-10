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
static void CRBadgeStoreReconcileContainerKeys(void);
static BOOL CRBadgeRedirectionEnabled(NSString *appID);

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
        CRBadgeStoreReconcileContainerKeys();
    });
}

/* 0xB00C: LSApplicationProxy reports whether a bundle is installed.
 * Unknown API/class state must never be treated as proof of uninstall. */
static BOOL CRBadgeApplicationConfirmedUninstalled(NSString *appID)
{
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL lookupSEL = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:lookupSEL])
        return NO;
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(proxyClass, lookupSEL, appID);
    SEL installedSEL = NSSelectorFromString(@"isInstalled");
    if (!proxy || ![proxy respondsToSelector:installedSEL])
        return NO;
    return !((BOOL (*)(id, SEL))objc_msgSend)(proxy, installedSEL);
}

/* 0xA658: read current icon badge without initializing the badge store.
 * A missing private API returns nil, not a fabricated count of zero. */
static NSNumber *CRBadgeExistingIconCount(NSString *appID)
{
    Class stateClass = NSClassFromString(@"UISApplicationState");
    SEL initSEL = NSSelectorFromString(@"initWithBundleIdentifier:");
    SEL getSEL = NSSelectorFromString(@"badgeValue");
    id value = nil;
    if (stateClass && [stateClass instancesRespondToSelector:initSEL]) {
        id state = ((id (*)(id, SEL, id))objc_msgSend)(
            [stateClass alloc], initSEL, appID);
        if ([state respondsToSelector:getSEL])
            value = ((id (*)(id, SEL))objc_msgSend)(state, getSEL);
    } else {
        Class serviceClass = NSClassFromString(@"FBSSystemService");
        SEL sharedSEL = NSSelectorFromString(@"sharedService");
        SEL serviceGetSEL = NSSelectorFromString(@"badgeValueForBundleID:");
        if ([serviceClass respondsToSelector:sharedSEL]) {
            id service = ((id (*)(id, SEL))objc_msgSend)(
                serviceClass, sharedSEL);
            if ([service respondsToSelector:serviceGetSEL])
                value = ((id (*)(id, SEL, id))objc_msgSend)(
                    service, serviceGetSEL, appID);
        }
    }
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

/* 0xB00C/0xB688: discard stored entries for containers that no longer
 * exist. Keep apps whose container registry is unavailable untouched, so a
 * transient manager failure does not destroy persisted badge data. */
static void CRBadgeStoreReconcileContainerKeys(void)
{
    CraneManager *manager = CraneManager.sharedManager;
    BOOL changed = NO;
    NSDictionary *snapshot = [gCRBadgeStore copy];
    for (id appID in snapshot) {
        id counts = snapshot[appID];
        if (![appID isKindOfClass:[NSString class]] ||
            ![counts isKindOfClass:[NSDictionary class]])
            continue;
        if (CRBadgeApplicationConfirmedUninstalled(appID)) {
            [gCRBadgeStore removeObjectForKey:appID];
            changed = YES;
            continue;
        }
        /* 0xB00C also drops stored counts when redirection is disabled.
         * Only apply after a usable registry lookup, avoiding destructive
         * cleanup during transient initialization or unavailable services. */
        NSArray *validIDs =
            [manager containerIdentifiersOfApplicationWithIdentifier:appID];
        if (![validIDs isKindOfClass:[NSArray class]] || !validIDs.count)
            continue;
        if (!CRBadgeRedirectionEnabled(appID)) {
            [gCRBadgeStore removeObjectForKey:appID];
            changed = YES;
            continue;
        }
        NSMutableDictionary *updated = [counts mutableCopy];
        for (id containerID in counts) {
            if (![validIDs containsObject:containerID])
                [updated removeObjectForKey:containerID];
        }
        /* 0xB00C reconciles persisted positive counts with the icon's
         * existing badge by storing that count under DEFAULT. */
        NSNumber *iconCount = CRBadgeExistingIconCount(appID);
        if (iconCount && [validIDs containsObject:@"DEFAULT"]) {
            NSInteger storedPositive = 0;
            for (id countValue in [counts allValues]) {
                if ([countValue respondsToSelector:@selector(integerValue)]) {
                    NSInteger count = [countValue integerValue];
                    if (count > 0)
                        storedPositive += count;
                }
            }
            if (storedPositive != [iconCount integerValue])
                updated[@"DEFAULT"] = iconCount;
        }
        if (![updated isEqualToDictionary:counts]) {
            gCRBadgeStore[appID] = [updated copy];
            changed = YES;
        }
    }
    if (changed)
        [gCRBadgeStore writeToFile:CRBadgeStorePath() atomically:YES];
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
static NSInteger CRBadgeAggregateCount(NSString *appID, BOOL validate);

static void CRBadgeProjectApplicationCount(NSString *appID, BOOL validate)
{
    if (!appID.length)
        return;
    NSInteger count = CRBadgeAggregateCount(appID, validate);
    NSNumber *value = @(count);
    Class stateClass = NSClassFromString(@"UISApplicationState");
    SEL initSEL = NSSelectorFromString(@"initWithBundleIdentifier:");
    SEL setSEL = NSSelectorFromString(@"setBadgeValue:");
    if (stateClass && [stateClass instancesRespondToSelector:initSEL]) {
        id state = ((id (*)(id, SEL, id))objc_msgSend)(
            [stateClass alloc], initSEL, appID);
        if ([state respondsToSelector:setSEL]) {
            ((void (*)(id, SEL, id))objc_msgSend)(state, setSEL, value);
            return;
        }
    }
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL sharedSEL = NSSelectorFromString(@"sharedService");
    SEL fallbackSEL = NSSelectorFromString(@"setBadgeValue:forBundleID:");
    if (![serviceClass respondsToSelector:sharedSEL])
        return;
    id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, sharedSEL);
    if ([service respondsToSelector:fallbackSEL])
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            service, fallbackSEL, value, appID);
}

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
    CRBadgeProjectApplicationCount(appID, NO);
}

static void CRResetContainerBadge(id self, SEL cmd, NSString *containerID,
                                  NSString *appID)
{
    (void)self; (void)cmd;
    if (containerID.length && appID.length) {
        CRBadgeStoreSetContainerCount(appID, containerID, 0);
        CRBadgeProjectApplicationCount(appID, YES);
    }
}

/* 0xBB04 / 0xFBB4 / 0xFCA8: the per-container identity is carried
 * by the notification save thread, not inferred from the active container. */
static IMP gCRBadgeQueueSetterOriginal;
static IMP gCRBadgePrivateSetterOriginal;
static BOOL CRBadgeRedirectionEnabled(NSString *appID);
static IMP gCRBadgePublicSetterOriginal;

/* CraneSB 0xA4A0: prefer the source process PID's container cache.
 * Never replace a missing cache result with the app's currently active ID. */
static NSString *CRBadgeContainerForConnection(NSXPCConnection *connection)
{
    Class cacheClass = NSClassFromString(@"ClientContainerCache");
    SEL sharedSEL = NSSelectorFromString(@"sharedInstance");
    SEL activeSEL = NSSelectorFromString(@"activeContainerIdentifierForPid:");
    if (!connection || !cacheClass ||
        ![cacheClass respondsToSelector:sharedSEL])
        return nil;
    id cache = ((id (*)(id, SEL))objc_msgSend)(cacheClass, sharedSEL);
    if (![cache respondsToSelector:activeSEL])
        return nil;
    pid_t pid = [connection processIdentifier];
    if (pid <= 0)
        return nil;
    id result = ((id (*)(id, SEL, pid_t))objc_msgSend)(cache, activeSEL, pid);
    return [result isKindOfClass:[NSString class]] ? result : nil;
}

/* 0xFD9C: public setter uses current XPC caller rather than save-thread ID.
 * On unknown caller identity, preserve Apple's setter without store mutation. */
static void CRBadgePublicSet(id self, SEL cmd, NSNumber *number,
                             NSString *appID, id completion)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gCRBadgePublicSetterOriginal;
    if (!original)
        return;
    if (CRBadgeRedirectionEnabled(appID) &&
        [number respondsToSelector:@selector(integerValue)]) {
        SEL currentSEL = NSSelectorFromString(@"currentConnection");
        NSXPCConnection *connection =
            [NSXPCConnection respondsToSelector:currentSEL]
                ? ((id (*)(id, SEL))objc_msgSend)([NSXPCConnection class], currentSEL)
                : nil;
        if (connection) {
            NSString *container = CRBadgeContainerForConnection(connection);
            if (!container.length)
                container = @"DEFAULT";
            CRBadgeStoreSetContainerCount(appID, container,
                                          [number integerValue]);
        }
    }
    original(self, cmd, number, appID, completion);
}


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

/* 0xAA00/0xAB44: preserve the negative-only fallback when positive
 * badge counts sum to zero (e.g. special system badge sentinel values). */
static NSInteger CRBadgeAggregateCount(NSString *appID, BOOL validate)
{
    if (!appID.length)
        return 0;
    CRBadgeStoreInitialize();
    NSDictionary *snapshot;
    @synchronized (gCRBadgeStoreLock) {
        id appCounts = gCRBadgeStore[appID];
        snapshot = [appCounts isKindOfClass:[NSDictionary class]]
            ? [appCounts copy] : @{};
    }
    NSInteger positive = 0;
    NSInteger negative = 0;
    for (id identifier in snapshot) {
        if (![identifier isKindOfClass:[NSString class]])
            continue;
        NSInteger count = CRBadgeStoreContainerCount(appID, identifier, validate);
        if (count >= 0)
            positive += count;
        else
            negative += count;
    }
    return positive != 0 ? positive : (negative < 0 ? negative : 0);
}

/* 0xBD98/0xBE80: remove only records belonging to the container whose
 * badge was cleared, using crane_sourceContainerID from the record userInfo. */
static void CRBadgeRemoveRecordsForContainer(id repository,
                                              NSString *appID,
                                              NSString *containerID,
                                              BOOL queued)
{
    NSString *selectorName = queued
        ? @"_queue_removeNotificationRecordsPassingTest:forBundleIdentifier:"
        : @"removeNotificationRecordsPassingTest:forBundleIdentifier:";
    SEL selector = NSSelectorFromString(selectorName);
    if (![repository respondsToSelector:selector])
        return;
    BOOL (^predicate)(id) = ^BOOL(id record) {
        id info = [record respondsToSelector:@selector(userInfo)]
            ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo))
            : nil;
        if (![info isKindOfClass:[NSDictionary class]])
            return NO;
        id source = info[@"crane_sourceContainerID"] ?: @"DEFAULT";
        return [source isKindOfClass:[NSString class]] &&
               [source isEqualToString:containerID];
    };
    ((void (*)(id, SEL, id, id))objc_msgSend)(
        repository, selector, predicate, appID);
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
        if ([number isEqualToNumber:@0]) {
            CRBadgeRemoveRecordsForContainer(self, appID, containerID,
                                             originalIMP == gCRBadgeQueueSetterOriginal);
        }
    }

    NSNumber *aggregate = @(CRBadgeAggregateCount(appID, YES));
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

/* 0xBF00/0x10138: preserve container identity for the duration of the
 * repository's synchronous save path, including its badge setter calls.
 * The source ID belongs to record.userInfo; never infer active container. */
static IMP gCRBadgeSaveRecordOriginal;

static void CRBadgeSaveRecord(id self, SEL cmd, id record,
                              id options, NSString *appID)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gCRBadgeSaveRecordOriginal;
    if (!original)
        return;

    id info = [record respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo))
        : nil;
    NSString *containerID = nil;
    if ([info isKindOfClass:[NSDictionary class]] && appID.length) {
        id source = info[@"crane_sourceContainerID"];
        if ([source isKindOfClass:[NSString class]] && [source length])
            containerID = source;
        else if (CRBadgeRedirectionEnabled(appID))
            containerID = @"DEFAULT";
    }
    if (!containerID) {
        original(self, cmd, record, options, appID);
        return;
    }

    NSMutableDictionary *threadInfo = [NSThread currentThread].threadDictionary;
    NSString *key = @"saveNotification_containerID";
    id previous = threadInfo[key];
    threadInfo[key] = containerID;
    @try {
        original(self, cmd, record, options, appID);
    } @finally {
        if (previous)
            threadInfo[key] = previous;
        else
            [threadInfo removeObjectForKey:key];
    }
}

/* 0xFF30 and 0x10050 wrap the same synchronous queue save context,
 * but their native selector argument lists are distinct. */
static NSString *CRBadgeSourceForRecord(id record, NSString *appID);
static IMP gCRBadgeOuterSaveOriginal;
static IMP gCRBadgeSaveRevisionOriginal;
static IMP gCRBadgeSaveOptionsOriginal;

/* CraneSB 0xF254: outer save path. This establishes the source context
 * while the original synchronous call executes; the separate foreground
 * queue propagation is not yet reconstructed. */
static void CRBadgeOuterSave(id self, SEL cmd, id record, BOOL repost,
                             NSString *appID, id completion)
{
    void (*original)(id, SEL, id, BOOL, id, id) =
        (void (*)(id, SEL, id, BOOL, id, id))gCRBadgeOuterSaveOriginal;
    if (!original)
        return;
    NSString *container = CRBadgeSourceForRecord(record, appID);
    NSMutableDictionary *threadInfo = [NSThread currentThread].threadDictionary;
    NSString *key = @"saveNotification_containerID";
    id previous = threadInfo[key];
    if (container)
        threadInfo[key] = container;
    @try {
        original(self, cmd, record, repost, appID, completion);
    } @finally {
        if (container) {
            if (previous)
                threadInfo[key] = previous;
            else
                [threadInfo removeObjectForKey:key];
        }
    }
}

static NSString *CRBadgeSourceForRecord(id record, NSString *appID)
{
    id info = [record respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo))
        : nil;
    if (![info isKindOfClass:[NSDictionary class]] || !appID.length)
        return nil;
    id source = info[@"crane_sourceContainerID"];
    if ([source isKindOfClass:[NSString class]] && [source length])
        return source;
    return CRBadgeRedirectionEnabled(appID) ? @"DEFAULT" : nil;
}

static void CRBadgeSaveRevision(id self, SEL cmd, id record, id revision,
                                BOOL repost, id options, NSString *appID)
{
    void (*original)(id, SEL, id, id, BOOL, id, id) =
        (void (*)(id, SEL, id, id, BOOL, id, id))gCRBadgeSaveRevisionOriginal;
    if (!original)
        return;
    NSString *container = CRBadgeSourceForRecord(record, appID);
    NSMutableDictionary *dict = [NSThread currentThread].threadDictionary;
    id previous = dict[@"saveNotification_containerID"];
    if (container)
        dict[@"saveNotification_containerID"] = container;
    @try {
        original(self, cmd, record, revision, repost, options, appID);
    } @finally {
        if (container) {
            if (previous)
                dict[@"saveNotification_containerID"] = previous;
            else
                [dict removeObjectForKey:@"saveNotification_containerID"];
        }
    }
}

static void CRBadgeSaveOptions(id self, SEL cmd, id record, BOOL repost,
                               id options, NSString *appID)
{
    void (*original)(id, SEL, id, BOOL, id, id) =
        (void (*)(id, SEL, id, BOOL, id, id))gCRBadgeSaveOptionsOriginal;
    if (!original)
        return;
    NSString *container = CRBadgeSourceForRecord(record, appID);
    NSMutableDictionary *dict = [NSThread currentThread].threadDictionary;
    id previous = dict[@"saveNotification_containerID"];
    if (container)
        dict[@"saveNotification_containerID"] = container;
    @try {
        original(self, cmd, record, repost, options, appID);
    } @finally {
        if (container) {
            if (previous)
                dict[@"saveNotification_containerID"] = previous;
            else
                [dict removeObjectForKey:@"saveNotification_containerID"];
        }
    }
}

void CRInitBadgeRepositoryHooks(void)
{
    Class repository = NSClassFromString(@"UNSNotificationRepository");
    if (!repository)
        repository = NSClassFromString(@"UNCLocalNotificationRepository");
    if (!repository)
        return;
    SEL outerSEL = NSSelectorFromString(
        @"saveNotificationRecord:shouldRepost:forBundleIdentifier:withCompletionHandler:");
    if ([repository instancesRespondToSelector:outerSEL])
        MSHookMessageEx(repository, outerSEL, (IMP)CRBadgeOuterSave,
                        &gCRBadgeOuterSaveOriginal);
    SEL saveSEL = NSSelectorFromString(
        @"_queue_saveNotificationRecord:withOptions:forBundleIdentifier:");
    if ([repository instancesRespondToSelector:saveSEL])
        MSHookMessageEx(repository, saveSEL, (IMP)CRBadgeSaveRecord,
                        &gCRBadgeSaveRecordOriginal);
    SEL revisionSEL = NSSelectorFromString(
        @"_queue_saveNotificationRecord:targetRevisionNumber:shouldRepost:withOptions:forBundleIdentifier:");
    if ([repository instancesRespondToSelector:revisionSEL])
        MSHookMessageEx(repository, revisionSEL, (IMP)CRBadgeSaveRevision,
                        &gCRBadgeSaveRevisionOriginal);
    SEL optionsSEL = NSSelectorFromString(
        @"_queue_saveNotificationRecord:shouldRepost:withOptions:forBundleIdentifier:");
    if ([repository instancesRespondToSelector:optionsSEL])
        MSHookMessageEx(repository, optionsSEL, (IMP)CRBadgeSaveOptions,
                        &gCRBadgeSaveOptionsOriginal);
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
    SEL publicSEL = NSSelectorFromString(
        @"setBadgeNumber:forBundleIdentifier:withCompletionHandler:");
    if ([repository instancesRespondToSelector:publicSEL])
        MSHookMessageEx(repository, publicSEL, (IMP)CRBadgePublicSet,
                        &gCRBadgePublicSetterOriginal);
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
