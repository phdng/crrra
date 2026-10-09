/*
 * CRCfprefs.m — CraneSupport cfprefsd preference isolation.
 *
 * Transcribed from CraneSupport 0xAB1C..0xBE34 and initCfprefsd 0xBBFC.
 * Private CoreFoundation symbols are looked up dynamically; libundirect is an
 * optional runtime compatibility layer exactly as in the recovered binary.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#import <dlfcn.h>
#import <unistd.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"

extern void *MSGetImageByName(const char *name);
extern void *MSFindSymbol(void *image, const char *name);

@interface ClientContainerCache : NSObject
+ (instancetype)sharedInstance;
- (NSString *)activeContainerIdentifierForPid:(pid_t)pid;
@end

static NSString * const CranePrefsHostIdentifierKey = @"hostIdentifier";
static NSString * const CranePrefsHostPidKey = @"hostPid";
static NSString * const CranePrefsTripletContainerKey =
    @"CFPrefsGetPathForTripletHook_activeContainerID";

static NSSet<NSString *> *CRPrefsIgnoredProcesses(void)
{
    static NSSet<NSString *> *ignored;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* InitFunc_0 0x6C5C. */
        ignored = [NSSet setWithObjects:@"watchdogd",
                                      @"com.apple.springboard",
                                      nil];
    });
    return ignored;
}

/* xpc_connection_get_pid is an original CraneSupport import, but Xcode 15's
 * public iOS SDK marks it unavailable. Resolve the exact symbol at runtime. */
typedef pid_t (*CRPrefsXPCConnectionGetPidFn)(xpc_connection_t connection);

static pid_t CRPrefsConnectionPid(xpc_connection_t connection)
{
    static CRPrefsXPCConnectionGetPidFn getPid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getPid = (CRPrefsXPCConnectionGetPidFn)
            dlsym(RTLD_DEFAULT, "xpc_connection_get_pid");
    });
    return getPid ? getPid(connection) : 0;
}

/* ------------------------------------------------------------------------- */
/* Shared request/source redirection logic                                    */
/* ------------------------------------------------------------------------- */

static void CRPrefsRecordHostFromMessage(xpc_object_t message)
{
    if (!message || xpc_get_type(message) != XPC_TYPE_DICTIONARY)
        return;

    xpc_object_t connection =
        xpc_dictionary_get_value(message, "connection");
    if (!connection || xpc_get_type(connection) != XPC_TYPE_CONNECTION)
        return;

    const char *host =
        xpc_dictionary_get_string(message,
                                  "CFPreferencesHostBundleIdentifier");
    pid_t pid = CRPrefsConnectionPid((xpc_connection_t)connection);
    if (!host)
        return;

    NSString *hostIdentifier = [NSString stringWithUTF8String:host];
    if (!hostIdentifier)
        return;

    NSMutableDictionary *threadDictionary =
        NSThread.currentThread.threadDictionary;
    threadDictionary[CranePrefsHostIdentifierKey] = hostIdentifier;
    threadDictionary[CranePrefsHostPidKey] = @(pid);
}

typedef void (^CRPrefsContainerContinuation)(id redirectedContainer);

