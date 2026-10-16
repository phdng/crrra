/*
 * F-08 persisted badge-count store, recovered from CraneSB 0xA860,
 * 0xA990, 0xAC68, 0xACD0, 0xAE20 and 0x11BB8.
 *
 * Store shape: app bundle identifier -> container identifier -> NSNumber.
 * Notification setters and listener lifecycle hooks project aggregate counts.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"
#import "CRXPCProtocols.h"

void CRBadgeStoreSetContainerCount(NSString *appID, NSString *containerID, NSInteger count);

static NSMutableDictionary *gCRBadgeStore;
static NSObject *gCRBadgeStoreLock;
static NSArray<NSString *> *gCRBadgeInitialRefresh;
static void CRBadgeProjectApplicationCount(NSString *appID, BOOL validate);
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
    /* 0xB00C invokes 0xAC2C after pruning stale containers or reconciling
     * the badge icon. Defer that projection until dispatch_once is complete:
     * CRBadgeProjectApplicationCount -> CRBadgeAggregateCount calls this
     * initializer, so projecting inside the once block would deadlock. */
    NSArray<NSString *> *refresh = nil;
    @synchronized (gCRBadgeStoreLock) {
        refresh = gCRBadgeInitialRefresh;
        gCRBadgeInitialRefresh = nil;
    }
    for (NSString *appID in refresh)
        CRBadgeProjectApplicationCount(appID, YES);
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
    NSMutableArray<NSString *> *refresh = [NSMutableArray new];
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
        /* Native 0xB688 totals the ORIGINAL stored values, before deleting
         * unknown IDs. Summing only surviving values changes DEFAULT repair. */
        uint32_t storedPositive = 0;
        for (id countValue in [counts allValues]) {
            if ([countValue respondsToSelector:@selector(intValue)]) {
                int32_t count = [countValue intValue];
                if (count > 0)
                    storedPositive += (uint32_t)count; /* original _DWORD wraps */
            }
        }
        for (id containerID in counts) {
            if (![validIDs containsObject:containerID])
                [updated removeObjectForKey:containerID];
        }
        /* 0xB00C writes DEFAULT directly on a badge mismatch, even if the
         * transient container registry does not list DEFAULT. Do not gate
         * this native repair path on membership in validIDs. */
        NSNumber *iconCount = CRBadgeExistingIconCount(appID);
        if (iconCount &&
            storedPositive != (uint32_t)[iconCount intValue])
            updated[@"DEFAULT"] = @([iconCount intValue]);
        if (![updated isEqualToDictionary:counts]) {
            gCRBadgeStore[appID] = [updated copy];
            [refresh addObject:appID];
            changed = YES;
        }
    }
    if (changed)
        [gCRBadgeStore writeToFile:CRBadgeStorePath() atomically:YES];
    gCRBadgeInitialRefresh = [refresh copy];
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
        /* Native 0xA860 returns NSNumber.intValue (32-bit), not NSInteger. */
        return [value respondsToSelector:@selector(intValue)]
            ? [value intValue] : 0;
    }
}

/* CraneSB 0x10BEC/0x10CB0: notification-listener badge lifecycle RPCs. */
static NSInteger CRBadgeAggregateCount(NSString *appID, BOOL validate);

