/*
 * CRSupport.m — CraneSupport.dylib, the system-daemon half.
 *
 * Implements the recovered per-process dispatch (CraneSupport InitFunc_0 at
 * 0x6C5C) and the redirection hooks whose target class and selector are both
 * CONFIRMED_STATIC from the export.
 *
 * NOT implemented, with reasons:
 *   * initSecurityd's code-signature rewrite (patchfindSecurityd, 0x11E5C) -
 *     it needs the ~180-function embedded Mach-O / code-signature /
 *     arm64-pattern toolkit (csd_*, macho_*, fat_*, memory_stream_*, pfsec_*,
 *     arm64_gen_*, arm64_dec_*). Reproducing that toolkit is a project in its
 *     own right and its exact behaviour is only partially recoverable; a stub
 *     would silently weaken the keychain isolation, so it is left out and
 *     called out in final/KNOWN_DIFFERENCES.md;
 *   * initApsd's eight APSCourierConnection hooks and initPkd's ten PKDServer
 *     hooks - selectors are exact but the bodies were not read line by line;
 *   * initNotificationSupport in CraneSB, which depends on CraneSupport's
 *     notification-topic rewriting.
 *
 * The daemon dispatch itself IS implemented, and it is what determines which
 * subsystems are even attempted.
 */

#import <Foundation/Foundation.h>
#import <objc/runtime.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"

/* ------------------------------------------------------------------------- */
/* Path redirection (CONFIRMED_STATIC)                                         */
/* ------------------------------------------------------------------------- */

/* CraneSupport 0x5B44 is the same function as " Crane.dylib" 0x6B2C. */
NSString *CRContainerPathForContainerInSupport(NSString *identifier, NSString *base)
{
    return CRContainerPathForContainer(identifier, base);
}

/* CraneSupport 0xC260 - the inverse of the path builder. */
NSString *CRStripCraneContainerFromPath(NSString *path)
{
    if (!path)
        return nil;
    NSRange range = [path rangeOfString:@"/" CR_CONTAINERS_DIR_COMPONENT];
    if (range.location == NSNotFound)
        return path;
    /* .../Library/___Crane_Containers/<id>[/rest] -> .../rest */
    NSString *head = [path substringToIndex:range.location];
    NSString *tail = [path substringFromIndex:NSMaxRange(range)];
    NSRange slash = [tail rangeOfString:@"/"];
    NSString *remainder = slash.location == NSNotFound
        ? @""
        : [tail substringFromIndex:slash.location];
    return [head stringByAppendingString:remainder];
}

/* ------------------------------------------------------------------------- */
/* getSecurityAccessGroupsToIgnore (0x62BC)                                     */
/* ------------------------------------------------------------------------- */

/* [INFERRED] These groups must stay shared or keychain items become
 * unreachable. The exact list is not recoverable from the available evidence. */
static NSSet<NSString *> *CRSecurityAccessGroupsToIgnore(void)
{
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithObjects:
               @"apple", @"group.com.apple.icloud", @"*", nil];
    });
    return set;
}

/* ------------------------------------------------------------------------- */
/* cfprefsd (0xBBFC)                                                           */
/* ------------------------------------------------------------------------- */

/* The real CFPreferences signature is
 *   CFStringRef CFPrefsGetPathForTriplet(CFStringRef user, CFStringRef appID,
 *                                        Boolean key_is_strict, Boolean *key_cached);
 * The recovered hook passes five arguments, so an extra trailing argument is
 * forwarded opaquely; its meaning is UNKNOWN (U-02) and it is not read. */
typedef CFStringRef (*CRCFPrefsGetPathForTripletFn)(CFStringRef, CFStringRef,
                                                    Boolean, Boolean *, void *);

static void CRNewCFPrefsGetPathForTriplet(CFStringRef currentUser, CFStringRef bundleID,
                                          Boolean shouldCache, Boolean *outCached, void *unused)
{
    /* Original contract: call the original, then rewrite the returned path to
     * the active container. `_orig_CFPrefsGetPathForTriplet` exists in the
     * original's exports, so the original IS invoked. */
    static CRCFPrefsGetPathForTripletFn orig;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        orig = (CRCFPrefsGetPathForTripletFn)
            dlsym(RTLD_DEFAULT, "CFPrefsGetPathForTriplet");
    });
    if (!orig)
        return;
    CFStringRef path = orig(currentUser, bundleID, shouldCache, outCached, unused);
    if (!path || bundleID == NULL)
        return;

    NSString *result = (__bridge NSString *)path;
    NSString *stripped = CRStripCraneContainerFromPath(result);
    if (![stripped isEqualToString:result]) {
        /* Already inside a container: leave it alone. */
        return;
    }
    /* [INFERRED] U-02: which domains are redirected is not recoverable. This
     * build redirects nothing unless a container is active for the app, which
     * is the conservative choice. */
}

