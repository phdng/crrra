"""Static safety contracts for Crane's reconstruction-only XPC runtime layer.

Run on the host without Theos. These checks prove source invariants only; they
are not a substitute for an on-device injection test.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "sources"
manager = (root / "libcrane" / "CRManager.m").read_text(encoding="utf-8")
helper = (root / "cranehelperd" / "CRHelperd.m").read_text(encoding="utf-8")
common = (root / "common" / "CRCommon.m").read_text(encoding="utf-8")
main = (root / "maindylib" / "CRMainDylib.m").read_text(encoding="utf-8")
springboard = (root / "cranesb" / "CRSpringBoard.m").read_text(encoding="utf-8")
support = (root / "support" / "CRSupport.m").read_text(encoding="utf-8")
mcm = (root / "support" / "CRMCM.m").read_text(encoding="utf-8")
prefs = (root / "common" / "CRPreferences.h").read_text(encoding="utf-8")
manager_header = (root / "common" / "CRManager.h").read_text(encoding="utf-8")

assert '#define CR_PREFS_DOMAIN @"com.opa334.craneprefs"' in prefs
# Crane 0x6924 constructs its UI bundle solely from the jbroot-resolved
# fixed bundle path, without a PreferenceBundles-relative fallback.
ui_start = common.index('static NSBundle *CRUIBundle(void)')
ui_end = common.index('NSString *CRLocalize(', ui_start)
ui_body = common[ui_start:ui_end]
assert 'bundleWithPath:CRJailbreakRootPath(CR_UI_BUNDLE_PATH)' in ui_body
assert 'if (!bundle)' in ui_body
assert 'dispatch_once(&' not in ui_body
assert 'CRPRootListController' not in ui_body
assert '/Library/PreferenceBundles/' not in ui_body
# Main Crane 0x6F40 dispatches off-main authentication success callbacks
# with dispatch_get_global_queue(0, 0), not a reconstructed QOS override.
auth_start = common.index('void CRRequestAuthentication(')
auth_end = common.index('/* Crane 0x6544', auth_start)
auth_body = common[auth_start:auth_end]
assert 'dispatch_get_global_queue(0, 0), handler' in auth_body
assert auth_body.index('BOOL onMainThread = NSThread.isMainThread;') < auth_body.index('LAContext *context =') < auth_body.index('canEvaluatePolicy:')
assert 'QOS_CLASS_DEFAULT' not in auth_body
# Main Crane 0x6924 consults the English fallback only when localization
# equals the input key; an empty translated value must be preserved.
localize_start = common.index('NSString *CRLocalize(NSString *key)')
localize_end = common.index('/* Crane 0x6BE0', localize_start)
localize_body = common[localize_start:localize_end]
assert 'if ([value isEqualToString:key])' in localize_body
assert 'if (!english)' in localize_body
assert 'dispatch_once(&' not in localize_body
assert '!value.length ||' not in localize_body
# CraneSupport 0x60C8 checks loaded dyld image paths, not dlopen presence,
# and returns platform names rather than dylib paths.
platform_start = common.index('NSString *CRGetInjectionPlatform(void)')
platform_end = common.index('/* Reconstruction-only runtime attestation', platform_start)
platform_body = common[platform_start:platform_end]
assert '_dyld_image_count()' in platform_body
assert '_dyld_get_image_name(i)' in platform_body
assert 'if (platform)\n            break;' not in platform_body
assert 'CRJailbreakRootPath(candidate[0])' in platform_body
assert 'CRIsDylibLoaded(' not in platform_body
assert 'CR_INSERTER_SUBSTITUTE, @"Substitute"' in platform_body
assert 'CR_INSERTER_TWEAK_INJECT, @"libhooker"' in platform_body
assert 'CR_INSERTER_SUBSTRATE, @"Substrate"' in platform_body
# CraneSupport 0xC260 returns only the portion preceding the first full
# '/Library/___Crane_Containers' marker; no trailing path is reconstructed.
strip_start = support.index('NSString *CRStripCraneContainerFromPath(')
strip_end = support.index('/* ------------------------------------------------------------------------- */', strip_start)
strip_body = support[strip_start:strip_end]
assert 'componentsSeparatedByString:' in strip_body
assert '@"/" CR_CONTAINERS_DIR_COMPONENT' in strip_body
assert 'firstObject' in strip_body
assert 'stringByAppendingString:' not in strip_body
for source in (manager, helper):
    assert 'CFPreferencesCopyAppValue(' in source, "global domain read missing"
    assert 'CFPreferencesSetAppValue(' in source, "global domain write missing"
    assert '(__bridge CFStringRef)CR_PREFS_DOMAIN' in source, "explicit global domain missing"

# The credential-less Objective-C delegate must never turn installation
# preflight into a successful insurance result.
delegate_start = helper.index(
    '- (void)verifyCraneInsuranceAndReply:',
    helper.index('@implementation CRHGlobalServiceDelegate'),
)
delegate_end = helper.index(
    '- (void)verifySupportLoadedIntoProcessNamed:', delegate_start
)
delegate_insurance = helper[delegate_start:delegate_end]
assert 'reply(NO, description, error, NO)' in delegate_insurance
assert 'reply(works' not in delegate_insurance
assert 'CraneSB runtime attestation' in delegate_insurance

# The shared manager PID lookup must query helperd and fail closed. Never
# fabricate DEFAULT when runtime evidence is absent. The proxy preserves the
# recovered 0x19608 two-argument reply ABI (container, connection status).
lookup_start = manager.index('static void CRManagerLookupActiveContainerForPid(')
lookup_end = manager.index('/* ------------------------------------------------------------------------- */', lookup_start)
lookup_body = manager[lookup_start:lookup_end]
assert '"operation", "lookup_pid"' in lookup_body
assert 'xpc_dictionary_set_int64(request, "pid", pid)' in lookup_body
assert 'xpc_dictionary_get_bool(response, "authorized")' in lookup_body
assert 'xpc_dictionary_get_bool(response, "injection_verified")' in lookup_body
assert 'finish(containerID, authorized)' in lookup_body
assert 'reply(CR_DEFAULT_CONTAINER_IDENTIFIER)' not in lookup_body
assert manager_header.count('reply:(void (^)(NSString *containerID, BOOL connectionWorks))reply;') == 2
assert 'reply:(void (^)(NSString *, BOOL))reply' in manager
assert 'reply:(void (^)(NSString *, BOOL))reply' in helper
assert 'reply:^(NSString *identifier, BOOL connectionWorks)' in mcm
assert 'reply:(void (^)(NSString *))reply' not in helper

# Raw XPC is intentionally narrow. Identity comes from the peer PID and proc
# name, never from caller-supplied identity fields.
peer_start = helper.index('static NSString *CRHandleHealthRequest(')
peer_end = helper.index('#pragma mark - main', peer_start)
peer_code = helper[peer_start:peer_end]
assert 'CRXPCConnectionGetPid(peer)' in peer_code
assert 'CRProcessNameForPid(peerPid)' in peer_code
assert 'CRSigningIdentifierForPeer(peer)' in peer_code
assert 'dlsym(handle ?: RTLD_DEFAULT, "proc_name")' in helper
assert 'dlsym(RTLD_DEFAULT, "xpc_connection_get_audit_token")' in helper
assert 'dlsym(RTLD_DEFAULT, "SecTaskCreateWithAuditToken")' in helper
assert 'dlsym(RTLD_DEFAULT, "SecTaskCopySigningIdentifier")' in helper
for operation in ('"ping"', '"insurance"', '"runtime_report"', '"lookup_pid"', '"component_loaded"'):
    assert operation in peer_code, f"missing raw-XPC operation {operation}"

# Insurance must require a live caller process and can only succeed when both
# preflight and runtime identity checks pass.
assert 'CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "works", preflight && injectionVerified)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "injection_verified", injectionVerified)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "preflight_ok", preflight)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "main_dylib_installed", installed)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "libsandy_loaded", sandy)' in peer_code
assert 'xpc_dictionary_get_bool(response, "injection_verified")' in manager

# PID inspection is caller-aware and target results require a live main-dylib
# report for the exact target PID/process.
assert 'CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID) ||' in peer_code
assert 'CRIsAuthenticatedCraneSupportPeer(peerProcess, peerSigningID)' in peer_code
assert 'CRRuntimeContainerForPid(targetPid, targetProcess)' in peer_code
assert 'entry[@"components"][@"Crane"]' in helper
assert 'xpc_dictionary_set_bool(reply, "authorized", authorized)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "injection_verified", containerID.length > 0)' in peer_code

# Read-only component health checks are caller-authenticated and power the
# recovered CraneSupport 0x9B68 verifyCraneSBLoadedAndReply: path.
assert 'CRRuntimeHasComponentInProcess(component, process)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "loaded", loaded)' in peer_code
assert 'CRManagerVerifyRuntimeComponent(@"CraneSB", @"SpringBoard", reply)' in manager
assert 'CRManagerVerifyRuntimeComponent(@"CraneSupport", name, reply)' in manager
assert '"operation", "component_loaded"' in manager
# Original CraneSB 0x11CA4/0x11D64 requires a synchronous pkd result.
# The reconstruction must bridge its authenticated asynchronous raw-XPC
# component report with a bounded, fail-closed wait (never a guessed YES).
assert '- (void)runSafeXPCBlock:(dispatch_block_t)block;' in manager_header
assert '- (void)runSafeXPCBlock:(dispatch_block_t)block' in manager
assert '- (void)verifyCraneSupportLoadedIntoDaemon:(NSString *)daemon' in manager_header
assert '- (void)verifyCraneSupportLoadedIntoDaemon:(NSString *)daemon' in manager
assert 'if (![daemon isEqualToString:@"pkd"])' in manager
assert 'CRManagerVerifyRuntimeComponent(@"CraneSupport", daemon,' in manager
assert 'dispatch_semaphore_wait(done,' in manager
assert 'dispatch_after(dispatch_time(DISPATCH_TIME_NOW,' in manager
assert '(int64_t)(2 * NSEC_PER_SEC)),' in manager
assert '(int64_t)(3 * NSEC_PER_SEC))' in manager
assert 'finish(NO);' in manager
assert 'result = (wait == 0 && loaded);' in manager
assert 'finished = YES; /* A late callback cannot alter the result. */' in manager
assert '[process isEqualToString:@"pkd"]' in support
assert '@"pkd": @"com.apple.pluginkit.pkd"' in helper
assert 'CRRuntimeHasComponentInProcess(component, process)' in helper

# Each injected side emits its own runtime proof. The app claim carries the
# actual container ID consumed from the launch environment.
assert '"operation", "runtime_report"' in common
assert 'CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier)' in main
assert 'CRReportRuntimeInjection(@"CraneSB", nil)' in springboard
assert 'CRReportRuntimeInjection(@"CraneSupport", nil)' in support
assert 'xpc_dictionary_set_string(report, "container_id", containerID.UTF8String)' in common
# A disconnected helper peer must trigger re-attestation, and a stale
# connection must not clear a newer live registration for the same PID.
assert 'NSUInteger myGeneration = ++generation;' in common
assert 'xpc_connection_cancel(created);' in common
assert 'static BOOL creationRetryScheduled;' in common
assert 'if (!creationRetryScheduled)' in common
assert 'creationRetryScheduled = NO;' in common
assert 'generation == myGeneration && connection == created' in common
assert 'if (!creationRetryScheduled)' in common
assert 'if (!retire)' in common
assert 'if (connection)' in common
assert 'if (generation != myGeneration || connection)' in common
assert 'reports[component] = containerID.length ? [containerID copy] : NSNull.null;' in common
assert 'for (NSString *name in reports)' in common
assert 'xpc_connection_send_message(created, replay);' in common
assert 'name = reports.allKeys.firstObject;' in common
assert 'CRReportRuntimeInjection(name,' in common
assert 'components[component] = claim;' in helper
assert 'claim[@"container"] = containerID;' in helper
assert '[components[component][@"peerToken"] isEqualToString:peerToken]' in helper
assert 'if (components.count == 0)' in helper
assert 'CRUnregisterRuntime(peerPid, peerToken)' in helper

# Raw XPC must not expose the reconstructed privileged Objective-C selectors.
for prohibited in (
    'setPreferenceValue:',
    'restoreKeychainItems:',
    'reloadApplicationWithIdentifier:',
    'dumpKeychainItemsForContainerIdentifier:',
):
    assert prohibited not in peer_code, f"privileged endpoint exposed: {prohibited}"

assert 'CR_HELPERD_PING_PROTOCOL_V1' in manager
assert '"operation", "insurance"' in manager
assert 'CRHandleHealthRequest(' in peer_code

print("Crane daemon/runtime static contracts: PASS (device runtime still required)")
