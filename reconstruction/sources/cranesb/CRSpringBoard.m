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
 *   CRSubtitleMenu / modern application menus    -> CRMenuHooks.m
 *   CraneActivatorManager (0x1C4D4..0x1E284)     -> CRActivator.m
 *
 * NOT implemented here, with the reason recorded rather than guessed:
 *   * the 40 notification-support hooks (initNotificationSupport, 0xCBEC) -
 *     the selectors are recovered but the target class of each is aliased in
 *     the decompilation, so the hooks could not be attributed to classes
 *     without inventing them (U-10);
 *   * the application-shortcut UI for both the modern UIMenu path and the
 *     pre-UIMenu (iOS 11/12) force-touch path is transcribed in CRMenuHooks.m;
 *   * the badge view constraint maths behind initCRBadgeContextMenuActionView
 *     (0x7F58) beyond the property additions;
 *   * CRNewContainerAlert (InitFunc_1) remains incomplete; CRErrorAlert and
 *     the recovered self-verification error presenters live in CRErrorAlerts.m.
 *
 * See final/KNOWN_DIFFERENCES.md.
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#include <unistd.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"

@interface CraneActivatorManager : NSObject
+ (void)startIfPossible;
@end

extern void CRInitErrorAlerts(void);
extern void CRInitRunningboarddErrorAlertHooks(void);
extern void CRPresentLibSandyNotWorkingError(void);
extern void CRPresentDaemonError(id brokenDaemons, NSError *error,
                                 BOOL connectionWorks);
extern void CRPresentMainDylibNotLoadedError(NSString *appName);
extern void CRPresentApsdRegistrationError(NSString *appID);
extern void CRPresentPkdRegistrationError(NSString *appID);
extern void CRInitApplicationShortcutHooks(void);
extern void CRInitApplicationShortcutLateHooks(void);
extern void CRInitUIMenuHooks(void);
extern void CRBadgeStoreInitialize(void);
extern void CRInitBadgeListenerMethods(void);
extern void CRInitBadgeRepositoryHooks(void);

/* ------------------------------------------------------------------------- */
/* Globals recovered from the export                                          */
/* ------------------------------------------------------------------------- */

static BOOL gIsSpringBoard = NO;          /* CraneSB 0x2DDFB */
static BOOL hasFinishedLaunching = NO;    /* CraneSB 0x2DDF9, set by didFinishLaunching */
static BOOL keychainOutdated = NO;        /* CraneSB 0x2DDF8 */
NSError *CRInjectionFixupError = nil;     /* CraneSB 0x2DDF0 */

extern int sandbox_container_path_for_pid(int pid, char *buf, size_t size);

/* ------------------------------------------------------------------------- */
/* Preference predicates (CONFIRMED_STATIC, one per recovered function)      */
/* ------------------------------------------------------------------------- */

static BOOL CRAppShortcutEnabled(void)          /* 0x1ECD8 */
{
    /* Root.plist declares default=true. On a fresh installation, the key
     * may not be persisted yet; do not skip shortcut hook installation. */
    id value = [[CraneManager sharedManager]
        preferenceValueForKey:CRPref_AppShortcutEnabled];
    return value ? [value boolValue] : YES;
}
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
static BOOL CRAlwaysAskBeforeLaunch(NSString *appID) /* 0x1F008 */
{
    if (!appID.length)
        return NO;
    NSDictionary *settings = [CraneManager.sharedManager
        applicationSettingsForApplicationWithIdentifier:appID];
    id value = settings[CRAppSetting_AlwaysAskBeforeLaunchEnabled];
    return value ? [value boolValue] : NO;
}

