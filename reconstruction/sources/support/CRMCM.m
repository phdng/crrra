/*
 * CRMCM.m — CraneSupport containermanagerd redirection.
 *
 * Transcribed from CraneSupport:
 *   redirectedURLForURL                         0xC2BC
 *   redirectedContainerPathCopyForContainerPath 0xC3E4
 *   xpc_connection_set_event_handler_hook_11_12 0xC54C
 *   createOrLookupContainer...V2V3Hook          0xC680
 *   containerForContainerIdentityHook           0xC8E8
 *   initContainermanagerd                        0xCC88
 *   wrappers / setCorrupt / group paths          0xCE44..0xD2BC
 *   ClientContainerCache                         0x125BC..0x12FBC
 *
 * Private MobileContainerManager classes/selectors are resolved dynamically.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#import <stdint.h>
#import <stdlib.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"

@interface NSObject (CraneMCMRuntime)
- (id)clientIdentity;
- (pid_t)posixPID;

- (id)containerPath;
- (NSURL *)url;
- (id)containerRootComponent;
- (id)containerDataComponent;
- (NSURL *)containerRootURL;
- (NSURL *)containerDataURL;
- (id)containerPathIdentifier;

- (id)copyWithZone:(NSZone *)zone;
- (uint64_t)containerClass;
- (uint32_t)platform;
- (id)userIdentity;
- (BOOL)transient;
- (BOOL)existed;
- (id)info;
- (id)uuid;
- (id)identifier;
- (id)userManagedAssetsDirName;
- (uint64_t)dataProtectionClass;
- (id)schemaVersion;

- (void)setTransient:(BOOL)value;
- (void)setExisted:(BOOL)value;
- (void)setInfo:(id)value;
- (void)setUuid:(id)value;
- (void)setIdentifier:(id)value;
- (void)setUserManagedAssetsDirName:(id)value;
- (void)setUrl:(NSURL *)value;
- (void)setDataProtectionClass:(uint64_t)value;
- (void)setSchemaVersion:(id)value;
- (void)setContainerPath:(id)value;
@end

@interface CraneManager (CraneMCMPrivateSurface)
- (void)_populateContainerDirectory:(NSString *)path ofType:(NSUInteger)type;
@end

/* ------------------------------------------------------------------------- */
/* ClientContainerCache — exact local cache semantics, adapted transport      */
/* ------------------------------------------------------------------------- */

@interface ClientContainerCache : NSObject {
    id _daemonCenter;
    NSMutableDictionary<NSNumber *, NSString *> *_activeContainerCache;
    dispatch_queue_t _activeContainerCacheQueue;
}
+ (instancetype)sharedInstance;
- (NSString *)activeContainerIdentifierForPid:(pid_t)pid;
- (NSString *)_getActiveContainerFromCacheForPid:(pid_t)pid;
- (void)_setActiveContainer:(NSString *)identifier toCacheForPid:(pid_t)pid;
- (void)_clearActiveContainerCache;
- (void)_registerForClearMessages;
@end

static void CRClearActiveContainerCache(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo)
{
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;
    [[ClientContainerCache sharedInstance] _clearActiveContainerCache];
}

@implementation ClientContainerCache

+ (instancetype)sharedInstance
{
    static ClientContainerCache *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    self = [super init];
    if (!self)
        return nil;

    dispatch_queue_attr_t attributes =
        dispatch_queue_attr_make_with_qos_class(NULL,
                                                QOS_CLASS_USER_INITIATED,
                                                -1);
    _activeContainerCacheQueue =
        dispatch_queue_create("activeContainerCacheQueue", attributes);
    [self _clearActiveContainerCache];
    [self _registerForClearMessages];
    return self;
}

