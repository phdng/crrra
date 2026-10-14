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
#import <objc/message.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"
#import "CRXPCDiagnostics.h"

#include <notify.h>
#include <dlfcn.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
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

#pragma mark - Keychain

/* Directly recovered from original cranehelperd:
 *   CRHKeychain class methods 0x100007B2C..0x100008A68
 *   helper SecItem loops      0x10000644C..0x10000747C
 * Move/delete are implemented here first because their query/update shape is
 * completely recoverable and they are required by container lifecycle. Dump,
 * restore and migration remain fail-closed until their serialization format is
 * fully transcribed. */
@interface CRHKeychain : NSObject
+ (NSString *)craneStringForContainerIdentifier:(NSString *)containerID;
+ (NSString *)redirectedAccessGroupForAccessGroup:(NSString *)accessGroup
                              containerIdentifier:(NSString *)containerID;
+ (NSSet<NSString *> *)accessGroupsForApplicationWithIdentifier:(NSString *)appID;
+ (BOOL)moveKeychainItemsFromContainerWithIdentifier:(NSString *)sourceContainer
                           toContainerWithIdentifier:(NSString *)destinationContainer
                        forApplicationWithIdentifier:(NSString *)appID;
+ (BOOL)deleteKeychainItemsForContainerWithIdentifier:(NSString *)containerID
                             forApplicationIdentifier:(NSString *)appID;
@end

static NSArray *CRHAllSecItemClasses(void)
{
    return @[
        (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecClassInternetPassword,
        (__bridge id)kSecClassCertificate,
        (__bridge id)kSecClassKey,
        (__bridge id)kSecClassIdentity
    ];
}

static NSSet<NSString *> *CRHKeychainAccessGroupsToIgnore(void)
{
    static NSSet<NSString *> *groups;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        groups = [NSSet setWithObjects:
            @"com.apple.token",
            @"com.apple.certificates",
            @"com.apple.identities",
            @"apple",
            @"com.apple.cfnetwork",
            @"com.apple.ProtectedCloudStorage",
            @"com.apple.passd",
            @"com.apple.managed.vpn.shared",
            nil];
    });
    return groups;
}

static BOOL CRHSecItemStatusIsSuccess(OSStatus status)
{
    /* Original 0x1000071B4/0x1000073E0 preserves the aggregate success
     * flag for both errSecSuccess and errSecItemNotFound (-25300). */
    return status == errSecSuccess || status == errSecItemNotFound;
}

static BOOL CRHSecItemUpdateAllClasses(NSDictionary *query,
                                       NSDictionary *attributes)
{
    if (![query isKindOfClass:NSDictionary.class] ||
        ![attributes isKindOfClass:NSDictionary.class])
        return NO;

    BOOL success = YES;
    for (id secClass in CRHAllSecItemClasses()) {
        NSMutableDictionary *classQuery = [query mutableCopy];
        classQuery[(__bridge id)kSecClass] = secClass;
        classQuery[@"craneprefs_unrestrict"] = @YES;
        OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)classQuery,
                                        (__bridge CFDictionaryRef)attributes);
        if (!CRHSecItemStatusIsSuccess(status))
            success = NO;
    }
    return success;
}

static BOOL CRHSecItemDeleteAllClasses(NSDictionary *query)
{
    if (![query isKindOfClass:NSDictionary.class])
        return NO;

    BOOL success = YES;
    for (id secClass in CRHAllSecItemClasses()) {
        NSMutableDictionary *classQuery = [query mutableCopy];
        classQuery[(__bridge id)kSecClass] = secClass;
        classQuery[@"craneprefs_unrestrict"] = @YES;
        OSStatus status = SecItemDelete((__bridge CFDictionaryRef)classQuery);
        if (!CRHSecItemStatusIsSuccess(status))
            success = NO;
    }
    return success;
}

@implementation CRHKeychain

+ (NSString *)craneStringForContainerIdentifier:(NSString *)containerID
{
    return containerID.length
        ? [@".c_r_a_n_e." stringByAppendingString:containerID] : nil;
}

+ (NSString *)redirectedAccessGroupForAccessGroup:(NSString *)accessGroup
                              containerIdentifier:(NSString *)containerID
{
    if (!accessGroup.length || !containerID.length)
        return nil;
    if ([containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return accessGroup;
    NSString *suffix = [self craneStringForContainerIdentifier:containerID];
    return suffix.length ? [accessGroup stringByAppendingString:suffix] : nil;
}

+ (NSSet<NSString *> *)accessGroupsForApplicationWithIdentifier:(NSString *)appID
{
    if (!appID.length)
        return [NSSet set];

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySEL = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySEL])
        return [NSSet set];

    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
            proxyClass, proxySEL, appID);
        SEL entitlementsSEL = NSSelectorFromString(@"entitlements");
        NSDictionary *entitlements = [proxy respondsToSelector:entitlementsSEL]
            ? ((id (*)(id, SEL))objc_msgSend)(proxy, entitlementsSEL) : nil;
        if (![entitlements isKindOfClass:NSDictionary.class])
            return [NSSet set];

        NSMutableSet<NSString *> *groups = [NSMutableSet set];
        id keychainGroups = entitlements[@"keychain-access-groups"];
        if ([keychainGroups isKindOfClass:NSArray.class])
            [groups addObjectsFromArray:keychainGroups];
        id applicationGroups =
            entitlements[@"com.apple.security.application-groups"];
        if ([applicationGroups isKindOfClass:NSArray.class])
            [groups addObjectsFromArray:applicationGroups];
        id applicationIdentifier = entitlements[@"application-identifier"];
        if ([applicationIdentifier isKindOfClass:NSString.class] &&
            [applicationIdentifier length])
            [groups addObject:applicationIdentifier];

        [groups minusSet:CRHKeychainAccessGroupsToIgnore()];
        return [groups copy];
    } @catch (NSException *exception) {
        NSLog(@"Crane helper: keychain entitlement lookup failed app=%@: %@",
              appID, exception);
        return [NSSet set];
    }
}

