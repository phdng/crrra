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
 * What is NOT recovered: the XPC interface definition, the reply-block shapes,
 * and the implementations. The protocol below is therefore THIS project's own
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

#include <notify.h>
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
    return [[NSUserDefaults standardUserDefaults] objectForKey:key];
}

- (void)storePreferenceValue:(id)value forKey:(NSString *)key
{
    if (!key)
        return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (value)
        [defaults setObject:value forKey:key];
    else
        [defaults removeObjectForKey:key];
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
- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL works, NSString *brokenDaemons, NSError *error, BOOL connectionWorks))reply;
- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL loaded))reply;
- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid reply:(void (^)(NSString *containerID))reply;
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

- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL, NSString *, NSError *, BOOL))reply
{
    /* "Insurance" is Crane's self-check: CraneSupport.dylib must be present in
     * every daemon that participates in redirection, CraneSB.dylib in
     * SpringBoard, and the main dylib in the app. CONFIRMED_STATIC from
     * INJECTION_ERROR_MESSAGE / CRANE_DYLIB_NOT_LOADED_ERROR. */
    BOOL mainDylibExists = [[NSFileManager defaultManager]
                            fileExistsAtPath:CR_MAIN_DYLIB_FILTER_PLIST];
    BOOL libSandyWorks = CRIsDylibLoaded(CR_LIB_SANDY);
    BOOL works = mainDylibExists && libSandyWorks;

    NSMutableArray<NSString *> *broken = [NSMutableArray array];
    if (!mainDylibExists)
        [broken addObject:@" Crane.dylib"];
    if (!libSandyWorks)
        [broken addObject:@"libsandy"];

    NSString *description = [broken componentsJoinedByString:@", "];
    NSError *error = works ? nil :
        [NSError errorWithDomain:@"com.opa334.crane" code:1 userInfo:
            @{NSLocalizedDescriptionKey: description ?: @"Crane is not working"}];
    reply(works, description, error, YES);
}

- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL))reply
{
    /* [INFERRED] Upstream asks cranehelperd to inspect a live process. This
     * build has no inspector, so it answers conservatively. */
    reply(NO);
}

- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid reply:(void (^)(NSString *))reply
{
    reply(CR_DEFAULT_CONTAINER_IDENTIFIER);
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
    /* Crane 0x65EC reads CraneSupport's per-container identifier; the source of
     * truth is /var/db/lsd or the lsd daemon. */
    reply([[NSUserDefaults standardUserDefaults]
           stringForKey:[NSString stringWithFormat:@"crane_identifier.%@.%@.%llu",
                         bundleID, vendorName, type]]);
}

- (void)setIdentifier:(NSString *)identifier
                ofType:(uint64_t)type
        forVendorName:(NSString *)vendorName
    andBundleIdentifier:(NSString *)bundleID
{
    [[NSUserDefaults standardUserDefaults]
     setObject:identifier forKey:[NSString stringWithFormat:@"crane_identifier.%@.%@.%llu",
                                  bundleID, vendorName, type]];
}

- (void)dumpKeychainItemsForContainerIdentifier:(NSString *)containerID
                      forApplicationIdentifier:(NSString *)appID
                                         reply:(void (^)(NSDictionary *))reply
{
    reply(@{});
}

- (void)restoreKeychainItems:(NSDictionary *)items
 toContainerIdentifier:(NSString *)containerID
   forApplicationIdentifier:(NSString *)appID {}

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

- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL, NSString *, NSError *, BOOL))reply
{
    [self.delegate verifyCraneInsuranceAndReply:reply];
}

- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name reply:(void (^)(BOOL))reply
{
    [self.delegate verifySupportLoadedIntoProcessNamed:name reply:reply];
}

- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid reply:(void (^)(NSString *))reply
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

/* The two Mach listeners share one non-privileged request allowlist. */
static void CRHandleHealthPing(xpc_connection_t peer, xpc_object_t message)
{
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
        return;
    const char *operation = xpc_dictionary_get_string(message, "operation");
    if (!operation || strcmp(operation, "ping") != 0)
        return;
    /* A version match is compatibility checking, not client authorization. */
    const char *protocol = xpc_dictionary_get_string(message, "protocol");
    if (!protocol || strcmp(protocol, CR_HELPERD_PING_PROTOCOL_V1) != 0)
        return;
    xpc_object_t reply = xpc_dictionary_create_reply(message);
    if (!reply)
        return;
    xpc_dictionary_set_bool(reply, "alive", true);
    xpc_dictionary_set_string(reply, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    xpc_connection_send_message(peer, reply);
    /* ARC manages the XPC reply. This is not caller authentication. */
}

/* The iOS SDK marks xpc_connection_get_pid unavailable. Do not use
 * desktop-only credential APIs here; this ping-only listener makes no
 * authorization claim and must not expose privileged operations. */
static void CRAcceptHealthPeer(xpc_connection_t peer)
{
    xpc_connection_set_event_handler(peer, ^(xpc_object_t message) {
        if (xpc_get_type(message) == XPC_TYPE_ERROR) {
            xpc_connection_cancel(peer);
            return;
        }
        CRHandleHealthPing(peer, message);
    });
    xpc_connection_resume(peer);
}

#pragma mark - main

int main(int argc, char *argv[], char *envp[])
{
    @autoreleasepool {
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