- (void)_registerForClearMessages
{
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        CRClearActiveContainerCache,
        CFSTR("com.opa334.cranesb/Loaded"),
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (NSString *)_getActiveContainerFromCacheForPid:(pid_t)pid
{
    __block NSString *result = nil;
    dispatch_sync(_activeContainerCacheQueue, ^{
        result = self->_activeContainerCache[@(pid)];
    });
    return result;
}

- (void)_setActiveContainer:(NSString *)identifier toCacheForPid:(pid_t)pid
{
    if (!identifier)
        return;
    dispatch_async(_activeContainerCacheQueue, ^{
        self->_activeContainerCache[@(pid)] = identifier;
    });
}

- (void)_clearActiveContainerCache
{
    dispatch_sync(_activeContainerCacheQueue, ^{
        self->_activeContainerCache = [NSMutableDictionary new];
    });
}

- (NSString *)activeContainerIdentifierForPid:(pid_t)pid
{
    if (pid == 0)
        return nil;

    NSString *cached = [self _getActiveContainerFromCacheForPid:pid];
    if ([cached isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return nil;
    if (cached)
        return cached;

    /*
     * Original 0x12A4C reaches cranehelperd through
     * cranehelperdGlobalSyncRemoteObjectProxy inside runSafeXPCBlock:, then
     * falls back to a containermanagerd proxy message on one XPC error.
     * libcrane's original connection internals are unavailable (U-01), while
     * the reconstructed manager already exposes the same fetch selector.
     * Use that selector as the transport boundary without inventing PID lookup.
     */
    __block NSString *fetched = nil;
    __block BOOL replied = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

    [[CraneManager sharedManager]
        fetchActiveContainerIDForProcessWithPid:pid
        reply:^(NSString *identifier) {
            fetched = identifier;
            replied = YES;
            dispatch_semaphore_signal(semaphore);
        }];

    if (!replied) {
        dispatch_time_t timeout =
            dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC);
        (void)dispatch_semaphore_wait(semaphore, timeout);
    }

    if (!replied)
        return nil;

    NSString *normalized = fetched ?: CR_DEFAULT_CONTAINER_IDENTIFIER;
    [self _setActiveContainer:normalized toCacheForPid:pid];
    return [normalized isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]
        ? nil
        : normalized;
}

@end

/* ------------------------------------------------------------------------- */
/* Redirection helpers                                                        */
/* ------------------------------------------------------------------------- */

static void CRMCMPopulateContainerDirectoryIfAvailable(NSString *path)
{
    if (!path)
        return;

    CraneManager *manager = [CraneManager sharedManager];
    SEL selector = NSSelectorFromString(@"_populateContainerDirectory:ofType:");
    if ([manager respondsToSelector:selector])
        [manager _populateContainerDirectory:path ofType:1];
}

static NSURL *CRMCMRedirectedURL(NSURL *url, NSString *containerIdentifier)
{
    if (!url || !containerIdentifier)
        return url;

    NSString *redirectedPath =
        CRContainerPathForContainer(containerIdentifier, url.path);
    if (!redirectedPath)
        return url;

    CRMCMPopulateContainerDirectoryIfAvailable(redirectedPath);
    return [NSURL fileURLWithPath:redirectedPath isDirectory:YES];
}

static id CRMCMRedirectedContainerPathCopy(id containerPath,
                                           NSString *containerIdentifier)
{
    if (!containerPath)
        return nil;

    id copy = [containerPath copyWithZone:nil];
    if (!copy)
        return containerPath;

    id pathIdentifier = [containerPath containerPathIdentifier];
    [copy setValue:pathIdentifier forKey:@"_containerPathIdentifier"];

    NSURL *rootURL =
        CRMCMRedirectedURL([containerPath containerRootURL], containerIdentifier);
    NSURL *dataURL =
        CRMCMRedirectedURL([containerPath containerDataURL], containerIdentifier);

    [copy setValue:rootURL forKey:@"_containerRootURL"];
    [copy setValue:dataURL forKey:@"_containerDataURL"];
    return copy;
}

static id CRMCMMetadataCopy(id metadata)
{
    if (!metadata)
        return nil;

    if ([metadata respondsToSelector:@selector(copyWithZone:)])
        return [metadata copyWithZone:nil];

    Class metadataClass = NSClassFromString(@"MCMMetadata");
    id copy = metadataClass ? [[metadataClass alloc] init] : nil;
    if (!copy)
        return metadata;

    BOOL hasURL = [metadata respondsToSelector:@selector(url)];

    [copy setValue:@([metadata containerClass]) forKey:@"_containerClass"];
    if (!hasURL)
        [copy setValue:@([metadata platform]) forKey:@"_platform"];

    [copy setValue:[metadata userIdentity] forKey:@"_userIdentity"];
    [copy setTransient:[metadata transient]];
    [copy setExisted:[metadata existed]];
    [copy setInfo:[metadata info]];
    [copy setUuid:[metadata uuid]];

    id identifier = [metadata identifier];
    if ([copy respondsToSelector:@selector(setIdentifier:)])
        [copy setIdentifier:identifier];
    else
        [copy setValue:identifier forKey:@"_identifier"];

    [copy setUserManagedAssetsDirName:[metadata userManagedAssetsDirName]];

    if (hasURL) {
        [copy setUrl:[metadata url]];
    } else {
        [copy setDataProtectionClass:[metadata dataProtectionClass]];
        [copy setSchemaVersion:[metadata schemaVersion]];
        [copy setContainerPath:[metadata containerPath]];
    }

    return copy;
}

static NSString *CRMCMActiveContainerForClient(id client)
{
    id identity = [client clientIdentity];
    pid_t pid = identity ? [identity posixPID] : 0;
    if (pid == 0)
        return nil;
    return [[ClientContainerCache sharedInstance]
        activeContainerIdentifierForPid:pid];
}

/* ------------------------------------------------------------------------- */
/* Modern MCMContainerFactory hooks                                            */
/* ------------------------------------------------------------------------- */

static IMP gOrigFactoryWithUpdate;
static IMP gOrigFactoryNoUpdate;
static IMP gOrigSetCorrupt;

static id CRMCMRedirectModernContainer(id client,
                                       id identity,
                                       id (^callOriginal)(void))
{
    id result = callOriginal();
    if (!identity || !result)
        return result;

    id clientIdentity = [client clientIdentity];
    if (!clientIdentity || [clientIdentity posixPID] == 0)
        return result;

    id path = [result containerPath];
    if (!path)
        return result;

    NSString *active = CRMCMActiveContainerForClient(client);
    if (!active)
        return result;

    id copy = [result copy];

    id copyPath = [copy containerPath];
    id rootComponent = [copyPath containerRootComponent];
    NSString *redirectedRoot =
        CRContainerPathForContainer(active, rootComponent);
    [copyPath setValue:redirectedRoot forKey:@"_containerRootComponent"];

    copyPath = [copy containerPath];
    id dataComponent = [copyPath containerDataComponent];
    NSString *redirectedData =
        CRContainerPathForContainer(active, dataComponent);
    [copyPath setValue:redirectedData forKey:@"_containerDataComponent"];

    /*
     * Original calls _populateContainerDirectory:ofType: after rewriting.
     * The libcrane body is unavailable; preserve the selector call only when
     * the reconstructed manager supplies it.
     */
    NSString *dataPath = [[[result containerPath] containerDataURL] path];
    CRMCMPopulateContainerDirectoryIfAvailable(dataPath);
    return copy;
}

static id CRMCMFactoryWithUpdate(id self, SEL _cmd,
                                 id identity,
                                 BOOL createIfNecessary,
                                 BOOL updateLinks,
                                 id *callerError)
{
    (void)callerError;
    return CRMCMRedirectModernContainer(self, identity, ^id {
        id localError = nil;
        id (*original)(id, SEL, id, BOOL, BOOL, id *) =
            (id (*)(id, SEL, id, BOOL, BOOL, id *))gOrigFactoryWithUpdate;
        return original(self,
                        _cmd,
                        identity,
                        createIfNecessary,
                        updateLinks,
                        &localError);
    });
}

static id CRMCMFactoryNoUpdate(id self, SEL _cmd,
                               id identity,
                               BOOL createIfNecessary,
                               id *callerError)
{
    (void)callerError;
    return CRMCMRedirectModernContainer(self, identity, ^id {
        id localError = nil;
        id (*original)(id, SEL, id, BOOL, id *) =
            (id (*)(id, SEL, id, BOOL, id *))gOrigFactoryNoUpdate;
        return original(self, _cmd, identity, createIfNecessary, &localError);
    });
}

static void CRMCMSetCorrupt(id self, SEL _cmd, BOOL corrupt)
{
    id containerPath = [self containerPath];
    id root = [containerPath containerRootComponent];
    BOOL isCranePath =
        [root respondsToSelector:@selector(containsString:)] &&
        [root containsString:@"/___Crane_Containers/"];

    void (*original)(id, SEL, BOOL) =
        (void (*)(id, SEL, BOOL))gOrigSetCorrupt;
    original(self, _cmd, corrupt && !isCranePath);
}

/* ------------------------------------------------------------------------- */
/* Legacy MCMClientConnection hooks                                            */
/* ------------------------------------------------------------------------- */

static IMP gOrigCreateLookupWithUpdate;
static IMP gOrigCreateLookupNoUpdate;

static id CRMCMRedirectLegacyMetadata(id client,
                                      id identity,
                                      id result)
{
    if (!identity || !result)
        return result;

    id clientIdentity = [client clientIdentity];
    if (!clientIdentity || [clientIdentity posixPID] == 0)
        return result;

    BOOL usesContainerPath = NSClassFromString(@"MCMContainerPath") != nil;
    id pathOrURL = usesContainerPath
        ? [result containerPath]
        : [result url];
    if (!pathOrURL)
        return result;

    NSString *active = CRMCMActiveContainerForClient(client);
    if (!active)
        return result;

    id copy = CRMCMMetadataCopy(result);
    if (usesContainerPath) {
        id redirected =
            CRMCMRedirectedContainerPathCopy([result containerPath], active);
        [copy setContainerPath:redirected];
    } else {
        NSURL *redirected = CRMCMRedirectedURL([result url], active);
        [copy setUrl:redirected];
    }
    return copy;
}

static id CRMCMCreateLookupWithUpdate(id self, SEL _cmd,
                                      id identity,
                                      BOOL createIfNecessary,
                                      BOOL transient,
                                      BOOL useLocking,
                                      BOOL updateLinks,
                                      id *error)
{
    id (*original)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, id *) =
        (id (*)(id, SEL, id, BOOL, BOOL, BOOL, BOOL, id *))
            gOrigCreateLookupWithUpdate;
    id result = original(self,
                         _cmd,
                         identity,
                         createIfNecessary,
                         transient,
                         useLocking,
                         updateLinks,
                         error);
    return CRMCMRedirectLegacyMetadata(self, identity, result);
}

static id CRMCMCreateLookupNoUpdate(id self, SEL _cmd,
                                    id identity,
                                    BOOL createIfNecessary,
                                    BOOL transient,
                                    BOOL useLocking,
                                    id *error)
{
    id (*original)(id, SEL, id, BOOL, BOOL, BOOL, id *) =
        (id (*)(id, SEL, id, BOOL, BOOL, BOOL, id *))
            gOrigCreateLookupNoUpdate;
    id result = original(self,
                         _cmd,
                         identity,
                         createIfNecessary,
                         transient,
                         useLocking,
                         error);
    return CRMCMRedirectLegacyMetadata(self, identity, result);
}

/* ------------------------------------------------------------------------- */
/* Old MCMGroupManager + xpc event-handler path                                */
/* ------------------------------------------------------------------------- */

static IMP gOrigGroupContainerPaths;
static pid_t gCRMCMCurrentPid;

typedef void (^CRXPCEventHandler)(xpc_object_t event);
typedef void (*CRXPCSetEventHandlerFn)(xpc_connection_t connection,
                                       CRXPCEventHandler handler);
typedef pid_t (*CRXPCConnectionGetPidFn)(xpc_connection_t connection);
static CRXPCSetEventHandlerFn gOrigXPCSetEventHandler;

static pid_t CRMCMConnectionPid(xpc_connection_t connection)
{
    static CRXPCConnectionGetPidFn getPid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getPid = (CRXPCConnectionGetPidFn)
            dlsym(RTLD_DEFAULT, "xpc_connection_get_pid");
    });
    return getPid ? getPid(connection) : 0;
}