+ (BOOL)moveKeychainItemsFromContainerWithIdentifier:(NSString *)sourceContainer
                           toContainerWithIdentifier:(NSString *)destinationContainer
                        forApplicationWithIdentifier:(NSString *)appID
{
    if (!sourceContainer.length || !destinationContainer.length || !appID.length)
        return NO;

    BOOL success = YES;
    for (NSString *baseGroup in [self accessGroupsForApplicationWithIdentifier:appID]) {
        NSString *sourceGroup =
            [self redirectedAccessGroupForAccessGroup:baseGroup
                                  containerIdentifier:sourceContainer];
        NSString *destinationGroup =
            [self redirectedAccessGroupForAccessGroup:baseGroup
                                  containerIdentifier:destinationContainer];
        if (!sourceGroup.length || !destinationGroup.length ||
            [sourceGroup isEqualToString:destinationGroup])
            continue;

        NSDictionary *query = @{
            (__bridge id)kSecAttrAccessGroup: sourceGroup,
            (__bridge id)kSecAttrSynchronizable:
                (__bridge id)kSecAttrSynchronizableAny
        };
        NSDictionary *update = @{
            (__bridge id)kSecAttrAccessGroup: destinationGroup
        };
        if (!CRHSecItemUpdateAllClasses(query, update))
            success = NO;
    }
    return success;
}

+ (BOOL)deleteKeychainItemsForContainerWithIdentifier:(NSString *)containerID
                             forApplicationIdentifier:(NSString *)appID
{
    if (!containerID.length || !appID.length)
        return NO;

    BOOL success = YES;
    for (NSString *baseGroup in [self accessGroupsForApplicationWithIdentifier:appID]) {
        NSString *redirected =
            [self redirectedAccessGroupForAccessGroup:baseGroup
                                  containerIdentifier:containerID];
        if (!redirected.length)
            continue;
        NSDictionary *query = @{
            (__bridge id)kSecAttrAccessGroup: redirected,
            (__bridge id)kSecAttrSynchronizable:
                (__bridge id)kSecAttrSynchronizableAny
        };
        if (!CRHSecItemDeleteAllClasses(query))
            success = NO;
    }
    return success;
}

@end
#pragma mark - Preferences service

/* Original CRHPreferencesService exposes only the three keychain migration /
 * backup selectors recovered from cranehelperd metadata. Do not repurpose this
 * privileged surface as a generic preference store: CraneManager and Root.plist
 * already own com.opa334.craneprefs directly. The serialization/migration body
 * is not fully recovered yet, so all three operations remain explicitly
 * fail-closed instead of fabricating an empty dump or reporting migration. */
@protocol CRHPreferencesServiceProtocol <NSObject>
- (void)dumpKeychainItemsFromContainerWithIdentifier:(NSString *)containerID
                            forApplicationIdentifier:(NSString *)appID
                                               reply:(void (^)(NSDictionary *items))reply;
- (void)restoreKeychainItemsToContainerWithIdentifier:(NSString *)containerID
                              forApplicationIdentifier:(NSString *)appID
                                       fromDictionary:(NSDictionary *)items;
- (void)migrateApplication:(NSString *)appID withAppSettings:(NSDictionary *)settings;
@end

@interface CRHPreferencesServiceDelegate : NSObject <CRHPreferencesServiceProtocol>
@end

@implementation CRHPreferencesServiceDelegate

- (void)dumpKeychainItemsFromContainerWithIdentifier:(NSString *)containerID
                            forApplicationIdentifier:(NSString *)appID
                                               reply:(void (^)(NSDictionary *))reply
{
    (void)containerID; (void)appID;
    NSLog(@"Crane helper: preferences keychain dump unavailable");
    if (reply)
        reply(nil);
}

- (void)restoreKeychainItemsToContainerWithIdentifier:(NSString *)containerID
                              forApplicationIdentifier:(NSString *)appID
                                       fromDictionary:(NSDictionary *)items
{
    (void)containerID; (void)appID; (void)items;
    NSLog(@"Crane helper: preferences keychain restore unavailable");
}

- (void)migrateApplication:(NSString *)appID withAppSettings:(NSDictionary *)settings
{
    (void)appID; (void)settings;
    NSLog(@"Crane helper: preferences keychain migration unavailable");
}

@end

@interface CRHPreferencesService : NSObject <CRHPreferencesServiceProtocol>
@property (nonatomic, strong) id<CRHPreferencesServiceProtocol> delegate;
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

- (void)dumpKeychainItemsFromContainerWithIdentifier:(NSString *)containerID
                            forApplicationIdentifier:(NSString *)appID
                                               reply:(void (^)(NSDictionary *))reply
{
    [self.delegate dumpKeychainItemsFromContainerWithIdentifier:containerID
                                      forApplicationIdentifier:appID
                                                         reply:reply];
}

- (void)restoreKeychainItemsToContainerWithIdentifier:(NSString *)containerID
                              forApplicationIdentifier:(NSString *)appID
                                       fromDictionary:(NSDictionary *)items
{
    [self.delegate restoreKeychainItemsToContainerWithIdentifier:containerID
                                        forApplicationIdentifier:appID
                                                 fromDictionary:items];
}

