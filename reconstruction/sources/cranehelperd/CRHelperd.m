/*
 * CRHelperd.m — cranehelperd, the privileged half of Crane.
 *
 * SCOPE AND HONESTY NOTE
 * ----------------------
 * The original /usr/local/libexec/cranehelperd has NO IDA export directory.
 * What is CONFIRMED_STATIC here:
 *   * the launchd registration (label, two Mach service names, root user,
 *     KeepAlive, the two safe-mode environment variables) - recovered from
 *     Library/LaunchDaemons/com.opa334.cranehelperd.plist;
 *   * the six Objective-C classes (CRHServiceShared, CRHGlobalService,
 *     CRHGlobalServiceDelegate, CRHPreferencesService,
 *     CRHPreferencesServiceDelegate, CRHKeychain) and the two protocols
 *     (CRHGlobalServiceProtocol, CRHPreferencesServiceProtocol) - recovered by
 *     parsing __objc_classlist directly (analysis/class_and_method_map.md);
 *   * the selector `crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:`
 *     and `crane_setIdentifier:...`, from __TEXT,__objc_methname.
 *
 * What is NOT recovered: the complete XPC interface definition and most daemon
 * implementations. A few caller-side reply shapes (including the 0x19608
 * PID/container status block) are recovered from CraneSB/CraneSupport exports.
 * The transport below is therefore still THIS project's own
 * (see U-01). It is deliberately shaped so the method names match the ones the
 * exported binaries actually call, but the original daemon cannot be expected
 * to satisfy it.
 *
 * This file registers the services and answers the checks that are fully
 * specified; the privileged operations are declared and left unimplemented
 * rather than faked.
 */

#import <Foundation/Foundation.h>
#import <Security/Security.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"
#import "CRXPCDiagnostics.h"

#include <notify.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <xpc/xpc.h>

extern char **environ;

/* Modern iOS SDKs declare xpc_connection_create_mach_service() as unavailable
 * to app targets even though the symbol is present in libxpc and is imported
 * by the recovered Crane binaries. Give the same linker symbol a private local
 * declaration without the SDK availability annotation so the jailbreak daemon
 * can retain the original ABI. */
extern xpc_connection_t CRXPCConnectionCreateMachService(const char *name,
                                                         dispatch_queue_t targetq,
                                                         uint64_t flags)
    __asm("_xpc_connection_create_mach_service");
extern pid_t CRXPCConnectionGetPid(xpc_connection_t connection)
    __asm("_xpc_connection_get_pid");

#pragma mark - Identifiers

/* cranehelperd 0x10000DFA2 / 0x10000DFE0 */
@interface CRHKeychain : NSObject
/* Present as a class in the original (cranehelperd __objc_classlist @0x100012DE0)
 * with its methods supplied by categories. Keychain dump/restore is not
 * implemented here - see analysis/binary_inventory.md section 7 and U-01. */
@end

@implementation CRHKeychain
@end

#pragma mark - Preferences service

/* Protocol definitions live here rather than being forward-declared, so the
 * delegate/service conformances and the NSXPCInterface are well formed. */
@protocol CRHPreferencesServiceProtocol <NSObject>
- (void)getPreferenceValueForKey:(NSString *)key withReply:(void (^)(id value))reply;
- (void)setPreferenceValue:(id)value forKey:(NSString *)key;
@end

@interface CRHPreferencesServiceDelegate : NSObject <CRHPreferencesServiceProtocol>
@end

@implementation CRHPreferencesServiceDelegate
/* Internal, non-protocol helper (the protocol method is the reply variant). */
- (id)storedPreferenceValueForKey:(NSString *)key
{
    if (!key.length)
        return nil;
    return CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)CR_PREFS_DOMAIN));
}

- (void)storePreferenceValue:(id)value forKey:(NSString *)key
{
    if (!key)
        return;
    /* Root.plist and CraneManager use a shared explicit preferences domain;
     * the daemon's standardUserDefaults belongs to a different process. */
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)value,
        (__bridge CFStringRef)CR_PREFS_DOMAIN);
    if (!CFPreferencesAppSynchronize((__bridge CFStringRef)CR_PREFS_DOMAIN))
        NSLog(@"Crane helper: failed to synchronize global preference key=%@", key);
    /* The preference domain is com.opa334.craneprefs; posting the reload
     * notification keeps the settings bundle and the injected daemons in sync,
     * which is what Root.plist's PostNotification does on every switch. */
    notify_post(CR_NOTIFICATION_RELOAD_PREFS.UTF8String);
}
@end

@interface CRHPreferencesService : NSObject <CRHPreferencesServiceProtocol>
@property (nonatomic, strong) id delegate;
@end

@implementation CRHPreferencesService

- (instancetype)init
{
    if ((self = [super init]))
        _delegate = [CRHPreferencesServiceDelegate new];
    return self;
}

- (NSXPCInterface *)interfaceForInterfaceWithProtocol:(Protocol *)protocol
{
    return [NSXPCInterface interfaceWithProtocol:protocol];
}

- (void)getPreferenceValueForKey:(NSString *)key withReply:(void (^)(id))reply
{
    reply([self.delegate storedPreferenceValueForKey:key]);
}

- (void)setPreferenceValue:(id)value forKey:(NSString *)key
{
    [self.delegate storePreferenceValue:value forKey:key];
}

@end

#pragma mark - Global service

@protocol CRHGlobalServiceProtocol <NSObject>
- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL works, NSArray<NSString *> *brokenDaemons, NSError *error))reply;
- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL loaded))reply;
- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                           reply:(void (^)(NSString *containerID, BOOL connectionWorks))reply;
- (void)reloadApplicationWithIdentifier:(NSString *)appID;
- (void)reloadDaemons:(NSArray<NSString *> *)daemons;
- (void)getIdentifierOfType:(uint64_t)type
             forVendorName:(NSString *)vendorName
         andBundleIdentifier:(NSString *)bundleID
                    withReply:(void (^)(NSString *identifier))reply;
- (void)setIdentifier:(NSString *)identifier
                ofType:(uint64_t)type
        forVendorName:(NSString *)vendorName
    andBundleIdentifier:(NSString *)bundleID;
- (void)dumpKeychainItemsForContainerIdentifier:(NSString *)containerID
                      forApplicationIdentifier:(NSString *)appID
                                         reply:(void (^)(NSDictionary *items))reply;
- (void)restoreKeychainItems:(NSDictionary *)items
 toContainerIdentifier:(NSString *)containerID
   forApplicationIdentifier:(NSString *)appID;
@end

@interface CRHGlobalServiceDelegate : NSObject <CRHGlobalServiceProtocol>
@end

@implementation CRHGlobalServiceDelegate

- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL, NSArray<NSString *> *, NSError *))reply
{
    /* This Objective-C delegate has no peer credential context. Never let a
     * future NSXPC wiring accidentally turn static installation checks into an
     * authorization result; the raw-XPC path below owns caller-aware insurance. */
    NSString *filter = CRJailbreakRootPath(CR_MAIN_DYLIB_FILTER_PLIST);
    BOOL mainDylibExists = filter.length &&
        [NSFileManager.defaultManager fileExistsAtPath:filter];
    BOOL libSandyWorks = CRIsDylibLoaded(CR_LIB_SANDY);
    NSMutableArray<NSString *> *broken = [NSMutableArray array];
    if (!mainDylibExists)
        [broken addObject:@"Crane.dylib"];
    if (!libSandyWorks)
        [broken addObject:@"libsandy"];
    [broken addObject:@"CraneSB runtime attestation"];
    NSString *description = [broken componentsJoinedByString:@", "];
    NSError *error = [NSError errorWithDomain:@"com.opa334.crane" code:2 userInfo:
        @{NSLocalizedDescriptionKey: description}];
    if (reply)
        reply(NO, [broken copy], error);
}

- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL))reply
{
    /* [INFERRED] Upstream asks cranehelperd to inspect a live process. This
     * build has no inspector, so it answers conservatively. */
    reply(NO);
}

- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                           reply:(void (^)(NSString *, BOOL))reply
{
    /* The credential-less Objective-C delegate cannot safely inspect the raw
     * runtime registry. Keep it fail-closed; the caller-aware raw-XPC route
     * implements the recovered 0x19608 two-argument reply ABI. */
    NSLog(@"CraneHelperd: credential-less PID %d lookup rejected", pid);
    if (reply)
        reply(nil, NO);
}

- (void)reloadApplicationWithIdentifier:(NSString *)appID
{
    /* BackBoardServices termination would be the real implementation; see
     * U-01. Left unimplemented rather than guessed. */
}