/* 0x1EB9C - global gate AND per-app gate */
static BOOL CRNotificationRedirectionEnabledForApp(NSString *appID)
{
    if (!CRPrefBool(CRPref_NotificationsSupportEnabled))
        return NO;
    NSDictionary *settings =
        [[CraneManager sharedManager] applicationSettingsForApplicationWithIdentifier:appID];
    id separate = settings[CRAppSetting_SeparateNotificationRegistrationsEnabled];
    return separate ? [separate boolValue] : YES;
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
        /* 0x1B45C -> crane_presentLibSandyNotWorkingError. Fail-open is
         * deliberate: the launch environment remains untouched. */
        CRPresentLibSandyNotWorkingError();
        return environment;
    }

    /* Re-attest on every redirected launch so helperd restart cannot leave a
     * stale positive cache or permanently lose the live CraneSB proof. */
    CRReportRuntimeInjection(@"CraneSB", nil);

    /* Verify that everything Crane needs is actually in place before handing
     * the app a container it cannot honour. */
    __block BOOL insuranceOK = NO;
    __block NSArray<NSString *> *brokenDaemons = nil;
    __block NSError *insuranceError = nil;
    __block NSError *replyLastError = nil;
    __block BOOL helperReplied = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSObject *replyLock = [NSObject new];
    __block BOOL replyClosed = NO;

    id<CRHelperServiceProtocol> proxy =
        (id<CRHelperServiceProtocol>)[manager cranehelperdGlobalSyncRemoteObjectProxy];
    if (!proxy || ![proxy respondsToSelector:@selector(verifyCraneInsuranceAndReply:)]) {
        /* Defensive fail-closed guard: the reconstruction intentionally
         * exposes only a read-only adapter here, never assume a full NSXPC
         * helper surface exists or wait for an impossible reply. */
        insuranceError = [NSError errorWithDomain:@"com.opa334.crane"
            code:1001 userInfo:@{NSLocalizedDescriptionKey:
                @"Crane helper XPC insurance service is unavailable"}];
        NSLog(@"CraneSB: unable to verify container launch for %@: %@",
              appID, insuranceError.localizedDescription);
    } else {
        [proxy verifyCraneInsuranceAndReply:^(BOOL works, NSArray<NSString *> *daemons,
                                              NSError *error) {
            @synchronized(replyLock) {
                if (replyClosed) return;
                insuranceOK = works;
                brokenDaemons = daemons;
                insuranceError = error;
                replyLastError = [manager getLastError];
                helperReplied = YES;
                replyClosed = YES;
                dispatch_semaphore_signal(sem);
            }
        }];
        long waitResult = dispatch_semaphore_wait(sem,
                                dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
        @synchronized(replyLock) {
            if (waitResult != 0) insuranceOK = NO;
            replyClosed = YES;
        }
    }

    /* Snapshot the native getLastError classification in the reply scope;
     * other concurrent helper queries may finish while this thread wakes. */
    NSError *lastError = helperReplied ? replyLastError : [manager getLastError];

    /* CraneSB 0x1B45C gates injection on the insurance reply's works bit.
     * getLastError only helps classify a failed check for the error alert. */
    if (insuranceOK) {
        if ([appSettings[CRAppSetting_SpoofSandboxLookupsEnabled] boolValue])
            env[CR_ENV_SPOOF_SANDBOX_LOOKUPS] = @"1";
        env[CR_ENV_CONTAINER_IDENTIFIER] = activeContainer;
        return env;
    }

    /* 0x1B45C -> crane_presentDaemonError. Preserve fail-open launch
     * semantics after presenting the recovered user-visible failure. */
    /* In original CraneSB 0x1B45C, the final alert flag is !getLastError,
     * not a fourth argument of verifyCraneInsuranceAndReply:. */
    CRPresentDaemonError(brokenDaemons,
                         insuranceError ?: lastError,
                         lastError == nil);
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
/* The app-side constructor reports its PID/container through an independent
 * asynchronous XPC connection. On fast app launches the initial 0x19608
 * lookup can win that race. Retry ONLY a live, same-PID app when the helper
 * answered but has not yet received the app-side proof. Two 750ms retries
 * are a bounded reconstruction adaptation; never turn no proof into success. */
static void CRVerifyProcessInjectionAfterLaunch(id process, pid_t pid,
                                                NSString *expectedContainer,
                                                NSUInteger attempt)
{
    if (!process || pid <= 0 || !expectedContainer.length)
        return;
    __weak id weakProcess = process;
    id<CRHelperServiceProtocol> proxy = (id<CRHelperServiceProtocol>)
        [CraneManager.sharedManager cranehelperdGlobalSyncRemoteObjectProxy];
    if (!proxy || ![proxy respondsToSelector:
                       @selector(fetchActiveContainerIDForProcessWithPid:reply:)]) {
        NSLog(@"CraneSB: post-launch lookup unavailable pid=%d", pid);
        CRPresentDaemonError(@[@"cranehelperd"], [NSError errorWithDomain:
            @"com.opa334.crane.helper.transport" code:1001 userInfo:@{
                NSLocalizedDescriptionKey: @"Post-launch lookup unavailable"
            }], NO);
        return;
    }
    [proxy fetchActiveContainerIDForProcessWithPid:pid
        reply:^(NSString *actualContainer, BOOL connectionWorks) {
            /* Snapshot the error while the helper reply-scoped diagnosis is
             * available. Main-thread delivery must not lose it. */
            NSError *lookupError = [CraneManager.sharedManager getLastError];
            dispatch_async(dispatch_get_main_queue(), ^{
                id launched = weakProcess;
                if (!launched ||
                    ![launched respondsToSelector:@selector(isRunning)] ||
                    !((BOOL (*)(id, SEL))objc_msgSend)(launched, @selector(isRunning)) ||
                    ![launched respondsToSelector:@selector(pid)] ||
                    (pid_t)((int (*)(id, SEL))objc_msgSend)(launched, @selector(pid)) != pid)
                    return;
                if (actualContainer.length) {
                    /* Native 0x19608 only checks for a nonnil response.
                     * Report a mismatch for diagnosis, not success/failure
                     * based on an unverified inferred expectation. */
                    NSLog(@"CraneSB: post-launch proof pid=%d expected=%@ actual=%@",
                          pid, expectedContainer, actualContainer);
                    return;
                }
                NSLog(@"CraneSB: post-launch proof missing pid=%d attempt=%lu helper=%d error=%@",
                      pid, (unsigned long)(attempt + 1), connectionWorks, lookupError);
                if (connectionWorks == YES && attempt < 2) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                                 (int64_t)(750 * NSEC_PER_MSEC)),
                                   dispatch_get_main_queue(), ^{
                        id again = weakProcess;
                        if (again)
                            CRVerifyProcessInjectionAfterLaunch(again, pid,
                                expectedContainer, attempt + 1);
                    });
                    return;
                }
                NSString *processName = nil;
                SEL queueNameSelector = NSSelectorFromString(@"_queue_name");
                if ([launched respondsToSelector:queueNameSelector]) {
                    @try { processName = [launched valueForKey:@"_name"]; }
                    @catch (__unused NSException *exception) { processName = nil; }
                } else if ([launched respondsToSelector:@selector(name)]) {
                    processName =
                        ((id (*)(id, SEL))objc_msgSend)(launched, @selector(name));
                }
                if (connectionWorks == YES) {
                    CRPresentMainDylibNotLoadedError(processName);
                } else {
                    CRPresentDaemonError(@[@"runningboardd"], lookupError, NO);
                }
            });
        }];
}

/* The recovered FBProcessManager bootstrap/create hooks can both register
 * callbacks on one FBProcess. One proof check per process+PID is sufficient;
 * an association is freed with the process, avoiding stale global PID sets. */
static char kCRInjectionCheckedPIDAssociation;

