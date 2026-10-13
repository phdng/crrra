/*
 * CRSupport.m — CraneSupport.dylib, the system-daemon half.
 *
 * Implements the recovered per-process dispatch (CraneSupport InitFunc_0 at
 * 0x6C5C) and the redirection hooks whose target class and selector are both
 * CONFIRMED_STATIC from the export.
 *
 * Keychain isolation is transcribed in CRSecurityd.m for the normal 0x11E5C
 * symbol-resolution path. Original 0x11C08 patchfinding remains unported.
 * Remaining partial/unimplemented work:
 *   * securityd private-symbol fallback (patchfindSecurityd, 0x11C08) -
 *     it needs the embedded Mach-O / arm64 pattern-scanning toolkit;
 *     the normal five-symbol path and keychain transformations are ported.
 *     A missing symbol therefore leaves F-07 unavailable rather than partly
 *     hooked, which avoids inconsistent Add/Read/Delete/Update isolation.
 *
 *
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
    /* CraneSupport 0xC260: split at the full marker and return firstObject;
     * the original does not preserve a trailing container-relative path. */
    return [[path componentsSeparatedByString:
        @"/" CR_CONTAINERS_DIR_COMPONENT] firstObject];
}

/* ------------------------------------------------------------------------- */
/* getSecurityAccessGroupsToIgnore (0x62BC)                                     */
/* ------------------------------------------------------------------------- */

/* CONFIRMED_STATIC: exact CraneSupport 0x62FC list.
 * These Apple groups deliberately remain shared. */
static NSSet<NSString *> *CRSecurityAccessGroupsToIgnore(void)
{
    static NSSet *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithObjects:
               @"com.apple.token", @"com.apple.certificates",
               @"com.apple.identities", @"apple", @"com.apple.cfnetwork",
               @"com.apple.ProtectedCloudStorage", @"com.apple.passd",
               @"com.apple.managed.vpn.shared", nil];
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
extern void CRInstallSecuritydHooks(void);

static void CRInitSecurityd(void)
{
    /* SecItemAdd / SecItemCopyMatching / SecItemDelete / SecItemUpdate and
     * securityd_xpc_dictionary_handler are hooked with _orig storage. Their bodies
     *
     * are implemented in CRSecurityd.m; the original private-symbol
     * patchfinder fallback remains unported. */
    CRInstallSecuritydHooks();
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
        CRReportRuntimeInjection(@"CraneSupport", nil);

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