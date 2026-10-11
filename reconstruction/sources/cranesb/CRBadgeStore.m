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
            for (id countValue in [updated allValues]) {
                if ([countValue respondsToSelector:@selector(integerValue)]) {
                    NSInteger count = [countValue integerValue];
                    if (count > 0)
                        storedPositive += count;
                }
            }
            if (storedPositive != [iconCount integerValue]) {
                if ([iconCount integerValue] == 0)
                    [updated removeObjectForKey:@"DEFAULT"];
                else
                    updated[@"DEFAULT"] = iconCount;
            }
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

/* 0x104AC/0x1235C: attach source container to incoming request content.
 * The DEFAULT container deliberately carries no extra metadata. */
static IMP gCRBadgeAddRequestsOriginal;

static void CRBadgeAddRequests(id self, SEL cmd, NSArray *requests,
                               NSString *appID, id completion)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gCRBadgeAddRequestsOriginal;
    if (!original)
        return;
    if (CRBadgeRedirectionEnabled(appID) &&
        [requests isKindOfClass:[NSArray class]]) {
        SEL currentSEL = NSSelectorFromString(@"currentConnection");
        NSXPCConnection *connection =
            [NSXPCConnection respondsToSelector:currentSEL]
                ? ((id (*)(id, SEL))objc_msgSend)(
                    [NSXPCConnection class], currentSEL) : nil;
        NSString *container = CRBadgeContainerForConnection(connection);
        if (container.length && ![container isEqualToString:@"DEFAULT"]) {
            for (id request in requests) {
                if (![request respondsToSelector:@selector(content)])
                    continue;
                id content = ((id (*)(id, SEL))objc_msgSend)(
                    request, @selector(content));
                if (![content respondsToSelector:@selector(userInfo)])
                    continue;
                id info = ((id (*)(id, SEL))objc_msgSend)(
                    content, @selector(userInfo));
                if (![info isKindOfClass:[NSDictionary class]])
                    continue;
                NSMutableDictionary *tagged = [info mutableCopy];
                tagged[@"crane_sourceContainerID"] = container;
                @try {
                    [content setValue:[tagged copy] forKey:@"_userInfo"];
                } @catch (NSException *exception) {
                    (void)exception;
                }
            }
        }
    }
    original(self, cmd, requests, appID, completion);
}

/* 0x1072C: the single-request save path carries the same source
 * metadata as the bulk add path; preserve BOOL shouldRepost ABI. */
static IMP gCRBadgeSaveRequestOriginal;

static void CRBadgeSaveRequest(id self, SEL cmd, id request, BOOL repost,
                               NSString *appID, id completion)
{
    void (*original)(id, SEL, id, BOOL, id, id) =
        (void (*)(id, SEL, id, BOOL, id, id))gCRBadgeSaveRequestOriginal;
    if (!original)
        return;
    if (CRBadgeRedirectionEnabled(appID) &&
        [request respondsToSelector:@selector(content)]) {
        SEL currentSEL = NSSelectorFromString(@"currentConnection");
        NSXPCConnection *connection =
            [NSXPCConnection respondsToSelector:currentSEL]
                ? ((id (*)(id, SEL))objc_msgSend)(
                    [NSXPCConnection class], currentSEL) : nil;
        NSString *container = CRBadgeContainerForConnection(connection);
        if (container.length && ![container isEqualToString:@"DEFAULT"]) {
            id content = ((id (*)(id, SEL))objc_msgSend)(
                request, @selector(content));
            if ([content respondsToSelector:@selector(userInfo)]) {
                id info = ((id (*)(id, SEL))objc_msgSend)(
                    content, @selector(userInfo));
                if ([info isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *tagged = [info mutableCopy];
                    tagged[@"crane_sourceContainerID"] = container;
                    @try {
                        [content setValue:[tagged copy] forKey:@"_userInfo"];
                    } @catch (NSException *exception) {
                        (void)exception;
                    }
                }
            }
        }
    }
    original(self, cmd, request, repost, appID, completion);
}

/* 0x108F4: deliveredDate: variant of the notification save hook.
 * The recovered original tags request.content._userInfo before forwarding
 * all five arguments unchanged to the saved implementation. */
static IMP gCRBadgeSaveDatedRequestOriginal;

static void CRBadgeSaveDatedRequest(id self, SEL cmd, id request, BOOL repost,
                                    id deliveredDate, NSString *appID,
                                    id completion)
{
    void (*original)(id, SEL, id, BOOL, id, id, id) =
        (void (*)(id, SEL, id, BOOL, id, id, id))gCRBadgeSaveDatedRequestOriginal;
    if (!original)
        return;
    if (CRBadgeRedirectionEnabled(appID) &&
        [request respondsToSelector:@selector(content)]) {
        SEL currentSEL = NSSelectorFromString(@"currentConnection");
        NSXPCConnection *connection =
            [NSXPCConnection respondsToSelector:currentSEL]
                ? ((id (*)(id, SEL))objc_msgSend)(
                    [NSXPCConnection class], currentSEL) : nil;
        NSString *container = CRBadgeContainerForConnection(connection);
        if (container.length && ![container isEqualToString:@"DEFAULT"]) {
            id content = ((id (*)(id, SEL))objc_msgSend)(
                request, @selector(content));
            if ([content respondsToSelector:@selector(userInfo)]) {
                id info = ((id (*)(id, SEL))objc_msgSend)(
                    content, @selector(userInfo));
                if ([info isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *tagged = [info mutableCopy];
                    tagged[@"crane_sourceContainerID"] = container;
                    @try {
                        [content setValue:[tagged copy] forKey:@"_userInfo"];
                    } @catch (NSException *exception) {
                        (void)exception;
                    }
                }
            }
        }
    }
    original(self, cmd, request, repost, deliveredDate, appID, completion);
}

/* CraneSB 0x10D10/0x12424: pending requests are returned only for the
 * caller's container, and copied without the private source tag. */
static IMP gCRBadgePendingRequestsOriginal;
static void CRBadgePendingRequests(id self, SEL cmd, NSString *appID, id completion)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgePendingRequestsOriginal;
    if (!original)
        return;
    if (!completion || !CRBadgeRedirectionEnabled(appID)) {
        original(self, cmd, appID, completion);
        return;
    }
    NSXPCConnection *connection = [NSXPCConnection currentConnection];
    if (!connection) {
        original(self, cmd, appID, completion);
        return;
    }
    NSString *container = CRBadgeContainerForConnection(connection) ?: @"DEFAULT";
    void (^reply)(NSArray *) = completion;
    original(self, cmd, appID, ^(NSArray *requests) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (id request in requests) {
            if (![request respondsToSelector:@selector(content)])
                continue;
            id content = ((id (*)(id, SEL))objc_msgSend)(request, @selector(content));
            id info = [content respondsToSelector:@selector(userInfo)]
                ? ((id (*)(id, SEL))objc_msgSend)(content, @selector(userInfo)) : nil;
            /* Original sub_BE18: absent userInfo yields nil; a dictionary
             * without the source tag maps to DEFAULT. */
            id source = [info isKindOfClass:[NSDictionary class]]
                ? (info[@"crane_sourceContainerID"] ?: @"DEFAULT") : nil;
            if (![container isEqualToString:source])
                continue;
            SEL copySEL = NSSelectorFromString(@"crane_copyWithoutContainerID");
            if (![request respondsToSelector:copySEL])
                continue;
            id copied = ((id (*)(id, SEL))objc_msgSend)(request, copySEL);
            if (copied)
                [filtered addObject:copied];
        }
        reply([filtered copy]);
    });
}