- (void)reloadDaemons:(NSArray<NSString *> *)daemons {}

- (void)getIdentifierOfType:(uint64_t)type
             forVendorName:(NSString *)vendorName
         andBundleIdentifier:(NSString *)bundleID
                    withReply:(void (^)(NSString *))reply
{
    /* F-11/F-19: the recovered CraneSupport 0x65EC identifier is owned by
     * lsd, NOT by cranehelperd's NSUserDefaults. The original lsd transport
     * and caller-authorization contract are not recovered. Never return a
     * fabricated identifier or read an unrelated daemon-local key. */
    (void)type; (void)vendorName; (void)bundleID;
    NSLog(@"CraneHelperd: original lsd identifier read unavailable");
    if (reply)
        reply(nil);
}

- (void)setIdentifier:(NSString *)identifier
                ofType:(uint64_t)type
        forVendorName:(NSString *)vendorName
    andBundleIdentifier:(NSString *)bundleID
{
    /* Until authenticated lsd storage is reconstructed, silently writing
     * daemon-local preferences would claim success while not changing the
     * application's actual vendor identifier. Fail closed, with a log. */
    (void)identifier; (void)type; (void)vendorName; (void)bundleID;
    NSLog(@"CraneHelperd: original lsd identifier write unavailable");
}

- (void)dumpKeychainItemsForContainerIdentifier:(NSString *)containerID
                      forApplicationIdentifier:(NSString *)appID
                                         reply:(void (^)(NSDictionary *))reply
{
    /* An empty dictionary is a VALID successful empty keychain dump. Do
     * not return it if the securityd/keychain backend is missing: callers
     * could mistake a stub result for a backup and overwrite real data. */
    (void)containerID; (void)appID;
    NSLog(@"CraneHelperd: keychain dump unavailable; refusing fake empty backup");
    if (reply)
        reply(nil);
}

- (void)restoreKeychainItems:(NSDictionary *)items
 toContainerIdentifier:(NSString *)containerID
   forApplicationIdentifier:(NSString *)appID
{
    /* The original keychain identity/mapping and restore authorization are
     * unavailable. Never mutate another container's secure items by guess. */
    (void)items; (void)containerID; (void)appID;
    NSLog(@"CraneHelperd: keychain restore unavailable");
}

@end

@interface CRHGlobalService : NSObject <CRHGlobalServiceProtocol>
@property (nonatomic, strong) id delegate;
@end

@implementation CRHGlobalService

- (instancetype)init
{
    if ((self = [super init]))
        _delegate = [CRHGlobalServiceDelegate new];
    return self;
}

- (NSXPCInterface *)interfaceForInterfaceWithProtocol:(Protocol *)protocol
{
    return [NSXPCInterface interfaceWithProtocol:protocol];
}

- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL, NSArray<NSString *> *, NSError *))reply
{
    [self.delegate verifyCraneInsuranceAndReply:reply];
}

- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL))reply
{
    [self.delegate verifySupportLoadedIntoProcessNamed:name reply:reply];
}

- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                           reply:(void (^)(NSString *, BOOL))reply
{
    [self.delegate fetchActiveContainerIDForProcessWithPid:pid reply:reply];
}

- (void)reloadApplicationWithIdentifier:(NSString *)appID
{
    [self.delegate reloadApplicationWithIdentifier:appID];
}

- (void)reloadDaemons:(NSArray<NSString *> *)daemons
{
    [self.delegate reloadDaemons:daemons];
}

- (void)getIdentifierOfType:(uint64_t)type
             forVendorName:(NSString *)vendorName
         andBundleIdentifier:(NSString *)bundleID
                    withReply:(void (^)(NSString *))reply
{
    [self.delegate getIdentifierOfType:type forVendorName:vendorName
                   andBundleIdentifier:bundleID withReply:reply];
}

- (void)setIdentifier:(NSString *)identifier
                ofType:(uint64_t)type
        forVendorName:(NSString *)vendorName
    andBundleIdentifier:(NSString *)bundleID
{
    [self.delegate setIdentifier:identifier ofType:type forVendorName:vendorName
              andBundleIdentifier:bundleID];
}

- (void)dumpKeychainItemsForContainerIdentifier:(NSString *)containerID
                      forApplicationIdentifier:(NSString *)appID
                                         reply:(void (^)(NSDictionary *))reply
{
    [self.delegate dumpKeychainItemsForContainerIdentifier:containerID
                                 forApplicationIdentifier:appID reply:reply];
}

- (void)restoreKeychainItems:(NSDictionary *)items
 toContainerIdentifier:(NSString *)containerID
   forApplicationIdentifier:(NSString *)appID
{
    [self.delegate restoreKeychainItems:items toContainerIdentifier:containerID
                   forApplicationIdentifier:appID];
}

@end

#pragma mark - Service host

@interface CRHServiceShared : NSObject
@property (class, nonatomic, readonly) CRHServiceShared *sharedService;
- (void)setService:(id)service forInterface:(NSString *)interface;
- (id)serviceForInterface:(NSString *)interface;
@end

@implementation CRHServiceShared

+ (CRHServiceShared *)sharedService
{
    static CRHServiceShared *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [CRHServiceShared new]; });
    return shared;
}

- (NSMutableDictionary *)services
{
    static NSMutableDictionary *services;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ services = [NSMutableDictionary new]; });
    return services;
}

- (void)setService:(id)service forInterface:(NSString *)interface
{
    self.services[interface] = service;
}

- (id)serviceForInterface:(NSString *)interface
{
    return self.services[interface];
}

@end

/* Runtime attestations are reconstruction-only. The daemon never trusts a
 * caller-supplied PID or executable name: both come from the XPC peer. */
static NSMutableDictionary<NSNumber *, NSMutableDictionary *> *CRRuntimeRegistry(void)
{
    static NSMutableDictionary *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMutableDictionary new]; });
    return registry;
}

typedef int (*CRProcNameFn)(int, void *, uint32_t);
typedef int (*CRProcListPidsFn)(uint32_t, uint32_t, void *, int);
typedef int (*CRProcPidInfoFn)(int, int, uint64_t, void *, int);
typedef int (*CRProcRegionFilenameFn)(int, uint64_t, void *, uint32_t);

/* Public XNU proc_regioninfo layout. Keep this private copy so the helper
 * does not depend on private SDK headers just to perform a read-only
 * diagnostic. PROC_PIDREGIONINFO == 7. */
struct CRProcRegionInfo {
    uint32_t pri_protection;
    uint32_t pri_max_protection;
    uint32_t pri_inheritance;
    uint32_t pri_flags;
    uint64_t pri_offset;
    uint32_t pri_behavior;
    uint32_t pri_user_wired_count;
    uint32_t pri_user_tag;
    uint32_t pri_pages_resident;
    uint32_t pri_pages_shared_now_private;
    uint32_t pri_pages_swapped_out;
    uint32_t pri_pages_dirtied;
    uint32_t pri_ref_count;
    uint32_t pri_shadow_depth;
    uint32_t pri_share_mode;
    uint32_t pri_private_pages_resident;
    uint32_t pri_shared_pages_resident;
    uint32_t pri_obj_id;
    uint32_t pri_depth;
    uint64_t pri_address;
    uint64_t pri_size;
};
_Static_assert(sizeof(struct CRProcRegionInfo) == 96,
               "Unexpected proc_regioninfo ABI");

static CRProcNameFn CRHelperProcNameFunction(void)
{
    static CRProcNameFn procName;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
        procName = (CRProcNameFn)dlsym(handle ?: RTLD_DEFAULT, "proc_name");
    });
    return procName;
}

static NSString *CRProcessNameForPid(pid_t pid)
{
    CRProcNameFn procName = CRHelperProcNameFunction();
    if (pid <= 0 || !procName)
        return nil;
    char buffer[1024] = {0};
    if (procName(pid, buffer, sizeof(buffer)) <= 0)
        return nil;
    return [NSString stringWithUTF8String:buffer];
}

static NSArray<NSString *> *CRCraneSupportProcessNames(void)
{
    static NSArray<NSString *> *processes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        processes = @[@"cfprefsd", @"containermanagerd", @"securityd",
                      @"pkd", @"lsd", @"accountsd", @"apsd"];
    });
    return processes;
}

static NSArray<NSString *> *CRCrucialCraneSupportProcessNames(void)
{
    /* Recovered original _crucialCraneSupportDaemons at 0x10000A1B0. */
    static NSArray<NSString *> *processes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        processes = @[@"cfprefsd", @"containermanagerd", @"securityd"];
    });
    return processes;
}

