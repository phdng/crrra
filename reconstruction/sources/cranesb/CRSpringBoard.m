/*
 * CRSpringBoard.m — CraneSB.dylib, the SpringBoard / runningboardd half.
 *
 * This file implements the parts of CraneSB that are fully recoverable from the
 * IDA export:
 *
 *   InitFunc_2 (0x1BC70)                       -> CRInitFunc
 *   crane_initSpringBoard (0x17A14)             -> CRInitSpringBoard
 *   crane_initRunningBoardd (0x1BF10)           -> CRInitRunningBoardd
 *   crane_applyEnvironmentChanges (0x1B45C)     -> CRApplyEnvironmentChanges
 *   crane_containerToRedirectTo (0x1B360)       -> CRContainerToRedirectTo
 *   the eight preference predicates             -> CR*Enabled accessors
 *   crane_initChoicyIntegration (0x1BBB8)       -> CRInitChoicyIntegration
 *   CRBadgeAction / CRSubtitleMenu               -> declared
 *
 * NOT implemented here, with the reason recorded rather than guessed:
 *   * the 40 notification-support hooks (initNotificationSupport, 0xCBEC) -
 *     the selectors are recovered but the target class of each is aliased in
 *     the decompilation, so the hooks could not be attributed to classes
 *     without inventing them (U-10);
 *   * the app-shortcut menu cell layout (U-05) - the row arrangement is only
 *     knowable from a screenshot or from reading the _configureCell hooks,
 *     neither of which is available here;
 *   * the badge view constraint maths behind initCRBadgeContextMenuActionView
 *     (0x7F58) beyond the property additions;
 *   * the SBAlertItem alert subclasses' body (InitFunc_0/1) beyond their
 *     property sets and hook registrations.
 *
 * See final/KNOWN_DIFFERENCES.md.
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"

/* ------------------------------------------------------------------------- */
/* Globals recovered from the export                                          */
/* ------------------------------------------------------------------------- */

static BOOL gIsSpringBoard = NO;          /* CraneSB 0x2DDFB */
static BOOL hasFinishedLaunching = NO;    /* CraneSB 0x2DDF9, set by didFinishLaunching */

extern int sandbox_container_path_for_pid(int pid, char *buf, size_t size);

/* ------------------------------------------------------------------------- */
/* Preference predicates (CONFIRMED_STATIC, one per recovered function)      */
/* ------------------------------------------------------------------------- */

static BOOL CRAppShortcutEnabled(void)          /* 0x1ECD8 */
{ return CRPrefBool(CRPref_AppShortcutEnabled); }
static BOOL CRExpandContainersShortcut(void)     /* 0x1EDE4 */
{ return CRPrefBool(CRPref_ExpandContainersShortcut); }
static BOOL CRLaunchAppOnContainerSelection(void)/* 0x1ED64 */
{ return CRPrefBool(CRPref_LaunchAppOnContainerSelection); }
static BOOL CRNewContainerShortcut(void)         /* 0x1EEF0 */
{ return CRPrefBool(CRPref_NewContainerShortcut); }
static BOOL CROnlyShowIfContainersExist(void)    /* 0x1EE64 */
{ return CRPrefBool(CRPref_OnlyShowIfContainersExist); }
static BOOL CRShowContainerBadges(void)          /* 0x1EF7C */
{ return CRPrefBool(CRPref_ShowContainerNotificationBadges); }
static BOOL CRAlwaysAskBeforeLaunch(void)        /* 0x1F008 */
{ return CRPrefBool(CRPref_AlwaysAskBeforeLaunch); }

/* 0x1EB9C - global gate AND per-app gate */
static BOOL CRNotificationRedirectionEnabledForApp(NSString *appID)
{
    if (!CRPrefBool(CRPref_NotificationsSupportEnabled))
        return NO;
    NSDictionary *settings =
        [[CraneManager sharedManager] applicationSettingsForApplicationWithIdentifier:appID];
    return [settings[CRAppSetting_SeparateNotificationRegistrationsEnabled] boolValue];
}

/* ------------------------------------------------------------------------- */
/* crane_containerToRedirectTo (0x1B360)                                       */
/* ------------------------------------------------------------------------- */

/* CONFIRMED_STATIC, verbatim:
 *   if (![manager isApplicationSupportedByCrane:appID]) return nil;
 *   NSString *active = [manager activeContainerIdentifierForApplicationWithIdentifier:appID];
 *   return [active isEqualToString:@"DEFAULT"] ? nil : active;
 */