static void CRPrefsWithSourceForDomain(id domain,
                                       id container,
                                       CRPrefsContainerContinuation continuation)
{
    if (!continuation)
        return;

    if (!domain) {
        continuation(container);
        return;
    }

    NSMutableDictionary *threadDictionary =
        NSThread.currentThread.threadDictionary;
    NSString *hostIdentifier =
        threadDictionary[CranePrefsHostIdentifierKey];
    NSNumber *hostPid =
        threadDictionary[CranePrefsHostPidKey];
    pid_t pid = hostPid.intValue;

    /* ADF0 consumes these exactly once. */
    [threadDictionary removeObjectForKey:CranePrefsHostIdentifierKey];
    [threadDictionary removeObjectForKey:CranePrefsHostPidKey];

    if (!hostIdentifier ||
        !hostPid ||
        [CRPrefsIgnoredProcesses() containsObject:hostIdentifier]) {
        continuation(container);
        return;
    }

    if (container) {
        /*
         * Preferences.app is special: the domain is the target application's
         * identifier, so query CraneManager directly rather than the Preferences
         * process's pid.
         */
        if ([hostIdentifier isEqualToString:@"com.apple.Preferences"]) {
            NSString *active =
                [[CraneManager sharedManager]
                    activeContainerIdentifierForApplicationWithIdentifier:domain];
            if (active &&
                ![active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
                continuation(CRContainerPathForContainer(active, container));
                return;
            }
        }

        NSString *active =
            [[ClientContainerCache sharedInstance]
                activeContainerIdentifierForPid:pid];
        if (active) {
            continuation(CRContainerPathForContainer(active, container));
            return;
        }

        continuation(container);
        return;
    }

    /*
     * No explicit container path: only redirect when the preference domain is
     * the calling host itself. The actual filename rewrite happens later in
     * __CFPrefsGetPathForTriplet via a short-lived thread-local container ID.
     */
    if (![domain isEqual:hostIdentifier]) {
        continuation(container);
        return;
    }

    NSString *active =
        [[ClientContainerCache sharedInstance]
            activeContainerIdentifierForPid:pid];
    if (!active) {
        continuation(container);
        return;
    }

    threadDictionary[CranePrefsTripletContainerKey] = active;
    continuation(nil);
    [threadDictionary removeObjectForKey:CranePrefsTripletContainerKey];
}

/* ------------------------------------------------------------------------- */
/* handleSourceMessage                                                        */
/* ------------------------------------------------------------------------- */

static IMP gOrigHandleSourceMessageObjC;

static void CRPrefsHandleSourceMessageObjC(id self,
                                           SEL _cmd,
                                           id message,
                                           id replyHandler)
{
    CRPrefsRecordHostFromMessage((xpc_object_t)message);

    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gOrigHandleSourceMessageObjC;
    original(self, _cmd, message, replyHandler);
}

/*
 * >= CoreFoundation 2000: the recovered binary hooks the private shared-cache
 * symbol directly. AD34/ADDC show that the original symbol is invoked with only
 * the first captured argument after the generic request bookkeeping.
 */
typedef void (*CRPrefsHandleSourceMessageV2OrigFn)(void *context);
static CRPrefsHandleSourceMessageV2OrigFn gOrigHandleSourceMessageV2;

static void CRPrefsHandleSourceMessageV2(void *context,
                                         xpc_object_t message,
                                         uintptr_t thirdArgument)
{
    (void)thirdArgument;
    CRPrefsRecordHostFromMessage(message);
    if (gOrigHandleSourceMessageV2)
        gOrigHandleSourceMessageV2(context);
}

/* ------------------------------------------------------------------------- */
/* withSourceForDomain                                                        */
/* ------------------------------------------------------------------------- */

static IMP gOrigWithSourcePerform;
static IMP gOrigWithSourceLocked;

static void CRPrefsWithSourcePerform(id self,
                                     SEL _cmd,
                                     id domain,
                                     id container,
                                     id user,
                                     BOOL byHost,
                                     BOOL managed,
                                     BOOL managedUsesContainer,
                                     id cloudStoreEntitlement,
                                     id cloudConfigurationPath,
                                     id perform)
{
    CRPrefsWithSourceForDomain(domain, container, ^(id redirectedContainer) {
        void (*original)(id, SEL, id, id, id,
                         BOOL, BOOL, BOOL, id, id, id) =
            (void (*)(id, SEL, id, id, id,
                      BOOL, BOOL, BOOL, id, id, id))gOrigWithSourcePerform;
        original(self,
                 _cmd,
                 domain,
                 redirectedContainer,
                 user,
                 byHost,
                 managed,
                 managedUsesContainer,
                 cloudStoreEntitlement,
                 cloudConfigurationPath,
                 perform);
    });
}

static void CRPrefsWithSourceLocked(id self,
                                    SEL _cmd,
                                    id domain,
                                    id container,
                                    id user,
                                    BOOL byHost,
                                    BOOL managed,
                                    BOOL managedUsesContainer,
                                    id cloudStoreEntitlement,
                                    id cloudConfigurationPath,
                                    id performWithSourceLock,
                                    id afterReleasingSourceLock)
{
    CRPrefsWithSourceForDomain(domain, container, ^(id redirectedContainer) {
        void (*original)(id, SEL, id, id, id,
                         BOOL, BOOL, BOOL, id, id, id, id) =
            (void (*)(id, SEL, id, id, id,
                      BOOL, BOOL, BOOL, id, id, id, id))gOrigWithSourceLocked;
        original(self,
                 _cmd,
                 domain,
                 redirectedContainer,
                 user,
                 byHost,
                 managed,
                 managedUsesContainer,
                 cloudStoreEntitlement,
                 cloudConfigurationPath,
                 performWithSourceLock,
                 afterReleasingSourceLock);
    });
}

/*
 * >= CoreFoundation 2000. B318/B42C show the direct symbol ABI has no SEL
 * argument and otherwise preserves the locked variant's argument order.
 */
typedef void (*CRPrefsWithSourceV3OrigFn)(
    id firstArgument,
    id domain,
    id container,
    id user,
    BOOL byHost,
    BOOL managed,
    BOOL managedUsesContainer,
    id cloudStoreEntitlement,
    id cloudConfigurationPath,
    id performWithSourceLock,
    id afterReleasingSourceLock);

static CRPrefsWithSourceV3OrigFn gOrigWithSourceV3;

static void CRPrefsWithSourceV3(id firstArgument,
                                id domain,
                                id container,
                                id user,
                                BOOL byHost,
                                BOOL managed,
                                BOOL managedUsesContainer,
                                id cloudStoreEntitlement,
                                id cloudConfigurationPath,
                                id performWithSourceLock,
                                id afterReleasingSourceLock)
{
    CRPrefsWithSourceForDomain(domain, container, ^(id redirectedContainer) {
        if (gOrigWithSourceV3) {
            gOrigWithSourceV3(firstArgument,
                              domain,
                              redirectedContainer,
                              user,
                              byHost,
                              managed,
                              managedUsesContainer,
                              cloudStoreEntitlement,
                              cloudConfigurationPath,
                              performWithSourceLock,
                              afterReleasingSourceLock);
        }
    });
}

/* ------------------------------------------------------------------------- */
/* __CFPrefsGetPathForTriplet                                                 */
/* ------------------------------------------------------------------------- */

typedef uintptr_t (*CRCFPrefsGetPathForTripletFn)(
    uintptr_t a1,
    uintptr_t a2,
    uintptr_t a3,
    uintptr_t a4,
    char *pathBuffer);

static CRCFPrefsGetPathForTripletFn gOrigCFPrefsGetPathForTriplet;

static uintptr_t CRPrefsGetPathForTriplet(uintptr_t a1,
                                          uintptr_t a2,
                                          uintptr_t a3,
                                          uintptr_t a4,
                                          char *pathBuffer)
{
    uintptr_t result = gOrigCFPrefsGetPathForTriplet
        ? gOrigCFPrefsGetPathForTriplet(a1, a2, a3, a4, pathBuffer)
        : 0;

    if (!pathBuffer || (uint32_t)result == 0)
        return result;

    NSString *active =
        NSThread.currentThread.threadDictionary[CranePrefsTripletContainerKey];
    if (!active)
        return result;

    NSString *path = [NSString stringWithUTF8String:pathBuffer];
    NSString *lastComponent = path.lastPathComponent;
    NSString *domain = lastComponent.stringByDeletingPathExtension;
    if (!domain)
        return result;

    NSString *filename =
        [NSString stringWithFormat:@"%@.c_r_a_n_e.%@.plist",
                                   domain,
                                   active];
    NSString *rewritten =
        [path.stringByDeletingLastPathComponent
            stringByAppendingPathComponent:filename];

    NSUInteger length = rewritten.length;
    NSUInteger copied = MIN(length, (NSUInteger)0x400);
    for (NSUInteger index = 0; index < copied; index++)
        pathBuffer[index] = (char)[rewritten characterAtIndex:index];

    /* B4D0 only writes a terminator when the rewritten path fits in < 0x400. */
    if (length < 0x400)
        pathBuffer[length] = '\0';

    return result;
}

/* ------------------------------------------------------------------------- */
/* Hook installation / libundirect compatibility                             */
/* ------------------------------------------------------------------------- */

typedef void (*CRLibUndirectMSHookMessageExFn)(
    Class cls,
    SEL selector,
    IMP replacement,
    IMP *original);

typedef void (*CRLibUndirectDSCRebindFn)(
    CFStringRef imageName,
    Class cls,
    SEL selector,
    const char *types);

static void *gCRLibUndirectHandle;
static CRLibUndirectMSHookMessageExFn gCRLibUndirectHookMessage;
static CRLibUndirectDSCRebindFn gCRLibUndirectDSCRebind;

static void CRPrefsLoadLibUndirect(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *path =
            access("/usr/lib/libundirect.dylib", F_OK) == 0
                ? "/usr/lib/libundirect.dylib"
                : "/var/jb/usr/lib/libundirect.dylib";
        gCRLibUndirectHandle = dlopen(path, RTLD_LAZY);
        if (gCRLibUndirectHandle) {
            gCRLibUndirectHookMessage =
                (CRLibUndirectMSHookMessageExFn)
                    dlsym(gCRLibUndirectHandle,
                          "libundirect_MSHookMessageEx");
            gCRLibUndirectDSCRebind =
                (CRLibUndirectDSCRebindFn)
                    dlsym(gCRLibUndirectHandle,
                          "libundirect_dsc_rebind");
        }
    });
}