/* CraneSB 0xC08C/0xC1D4, 0xC4B0/0xC5E0 and wrappers 0x10EA4..0x11110.
 * Resolve the caller-scoped pending list before any destructive operation. */
static void CRBadgeResolveRemovalIdentifiers(id self, NSString *appID,
                                              NSArray *requested, BOOL removeAll,
                                              void (^reply)(NSArray *))
{
    if (!CRBadgeRedirectionEnabled(appID) || ![NSXPCConnection currentConnection]) {
        reply(requested);
        return;
    }
    SEL pendingSEL = NSSelectorFromString(
        @"getPendingNotificationRequestsForBundleIdentifier:withCompletionHandler:");
    if (![self respondsToSelector:pendingSEL]) {
        reply(@[]);
        return;
    }
    ((void (*)(id, SEL, id, id))objc_msgSend)(self, pendingSEL, appID,
        ^(NSArray *pending) {
            NSMutableArray *identifiers = [NSMutableArray array];
            for (id request in pending) {
                id identifier = [request respondsToSelector:@selector(identifier)]
                    ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(identifier)) : nil;
                if (!identifier)
                    continue;
                if (removeAll || [requested containsObject:identifier])
                    [identifiers addObject:identifier];
            }
            reply([identifiers copy]);
        });
}

static IMP gCRBadgeRemovePendingWithReplyOriginal;
static void CRBadgeRemovePendingWithReply(id self, SEL cmd, NSArray *identifiers,
                                           NSString *appID, id completion)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gCRBadgeRemovePendingWithReplyOriginal;
    if (!original)
        return;
    CRBadgeResolveRemovalIdentifiers(self, appID, identifiers, NO, ^(NSArray *filtered) {
        original(self, cmd, filtered, appID, completion);
    });
}

static IMP gCRBadgeRemovePendingOriginal;
static void CRBadgeRemovePending(id self, SEL cmd, NSArray *identifiers,
                                  NSString *appID)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeRemovePendingOriginal;
    if (!original)
        return;
    CRBadgeResolveRemovalIdentifiers(self, appID, identifiers, NO, ^(NSArray *filtered) {
        original(self, cmd, filtered, appID);
    });
}

static void CRBadgeRemoveAllScoped(id self, NSString *appID, id completion)
{
    CRBadgeResolveRemovalIdentifiers(self, appID, nil, YES, ^(NSArray *identifiers) {
        SEL withoutReply = NSSelectorFromString(
            @"removePendingNotificationRequestsWithIdentifiers:forBundleIdentifier:");
        SEL withReply = NSSelectorFromString(
            @"removePendingNotificationRequestsWithIdentifiers:forBundleIdentifier:completionHandler:");
        if (completion && [self respondsToSelector:withReply])
            ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, withReply, identifiers, appID, completion);
        else {
            if ([self respondsToSelector:withoutReply])
                ((void (*)(id, SEL, id, id))objc_msgSend)(self, withoutReply, identifiers, appID);
            else if ([self respondsToSelector:withReply])
                ((void (*)(id, SEL, id, id, id))objc_msgSend)(self, withReply, identifiers, appID, nil);
            if (completion)
                ((void (^)(void))completion)();
        }
    });
}

static IMP gCRBadgeRemoveAllPendingWithReplyOriginal;
static void CRBadgeRemoveAllPendingWithReply(id self, SEL cmd,
                                              NSString *appID, id completion)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeRemoveAllPendingWithReplyOriginal;
    if (!original)
        return;
    if (!CRBadgeRedirectionEnabled(appID) || ![NSXPCConnection currentConnection]) {
        original(self, cmd, appID, completion);
        return;
    }
    CRBadgeRemoveAllScoped(self, appID, completion);
}