- (void)migrateApplication:(NSString *)appID withAppSettings:(NSDictionary *)settings
{
    [self.delegate migrateApplication:appID withAppSettings:settings];
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
typedef int (*CRProcPidPathFn)(int, void *, uint32_t);
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

/* Original CRHServiceShared process-control helpers are recoverable from the
 * stripped helper's Objective-C IMPs. reloadApplication: resolves an
 * LSApplicationProxy canonical executable path and looks up the PID by that
 * exact path; daemon control resolves by process name. */
static CRProcPidPathFn CRHelperProcPidPathFunction(void)
{
    static CRProcPidPathFn procPidPath;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
        procPidPath = (CRProcPidPathFn)dlsym(
            handle ?: RTLD_DEFAULT, "proc_pidpath");
    });
    return procPidPath;
}

static pid_t CRPidForProcessName(NSString *name)
{
    if (!name.length)
        return 0;
    NSNumber *pid = CRProcessPidsForNames(@[name])[name];
    return pid ? (pid_t)pid.intValue : 0;
}

static pid_t CRPidForExecutablePath(NSString *executablePath)
{
    if (!executablePath.length)
        return 0;

    CRProcListPidsFn procListPids = CRHelperProcListPidsFunction();
    CRProcPidPathFn procPidPath = CRHelperProcPidPathFunction();
    if (!procListPids || !procPidPath)
        return 0;

    int required = procListPids(1, 0, NULL, 0);
    if (required <= 0)
        return 0;
    int capacity = required + (int)(256 * sizeof(pid_t));
    pid_t *pids = calloc(1, (size_t)capacity);
    if (!pids)
        return 0;

    int bytes = procListPids(1, 0, pids, capacity);
    if (bytes <= 0) {
        free(pids);
        return 0;
    }

    pid_t result = 0;
    NSUInteger count = (NSUInteger)bytes / sizeof(pid_t);
    for (NSUInteger i = 0; i < count; ++i) {
        pid_t pid = pids[i];
        if (pid < 2)
            continue;
        char pathBuffer[4096] = {0};
        if (procPidPath(pid, pathBuffer, sizeof(pathBuffer)) <= 0)
            continue;
        NSString *path = [NSString stringWithUTF8String:pathBuffer];
        if ([path isEqualToString:executablePath]) {
            result = pid;
            break;
        }
    }
    free(pids);
    return result;
}

/* Recovered _serviceNameForDaemon: at 0x10000AA64. Four daemons use
 * nontrivial Mach-service names; all others are "com.apple." + daemon. */
static NSString *CRServiceNameForDaemon(NSString *daemon)
{
    if ([daemon isEqualToString:@"cfprefsd"])
        return @"com.apple.cfprefsd.daemon";
    if ([daemon isEqualToString:@"pkd"])
        return @"com.apple.pluginkit.pkd";
    if ([daemon isEqualToString:@"lsd"])
        return @"com.apple.lsd.xpc";
    if ([daemon isEqualToString:@"accountsd"])
        return @"com.apple.accountsd.accountmanager";
    return daemon.length
        ? [@"com.apple." stringByAppendingString:daemon]
        : nil;
}

/* Recovered _pingDaemon: at 0x10000AB4C. A privileged Mach-service
 * connection plus one synchronous empty dictionary is enough to ask launchd
 * to activate an on-demand daemon. Connection-invalid/interrupted means the
 * activation probe failed. */
static BOOL CRPingDaemon(NSString *daemon)
{
    NSString *serviceName = CRServiceNameForDaemon(daemon);
    if (!serviceName.length)
        return NO;

    xpc_connection_t connection = CRXPCConnectionCreateMachService(
        serviceName.UTF8String, NULL, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
    if (!connection)
        return NO;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        (void)event;
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (!request) {
        xpc_connection_cancel(connection);
        return NO;
    }
    xpc_object_t response =
        xpc_connection_send_message_with_reply_sync(connection, request);
    BOOL success = response &&
        response != XPC_ERROR_CONNECTION_INVALID &&
        response != XPC_ERROR_CONNECTION_INTERRUPTED;
    xpc_connection_cancel(connection);
    return success;
}

/* Recovered _execute:whileDaemonWithNameIsRunning: at 0x10000AC20 first
 * checks for a running PID, pings the service only when absent, then checks
 * the PID again. Insurance uses the same activation intent for the crucial
 * daemon set instead of treating an on-demand daemon as permanently absent. */
static void CRActivateCrucialCraneSupportDaemons(void)
{
    for (NSString *daemon in CRCrucialCraneSupportProcessNames()) {
        pid_t before = CRPidForProcessName(daemon);
        if (before > 0)
            continue;
        BOOL pinged = CRPingDaemon(daemon);
        pid_t after = CRPidForProcessName(daemon);
        NSLog(@"Crane helper: daemon activation process=%@ pinged=%d pid=%d",
              daemon, pinged, after);
    }
}

typedef CFNotificationCenterRef (*CRGetDistributedCenterFn)(void);

static void CRPostReloadApplicationNotification(NSString *appID)
{
    if (!appID.length)
        return;

    /* Recovered helper sub_100009FB4: log, then post the distributed
     * com.opa334.crane/ReloadApplication notification with object
     * "ReloadApplication" and { applicationIdentifier = appID }. */
    NSLog(@"Crane - Reload requested, killed");

    static CRGetDistributedCenterFn getDistributedCenter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getDistributedCenter = (CRGetDistributedCenterFn)dlsym(
            RTLD_DEFAULT, "CFNotificationCenterGetDistributedCenter");
    });
    if (!getDistributedCenter)
        return;

    CFNotificationCenterRef center = getDistributedCenter();
    if (!center)
        return;
    NSDictionary *userInfo = @{@"applicationIdentifier": appID};
    CFNotificationCenterPostNotification(
        center,
        CFSTR("com.opa334.crane/ReloadApplication"),
        CFSTR("ReloadApplication"),
        (__bridge CFDictionaryRef)userInfo,
        true);
}