static CRProcListPidsFn CRHelperProcListPidsFunction(void)
{
    static CRProcListPidsFn procListPids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
        procListPids = (CRProcListPidsFn)dlsym(
            handle ?: RTLD_DEFAULT, "proc_listpids");
    });
    return procListPids;
}

static NSArray<NSString *> *CRRunningCraneSupportProcesses(void)
{
    /* Original 0x1B45C receives broken daemons from cranehelperd, while the
     * helper implementation itself is U-01. For reconstruction insurance,
     * inspect only currently-running filter targets so an absent on-demand
     * daemon does not become a false injection failure. This is read-only. */
    CRProcListPidsFn procListPids = CRHelperProcListPidsFunction();
    if (!procListPids || !CRHelperProcNameFunction())
        return nil;

    /* PROC_ALL_PIDS == 1. Leave spare capacity for processes created between
     * the sizing and fill calls. */
    int required = procListPids(1, 0, NULL, 0);
    if (required <= 0)
        return nil;
    int capacity = required + (int)(256 * sizeof(pid_t));
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids)
        return nil;
    int bytes = procListPids(1, 0, pids, capacity);
    if (bytes <= 0) {
        free(pids);
        return nil;
    }

    NSMutableSet<NSString *> *running = [NSMutableSet new];
    NSUInteger count = (NSUInteger)bytes / sizeof(pid_t);
    for (NSUInteger i = 0; i < count; ++i) {
        NSString *name = CRProcessNameForPid(pids[i]);
        if (name.length && [CRCraneSupportProcessNames() containsObject:name])
            [running addObject:name];
    }
    free(pids);

    NSMutableArray<NSString *> *ordered = [NSMutableArray new];
    for (NSString *name in CRCraneSupportProcessNames()) {
        if ([running containsObject:name])
            [ordered addObject:name];
    }
    return ordered;
}

static CRProcPidInfoFn CRHelperProcPidInfoFunction(void)
{
    static CRProcPidInfoFn procPidInfo;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
        procPidInfo = (CRProcPidInfoFn)dlsym(
            handle ?: RTLD_DEFAULT, "proc_pidinfo");
    });
    return procPidInfo;
}

static CRProcRegionFilenameFn CRHelperProcRegionFilenameFunction(void)
{
    static CRProcRegionFilenameFn procRegionFilename;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
        procRegionFilename = (CRProcRegionFilenameFn)dlsym(
            handle ?: RTLD_DEFAULT, "proc_regionfilename");
    });
    return procRegionFilename;
}

static NSDictionary<NSString *, NSNumber *> *
CRProcessPidsForNames(NSArray<NSString *> *names)
{
    CRProcListPidsFn procListPids = CRHelperProcListPidsFunction();
    if (!procListPids || !CRHelperProcNameFunction() || names.count == 0)
        return nil;

    int required = procListPids(1, 0, NULL, 0);
    if (required <= 0)
        return nil;
    int capacity = required + (int)(256 * sizeof(pid_t));
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids)
        return nil;
    int bytes = procListPids(1, 0, pids, capacity);
    if (bytes <= 0) {
        free(pids);
        return nil;
    }

    NSMutableDictionary<NSString *, NSNumber *> *result = [NSMutableDictionary new];
    NSUInteger count = (NSUInteger)bytes / sizeof(pid_t);
    for (NSUInteger i = 0; i < count; ++i) {
        NSString *name = CRProcessNameForPid(pids[i]);
        if (name.length && [names containsObject:name] && !result[name])
            result[name] = @(pids[i]);
    }
    free(pids);
    return [result copy];
}

static NSString *const CRSupportFilterVirtualPath =
    @"/Library/MobileSubstrate/DynamicLibraries/CraneSupport.plist";
static NSString *const CRSupportDylibVirtualPath =
    @"/Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib";
static NSString *const CRInjectionErrorDomain = @"cranehelperdErrorDomain";

static BOOL gLastInjectionFixupAttempted = NO;
static BOOL gLastInjectionFixupInProgress = NO;
static BOOL gLastInjectionFixupSuccess = NO;
static NSError *gLastInjectionFixupError = nil;
static NSString *gLastInjectionFixupProcess = nil;
static NSString *gLastInjectionFixupBackend = nil;
static NSMutableArray<NSString *> *gLastInjectionFixupTransitions = nil;
static NSTimeInterval gLastInjectionFixupTime = 0;

static void CRBeginInjectionFixupAttempt(void)
{
    @synchronized(CRInjectionErrorDomain) {
        gLastInjectionFixupAttempted = YES;
        gLastInjectionFixupInProgress = YES;
        gLastInjectionFixupSuccess = NO;
        gLastInjectionFixupError = nil;
        gLastInjectionFixupProcess = nil;
        gLastInjectionFixupBackend = nil;
        gLastInjectionFixupTransitions = [NSMutableArray new];
        gLastInjectionFixupTime = [NSDate timeIntervalSinceReferenceDate];
    }
}

static void CRSetInjectionFixupContext(NSString *process, NSString *backend)
{
    @synchronized(CRInjectionErrorDomain) {
        gLastInjectionFixupProcess = [process copy];
        gLastInjectionFixupBackend = [backend copy];
    }
}

static void CRRecordInjectionFixupTransition(NSString *process,
                                               pid_t oldPid,
                                               NSString *actualProcess)
{
    @synchronized(CRInjectionErrorDomain) {
        if (!gLastInjectionFixupTransitions)
            gLastInjectionFixupTransitions = [NSMutableArray new];
        [gLastInjectionFixupTransitions addObject:
            [NSString stringWithFormat:@"%@[%d->%@]",
                process ?: @"<unknown>", oldPid,
                actualProcess.length ? actualProcess : @"gone"]];
    }
}

static void CRFinishInjectionFixupAttempt(BOOL success, NSError *error)
{
    @synchronized(CRInjectionErrorDomain) {
        gLastInjectionFixupInProgress = NO;
        gLastInjectionFixupSuccess = success;
        gLastInjectionFixupError = error;
        gLastInjectionFixupTime = [NSDate timeIntervalSinceReferenceDate];
    }
}

static NSDictionary *CRLastInjectionFixupSnapshot(void)
{
    @synchronized(CRInjectionErrorDomain) {
        NSMutableDictionary *snapshot = [@{
            @"attempted": @(gLastInjectionFixupAttempted),
            @"inProgress": @(gLastInjectionFixupInProgress),
            @"success": @(gLastInjectionFixupSuccess),
            @"time": @(gLastInjectionFixupTime),
        } mutableCopy];
        if (gLastInjectionFixupProcess.length)
            snapshot[@"process"] = gLastInjectionFixupProcess;
        if (gLastInjectionFixupBackend.length)
            snapshot[@"backend"] = gLastInjectionFixupBackend;
        if (gLastInjectionFixupError)
            snapshot[@"error"] = gLastInjectionFixupError;
        if (gLastInjectionFixupTransitions.count)
            snapshot[@"transitions"] =
                [gLastInjectionFixupTransitions componentsJoinedByString:@","];
        return [snapshot copy];
    }
}

typedef NS_ENUM(NSInteger, CRInjectionErrorCode) {
    CRInjectionDylibFileNotFound = 1001,
    CRInjectionBinaryNotFound = 1002,
    CRInjectionExceptionOccurred = 1003,
    CRInjectionInvalidFilter = 1101,
    CRInjectionInspectionUnavailable = 1102,
    CRInjectionSpawnFailed = 1103,
    CRInjectionTimedOut = 1104,
    CRInjectionToolFailed = 1105,
    CRInjectionVerificationFailed = 1106,
    CRInjectionTargetChanged = 1107,
};

static NSError *CRInjectionError(CRInjectionErrorCode code,
                                 NSString *description)
{
    return [NSError errorWithDomain:CRInjectionErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey:
                               description ?: @"CraneSupport injection failed"}];
}

