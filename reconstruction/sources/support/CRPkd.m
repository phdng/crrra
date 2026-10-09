/*
 * CRPkd.m — CraneSupport pkd / PlugInKit isolation.
 *
 * Transcribed from CraneSupport 0xE888..0x10800 and initPkd 0xF2B4.
 * All private framework classes are resolved dynamically; only the recovered
 * Objective-C selector ABI is compiled here.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#import <dlfcn.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"

@interface NSObject (CranePkdRuntime)
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
+ (id)pluginKitProxyForIdentifier:(NSString *)identifier;
+ (id)server;

- (BOOL)isAppExtension;
- (NSURL *)containingUrl;
- (NSDictionary *)plugInDictionary;
- (NSDictionary *)pluginKitDictionary;
- (NSArray *)plugInKitPlugins;
- (id)getProxy;
- (xpc_object_t)request;

- (NSString *)crane_activeContainerID;
- (void)setCrane_activeContainerID:(NSString *)identifier;
- (void)crane_updateActiveContainerID:(NSString *)identifier;

- (void)terminatePlugIns:(NSArray *)plugIns
          synchronously:(BOOL)synchronously
                  reply:(dispatch_block_t)reply;
- (void)terminatePlugIns:(NSArray *)plugIns
                   reply:(dispatch_block_t)reply;
@end

static NSString *gCRPkdContainerID;
static id gCRPkdServer;

static IMP gOrigEnableFull;
static IMP gOrigEnableLanguages;
static IMP gOrigEnableOneShot;
static IMP gOrigEnableBasic;
static IMP gOrigMatchPlugIns;
static IMP gOrigFindPlugIns;
static IMP gOrigFindPlugInsUUID;
static IMP gOrigFindPlugInsUUIDAllVersions;
static IMP gOrigFindPlugInsForQuery;
static IMP gOrigPluginsMatchingQuery;
static IMP gOrigPKDServerInit;

static NSString *CRPkdActiveContainerID(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self, (const void *)&CRPkdActiveContainerID);
}

static void CRPkdSetActiveContainerID(id self, SEL _cmd, NSString *identifier)
{
    (void)_cmd;
    /* Original association policy is numeric 1 = RETAIN_NONATOMIC. */
    objc_setAssociatedObject(self,
                             (const void *)&CRPkdActiveContainerID,
                             identifier,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id CRPkdServerObject(void)
{
    Class serverClass = NSClassFromString(@"PKDServer");
    if (serverClass && [(id)serverClass respondsToSelector:@selector(server)])
        return [(id)serverClass server];
    return gCRPkdServer;
}

/* terminatePlugIns (0xE888). Converts PKDPlugIn values to their LSPlugInKit
 * proxies when possible, then asks PKDServer to terminate them. The recovered
 * reply blocks have signature v8@?0 (no arguments). */
static void CRPkdTerminatePlugIns(NSArray *plugIns, BOOL synchronously)
{
    if (plugIns.count == 0)
        return;

    NSMutableArray *proxies = [NSMutableArray new];
    for (id plugIn in plugIns) {
        NSString *className = NSStringFromClass([plugIn class]);
        if ([className isEqualToString:@"LSPlugInKitProxy"]) {
            [proxies addObject:plugIn];
        } else if ([className isEqualToString:@"PKDPlugIn"]) {
            if ([plugIn respondsToSelector:@selector(getProxy)]) {
                id proxy = [plugIn getProxy];
                if (proxy)
                    [proxies addObject:proxy];
            } else {
                [proxies addObject:plugIn];
            }
        }
    }

    id server = CRPkdServerObject();
    if (!server || proxies.count == 0)
        return;

    if ([server respondsToSelector:@selector(terminatePlugIns:synchronously:reply:)]) {
        [server terminatePlugIns:proxies synchronously:synchronously reply:^{}];
    } else if ([server respondsToSelector:@selector(terminatePlugIns:reply:)]) {
        if (synchronously) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            [server terminatePlugIns:proxies reply:^{
                dispatch_semaphore_signal(semaphore);
            }];
            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        } else {
            [server terminatePlugIns:proxies reply:^{}];
        }
    }
}