static IMP gCRBadgeRemoveAllPendingOriginal;
static void CRBadgeRemoveAllPending(id self, SEL cmd, NSString *appID)
{
    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gCRBadgeRemoveAllPendingOriginal;
    if (!original)
        return;
    if (!CRBadgeRedirectionEnabled(appID) || ![NSXPCConnection currentConnection]) {
        original(self, cmd, appID);
        return;
    }
    CRBadgeRemoveAllScoped(self, appID, nil);
}

/* 0x10350/0x1FF68/0x1FF7C: recover the APNS topic separator
 * verbatim; only rewrite messages with a valid nonempty suffix. */
static IMP gCRBadgeDeliverMessageOriginal;
static void CRBadgeDeliverMessage(id self, SEL cmd, id message)
{
    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gCRBadgeDeliverMessageOriginal;
    if (!original)
        return;
    SEL topicSEL = @selector(topic);
    SEL setTopicSEL = NSSelectorFromString(@"setTopic:");
    SEL userInfoSEL = @selector(userInfo);
    SEL setUserInfoSEL = NSSelectorFromString(@"setUserInfo:");
    if ([message respondsToSelector:topicSEL] &&
        [message respondsToSelector:setTopicSEL] &&
        [message respondsToSelector:userInfoSEL] &&
        [message respondsToSelector:setUserInfoSEL]) {
        id topic = ((id (*)(id, SEL))objc_msgSend)(message, topicSEL);
        if ([topic isKindOfClass:[NSString class]]) {
            NSString *separator = @".c_r_a_n_e.";
            NSArray *parts = [topic componentsSeparatedByString:separator];
            if (parts.count > 1) {
                /* 0x1FF7C uses firstObject/lastObject, not the substring
                 * after the first separator, for repeated separators. */
                NSString *base = [parts firstObject];
                NSString *container = [parts lastObject];
                id info = ((id (*)(id, SEL))objc_msgSend)(
                    message, userInfoSEL);
                if (base.length && container.length &&
                    [info isKindOfClass:[NSDictionary class]]) {
                    NSMutableDictionary *tagged = [info mutableCopy];
                    if (![container isEqualToString:@"DEFAULT"])
                        tagged[@"crane_sourceContainerID"] = container;
                    else
                        [tagged removeObjectForKey:@"crane_sourceContainerID"];
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        message, setTopicSEL, base);
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        message, setUserInfoSEL, [tagged copy]);
                }
            }
        }
    }
    original(self, cmd, message);
}

/* 0xE2C4: a token delivered for a Crane-specific topic is reported
 * to the notification server under its original bundle topic. */
static IMP gCRBadgeReceiveTokenOriginal;

static void CRBadgeReceiveToken(id self, SEL cmd, id connection, id token,
                                NSString *topic, id identifier)
{
    void (*original)(id, SEL, id, id, id, id) =
        (void (*)(id, SEL, id, id, id, id))gCRBadgeReceiveTokenOriginal;
    if (!original)
        return;
    NSString *base = topic;
    NSString *separator = @".c_r_a_n_e.";
    if ([topic isKindOfClass:[NSString class]] &&
        [topic containsString:separator]) {
        base = [[topic componentsSeparatedByString:separator] firstObject];
        if (base.length) {
            /* Original 0xE2C4 keeps its token-needed queue in sync. */
            @try {
                id needed = [self valueForKey:@"_bundleIdentifiersNeedingToken"];
                if ([needed respondsToSelector:@selector(containsObject:)] &&
                    [needed containsObject:topic] &&
                    [needed respondsToSelector:@selector(removeObject:)] &&
                    [needed respondsToSelector:@selector(addObject:)]) {
                    [needed removeObject:topic];
                    [needed addObject:base];
                }
            } @catch (NSException *exception) {
                (void)exception;
            }
        } else {
            base = topic;
        }
    }
    original(self, cmd, connection, token, base, identifier);
}

/* CraneSB 0xD958: LSApplicationProxy bundle ID is topic-scoped only
 * while requestToken's origin container is active on this thread. */
static IMP gCRBadgeProxyBundleIDOriginal;
static id CRBadgeProxyBundleID(id self, SEL cmd)
{
    id (*original)(id, SEL) = (id (*)(id, SEL))gCRBadgeProxyBundleIDOriginal;
    id appID = original ? original(self, cmd) : nil;
    id container = [NSThread currentThread].threadDictionary[@"crane_requestOriginContainerID"];
    if (container && [appID isKindOfClass:[NSString class]])
        return [NSString stringWithFormat:@"%@.c_r_a_n_e.%@", appID, container];
    return appID;
}

/* 0xDC5C/0xE194: encode token invalidation per originating container.
 * The source is resolved from the listener's current XPC connection. */
static IMP gCRBadgeInvalidateTokenOriginal;

static void CRBadgeInvalidateToken(id self, SEL cmd, NSString *appID)
{
    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gCRBadgeInvalidateTokenOriginal;
    if (!original)
        return;
    if (CRBadgeRedirectionEnabled(appID)) {
        SEL currentSEL = NSSelectorFromString(@"_currentConnection");
        id connection = [self respondsToSelector:currentSEL]
            ? ((id (*)(id, SEL))objc_msgSend)(self, currentSEL) : nil;
        NSString *container = CRBadgeContainerForConnection(connection);
        if (container.length) {
            NSString *topic = [NSString stringWithFormat:
                @"%@.c_r_a_n_e.%@", appID, container];
            original(self, cmd, topic);
            return;
        }
    }
    original(self, cmd, appID);
}

/* 0xDA30/0xDF68: route token requests to a container-specific APNS
 * topic. Scope origin on the calling thread for synchronous callbacks. */