static NSArray<NSString *> *CRSupportFixupTargets(NSError **error)
{
    if (error)
        *error = nil;

    NSString *filterPath = CRJailbreakRootPath(CRSupportFilterVirtualPath);
    NSDictionary *root = filterPath.length
        ? [NSDictionary dictionaryWithContentsOfFile:filterPath] : nil;
    NSDictionary *filter = [root[@"Filter"] isKindOfClass:NSDictionary.class]
        ? root[@"Filter"] : nil;
    NSArray *executables = [filter[@"Executables"] isKindOfClass:NSArray.class]
        ? filter[@"Executables"] : nil;

    if (executables.count == 0) {
        if (error) {
            *error = CRInjectionError(CRInjectionInvalidFilter,
                [NSString stringWithFormat:
                    @"CraneSupport filter has no executable list at %@", filterPath]);
        }
        return nil;
    }

    NSSet<NSString *> *allowed =
        [NSSet setWithArray:CRCraneSupportProcessNames()];
    NSMutableArray<NSString *> *validated = [NSMutableArray new];
    for (id item in executables) {
        if (![item isKindOfClass:NSString.class] ||
            ![allowed containsObject:(NSString *)item]) {
            if (error) {
                *error = CRInjectionError(CRInjectionInvalidFilter,
                    [NSString stringWithFormat:
                        @"CraneSupport filter contains unexpected executable %@", item]);
            }
            return nil;
        }
        if (![validated containsObject:item])
            [validated addObject:item];
    }
    return [validated copy];
}

static BOOL CRPidMapsImageLeaf(pid_t pid, NSString *leaf,
                               BOOL *inspectionAvailable)
{
    if (inspectionAvailable)
        *inspectionAvailable = NO;
    if (pid <= 0 || leaf.length == 0)
        return NO;

    CRProcPidInfoFn procPidInfo = CRHelperProcPidInfoFunction();
    CRProcRegionFilenameFn procRegionFilename =
        CRHelperProcRegionFilenameFunction();
    if (!procPidInfo || !procRegionFilename)
        return NO;

    BOOL sawRegion = NO;
    BOOL sawPath = NO;
    uint64_t address = 0;
    for (NSUInteger region = 0; region < 16384; ++region) {
        struct CRProcRegionInfo info = {0};
        int bytes = procPidInfo(pid, 7, address, &info, (int)sizeof(info));
        if (bytes < (int)sizeof(info) || info.pri_size == 0)
            break;
        sawRegion = YES;

        char path[PATH_MAX] = {0};
        int length = procRegionFilename(
            pid, info.pri_address, path, (uint32_t)sizeof(path));
        if (length > 0) {
            sawPath = YES;
            const char *name = strrchr(path, '/');
            name = name ? name + 1 : path;
            if (strcmp(name, leaf.UTF8String) == 0) {
                if (inspectionAvailable)
                    *inspectionAvailable = YES;
                return YES;
            }
        }

        if (UINT64_MAX - info.pri_address < info.pri_size)
            break;
        uint64_t next = info.pri_address + info.pri_size;
        if (next <= address)
            break;
        address = next;
    }

    if (inspectionAvailable)
        *inspectionAvailable = sawRegion && sawPath;
    return NO;
}