static void CRMCMXPCSetEventHandler(xpc_connection_t connection,
                                    CRXPCEventHandler handler)
{
    CRXPCEventHandler wrapped = ^(xpc_object_t event) {
        if (event && xpc_get_type(event) == XPC_TYPE_CONNECTION) {
            gCRMCMCurrentPid = CRMCMConnectionPid((xpc_connection_t)event);
            char *description = xpc_copy_description(event);
            if (description)
                free(description);
        }
        if (handler)
            handler(event);
    };

    gOrigXPCSetEventHandler(connection, wrapped);
}

static id CRMCMGroupContainerPaths(id self, SEL _cmd,
                                   id user,
                                   id clientConnection,
                                   id identifier,
                                   id *error)
{
    id (*original)(id, SEL, id, id, id, id *) =
        (id (*)(id, SEL, id, id, id, id *))gOrigGroupContainerPaths;
    NSDictionary *paths =
        original(self, _cmd, user, clientConnection, identifier, error);

    if (!identifier || paths.count == 0)
        return paths;

    NSString *active =
        [[ClientContainerCache sharedInstance]
            activeContainerIdentifierForPid:gCRMCMCurrentPid];
    if (!active)
        return paths;

    NSMutableDictionary *redirected = [NSMutableDictionary new];
    for (id key in paths) {
        NSString *path = paths[key];
        NSString *newPath = CRContainerPathForContainer(active, path);
        if (newPath)
            redirected[key] = newPath;
    }
    return redirected;
}