static void CRRegisterInjectionCheckForProcess(id self, SEL _cmd, id process,
                                               NSString *containerID)
{
    (void)self; (void)_cmd;
    if (!process || !containerID.length)
        return;

    /* CraneSB 0x18238 registers after-launch verification, not a fixed
     * timer from the initial launch request. */
    __weak id weakProcess = process;
    NSString *expectedContainer = [containerID copy];
    void (^checkAfterLaunch)(void) = ^{
        id launched = weakProcess;
        if (!launched || ![launched respondsToSelector:@selector(isRunning)] ||
            !((BOOL (*)(id, SEL))objc_msgSend)(launched, @selector(isRunning)) ||
            ![launched respondsToSelector:@selector(pid)])
            return;
        pid_t pid = (pid_t)((int (*)(id, SEL))objc_msgSend)(launched, @selector(pid));
        if (pid <= 0)
            return;
        @synchronized(launched) {
            NSNumber *alreadyChecked = objc_getAssociatedObject(
                launched, &kCRInjectionCheckedPIDAssociation);
            if (alreadyChecked && alreadyChecked.intValue == pid) {
                NSLog(@"CraneSB: duplicate post-launch check ignored pid=%d", pid);
                return;
            }
            objc_setAssociatedObject(launched, &kCRInjectionCheckedPIDAssociation,
                                    @(pid), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        CRVerifyProcessInjectionAfterLaunch(launched, pid, expectedContainer, 0);
    };
    SEL callbackSelector = NSSelectorFromString(@"_executeBlockAfterLaunchCompletes:");
    if (![process respondsToSelector:callbackSelector])
        callbackSelector = NSSelectorFromString(@"executeBlockAfterLaunchCompletes:");
    if ([process respondsToSelector:callbackSelector])
        ((void (*)(id, SEL, id))objc_msgSend)(process, callbackSelector, checkAfterLaunch);
}

/* crane_applyModificationsIfNeededToExecutionContext:withApplicationIdentifier:
 * is where CRApplyEnvironmentChanges is invoked, from sub_180F0.
 * Type encoding "@@:@@" is recovered verbatim from Crane 0x17A14. */
static id CRApplyModificationsIfNeededToExecutionContext(id self, SEL _cmd,
                                                        id executionContext,
                                                        NSString *appID)
{
    (void)self; (void)_cmd;
    /* CraneSB 0x180F0: before SpringBoard has finished launching the
     * execution context must not be changed. */
    if (!hasFinishedLaunching || !appID.length)
        return nil;

    /* Native 0x180F0 returns only a container ID on iOS 13+ and expects
     * CraneSB in runningboardd to supply _additionalEnvironment later.
     * Roothide Bootstrap may not inject third-party tweaks into daemons.
     * Attempt a bounded, authenticated compatibility route using the
     * *same* executionContext environment API that native 0x180F0 uses on
     * iOS 11/12. This is roothide-only and preserves the native return
     * value, so verification still catches launches with no injected env. */
    if (kCFCoreFoundationVersionNumber >= 1665.15) {
        NSString *containerID = CRContainerToRedirectTo(appID);
#if defined(CRANE_ROOTHIDE)
        if (containerID.length) {
            SEL getEnvironment = @selector(environment);
            SEL setEnvironment = @selector(setEnvironment:);
            NSString *surface = @"environment";
            /* 0x1BD44 establishes _additionalEnvironment on modern
             * RBLaunchRequestContext; the SpringBoard execution context
             * can expose either pair depending on iOS. Prefer the modern
             * surface when actually available, never assume the selector. */
            SEL modernRead = NSSelectorFromString(@"_additionalEnvironment");
            SEL modernWrite = NSSelectorFromString(@"_setAdditionalEnvironment:");
            if ([executionContext respondsToSelector:modernRead] &&
                [executionContext respondsToSelector:modernWrite]) {
                getEnvironment = modernRead;
                setEnvironment = modernWrite;
                surface = @"additionalEnvironment";
            }
            BOOL canApply = executionContext &&
                [executionContext respondsToSelector:getEnvironment] &&
                [executionContext respondsToSelector:setEnvironment];
            if (!canApply) {
                NSLog(@"CraneSB: roothide SpringBoard launch fallback unavailable app=%@ contextEnvironmentSelectors=0", appID);
            } else {
                id original = ((id (*)(id, SEL))objc_msgSend)(
                    executionContext, getEnvironment);
                if (original && ![original isKindOfClass:NSDictionary.class]) {
                    NSLog(@"CraneSB: roothide SpringBoard launch fallback refused invalid environment app=%@", appID);
                } else {
                    NSMutableDictionary *updated = CRApplyEnvironmentChanges(
                        (NSMutableDictionary *)original, appID);
                    if (updated != original &&
                        [updated[CR_ENV_CONTAINER_IDENTIFIER] isEqualToString:containerID]) {
                        ((void (*)(id, SEL, id))objc_msgSend)(
                            executionContext, setEnvironment, updated);
                        NSLog(@"CraneSB: roothide SpringBoard launch fallback applied app=%@ container=%@ surface=%@", appID, containerID, surface);
                    } else {
                        NSLog(@"CraneSB: roothide SpringBoard launch fallback blocked app=%@ (insurance or environment)", appID);
                    }
                }
            }
        }
#endif
        return containerID;
    }

    /* Pre-iOS 13 path from 0x180F0: update the execution context only if
     * crane_applyEnvironmentChanges returned a different environment. */
    SEL getEnvironment = @selector(environment);
    SEL setEnvironment = @selector(setEnvironment:);
    if (!executionContext ||
        ![executionContext respondsToSelector:getEnvironment] ||
        ![executionContext respondsToSelector:setEnvironment])
        return nil;
    NSDictionary *original = ((id (*)(id, SEL))objc_msgSend)(executionContext, getEnvironment);
    NSMutableDictionary *updated = CRApplyEnvironmentChanges((NSMutableDictionary *)original, appID);
    if (updated == original)
        return nil;
    NSString *containerID = updated[CR_ENV_CONTAINER_IDENTIFIER];
    ((void (*)(id, SEL, id))objc_msgSend)(executionContext, setEnvironment, updated);
    return containerID;
}

/* FBProcessManager launch interception, CraneSB 0x17DF4/0x17F14/0x1801C.
 * Preserve the exact order: identify target, apply context change, call
 * original, then register injection verification for a redirected process. */
static id (*gOriginalBootstrapProcess)(id, SEL, id, BOOL, NSError **);
static id (*gOriginalCreateProcess)(id, SEL, id);
static id (*gOriginalCreateApplicationProcess)(id, SEL, NSString *, id);

static NSString *CRLaunchApplicationIdentifier(id executionContext)
{
    id identity = [executionContext respondsToSelector:@selector(identity)]
        ? ((id (*)(id, SEL))objc_msgSend)(executionContext, @selector(identity)) : nil;
    return [identity respondsToSelector:@selector(embeddedApplicationIdentifier)]
        ? ((id (*)(id, SEL))objc_msgSend)(identity, @selector(embeddedApplicationIdentifier)) : nil;
}

static id CRBootstrapProcess(id self, SEL command, id context, BOOL synchronously, NSError **error)
{
    NSString *appID = CRLaunchApplicationIdentifier(context);
    NSString *container = CRApplyModificationsIfNeededToExecutionContext(self, command, context, appID);
    id process = gOriginalBootstrapProcess
        ? gOriginalBootstrapProcess(self, command, context, synchronously, error) : nil;
    if (container.length && process) {
        if (CRIsDylibLoaded(CR_LIB_SANDY))
            CRRegisterInjectionCheckForProcess(self, command, process, container);
        else
            CRPresentLibSandyNotWorkingError();
    }
    return process;
}

static id CRCreateProcess(id self, SEL command, id context)
{
    NSString *container = CRApplyModificationsIfNeededToExecutionContext(
        self, command, context, CRLaunchApplicationIdentifier(context));
    id process = gOriginalCreateProcess ? gOriginalCreateProcess(self, command, context) : nil;
    if (container.length && process) {
        if (CRIsDylibLoaded(CR_LIB_SANDY))
            CRRegisterInjectionCheckForProcess(self, command, process, container);
        else
            CRPresentLibSandyNotWorkingError();
    }
    return process;
}

static id CRCreateApplicationProcess(id self, SEL command, NSString *appID, id context)
{
    NSString *container = CRApplyModificationsIfNeededToExecutionContext(self, command, context, appID);
    id process = gOriginalCreateApplicationProcess
        ? gOriginalCreateApplicationProcess(self, command, appID, context) : nil;
    if (container.length && process)
        CRRegisterInjectionCheckForProcess(self, command, process, container);
    return process;
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
/* Always Ask Before Launch (0x12B3C / 0x18354 / 0x18580 / 0x18710)          */
/* ------------------------------------------------------------------------- */

static void (*gOriginalLaunchFromIconView)(id, SEL, id);
static void (*gOriginalLaunchFromIconViewActions)(id, SEL, id, id);
static void (*gOriginalLaunchFromIconViewActionsFlags)(id, SEL, id, id, NSUInteger);

static NSString *CRLaunchBundleIdentifierFromIconView(id iconView,
                                                       BOOL allowIconFallback)
{
    if (!iconView)
        return nil;

    SEL applicationBundleIdentifier =
        NSSelectorFromString(@"applicationBundleIdentifier");
    if ([iconView respondsToSelector:applicationBundleIdentifier])
        return ((id (*)(id, SEL))objc_msgSend)(
            iconView, applicationBundleIdentifier);

    SEL shortcutsIdentifier =
        NSSelectorFromString(@"applicationBundleIdentifierForShortcuts");
    if ([iconView respondsToSelector:shortcutsIdentifier])
        return ((id (*)(id, SEL))objc_msgSend)(iconView, shortcutsIdentifier);

    /* Native 0x18354 alone has this third fallback. The two overloads with
     * actions stop after the shortcut identifier probes. */
    if (!allowIconFallback)
        return nil;

    SEL iconSEL = NSSelectorFromString(@"icon");
    id icon = [iconView respondsToSelector:iconSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(iconView, iconSEL) : nil;
    Class applicationIconClass = NSClassFromString(@"SBApplicationIcon");
    if (!applicationIconClass || ![icon isKindOfClass:applicationIconClass])
        return nil;

    SEL applicationSEL = NSSelectorFromString(@"application");
    id application = [icon respondsToSelector:applicationSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(icon, applicationSEL) : nil;
    SEL bundleIdentifierSEL = NSSelectorFromString(@"bundleIdentifier");
    return [application respondsToSelector:bundleIdentifierSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(application, bundleIdentifierSEL)
        : nil;
}

static void CROpenApplicationAfterContainerSwitch(NSString *appID)
{
    Class serviceClass = NSClassFromString(@"FBSOpenApplicationService");
    SEL selector = NSSelectorFromString(
        @"openApplication:withOptions:completion:");
    id service = serviceClass ? [[serviceClass alloc] init] : nil;
    if ([service respondsToSelector:selector])
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            service, selector, appID, nil, nil);
}

static void CRHandleAppLaunchContainerPicker(id presenter,
                                              id sourceView,
                                              NSString *appID,
                                              dispatch_block_t continuation,
                                              BOOL continueAfterSwitch)
{
    if (!presenter || !sourceView || !appID.length || !continuation) {
        if (continuation)
            continuation();
        return;
    }

    CraneManager *manager = CraneManager.sharedManager;
    NSString *appName = [manager displayNameForApplicationWithIdentifier:appID];
    NSString *active =
        [manager activeContainerIdentifierForApplicationWithIdentifier:appID];
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:appName
                         message:CRLocalize(@"SELECT_CONTAINER")
                  preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSString *> *containers =
        [manager containerIdentifiersOfApplicationWithIdentifier:appID];
    for (NSString *containerID in containers) {
        NSString *title = [manager
            displayNameForContainerWithIdentifier:containerID
                       ofApplicationWithIdentifier:appID
                            shouldUseShortVersion:NO];
        UIAlertAction *action = [UIAlertAction
            actionWithTitle:title
                      style:UIAlertActionStyleDefault
                    handler:^(__unused UIAlertAction *selectedAction) {
            if ([containerID isEqualToString:active]) {
                continuation();
                return;
            }

            [CraneManager.sharedManager
                setActiveContainerIdentifier:containerID
                 forApplicationWithIdentifier:appID
                usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {
                    (void)authenticated;
                    if (continueAfterSwitch)
                        continuation();
                    else
                        CROpenApplicationAfterContainerSwitch(appID);
                }];
        }];

        if ([containerID isEqualToString:active]) {
            UIImage *checkmark = nil;
            if ([UIImage respondsToSelector:@selector(systemImageNamed:)])
                checkmark = [UIImage systemImageNamed:@"checkmark"];
            else
                checkmark = [CRIcon(@"SelectedContainerCheckmark")
                    imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
            if (checkmark)
                [action setValue:checkmark forKey:@"image"];
        }
        [alert addAction:action];
    }

    [alert addAction:[UIAlertAction
        actionWithTitle:CRLocalize(@"CANCEL")
                  style:UIAlertActionStyleCancel
                handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView;
        if ([sourceView isKindOfClass:UIView.class])
            popover.sourceRect = ((UIView *)sourceView).bounds;
    }
    [presenter presentViewController:alert animated:YES completion:nil];
}

static id CRLaunchPickerPresenter(id iconView)
{
    SEL selector = NSSelectorFromString(@"_viewControllerForAncestor");
    return [iconView respondsToSelector:selector]
        ? ((id (*)(id, SEL))objc_msgSend)(iconView, selector) : nil;
}

static void CRLaunchFromIconView(id self, SEL _cmd, id iconView)
{
    NSString *appID = CRLaunchBundleIdentifierFromIconView(iconView, YES);
    if (!CRAlwaysAskBeforeLaunch(appID)) {
        if (gOriginalLaunchFromIconView)
            gOriginalLaunchFromIconView(self, _cmd, iconView);
        return;
    }

    id presenter = CRLaunchPickerPresenter(iconView);
    if (!presenter) {
        if (gOriginalLaunchFromIconView)
            gOriginalLaunchFromIconView(self, _cmd, iconView);
        return;
    }
    CRHandleAppLaunchContainerPicker(presenter, iconView, appID, ^{
        if (gOriginalLaunchFromIconView)
            gOriginalLaunchFromIconView(self, _cmd, iconView);
    }, NO);
}

static void CRLaunchFromIconViewActions(id self, SEL _cmd,
                                        id iconView, id actions)
{
    NSString *appID = CRLaunchBundleIdentifierFromIconView(iconView, NO);
    if (!CRAlwaysAskBeforeLaunch(appID)) {
        if (gOriginalLaunchFromIconViewActions)
            gOriginalLaunchFromIconViewActions(self, _cmd, iconView, actions);
        return;
    }

    id presenter = CRLaunchPickerPresenter(iconView);
    if (!presenter) {
        if (gOriginalLaunchFromIconViewActions)
            gOriginalLaunchFromIconViewActions(self, _cmd, iconView, actions);
        return;
    }
    CRHandleAppLaunchContainerPicker(presenter, iconView, appID, ^{
        if (gOriginalLaunchFromIconViewActions)
            gOriginalLaunchFromIconViewActions(self, _cmd, iconView, actions);
    }, NO);
}

static void CRLaunchFromIconViewActionsFlags(id self, SEL _cmd,
                                             id iconView, id actions,
                                             NSUInteger modifierFlags)
{
    NSString *appID = CRLaunchBundleIdentifierFromIconView(iconView, NO);
    if (!CRAlwaysAskBeforeLaunch(appID)) {
        if (gOriginalLaunchFromIconViewActionsFlags)
            gOriginalLaunchFromIconViewActionsFlags(
                self, _cmd, iconView, actions, modifierFlags);
        return;
    }

    id presenter = CRLaunchPickerPresenter(iconView);
    if (!presenter) {
        if (gOriginalLaunchFromIconViewActionsFlags)
            gOriginalLaunchFromIconViewActionsFlags(
                self, _cmd, iconView, actions, modifierFlags);
        return;
    }
    CRHandleAppLaunchContainerPicker(presenter, iconView, appID, ^{
        if (gOriginalLaunchFromIconViewActionsFlags)
            gOriginalLaunchFromIconViewActionsFlags(
                self, _cmd, iconView, actions, modifierFlags);
    }, NO);
}

/* ------------------------------------------------------------------------- */
/* Choicy integration                                                         */
/* ------------------------------------------------------------------------- */

/* All six provider selectors and their exact return encodings are recovered:
 * I24@0:8@16, four B24@0:8@16 methods, then @24@0:8@16. Choicy's protocol
 * header is not shipped, so runtime registration is used exactly as in 0x1BBB8. */
@interface NSObject (CraneChoicyRuntime)
+ (id)sharedManager;
- (void)registerOverrideProvider:(id)provider;
@end

static BOOL CRChoicyParseNumberBool(id value, BOOL fallback)
{
    return [value isKindOfClass:NSNumber.class] ? [value boolValue] : fallback;
}

static NSInteger CRChoicyParseNumberInteger(id value, NSInteger fallback)
{
    return [value isKindOfClass:NSNumber.class] ? [value integerValue] : fallback;
}

static NSDictionary *CRChoicyContainerSettings(NSString *appID,
                                                NSString **activeContainer)
{
    CraneManager *manager = CraneManager.sharedManager;
    NSString *active =
        [manager activeContainerIdentifierForApplicationWithIdentifier:appID];
    if (activeContainer)
        *activeContainer = active;
    return [manager containerSettingsForContainerWithIdentifier:active
                                    ofApplicationWithIdentifier:appID];
}

static NSDictionary *CRChoicyConfiguration(NSString *appID)
{
    NSDictionary *settings = CRChoicyContainerSettings(appID, NULL);
    return settings[CRCContainer_ChoicyConfigurationOverwrite];
}

@interface CraneChoicyOverwriteProvider : NSObject
@end

@implementation CraneChoicyOverwriteProvider

- (unsigned int)providedOverridesForApplication:(NSString *)appID
{
    NSString *active = nil;
    NSDictionary *settings = CRChoicyContainerSettings(appID, &active);
    if ([active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return 0;

    return CRChoicyParseNumberBool(
               settings[CRCContainer_ChoicyConfigurationOverwriteEnabled], NO)
               ? 7u
               : 0u;
}

- (BOOL)customTweakConfigurationEnabledOverrideForApplication:(NSString *)appID
{
    NSDictionary *configuration = CRChoicyConfiguration(appID);
    BOOL tweakInjectionDisabled =
        CRChoicyParseNumberBool(configuration[@"tweakInjectionDisabled"], NO);
    BOOL customConfigurationEnabled =
        CRChoicyParseNumberBool(configuration[@"customTweakConfigurationEnabled"], NO);
    return customConfigurationEnabled || tweakInjectionDisabled;
}

- (BOOL)overwriteGlobalConfigurationOverrideForApplication:(NSString *)appID
{
    NSDictionary *configuration = CRChoicyConfiguration(appID);
    return CRChoicyParseNumberBool(
        configuration[@"overwriteGlobalTweakConfiguration"], NO);
}

- (BOOL)disableTweakInjectionOverrideForApplication:(NSString *)appID
{
    (void)appID;
    return NO;
}

- (BOOL)customTweakConfigurationAllowDenyModeOverrideForApplication:(NSString *)appID
{
    NSDictionary *configuration = CRChoicyConfiguration(appID);
    if (CRChoicyParseNumberBool(configuration[@"tweakInjectionDisabled"], NO))
        return NO;

    return CRChoicyParseNumberInteger(configuration[@"allowDenyMode"], 1) != 1;
}

- (id)customTweakConfigurationAllowOrDenyListOverrideForApplication:(NSString *)appID
{
    NSDictionary *configuration = CRChoicyConfiguration(appID);
    NSArray *craneOnly = @[@" Crane"];

    if (CRChoicyParseNumberBool(configuration[@"tweakInjectionDisabled"], NO))
        return craneOnly;

    if (CRChoicyParseNumberInteger(configuration[@"allowDenyMode"], 1) != 1)
        return configuration[@"deniedTweaks"];

    NSArray *allowedTweaks = configuration[@"allowedTweaks"];
    return allowedTweaks
        ? [allowedTweaks arrayByAddingObjectsFromArray:craneOnly]
        : craneOnly;
}
@end

static void CRInitChoicyIntegration(void)
{
    NSString *choicyPath = CRJailbreakRootPath(CR_CHOICY_SB_DYLIB);
    const char *fileSystemPath = choicyPath.fileSystemRepresentation;
    if (!fileSystemPath || access(fileSystemPath, F_OK) != 0)
        return;

    dlopen(fileSystemPath, RTLD_NOW);

    Class managerClass = NSClassFromString(@"ChoicyOverrideManager");
    if (!managerClass)
        return;

    id manager = [managerClass sharedManager];
    CraneChoicyOverwriteProvider *provider = [CraneChoicyOverwriteProvider new];
    [manager registerOverrideProvider:provider];
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
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    /* Exact CraneSB 0x12B30 behavior. This notification clears the migration
     * warning; it is unrelated to SpringBoard launch completion. */
    keychainOutdated = NO;
}

static void CRInitSpringBoard(void)
{
    NSLog(@"CraneSB: SpringBoard initialization reached");
    hasFinishedLaunching = NO;

    /* Restore CraneSB's per-app badge-count snapshot (0xAE20). */
    CRBadgeStoreInitialize();
    CRInitBadgeListenerMethods();
    CRInitBadgeRepositoryHooks();

    /* +[CraneActivatorManager startIfPossible] dynamically loads Activator and
     * remains a no-op when it is absent, matching the recovered 0x1C580 path. */
    [CraneActivatorManager startIfPossible];

    Class fbProcess = NSClassFromString(@"FBProcess");
    Class fbProcessManager = NSClassFromString(@"FBProcessManager");
    Class sbIconController = NSClassFromString(@"SBIconController");

    if (fbProcess) {
        class_addMethod(fbProcess, @selector(crane_containerIdentifier),
                        (IMP)CRFBProcessContainerIdentifier, "@@:");
    }

    if (fbProcessManager) {
        /* Registration order follows the original CraneSB 0x17A14. */
        SEL bootstrap = NSSelectorFromString(@"_bootstrapProcessWithExecutionContext:synchronously:error:");
        SEL create = NSSelectorFromString(@"_createProcessWithExecutionContext:");
        SEL application = NSSelectorFromString(@"createApplicationProcessForBundleID:withExecutionContext:");
        if ([fbProcessManager instancesRespondToSelector:bootstrap])
            MSHookMessageEx(fbProcessManager, bootstrap, (IMP)CRBootstrapProcess,
                            (IMP *)&gOriginalBootstrapProcess);
        if ([fbProcessManager instancesRespondToSelector:create])
            MSHookMessageEx(fbProcessManager, create, (IMP)CRCreateProcess,
                            (IMP *)&gOriginalCreateProcess);
        if ([fbProcessManager instancesRespondToSelector:application])
            MSHookMessageEx(fbProcessManager, application, (IMP)CRCreateApplicationProcess,
                            (IMP *)&gOriginalCreateApplicationProcess);
        class_addMethod(fbProcessManager,
                        @selector(crane_applyModificationsIfNeededToExecutionContext:withApplicationIdentifier:),
                        (IMP)CRApplyModificationsIfNeededToExecutionContext,
                        "@@:@@");
        class_addMethod(fbProcessManager,
                        @selector(crane_registerInjectionCheckForProcess:toBeLaunchedIntoContainer:),
                        (IMP)CRRegisterInjectionCheckForProcess,
                        "v@:@@");
    }

    if (sbIconController) {
        SEL launch = NSSelectorFromString(@"_launchFromIconView:");
        SEL launchActions =
            NSSelectorFromString(@"_launchFromIconView:withActions:");
        SEL launchFlags = NSSelectorFromString(
            @"_launchFromIconView:withActions:modifierFlags:");
        if ([sbIconController instancesRespondToSelector:launch])
            MSHookMessageEx(sbIconController, launch,
                            (IMP)CRLaunchFromIconView,
                            (IMP *)&gOriginalLaunchFromIconView);
        if ([sbIconController instancesRespondToSelector:launchActions])
            MSHookMessageEx(sbIconController, launchActions,
                            (IMP)CRLaunchFromIconViewActions,
                            (IMP *)&gOriginalLaunchFromIconViewActions);
        if ([sbIconController instancesRespondToSelector:launchFlags])
            MSHookMessageEx(sbIconController, launchFlags,
                            (IMP)CRLaunchFromIconViewActionsFlags,
                            (IMP *)&gOriginalLaunchFromIconViewActionsFlags);
    }

    /* CONFIRMED_STATIC: on CF >= 1665.15 (iOS 13-era+) the original installs the
     * runningboardd error-alert hooks; on older systems it loads the icon
     * bundle and does the Choicy integration instead. The inversion is
     * reproduced as read from the decompilation (U-07). */
    if (kCFCoreFoundationVersionNumber >= 1665.15) {
        CRInitRunningboarddErrorAlertHooks();
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

    BOOL shortcutsEnabled = CRAppShortcutEnabled();
    NSLog(@"CraneSB: application shortcuts enabled=%@", shortcutsEnabled ? @"YES" : @"NO");
    if (shortcutsEnabled)
        CRInitApplicationShortcutHooks();

    /* initNotificationSupport / initCRBadgeContextMenuActionView remain
     * separate gaps; both modern and legacy container-selection paths are wired. */
    CRInitUIMenuHooks();
}

static void CRStartHelperIfNeeded(void)
{
    /* Original 0x14894 uses NSTask with the jbroot-resolved
     * /usr/local/bin/cranehelperd_start path, then waits for exit. Resolve the
     * private-on-iOS class dynamically so the public SDK can still compile. */
    Class taskClass = NSClassFromString(@"NSTask");
    SEL setLaunchPath = NSSelectorFromString(@"setLaunchPath:");
    SEL launch = NSSelectorFromString(@"launch");
    SEL waitUntilExit = NSSelectorFromString(@"waitUntilExit");
    NSString *path = CRJailbreakRootPath(CR_HELPERD_START_BIN);
    id task = taskClass ? [[taskClass alloc] init] : nil;
    if (!task || !path.length ||
        ![task respondsToSelector:setLaunchPath] ||
        ![task respondsToSelector:launch] ||
        ![task respondsToSelector:waitUntilExit]) {
        NSLog(@"CraneSB: cranehelperd_start unavailable path=%@", path);
        return;
    }
    ((void (*)(id, SEL, id))objc_msgSend)(task, setLaunchPath, path);
    ((void (*)(id, SEL))objc_msgSend)(task, launch);
    ((void (*)(id, SEL))objc_msgSend)(task, waitUntilExit);
}

static void CRRequestInjectionFixupWhenHelperReady(CraneManager *manager)
{
    if (!manager)
        return;

    static NSObject *lock;
    static BOOL inFlight;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized(lock) {
        if (inFlight)
            return;
        inFlight = YES;
    }

    /* cranehelperdConnectionWorks is deliberately cache-only on SpringBoard's
     * main thread. The old reconstruction called it twice synchronously around
     * CRStartHelperIfNeeded, so a cold helper could remain "probeInFlight" and
     * the recovered 0x1782C fix-up was skipped forever. Probe from a worker,
     * where CraneManager performs the bounded synchronous health request. */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        const NSUInteger maxAttempts = 8;
        for (NSUInteger attempt = 1; attempt <= maxAttempts; ++attempt) {
            if ([manager cranehelperdConnectionWorks]) {
                id proxy = [manager cranehelperdGlobalAsyncRemoteObjectProxy];
                SEL fixupSEL =
                    NSSelectorFromString(@"runInjectionFixUpIfNeededAndReply:");
                if ([proxy respondsToSelector:fixupSEL]) {
                    NSLog(@"CraneSB: requesting helper injection fixup attempt=%lu",
                          (unsigned long)attempt);
                    void (^reply)(BOOL, NSError *) =
                        ^(BOOL success, NSError *error) {
                            if (!success)
                                CRInjectionFixupError = error;
                            NSLog(@"CraneSB: helper injection fixup reply success=%d error=%@",
                                  success, error);
                            @synchronized(lock) {
                                inFlight = NO;
                            }
                        };
                    ((void (*)(id, SEL, id))objc_msgSend)(
                        proxy, fixupSEL, reply);
                    return;
                }

                NSError *error = [NSError errorWithDomain:
                    @"com.opa334.crane.helper.fixup"
                    code:1 userInfo:@{NSLocalizedDescriptionKey:
                        @"Crane helper proxy does not expose injection fix-up"}];
                CRInjectionFixupError = error;
                NSLog(@"CraneSB: helper injection fixup unavailable error=%@",
                      error);
                @synchronized(lock) {
                    inFlight = NO;
                }
                return;
            }

            if (attempt < maxAttempts)
                usleep(250000);
        }

        NSError *error = [NSError errorWithDomain:
            @"com.opa334.crane.helper.fixup"
            code:2 userInfo:@{NSLocalizedDescriptionKey:
                @"Crane helper did not become ready for injection fix-up"}];
        CRInjectionFixupError = error;
        NSLog(@"CraneSB: helper injection fixup readiness failed error=%@",
              error);
        @synchronized(lock) {
            inFlight = NO;
        }
    });
}

static void CRCheckKeychainVersion(void)
{
    /* Exact 0x12AD0 state transition. Migration completion 0x12B30 clears it. */
    if (![CraneManager.sharedManager isKeychainVersionUpToDate])
        keychainOutdated = YES;
}

static void CRDidFinishLaunching(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object,
                                 CFDictionaryRef userInfo)
{
    (void)center; (void)observer; (void)name; (void)object; (void)userInfo;
    CraneManager *manager = CraneManager.sharedManager;

    /* CraneSB 0x1782C first attempts the recovered starter when the helper is
     * unreachable, then rechecks before asking for the injection fix-up. */
    if (![manager cranehelperdConnectionWorks])
        CRStartHelperIfNeeded();

    /* Do not immediately re-read the main-thread helper cache here. A cold
     * helper startup races that cache by construction. The worker retry below
     * preserves the original fix-up ordering intent while waiting for the
     * newly started Mach service to become genuinely reachable. */
    CRRequestInjectionFixupWhenHelperReady(manager);

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)CR_NOTIFICATION_SB_LOADED,
        NULL, NULL, YES);

    CRCheckKeychainVersion();
    dispatch_async(dispatch_get_global_queue(0, 0), ^{
        CRBadgeStoreInitialize();
    });

    if (kCFCoreFoundationVersionNumber < 1665.15 && CRAppShortcutEnabled())
        CRInitApplicationShortcutLateHooks();
    hasFinishedLaunching = YES;
}

/* ------------------------------------------------------------------------- */
/* crane_initRunningBoardd (0x1BF10)                                           */
/* ------------------------------------------------------------------------- */

/* CraneSB 0x1BD44 requires libSandy_applyProfile("CraneRB") to return 0
 * before it can change the runningboardd launch environment. The successful
 * profile is process-wide; failed attempts may be retried on a later launch. */
static BOOL CRRunningBoardProfileReady(void)
{
    static BOOL applied;
    @synchronized([CraneManager class]) {
        if (applied) return YES;
        NSString *path = CRJailbreakRootPath(CR_LIB_SANDY);
        void *handle = path ? dlopen(path.fileSystemRepresentation, RTLD_NOW) : NULL;
        if (!handle) {
            NSLog(@"CraneSB: runningboardd CraneRB profile cannot load libSandy path=%@ error=%s",
                  path, dlerror() ?: "unknown");
            return NO;
        }
        int (*applyProfile)(const char *) = (int (*)(const char *))
            dlsym(handle, "libSandy_applyProfile");
        int result = applyProfile ? applyProfile("CraneRB") : -1;
        dlclose(handle);
        if (result == 0) applied = YES;
        else NSLog(@"CraneSB: CraneRB sandbox profile unavailable (code=%d)", result);
        return applied;
    }
}

/* CraneSB 0x1BD44 mutates the additional launch environment before the
 * original RBProcessManager request handler sees it. */
static void CRModifyRunningBoardLaunchRequest(id request)
{
    if (!CRRunningBoardProfileReady()) return;
    id context = [request respondsToSelector:@selector(context)]
        ? ((id (*)(id, SEL))objc_msgSend)(request, @selector(context)) : nil;
    if (!context) {
        NSLog(@"CraneSB: runningboardd launch request has no context");
        return;
    }
    NSString *appID = nil;
    if ([context respondsToSelector:@selector(bundleIdentifier)])
        appID = ((id (*)(id, SEL))objc_msgSend)(context, @selector(bundleIdentifier));
    else
        appID = CRLaunchApplicationIdentifier(context);
    if (!appID.length) {
        NSLog(@"CraneSB: runningboardd launch context has no application ID");
        return;
    }
    if (![context respondsToSelector:NSSelectorFromString(@"_additionalEnvironment")] ||
        ![context respondsToSelector:NSSelectorFromString(@"_setAdditionalEnvironment:")]) {
        if (CRContainerToRedirectTo(appID).length)
            NSLog(@"CraneSB: runningboardd missing additionalEnvironment selector app=%@", appID);
        return;
    }
    SEL readEnvironment = NSSelectorFromString(@"_additionalEnvironment");
    NSDictionary *original = ((id (*)(id, SEL))objc_msgSend)(context, readEnvironment);
    NSMutableDictionary *updated = CRApplyEnvironmentChanges((NSMutableDictionary *)original, appID);
    if (updated != original) {
        NSLog(@"CraneSB: runningboardd launch environment app=%@ containerIDSet=%d",
              appID, [updated[CR_ENV_CONTAINER_IDENTIFIER] isKindOfClass:NSString.class]);
        ((void (*)(id, SEL, id))objc_msgSend)(context,
            NSSelectorFromString(@"_setAdditionalEnvironment:"), updated);
    } else if (CRContainerToRedirectTo(appID).length) {
        NSLog(@"CraneSB: runningboardd launch unchanged app=%@ (insurance/profile check)", appID);
    }
}

static id (*gOriginalRBExecuteLaunchRequest)(id, SEL, id, id);
static id (*gOriginalRBPrivateExecuteLaunchRequest)(id, SEL, id, id);

static id CRRBExecuteLaunchRequest(id self, SEL command, id request, id argument)
{
    CRModifyRunningBoardLaunchRequest(request);
    return gOriginalRBExecuteLaunchRequest
        ? gOriginalRBExecuteLaunchRequest(self, command, request, argument) : nil;
}

static id CRRBPrivateExecuteLaunchRequest(id self, SEL command, id request, id error)
{
    CRModifyRunningBoardLaunchRequest(request);
    return gOriginalRBPrivateExecuteLaunchRequest
        ? gOriginalRBPrivateExecuteLaunchRequest(self, command, request, error) : nil;
}

static void CRInitRunningBoardd(void)
{
    /* Original CraneSB 0x1BF74/0x1BFEC: modify request before calling the
     * original selector. Register only selectors present on this iOS build. */
    Class processManager = NSClassFromString(@"RBProcessManager");
    if (processManager) {
        SEL execute = NSSelectorFromString(@"executeLaunchRequest:withError:");
        SEL privateExecute = NSSelectorFromString(@"_executeLaunchRequest:withError:");
        NSLog(@"CraneSB: runningboardd hook selectors execute=%d private=%d",
              [processManager instancesRespondToSelector:execute],
              [processManager instancesRespondToSelector:privateExecute]);
        if ([processManager instancesRespondToSelector:execute])
            MSHookMessageEx(processManager, execute, (IMP)CRRBExecuteLaunchRequest,
                            (IMP *)&gOriginalRBExecuteLaunchRequest);
        if ([processManager instancesRespondToSelector:privateExecute])
            MSHookMessageEx(processManager, privateExecute,
                            (IMP)CRRBPrivateExecuteLaunchRequest,
                            (IMP *)&gOriginalRBPrivateExecuteLaunchRequest);
    }
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
            CRReportRuntimeInjection(@"CraneSB", nil);
            gIsSpringBoard = YES;
            CRInitErrorAlerts();
            CRInitSpringBoard();
        } else if ([executable isEqualToString:@"runningboardd"]) {
            CRReportRuntimeInjection(@"CraneSB", nil);
            CRInitRunningBoardd();
        }
    }
}