static NSString *CRFindSupportInjectionBinary(void)
{
#if CRANE_ROOTHIDE
    NSArray<NSString *> *candidates = @[
        @"/basebin/opainject",
        @"/usr/bin/opainject",
        @"/usr/local/bin/opainject",
        @"/usr/libexec/libhooker/libsyringe",
        @"/usr/bin/cynject",
        @"/usr/bin/cynject.old",
    ];
#else
    NSArray<NSString *> *candidates = @[
        @"/usr/libexec/libhooker/libsyringe",
        @"/usr/bin/cynject",
        @"/usr/bin/cynject.old",
        @"/basebin/opainject",
        @"/usr/bin/opainject",
        @"/usr/local/bin/opainject",
    ];
#endif

    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *virtualPath in candidates) {
        NSString *path = CRJailbreakRootPath(virtualPath);
        BOOL directory = NO;
        if (path.length &&
            [fm fileExistsAtPath:path isDirectory:&directory] &&
            !directory && [fm isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSString *CRSupportInjectionBackendInventory(void)
{
#if CRANE_ROOTHIDE
    NSArray<NSString *> *candidates = @[
        @"/basebin/opainject",
        @"/usr/bin/opainject",
        @"/usr/local/bin/opainject",
        @"/usr/libexec/libhooker/libsyringe",
        @"/usr/bin/cynject",
        @"/usr/bin/cynject.old",
    ];
#else
    NSArray<NSString *> *candidates = @[
        @"/usr/libexec/libhooker/libsyringe",
        @"/usr/bin/cynject",
        @"/usr/bin/cynject.old",
        @"/basebin/opainject",
        @"/usr/bin/opainject",
        @"/usr/local/bin/opainject",
    ];
#endif

    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *virtualPath in candidates) {
        NSString *path = CRJailbreakRootPath(virtualPath);
        BOOL directory = NO;
        BOOL exists = path.length &&
            [fm fileExistsAtPath:path isDirectory:&directory] &&
            !directory;
        BOOL executable = exists && [fm isExecutableFileAtPath:path];
        [parts addObject:[NSString stringWithFormat:@"%@=%d/%d",
            virtualPath, exists, executable]];
    }
    return [parts componentsJoinedByString:@","];
}

static BOOL CRRunInjectionTool(NSString *toolPath, pid_t targetPid,
                               NSString *dylibPath, NSError **error)
{
    if (error)
        *error = nil;

    const char *tool = toolPath.fileSystemRepresentation;
    const char *dylib = dylibPath.fileSystemRepresentation;
    if (!tool || !dylib || targetPid <= 0) {
        if (error)
            *error = CRInjectionError(CRInjectionSpawnFailed,
                                      @"Injector arguments are invalid");
        return NO;
    }

    char pidBuffer[32] = {0};
    snprintf(pidBuffer, sizeof(pidBuffer), "%d", targetPid);
    char *argv[] = {(char *)tool, pidBuffer, (char *)dylib, NULL};

    pid_t injectorPid = 0;
    int spawnResult = posix_spawn(&injectorPid, tool, NULL, NULL, argv, environ);
    if (spawnResult != 0 || injectorPid <= 0) {
        if (error) {
            *error = CRInjectionError(CRInjectionSpawnFailed,
                [NSString stringWithFormat:
                    @"Unable to start %@ for pid %d: %s",
                    toolPath.lastPathComponent, targetPid,
                    strerror(spawnResult ?: errno)]);
        }
        return NO;
    }

    int status = 0;
    BOOL reaped = NO;
    NSTimeInterval deadline =
        [NSDate timeIntervalSinceReferenceDate] + 8.0;
    while ([NSDate timeIntervalSinceReferenceDate] < deadline) {
        pid_t waited = waitpid(injectorPid, &status, WNOHANG);
        if (waited == injectorPid) {
            reaped = YES;
            break;
        }
        if (waited < 0 && errno != EINTR) {
            if (error) {
                *error = CRInjectionError(CRInjectionToolFailed,
                    [NSString stringWithFormat:
                        @"waitpid failed for injector %@: %s",
                        toolPath.lastPathComponent, strerror(errno)]);
            }
            return NO;
        }
        usleep(100000);
    }

    if (!reaped) {
        kill(injectorPid, SIGTERM);
        for (NSUInteger attempt = 0; attempt < 10; ++attempt) {
            pid_t waited = waitpid(injectorPid, &status, WNOHANG);
            if (waited == injectorPid) {
                reaped = YES;
                break;
            }
            usleep(50000);
        }
        if (!reaped) {
            kill(injectorPid, SIGKILL);
            while (waitpid(injectorPid, &status, 0) < 0 && errno == EINTR) {}
        }
        if (error) {
            *error = CRInjectionError(CRInjectionTimedOut,
                [NSString stringWithFormat:
                    @"Injector %@ timed out for pid %d",
                    toolPath.lastPathComponent, targetPid]);
        }
        return NO;
    }

    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) {
        NSString *reason = WIFEXITED(status)
            ? [NSString stringWithFormat:@"exit=%d", WEXITSTATUS(status)]
            : (WIFSIGNALED(status)
                ? [NSString stringWithFormat:@"signal=%d", WTERMSIG(status)]
                : @"abnormal termination");
        if (error) {
            *error = CRInjectionError(CRInjectionToolFailed,
                [NSString stringWithFormat:
                    @"Injector %@ failed for pid %d (%@)",
                    toolPath.lastPathComponent, targetPid, reason]);
        }
        return NO;
    }
    return YES;
}

static BOOL CRFixupCraneSupportInPid(pid_t pid, NSString *process,
                                     NSError **error)
{
    if (error)
        *error = nil;

    NSString *actualProcess = CRProcessNameForPid(pid);
    if (pid <= 0 || ![actualProcess isEqualToString:process]) {
        /* Original _fixupInjectionIfNeededForDaemon:error: resolves the PID
         * immediately before injection and returns NO without NSError when the
         * daemon is not running. runInjectionFixUpIfNeededAndReply: only stops
         * on NSError. Match that behavior: a target transition is deferred to
         * later verification, not treated as a fatal injector failure. */
        CRRecordInjectionFixupTransition(process, pid, actualProcess);
        NSLog(@"Crane helper: injection fixup process=%@ pid=%d deferred=target_changed_before actual=%@",
              process, pid, actualProcess);
        return YES;
    }

    NSString *dylibPath = CRJailbreakRootPath(CRSupportDylibVirtualPath);
    BOOL isDirectory = NO;
    if (!dylibPath.length ||
        ![NSFileManager.defaultManager fileExistsAtPath:dylibPath
                                            isDirectory:&isDirectory] ||
        isDirectory) {
        if (error) {
            *error = CRInjectionError(CRInjectionDylibFileNotFound,
                [NSString stringWithFormat:
                    @"CRANEHELPERD_INJECTION_ERROR_DYLIB_FILE_NOT_FOUND: %@",
                    dylibPath ?: CRSupportDylibVirtualPath]);
        }
        return NO;
    }

    BOOL inspectionAvailable = NO;
    if (CRPidMapsImageLeaf(pid, @"CraneSupport.dylib",
                           &inspectionAvailable)) {
        NSLog(@"Crane helper: injection fixup process=%@ pid=%d alreadyLoaded=1",
              process, pid);
        return YES;
    }
    if (!inspectionAvailable) {
        if (error) {
            *error = CRInjectionError(CRInjectionInspectionUnavailable,
                [NSString stringWithFormat:
                    @"Cannot inspect mapped images for %@ pid=%d; refusing blind injection",
                    process, pid]);
        }
        return NO;
    }

    NSString *toolPath = CRFindSupportInjectionBinary();
    if (!toolPath.length) {
        if (error) {
            *error = CRInjectionError(CRInjectionBinaryNotFound,
                @"CRANEHELPERD_INJECTION_ERROR_INJECTION_BINARY_NOT_FOUND");
        }
        return NO;
    }

    CRSetInjectionFixupContext(process, toolPath.lastPathComponent);
    NSLog(@"Crane helper: injection fixup process=%@ pid=%d tool=%@ dylib=%@",
          process, pid, toolPath.lastPathComponent, dylibPath);
    @try {
        NSError *toolError = nil;
        if (!CRRunInjectionTool(toolPath, pid, dylibPath, &toolError)) {
            if (error)
                *error = toolError;
            return NO;
        }
    } @catch (NSException *exception) {
        if (error) {
            *error = CRInjectionError(CRInjectionExceptionOccurred,
                [NSString stringWithFormat:
                    @"CRANEHELPERD_INJECTION_ERROR_EXCEPTION_OCCURED: %@",
                    exception.reason ?: exception.name]);
        }
        return NO;
    }

    /* Recovered original _injectDylib:intoProcessWithPid:error: returns
     * success when the injector exits 0. It does not synchronously poll the
     * image map here; later insurance/verify paths decide real health. Keep
     * one immediate mapper sample as diagnostic only so the pass stays fast. */
    NSString *currentProcess = CRProcessNameForPid(pid);
    if (![currentProcess isEqualToString:process]) {
        CRRecordInjectionFixupTransition(process, pid, currentProcess);
        NSLog(@"Crane helper: injection fixup process=%@ pid=%d injectorExit=0 deferred=target_transition actual=%@",
              process, pid, currentProcess);
        return YES;
    }

    BOOL canInspect = NO;
    BOOL mapped = CRPidMapsImageLeaf(pid, @"CraneSupport.dylib", &canInspect);
    NSLog(@"Crane helper: injection fixup process=%@ pid=%d injectorExit=0 immediateMapped=%d inspect=%d",
          process, pid, mapped, canInspect);
    return YES;
}

static BOOL CRRunCraneSupportInjectionFixup(NSError **error)
{
    if (error)
        *error = nil;

    NSError *targetError = nil;
    NSArray<NSString *> *targets = CRSupportFixupTargets(&targetError);
    if (!targets) {
        if (error)
            *error = targetError;
        return NO;
    }

    for (NSString *process in targets) {
        /* Match original _fixupInjectionIfNeededForDaemon:error:: resolve each
         * daemon immediately before its injection instead of carrying one PID
         * snapshot across the entire multi-daemon pass. */
        NSDictionary<NSString *, NSNumber *> *pidMap =
            CRProcessPidsForNames(@[process]);
        if (!pidMap) {
            if (error) {
                *error = CRInjectionError(CRInjectionInspectionUnavailable,
                    [NSString stringWithFormat:
                        @"Unable to enumerate CraneSupport target %@", process]);
            }
            return NO;
        }
        pid_t pid = (pid_t)[pidMap[process] intValue];
        if (pid <= 0) {
            NSLog(@"Crane helper: injection fixup process=%@ skipped=not_running",
                  process);
            continue;
        }

        NSError *fixError = nil;
        if (!CRFixupCraneSupportInPid(pid, process, &fixError)) {
            if (error)
                *error = fixError;
            return NO;
        }
    }
    return YES;
}

static NSString *CRSupportMappedImageSummary(NSArray<NSString *> *processes)
{
    /* Diagnostic only. Never use this mapper as insurance proof: proc region
     * visibility may be restricted independently of tweak injection. Positive
     * image hits are direct evidence; inspection failure remains inconclusive. */
    CRProcPidInfoFn procPidInfo = CRHelperProcPidInfoFunction();
    CRProcRegionFilenameFn procRegionFilename =
        CRHelperProcRegionFilenameFunction();
    NSDictionary<NSString *, NSNumber *> *pidMap =
        CRProcessPidsForNames(processes);
    if (!procPidInfo || !procRegionFilename || !pidMap)
        return @"inspection=unavailable";

    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *process in processes) {
        pid_t pid = (pid_t)[pidMap[process] intValue];
        BOOL sawRegion = NO;
        BOOL sawPath = NO;
        BOOL support = NO;
        BOOL flags = NO;
        BOOL plain = NO;
        BOOL bare = NO;
        BOOL systemhook = NO;
        BOOL tweakLoader = NO;
        BOOL injector = NO;
        BOOL ellekit = NO;
        BOOL substrate = NO;
        NSMutableSet<NSString *> *otherTweaks = [NSMutableSet new];
        NSMutableSet<NSString *> *jailbreakImages = [NSMutableSet new];
        uint64_t address = 0;

        if (pid > 0) {
            for (NSUInteger region = 0; region < 16384; ++region) {
                struct CRProcRegionInfo info = {0};
                int bytes = procPidInfo(pid, 7 /* PROC_PIDREGIONINFO */,
                                        address, &info, (int)sizeof(info));
                if (bytes < (int)sizeof(info) || info.pri_size == 0)
                    break;
                sawRegion = YES;

                char path[PATH_MAX] = {0};
                int length = procRegionFilename(
                    pid, info.pri_address, path, (uint32_t)sizeof(path));
                if (length > 0) {
                    sawPath = YES;
                    const char *leaf = strrchr(path, '/');
                    leaf = leaf ? leaf + 1 : path;
                    if (strcmp(leaf, "CraneSupport.dylib") == 0)
                        support = YES;
                    else if (strcmp(leaf, "CraneSupportProbeFlags.dylib") == 0)
                        flags = YES;
                    else if (strcmp(leaf, "CraneSupportProbePlain.dylib") == 0)
                        plain = YES;
                    else if (strcmp(leaf, "CraneSupportProbeBare.dylib") == 0)
                        bare = YES;

                    if (strcmp(leaf, "systemhook.dylib") == 0)
                        systemhook = YES;
                    if (strcmp(leaf, "TweakLoader.dylib") == 0 ||
                        strcmp(leaf, "TweakInject.dylib") == 0)
                        tweakLoader = YES;
                    if (strcmp(leaf, "libinjector.dylib") == 0)
                        injector = YES;
                    if (strcmp(leaf, "libellekit.dylib") == 0)
                        ellekit = YES;
                    if (strcmp(leaf, "libsubstrate.dylib") == 0 ||
                        strcmp(leaf, "CydiaSubstrate") == 0)
                        substrate = YES;

                    NSString *imagePath = [NSString stringWithUTF8String:path];
                    BOOL tweakDirectory =
                        [imagePath containsString:@"/TweakInject/"] ||
                        [imagePath containsString:
                            @"/MobileSubstrate/DynamicLibraries/"];
                    NSString *leafName = [NSString stringWithUTF8String:leaf];
                    if (tweakDirectory &&
                        strcmp(leaf, "CraneSupport.dylib") != 0 &&
                        strcmp(leaf, "CraneSupportProbeFlags.dylib") != 0 &&
                        strcmp(leaf, "CraneSupportProbePlain.dylib") != 0 &&
                        strcmp(leaf, "CraneSupportProbeBare.dylib") != 0 &&
                        leafName.length) {
                        [otherTweaks addObject:leafName];
                    }

                    /* RootHide randomizes the jailbreak root and may also
                     * randomize systemhook's filename. Track file-backed
                     * images originating from the jailbreak tree without
                     * assuming the systemhook leaf name. */
                    BOOL jailbreakPath =
                        [imagePath containsString:@"/.jbroot-"] ||
                        [imagePath containsString:@"/var/jb/"] ||
                        [imagePath containsString:@"/basebin/"];
                    if (jailbreakPath && leafName.length)
                        [jailbreakImages addObject:leafName];
                }
                if (UINT64_MAX - info.pri_address < info.pri_size)
                    break;
                uint64_t next = info.pri_address + info.pri_size;
                if (next <= address)
                    break;
                address = next;
            }
        }

        BOOL inspect = sawRegion && sawPath;
        NSArray<NSString *> *sortedTweaks =
            [[otherTweaks allObjects] sortedArrayUsingSelector:
                @selector(compare:)];
        NSString *sample = sortedTweaks.count
            ? [[sortedTweaks subarrayWithRange:
                NSMakeRange(0, MIN((NSUInteger)3, sortedTweaks.count))]
                componentsJoinedByString:@"+"] : @"-";
        NSArray<NSString *> *sortedJB =
            [[jailbreakImages allObjects] sortedArrayUsingSelector:
                @selector(compare:)];
        NSString *jbSample = sortedJB.count
            ? [[sortedJB subarrayWithRange:
                NSMakeRange(0, MIN((NSUInteger)4, sortedJB.count))]
                componentsJoinedByString:@"+"] : @"-";
        [parts addObject:[NSString stringWithFormat:
            @"%@[pid=%d inspect=%d systemhook=%d loader=%d injector=%d ellekit=%d substrate=%d jb=%lu jbSample=%@ other=%lu sample=%@ support=%d flags=%d plain=%d bare=%d]",
            process, pid, inspect, systemhook, tweakLoader, injector, ellekit,
            substrate, (unsigned long)jailbreakImages.count, jbSample,
            (unsigned long)otherTweaks.count, sample,
            support, flags, plain, bare]];
    }
    return [parts componentsJoinedByString:@"; "];
}