/* crane_updateActiveContainerID: (0xF638). Nil and DEFAULT are semantically
 * identical for comparison; a real change forces the currently running plug-in
 * instance down before its next launch receives the new environment. */
static void CRPkdUpdateActiveContainerID(id self, SEL _cmd, NSString *identifier)
{
    (void)_cmd;
    NSString *requested = identifier ?: CR_DEFAULT_CONTAINER_IDENTIFIER;
    NSString *current = [self crane_activeContainerID] ?: CR_DEFAULT_CONTAINER_IDENTIFIER;

    if (![current isEqualToString:requested]) {
        [self setCrane_activeContainerID:requested];
        CRPkdTerminatePlugIns(@[self], YES);
    }
}

/* reloadApplication (0xEC44). The distributed notification deliberately
 * excludes notification-service extensions; their lifecycle is container-aware
 * through crane_activeContainerID instead. */
static void CRPkdReloadApplication(CFNotificationCenterRef center,
                                   void *observer,
                                   CFStringRef name,
                                   const void *object,
                                   CFDictionaryRef userInfo)
{
    (void)center;
    (void)observer;
    (void)name;
    (void)object;

    NSDictionary *info = (__bridge NSDictionary *)userInfo;
    NSString *applicationIdentifier = info[@"applicationIdentifier"];
    if (!applicationIdentifier)
        return;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    id application = proxyClass
        ? [(id)proxyClass applicationProxyForIdentifier:applicationIdentifier]
        : nil;
    NSMutableArray *plugIns = [[application plugInKitPlugins] mutableCopy];
    if (!plugIns)
        return;

    for (id plugIn in [plugIns reverseObjectEnumerator]) {
        NSString *extensionPoint = [plugIn pluginKitDictionary][@"NSExtensionPointIdentifier"];
        if ([extensionPoint isEqualToString:@"com.apple.usernotifications.service"])
            [plugIns removeObject:plugIn];
    }

    CRPkdTerminatePlugIns(plugIns, NO);
}

typedef void (^CRPkdEnableContinuation)(NSDictionary *environment);

/* enableForClientHook (0xEEB0). For normal app extensions the active container
 * is looked up from the containing application. Notification-service
 * extensions use the PKDPlugIn's query-specific crane_activeContainerID. */
static void CRPkdEnableForClient(id plugIn,
                                 NSDictionary *environment,
                                 CRPkdEnableContinuation continuation)
{
    if (![plugIn isAppExtension]) {
        continuation(environment);
        return;
    }

    NSURL *containingURL = [plugIn containingUrl];
    if (!containingURL) {
        continuation(environment);
        return;
    }

    NSBundle *bundle = [NSBundle bundleWithURL:containingURL];
    NSString *applicationIdentifier = bundle.bundleIdentifier;
    NSString *extensionPoint =
        [plugIn plugInDictionary][@"NSExtensionPointIdentifier"];

    NSString *containerIdentifier = nil;
    if ([extensionPoint isEqualToString:@"com.apple.usernotifications.service"]) {
        containerIdentifier = [plugIn crane_activeContainerID];
    } else {
        containerIdentifier =
            [[CraneManager sharedManager]
                activeContainerIdentifierForApplicationWithIdentifier:applicationIdentifier];
    }

    if (!containerIdentifier) {
        continuation(environment);
        return;
    }

    NSMutableDictionary *updated = environment
        ? [environment mutableCopy]
        : [NSMutableDictionary new];
    updated[CR_ENV_CONTAINER_IDENTIFIER] = containerIdentifier;
    continuation(updated);
}

/* Four PKDPlugIn enableForClient variants. The original wrappers only replace
 * the environment argument and preserve every other argument verbatim. */