static void CRBadgeProjectApplicationCount(NSString *appID, BOOL validate)
{
    if (!appID.length)
        return;
    NSInteger count = CRBadgeAggregateCount(appID, validate);
    /* 0xA774 constructs numberWithInt:, preserving native badge ABI. */
    NSNumber *value = @((int)count);
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

/* Original 0xA4A0 takes (connection, bundleID). Its 0x20F58 probe checks
 * iOS >= 17.0.0; on that branch it resolves through FBProcessManager by
 * bundle ID, while older systems use the source PID's ClientContainerCache. */
static NSString *CRBadgeContainerForConnectionAndApplication(
    NSXPCConnection *connection, NSString *appID)
{
    NSOperatingSystemVersion version =
        [[NSProcessInfo processInfo] operatingSystemVersion];
    if (version.majorVersion < 17)
        return CRBadgeContainerForConnection(connection);
    if (!appID)
        return nil;
    Class managerClass = NSClassFromString(@"FBProcessManager");
    SEL sharedSEL = NSSelectorFromString(@"sharedInstance");
    if (![managerClass respondsToSelector:sharedSEL])
        return nil;
    id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, sharedSEL);
    SEL processesSEL = NSSelectorFromString(@"processesForBundleIdentifier:");
    if (![manager respondsToSelector:processesSEL])
        return nil;
    id processes = ((id (*)(id, SEL, id))objc_msgSend)(
        manager, processesSEL, appID);
    if ([processes count] != 1)
        return nil;
    id process = [processes firstObject];
    SEL containerSEL = NSSelectorFromString(@"crane_containerIdentifier");
    id container = [process respondsToSelector:containerSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(process, containerSEL) : nil;
    return [container isEqualToString:@"DEFAULT"] ? nil : container;
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
    if (CRBadgeRedirectionEnabled(appID)) {
        SEL currentSEL = NSSelectorFromString(@"currentConnection");
        NSXPCConnection *connection =
            [NSXPCConnection respondsToSelector:currentSEL]
                ? ((id (*)(id, SEL))objc_msgSend)([NSXPCConnection class], currentSEL)
                : nil;
        if (connection) {
            NSString *container = CRBadgeContainerForConnectionAndApplication(connection, appID);
            if (!container.length)
                container = @"DEFAULT";
            CRBadgeStoreSetContainerCount(appID, container,
                                          [number intValue]);
            /* Original 0xFD9C clears this caller's notification records
             * before forwarding a badge value equal to NSNumber(0). */
            if ([number isEqual:[NSNumber numberWithInt:0]]) {
                SEL removeSEL = NSSelectorFromString(
                    @"removeAllNotificationRecordsForBundleIdentifier:");
                if ([self respondsToSelector:removeSEL])
                    ((void (*)(id, SEL, id))objc_msgSend)(self, removeSEL, appID);
            }
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

/* 0xAA00/0xAB44: native _DWORD accumulators wrap at 32 bits. Positive
 * badge totals take priority; only a zero positive total can fall back to
 * a signed-negative sentinel total. Use unsigned addition to avoid UB. */
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
    uint32_t positive = 0;
    uint32_t negative = 0;
    for (id identifier in snapshot) {
        if (![identifier isKindOfClass:[NSString class]])
            continue;
        int32_t count = (int32_t)CRBadgeStoreContainerCount(
            appID, identifier, validate);
        if (count >= 0)
            positive += (uint32_t)count;
        else
            negative += (uint32_t)count;
    }
    /* Match 0xAA00: the sign bit of the *wrapped* negative accumulator
     * controls fallback, rather than the sign of any individual entry. */
    return (NSInteger)(int32_t)(positive != 0 ? positive :
        ((int32_t)negative < 0 ? negative : 0));
}

static id CRBadgeRecordSource(id record);

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
        /* Original 0xBD98/0xBE80 delegates to the 0xBE18 marker rule. */
        id source = CRBadgeRecordSource(record);
        return [source isEqualToString:containerID];
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
    /* 0xBB04 sends intValue even for a nil NSNumber (Objective-C returns 0).
     * An empty value clears the stored count but does not match NSNumber(0)
     * for record-removal purposes. Keep the source-container type guard. */
    if ([containerID isKindOfClass:[NSString class]] &&
        [containerID length]) {
        CRBadgeStoreSetContainerCount(appID, containerID,
                                     [number intValue]);
        if ([number isEqual:@0]) {
            CRBadgeRemoveRecordsForContainer(self, appID, containerID,
                                             originalIMP == gCRBadgeQueueSetterOriginal);
        }
    }

    /* 0xBB04 forwards +[NSNumber numberWithInt:] of 0xAA00's sum,
     * rather than an NSInteger-sized NSNumber. */
    NSNumber *aggregate = @((int)CRBadgeAggregateCount(appID, YES));
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
static NSString *CRBadgeSourceForRecord(id record, NSString *appID);

static void CRBadgeSaveRecord(id self, SEL cmd, id record,
                              id options, NSString *appID)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gCRBadgeSaveRecordOriginal;
    if (!original)
        return;

    /* Original 0x10138 delegates to 0xBF00 -> 0xBA6C, including
     * nil userInfo and present keyed collection semantics. */
    NSString *containerID = CRBadgeSourceForRecord(record, appID);
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

/* CraneSB 0xF254/0x10218/0x11FB0: global foreground context is
 * set before the outer save, then cleared asynchronously on _queue. */
static NSString *gCRBadgeForegroundContainer;
/* Reconstruction-only guard: an older queued clear must not erase a newer
 * notification's foreground context (original 0x11FB0 clears unconditionally). */
static uint64_t gCRBadgeForegroundGeneration;
static NSObject *CRBadgeForegroundLock(void)
{
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    return lock;
}
static IMP gCRBadgeSystemForegroundOriginal;
static BOOL CRBadgeSystemForeground(id self, SEL cmd, NSString *appID)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeSystemForegroundOriginal;
    BOOL foreground = original ? original(self, cmd, appID) : NO;
    NSString *foregroundContainer = nil;
    @synchronized (CRBadgeForegroundLock()) {
        foregroundContainer = gCRBadgeForegroundContainer;
    }
    if (!foreground || !foregroundContainer)
        return foreground;
    Class processClass = NSClassFromString(@"FBProcessManager");
    SEL sharedSEL = NSSelectorFromString(@"sharedInstance");
    if (![processClass respondsToSelector:sharedSEL])
        return NO;
    id manager = ((id (*)(id, SEL))objc_msgSend)(processClass, sharedSEL);
    SEL processesSEL = NSSelectorFromString(@"processesForBundleIdentifier:");
    id processes = [manager respondsToSelector:processesSEL]
        ? ((id (*)(id, SEL, id))objc_msgSend)(manager, processesSEL, appID) : nil;
    id process = [processes respondsToSelector:@selector(firstObject)]
        ? [processes firstObject] : nil;
    SEL containerSEL = NSSelectorFromString(@"crane_containerIdentifier");
    id active = [process respondsToSelector:containerSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(process, containerSEL) : nil;
    return [foregroundContainer isEqualToString:active];
}

/* CraneSB 0xBA6C: nil userInfo/appID selects DEFAULT; a present
 * keyed source marker is authoritative even for disabled applications. */
static id CRBadgeContainerForNotificationInfo(id info, NSString *appID)
{
    if (!info || !appID)
        return @"DEFAULT";
    SEL keyedSEL = @selector(objectForKeyedSubscript:);
    id source = [info respondsToSelector:keyedSEL]
        ? ((id (*)(id, SEL, id))objc_msgSend)(info, keyedSEL,
                                             @"crane_sourceContainerID") : nil;
    if (source)
        return source;
    return CRBadgeRedirectionEnabled(appID) ? @"DEFAULT" : nil;
}

/* CraneSB 0xF254/0xBA6C: outer save uses notification userInfo to
 * establish the global foreground context before invoking the original. */
static void CRBadgeOuterSave(id self, SEL cmd, id record, BOOL repost,
                             NSString *appID, id completion)
{
    void (*original)(id, SEL, id, BOOL, id, id) =
        (void (*)(id, SEL, id, BOOL, id, id))gCRBadgeOuterSaveOriginal;
    if (!original)
        return;
    id userInfo = [record respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo)) : nil;
    NSString *container = CRBadgeContainerForNotificationInfo(userInfo, appID);
    uint64_t foregroundGeneration;
    @synchronized (CRBadgeForegroundLock()) {
        gCRBadgeForegroundContainer = [container copy];
        foregroundGeneration = ++gCRBadgeForegroundGeneration;
    }
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
        /* Cleanup also runs when the original method raises, so process-wide
         * foreground metadata cannot persist after a failed save. */
        dispatch_queue_t queue = nil;
        @try { queue = [self valueForKey:@"_queue"]; }
        @catch (NSException *exception) { (void)exception; }
        void (^clearForeground)(void) = ^{
            @synchronized (CRBadgeForegroundLock()) {
                if (foregroundGeneration == gCRBadgeForegroundGeneration)
                    gCRBadgeForegroundContainer = nil;
            }
        };
        if (queue)
            dispatch_async(queue, clearForeground);
        else
            clearForeground();
    }
}

static NSString *CRBadgeSourceForRecord(id record, NSString *appID)
{
    id info = [record respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo))
        : nil;
    return CRBadgeContainerForNotificationInfo(info, appID);
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
        NSString *container = CRBadgeContainerForConnectionAndApplication(connection, appID);
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
        NSString *container = CRBadgeContainerForConnectionAndApplication(connection, appID);
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
        NSString *container = CRBadgeContainerForConnectionAndApplication(connection, appID);
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

static id CRBadgeSourceMarkerFromInfo(id info);
static id CRBadgeExplicitSourceTagFromInfo(id info);

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
    NSString *container = CRBadgeContainerForConnectionAndApplication(connection, appID) ?: @"DEFAULT";
    void (^reply)(NSArray *) = completion;
    original(self, cmd, appID, ^(NSArray *requests) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (id request in requests) {
            if (![request respondsToSelector:@selector(content)])
                continue;
            id content = ((id (*)(id, SEL))objc_msgSend)(request, @selector(content));
            id info = [content respondsToSelector:@selector(userInfo)]
                ? ((id (*)(id, SEL))objc_msgSend)(content, @selector(userInfo)) : nil;
            /* Original 0x12424 delegates to 0xBE18 for source matching. */
            id source = CRBadgeSourceMarkerFromInfo(info);
            if (![container isEqualToString:source])
                continue;
            SEL copySEL = NSSelectorFromString(@"crane_copyWithoutContainerID");
            if (![request respondsToSelector:copySEL])
                continue;
            id copied = ((id (*)(id, SEL))objc_msgSend)(request, copySEL);
            if (!copied ||
                (CRBadgeExplicitSourceTagFromInfo(info) && copied == request))
                continue;
            /* Recheck the returned request: the private copy selector can
             * be provided by a different implementation on some builds. */
            id copiedContent = [copied respondsToSelector:@selector(content)]
                ? ((id (*)(id, SEL))objc_msgSend)(copied, @selector(content)) : nil;
            id copiedInfo = [copiedContent respondsToSelector:@selector(userInfo)]
                ? ((id (*)(id, SEL))objc_msgSend)(copiedContent, @selector(userInfo)) : nil;
            if (!copiedInfo ||
                ![copiedInfo respondsToSelector:@selector(objectForKeyedSubscript:)] ||
                CRBadgeExplicitSourceTagFromInfo(copiedInfo))
                continue;
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
            if (removeAll) {
                /* Original 0xC5E0 enumerates pending requests in order
                 * and forwards every valid identifier. */
                for (id request in pending) {
                    id identifier = [request respondsToSelector:@selector(identifier)]
                        ? ((id (*)(id, SEL))objc_msgSend)(
                            request, @selector(identifier)) : nil;
                    if (identifier)
                        [identifiers addObject:identifier];
                }
            } else {
                /* Original 0xC1D4 enumerates requested IDs FIRST and
                 * searches the caller-scoped pending list for each one.
                 * Preserve original order and repeated requested IDs:
                 * iterating pending first silently dropped duplicates. */
                for (id requestedIdentifier in requested) {
                    for (id request in pending) {
                        id identifier = [request respondsToSelector:@selector(identifier)]
                            ? ((id (*)(id, SEL))objc_msgSend)(
                                request, @selector(identifier)) : nil;
                        if ([identifier isEqualToString:requestedIdentifier]) {
                            [identifiers addObject:requestedIdentifier];
                            break;
                        }
                    }
                }
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
static BOOL CRBadgeDaemonSupportVerified(NSString *daemon);
extern void CRPresentApsdRegistrationError(NSString *appID);

static void CRBadgeInvalidateToken(id self, SEL cmd, NSString *appID)
{
    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gCRBadgeInvalidateTokenOriginal;
    if (!original)
        return;
    /* Native 0xDC5C/0xE194 checks 0x11D74 before encoding the topic.
     * Failure must keep Apple's original registration/invalidation path. */
    if (CRBadgeRedirectionEnabled(appID) &&
        CRBadgeDaemonSupportVerified(@"apsd")) {
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

/* 0xDA30/0xDF68: route token requests to container-specific APNs topics.
 * Only modern 0xDA30 scopes origin on the thread; legacy 0xDF68 aliases
 * the source-description table or forwards the unencoded original ID. */
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
    /* Native 0xDA30/0xDF68 invokes 0x11D74 before obtaining the PID.
     * Do not manufacture a container APNs topic if apsd has no verified
     * CraneSupport runtime report. */
    if (!CRBadgeDaemonSupportVerified(@"apsd")) {
        CRPresentApsdRegistrationError(appID);
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
    /* 0xDA30 scopes LSApplicationProxy's bundle rewrite to the modern
     * listener. Native 0xDF68 uses a source-description alias instead and
     * does NOT establish crane_requestOriginContainerID. */
    BOOL legacyListener = class_getInstanceVariable(object_getClass(self),
        "_bundleIdentifierToSourceDescription") != NULL;
    if (!legacyListener)
        context[key] = container;
    /* 0xDF68: older UNCLocal listener implementations keep a source
     * description indexed by the original bundle ID. Temporarily alias it
     * under the encoded topic while the original request runs. */
    NSMutableDictionary *descriptions = nil;
    id sourceDescription = nil;
    BOOL aliasInstalled = NO;
    /* 0xDF68 (legacy): if the source-description ivar exists but no
     * description is registered for the base app, native forwards the
     * original bundle identifier rather than an unresolvable Crane topic.
     * 0xDA30 (modern) does not consult this ivar. */
    BOOL legacyDescriptionMissing = NO;
    if (legacyListener) {
        legacyDescriptionMissing = YES;
        @try {
            id mapping = [self valueForKey:@"_bundleIdentifierToSourceDescription"];
            if ([mapping isKindOfClass:[NSMutableDictionary class]]) {
                id candidate = mapping[appID];
                if (candidate) {
                    legacyDescriptionMissing = NO;
                    if (!mapping[topic]) {
                        descriptions = mapping;
                        sourceDescription = candidate;
                        descriptions[topic] = sourceDescription;
                        aliasInstalled = YES;
                    }
                }
            }
        } @catch (NSException *exception) {
            (void)exception;
        }
    }
    @try {
        original(self, cmd, legacyDescriptionMissing ? appID : topic,
                 completion);
    } @finally {
        if (aliasInstalled && descriptions[topic] == sourceDescription)
            [descriptions removeObjectForKey:topic];
        if (!legacyListener) {
            if (previous)
                context[key] = previous;
            else
                [context removeObjectForKey:key];
        }
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
        /* 0xEBA0 skips DEFAULT, not an empty identifier. */
        if (![identifier isKindOfClass:[NSString class]] ||
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
static id CRBadgeSourceMarkerFromInfo(id info);

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
            /* 0xEDF4 calls 0xBE18 even when userInfo is nil.  The
             * settings lookup must receive the original nil/DEFAULT marker. */
            id source = CRBadgeSourceMarkerFromInfo(info);
            NSDictionary *settings = [[CraneManager sharedManager]
                containerSettingsForContainerWithIdentifier:source
                ofApplicationWithIdentifier:topic];
            id allowed = [settings objectForKey:@"notificationsAllowed"];
            if (allowed && [allowed respondsToSelector:@selector(boolValue)] &&
                ![allowed boolValue])
                return;
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
    /* Mirror 0xBA6C keyed lookup for enabled applications, but keep the
     * current conservative pkd-unverified gate above until it is ported. */
    SEL keyedSEL = @selector(objectForKeyedSubscript:);
    if (!info || ![info respondsToSelector:keyedSEL])
        return @"DEFAULT";
    id source = ((id (*)(id, SEL, id))objc_msgSend)(
        info, keyedSEL, @"crane_sourceContainerID");
    if (!source)
        return @"DEFAULT";
    return [source isKindOfClass:[NSString class]] && [source length]
        ? source : nil;
}

/* CraneSB 0xB7B8 -> 0x11CA4 -> 0x11D64: verify pkd through
 * cranehelperd before setting extension_containerIDToAppend. Fail closed
 * when the synchronous helper proxy cannot provide a verified reply. */
extern void CRPresentPkdRegistrationError(NSString *appID);
static BOOL CRBadgeDaemonSupportVerified(NSString *daemon)
{
    CraneManager *manager = [CraneManager sharedManager];
    SEL safeSEL = NSSelectorFromString(@"runSafeXPCBlock:");
    SEL verifySEL = NSSelectorFromString(
        @"verifyCraneSupportLoadedIntoDaemon:reply:");
    if (![manager respondsToSelector:safeSEL])
        return NO;
    __block BOOL verified = NO;
    __block BOOL replied = NO;
    dispatch_block_t check = ^{
        id proxy = [manager cranehelperdGlobalSyncRemoteObjectProxy];
        if (![proxy respondsToSelector:verifySEL])
            return;
        void (^reply)(BOOL) = ^(BOOL supported) {
            verified = supported;
            replied = YES;
        };
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            proxy, verifySEL, daemon, reply);
    };
    ((void (*)(id, SEL, id))objc_msgSend)(manager, safeSEL, check);
    return replied && verified;
}

static BOOL CRBadgePkdSupportVerified(void)
{
    return CRBadgeDaemonSupportVerified(@"pkd");
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
    if (container && !CRBadgePkdSupportVerified()) {
        CRPresentPkdRegistrationError(appID);
        container = nil;
    }
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
    if (container && !CRBadgePkdSupportVerified()) {
        CRPresentPkdRegistrationError(appID);
        container = nil;
    }
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
    /* Original 0xE730 skips decoration only when the name is nil. */
    if (!name)
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
    /* 0x1119C calls the same native 0xBA6C source resolver as 0xF254. */
    id source = CRBadgeContainerForNotificationInfo(info, appID);
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

/* CraneSB 0x11420/0x126D0: bulletin actions switch the associated
 * container before forwarding the response to the original provider. */
static IMP gCRBadgeBulletinActionOriginal;
static void CRBadgeBulletinAction(id self, SEL cmd, id response, id completion)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeBulletinActionOriginal;
    if (!original)
        return;
    NSInteger actionType = [response respondsToSelector:@selector(actionType)]
        ? ((NSInteger (*)(id, SEL))objc_msgSend)(response, @selector(actionType)) : 0;
    if (actionType == 8 || actionType == 5) {
        original(self, cmd, response, completion);
        return;
    }
    id appID = [self respondsToSelector:@selector(sectionIdentifier)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(sectionIdentifier)) : nil;
    id context = [response respondsToSelector:@selector(bulletinContext)]
        ? ((id (*)(id, SEL))objc_msgSend)(response, @selector(bulletinContext)) : nil;
    /* Original 0x11420 uses 0xBA6C for bulletin context as well. */
    id container = CRBadgeContainerForNotificationInfo(context, appID);
    if (!container) {
        original(self, cmd, response, completion);
        return;
    }
    [[CraneManager sharedManager]
        setActiveContainerIdentifier:container
         forApplicationWithIdentifier:appID
                 reloadApplication:YES
   usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {
        (void)authenticated;
        original(self, cmd, response, completion);
    }];
}

static id CRBadgeSourceMarkerFromInfo(id info);
static id CRBadgeExplicitSourceTagFromInfo(id info);

/* CraneSB 0x115F4: carry request source metadata into mutated content. */
static IMP gCRBadgeMutateContentOriginal;
static id CRBadgeMutateContent(id self, SEL cmd, id request, id error)
{
    id (*original)(id, SEL, id, id) =
        (id (*)(id, SEL, id, id))gCRBadgeMutateContentOriginal;
    id content = [request respondsToSelector:@selector(content)]
        ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(content)) : nil;
    id info = [content respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(content, @selector(userInfo)) : nil;
    /* CraneSB 0xBE18: absent userInfo means no source; absent key in
     * present userInfo means DEFAULT. */
    id source = CRBadgeSourceMarkerFromInfo(info);
    id mutated = original ? original(self, cmd, request, error) : nil;
    if (source && ![source isEqual:@"DEFAULT"] &&
        [mutated respondsToSelector:@selector(userInfo)]) {
        id mutatedInfo = ((id (*)(id, SEL))objc_msgSend)(mutated, @selector(userInfo));
        /* Native 0x1235C copies the returned keyed userInfo and installs
         * the original source marker. Do not assume NSDictionary identity. */
        if ([mutatedInfo respondsToSelector:@selector(mutableCopy)]) {
            @try {
                id tagged = [mutatedInfo mutableCopy];
                SEL setSEL = @selector(setObject:forKeyedSubscript:);
                if (tagged && tagged != mutatedInfo &&
                    [tagged respondsToSelector:setSEL]) {
                    ((void (*)(id, SEL, id, id))objc_msgSend)(tagged, setSEL,
                        source, @"crane_sourceContainerID");
                    [mutated setValue:[tagged copy] forKey:@"_userInfo"];
                }
            } @catch (NSException *exception) { (void)exception; }
        }
    }
    return mutated;
}

/* Native 0x126E8 reads keyed userInfo and both copy selectors remove only
 * its source marker. Keep the mutation on an independent copy, and reject
 * unknown collection implementations if copying/removal fails. */
static id CRBadgeUserInfoCopyWithoutTag(id info)
{
    if (!CRBadgeExplicitSourceTagFromInfo(info))
        return nil;
    @try {
        id stripped = [info respondsToSelector:@selector(mutableCopy)]
            ? [info mutableCopy] : nil;
        if (!stripped || stripped == info ||
            ![stripped respondsToSelector:@selector(removeObjectForKey:)])
            return nil;
        [stripped removeObjectForKey:@"crane_sourceContainerID"];
        id clean = [stripped copy];
        if (!clean || ![clean respondsToSelector:@selector(objectForKeyedSubscript:)] ||
            CRBadgeExplicitSourceTagFromInfo(clean))
            return nil;
        return clean;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

/* CraneSB 0x1172C/0x11984/0x126E8: remove only the source marker.
 * Preserve object identity when there is no marker to strip. */
static id CRBadgeRecordCopyWithoutContainer(id self, SEL cmd)
{
    id info = [self respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(userInfo)) : nil;
    if (!CRBadgeExplicitSourceTagFromInfo(info))
        return self;
    id stripped = CRBadgeUserInfoCopyWithoutTag(info);
    if (!stripped)
        return nil;
    id representation = [self respondsToSelector:@selector(dictionaryRepresentation)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(dictionaryRepresentation)) : nil;
    Class recordClass = NSClassFromString(@"UNSNotificationRecord");
    id allocated = ((id (*)(id, SEL))objc_msgSend)(recordClass, @selector(alloc));
    SEL initSEL = NSSelectorFromString(@"initWithDictionaryRepresentation:");
    id record = [allocated respondsToSelector:initSEL] && representation
        ? ((id (*)(id, SEL, id))objc_msgSend)(allocated, initSEL, representation)
        : nil;
    /* 0x1172C constructs a UNSNotificationRecord from its dictionary
     * representation; it does not fall back to NSCopying. */
    if (!record || record == self ||
        ![record respondsToSelector:@selector(setUserInfo:)])
        return nil;
    @try {
        ((void (*)(id, SEL, id))objc_msgSend)(
            record, @selector(setUserInfo:), [stripped copy]);
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
    /* Private setters can silently decline updates on some iOS builds.
     * Only return a copy after confirming the source marker is gone. */
    id verifiedInfo = [record respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo)) : nil;
    if (!verifiedInfo ||
        ![verifiedInfo respondsToSelector:@selector(objectForKeyedSubscript:)] ||
        CRBadgeExplicitSourceTagFromInfo(verifiedInfo))
        return nil;
    return record;
}

static id CRBadgeRequestCopyWithoutContainer(id self, SEL cmd)
{
    id content = [self respondsToSelector:@selector(content)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(content)) : nil;
    id info = [content respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(content, @selector(userInfo)) : nil;
    if (!CRBadgeExplicitSourceTagFromInfo(info))
        return self;
    id stripped = CRBadgeUserInfoCopyWithoutTag(info);
    if (!stripped)
        return nil;
    /* Original 0x11984 invokes copy directly on UNNotificationRequest. */
    id request = [self copy];
    if (!request || request == self)
        return nil;
    id copiedContent = [request respondsToSelector:@selector(content)]
        ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(content)) : nil;
    if (!copiedContent || copiedContent == content)
        return nil;
    @try {
        [copiedContent setValue:[stripped copy] forKey:@"_userInfo"];
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
    id verifiedInfo = [copiedContent respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(copiedContent, @selector(userInfo)) : nil;
    if (!verifiedInfo ||
        ![verifiedInfo respondsToSelector:@selector(objectForKeyedSubscript:)] ||
        CRBadgeExplicitSourceTagFromInfo(verifiedInfo))
        return nil;
    return request;
}

/* Native 0x126E8: a present, keyed userInfo returns the explicit marker;
 * nil userInfo or a missing key has no explicit marker. */
static id CRBadgeExplicitSourceTagFromInfo(id info)
{
    if (!info || ![info respondsToSelector:@selector(objectForKeyedSubscript:)])
        return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        info, @selector(objectForKeyedSubscript:), @"crane_sourceContainerID");
}

/* CraneSB 0x11884/0xBE18: matching records from different source
 * containers must not be considered similar. */
static id CRBadgeSourceMarkerFromInfo(id info)
{
    /* Native 0xBE18: nil userInfo stays nil; present info without a
     * crane_sourceContainerID marker belongs to DEFAULT. */
    if (!info || ![info respondsToSelector:@selector(objectForKeyedSubscript:)])
        return nil;
    id marker = ((id (*)(id, SEL, id))objc_msgSend)(
        info, @selector(objectForKeyedSubscript:), @"crane_sourceContainerID");
    return marker ?: @"DEFAULT";
}

static IMP gCRBadgeRecordSimilarOriginal;
static BOOL CRBadgeRecordIsSimilar(id self, SEL cmd, id other)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeRecordSimilarOriginal;
    BOOL similar = original ? original(self, cmd, other) : NO;
    if (!similar)
        return NO;
    id lhs = [self respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(self, @selector(userInfo)) : nil;
    id rhs = [other respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(other, @selector(userInfo)) : nil;
    id lhsContainer = CRBadgeSourceMarkerFromInfo(lhs);
    id rhsContainer = CRBadgeSourceMarkerFromInfo(rhs);
    return [lhsContainer isEqualToString:rhsContainer];
}

/* CraneSB 0xF59C/0xF750: repository reads expose only records from
 * the caller's container and strip the private source tag. */
static id CRBadgeRecordSource(id record)
{
    id info = [record respondsToSelector:@selector(userInfo)]
        ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo)) : nil;
    return CRBadgeSourceMarkerFromInfo(info);
}

/* Verify the copy postcondition even if another implementation supplies
 * crane_copyWithoutContainerID at runtime. */
static id CRBadgeSanitizedRecord(id record)
{
    SEL copySEL = NSSelectorFromString(@"crane_copyWithoutContainerID");
    if (![record respondsToSelector:copySEL])
        return nil;
    @try {
        id originalInfo = [record respondsToSelector:@selector(userInfo)]
            ? ((id (*)(id, SEL))objc_msgSend)(record, @selector(userInfo)) : nil;
        BOOL tagged = CRBadgeExplicitSourceTagFromInfo(originalInfo) != nil;
        id clean = ((id (*)(id, SEL))objc_msgSend)(record, copySEL);
        /* Tagged repository records must not be sanitized in place. */
        if (tagged && clean == record)
            return nil;
        id info = [clean respondsToSelector:@selector(userInfo)]
            ? ((id (*)(id, SEL))objc_msgSend)(clean, @selector(userInfo)) : nil;
        if (!info ||
            ![info respondsToSelector:@selector(objectForKeyedSubscript:)] ||
            CRBadgeExplicitSourceTagFromInfo(info))
            return nil;
        return clean;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

static IMP gCRBadgeRecordLookupOriginal;
static id CRBadgeRecordLookup(id self, SEL cmd, id identifier, NSString *appID)
{
    id (*original)(id, SEL, id, id) =
        (id (*)(id, SEL, id, id))gCRBadgeRecordLookupOriginal;
    if (!original)
        return nil;
    if (!CRBadgeRedirectionEnabled(appID) || ![NSXPCConnection currentConnection])
        return original(self, cmd, identifier, appID);
    NSString *container = CRBadgeContainerForConnectionAndApplication(
        [NSXPCConnection currentConnection], appID) ?: @"DEFAULT";
    id record = original(self, cmd, identifier, appID);
    if (![CRBadgeRecordSource(record) isEqualToString:container])
        return nil;
    return CRBadgeSanitizedRecord(record);
}

static IMP gCRBadgeRecordsLookupOriginal;
static id CRBadgeRecordsLookup(id self, SEL cmd, NSString *appID)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gCRBadgeRecordsLookupOriginal;
    if (!original)
        return nil;
    if (!CRBadgeRedirectionEnabled(appID) || ![NSXPCConnection currentConnection])
        return original(self, cmd, appID);
    NSString *container = CRBadgeContainerForConnectionAndApplication(
        [NSXPCConnection currentConnection], appID) ?: @"DEFAULT";
    NSArray *records = original(self, cmd, appID);
    NSMutableArray *filtered = [NSMutableArray array];
    for (id record in records) {
        if (![CRBadgeRecordSource(record) isEqualToString:container])
            continue;
        id clean = CRBadgeSanitizedRecord(record);
        if (clean)
            [filtered addObject:clean];
    }
    return [filtered copy];
}

/* CraneSB 0xFA20/0x120B0: asynchronously filter repository records
 * with the caller's XPC container captured before the original call. */
static IMP gCRBadgeRecordsLookupWithReplyOriginal;
static void CRBadgeRecordsLookupWithReply(id self, SEL cmd,
                                           NSString *appID, id completion)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeRecordsLookupWithReplyOriginal;
    if (!original)
        return;
    NSXPCConnection *connection = [NSXPCConnection currentConnection];
    if (!CRBadgeRedirectionEnabled(appID) || !connection || !completion) {
        original(self, cmd, appID, completion);
        return;
    }
    NSString *container = CRBadgeContainerForConnectionAndApplication(connection, appID) ?: @"DEFAULT";
    void (^reply)(NSArray *) = completion;
    original(self, cmd, appID, ^(NSArray *records) {
        NSMutableArray *filtered = [NSMutableArray array];
        for (id record in records) {
            if (![CRBadgeRecordSource(record) isEqualToString:container])
                continue;
            id clean = CRBadgeSanitizedRecord(record);
            if (clean)
                [filtered addObject:clean];
        }
        reply([filtered copy]);
    });
}

/* CraneSB 0xF398/0x11FC0: apply the caller's predicate first,
 * then require the notification record to belong to its container. */
static IMP gCRBadgeRemoveRecordsPassingTestOriginal;
static void CRBadgeRemoveRecordsPassingTest(id self, SEL cmd, id predicate,
                                             NSString *appID)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeRemoveRecordsPassingTestOriginal;
    if (!original)
        return;
    NSXPCConnection *connection = [NSXPCConnection currentConnection];
    if (!CRBadgeRedirectionEnabled(appID) || !connection || !predicate) {
        original(self, cmd, predicate, appID);
        return;
    }
    NSString *container = CRBadgeContainerForConnectionAndApplication(connection, appID) ?: @"DEFAULT";
    BOOL (^test)(id) = predicate;
    original(self, cmd, ^BOOL(id record) {
        if (!test(record))
            return NO;
        return [CRBadgeRecordSource(record) isEqualToString:container];
    }, appID);
}

/* CraneSB 0xF524: when notification redirection is enabled, route
 * remove-all through the predicate remover (0xF398) instead of the original
 * unscoped remove-all implementation. The native predicate is always YES. */
static IMP gCRBadgeRemoveAllRecordsOriginal;
static void CRBadgeRemoveAllRecords(id self, SEL cmd, NSString *appID)
{
    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gCRBadgeRemoveAllRecordsOriginal;
    if (!CRBadgeRedirectionEnabled(appID)) {
        if (original) original(self, cmd, appID);
        return;
    }
    SEL removeSEL = NSSelectorFromString(
        @"removeNotificationRecordsPassingTest:forBundleIdentifier:");
    if ([self respondsToSelector:removeSEL])
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            self, removeSEL, ^BOOL(id record) { (void)record; return YES; }, appID);
}

/* CraneSB 0x10AD8: invalidate the remote-notification registration for
 * a specific container; DEFAULT uses the unmodified bundle identifier. */
static void CRBadgeUnregisterNotifications(id self, SEL cmd,
                                            NSString *containerID, NSString *appID)
{
    (void)self; (void)cmd;
    Class serverClass = NSClassFromString(@"UNSUserNotificationServer");
    SEL sharedSEL = NSSelectorFromString(@"sharedInstance");
    if (![serverClass respondsToSelector:sharedSEL])
        return;
    id server = ((id (*)(id, SEL))objc_msgSend)(serverClass, sharedSEL);
    id service = nil;
    @try { service = [server valueForKey:@"_remoteNotificationService"]; }
    @catch (NSException *exception) { (void)exception; }
    SEL invalidateSEL = NSSelectorFromString(
        @"invalidateTokenForRemoteNotificationsForBundleIdentifier:");
    if (![service respondsToSelector:invalidateSEL])
        return;
    NSString *topic = (containerID && ![containerID isEqualToString:@"DEFAULT"])
        ? [NSString stringWithFormat:@"%@.c_r_a_n_e.%@", appID, containerID]
        : appID;
    ((void (*)(id, SEL, id))objc_msgSend)(service, invalidateSEL, topic);
}

/* The original binary contains a Clang-compiled
 * _OBJC_PROTOCOL_$_UNUserNotificationProtocolCraneAdditions. It MUST
 * be declared with @protocol (CRXPCProtocols.h), not synthesized with
 * objc_allocateProtocol(): NSXPCInterface on iOS 15 requires Clang's
 * extended method type metadata and otherwise throws at setProtocol:. */

/* CraneSB 0x11AF8/0x1F7B0: widen the notification server XPC
 * protocol only when both original and Crane additions are available.
 * Do not substitute a missing protocol (which would invalidate XPC). */
static IMP gCRBadgeXPCSetProtocolOriginal;
static void CRBadgeXPCSetProtocol(id self, SEL cmd, Protocol *protocol)
{
    void (*original)(id, SEL, Protocol *) =
        (void (*)(id, SEL, Protocol *))gCRBadgeXPCSetProtocolOriginal;
    if (!original)
        return;
    Protocol *base = objc_getProtocol("UNUserNotificationServerProtocol");
    Protocol *additions = @protocol(UNUserNotificationProtocolCraneAdditions);
    if (base && additions && protocol && protocol_isEqual(protocol, base)) {
        Protocol *extended = objc_getProtocol(
            "UNUserNotificationServerProtocolPlusCraneAdditions");
        if (!extended) {
            extended = objc_allocateProtocol(
                "UNUserNotificationServerProtocolPlusCraneAdditions");
            if (extended) {
                protocol_addProtocol(extended, additions);
                protocol_addProtocol(extended, base);
                objc_registerProtocol(extended);
            }
        }
        if (extended) {
            @try {
                original(self, cmd, extended);
                return;
            } @catch (NSException *exception) {
                /* An incompatible extended interface must not terminate
                 * SpringBoard. Fall back to the unmodified Apple protocol,
                 * disabling Crane's notification XPC additions for this
                 * interface rather than triggering a Safe Mode crash. */
                NSLog(@"CraneSB: extended notification XPC interface rejected: %@; using original protocol",
                      exception);
            }
        }
    }
    original(self, cmd, protocol);
}

/* CraneSB 0xF19C/0xF1F8 -> 0xC7D4/0xC8B4: after the system
 * unregisters an app, clean up all container-specific APNS topics. */
static char gCRBadgeUninstallQueueSpecificKey;
static void CRBadgeCleanupUninstalledSources(id server, id sources)
{
    if (![sources conformsToProtocol:@protocol(NSFastEnumeration)])
        return;
    dispatch_queue_t queue = nil;
    @try { queue = [server valueForKey:@"_queue"]; }
    @catch (NSException *exception) { (void)exception; }
    if (!queue)
        return;
    /* The original 0xC7D4 dispatches synchronously. Avoid deadlock if
     * an uninstall callback itself arrives on this serial queue. */
    dispatch_queue_set_specific(queue, &gCRBadgeUninstallQueueSpecificKey,
                                (__bridge void *)queue, NULL);
    dispatch_block_t cleanup = ^{
        SEL invalidate = NSSelectorFromString(@"_queue_invalidateTokenForBundleIdentifier:");
        SEL removeRegistration = NSSelectorFromString(@"_queue_removeRegistrationForBundleIdentifier:");
        SEL removeClient = NSSelectorFromString(@"_queue_removeClientForBundleIdentifier:");
        for (id source in sources) {
            NSString *appID = [source respondsToSelector:@selector(bundleIdentifier)]
                ? ((id (*)(id, SEL))objc_msgSend)(source, @selector(bundleIdentifier)) : nil;
            if (![appID isKindOfClass:[NSString class]] ||
                !CRBadgeRedirectionEnabled(appID))
                continue;
            NSArray *containers = [[CraneManager sharedManager]
                containerIdentifiersOfApplicationWithIdentifier:appID];
            for (NSString *container in containers) {
                /* 0x1FEF0 builds no topic when either argument is nil.
                 * Avoid generating a synthetic "(null)" APNS identifier. */
                if (![container isKindOfClass:[NSString class]])
                    continue;
                NSString *topic = [NSString stringWithFormat:
                    @"%@.c_r_a_n_e.%@", appID, container];
                if ([server respondsToSelector:invalidate])
                    ((void (*)(id, SEL, id))objc_msgSend)(server, invalidate, topic);
                if ([server respondsToSelector:removeRegistration])
                    ((void (*)(id, SEL, id))objc_msgSend)(server, removeRegistration, topic);
                else if ([server respondsToSelector:removeClient])
                    ((void (*)(id, SEL, id))objc_msgSend)(server, removeClient, topic);
            }
        }
        SEL recalculate = NSSelectorFromString(@"_queue_calculateTopics");
        if ([server respondsToSelector:recalculate])
            ((void (*)(id, SEL))objc_msgSend)(server, recalculate);
    };
    /* A non-null value from another repository's queue must not cause
     * this repository's cleanup to run on the wrong queue. */
    if (dispatch_get_specific(&gCRBadgeUninstallQueueSpecificKey) ==
        (__bridge void *)queue)
        cleanup();
    else
        dispatch_sync(queue, cleanup);
}

static IMP gCRBadgeSourcesUninstallOriginal;
static IMP gCRBadgeAppsUninstallOriginal;
static void CRBadgeSourcesUninstalled(id self, SEL cmd, id sources)
{
    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gCRBadgeSourcesUninstallOriginal;
    if (original) original(self, cmd, sources);
    CRBadgeCleanupUninstalledSources(self, sources);
}
static void CRBadgeApplicationsUninstalled(id self, SEL cmd, id apps)
{
    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gCRBadgeAppsUninstallOriginal;
    if (original) original(self, cmd, apps);
    CRBadgeCleanupUninstalledSources(self, apps);
}

/* CraneSB 0xD55C/0xD6B4/0xD80C: pass the requesting
 * container into extension discovery without mutating caller attributes. */
static id CRBadgeExtensionMatchingAttributes(id attributes)
{
    id container = [NSThread currentThread].threadDictionary[
        @"extension_containerIDToAppend"];
    if (!container || ![attributes isKindOfClass:[NSDictionary class]])
        return attributes;
    NSMutableDictionary *tagged = [attributes mutableCopy];
    tagged[@"crane_containerID"] = container;
    return tagged;
}

static IMP gCRBadgeExtensionSyncOriginal;
static IMP gCRBadgeExtensionAsyncOriginal;
static void CRBadgeExtensionsSync(id self, SEL cmd, id attributes,
                                   BOOL synchronously, id completion)
{
    void (*original)(id, SEL, id, BOOL, id) =
        (void (*)(id, SEL, id, BOOL, id))gCRBadgeExtensionSyncOriginal;
    if (original)
        original(self, cmd, CRBadgeExtensionMatchingAttributes(attributes),
                 synchronously, completion);
}

static void CRBadgeExtensionsAsync(id self, SEL cmd, id attributes,
                                    id completion)
{
    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gCRBadgeExtensionAsyncOriginal;
    if (original)
        original(self, cmd, CRBadgeExtensionMatchingAttributes(attributes),
                 completion);
}

/* CraneSB 0xEA50: a Crane-encoded notification topic is authorized
 * only when its container ID matches the current XPC client's PID. */
static IMP gCRBadgeNotificationPermissionOriginal;
static BOOL CRBadgeNotificationPermission(id self, SEL cmd, NSString *topic)
{
    BOOL (*original)(id, SEL, id) =
        (BOOL (*)(id, SEL, id))gCRBadgeNotificationPermissionOriginal;
    if (!original)
        return NO;
    if (![topic isKindOfClass:[NSString class]])
        return original(self, cmd, topic);
    NSRange separator = [topic rangeOfString:@".c_r_a_n_e."];
    if (separator.location == NSNotFound)
        return original(self, cmd, topic);
    /* 0x1FF7C uses firstObject for the bundle and lastObject for
     * the container, including topics with repeated separators. */
    NSArray *parts = [topic componentsSeparatedByString:@".c_r_a_n_e."];
    NSString *appID = [parts firstObject];
    NSString *container = [parts lastObject];
    NSString *active = CRBadgeContainerForConnection(self);
    if (![active isEqualToString:container])
        return NO;
    return original(self, cmd, appID);
}

void CRInitBadgeListenerMethods(void)
{
    /* Prefer EXConcreteExtension; otherwise use NSExtension's supported
     * synchronous or legacy asynchronous class-method signature (0xCBEC). */
    Class extensionLookupClass = NSClassFromString(@"EXConcreteExtension");
    if (!extensionLookupClass)
        extensionLookupClass = NSClassFromString(@"NSExtension");
    SEL syncExtensionsSEL = NSSelectorFromString(
        @"extensionsWithMatchingAttributes:synchronously:completion:");
    SEL asyncExtensionsSEL = NSSelectorFromString(
        @"extensionsWithMatchingAttributes:completion:");
    if (extensionLookupClass) {
        Class extensionMeta = object_getClass(extensionLookupClass);
        if ([extensionLookupClass respondsToSelector:syncExtensionsSEL])
            MSHookMessageEx(extensionMeta, syncExtensionsSEL,
                            (IMP)CRBadgeExtensionsSync,
                            &gCRBadgeExtensionSyncOriginal);
        else if ([extensionLookupClass respondsToSelector:asyncExtensionsSEL])
            MSHookMessageEx(extensionMeta, asyncExtensionsSEL,
                            (IMP)CRBadgeExtensionsAsync,
                            &gCRBadgeExtensionAsyncOriginal);
    }
    Class xpcClass = NSClassFromString(@"NSXPCConnection");
    SEL permissionSEL = NSSelectorFromString(
        @"uns_isAllowedToRequestUserNotificationsForBundleIdentifier:");
    if (xpcClass && [xpcClass instancesRespondToSelector:permissionSEL])
        MSHookMessageEx(xpcClass, permissionSEL,
                        (IMP)CRBadgeNotificationPermission,
                        &gCRBadgeNotificationPermissionOriginal);
    Class xpcInterface = NSClassFromString(@"NSXPCInterface");
    SEL setProtocolSEL = NSSelectorFromString(@"setProtocol:");
    if (xpcInterface && [xpcInterface instancesRespondToSelector:setProtocolSEL])
        MSHookMessageEx(xpcInterface, setProtocolSEL,
                        (IMP)CRBadgeXPCSetProtocol, &gCRBadgeXPCSetProtocolOriginal);
    Class repositoryClass = NSClassFromString(@"UNSNotificationRepository");
    if (!repositoryClass)
        repositoryClass = NSClassFromString(@"UNCLocalNotificationRepository");
    SEL removeAllRecordsSEL = NSSelectorFromString(
        @"removeAllNotificationRecordsForBundleIdentifier:");
    if (repositoryClass && [repositoryClass instancesRespondToSelector:removeAllRecordsSEL])
        MSHookMessageEx(repositoryClass, removeAllRecordsSEL,
                        (IMP)CRBadgeRemoveAllRecords,
                        &gCRBadgeRemoveAllRecordsOriginal);
    SEL removeTestSEL = NSSelectorFromString(
        @"removeNotificationRecordsPassingTest:forBundleIdentifier:");
    if (repositoryClass && [repositoryClass instancesRespondToSelector:removeTestSEL])
        MSHookMessageEx(repositoryClass, removeTestSEL,
                        (IMP)CRBadgeRemoveRecordsPassingTest,
                        &gCRBadgeRemoveRecordsPassingTestOriginal);
    SEL recordSEL = NSSelectorFromString(@"notificationRecordForForIdentifier:bundleIdentifier:");
    if (repositoryClass && [repositoryClass instancesRespondToSelector:recordSEL])
        MSHookMessageEx(repositoryClass, recordSEL, (IMP)CRBadgeRecordLookup,
                        &gCRBadgeRecordLookupOriginal);
    SEL recordsReplySEL = NSSelectorFromString(
        @"notificationRecordsForBundleIdentifier:withCompletionHandler:");
    if (repositoryClass && [repositoryClass instancesRespondToSelector:recordsReplySEL])
        MSHookMessageEx(repositoryClass, recordsReplySEL,
                        (IMP)CRBadgeRecordsLookupWithReply,
                        &gCRBadgeRecordsLookupWithReplyOriginal);
    SEL recordsSEL = NSSelectorFromString(@"notificationRecordsForBundleIdentifier:");
    if (repositoryClass && [repositoryClass instancesRespondToSelector:recordsSEL])
        MSHookMessageEx(repositoryClass, recordsSEL, (IMP)CRBadgeRecordsLookup,
                        &gCRBadgeRecordsLookupOriginal);
    SEL copySEL = NSSelectorFromString(@"crane_copyWithoutContainerID");
    Class recordClass = NSClassFromString(@"UNSNotificationRecord");
    if (recordClass) {
        class_addMethod(recordClass, copySEL,
                        (IMP)CRBadgeRecordCopyWithoutContainer, "@@:");
        SEL similarSEL = NSSelectorFromString(@"isSimilar:");
        if ([recordClass instancesRespondToSelector:similarSEL])
            MSHookMessageEx(recordClass, similarSEL,
                            (IMP)CRBadgeRecordIsSimilar,
                            &gCRBadgeRecordSimilarOriginal);
    }
    Class requestClass = NSClassFromString(@"UNNotificationRequest");
    if (requestClass)
        class_addMethod(requestClass, copySEL,
                        (IMP)CRBadgeRequestCopyWithoutContainer, "@@:");
    Class extension = NSClassFromString(@"UNSNotificationServiceExtension");
    if (!extension)
        extension = NSClassFromString(@"UNCNotificationServiceExtension");
    SEL mutateSEL = NSSelectorFromString(@"mutateContentForNotificationRequest:error:");
    if (extension && [extension instancesRespondToSelector:mutateSEL])
        MSHookMessageEx(extension, mutateSEL, (IMP)CRBadgeMutateContent,
                        &gCRBadgeMutateContentOriginal);
    Class notificationServer = NSClassFromString(@"UNSUserNotificationServer");
    SEL systemForegroundSEL = NSSelectorFromString(@"isApplicationForeground:");
    if (notificationServer && [notificationServer instancesRespondToSelector:systemForegroundSEL])
        MSHookMessageEx(notificationServer, systemForegroundSEL,
                        (IMP)CRBadgeSystemForeground, &gCRBadgeSystemForegroundOriginal);
    Class dataProvider = NSClassFromString(@"UNSDefaultDataProvider");
    SEL actionSEL = NSSelectorFromString(@"handleBulletinActionResponse:withCompletion:");
    if (dataProvider && [dataProvider instancesRespondToSelector:actionSEL])
        MSHookMessageEx(dataProvider, actionSEL, (IMP)CRBadgeBulletinAction,
                        &gCRBadgeBulletinActionOriginal);
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
    SEL sourcesUninstallSEL = NSSelectorFromString(@"notificationSourcesDidUninstall:");
    if (remoteClass && [remoteClass instancesRespondToSelector:sourcesUninstallSEL])
        MSHookMessageEx(remoteClass, sourcesUninstallSEL,
                        (IMP)CRBadgeSourcesUninstalled,
                        &gCRBadgeSourcesUninstallOriginal);
    SEL appsUninstallSEL = NSSelectorFromString(@"applicationsDidUninstall:");
    if (remoteClass && [remoteClass instancesRespondToSelector:appsUninstallSEL])
        MSHookMessageEx(remoteClass, appsUninstallSEL,
                        (IMP)CRBadgeApplicationsUninstalled,
                        &gCRBadgeAppsUninstallOriginal);
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
        NSSelectorFromString(@"crane_unregisterFromNotificationsIfNeededForContainerIdentifier:ofApplicationWithIdentifier:"),
        (IMP)CRBadgeUnregisterNotifications, "v@:@@");
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
        /* 0xACD0 stores numberWithInt: and deletes on a 32-bit zero. */
        int nativeCount = (int)count;
        if (nativeCount != 0)
            counts[containerID] = @(nativeCount);
        else
            [counts removeObjectForKey:containerID];
        gCRBadgeStore[appID] = [counts copy];
        [gCRBadgeStore writeToFile:CRBadgeStorePath() atomically:YES];
    }
}