static void CRPrefsPrepareDSCMethod(Class cls,
                                    SEL selector,
                                    const char *types)
{
    CRPrefsLoadLibUndirect();
    if (gCRLibUndirectDSCRebind)
        gCRLibUndirectDSCRebind(CFSTR("CoreFoundation"),
                                cls,
                                selector,
                                types);
}

static void CRPrefsHookMessage(Class cls,
                               SEL selector,
                               IMP replacement,
                               IMP *original)
{
    CRPrefsLoadLibUndirect();
    if (gCRLibUndirectHookMessage) {
        gCRLibUndirectHookMessage(cls, selector, replacement, original);
    } else {
        MSHookMessageEx(cls, selector, replacement, original);
    }
}

static void CRPrefsInitHandleSourceMessage(void *modernSymbol)
{
    if (kCFCoreFoundationVersionNumber >= 2000.0 && modernSymbol) {
        MSHookFunction(modernSymbol,
                       (void *)CRPrefsHandleSourceMessageV2,
                       (void **)&gOrigHandleSourceMessageV2);
        return;
    }

    Class daemonClass = NSClassFromString(@"CFPrefsDaemon");
    if (!daemonClass)
        return;

    CRPrefsHookMessage(daemonClass,
                       NSSelectorFromString(@"handleSourceMessage:replyHandler:"),
                       (IMP)CRPrefsHandleSourceMessageObjC,
                       &gOrigHandleSourceMessageObjC);
}