/* ------------------------------------------------------------------------- */
/* Modern containermanagerd Crane proxy (0x68C0 / 0x69DC / 0x6C40)           */
/* ------------------------------------------------------------------------- */

typedef struct {
    uint32_t val[8];
} CRAuditToken;

typedef void (*CRXPCGetAuditTokenFn)(xpc_connection_t connection,
                                     CRAuditToken *token);
typedef xpc_connection_t (*CRXPCDictionaryGetRemoteConnectionFn)(xpc_object_t dictionary);
typedef CFTypeRef (*CRSecTaskCreateWithAuditTokenFn)(CFAllocatorRef allocator,
                                                     CRAuditToken token);
typedef CFStringRef (*CRSecTaskCopySigningIdentifierFn)(CFTypeRef task,
                                                        CFErrorRef *error);

static BOOL CRMCMIsCraneSupportDaemon(xpc_connection_t connection)
{
    if (!connection)
        return NO;

    static CRXPCGetAuditTokenFn getAuditToken;
    static CRSecTaskCreateWithAuditTokenFn createTask;
    static CRSecTaskCopySigningIdentifierFn copySigningIdentifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getAuditToken = (CRXPCGetAuditTokenFn)
            dlsym(RTLD_DEFAULT, "xpc_connection_get_audit_token");
        createTask = (CRSecTaskCreateWithAuditTokenFn)
            dlsym(RTLD_DEFAULT, "SecTaskCreateWithAuditToken");
        copySigningIdentifier = (CRSecTaskCopySigningIdentifierFn)
            dlsym(RTLD_DEFAULT, "SecTaskCopySigningIdentifier");
    });

    if (!getAuditToken || !createTask || !copySigningIdentifier)
        return NO;

    CRAuditToken token = {0};
    getAuditToken(connection, &token);

    CFTypeRef task = createTask(kCFAllocatorDefault, token);
    if (!task)
        return NO;

    CFStringRef signingIdentifier = copySigningIdentifier(task, NULL);
    CFRelease(task);
    if (!signingIdentifier)
        return NO;

    NSArray<NSString *> *allowed = @[
        @"com.apple.cfprefsd",
        @"com.apple.securityd",
        @"com.apple.pluginkit.pkd",
        @"com.apple.lsd",
        @"com.apple.accountsd",
        @"com.apple.apsd",
    ];
    BOOL result = [allowed containsObject:(__bridge NSString *)signingIdentifier];
    CFRelease(signingIdentifier);
    return result;
}