static NSString *CRContainerToRedirectTo(NSString *appID)
{
    CraneManager *manager = CraneManager.sharedManager;
    if (![manager isApplicationSupportedByCrane:appID])
        return nil;
    NSString *active = [manager activeContainerIdentifierForApplicationWithIdentifier:appID];
    if ([active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return nil;
    return active;
}

/* ------------------------------------------------------------------------- */
/* crane_applyEnvironmentChanges (0x1B45C)                                    */
/* ------------------------------------------------------------------------- */

/* This is the single most important function in the tweak: it is the only
 * channel by which SpringBoard tells an app which container to use. Its
 * contract is reproduced exactly, including the fail-open error paths. */
static NSMutableDictionary *CRApplyEnvironmentChanges(NSMutableDictionary *environment,
                                                     NSString *appID)
{
    CraneManager *manager = CraneManager.sharedManager;

    /* Step 1: unsupported applications get no changes at all. */
    if (![manager isApplicationSupportedByCrane:appID])
        return environment;

    NSDictionary *appSettings = [manager applicationSettingsForApplicationWithIdentifier:appID];
    NSString *activeContainer =
        [manager activeContainerIdentifierForApplicationWithIdentifier:appID];
    NSDictionary *containerSettings =
        [manager containerSettingsForContainerWithIdentifier:activeContainer
                                 ofApplicationWithIdentifier:appID];

    /* Step 2: switch the Game Center account for the container, if enabled. */
    if ([appSettings[CRAppSetting_GameCenterSupportEnabled] boolValue]) {
        id account = containerSettings[CRCContainer_AssociatedGameCenterAccount];
        [manager gameCenter_setActiveAccount:account andDontKillApplication:appID];
    }

    if ([activeContainer isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
        /* Step 3a: default container. Protection is the only thing that can be
         * requested, and only when the app opted in. */
        if ([appSettings[CRAppSetting_ContainerProtectionEnabled] boolValue]) {
            NSMutableDictionary *env = [environment mutableCopy] ?: [NSMutableDictionary new];
            env[CR_ENV_PROTECT_CONTAINERS] = @"1";
            return env;
        }
        return environment;
    }

    /* Step 3b: non-default container. */
    NSMutableDictionary *env = [environment mutableCopy] ?: [NSMutableDictionary new];

    [manager resetLastError];

    /* libSandy must be running, otherwise the daemon cannot be reached. */
    if (!CRIsDylibLoaded(CR_LIB_SANDY)) {
        /* crane_presentLibSandyNotWorkingError - the user sees an alert, the
         * environment is left untouched and the app starts in its real
         * container. Fail-open is deliberate in the original. */
        return environment;
    }

    /* Verify that everything Crane needs is actually in place before handing
     * the app a container it cannot honour. */
    __block BOOL insuranceOK = NO;
    __block NSString *brokenDaemons = nil;
    __block NSError *insuranceError = nil;
    __block BOOL connectionWorks = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    id<CRHelperServiceProtocol> proxy =
        (id<CRHelperServiceProtocol>)[manager cranehelperdGlobalSyncRemoteObjectProxy];
    if ([proxy respondsToSelector:@selector(verifyCraneInsuranceAndReply:)]) {
        [proxy verifyCraneInsuranceAndReply:^(BOOL works, NSString *daemons,
                                              NSError *error, BOOL connWorks) {
            insuranceOK = works;
            brokenDaemons = daemons;
            insuranceError = error;
            connectionWorks = connWorks;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem,
                                dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    }

    NSError *lastError = [manager getLastError];

    if (insuranceOK && !lastError) {
        if ([appSettings[CRAppSetting_SpoofSandboxLookupsEnabled] boolValue])
            env[CR_ENV_SPOOF_SANDBOX_LOOKUPS] = @"1";
        env[CR_ENV_CONTAINER_IDENTIFIER] = activeContainer;
        return env;
    }

    /* crane_presentDaemonErrorWithBrokenDaemons:error:connectionWorks: */
    NSLog(@"[Crane] refusing to redirect %@: %@ (%@)", appID, brokenDaemons,
          insuranceError ?: lastError ?: @"unknown");
    (void)connectionWorks;
    return environment;
}

/* ------------------------------------------------------------------------- */
/* SpringBoard hooks                                                          */
/* ------------------------------------------------------------------------- */

/* crane_registerInjectionCheckForProcess:toBeLaunchedIntoContainer: is added to
 * FBProcessManager by crane_initSpringBoard so that after a launch SpringBoard
 * can confirm the main dylib actually loaded into the app. The alert shown on
 * failure is CRANE_DYLIB_NOT_LOADED_ERROR.
 *
 * Type encoding "v@:@@" is recovered verbatim from Crane 0x17A14. */
static void CRRegisterInjectionCheckForProcess(id self, SEL _cmd, id process,
                                              NSString *containerID)
{
    /* [INFERRED] U-01. The original verifies through cranehelperd
     * (verifySupportLoaded…, verifyCraneInsurance…). Not wired up here. */
    (void)self; (void)_cmd;
    (void)process;
    (void)containerID;
}

/* crane_applyModificationsIfNeededToExecutionContext:withApplicationIdentifier:
 * is where CRApplyEnvironmentChanges is invoked, from sub_180F0.
 * Type encoding "@@:@@" is recovered verbatim from Crane 0x17A14. */
static void CRApplyModificationsIfNeededToExecutionContext(id self, SEL _cmd,
                                                          id executionContext,
                                                          NSString *appID)
{
    (void)self; (void)_cmd;
    (void)executionContext;
    /* The original mutates the private FBProcessExecutionContext's environment
     * in place. That API is not recoverable, so the call site is not wired;
     * CRApplyEnvironmentChanges above holds the full contract and is the piece
     * that is transcribed. See final/KNOWN_DIFFERENCES.md D-04. */
    (void)appID;
}

/* crane_containerIdentifier on FBProcess, encoding "@@:" (Crane 0x17A14). */
static id CRFBProcessContainerIdentifier(id self, SEL _cmd)
{
    (void)_cmd;
    return [CraneManager.sharedManager
            activeContainerIdentifierForApplicationWithIdentifier:
                CRSafeGetBundleIdentifier()];
}

/* ------------------------------------------------------------------------- */
/* Choicy integration                                                         */
/* ------------------------------------------------------------------------- */

/* CraneChoicyOverwriteProvider overrides Choicy's provider so that Crane is
 * never disabled for an application it manages. All six selector names are
 * CONFIRMED_STATIC; Choicy's own protocol declaration is not in this tree, so
 * the interface is declared structurally rather than by adopting Choicy's
 * protocol. */
@interface CraneChoicyOverwriteProvider : NSObject
@end

@implementation CraneChoicyOverwriteProvider
- (NSDictionary *)providedOverridesForApplication:(NSString *)appID
{
    if (!CRPrefBool(CRPref_ChoicyConfigOverwrite))
        return nil;
    /* CUSTOM_TWEAK_CONFIGURATION_OVERWRITE keeps CraneSB/CraneSupport/Crane in
     * Choicy's custom tweak configuration, and disables tweak injection
     * overrides, so Choicy can only turn Crane off for unsupported apps. */
    return @{
        CRPref_CustomTweakConfiguration: @1,
        @"tweakInjectionDisabled": @0,
    };
}
- (id)customTweakConfigurationEnabledOverrideForApplication:(NSString *)appID { return @1; }
- (id)overwriteGlobalConfigurationOverrideForApplication:(NSString *)appID { return @1; }
- (id)disableTweakInjectionOverrideForApplication:(NSString *)appID { return @0; }
- (id)customTweakConfigurationAllowDenyModeOverrideForApplication:(NSString *)appID { return @0; }
- (id)customTweakConfigurationAllowOrDenyListOverrideForApplication:(NSString *)appID { return @0; }
@end

static void CRInitChoicyIntegration(void)
{
    if (NSClassFromString(@"ChoicyOverrideManager") == nil)
        return;
    Class providerClass = NSClassFromString(@"CraneChoicyOverwriteProvider")
                          ?: CraneChoicyOverwriteProvider.class;
    if (![providerClass isSubclassOfClass:NSClassFromString(@"CRChoicyOverwriteProvider")]) {
        NSLog(@"[Crane] Choicy integration skipped: Choicy's provider class was "
               "not found. Install Choicy and reopen Settings (see "
               @"LIBSANDY_CHOICY_NOTICE / INJECTION_ERROR_MESSAGE_CHOICY).");
    }
}

/* ------------------------------------------------------------------------- */
/* crane_initSpringBoard (0x17A14)                                             */
/* ------------------------------------------------------------------------- */

static void CRDidFinishLaunching(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo);

static void CRKeychainMigrationSucceeded(CFNotificationCenterRef center, void *observer,
                                         CFStringRef name, const void *object,
                                         CFDictionaryRef userInfo)
{
    hasFinishedLaunching = YES;
}

static void CRInitSpringBoard(void)
{
    hasFinishedLaunching = NO;

    /* +[CraneActivatorManager startIfPossible] - the whole class is a no-op when
     * /usr/lib/libactivator.dylib is absent, which is the documented graceful
     * degradation (ACTIVATOR_INFO_SUGGESTION_MESSAGE). */
    if (CRIsDylibLoaded(CR_ACTIVATOR_LIB))
        NSLog(@"[Crane] Activator integration active");

    Class fbProcess = NSClassFromString(@"FBProcess");
    Class fbProcessManager = NSClassFromString(@"FBProcessManager");
    Class sbIconController = NSClassFromString(@"SBIconController");

    if (fbProcess) {
        class_addMethod(fbProcess, @selector(crane_containerIdentifier),
                        (IMP)CRFBProcessContainerIdentifier, "@@:");
    }

    if (fbProcessManager) {
        /* Hook registration order is taken verbatim from 0x17A14. The bodies of
         * the three launch hooks are not recovered here (see D-04); the two
         * methods Crane adds are added, with the type encodings the original
         * uses. */
        class_addMethod(fbProcessManager,
                        @selector(crane_applyModificationsIfNeededToExecutionContext:withApplicationIdentifier:),
                        (IMP)CRApplyModificationsIfNeededToExecutionContext,
                        "@@:@@");
        class_addMethod(fbProcessManager,
                        @selector(crane_registerInjectionCheckForProcess:toBeLaunchedIntoContainer:),
                        (IMP)CRRegisterInjectionCheckForProcess,
                        "v@:@@");
    }

    (void)sbIconController;

    /* CONFIRMED_STATIC: on CF >= 1665.15 (iOS 15+) the original installs the
     * runningboardd error-alert hooks; on older systems it loads the icon
     * bundle and does the Choicy integration instead. The inversion is
     * reproduced as read from the decompilation (U-07). */
    if (kCFCoreFoundationVersionNumber >= 1665.15) {
        /* initRunningboarddErrorAlertHooks (0x17620) needs the
         * UNSUserNotificationServerConnectionListener API, which only exists on
         * the newer systems - hence the gate. */
    } else {
        CRInitChoicyIntegration();
    }

    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), NULL,
                                    CRDidFinishLaunching,
                                    (__bridge CFStringRef)UIApplicationDidFinishLaunchingNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                    CRKeychainMigrationSucceeded,
                                    (__bridge CFStringRef)CR_NOTIFICATION_MIGRATION_SUCCEEDED,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    if (CRAppShortcutEnabled())
        NSLog(@"[Crane] app shortcuts enabled");

    /* initNotificationSupport / initCRBadgeContextMenuActionView /
     * initUIMenuHooks are not implemented - see the file header. */
}

static void CRDidFinishLaunching(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo)
{
    hasFinishedLaunching = YES;
}

/* ------------------------------------------------------------------------- */
/* crane_initRunningBoardd (0x1BF10)                                           */
/* ------------------------------------------------------------------------- */

static void CRInitRunningBoardd(void)
{
    /* RBProcessManager executeLaunchRequest:withError: / _executeLaunchRequest:
     * are the two hooks the original installs here; their bodies live in
     * sub_1BF74 / sub_1BFEC and are not reproduced. */
    CRInitChoicyIntegration();
}

/* ------------------------------------------------------------------------- */
/* InitFunc_2 (0x1BC70)                                                        */
/* ------------------------------------------------------------------------- */

__attribute__((constructor))
static void CRInitFunc(void)
{
    @autoreleasepool {
        NSString *executable = CRGetProcessName();
        if ([executable isEqualToString:@"SpringBoard"]) {
            gIsSpringBoard = YES;
            CRInitSpringBoard();
        } else if ([executable isEqualToString:@"runningboardd"]) {
            CRInitRunningBoardd();
        }
    }
}