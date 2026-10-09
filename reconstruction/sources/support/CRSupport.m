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
 *   * initAccountsd, initApsd, initLsd, initPkd and initContainermanagerd
 *     have since been transcribed into CRAccountsd.m, CRApsd.m, CRLsd.m,
 *     CRPkd.m and CRMCM.m;
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

extern void CRInitCfprefsd(void);

/* ------------------------------------------------------------------------- */
/* containermanagerd (0xCC88)                                                  */
/* ------------------------------------------------------------------------- */

extern void CRInitContainermanagerd(void);

extern void CRInitCraneProxy(void);

/* ------------------------------------------------------------------------- */
/* accountsd (0x7200)                                                          */
/* ------------------------------------------------------------------------- */

extern void CRInitAccountsd(void);

/* ------------------------------------------------------------------------- */
/* pkd (0xF2B4) / apsd (0x9C4C) / lsd (0xD7D8) / securityd (0x11E5C)           */
/* ------------------------------------------------------------------------- */

extern void CRInitPkd(void);

extern void CRInitApsd(void);

extern void CRInitLsd(void);

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