static BOOL CRPkdEnableFull(id self, SEL _cmd,
                            id client, NSDictionary *environment,
                            id languages, id oneShotUUID,
                            id persona, id sandbox,
                            int pid, id *error)
{
    __block BOOL result = NO;
    CRPkdEnableForClient(self, environment, ^(NSDictionary *updated) {
        BOOL (*original)(id, SEL, id, NSDictionary *, id, id, id, id, int, id *) =
            (BOOL (*)(id, SEL, id, NSDictionary *, id, id, id, id, int, id *))gOrigEnableFull;
        result = original(self, _cmd, client, updated, languages, oneShotUUID,
                          persona, sandbox, pid, error);
    });
    return result;
}

static BOOL CRPkdEnableLanguages(id self, SEL _cmd,
                                 id client, NSDictionary *environment,
                                 id languages, id oneShotUUID,
                                 int pid, id *error)
{
    __block BOOL result = NO;
    CRPkdEnableForClient(self, environment, ^(NSDictionary *updated) {
        BOOL (*original)(id, SEL, id, NSDictionary *, id, id, int, id *) =
            (BOOL (*)(id, SEL, id, NSDictionary *, id, id, int, id *))gOrigEnableLanguages;
        result = original(self, _cmd, client, updated, languages, oneShotUUID,
                          pid, error);
    });
    return result;
}

static BOOL CRPkdEnableOneShot(id self, SEL _cmd,
                               id client, NSDictionary *environment,
                               id oneShotUUID, int pid, id *error)
{
    __block BOOL result = NO;
    CRPkdEnableForClient(self, environment, ^(NSDictionary *updated) {
        BOOL (*original)(id, SEL, id, NSDictionary *, id, int, id *) =
            (BOOL (*)(id, SEL, id, NSDictionary *, id, int, id *))gOrigEnableOneShot;
        result = original(self, _cmd, client, updated, oneShotUUID, pid, error);
    });
    return result;
}

static id CRPkdEnableBasic(id self, SEL _cmd, id client, NSDictionary *environment)
{
    __block id result = nil;
    CRPkdEnableForClient(self, environment, ^(NSDictionary *updated) {
        id (*original)(id, SEL, id, NSDictionary *) =
            (id (*)(id, SEL, id, NSDictionary *))gOrigEnableBasic;
        result = original(self, _cmd, client, updated);
    });
    return result;
}

/* Transaction.matchPlugIns (0xFD70). Crane's private rule is consumed inside
 * pkd so the stock PlugInKit matcher never sees it. */
static void CRPkdMatchPlugIns(id self, SEL _cmd)
{
    xpc_object_t request = [self request];
    xpc_object_t rules = request
        ? xpc_dictionary_get_dictionary(request, "rules")
        : NULL;

    if (rules && xpc_get_type(rules) == XPC_TYPE_DICTIONARY) {
        const char *container = xpc_dictionary_get_string(rules, "crane_containerID");
        if (container) {
            gCRPkdContainerID = [NSString stringWithUTF8String:container];
            xpc_dictionary_set_value(rules, "crane_containerID", NULL);
            xpc_dictionary_set_value(request, "rules", rules);

            /* Recovered code materialises/free()s descriptions; no logging is
             * emitted, but preserve the side-effect-free calls. */
            char *rulesDescription = xpc_copy_description(rules);
            if (rulesDescription)
                free(rulesDescription);
            char *requestDescription = xpc_copy_description(request);
            if (requestDescription)
                free(requestDescription);
        }
    }

    void (*original)(id, SEL) = (void (*)(id, SEL))gOrigMatchPlugIns;
    original(self, _cmd);
}

typedef NSArray *(^CRPkdFindPlugInsContinuation)(void);

/* findPlugInsHook (0xF174). The query-scoped global is consumed exactly once,
 * attached to every returned PKDPlugIn, then cleared. */
static NSArray *CRPkdFindPlugIns(CRPkdFindPlugInsContinuation continuation)
{
    NSArray *result = continuation();
    NSString *containerIdentifier = gCRPkdContainerID;
    if (containerIdentifier) {
        for (id plugIn in result)
            [plugIn crane_updateActiveContainerID:containerIdentifier];
        gCRPkdContainerID = nil;
    }
    return result;
}