static CRXPCSetEventHandlerFn gOrigProxyXPCSetEventHandler;

static void CRMCMProxyEventHandler(xpc_object_t event,
                                   CRXPCEventHandler originalHandler)
{
    if (!event || xpc_get_type(event) != XPC_TYPE_DICTIONARY) {
        if (originalHandler)
            originalHandler(event);
        return;
    }

    char *description = xpc_copy_description(event);
    if (description)
        free(description);

    if (!xpc_dictionary_get_bool(event, "crane_isProxyMessage")) {
        if (originalHandler)
            originalHandler(event);
        return;
    }

    static CRXPCDictionaryGetRemoteConnectionFn getRemoteConnection;
    static dispatch_once_t remoteOnce;
    dispatch_once(&remoteOnce, ^{
        getRemoteConnection = (CRXPCDictionaryGetRemoteConnectionFn)
            dlsym(RTLD_DEFAULT, "xpc_dictionary_get_remote_connection");
    });
    xpc_connection_t remote = getRemoteConnection
        ? getRemoteConnection(event)
        : NULL;
    if (!CRMCMIsCraneSupportDaemon(remote)) {
        if (originalHandler)
            originalHandler(event);
        return;
    }

    pid_t pid = (pid_t)xpc_dictionary_get_int64(event, "crane_checkPid");
    NSString *active =
        [[ClientContainerCache sharedInstance]
            activeContainerIdentifierForPid:pid];

    xpc_object_t reply = xpc_dictionary_create_reply(event);
    if (reply) {
        if (active)
            xpc_dictionary_set_string(reply,
                                      "crane_containerID",
                                      active.UTF8String);
        xpc_connection_send_message(remote, reply);
    }
}