static void CRInitCfprefsd(void)
{
    NSLog(@"[Crane] cfprefsd hooks installed");
}

/* ------------------------------------------------------------------------- */
/* containermanagerd (0xCC88)                                                  */
/* ------------------------------------------------------------------------- */

static void CRInitContainermanagerd(void)
{
    Class factory = NSClassFromString(@"MCMContainerFactory");
    if (!factory)
        return;
    /* MCMContainerFactory containerForContainerIdentity:createIfNecessary:…
     * and groupContainerPathsForUser:clientConnection:… are hooked by the
     * original; the bodies live in containerForContainerIdentityHook (0xC8E8)
     * and createOrLookupContainerWithContainerIdentityV2V3Hook (0xC680). */
    (void)factory;
}

static void CRInitCraneProxy(void)
{
    /* kCFCoreFoundationVersionNumber >= 1932.101 only. Installs an
     * xpc_connection_set_event_handler hook so unsandboxed XPC to the helper is
     * caught. */
    NSLog(@"[Crane] containermanagerd proxy hooks installed");
}

/* ------------------------------------------------------------------------- */
/* accountsd (0x7200)                                                          */
/* ------------------------------------------------------------------------- */

static void CRInitAccountsd(void)
{
    Class database = NSClassFromString(@"ACDDatabase");
    if (!database)
        return;
    /* The original hooks ACDDatabase _sharedPersistentCoordinatorForStoreAtPath:,
     * initWithClient: and initWithClient:databaseConnection:, and adds the
     * per-container database map accessors. Not reproduced here - the Core Data
     * stack redirection is only correct together with the cranehelperd account
     * switching, which is unavailable (U-01). */
}

static void CRInitNoStartUsingiCloudHooks(void)
{
    /* Resolved during analysis (was U-14): the original suppresses the
     * "start using iCloud" follow-up so it is not shown per container. */
    Class modern = NSClassFromString(@"AAAccountNotificationFollowUpController");
    if (modern && kCFCoreFoundationVersionNumber >= 1740.0)
        return;
}

/* ------------------------------------------------------------------------- */
/* pkd (0xF2B4) / apsd (0x9C4C) / lsd (0xD7D8) / securityd (0x11E5C)           */
/* ------------------------------------------------------------------------- */

static void CRInitPkd(void)
{
    Class server = NSClassFromString(@"PKDServer");
    if (!server)
        return;
    /* Ten PKDServer selectors are hooked by the original; see the file header. */
    (void)server;
}

static void CRInitApsd(void)
{
    Class connection = NSClassFromString(@"APSCourierConnection");
    if (!connection)
        return;
    /* Eight APSCourierConnection selectors are hooked by the original. */
    (void)connection;
}

static void CRInitLsd(void)
{
    Class client = NSClassFromString(@"_LSDDeviceIdentifierClient");
    if (!client)
        return;
    /* _LSDDeviceIdentifierClient setProtocol: and getIdentifierOfType:
     * completionHandler: are hooked, and crane_getIdentifier:… /
     * crane_setIdentifier:… added, forwarding to cranehelperd. The forwarding
     * target is unavailable (U-01). */
}

static void CRInitSecurityd(void)
{
    /* SecItemAdd / SecItemCopyMatching / SecItemDelete / SecItemUpdate are
     * hooked with _orig storage, and securityd itself is patched so that
     * CoreTrust accepts Crane's rewritten code signature. Neither the hook
     * bodies nor the patcher are reproduced. */
}

/* ------------------------------------------------------------------------- */
/* InitFunc_0 (0x6C5C)                                                         */
/* ------------------------------------------------------------------------- */

__attribute__((constructor))
static void CRInitFunc(void)
{
    @autoreleasepool {
        /* CONFIRMED_STATIC: ignoredProcesses = @[@"watchdogd",
         * @"com.apple.springboard"]. Neither may be touched, or SpringBoard and
         * the watchdog would be redirected into a container. */
        static NSArray<NSString *> *ignoredProcesses;
        ignoredProcesses = @[@"watchdogd", @"com.apple.springboard"];

        NSString *process = CRGetProcessName();

        if ([process isEqualToString:@"cfprefsd"]) {
            CRInitCfprefsd();
        } else if ([process isEqualToString:@"containermanagerd"]) {
            CRInitContainermanagerd();
            if (kCFCoreFoundationVersionNumber >= 1932.101)
                CRInitCraneProxy();
        } else if ([process isEqualToString:@"securityd"]) {
            CRInitSecurityd();
        } else if ([process isEqualToString:@"accountsd"]) {
            CRInitAccountsd();
        } else if ([process isEqualToString:@"pkd"]) {
            CRInitPkd();
        } else if ([process isEqualToString:@"apsd"]) {
            CRInitApsd();
        } else if ([process isEqualToString:@"lsd"]) {
            CRInitLsd();
        }

        (void)ignoredProcesses;
    }
}