static id CRPkdFindPlugIns1(id self, SEL _cmd, id query)
{
    return CRPkdFindPlugIns(^NSArray *{
        id (*original)(id, SEL, id) = (id (*)(id, SEL, id))gOrigFindPlugIns;
        return original(self, _cmd, query);
    });
}

static id CRPkdFindPlugIns2(id self, SEL _cmd, id query, id discoveryUUID)
{
    return CRPkdFindPlugIns(^NSArray *{
        id (*original)(id, SEL, id, id) =
            (id (*)(id, SEL, id, id))gOrigFindPlugInsUUID;
        return original(self, _cmd, query, discoveryUUID);
    });
}

static id CRPkdFindPlugIns3(id self, SEL _cmd,
                            id query, id discoveryUUID, BOOL allVersions)
{
    return CRPkdFindPlugIns(^NSArray *{
        id (*original)(id, SEL, id, id, BOOL) =
            (id (*)(id, SEL, id, id, BOOL))gOrigFindPlugInsUUIDAllVersions;
        return original(self, _cmd, query, discoveryUUID, allVersions);
    });
}

static id CRPkdFindPlugInsForQuery(id self, SEL _cmd,
                                   id query, id discoveryUUID, BOOL allVersions)
{
    return CRPkdFindPlugIns(^NSArray *{
        id (*original)(id, SEL, id, id, BOOL) =
            (id (*)(id, SEL, id, id, BOOL))gOrigFindPlugInsForQuery;
        return original(self, _cmd, query, discoveryUUID, allVersions);
    });
}

/* 0x101CC. This special case is part of initPkd in the original and keeps the
 * Crane Shortcuts extension discoverable when stock PlugInKit returns none. */
static NSArray *CRPkdPluginsMatchingQuery(id self, SEL _cmd,
                                          NSDictionary *query, BOOL applyFilter)
{
    NSArray *(*original)(id, SEL, NSDictionary *, BOOL) =
        (NSArray *(*)(id, SEL, NSDictionary *, BOOL))gOrigPluginsMatchingQuery;
    NSArray *result = original(self, _cmd, query, applyFilter);
    if (result.count != 0)
        return result;

    id intentsSupported = query[@"IntentsSupported"];
    NSString *containingApp = query[@"NSExtensionContainingApp"];
    NSString *extensionPoint = query[@"NSExtensionPointName"];
    if (!intentsSupported ||
        !containingApp ||
        !extensionPoint ||
        ![containingApp containsString:@"/Applications/CraneApplication.app"] ||
        ![extensionPoint isEqualToString:@"com.apple.intents-service"]) {
        return result;
    }

    Class proxyClass = NSClassFromString(@"LSPlugInKitProxy");
    id proxy = proxyClass
        ? [(id)proxyClass
            pluginKitProxyForIdentifier:@"com.opa334.CraneApplication.CraneShortcuts"]
        : nil;
    return proxy ? @[proxy] : result;
}

static id CRPkdServerInit(id self, SEL _cmd,
                          id connection, id queue,
                          id database, id externalProviders)
{
    id (*original)(id, SEL, id, id, id, id) =
        (id (*)(id, SEL, id, id, id, id))gOrigPKDServerInit;
    id result = original(self, _cmd, connection, queue, database, externalProviders);
    gCRPkdServer = result;
    return result;
}