static void CRMCMProxyXPCSetEventHandler(xpc_connection_t connection,
                                         CRXPCEventHandler handler)
{
    if (!connection) {
        gOrigProxyXPCSetEventHandler(connection, handler);
        return;
    }

    char *description = xpc_copy_description(connection);
    BOOL isContainerManager =
        description && strstr(description,
                              " name = com.apple.containermanagerd") != NULL;

    if (!isContainerManager) {
        if (description)
            free(description);
        gOrigProxyXPCSetEventHandler(connection, handler);
        return;
    }

    CRXPCEventHandler wrapped = ^(xpc_object_t event) {
        CRMCMProxyEventHandler(event, handler);
    };
    gOrigProxyXPCSetEventHandler(connection, wrapped);
    free(description);
}

void CRInitCraneProxy(void)
{
    MSHookFunction((void *)&xpc_connection_set_event_handler,
                   (void *)CRMCMProxyXPCSetEventHandler,
                   (void **)&gOrigProxyXPCSetEventHandler);
}

/* ------------------------------------------------------------------------- */
/* initContainermanagerd (0xCC88)                                             */
/* ------------------------------------------------------------------------- */

void CRInitContainermanagerd(void)
{
    Class clientClass = NSClassFromString(@"MCMClientConnection");
    Class factoryClass = NSClassFromString(@"MCMContainerFactory");

    SEL factoryWithUpdate =
        NSSelectorFromString(
            @"containerForContainerIdentity:createIfNecessary:updateLinks:error:");
    SEL factoryNoUpdate =
        NSSelectorFromString(
            @"containerForContainerIdentity:createIfNecessary:error:");

    if (factoryClass &&
        ([factoryClass instancesRespondToSelector:factoryWithUpdate] ||
         [factoryClass instancesRespondToSelector:factoryNoUpdate])) {
        /* Original installs both once either modern factory variant is present. */
        MSHookMessageEx(factoryClass,
                        factoryWithUpdate,
                        (IMP)CRMCMFactoryWithUpdate,
                        &gOrigFactoryWithUpdate);
        MSHookMessageEx(factoryClass,
                        factoryNoUpdate,
                        (IMP)CRMCMFactoryNoUpdate,
                        &gOrigFactoryNoUpdate);

        Class cacheEntryClass = NSClassFromString(@"MCMContainerCacheEntry");
        if (cacheEntryClass) {
            MSHookMessageEx(cacheEntryClass,
                            NSSelectorFromString(@"setCorrupt:"),
                            (IMP)CRMCMSetCorrupt,
                            &gOrigSetCorrupt);
        }
        return;
    }

    SEL createWithUpdate =
        NSSelectorFromString(
            @"createOrLookupContainerWithContainerIdentity:createIfNecessary:"
             "transient:useLocking:updateLinks:withError:");
    if (clientClass &&
        [clientClass instancesRespondToSelector:createWithUpdate]) {
        MSHookMessageEx(clientClass,
                        createWithUpdate,
                        (IMP)CRMCMCreateLookupWithUpdate,
                        &gOrigCreateLookupWithUpdate);
        return;
    }

    SEL createNoUpdate =
        NSSelectorFromString(
            @"createOrLookupContainerWithContainerIdentity:createIfNecessary:"
             "transient:useLocking:withError:");
    if (clientClass &&
        [clientClass instancesRespondToSelector:createNoUpdate]) {
        MSHookMessageEx(clientClass,
                        createNoUpdate,
                        (IMP)CRMCMCreateLookupNoUpdate,
                        &gOrigCreateLookupNoUpdate);
        return;
    }

    Class groupManagerClass = NSClassFromString(@"MCMGroupManager");
    if (groupManagerClass) {
        MSHookMessageEx(
            groupManagerClass,
            NSSelectorFromString(
                @"groupContainerPathsForUser:clientConnection:identifier:withError:"),
            (IMP)CRMCMGroupContainerPaths,
            &gOrigGroupContainerPaths);
    }

    MSHookFunction((void *)&xpc_connection_set_event_handler,
                   (void *)CRMCMXPCSetEventHandler,
                   (void **)&gOrigXPCSetEventHandler);
}
