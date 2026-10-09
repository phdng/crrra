/*
 * CRLsd.m — CraneSupport lsd / per-container device identifier isolation.
 *
 * Transcribed from CraneSupport:
 *   initLSDProtocol                                0x6390
 *   vendorIdentifierForNameAndBundleIdentifier    0xD6E8
 *   initLsd                                       0xD7D8
 *   NSXPCInterface setProtocol: hook              0xD8E4
 *   getIdentifierOfType:completionHandler: hook   0xD9A4
 *   crane_getIdentifier:...                       0xDC94 / 0xE51C
 *   crane_setIdentifier:...                       0xE0F4 / 0xE718
 *
 * Private LaunchServices classes/selectors are resolved dynamically.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <stdint.h>

#import "CRManager.h"
#import "CRPreferences.h"
#import "CRPaths.h"
#import "CRCommon.h"

@interface ClientContainerCache : NSObject
+ (instancetype)sharedInstance;
- (NSString *)activeContainerIdentifierForPid:(pid_t)pid;
@end

typedef struct {
    uint32_t val[8];
} CraneLSDAuditToken;

@interface NSXPCConnection (CraneLSDPrivate)
- (pid_t)processIdentifier;
- (CraneLSDAuditToken)auditToken;
@end

@interface NSObject (CraneLSDRuntime)
+ (id)sharedCache;
+ (id)sharedInstance;
+ (id)currentPersona;

- (NSXPCConnection *)XPCConnection;
- (id)cacheForPersona:(id)persona;
- (NSMutableDictionary *)identifiersOfTypeNotDispatched:(int64_t)type;
- (void)save;
@end

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

typedef CFTypeRef (*CraneLSDSecTaskCreateWithAuditTokenFn)(
    CFAllocatorRef allocator,
    CraneLSDAuditToken token);
typedef CFStringRef (*CraneLSDSecTaskCopySigningIdentifierFn)(
    CFTypeRef task,
    CFErrorRef *error);

static NSString *CraneLSDSigningIdentifierForConnection(NSXPCConnection *connection)
{
    if (!connection)
        return nil;

    static CraneLSDSecTaskCreateWithAuditTokenFn createTask;
    static CraneLSDSecTaskCopySigningIdentifierFn copySigningIdentifier;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        createTask = (CraneLSDSecTaskCreateWithAuditTokenFn)
            dlsym(RTLD_DEFAULT, "SecTaskCreateWithAuditToken");
        copySigningIdentifier = (CraneLSDSecTaskCopySigningIdentifierFn)
            dlsym(RTLD_DEFAULT, "SecTaskCopySigningIdentifier");
    });

    if (!createTask || !copySigningIdentifier)
        return nil;

    CraneLSDAuditToken token = [connection auditToken];
    CFTypeRef task = createTask(kCFAllocatorDefault, token);
    if (!task)
        return nil;

    CFStringRef identifier = copySigningIdentifier(task, NULL);
    CFRelease(task);
    return CFBridgingRelease(identifier);
}

/* ------------------------------------------------------------------------- */
/* Protocol extension                                                        */
/* ------------------------------------------------------------------------- */

static void CraneLSDInitProtocol(void)
{
    Protocol *additions =
        objc_getProtocol("_LSDDeviceIdentifierProtocolCraneAdditions");
    if (!additions) {
        additions =
            objc_allocateProtocol("_LSDDeviceIdentifierProtocolCraneAdditions");
        if (additions) {
            protocol_addMethodDescription(
                additions,
                NSSelectorFromString(
                    @"crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:"),
                "v@:@?q@@",
                YES,
                YES);
            protocol_addMethodDescription(
                additions,
                NSSelectorFromString(
                    @"crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:"),
                "v@:@q@@",
                YES,
                YES);
            objc_registerProtocol(additions);
        }
    }

    if (objc_getProtocol("_LSDDeviceIdentifierProtocolPlusCraneAdditions"))
        return;

    Protocol *plus =
        objc_allocateProtocol("_LSDDeviceIdentifierProtocolPlusCraneAdditions");
    if (!plus)
        return;

    additions =
        objc_getProtocol("_LSDDeviceIdentifierProtocolCraneAdditions");
    Protocol *base = objc_getProtocol("_LSDDeviceIdentifierProtocol");
    if (additions)
        protocol_addProtocol(plus, additions);
    if (base)
        protocol_addProtocol(plus, base);
    objc_registerProtocol(plus);
}

