"""Post-launch app injection proof diagnostic/retry contracts.

The original CraneSB 0x194EC/0x19608 checks whether Crane's main dylib
registered for a launched process. A separate one-way XPC runtime_report
from the app constructor can arrive after an immediate helper lookup.
The reconstruction delays the 'not loaded' alert only for a live,
same-PID process when helper is reachable but its proof is missing.
It must never infer positive injection or suppress a transport error.

The RunningBoard hook remains responsible for setting launch environment
on iOS 13+, and logs failures without changing its selector ABI.
These static/independent tests are NOT an iOS injection verification.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sb = (root / "sources/cranesb/CRSpringBoard.m").read_text(encoding="utf-8")
alerts = (root / "sources/cranesb/CRErrorAlerts.m").read_text(encoding="utf-8")
helper = (root / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
main = (root / "sources/maindylib/CRMainDylib.m").read_text(encoding="utf-8")
common = (root / "sources/common/CRCommon.m").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

a = sb.index("static void CRVerifyProcessInjectionAfterLaunch(")
b = sb.index("/* crane_applyModificationsIfNeededToExecutionContext:", a)
verification = sb[a:b]

for piece in (
    'static void CRVerifyProcessInjectionAfterLaunch(id process, pid_t pid,',
    '@selector(fetchActiveContainerIDForProcessWithPid:reply:)',
    'reply:^(NSString *actualContainer, BOOL connectionWorks)',
    'NSError *lookupError = [CraneManager.sharedManager getLastError];',
    'dispatch_async(dispatch_get_main_queue(), ^{',
    '![launched respondsToSelector:@selector(isRunning)]',
    '(pid_t)((int (*)(id, SEL))objc_msgSend)(launched, @selector(pid)) != pid',
    'if (actualContainer.length)',
    'if (connectionWorks == YES && attempt < 2)',
    'dispatch_after(dispatch_time(DISPATCH_TIME_NOW,',
    '(int64_t)(750 * NSEC_PER_MSEC)',
    'CRVerifyProcessInjectionAfterLaunch(again, pid,',
    'CRPresentMainDylibNotLoadedError(processName);',
    'CRPresentDaemonError(@[@"runningboardd"], lookupError, NO);',
    'CRVerifyProcessInjectionAfterLaunch(launched, pid, expectedContainer, 0);',
    'executeBlockAfterLaunchCompletes:',
):
    assert piece in verification, piece

assert verification.index('if (actualContainer.length)') < verification.index('if (connectionWorks == YES && attempt < 2)')
# The temporary seven-daemon health matrix used during injection diagnosis
# must not run on every successful app launch now that insurance/fix-up is
# device-proven. Native 0x19608 stops once it has a nonnil app proof.
assert 'supportProcesses' not in verification
assert 'verifySupportLoadedIntoProcessNamed:supportProcess' not in verification
assert 'CraneSB: support health process=' not in verification
assert verification.index('(pid_t)((int (*)(id, SEL))objc_msgSend)(launched, @selector(pid)) != pid') < verification.index('if (actualContainer.length)')
assert verification.index('if (connectionWorks == YES && attempt < 2)') < verification.index('CRPresentMainDylibNotLoadedError(processName);')
assert verification.index('NSError *lookupError = [CraneManager.sharedManager getLastError];') < verification.index('dispatch_async(dispatch_get_main_queue(), ^{')
assert 'attempt < 3' not in verification
assert 'CRPresentMainDylibNotLoadedError(processName);' in verification
assert 'reply(YES' not in verification

runningboard = sb[sb.index('static BOOL CRRunningBoardProfileReady('):
                  sb.index('/* ------------------------------------------------------------------------- */\n/* InitFunc_2')]
for piece in (
    'applyProfile("CraneRB")',
    'runningboardd CraneRB profile cannot load libSandy',
    'runningboardd launch request has no context',
    'runningboardd launch context has no application ID',
    'runningboardd missing additionalEnvironment selector',
    'runningboardd launch environment app=%@ containerIDSet=%d',
    'runningboardd launch unchanged app=%@',
    'runningboardd hook selectors execute=%d private=%d',
    'CRApplyEnvironmentChanges((NSMutableDictionary *)original, appID)',
    'if (updated != original)',
):
    assert piece in runningboard, piece

for piece in (
    'Crane helper: runtime_report accepted pid=',
    'Crane helper: runtime_report rejected pid=',
    'Crane helper: lookup_pid caller=',
    'CRRuntimeComponentAllowed(component, peerProcess, peerSigningID)',
    'CRRuntimeContainerForPid(targetPid, targetProcess)',
    'xpc_dictionary_set_bool(reply, "authorized", authorized)',
    'xpc_dictionary_set_bool(reply, "injection_verified", containerID.length > 0)',
):
    assert piece in helper, piece

assert 'CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier)' in main
assert 'CRReportRuntimeInjection(@"CraneSB", nil)' in sb
assert '"operation", "runtime_report"' in common
assert 'CRManagerDeliverHelperReply(error' in manager
assert 'check_postlaunch_injection_contract.py' in workflow

# CraneSB didFinishLaunching 0x1782C ordering and state. The recovered helper
# fix-up selector is preserved and the reconstruction waits for helper
# readiness off the main thread before sending it; callback 0x179C4 stores
# NSError only when success == NO.
assert 'static BOOL keychainOutdated = NO;' in sb
assert 'NSError *CRInjectionFixupError = nil;' in sb
migration_start = sb.index('static void CRKeychainMigrationSucceeded(')
migration_end = sb.index('static void CRInitSpringBoard(void)', migration_start)
migration = sb[migration_start:migration_end]
assert 'keychainOutdated = NO;' in migration
assert 'hasFinishedLaunching = YES;' not in migration
finish_start = sb.index('static void CRDidFinishLaunching(CFNotificationCenterRef center',
                        sb.index('static void CRStartHelperIfNeeded(void)'))
finish_end = sb.index('/* ------------------------------------------------------------------------- */\n/* crane_initRunningBoardd', finish_start)
finish = sb[finish_start:finish_end]
for fragment in (
    'if (![manager cranehelperdConnectionWorks])',
    'CRStartHelperIfNeeded();',
    'CRRequestInjectionFixupWhenHelperReady(manager);',
    'CR_NOTIFICATION_SB_LOADED',
    'CRCheckKeychainVersion();',
    'dispatch_get_global_queue(0, 0)',
    'CRBadgeStoreInitialize();',
    'hasFinishedLaunching = YES;',
):
    assert fragment in finish, fragment
assert finish.index('CRStartHelperIfNeeded();') < finish.index(
    'CRRequestInjectionFixupWhenHelperReady(manager);') < finish.index(
    'CR_NOTIFICATION_SB_LOADED') < finish.index('CRCheckKeychainVersion();') < finish.index(
    'hasFinishedLaunching = YES;')

retry_start = sb.index('static void CRRequestInjectionFixupWhenHelperReady(')
retry_end = sb.index('static void CRCheckKeychainVersion(void)', retry_start)
retry = sb[retry_start:retry_end]
for fragment in (
    'dispatch_get_global_queue(QOS_CLASS_UTILITY, 0)',
    'const NSUInteger maxAttempts = 8;',
    '[manager cranehelperdConnectionWorks]',
    '[manager cranehelperdGlobalAsyncRemoteObjectProxy]',
    '@"runInjectionFixUpIfNeededAndReply:"',
    'if (!success)\n                                CRInjectionFixupError = error;',
    'usleep(250000);',
    'inFlight = NO;',
):
    assert fragment in retry, fragment
assert 'CRStartHelperIfNeeded();' not in retry
assert retry.index('[manager cranehelperdConnectionWorks]') < retry.index(
    '@"runInjectionFixUpIfNeededAndReply:"')
starter = sb[sb.index('static void CRStartHelperIfNeeded(void)'):
             sb.index('static void CRCheckKeychainVersion(void)')]
for fragment in (
    'NSClassFromString(@"NSTask")',
    'CRJailbreakRootPath(CR_HELPERD_START_BIN)',
    '@"setLaunchPath:"', '@"launch"', '@"waitUntilExit"',
):
    assert fragment in starter, fragment
check_keychain = sb[sb.index('static void CRCheckKeychainVersion(void)'):finish_start]
assert 'isKeychainVersionUpToDate' in check_keychain
assert 'keychainOutdated = YES;' in check_keychain

# Original 0x19E70 appends the stored fix-up error only for the daemon
# injection-failure branch, before the Choicy notice.
assert 'extern NSError *CRInjectionFixupError;' in alerts
daemon_start = alerts.index('void CRPresentDaemonError(')
daemon_end = alerts.index('void CRPresentMainDylibNotLoadedError', daemon_start)
daemon = alerts[daemon_start:daemon_end]
assert 'CRLocalize(@"FIXUP_ERROR_DESCRIPTION")' in daemon
assert 'CRInjectionFixupError.localizedDescription' in daemon
assert daemon.index('CRLocalize(@"FIXUP_ERROR_DESCRIPTION")') < daemon.index(
    'CRAppendChoicyNoticeIfNeeded(message)')

# Independent decision model: valid proofs stop immediately, missing proof
# with reachable helper retries at most twice, failed XPC goes to its own
# error path, and dead/replaced processes produce no alert.
def next_step(proof, helper_connected, attempt, same_pid=True, running=True):
    if not same_pid or not running:
        return "stale"
    if proof:
        return "verified"
    if not helper_connected:
        return "transport-error"
    if attempt < 2:
        return "retry"
    return "not-loaded-alert"

assert next_step(True, True, 0) == "verified"
assert next_step(False, True, 0) == "retry"
assert next_step(False, True, 1) == "retry"
assert next_step(False, True, 2) == "not-loaded-alert"
assert next_step(False, False, 0) == "transport-error"
assert next_step(False, False, 2) == "transport-error"
assert next_step(False, True, 1, same_pid=False) == "stale"
assert next_step(False, True, 1, running=False) == "stale"
assert next_step(True, True, 1, same_pid=False) == "stale"

print("Crane post-launch injection proof/retry diagnostic contract: PASS (device unverified)")