static IMP gCRBadgeRequestTokenOriginal;

static void CRBadgeRequestToken(id self, SEL cmd, NSString *appID,
                                id completion)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeRequestTokenOriginal;
    if (!original)
        return;
    if (!CRBadgeRedirectionEnabled(appID)) {
        original(self, cmd, appID, completion);
        return;
    }
    SEL currentSEL = NSSelectorFromString(@"_currentConnection");
    id connection = [self respondsToSelector:currentSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(self, currentSEL) : nil;
    NSString *container = CRBadgeContainerForConnection(connection);
    if (!container.length) {
        original(self, cmd, appID, completion);
        return;
    }
    NSString *topic = [NSString stringWithFormat:
        @"%@.c_r_a_n_e.%@", appID, container];
    NSMutableDictionary *context = [NSThread currentThread].threadDictionary;
    NSString *key = @"crane_requestOriginContainerID";
    id previous = context[key];
    context[key] = container;
    /* 0xDF68: older UNCLocal listener implementations keep a source
     * description indexed by the original bundle ID. Temporarily alias it
     * under the encoded topic while the original request runs. */
    NSMutableDictionary *descriptions = nil;
    id sourceDescription = nil;
    BOOL aliasInstalled = NO;
    @try {
        id mapping = [self valueForKey:@"_bundleIdentifierToSourceDescription"];
        if ([mapping isKindOfClass:[NSMutableDictionary class]]) {
            id candidate = mapping[appID];
            if (candidate && !mapping[topic]) {
                descriptions = mapping;
                sourceDescription = candidate;
                descriptions[topic] = sourceDescription;
                aliasInstalled = YES;
            }
        }
    } @catch (NSException *exception) {
        (void)exception;
    }
    @try {
        original(self, cmd, topic, completion);
    } @finally {
        if (aliasInstalled && descriptions[topic] == sourceDescription)
            [descriptions removeObjectForKey:topic];
        if (previous)
            context[key] = previous;
        else
            [context removeObjectForKey:key];
    }
}

/* 0xDE54: the notification source description lookup is a class method.
 * Convert encoded topics back to their original bundle ID before lookup. */
static IMP gCRBadgeSourceDescriptionOriginal;

static id CRBadgeSourceDescription(id self, SEL cmd, NSString *bundleID)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gCRBadgeSourceDescriptionOriginal;
    if (!original)
        return nil;
    if ([bundleID isKindOfClass:[NSString class]] &&
        [bundleID containsString:@".c_r_a_n_e."]) {
        NSString *base = [[bundleID componentsSeparatedByString:
            @".c_r_a_n_e."] firstObject];
        if (base.length)
            bundleID = base;
    }
    return original(self, cmd, bundleID);
}

/* 0xE698: normalize a Crane APNS topic for the legacy app-description
 * lookup, without modifying the installed-bundle-identifier collection. */
static IMP gCRBadgeAppDescriptionOriginal;

static id CRBadgeAppDescription(id self, SEL cmd, NSString *bundleID)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gCRBadgeAppDescriptionOriginal;
    if (!original)
        return nil;
    if ([bundleID isKindOfClass:[NSString class]] &&
        [bundleID containsString:@".c_r_a_n_e."]) {
        NSString *base = [[bundleID componentsSeparatedByString:
            @".c_r_a_n_e."] firstObject];
        if (base.length)
            bundleID = base;
    }
    return original(self, cmd, bundleID);
}

/* 0xEBA0: report an APNS topic per non-default container in addition
 * to the existing topics returned by the notification server. */
static IMP gCRBadgeAllTopicsOriginal;

static id CRBadgeAllTopics(id self, SEL cmd, NSString *appID)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gCRBadgeAllTopicsOriginal;
    if (!original)
        return nil;
    id topics = original(self, cmd, appID);
    if (!CRBadgeRedirectionEnabled(appID))
        return topics;
    NSArray *identifiers = [CraneManager.sharedManager
        containerIdentifiersOfApplicationWithIdentifier:appID];
    if (![topics respondsToSelector:@selector(mutableCopy)] ||
        ![identifiers isKindOfClass:[NSArray class]] || identifiers.count < 2)
        return topics;
    id expanded = [topics mutableCopy];
    if (![expanded respondsToSelector:@selector(addObject:)])
        return topics;
    for (id identifier in identifiers) {
        if (![identifier isKindOfClass:[NSString class]] ||
            ![identifier length] ||
            [identifier isEqualToString:@"DEFAULT"])
            continue;
        NSString *topic = [NSString stringWithFormat:
            @"%@.c_r_a_n_e.%@", appID, identifier];
        [expanded addObject:topic];
    }
    return expanded;
}

/* 0xE448/0xE4DC: eligibility checks operate on the underlying
 * application's topic, not the Crane-encoded container topic. */
static NSString *CRBadgeOriginalTopic(id topic)
{
    if (![topic isKindOfClass:[NSString class]])
        return topic;
    NSString *separator = @".c_r_a_n_e.";
    if (![topic containsString:separator])
        return topic;
    return [[topic componentsSeparatedByString:separator] firstObject];
}

static IMP gCRBadgeContentAvailableOriginal;
static BOOL CRBadgeContentAvailable(id self, SEL cmd, id topic)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeContentAvailableOriginal;
    return original ? original(self, cmd, CRBadgeOriginalTopic(topic)) : NO;
}

static IMP gCRBadgeBackgroundRefreshOriginal;
static BOOL CRBadgeBackgroundRefresh(id self, SEL cmd, id topic)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeBackgroundRefreshOriginal;
    return original ? original(self, cmd, CRBadgeOriginalTopic(topic)) : NO;
}

