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
#include <stdlib.h>
#include <xpc/xpc.h>

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

static NSArray<NSString *> *CRRunningCraneSupportProcesses(void)
{
    /* Original 0x1B45C receives broken daemons from cranehelperd, while the
     * helper implementation itself is U-01. For reconstruction insurance,
     * inspect only currently-running filter targets so an absent on-demand
     * daemon does not become a false injection failure. This is read-only. */
    static CRProcListPidsFn procListPids;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *handle = dlopen("/usr/lib/libproc.dylib", RTLD_LAZY);
        procListPids = (CRProcListPidsFn)dlsym(
            handle ?: RTLD_DEFAULT, "proc_listpids");
    });
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
 * health, runtime attestation, and caller-authorized PID inspection only. */
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
        strcmp(operation, "component_loaded") != 0)
        return nil;

    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply)
        return nil;

    if (strcmp(operation, "insurance") == 0) {
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
        /* An empty running-target set is not accepted as proof. At least one
         * recovered CraneSupport target is expected on a live iOS system. */
        BOOL supportComplete = supportInspectionAvailable &&
            runningSupport.count > 0 && brokenSupport.count == 0;
        NSString *brokenSupportString =
            [brokenSupport componentsJoinedByString:@", "];

        NSLog(@"Crane helper: insurance caller=%@ authorized=%d preflight=%d supportInspect=%d running=%lu supportComplete=%d broken=%@",
              peerProcess, injectionVerified, preflight,
              supportInspectionAvailable, (unsigned long)runningSupport.count,
              supportComplete, brokenSupportString);

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