static id CRApplicationProxyForIdentifier(NSString *appID)
{
    if (!appID.length)
        return nil;

    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
               RTLD_LAZY | RTLD_LOCAL);
    });

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL proxySEL = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:proxySEL])
        return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(
        (id)proxyClass, proxySEL, appID);
}

/* Recovered helper 0x10000CC68. Crane excludes ten Apple system apps, allows
 * the three Store/Music bundle IDs even if they do not have a normal data
 * container, and otherwise requires a dataContainerURL and !atl_isHidden. */
static BOOL CRApplicationProxyIsSupported(id application)
{
    if (!application)
        return NO;

    SEL bundleSEL = NSSelectorFromString(@"bundleIdentifier");
    if (![application respondsToSelector:bundleSEL])
        return NO;
    NSString *bundleID =
        ((id (*)(id, SEL))objc_msgSend)(application, bundleSEL);
    if (![bundleID isKindOfClass:NSString.class] || !bundleID.length)
        return NO;

    static NSSet<NSString *> *excluded;
    static NSSet<NSString *> *storeApps;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        excluded = [NSSet setWithArray:@[
            @"com.apple.Preferences",
            @"com.apple.MobileSMS",
            @"com.apple.mobilesafari",
            @"com.apple.MobileAddressBook",
            @"com.apple.mobilephone",
            @"com.apple.facetime",
            @"com.apple.mobilecal",
            @"com.apple.sidecar",
            @"com.apple.siri",
            @"com.apple.DocumentsApp",
        ]];
        storeApps = [NSSet setWithArray:@[
            @"com.apple.AppStore",
            @"com.apple.Music",
            @"com.apple.MobileStore",
        ]];
    });
    if ([excluded containsObject:bundleID])
        return NO;
    if ([storeApps containsObject:bundleID])
        return YES;

    SEL hiddenSEL = NSSelectorFromString(@"atl_isHidden");
    BOOL hidden = [application respondsToSelector:hiddenSEL]
        ? ((BOOL (*)(id, SEL))objc_msgSend)(application, hiddenSEL) : NO;
    SEL dataSEL = NSSelectorFromString(@"dataContainerURL");
    id dataURL = [application respondsToSelector:dataSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(application, dataSEL) : nil;
    return dataURL != nil && !hidden;
}

static BOOL CRApplicationIdentifierIsSupported(NSString *appID)
{
    return CRApplicationProxyIsSupported(
        CRApplicationProxyForIdentifier(appID));
}

static NSString *CRDisplayNameForApplicationIdentifier(NSString *appID)
{
    id application = CRApplicationProxyForIdentifier(appID);
    SEL nameSEL = NSSelectorFromString(@"localizedName");
    id name = application && [application respondsToSelector:nameSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(application, nameSEL) : nil;
    return [name isKindOfClass:NSString.class] ? name : nil;
}

/* Recovered helper 0x10000CF8C: enumerate LSApplicationWorkspace types 0 and
 * 1 and append the bundle identifier only when the exact support predicate
 * above passes. Preserve enumeration order while avoiding accidental dupes. */
static NSArray<NSString *> *CRSupportedApplicationIdentifiers(void)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
               RTLD_LAZY | RTLD_LOCAL);
    });

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    SEL defaultSEL = NSSelectorFromString(@"defaultWorkspace");
    if (!workspaceClass || ![workspaceClass respondsToSelector:defaultSEL])
        return nil;
    id workspace = ((id (*)(id, SEL))objc_msgSend)(
        (id)workspaceClass, defaultSEL);
    SEL enumerateSEL = NSSelectorFromString(@"enumerateApplicationsOfType:block:");
    if (!workspace || ![workspace respondsToSelector:enumerateSEL])
        return nil;

    NSMutableArray<NSString *> *result = [NSMutableArray new];
    NSMutableSet<NSString *> *seen = [NSMutableSet new];
    void (^visit)(id) = ^(id application) {
        if (!CRApplicationProxyIsSupported(application))
            return;
        SEL bundleSEL = NSSelectorFromString(@"bundleIdentifier");
        NSString *bundleID = [application respondsToSelector:bundleSEL]
            ? ((id (*)(id, SEL))objc_msgSend)(application, bundleSEL) : nil;
        if (bundleID.length && ![seen containsObject:bundleID]) {
            [seen addObject:bundleID];
            [result addObject:bundleID];
        }
    };
    ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(
        workspace, enumerateSEL, 0, visit);
    ((void (*)(id, SEL, NSUInteger, id))objc_msgSend)(
        workspace, enumerateSEL, 1, visit);
    return [result copy];
}

static id CRLSDDeviceIdentifierProxy(void)
{
    /* Original read/write methods resolve _LSDDeviceIdentifierService and use
     * synchronousXPCProxyWithErrorHandler:. CraneSupport/CRLsd.m installs the
     * two crane_* methods on the remote _LSDDeviceIdentifierClient and
     * authenticates the helper again by its executable path. */
    dlopen("/System/Library/Frameworks/MobileCoreServices.framework/MobileCoreServices",
           RTLD_LAZY | RTLD_LOCAL);
    dlopen("/System/Library/Frameworks/CoreServices.framework/CoreServices",
           RTLD_LAZY | RTLD_LOCAL);

    Class serviceClass = NSClassFromString(@"_LSDDeviceIdentifierService");
    SEL proxySEL = NSSelectorFromString(@"synchronousXPCProxyWithErrorHandler:");
    if (!serviceClass || ![serviceClass respondsToSelector:proxySEL])
        return nil;

    __block NSError *proxyError = nil;
    id errorHandler = ^(NSError *error) {
        proxyError = error;
    };
    id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
        (id)serviceClass, proxySEL, errorHandler);
    if (proxyError) {
        NSLog(@"Crane helper: LSD device identifier proxy error=%@", proxyError);
        return nil;
    }
    return proxy;
}