/* 0xE570/0xE604: legacy notification eligibility queries also
 * resolve encoded Crane topics as the underlying application. */
static IMP gCRBadgeUserNotificationEnabledOriginal;
static BOOL CRBadgeUserNotificationEnabled(id self, SEL cmd, id topic)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeUserNotificationEnabledOriginal;
    return original ? original(self, cmd, CRBadgeOriginalTopic(topic)) : NO;
}

static IMP gCRBadgeApplicationForegroundOriginal;
static BOOL CRBadgeApplicationForeground(id self, SEL cmd, id topic)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeApplicationForegroundOriginal;
    return original ? original(self, cmd, CRBadgeOriginalTopic(topic)) : NO;
}

/* 0xDEEC/0xE94C: isolate Crane's membership behavior to a subclass
 * of the mutable set used for installed bundle IDs. */
static Class gCRBadgeResolvingSetClass;
static IMP gCRBadgeSetContainsOriginal;

static BOOL CRBadgeSetContainsObject(id self, SEL cmd, id object)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeSetContainsOriginal;
    return original ? original(self, cmd, CRBadgeOriginalTopic(object)) : NO;
}

static IMP gCRBadgeInitializeRemoteOriginal;
static void CRBadgeInitializeRemote(id self, SEL cmd)
{
    void (*original)(id, SEL) =
        (void (*)(id, SEL))gCRBadgeInitializeRemoteOriginal;
    if (!original)
        return;
    original(self, cmd);
    if (!gCRBadgeResolvingSetClass)
        return;
    @try {
        id installed = [self valueForKey:@"_installedBundleIdentifiers"];
        Class base = class_getSuperclass(gCRBadgeResolvingSetClass);
        if (installed && object_getClass(installed) == base)
            object_setClass(installed, gCRBadgeResolvingSetClass);
    } @catch (NSException *exception) {
        (void)exception;
    }
}

static void CRBadgePrepareResolvingSet(void)
{
    Class base = objc_getClass("__NSSetM");
    SEL containsSEL = @selector(containsObject:);
    if (!base || ![base instancesRespondToSelector:containsSEL])
        return;
    Method containsMethod = class_getInstanceMethod(base, containsSEL);
    if (!containsMethod)
        return;
    gCRBadgeSetContainsOriginal = method_getImplementation(containsMethod);
    const char *containsTypes = method_getTypeEncoding(containsMethod);
    if (!gCRBadgeSetContainsOriginal || !containsTypes)
        return;
    Class subclass = NSClassFromString(@"CRCraneResolvingSet");
    if (!subclass) {
        subclass = objc_allocateClassPair(base, "CRCraneResolvingSet", 0);
        if (!subclass)
            return;
        if (!class_addMethod(subclass, containsSEL,
                             (IMP)CRBadgeSetContainsObject, containsTypes)) {
            objc_disposeClassPair(subclass);
            return;
        }
        objc_registerClassPair(subclass);
    }
    if (class_getSuperclass(subclass) == base)
        gCRBadgeResolvingSetClass = subclass;
}

/* 0xEDF4/0xBE18: enforce per-container notification permission on the
 * remote server's incoming message path before forwarding to the system. */
static IMP gCRBadgeIncomingMessageOriginal;

static void CRBadgeIncomingMessage(id self, SEL cmd, id connection, id message)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeIncomingMessageOriginal;
    if (!original)
        return;
    SEL topicSEL = @selector(topic);
    SEL infoSEL = @selector(userInfo);
    if ([message respondsToSelector:topicSEL] &&
        [message respondsToSelector:infoSEL]) {
        id topic = ((id (*)(id, SEL))objc_msgSend)(message, topicSEL);
        if (CRBadgeRedirectionEnabled(topic)) {
            id info = ((id (*)(id, SEL))objc_msgSend)(message, infoSEL);
            if ([info isKindOfClass:[NSDictionary class]]) {
                id source = info[@"crane_sourceContainerID"];
                if (!source)
                    source = @"DEFAULT";
                if ([source isKindOfClass:[NSString class]]) {
                    NSDictionary *settings = [[CraneManager sharedManager]
                        containerSettingsForContainerWithIdentifier:source
                        ofApplicationWithIdentifier:topic];
                    id allowed = [settings objectForKey:@"notificationsAllowed"];
                    if (allowed && [allowed respondsToSelector:@selector(boolValue)] &&
                        ![allowed boolValue])
                        return;
                }
            }
        }
    }
    original(self, cmd, connection, message);
}

/* 0xEF84/0xF094 and 0xB7B8: scope container metadata around the
 * synchronous original notification mutation call. pkd verification remains
 * unported; without it only explicit existing metadata is propagated. */
static NSString *CRBadgeMutationContainer(id request, id appID)
{
    /* 0xBA6C: absent source metadata belongs to DEFAULT only when
     * notification redirection is enabled for the target application. */
    if (!CRBadgeRedirectionEnabled(appID))
        return nil;
    if (![request respondsToSelector:@selector(content)])
        return @"DEFAULT";
    id content = ((id (*)(id, SEL))objc_msgSend)(request, @selector(content));
    if (![content respondsToSelector:@selector(userInfo)])
        return @"DEFAULT";
    id info = ((id (*)(id, SEL))objc_msgSend)(content, @selector(userInfo));
    if (![info isKindOfClass:[NSDictionary class]])
        return @"DEFAULT";
    id source = info[@"crane_sourceContainerID"];
    if (!source)
        return @"DEFAULT";
    return [source isKindOfClass:[NSString class]] && [source length]
        ? source : nil;
}