static IMP gOrigSetProtocol;

static void CraneLSDSetProtocol(id self, SEL _cmd, Protocol *protocol)
{
    Protocol *base = objc_getProtocol("_LSDDeviceIdentifierProtocol");
    Protocol *plus =
        objc_getProtocol("_LSDDeviceIdentifierProtocolPlusCraneAdditions");

    Protocol *effective = protocol;
    if (base && plus && protocol && protocol_isEqual(protocol, base))
        effective = plus;

    void (*original)(id, SEL, Protocol *) =
        (void (*)(id, SEL, Protocol *))gOrigSetProtocol;
    original(self, _cmd, effective);
}

/* ------------------------------------------------------------------------- */
/* Normal LSD getIdentifier spoof                                            */
/* ------------------------------------------------------------------------- */

static IMP gOrigGetIdentifier;

static void CraneLSDGetIdentifier(id self,
                                  SEL _cmd,
                                  int64_t type,
                                  void (^completion)(NSUUID *identifier))
{
    void (*original)(id, SEL, int64_t, id) =
        (void (*)(id, SEL, int64_t, id))gOrigGetIdentifier;

    if (type != 0) {
        original(self, _cmd, type, completion);
        return;
    }

    NSXPCConnection *connection = [self XPCConnection];
    pid_t pid = [connection processIdentifier];
    if (pid == 0) {
        original(self, _cmd, type, completion);
        return;
    }

    NSString *active =
        [[ClientContainerCache sharedInstance]
            activeContainerIdentifierForPid:pid];
    if (!active ||
        [active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
        original(self, _cmd, type, completion);
        return;
    }

    NSString *bundleIdentifier =
        CraneLSDSigningIdentifierForConnection(connection);
    if (!bundleIdentifier) {
        original(self, _cmd, type, completion);
        return;
    }

    NSDictionary *settings =
        [[CraneManager sharedManager]
            containerSettingsForContainerWithIdentifier:active
                           ofApplicationWithIdentifier:bundleIdentifier];

    NSString *custom = settings[@"customDeviceIdentifier"];
    NSNumber *useContainerIdentifier =
        settings[CRPref_UseContainerIdentifierAsDeviceID];
    if (!useContainerIdentifier)
        useContainerIdentifier = @YES;

    NSString *selected =
        (custom && !useContainerIdentifier.boolValue)
            ? custom
            : active;

    NSUUID *identifier =
        [[NSUUID alloc] initWithUUIDString:selected];
    if (completion)
        completion(identifier);
}

/* ------------------------------------------------------------------------- */
/* cranehelperd-only direct cache access                                     */
/* ------------------------------------------------------------------------- */

static NSString *CraneLSDVendorIdentifier(NSString *vendorName,
                                          NSString *bundleIdentifier)
{
    if (vendorName)
        return vendorName;
    if (!bundleIdentifier)
        return nil;

    NSRange range =
        [bundleIdentifier rangeOfString:@"."
                                options:NSBackwardsSearch];
    NSString *prefix =
        range.location == NSNotFound
            ? bundleIdentifier
            : [bundleIdentifier substringToIndex:range.location];
    return [@"BundleID:" stringByAppendingString:prefix];
}

static BOOL CraneLSDCallerIsHelperd(id client)
{
    NSXPCConnection *connection = [client XPCConnection];
    pid_t pid = [connection processIdentifier];
    if (pid <= 0)
        return NO;

    char buffer[4096] = {0};
    if (proc_pidpath(pid, buffer, sizeof(buffer)) <= 0)
        return NO;

    NSString *actual =
        [[[@(buffer) stringByResolvingSymlinksInPath]
            stringByStandardizingPath] copy];
    NSString *expected =
        [[[CRJailbreakRootPath(CR_HELPERD_BIN)
            stringByResolvingSymlinksInPath]
            stringByStandardizingPath] copy];

    return actual && expected && [actual isEqualToString:expected];
}

static id CraneLSDDeviceIdentifierCache(void)
{
    Class cacheClass = NSClassFromString(@"_LSDeviceIdentifierCache");
    if ([cacheClass respondsToSelector:NSSelectorFromString(@"sharedCache")])
        return [cacheClass sharedCache];

    Class managerClass = NSClassFromString(@"_LSDeviceIdentifierManager");
    id manager =
        [managerClass respondsToSelector:NSSelectorFromString(@"sharedInstance")]
            ? [managerClass sharedInstance]
            : nil;

    Class personaClass = NSClassFromString(@"UMUserPersona");
    id persona =
        [personaClass respondsToSelector:NSSelectorFromString(@"currentPersona")]
            ? [personaClass currentPersona]
            : nil;

    if (!manager || !persona)
        return nil;
    return [manager cacheForPersona:persona];
}

static void CraneLSDGetIdentifierForHelper(
    id self,
    SEL _cmd,
    void (^reply)(NSArray *identifiers),
    int64_t type,
    NSString *vendorName,
    NSString *bundleIdentifier)
{
    (void)_cmd;

    if (!reply)
        return;

    if (!CraneLSDCallerIsHelperd(self)) {
        reply(nil);
        return;
    }

    NSString *vendorIdentifier =
        CraneLSDVendorIdentifier(vendorName, bundleIdentifier);
    if (!vendorIdentifier) {
        reply(nil);
        return;
    }

    id cache = CraneLSDDeviceIdentifierCache();
    dispatch_queue_t queue =
        [cache valueForKey:@"_queue"];
    if (!cache || !queue) {
        reply(nil);
        return;
    }

    dispatch_async(queue, ^{
        NSMutableDictionary *identifiers =
            [cache identifiersOfTypeNotDispatched:type];
        NSDictionary *entry = identifiers[vendorIdentifier];
        if (!entry) {
            reply(nil);
            return;
        }

        id applications = entry[@"LSApplications"];
        if (![applications containsObject:bundleIdentifier]) {
            reply(nil);
            return;
        }

        id identifier = entry[@"LSVendorIdentifier"];
        reply(identifier ? @[identifier] : nil);
    });
}

static void CraneLSDSetIdentifierForHelper(
    id self,
    SEL _cmd,
    id identifier,
    int64_t type,
    NSString *vendorName,
    NSString *bundleIdentifier)
{
    (void)_cmd;

    if (!identifier || !CraneLSDCallerIsHelperd(self))
        return;

    NSString *vendorIdentifier =
        CraneLSDVendorIdentifier(vendorName, bundleIdentifier);
    if (!vendorIdentifier)
        return;

    id cache = CraneLSDDeviceIdentifierCache();
    dispatch_queue_t queue =
        [cache valueForKey:@"_queue"];
    if (!cache || !queue)
        return;

    dispatch_async(queue, ^{
        NSMutableDictionary *identifiers =
            [cache identifiersOfTypeNotDispatched:type];
        NSDictionary *entry = identifiers[vendorIdentifier];
        if (!entry)
            return;

        id applications = entry[@"LSApplications"];
        if (![applications containsObject:bundleIdentifier])
            return;

        NSMutableDictionary *updated = [entry mutableCopy];
        updated[@"LSVendorIdentifier"] = identifier;
        identifiers[vendorIdentifier] = [updated copy];
        [cache save];
    });
}

/* ------------------------------------------------------------------------- */
/* initLsd 0xD7D8                                                           */
/* ------------------------------------------------------------------------- */

void CRInitLsd(void)
{
    CraneLSDInitProtocol();

    Class interfaceClass = NSClassFromString(@"NSXPCInterface");
    if (interfaceClass) {
        MSHookMessageEx(interfaceClass,
                        NSSelectorFromString(@"setProtocol:"),
                        (IMP)CraneLSDSetProtocol,
                        &gOrigSetProtocol);
    }

    Class clientClass =
        NSClassFromString(@"_LSDDeviceIdentifierClient");
    if (!clientClass)
        return;

    MSHookMessageEx(
        clientClass,
        NSSelectorFromString(@"getIdentifierOfType:completionHandler:"),
        (IMP)CraneLSDGetIdentifier,
        &gOrigGetIdentifier);

    class_addMethod(
        clientClass,
        NSSelectorFromString(
            @"crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:"),
        (IMP)CraneLSDGetIdentifierForHelper,
        "v@:@?q@@");

    class_addMethod(
        clientClass,
        NSSelectorFromString(
            @"crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:"),
        (IMP)CraneLSDSetIdentifierForHelper,
        "v@:@q@@");
}