typedef struct {
    uint32_t val[8];
} CRHelperAuditToken;

typedef void (*CRHelperXPCGetAuditTokenFn)(xpc_connection_t connection,
                                           CRHelperAuditToken *token);
typedef CFTypeRef (*CRHelperSecTaskCreateWithAuditTokenFn)(CFAllocatorRef allocator,
                                                           CRHelperAuditToken token);
typedef CFStringRef (*CRHelperSecTaskCopySigningIdentifierFn)(CFTypeRef task,
                                                              CFErrorRef *error);

static NSString *CRSigningIdentifierForPeer(xpc_connection_t peer)
{
    static CRHelperXPCGetAuditTokenFn getAuditToken;
    static CRHelperSecTaskCreateWithAuditTokenFn createTask;
    static CRHelperSecTaskCopySigningIdentifierFn copySigningIdentifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getAuditToken = (CRHelperXPCGetAuditTokenFn)
            dlsym(RTLD_DEFAULT, "xpc_connection_get_audit_token");
        createTask = (CRHelperSecTaskCreateWithAuditTokenFn)
            dlsym(RTLD_DEFAULT, "SecTaskCreateWithAuditToken");
        copySigningIdentifier = (CRHelperSecTaskCopySigningIdentifierFn)
            dlsym(RTLD_DEFAULT, "SecTaskCopySigningIdentifier");
    });
    if (!peer || !getAuditToken || !createTask || !copySigningIdentifier)
        return nil;

    CRHelperAuditToken token = {0};
    getAuditToken(peer, &token);
    CFTypeRef task = createTask(kCFAllocatorDefault, token);
    if (!task)
        return nil;
    CFStringRef identifier = copySigningIdentifier(task, NULL);
    CFRelease(task);
    if (!identifier)
        return nil;
    NSString *result = [(__bridge NSString *)identifier copy];
    CFRelease(identifier);
    return result;
}

static BOOL CRIsCraneSBProcess(NSString *process)
{
    return [process isEqualToString:@"SpringBoard"] ||
           [process isEqualToString:@"runningboardd"];
}

static BOOL CRIsAuthenticatedCraneSBPeer(NSString *process, NSString *signingID)
{
    if ([process isEqualToString:@"SpringBoard"])
        return [signingID isEqualToString:@"com.apple.springboard"];
    if ([process isEqualToString:@"runningboardd"]) {
        /* No runningboardd signing-ID literal survives in the recovered Crane
         * artifacts. Accept the two Apple identifiers used across supported
         * iOS generations, but still require the kernel-derived process name. */
        return [signingID isEqualToString:@"com.apple.runningboardd"] ||
               [signingID isEqualToString:@"com.apple.runningboard"];
    }
    return NO;
}

static BOOL CRIsCraneSupportProcess(NSString *process)
{
    return [CRCraneSupportProcessNames() containsObject:process];
}

static BOOL CRIsAuthenticatedCraneSupportPeer(NSString *process, NSString *signingID)
{
    static NSDictionary<NSString *, NSString *> *signingIDs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        /* Six identifiers are recovered verbatim from CRMCM 0x68C0. The
         * containermanagerd identifier is inferred from its system service
         * identity; a mismatch fails closed on-device. */
        signingIDs = @{
            @"cfprefsd": @"com.apple.cfprefsd",
            @"containermanagerd": @"com.apple.containermanagerd",
            @"securityd": @"com.apple.securityd",
            @"pkd": @"com.apple.pluginkit.pkd",
            @"lsd": @"com.apple.lsd",
            @"accountsd": @"com.apple.accountsd",
            @"apsd": @"com.apple.apsd",
        };
    });
    NSString *expected = signingIDs[process];
    return expected.length && [signingID isEqualToString:expected];
}

static BOOL CRRuntimeComponentAllowed(NSString *component, NSString *process,
                                      NSString *signingID)
{
    if ([component isEqualToString:@"CraneSB"])
        return CRIsAuthenticatedCraneSBPeer(process, signingID);
    if ([component isEqualToString:@"CraneSupport"])
        return CRIsAuthenticatedCraneSupportPeer(process, signingID);
    if ([component isEqualToString:@"Crane"])
        return process.length && ![process isEqualToString:@"cranehelperd"];
    return NO;
}

static void CRRegisterRuntime(pid_t pid, NSString *process,
                              NSString *component, NSString *containerID,
                              NSString *peerToken)
{
    if (pid <= 0 || !process.length || !component.length)
        return;
    NSMutableDictionary *registry = CRRuntimeRegistry();
    @synchronized(registry) {
        NSMutableDictionary *entry = registry[@(pid)];
        if (!entry || ![entry[@"process"] isEqualToString:process]) {
            entry = [@{@"process": process,
                       @"components": [NSMutableDictionary new]} mutableCopy];
            registry[@(pid)] = entry;
        }
        NSMutableDictionary *components = entry[@"components"];
        NSMutableDictionary *claim = [@{@"peerToken": peerToken} mutableCopy];
        if ([component isEqualToString:@"Crane"] && containerID.length)
            claim[@"container"] = containerID;
        components[component] = claim;
    }
}

static void CRUnregisterRuntime(pid_t pid, NSString *peerToken)
{
    NSMutableDictionary *registry = CRRuntimeRegistry();
    @synchronized(registry) {
        NSDictionary *entry = registry[@(pid)];
        /* Remove only claims belonging to the disconnected peer. A process
         * can host multiple injected components and independent XPC peers. */
        NSMutableDictionary *components = entry[@"components"];
        for (NSString *component in [components.allKeys copy]) {
            if ([components[component][@"peerToken"] isEqualToString:peerToken])
                [components removeObjectForKey:component];
        }
        if (components.count == 0)
            [registry removeObjectForKey:@(pid)];
    }
}

static BOOL CRRuntimeHasComponent(pid_t pid, NSString *process, NSString *component)
{
    NSMutableDictionary *registry = CRRuntimeRegistry();
    @synchronized(registry) {
        NSDictionary *entry = registry[@(pid)];
        if (![entry[@"process"] isEqualToString:process])
            return NO;
        return entry[@"components"][component] != nil;
    }
}