static IMP gCRBadgeModifyPushOriginal;
static void CRBadgeModifyPush(id self, SEL cmd, id request, id appID,
                              id message, BOOL enforcePushType)
{
    void (*original)(id, SEL, id, id, id, BOOL) =
        (void (*)(id, SEL, id, id, id, BOOL))gCRBadgeModifyPushOriginal;
    if (!original)
        return;
    NSString *container = CRBadgeMutationContainer(request, appID);
    NSMutableDictionary *context = [NSThread currentThread].threadDictionary;
    NSString *key = @"extension_containerIDToAppend";
    id previous = context[key];
    if (container)
        context[key] = container;
    @try {
        original(self, cmd, request, appID, message, enforcePushType);
    } @finally {
        if (container) {
            if (previous)
                context[key] = previous;
            else
                [context removeObjectForKey:key];
        }
    }
}

static IMP gCRBadgeModifyLegacyOriginal;
static void CRBadgeModifyLegacy(id self, SEL cmd, id request, id appID,
                                id message)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gCRBadgeModifyLegacyOriginal;
    if (!original)
        return;
    NSString *container = CRBadgeMutationContainer(request, appID);
    NSMutableDictionary *context = [NSThread currentThread].threadDictionary;
    NSString *key = @"extension_containerIDToAppend";
    id previous = context[key];
    if (container)
        context[key] = container;
    @try {
        original(self, cmd, request, appID, message);
    } @finally {
        if (container) {
            if (previous)
                context[key] = previous;
            else
                [context removeObjectForKey:key];
        }
    }
}

/* CraneSB 0xE730: decorate notification title with the source
 * container's display name. The recovered CraneManager selector is not
 * reconstructed yet, so preserve the original title until it exists. */
static IMP gCRBadgeNotificationTitleOriginal;
static id CRBadgeNotificationTitle(id self, SEL cmd)
{
    id (*original)(id, SEL) = (id (*)(id, SEL))gCRBadgeNotificationTitleOriginal;
    id title = original ? original(self, cmd) : nil;
    SEL requestSEL = NSSelectorFromString(@"notificationRequest");
    if (![self respondsToSelector:requestSEL])
        return title;
    id notificationRequest = ((id (*)(id, SEL))objc_msgSend)(self, requestSEL);
    SEL userNotificationSEL = NSSelectorFromString(@"userNotification");
    if (![notificationRequest respondsToSelector:userNotificationSEL])
        return title;
    id notification = ((id (*)(id, SEL))objc_msgSend)(notificationRequest, userNotificationSEL);
    if (!notification)
        return title;
    id appID = [notificationRequest respondsToSelector:@selector(sectionIdentifier)]
        ? ((id (*)(id, SEL))objc_msgSend)(notificationRequest, @selector(sectionIdentifier)) : nil;
    id manager = [CraneManager sharedManager];
    SEL nameSEL = NSSelectorFromString(
        @"containerNameToDisplayInNotificationWithUserInfoOrContext:ofApplicationWithIdentifier:");
    if (![manager respondsToSelector:nameSEL])
        return title;
    id request = [notification respondsToSelector:@selector(request)]
        ? ((id (*)(id, SEL))objc_msgSend)(notification, @selector(request)) : nil;
    id content = [request respondsToSelector:@selector(content)]
        ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(content)) : nil;
    id info = [content respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(content, @selector(userInfo)) : nil;
    id name = ((id (*)(id, SEL, id, id))objc_msgSend)(manager, nameSEL, info, appID);
    if (![name isKindOfClass:[NSString class]] || ![name length])
        return title;
    return [NSString stringWithFormat:@"%@ (%@)", title, [name uppercaseString]];
}

/* CraneSB 0x1119C: scope bulletin headers and context to the source
 * container after the original provider creates the bulletin. */