static id CRReadDeviceVendorIdentifier(NSString *appID)
{
    id application = CRApplicationProxyForIdentifier(appID);
    SEL vendorSEL = NSSelectorFromString(@"vendorName");
    NSString *vendorName = application &&
        [application respondsToSelector:vendorSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(application, vendorSEL) : nil;

    id proxy = CRLSDDeviceIdentifierProxy();
    SEL readSEL = NSSelectorFromString(
        @"crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:");
    if (!proxy || ![proxy respondsToSelector:readSEL])
        return nil;

    __block id identifier = nil;
    void (^reply)(NSArray *) = ^(NSArray *values) {
        if ([values isKindOfClass:NSArray.class] && values.count)
            identifier = values.firstObject;
    };
    ((void (*)(id, SEL, id, int64_t, id, id))objc_msgSend)(
        proxy, readSEL, reply, (int64_t)0, vendorName, appID);
    return identifier;
}

static BOOL CRWriteDeviceVendorIdentifier(id identifier, NSString *appID)
{
    if (!identifier || !appID.length)
        return NO;

    id application = CRApplicationProxyForIdentifier(appID);
    SEL vendorSEL = NSSelectorFromString(@"vendorName");
    NSString *vendorName = application &&
        [application respondsToSelector:vendorSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(application, vendorSEL) : nil;

    id proxy = CRLSDDeviceIdentifierProxy();
    SEL writeSEL = NSSelectorFromString(
        @"crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:");
    if (!proxy || ![proxy respondsToSelector:writeSEL])
        return NO;

    ((void (*)(id, SEL, id, int64_t, id, id))objc_msgSend)(
        proxy, writeSEL, identifier, (int64_t)0, vendorName, appID);
    return YES;
}

static NSString *CRDeviceIdentifierString(id identifier)
{
    if ([identifier isKindOfClass:NSString.class])
        return identifier;
    SEL uuidStringSEL = NSSelectorFromString(@"UUIDString");
    if ([identifier respondsToSelector:uuidStringSEL]) {
        id value = ((id (*)(id, SEL))objc_msgSend)(
            identifier, uuidStringSEL);
        return [value isKindOfClass:NSString.class] ? value : nil;
    }
    return nil;
}

static NSString *CRExecutablePathForApplicationIdentifier(NSString *appID)
{
    if (!appID.length)
        return nil;

    id proxy = CRApplicationProxyForIdentifier(appID);
    SEL pathSEL = NSSelectorFromString(@"canonicalExecutablePath");
    if (!proxy || ![proxy respondsToSelector:pathSEL])
        return nil;
    id path = ((id (*)(id, SEL))objc_msgSend)(proxy, pathSEL);
    return [path isKindOfClass:NSString.class] ? path : nil;
}

/* Recovered CRHGlobalService reloadApplication: at 0x100005CD0:
 *  1. post the PlugInKit distributed reload notification;
 *  2. resolve canonical executable path -> PID;
 *  3. SIGTERM that PID;
 *  4. resolve the path/PID again and SIGKILL only if still present.
 * There is deliberately no caller-selected PID or executable path. */
static BOOL CRReloadApplication(NSString *appID)
{
    if (!appID.length)
        return NO;

    CRPostReloadApplicationNotification(appID);
    NSString *path = CRExecutablePathForApplicationIdentifier(appID);
    if (!path.length) {
        NSLog(@"Crane helper: reload application=%@ unavailable=no_executable_path",
              appID);
        return NO;
    }

    pid_t pid = CRPidForExecutablePath(path);
    if (pid >= 2)
        kill(pid, SIGTERM);

    NSString *currentPath = CRExecutablePathForApplicationIdentifier(appID);
    pid_t currentPid = currentPath.length
        ? CRPidForExecutablePath(currentPath) : 0;
    if (currentPid >= 2)
        kill(currentPid, SIGKILL);

    NSLog(@"Crane helper: reload application=%@ path=%@ termPid=%d killPid=%d",
          appID, path, pid, currentPid);
    return YES;
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
    }
}

static NSDictionary *CRLastInjectionFixupSnapshot(void)
{
    @synchronized(CRInjectionErrorDomain) {
        NSMutableDictionary *snapshot = [@{
            @"attempted": @(gLastInjectionFixupAttempted),
            @"inProgress": @(gLastInjectionFixupInProgress),
            @"success": @(gLastInjectionFixupSuccess),
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

/* Recovered CRHGlobalService reloadDaemons: at 0x100005A48. The original
 * never accepts an arbitrary process name: it intersects the caller's set
 * with CraneSupport's configured daemons plus these five fixed Store/Game
 * Center processes before calling _killallProcessesWithName:. */
static NSSet<NSString *> *CRAllowedReloadDaemonNames(void)
{
    NSMutableSet<NSString *> *allowed = [NSMutableSet new];
    NSArray<NSString *> *support = CRSupportFixupTargets(NULL);
    if (support.count)
        [allowed addObjectsFromArray:support];
    [allowed addObjectsFromArray:@[
        @"appstored",
        @"itunesstored",
        @"StoreKitUIService",
        @"itunescloudd",
        @"gamed",
    ]];
    return [allowed copy];
}

/* Recovered _killallProcessesWithName: at 0x10000BAB0. A newly observed PID
 * gets SIGTERM. If the same PID survives the next lookup it is escalated to
 * SIGKILL, then SIGTERM is issued as in the original. Bound the reconstruction
 * loop so a launchd KeepAlive service cannot wedge the helper indefinitely. */
static void CRKillAllProcessesWithName(NSString *process)
{
    if (!process.length)
        return;

    pid_t previous = 0;
    for (NSUInteger attempt = 0; attempt < 64; ++attempt) {
        pid_t pid = CRPidForProcessName(process);
        if (pid < 2)
            return;
        if (pid == previous)
            kill(pid, SIGKILL);
        kill(pid, SIGTERM);
        previous = pid;
    }
    NSLog(@"Crane helper: reload daemon=%@ stopped after bounded kill loop",
          process);
}

static NSArray<NSString *> *CRReloadDaemons(NSArray *requestedDaemons)
{
    if (![requestedDaemons isKindOfClass:NSArray.class])
        return nil;

    NSMutableSet<NSString *> *requested = [NSMutableSet new];
    for (id value in requestedDaemons) {
        if ([value isKindOfClass:NSString.class] && [value length])
            [requested addObject:value];
    }

    NSMutableSet<NSString *> *selected =
        [CRAllowedReloadDaemonNames() mutableCopy];
    [selected intersectSet:requested];

    NSArray<NSString *> *ordered = [[selected allObjects]
        sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *process in ordered)
        CRKillAllProcessesWithName(process);

    NSLog(@"Crane helper: reload daemons requested=%@ selected=%@",
          requestedDaemons, ordered);
    return ordered;
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

static NSArray<NSString *> *CRSupportInjectionBinaryCandidates(void)
{
#if CRANE_ROOTHIDE
    return @[
        @"/basebin/opainject",
        @"/usr/bin/opainject",
        @"/usr/local/bin/opainject",
        @"/usr/libexec/libhooker/libsyringe",
        @"/usr/bin/cynject",
        @"/usr/bin/cynject.old",
    ];
#else
    /* Exact recovered rootful backend set. opainject is a Roothide-only
     * platform adaptation and must not change rootful selection semantics. */
    return @[
        @"/usr/libexec/libhooker/libsyringe",
        @"/usr/bin/cynject",
        @"/usr/bin/cynject.old",
    ];
#endif
}

static NSString *CRFindSupportInjectionBinary(void)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *virtualPath in CRSupportInjectionBinaryCandidates()) {
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
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    for (NSString *virtualPath in CRSupportInjectionBinaryCandidates()) {
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

static BOOL CRRuntimeHasComponent(pid_t pid, NSString *process,
                                  NSString *component);
static BOOL CRRuntimeHasComponentInProcess(NSString *component,
                                           NSString *process);

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
            BOOL timedOut = [toolError.domain isEqualToString:CRInjectionErrorDomain] &&
                toolError.code == CRInjectionTimedOut;
            if (timedOut) {
                NSString *currentProcess = CRProcessNameForPid(pid);
                if (![currentProcess isEqualToString:process]) {
                    CRRecordInjectionFixupTransition(
                        process, pid, currentProcess);
                    NSLog(@"Crane helper: injection fixup process=%@ pid=%d timeoutDeferred=target_transition actual=%@",
                          process, pid, currentProcess);
                    return YES;
                }

                BOOL canInspect = NO;
                BOOL mapped = CRPidMapsImageLeaf(
                    pid, @"CraneSupport.dylib", &canInspect);
                BOOL runtimeProof =
                    CRRuntimeHasComponent(pid, process, @"CraneSupport");
                if (mapped || runtimeProof) {
                    NSLog(@"Crane helper: injection fixup process=%@ pid=%d timeoutRecovered=1 mapped=%d runtimeProof=%d inspect=%d",
                          process, pid, mapped, runtimeProof, canInspect);
                    return YES;
                }
            }

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
            @"%@[pid=%d inspect=%d systemhook=%d loader=%d injector=%d ellekit=%d substrate=%d jb=%lu jbSample=%@ other=%lu sample=%@ support=%d]",
            process, pid, inspect, systemhook, tweakLoader, injector, ellekit,
            substrate, (unsigned long)jailbreakImages.count, jbSample,
            (unsigned long)otherTweaks.count, sample, support]];
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

/* Privileged control requests are narrower than health/insurance. The
 * recovered reload call sites are SpringBoard (daemon recovery/menu flow) and
 * Preferences (settings changes). Do not inherit runningboardd's health-only
 * allowance for operations that terminate processes. */
static BOOL CRIsAuthenticatedCraneControlPeer(NSString *process,
                                               NSString *signingID)
{
    if ([process isEqualToString:@"SpringBoard"])
        return [signingID isEqualToString:@"com.apple.springboard"];
    if ([process isEqualToString:@"Preferences"])
        return [signingID isEqualToString:@"com.apple.Preferences"];
    return NO;
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

/* Error replies use the same fields as the existing injection_fixup
 * transport. This is local to the helper, not a new privileged operation. */
static void CRSetReplyError(xpc_object_t reply,
                            CRHelperTransportErrorCode code,
                            NSString *description)
{
    if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY)
        return;
    xpc_dictionary_set_string(reply, "error_domain",
                              "com.opa334.crane.helper.transport");
    xpc_dictionary_set_int64(reply, "error_code", (int64_t)code);
    xpc_dictionary_set_string(reply, "error_description",
        (description ?: @"Helper operation failed").UTF8String);
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
        strcmp(operation, "injection_fixup") != 0 &&
        strcmp(operation, "reload_application") != 0 &&
        strcmp(operation, "reload_daemons") != 0 &&
        strcmp(operation, "get_application_display_name") != 0 &&
        strcmp(operation, "get_supported_application_ids") != 0 &&
        strcmp(operation, "check_application_supported") != 0 &&
        strcmp(operation, "read_device_vendor_identifier") != 0 &&
        strcmp(operation, "write_device_vendor_identifier") != 0 &&
        strcmp(operation, "move_keychain_items") != 0 &&
        strcmp(operation, "delete_keychain_items") != 0)
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
    } else if (strcmp(operation, "get_application_display_name") == 0) {
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        const char *appCString =
            xpc_dictionary_get_string(message, "application_id");
        NSString *appID = appCString
            ? [NSString stringWithUTF8String:appCString] : nil;
        BOOL validRequest = appID.length > 0 && appID.length <= 255 &&
            [appID rangeOfString:@"/"].location == NSNotFound;
        NSString *displayName = authorized && validRequest
            ? CRDisplayNameForApplicationIdentifier(appID) : nil;
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", authorized && validRequest);
        if (displayName.length)
            xpc_dictionary_set_string(reply, "display_name", displayName.UTF8String);
    } else if (strcmp(operation, "get_supported_application_ids") == 0) {
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        NSArray<NSString *> *identifiers = authorized
            ? CRSupportedApplicationIdentifiers() : nil;
        BOOL success = authorized && identifiers != nil;
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", success);
        if (success) {
            xpc_object_t values = xpc_array_create(NULL, 0);
            for (NSString *identifier in identifiers) {
                xpc_object_t item = xpc_string_create(identifier.UTF8String);
                if (item)
                    xpc_array_append_value(values, item);
            }
            xpc_dictionary_set_value(reply, "application_ids", values);
        }
    } else if (strcmp(operation, "check_application_supported") == 0) {
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        const char *appCString =
            xpc_dictionary_get_string(message, "application_id");
        NSString *appID = appCString
            ? [NSString stringWithUTF8String:appCString] : nil;
        BOOL validRequest = appID.length > 0 && appID.length <= 255 &&
            [appID rangeOfString:@"/"].location == NSNotFound;
        BOOL supported = authorized && validRequest &&
            CRApplicationIdentifierIsSupported(appID);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", authorized && validRequest);
        xpc_dictionary_set_bool(reply, "supported", supported);
    } else if (strcmp(operation, "read_device_vendor_identifier") == 0) {
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        const char *appCString =
            xpc_dictionary_get_string(message, "application_id");
        NSString *appID = appCString
            ? [NSString stringWithUTF8String:appCString] : nil;
        BOOL validRequest = appID.length > 0 && appID.length <= 255 &&
            [appID rangeOfString:@"/"].location == NSNotFound;
        id identifier = authorized && validRequest
            ? CRReadDeviceVendorIdentifier(appID) : nil;
        NSString *identifierString =
            CRDeviceIdentifierString(identifier);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", authorized && validRequest);
        if (identifierString.length) {
            xpc_dictionary_set_string(reply, "identifier",
                                      identifierString.UTF8String);
        }
    } else if (strcmp(operation, "write_device_vendor_identifier") == 0) {
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        const char *appCString =
            xpc_dictionary_get_string(message, "application_id");
        const char *identifierCString =
            xpc_dictionary_get_string(message, "identifier");
        NSString *appID = appCString
            ? [NSString stringWithUTF8String:appCString] : nil;
        NSString *identifierString = identifierCString
            ? [NSString stringWithUTF8String:identifierCString] : nil;
        NSUUID *identifier = identifierString.length
            ? [[NSUUID alloc] initWithUUIDString:identifierString] : nil;
        BOOL validRequest = appID.length > 0 && appID.length <= 255 &&
            [appID rangeOfString:@"/"].location == NSNotFound &&
            identifier != nil;
        BOOL success = authorized && validRequest &&
            CRWriteDeviceVendorIdentifier(identifier, appID);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", success);
        if (authorized && !validRequest) {
            xpc_dictionary_set_string(reply, "error_description",
                "Invalid application or vendor identifier");
        } else if (authorized && validRequest && !success) {
            xpc_dictionary_set_string(reply, "error_description",
                "LSD device identifier service unavailable");
        }
    } else if (strcmp(operation, "move_keychain_items") == 0) {
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        const char *appCString =
            xpc_dictionary_get_string(message, "application_id");
        const char *sourceCString =
            xpc_dictionary_get_string(message, "source_container_id");
        const char *destinationCString =
            xpc_dictionary_get_string(message, "destination_container_id");
        NSString *appID = appCString
            ? [NSString stringWithUTF8String:appCString] : nil;
        NSString *sourceContainer = sourceCString
            ? [NSString stringWithUTF8String:sourceCString] : nil;
        NSString *destinationContainer = destinationCString
            ? [NSString stringWithUTF8String:destinationCString] : nil;
        BOOL sourceValid = sourceContainer.length > 0 &&
            ([sourceContainer isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
             [[NSUUID alloc] initWithUUIDString:sourceContainer] != nil);
        BOOL destinationValid = destinationContainer.length > 0 &&
            ([destinationContainer isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
             [[NSUUID alloc] initWithUUIDString:destinationContainer] != nil);
        BOOL validRequest = appID.length > 0 && appID.length <= 255 &&
            [appID rangeOfString:@"/"].location == NSNotFound &&
            sourceValid && destinationValid;
        BOOL success = authorized && validRequest &&
            [CRHKeychain
                moveKeychainItemsFromContainerWithIdentifier:sourceContainer
                                   toContainerWithIdentifier:destinationContainer
                                forApplicationWithIdentifier:appID];
        NSLog(@"Crane helper: move keychain caller=%@ app=%@ source=%@ destination=%@ authorized=%d valid=%d success=%d",
              peerProcess, appID, sourceContainer, destinationContainer,
              authorized, validRequest, success);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", success);
        if (authorized && !validRequest)
            CRSetReplyError(reply, CRHelperInvalidRequest,
                            @"Invalid keychain move request");
        else if (authorized && validRequest && !success)
            CRSetReplyError(reply, CRHelperOperationFailed,
                            @"One or more keychain classes could not be moved");
    } else if (strcmp(operation, "delete_keychain_items") == 0) {
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        const char *appCString =
            xpc_dictionary_get_string(message, "application_id");
        const char *containerCString =
            xpc_dictionary_get_string(message, "container_id");
        NSString *appID = appCString
            ? [NSString stringWithUTF8String:appCString] : nil;
        NSString *containerID = containerCString
            ? [NSString stringWithUTF8String:containerCString] : nil;
        BOOL containerValid = containerID.length > 0 &&
            ([containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
             [[NSUUID alloc] initWithUUIDString:containerID] != nil);
        BOOL validRequest = appID.length > 0 && appID.length <= 255 &&
            [appID rangeOfString:@"/"].location == NSNotFound &&
            containerValid;
        BOOL success = authorized && validRequest &&
            [CRHKeychain
                deleteKeychainItemsForContainerWithIdentifier:containerID
                                     forApplicationIdentifier:appID];
        NSLog(@"Crane helper: delete keychain caller=%@ app=%@ container=%@ authorized=%d valid=%d success=%d",
              peerProcess, appID, containerID, authorized, validRequest, success);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", success);
        if (authorized && !validRequest)
            CRSetReplyError(reply, CRHelperInvalidRequest,
                            @"Invalid keychain delete request");
        else if (authorized && validRequest && !success)
            CRSetReplyError(reply, CRHelperOperationFailed,
                            @"One or more keychain classes could not be deleted");
    } else if (strcmp(operation, "reload_application") == 0) {
        /* The caller supplies only a bundle identifier. The helper resolves
         * LSApplicationProxy -> canonicalExecutablePath -> live PID itself,
         * matching original reloadApplication: and preventing PID/path abuse. */
        BOOL authorized = compatible &&
            CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID);
        const char *appCString =
            xpc_dictionary_get_string(message, "application_id");
        NSString *appID = appCString
            ? [NSString stringWithUTF8String:appCString] : nil;
        BOOL validRequest = appID.length > 0 && appID.length <= 255 &&
            [appID rangeOfString:@"/"].location == NSNotFound;
        BOOL success = authorized && validRequest &&
            CRReloadApplication(appID);
        NSLog(@"Crane helper: reload_application caller=%@ app=%@ authorized=%d valid=%d success=%d",
              peerProcess, appID, authorized, validRequest, success);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", success);
        if (authorized && !validRequest) {
            xpc_dictionary_set_string(reply, "error_description",
                "Invalid application identifier");
        } else if (authorized && validRequest && !success) {
            xpc_dictionary_set_string(reply, "error_description",
                "Application executable path could not be resolved");
        }
    } else if (strcmp(operation, "reload_daemons") == 0) {
        /* Original CraneSB 0x1A53C is the recovered caller. Keep this
         * operation SpringBoard-only and intersect names with the helper's
         * fixed recovered allowlist before sending any signal. */
        BOOL authorized = compatible &&
            [peerProcess isEqualToString:@"SpringBoard"] &&
            [peerSigningID isEqualToString:@"com.apple.springboard"];
        xpc_object_t values = xpc_dictionary_get_value(message, "daemons");
        __block BOOL validRequest = values && xpc_get_type(values) == XPC_TYPE_ARRAY;
        NSMutableArray<NSString *> *requested = [NSMutableArray new];
        if (validRequest) {
            xpc_array_apply(values, ^bool(size_t index, xpc_object_t value) {
                (void)index;
                if (xpc_get_type(value) != XPC_TYPE_STRING) {
                    validRequest = NO;
                    return false;
                }
                const char *item = xpc_string_get_string_ptr(value);
                NSString *name = item
                    ? [NSString stringWithUTF8String:item] : nil;
                if (!name.length || name.length > 128) {
                    validRequest = NO;
                    return false;
                }
                [requested addObject:name];
                return true;
            });
        }
        NSArray<NSString *> *selected = authorized && validRequest
            ? CRReloadDaemons(requested) : nil;
        BOOL success = authorized && validRequest && selected != nil;
        NSLog(@"Crane helper: reload_daemons caller=%@ authorized=%d valid=%d selected=%@",
              peerProcess, authorized, validRequest, selected);
        xpc_dictionary_set_bool(reply, "authorized", authorized);
        xpc_dictionary_set_bool(reply, "success", success);
        if (selected.count) {
            NSString *summary = [selected componentsJoinedByString:@","];
            xpc_dictionary_set_string(reply, "reloaded_daemons",
                                      summary.UTF8String);
        }
        if (authorized && !validRequest) {
            xpc_dictionary_set_string(reply, "error_description",
                "Invalid daemon list");
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

        if (injectionVerified)
            CRActivateCrucialCraneSupportDaemons();

        NSArray<NSString *> *runningSupport =
            CRRunningCraneSupportProcesses();
        BOOL supportInspectionAvailable = runningSupport != nil;
        NSMutableArray<NSString *> *brokenSupport = [NSMutableArray new];
        for (NSString *process in runningSupport ?: @[]) {
            if (!CRRuntimeHasComponentInProcess(@"CraneSupport", process))
                [brokenSupport addObject:process];
        }

        /* Original helper verifies its exact crucial set after using
         * _execute:whileDaemon... to activate on-demand services. The ping
         * above reproduces that activation attempt; if a crucial daemon is
         * still absent, insurance remains fail-closed. */
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