static BOOL CRRuntimeHasComponentInProcess(NSString *component, NSString *process)
{
    if (!component.length)
        return NO;
    NSMutableDictionary *registry = CRRuntimeRegistry();
    @synchronized(registry) {
        for (NSDictionary *entry in registry.allValues) {
            if (process.length && ![entry[@"process"] isEqualToString:process])
                continue;
            if (entry[@"components"][component])
                return YES;
        }
    }
    return NO;
}

static NSString *CRRuntimeContainerForPid(pid_t pid, NSString *process)
{
    NSMutableDictionary *registry = CRRuntimeRegistry();
    @synchronized(registry) {
        NSDictionary *entry = registry[@(pid)];
        if (!entry) {
            NSLog(@"Crane helper: PID proof missing pid=%d reason=no_runtime_peer", pid);
            return nil;
        }
        if (![entry[@"process"] isEqualToString:process]) {
            NSLog(@"Crane helper: PID proof missing pid=%d reason=process_name_mismatch reported=%@ actual=%@",
                  pid, entry[@"process"], process);
            return nil;
        }
        NSDictionary *claim = entry[@"components"][@"Crane"];
        if (!claim) {
            NSLog(@"Crane helper: PID proof missing pid=%d reason=no_crane_report", pid);
            return nil;
        }
        NSString *containerID = claim[@"container"];
        if (!containerID.length)
            NSLog(@"Crane helper: PID proof missing pid=%d reason=empty_container_claim", pid);
        return containerID;
    }
}

/* The two Mach listeners share a deliberately small raw-XPC surface:
 * health, runtime attestation, caller-authorized PID inspection, and one
 * fixed-purpose SpringBoard-only CraneSupport live fix-up. */
static NSString *CRHandleHealthRequest(xpc_connection_t peer,
                                       xpc_object_t message,
                                       pid_t peerPid,
                                       NSString *peerProcess,
                                       NSString *peerSigningID,
                                       NSString *peerToken)
{
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
        return nil;

    const char *operation = xpc_dictionary_get_string(message, "operation");
    if (!operation)
        return nil;
    const char *protocol = xpc_dictionary_get_string(message, "protocol");
    BOOL compatible = protocol &&
        strcmp(protocol, CR_HELPERD_PING_PROTOCOL_V1) == 0;

    if (strcmp(operation, "runtime_report") == 0) {
        const char *componentCString = xpc_dictionary_get_string(message, "component");
        NSString *component = componentCString
            ? [NSString stringWithUTF8String:componentCString] : nil;
        const char *containerCString = xpc_dictionary_get_string(message, "container_id");
        NSString *containerID = containerCString
            ? [NSString stringWithUTF8String:containerCString] : nil;
        if (compatible &&
            CRRuntimeComponentAllowed(component, peerProcess, peerSigningID)) {
            CRRegisterRuntime(peerPid, peerProcess, component, containerID,
                              peerToken);
            BOOL containerProof = [component isEqualToString:@"Crane"] &&
                containerID.length > 0;
            NSLog(@"Crane helper: runtime_report accepted pid=%d process=%@ component=%@ containerProof=%d",
                  peerPid, peerProcess, component, containerProof);
            if (containerProof) {
                /* Reconstruction-only cache coherence: CraneSupport may have
                 * looked up this PID before the app's asynchronous report and
                 * cached DEFAULT. Wake every injected system daemon so its
                 * ClientContainerCache retries against the now-live proof. */
                notify_post(CR_NOTIFICATION_RUNTIME_REGISTRY_CHANGED.UTF8String);
            }
            return component;
        }
        NSLog(@"Crane helper: runtime_report rejected pid=%d process=%@ component=%@ compatible=%d signingID=%@",
              peerPid, peerProcess, component, compatible, peerSigningID);
        return nil;
    }

    if (strcmp(operation, "ping") != 0 &&
        strcmp(operation, "insurance") != 0 &&
        strcmp(operation, "lookup_pid") != 0 &&
        strcmp(operation, "component_loaded") != 0 &&
        strcmp(operation, "injection_fixup") != 0)
        return nil;

    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply)
        return nil;

    if (strcmp(operation, "injection_fixup") == 0) {
        /* Original CraneSB 0x1782C invokes this only after helper connectivity
         * succeeds. Keep the reconstruction endpoint narrower than a generic
         * injector: caller identity comes from the XPC peer, no PID/path is
         * accepted from the request, and the helper may inject only its fixed
         * installed CraneSupport dylib into its fixed filter targets. */
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID) &&
            [peerProcess isEqualToString:@"SpringBoard"];
        NSError *fixError = nil;
        if (authorized)
            CRBeginInjectionFixupAttempt();
        BOOL success = authorized &&
            CRRunCraneSupportInjectionFixup(&fixError);
        if (authorized)
            CRFinishInjectionFixupAttempt(success, fixError);
        NSLog(@"Crane helper: injection_fixup caller=%@ authorized=%d success=%d error=%@",
              peerProcess, authorized, success, fixError);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", success);
        if (fixError) {
            xpc_dictionary_set_string(reply, "error_domain",
                fixError.domain.UTF8String);
            xpc_dictionary_set_int64(reply, "error_code",
                (int64_t)fixError.code);
            if (fixError.localizedDescription.length) {
                xpc_dictionary_set_string(reply, "error_description",
                    fixError.localizedDescription.UTF8String);
            }
        }
    } else if (strcmp(operation, "insurance") == 0) {
        NSString *filter = CRJailbreakRootPath(CR_MAIN_DYLIB_FILTER_PLIST);
        BOOL installed = filter.length &&
            [NSFileManager.defaultManager fileExistsAtPath:filter];
        BOOL sandy = CRIsDylibLoaded(CR_LIB_SANDY);
        /* This request is emitted only by CraneSB's launch path. Binding it
         * to the kernel-reported SpringBoard/runningboardd peer avoids a race
         * with the separate persistent heartbeat connection. */
        BOOL injectionVerified = compatible &&
            CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID);
        BOOL preflight = compatible && installed && sandy;

        NSArray<NSString *> *runningSupport =
            CRRunningCraneSupportProcesses();
        BOOL supportInspectionAvailable = runningSupport != nil;
        NSMutableArray<NSString *> *brokenSupport = [NSMutableArray new];
        for (NSString *process in runningSupport ?: @[]) {
            if (!CRRuntimeHasComponentInProcess(@"CraneSupport", process))
                [brokenSupport addObject:process];
        }

        /* Original helper insurance verifies its exact crucial set even when
         * one of those daemons is currently absent; _execute:whileDaemon...
         * pings an on-demand service before verification. Reconstruction does
         * not yet reproduce that activation ping here, so fail closed instead
         * of silently treating an absent crucial daemon as healthy. */
        for (NSString *process in CRCrucialCraneSupportProcessNames()) {
            if (![runningSupport containsObject:process] &&
                ![brokenSupport containsObject:process]) {
                [brokenSupport addObject:process];
            }
        }

        BOOL supportComplete = supportInspectionAvailable &&
            runningSupport.count > 0 && brokenSupport.count == 0;
        NSString *brokenSupportString =
            [brokenSupport componentsJoinedByString:@", "];
        NSString *supportImageMap = nil;
        if (injectionVerified && !supportComplete && runningSupport.count > 0)
            supportImageMap = CRSupportMappedImageSummary(runningSupport);

        NSDictionary *fixupState = CRLastInjectionFixupSnapshot();
        NSError *lastFixupError = fixupState[@"error"];
        NSString *backendInventory = CRSupportInjectionBackendInventory();
        NSLog(@"Crane helper: insurance caller=%@ authorized=%d preflight=%d supportInspect=%d running=%lu supportComplete=%d broken=%@ images=%@ fixupAttempted=%d fixupInProgress=%d fixupSuccess=%d fixupProcess=%@ fixupBackend=%@ fixupTransitions=%@ fixupError=%@ backends=%@",
              peerProcess, injectionVerified, preflight,
              supportInspectionAvailable, (unsigned long)runningSupport.count,
              supportComplete, brokenSupportString, supportImageMap,
              [fixupState[@"attempted"] boolValue],
              [fixupState[@"inProgress"] boolValue],
              [fixupState[@"success"] boolValue],
              fixupState[@"process"], fixupState[@"backend"],
              fixupState[@"transitions"], lastFixupError, backendInventory);

        xpc_dictionary_set_bool(reply, "preflight_ok", preflight);
        xpc_dictionary_set_bool(reply, "injection_verified", injectionVerified);
        xpc_dictionary_set_bool(reply, "support_inspection_available",
                                supportInspectionAvailable);
        xpc_dictionary_set_bool(reply, "support_complete", supportComplete);
        xpc_dictionary_set_int64(reply, "support_running_count",
                                 (int64_t)runningSupport.count);
        if (brokenSupportString.length)
            xpc_dictionary_set_string(reply, "broken_daemons",
                                      brokenSupportString.UTF8String);
        if (supportImageMap.length)
            xpc_dictionary_set_string(reply, "support_image_map",
                                      supportImageMap.UTF8String);
        xpc_dictionary_set_bool(reply, "fixup_attempted",
                                [fixupState[@"attempted"] boolValue]);
        xpc_dictionary_set_bool(reply, "fixup_in_progress",
                                [fixupState[@"inProgress"] boolValue]);
        xpc_dictionary_set_bool(reply, "fixup_success",
                                [fixupState[@"success"] boolValue]);
        if ([fixupState[@"process"] length])
            xpc_dictionary_set_string(reply, "fixup_process",
                                      [fixupState[@"process"] UTF8String]);
        if ([fixupState[@"backend"] length])
            xpc_dictionary_set_string(reply, "fixup_backend",
                                      [fixupState[@"backend"] UTF8String]);
        if ([fixupState[@"transitions"] length])
            xpc_dictionary_set_string(reply, "fixup_transitions",
                                      [fixupState[@"transitions"] UTF8String]);
        if (lastFixupError) {
            xpc_dictionary_set_int64(reply, "fixup_error_code",
                                     (int64_t)lastFixupError.code);
            if (lastFixupError.localizedDescription.length)
                xpc_dictionary_set_string(reply, "fixup_error_description",
                                          lastFixupError.localizedDescription.UTF8String);
        }
        if (backendInventory.length)
            xpc_dictionary_set_string(reply, "fixup_backend_inventory",
                                      backendInventory.UTF8String);
        xpc_dictionary_set_bool(reply, "works",
            preflight && injectionVerified && supportComplete);
        xpc_dictionary_set_bool(reply, "main_dylib_installed", installed);
        xpc_dictionary_set_bool(reply, "libsandy_loaded", sandy);
        if (peerProcess.length)
            xpc_dictionary_set_string(reply, "caller_process", peerProcess.UTF8String);
        if (peerSigningID.length)
            xpc_dictionary_set_string(reply, "caller_signing_id", peerSigningID.UTF8String);
    } else if (strcmp(operation, "component_loaded") == 0) {
        BOOL authorized = compatible &&
            (CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID) ||
             CRIsAuthenticatedCraneSupportPeer(peerProcess, peerSigningID));
        const char *componentCString = xpc_dictionary_get_string(message, "component");
        const char *processCString = xpc_dictionary_get_string(message, "process");
        NSString *component = componentCString
            ? [NSString stringWithUTF8String:componentCString] : nil;
        NSString *process = processCString
            ? [NSString stringWithUTF8String:processCString] : nil;
        BOOL queryAllowed = [component isEqualToString:@"CraneSB"] ||
            [component isEqualToString:@"CraneSupport"];
        BOOL loaded = authorized && queryAllowed &&
            CRRuntimeHasComponentInProcess(component, process);
        NSLog(@"Crane helper: component_loaded caller=%@ process=%@ component=%@ authorized=%d loaded=%d",
              peerProcess, process, component, authorized, loaded);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "loaded", loaded);
    } else if (strcmp(operation, "lookup_pid") == 0) {
        /* PID/container inspection is limited to Crane's system-side
         * processes. The target PID is still verified against a live runtime
         * report before any container identifier is returned. */
        BOOL authorized = compatible &&
            (CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID) ||
             CRIsAuthenticatedCraneSupportPeer(peerProcess, peerSigningID));
        pid_t targetPid = (pid_t)xpc_dictionary_get_int64(message, "pid");
        NSString *targetProcess = authorized ? CRProcessNameForPid(targetPid) : nil;
        NSString *containerID = targetProcess
            ? CRRuntimeContainerForPid(targetPid, targetProcess) : nil;
        NSLog(@"Crane helper: lookup_pid caller=%@ target=%d targetProcess=%@ authorized=%d hasProof=%d",
              peerProcess, targetPid, targetProcess, authorized,
              containerID.length > 0);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "injection_verified", containerID.length > 0);
        if (containerID.length)
            xpc_dictionary_set_string(reply, "container_id", containerID.UTF8String);
    }

    xpc_dictionary_set_bool(reply, "alive", compatible);
    xpc_dictionary_set_string(reply, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    xpc_connection_send_message(peer, reply);
    return nil;
}