static IMP gCRBadgeBulletinOriginal;
static id CRBadgeBulletinForNotification(id self, SEL cmd, id notification)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gCRBadgeBulletinOriginal;
    id bulletin = original ? original(self, cmd, notification) : nil;
    id appID = [self respondsToSelector:@selector(sectionIdentifier)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier)) : nil;
    id info = [notification respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(notification, @selector(userInfo)) : nil;
    id source = [info isKindOfClass:[NSDictionary class]]
        ? info[@"crane_sourceContainerID"] : nil;
    if (!source && [info isKindOfClass:[NSDictionary class]] &&
        CRBadgeRedirectionEnabled(appID))
        source = @"DEFAULT";
    if (!source || !bulletin)
        return bulletin;
    if ([bulletin respondsToSelector:@selector(setHeader:)]) {
        NSString *name = [[CraneManager sharedManager]
            containerNameToDisplayInNotificationWithUserInfoOrContext:info
                                     ofApplicationWithIdentifier:appID];
        if (name) {
            NSString *applicationName = [[CraneManager sharedManager]
                displayNameForApplicationWithIdentifier:appID];
            ((void (*)(id, SEL, id))objc_msgSend)(bulletin, @selector(setHeader:),
                [NSString stringWithFormat:@"%@ (%@)", applicationName, name]);
        }
    }
    if (![source isEqual:@"DEFAULT"] &&
        [bulletin respondsToSelector:@selector(context)] &&
        [bulletin respondsToSelector:@selector(setContext:)]) {
        id context = ((id (*)(id, SEL))objc_msgSend)(bulletin, @selector(context));
        if ([context isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *tagged = [context mutableCopy];
            tagged[@"crane_sourceContainerID"] = source;
            ((void (*)(id, SEL, id))objc_msgSend)(bulletin, @selector(setContext:),
                [tagged copy]);
        }
    }
    return bulletin;
}

void CRInitBadgeListenerMethods(void)
{
    Class dataProvider = NSClassFromString(@"UNSDefaultDataProvider");
    SEL bulletinSEL = NSSelectorFromString(@"_queue_bulletinForNotification:");
    if (dataProvider && [dataProvider instancesRespondToSelector:bulletinSEL])
        MSHookMessageEx(dataProvider, bulletinSEL,
                        (IMP)CRBadgeBulletinForNotification,
                        &gCRBadgeBulletinOriginal);
    Class bulletinClass = NSClassFromString(@"BBBulletin");
    SEL headerSEL = NSSelectorFromString(@"setHeader:");
    if (!bulletinClass || ![bulletinClass instancesRespondToSelector:headerSEL]) {
        Class provider = NSClassFromString(@"NCNotificationRequestContentProvider");
        SEL titleSEL = NSSelectorFromString(@"title");
        if (provider && [provider instancesRespondToSelector:titleSEL])
            MSHookMessageEx(provider, titleSEL,
                            (IMP)CRBadgeNotificationTitle,
                            &gCRBadgeNotificationTitleOriginal);
    }
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySEL = NSSelectorFromString(@"un_applicationBundleIdentifier");
    if (proxyClass && [proxyClass instancesRespondToSelector:proxySEL])
        MSHookMessageEx(proxyClass, proxySEL, (IMP)CRBadgeProxyBundleID,
                        &gCRBadgeProxyBundleIDOriginal);
    Class descriptionClass = NSClassFromString(
        @"UNSNotificationSourceDescription");
    if (!descriptionClass)
        descriptionClass = NSClassFromString(
            @"UNCNotificationSourceDescription");
    SEL descriptionSEL = NSSelectorFromString(
        @"sourceDescriptionWithBundleIdentifier:");
    if (descriptionClass &&
        [descriptionClass respondsToSelector:descriptionSEL])
        MSHookMessageEx(object_getClass(descriptionClass), descriptionSEL,
                        (IMP)CRBadgeSourceDescription,
                        &gCRBadgeSourceDescriptionOriginal);
    Class remoteClass = NSClassFromString(@"UNSRemoteNotificationServer");
    if (!remoteClass)
        remoteClass = NSClassFromString(@"UNCRemoteNotificationServer");
    if (NSClassFromString(@"UNSUserNotificationServerConnectionListener")) {
        CRBadgePrepareResolvingSet();
        SEL initRemoteSEL = NSSelectorFromString(
            @"_queue_didCompleteInitialization");
        if (gCRBadgeResolvingSetClass && remoteClass &&
            [remoteClass instancesRespondToSelector:initRemoteSEL])
            MSHookMessageEx(remoteClass, initRemoteSEL,
                            (IMP)CRBadgeInitializeRemote,
                            &gCRBadgeInitializeRemoteOriginal);
    }
    SEL modifyPushSEL = NSSelectorFromString(
        @"_queue_tryToModifyNotificationRequest:bundleIdentifier:message:enforcePushType:");
    if (remoteClass && [remoteClass instancesRespondToSelector:modifyPushSEL])
        MSHookMessageEx(remoteClass, modifyPushSEL, (IMP)CRBadgeModifyPush,
                        &gCRBadgeModifyPushOriginal);
    SEL modifyLegacySEL = NSSelectorFromString(
        @"_queue_tryToModifyNotificationRequest:bundleIdentifier:message:");
    if (remoteClass && [remoteClass instancesRespondToSelector:modifyLegacySEL])
        MSHookMessageEx(remoteClass, modifyLegacySEL, (IMP)CRBadgeModifyLegacy,
                        &gCRBadgeModifyLegacyOriginal);
    SEL incomingSEL = NSSelectorFromString(
        @"connection:didReceiveIncomingMessage:");
    if (remoteClass && [remoteClass instancesRespondToSelector:incomingSEL])
        MSHookMessageEx(remoteClass, incomingSEL,
                        (IMP)CRBadgeIncomingMessage,
                        &gCRBadgeIncomingMessageOriginal);
    SEL contentAvailableSEL = NSSelectorFromString(
        @"_queue_isContentAvailableRemoteNotificationSupportedForBundleIdentifier:");
    if (remoteClass &&
        [remoteClass instancesRespondToSelector:contentAvailableSEL])
        MSHookMessageEx(remoteClass, contentAvailableSEL,
                        (IMP)CRBadgeContentAvailable,
                        &gCRBadgeContentAvailableOriginal);
    SEL refreshSEL = NSSelectorFromString(
        @"_queue_isBackgroundAppRefreshAllowedForBundleIdentifier:");
    if (remoteClass && [remoteClass instancesRespondToSelector:refreshSEL])
        MSHookMessageEx(remoteClass, refreshSEL,
                        (IMP)CRBadgeBackgroundRefresh,
                        &gCRBadgeBackgroundRefreshOriginal);
    SEL enabledSEL = NSSelectorFromString(
        @"_queue_isUserNotificationEnabledForApplication:");
    if (remoteClass && [remoteClass instancesRespondToSelector:enabledSEL])
        MSHookMessageEx(remoteClass, enabledSEL,
                        (IMP)CRBadgeUserNotificationEnabled,
                        &gCRBadgeUserNotificationEnabledOriginal);
    SEL foregroundSEL = NSSelectorFromString(
        @"_queue_isApplicationForeground:");
    if (remoteClass && [remoteClass instancesRespondToSelector:foregroundSEL])
        MSHookMessageEx(remoteClass, foregroundSEL,
                        (IMP)CRBadgeApplicationForeground,
                        &gCRBadgeApplicationForegroundOriginal);
    SEL allTopicsSEL = NSSelectorFromString(
        @"_queue_allTopicsForApplication:");
    if (remoteClass && [remoteClass instancesRespondToSelector:allTopicsSEL])
        MSHookMessageEx(remoteClass, allTopicsSEL,
                        (IMP)CRBadgeAllTopics, &gCRBadgeAllTopicsOriginal);
    SEL appDescriptionSEL = NSSelectorFromString(
        @"_queue_appDescriptionForBundleIdentifier:");
    if (remoteClass &&
        [remoteClass instancesRespondToSelector:appDescriptionSEL])
        MSHookMessageEx(remoteClass, appDescriptionSEL,
                        (IMP)CRBadgeAppDescription,
                        &gCRBadgeAppDescriptionOriginal);
    SEL receiveSEL = NSSelectorFromString(
        @"_queue_connection:didReceiveToken:forTopic:identifier:");
    if (remoteClass && [remoteClass instancesRespondToSelector:receiveSEL])
        MSHookMessageEx(remoteClass, receiveSEL, (IMP)CRBadgeReceiveToken,
                        &gCRBadgeReceiveTokenOriginal);
    Class apsClass = NSClassFromString(@"APSConnection");
    SEL deliverSEL = NSSelectorFromString(@"_deliverMessage:");
    if (apsClass && [apsClass instancesRespondToSelector:deliverSEL])
        MSHookMessageEx(apsClass, deliverSEL, (IMP)CRBadgeDeliverMessage,
                        &gCRBadgeDeliverMessageOriginal);
    Class tokenListener = NSClassFromString(
        @"UNSUserNotificationServerRemoteNotificationConnectionListener");
    if (!tokenListener)
        tokenListener = NSClassFromString(
            @"UNSUserNotificationServerConnectionListener");
    SEL requestSEL = NSSelectorFromString(
        @"requestTokenForRemoteNotificationsForBundleIdentifier:withCompletionHandler:");
    if (tokenListener &&
        [tokenListener instancesRespondToSelector:requestSEL])
        MSHookMessageEx(tokenListener, requestSEL, (IMP)CRBadgeRequestToken,
                        &gCRBadgeRequestTokenOriginal);
    SEL invalidateSEL = NSSelectorFromString(
        @"invalidateTokenForRemoteNotificationsForBundleIdentifier:");
    if (tokenListener &&
        [tokenListener instancesRespondToSelector:invalidateSEL])
        MSHookMessageEx(tokenListener, invalidateSEL,
                        (IMP)CRBadgeInvalidateToken,
                        &gCRBadgeInvalidateTokenOriginal);
    Class listener = NSClassFromString(
        @"UNSUserNotificationServerConnectionListener");
    if (!listener)
        return;
    SEL saveRequestSEL = NSSelectorFromString(
        @"_saveNotificationRequest:shouldRepost:forBundleIdentifier:withCompletionHandler:");
    if ([listener instancesRespondToSelector:saveRequestSEL])
        MSHookMessageEx(listener, saveRequestSEL, (IMP)CRBadgeSaveRequest,
                        &gCRBadgeSaveRequestOriginal);
    SEL datedSaveSEL = NSSelectorFromString(
        @"_saveNotificationRequest:shouldRepost:deliveredDate:forBundleIdentifier:withCompletionHandler:");
    if ([listener instancesRespondToSelector:datedSaveSEL])
        MSHookMessageEx(listener, datedSaveSEL,
                        (IMP)CRBadgeSaveDatedRequest,
                        &gCRBadgeSaveDatedRequestOriginal);
    SEL addSEL = NSSelectorFromString(
        @"_addNotificationRequests:forBundleIdentifier:withCompletionHandler:");
    if ([listener instancesRespondToSelector:addSEL])
        MSHookMessageEx(listener, addSEL, (IMP)CRBadgeAddRequests,
                        &gCRBadgeAddRequestsOriginal);
    SEL pendingSEL = NSSelectorFromString(@"getPendingNotificationRequestsForBundleIdentifier:withCompletionHandler:");
    if ([listener instancesRespondToSelector:pendingSEL])
        MSHookMessageEx(listener, pendingSEL, (IMP)CRBadgePendingRequests,
                        &gCRBadgePendingRequestsOriginal);
    SEL removeWithReplySEL = NSSelectorFromString(
        @"removePendingNotificationRequestsWithIdentifiers:forBundleIdentifier:completionHandler:");
    if ([listener instancesRespondToSelector:removeWithReplySEL])
        MSHookMessageEx(listener, removeWithReplySEL,
                        (IMP)CRBadgeRemovePendingWithReply,
                        &gCRBadgeRemovePendingWithReplyOriginal);
    SEL removeSEL = NSSelectorFromString(
        @"removePendingNotificationRequestsWithIdentifiers:forBundleIdentifier:");
    if ([listener instancesRespondToSelector:removeSEL])
        MSHookMessageEx(listener, removeSEL,
                        (IMP)CRBadgeRemovePending,
                        &gCRBadgeRemovePendingOriginal);
    SEL removeAllWithReplySEL = NSSelectorFromString(
        @"removeAllPendingNotificationRequestsForBundleIdentifier:completionHandler:");
    if ([listener instancesRespondToSelector:removeAllWithReplySEL])
        MSHookMessageEx(listener, removeAllWithReplySEL,
                        (IMP)CRBadgeRemoveAllPendingWithReply,
                        &gCRBadgeRemoveAllPendingWithReplyOriginal);
    SEL removeAllSEL = NSSelectorFromString(
        @"removeAllPendingNotificationRequestsForBundleIdentifier:");
    if ([listener instancesRespondToSelector:removeAllSEL])
        MSHookMessageEx(listener, removeAllSEL,
                        (IMP)CRBadgeRemoveAllPending,
                        &gCRBadgeRemoveAllPendingOriginal);
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