static void CRPrefsInitWithSourceForDomain(void *modernSymbol)
{
    Class daemonClass = NSClassFromString(@"CFPrefsDaemon");
    if (!daemonClass)
        return;

    SEL performSelector =
        NSSelectorFromString(
            @"withSourceForDomain:inContainer:user:byHost:managed:"
             "managedUsesContainer:cloudStoreEntitlement:"
             "cloudConfigurationPath:perform:");

    if ([daemonClass instancesRespondToSelector:performSelector]) {
        CRPrefsHookMessage(daemonClass,
                           performSelector,
                           (IMP)CRPrefsWithSourcePerform,
                           &gOrigWithSourcePerform);
        return;
    }

    if (kCFCoreFoundationVersionNumber >= 2000.0 && modernSymbol) {
        MSHookFunction(modernSymbol,
                       (void *)CRPrefsWithSourceV3,
                       (void **)&gOrigWithSourceV3);
        return;
    }

    SEL lockedSelector =
        NSSelectorFromString(
            @"withSourceForDomain:inContainer:user:byHost:managed:"
             "managedUsesContainer:cloudStoreEntitlement:"
             "cloudConfigurationPath:performWithSourceLock:"
             "afterReleasingSourceLock:");

    CRPrefsHookMessage(daemonClass,
                       lockedSelector,
                       (IMP)CRPrefsWithSourceLocked,
                       &gOrigWithSourceLocked);
}

void CRInitCfprefsd(void)
{
    void *coreFoundation =
        MSGetImageByName(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation");
    if (!coreFoundation)
        return;

    void *handleSourceMessageSymbol = NULL;
    void *withSourceForDomainSymbol = NULL;

    if (kCFCoreFoundationVersionNumber >= 1740.0) {
        if (kCFCoreFoundationVersionNumber >= 2000.0) {
            handleSourceMessageSymbol =
                MSFindSymbol(
                    coreFoundation,
                    "-[CFPrefsDaemon handleSourceMessage:replyHandler:]");
            withSourceForDomainSymbol =
                MSFindSymbol(
                    coreFoundation,
                    "-[CFPrefsDaemon withSourceForDomain:inContainer:user:"
                    "byHost:managed:managedUsesContainer:cloudStoreEntitlement:"
                    "cloudConfigurationPath:performWithSourceLock:"
                    "afterReleasingSourceLock:]");
        } else {
            Class daemonClass = NSClassFromString(@"CFPrefsDaemon");
            if (daemonClass) {
                CRPrefsPrepareDSCMethod(
                    daemonClass,
                    NSSelectorFromString(
                        @"withSourceForDomain:inContainer:user:byHost:managed:"
                         "managedUsesContainer:cloudStoreEntitlement:"
                         "cloudConfigurationPath:performWithSourceLock:"
                         "afterReleasingSourceLock:"),
                    "v@:@@@BBB@@@@");
                CRPrefsPrepareDSCMethod(
                    daemonClass,
                    NSSelectorFromString(
                        @"handleSourceMessage:replyHandler:"),
                    "v@:@@");
            }
        }
    }

    CRPrefsInitHandleSourceMessage(handleSourceMessageSymbol);
    CRPrefsInitWithSourceForDomain(withSourceForDomainSymbol);

    void *triplet =
        MSFindSymbol(coreFoundation, "__CFPrefsGetPathForTriplet");
    if (triplet) {
        MSHookFunction(triplet,
                       (void *)CRPrefsGetPathForTriplet,
                       (void **)&gOrigCFPrefsGetPathForTriplet);
    }
}