static void CRAcceptHealthPeer(xpc_connection_t peer)
{
    pid_t peerPid = CRXPCConnectionGetPid(peer);
    NSString *peerProcess = CRProcessNameForPid(peerPid);
    NSString *peerSigningID = CRSigningIdentifierForPeer(peer);
    NSString *peerToken = NSUUID.UUID.UUIDString;
    NSLog(@"Crane helper: accepted peer pid=%d process=%@ signingID=%@",
          peerPid, peerProcess, peerSigningID);
    __block BOOL registeredOnPeer = NO;

    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        if (xpc_get_type(message) == XPC_TYPE_ERROR) {
            if (registeredOnPeer) {
                NSLog(@"Crane helper: runtime peer disconnected pid=%d process=%@; removing live proof",
                      peerPid, peerProcess);
                CRUnregisterRuntime(peerPid, peerToken);
                /* Also invalidate positive PID entries on process/peer exit;
                 * otherwise a later PID reuse could inherit a stale container. */
                notify_post(CR_NOTIFICATION_RUNTIME_REGISTRY_CHANGED.UTF8String);
            }
            xpc_connection_cancel(peer);
            return;
        }
        NSString *registered = CRHandleHealthRequest(
            peer, message, peerPid, peerProcess, peerSigningID, peerToken);
        if (registered.length)
            registeredOnPeer = YES;
    });
    xpc_connection_resume(peer);
}

#pragma mark - main

int main(int argc, char *argv[], char *envp[])
{
    @autoreleasepool {
        NSLog(@"Crane helper: starting pid=%d uid=%d protocol=%s",
              getpid(), geteuid(), CR_HELPERD_PING_PROTOCOL_V1);
        CRHServiceShared *shared = CRHServiceShared.sharedService;

        CRHPreferencesService *prefs = [CRHPreferencesService new];
        [shared setService:prefs forInterface:NSStringFromProtocol(@protocol(CRHPreferencesServiceProtocol))];

        CRHGlobalService *global = [CRHGlobalService new];
        [shared setService:global forInterface:NSStringFromProtocol(@protocol(CRHGlobalServiceProtocol))];

        /* Both Mach service names are CONFIRMED_STATIC from the launchd plist.
         * A service that is already registered by an older instance must not
         * abort this one; KeepAlive means launchd will restart us anyway. */
        xpc_connection_t prefsConn =
            CRXPCConnectionCreateMachService(CR_HELPERD_PREFS_MACH_SERVICE.UTF8String,
                                             NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (prefsConn) {
            xpc_connection_set_event_handler(prefsConn,
                ^(xpc_object_t event) {
                    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                        NSLog(@"Crane helper: preferences XPC listener error=%@",
                              CRHelperXPCEventError(event, @"listen_preferences"));
                        return;
                    }
                    if (xpc_get_type(event) != XPC_TYPE_CONNECTION)
                        return;
                    CRAcceptHealthPeer((xpc_connection_t)event);
                });
            xpc_connection_resume(prefsConn);
        } else {
            NSLog(@"Crane helper: preferences XPC service creation failed");
        }

        xpc_connection_t globalConn =
            CRXPCConnectionCreateMachService(CR_HELPERD_MACH_SERVICE.UTF8String,
                                             NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        if (globalConn) {
            xpc_connection_set_event_handler(globalConn,
                ^(xpc_object_t event) {
                    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                        NSLog(@"Crane helper: global XPC listener error=%@",
                              CRHelperXPCEventError(event, @"listen_global"));
                        return;
                    }
                    if (xpc_get_type(event) != XPC_TYPE_CONNECTION)
                        return;
                    CRAcceptHealthPeer((xpc_connection_t)event);
                });
            xpc_connection_resume(globalConn);
        } else {
            NSLog(@"Crane helper: global XPC service creation failed");
        }

        dispatch_main();
    }
    return 0;
}