void CRInitPkd(void)
{
    Class transactionClass = NSClassFromString(@"Transaction");
    if (!transactionClass)
        transactionClass = NSClassFromString(@"PKDTransaction");

    Class plugInClass = NSClassFromString(@"PKDPlugIn");
    if (!plugInClass)
        return;

    objc_property_attribute_t attributes[] = {
        { "T", "@\"NSString\"" },
        { "&", "" },
        { "N", "" },
    };
    class_addProperty(plugInClass, "crane_activeContainerID", attributes, 3);
    class_addMethod(plugInClass,
                    @selector(crane_activeContainerID),
                    (IMP)CRPkdActiveContainerID,
                    "@@:");
    class_addMethod(plugInClass,
                    @selector(setCrane_activeContainerID:),
                    (IMP)CRPkdSetActiveContainerID,
                    "v@:@");
    class_addMethod(plugInClass,
                    @selector(crane_updateActiveContainerID:),
                    (IMP)CRPkdUpdateActiveContainerID,
                    "v@:@");

    MSHookMessageEx(
        plugInClass,
        NSSelectorFromString(@"enableForClient:environment:languages:oneShotUUID:persona:sandbox:pid:error:"),
        (IMP)CRPkdEnableFull,
        &gOrigEnableFull);
    MSHookMessageEx(
        plugInClass,
        NSSelectorFromString(@"enableForClient:environment:languages:oneShotUUID:pid:error:"),
        (IMP)CRPkdEnableLanguages,
        &gOrigEnableLanguages);
    MSHookMessageEx(
        plugInClass,
        NSSelectorFromString(@"enableForClient:environment:oneShotUUID:pid:error:"),
        (IMP)CRPkdEnableOneShot,
        &gOrigEnableOneShot);
    MSHookMessageEx(
        plugInClass,
        NSSelectorFromString(@"enableForClient:environment:"),
        (IMP)CRPkdEnableBasic,
        &gOrigEnableBasic);

    if (transactionClass) {
        MSHookMessageEx(transactionClass,
                        NSSelectorFromString(@"matchPlugIns"),
                        (IMP)CRPkdMatchPlugIns,
                        &gOrigMatchPlugIns);
    }

    Class databaseClass = NSClassFromString(@"PKDatabase");
    if (databaseClass) {
        MSHookMessageEx(databaseClass,
                        NSSelectorFromString(@"findPlugIns:"),
                        (IMP)CRPkdFindPlugIns1,
                        &gOrigFindPlugIns);
        MSHookMessageEx(databaseClass,
                        NSSelectorFromString(@"findPlugIns:discoveryInstanceUUID:"),
                        (IMP)CRPkdFindPlugIns2,
                        &gOrigFindPlugInsUUID);
        MSHookMessageEx(databaseClass,
                        NSSelectorFromString(@"findPlugIns:discoveryInstanceUUID:allVersions:"),
                        (IMP)CRPkdFindPlugIns3,
                        &gOrigFindPlugInsUUIDAllVersions);
        MSHookMessageEx(databaseClass,
                        NSSelectorFromString(@"findPlugInsForQuery:discoveryInstanceUUID:allVersions:"),
                        (IMP)CRPkdFindPlugInsForQuery,
                        &gOrigFindPlugInsForQuery);
    }

    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (workspaceClass) {
        MSHookMessageEx(workspaceClass,
                        NSSelectorFromString(@"pluginsMatchingQuery:applyFilter:"),
                        (IMP)CRPkdPluginsMatchingQuery,
                        &gOrigPluginsMatchingQuery);
    }

    typedef CFNotificationCenterRef (*CRGetDistributedCenterFn)(void);
    CRGetDistributedCenterFn getDistributedCenter =
        (CRGetDistributedCenterFn)dlsym(RTLD_DEFAULT,
                                        "CFNotificationCenterGetDistributedCenter");
    if (getDistributedCenter) {
        CFNotificationCenterRef center = getDistributedCenter();
        if (center) {
            CFNotificationCenterAddObserver(
                center,
                NULL,
                CRPkdReloadApplication,
                CFSTR("com.opa334.crane/ReloadApplication"),
                CFSTR("ReloadApplication"),
                CFNotificationSuspensionBehaviorDeliverImmediately);
        }
    }

    Class serverClass = NSClassFromString(@"PKDServer");
    if (serverClass && ![(id)serverClass respondsToSelector:@selector(server)]) {
        MSHookMessageEx(
            serverClass,
            NSSelectorFromString(@"initWithConnection:queue:database:externalProviders:"),
            (IMP)CRPkdServerInit,
            &gOrigPKDServerInit);
    }
}
