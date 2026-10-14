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
paths = (root / "common" / "CRPaths.h").read_text(encoding="utf-8")

assert '#define CR_PREFS_DOMAIN @"com.opa334.craneprefs"' in prefs
# Crane 0x6924 constructs its UI bundle solely from the jbroot-resolved
# fixed bundle path, without a PreferenceBundles-relative fallback.
ui_start = common.index('static NSBundle *CRUIBundle(void)')
ui_end = common.index('NSString *CRLocalize(', ui_start)
ui_body = common[ui_start:ui_end]
assert 'CRJailbreakRootPath(CR_UI_BUNDLE_PATH)' in ui_body
assert '[NSBundle bundleWithPath:path]' in ui_body
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
localize_body = (root / "common" / "CRLocalization.h").read_text(encoding="utf-8")
assert 'CRLocalizedStringFromBundle(CRUIBundle(), key, &english)' in common[localize_start:localize_end]
assert 'if (!value || [value isEqualToString:key])' in localize_body
assert 'return value ?: key;' in localize_body
assert 'if (path.length)' in localize_body
assert 'if (!*englishCache && bundle)' in localize_body
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
# The original Preferences service is for keychain backup/migration, not a
# generic privileged preference store. Global app settings remain owned by
# CraneManager; helperd must not expose arbitrary domain read/write.
assert 'CFPreferencesCopyAppValue(' in manager, 'manager global domain read missing'
assert 'CFPreferencesSetAppValue(' in manager, 'manager global domain write missing'
assert '(__bridge CFStringRef)CR_PREFS_DOMAIN' in manager
assert 'CFPreferencesCopyAppValue(' not in helper
assert 'CFPreferencesSetAppValue(' not in helper
assert '@protocol CRHPreferencesServiceProtocol <NSObject>' in helper
assert 'dumpKeychainItemsFromContainerWithIdentifier:' in helper
assert 'restoreKeychainItemsToContainerWithIdentifier:' in helper
assert 'migrateApplication:(NSString *)appID withAppSettings:' in helper

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
assert 'reply(NO, [broken copy], error)' in delegate_insurance
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
assert 'CraneManager: helper lookup_pid target=%d authorized=%d injected=%d container=%@' in lookup_body
container_pos = lookup_body.index('NSString *containerID = container')
lookup_log_pos = lookup_body.index('CraneManager: helper lookup_pid target=%d', container_pos)
lookup_finish_pos = lookup_body.index('finish(containerID, authorized, error)', lookup_log_pos)
assert container_pos < lookup_log_pos < lookup_finish_pos
assert 'finish(containerID, authorized, error)' in lookup_body
assert 'CRHelperValidateHealthReply(response, @"lookup_pid", &error)' in lookup_body
assert 'CRHelperReplyTimedOut' in lookup_body
assert 'CRManagerDeliverHelperReply(error,' in lookup_body
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
for operation in ('"ping"', '"insurance"', '"runtime_report"', '"lookup_pid"', '"component_loaded"', '"injection_fixup"'):
    assert operation in peer_code, f"missing raw-XPC operation {operation}"

# Insurance must require a live caller plus CraneSupport proof for every
# recovered target daemon that is actually running. This mirrors the recovered
# 0x1B45C fail-open-on-insurance-failure behavior without inventing a requirement
# that an on-demand daemon must exist. Process enumeration is read-only.
assert 'CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID)' in peer_code
assert 'CRRunningCraneSupportProcesses()' in peer_code
assert 'proc_listpids' in helper
assert 'CRCraneSupportProcessNames()' in helper
# Read-only mapped-image diagnostics distinguish "not mapped" from
# "mapped but runtime_report missing" without trusting daemon oslog/notify.
assert 'dlsym(' in helper and '"proc_pidinfo"' in helper
assert '"proc_regionfilename"' in helper
assert 'struct CRProcRegionInfo' in helper
assert '_Static_assert(sizeof(struct CRProcRegionInfo) == 96' in helper
assert 'PROC_PIDREGIONINFO' in helper
assert 'CRSupportMappedImageSummary(runningSupport)' in peer_code
assert 'xpc_dictionary_set_string(reply, "support_image_map"' in peer_code
assert 'CraneManager: helper support image map %@' in manager
assert 'xpc_dictionary_get_string(response, "support_image_map")' in manager
assert 'xpc_dictionary_set_bool(reply, "fixup_attempted"' in peer_code
assert 'xpc_dictionary_set_bool(reply, "fixup_in_progress"' in peer_code
assert 'xpc_dictionary_set_bool(reply, "fixup_success"' in peer_code
assert 'xpc_dictionary_set_string(reply, "fixup_backend_inventory"' in peer_code
assert 'xpc_dictionary_set_string(reply, "fixup_transitions"' in peer_code
assert 'xpc_dictionary_get_bool(response, "fixup_attempted")' in manager
assert 'xpc_dictionary_get_bool(response, "fixup_in_progress")' in manager
assert 'xpc_dictionary_get_string(response, "fixup_transitions")' in manager
assert 'xpc_dictionary_get_bool(response, "fixup_success")' in manager
assert 'xpc_dictionary_get_string(response, "fixup_backend_inventory")' in manager
assert 'CraneManager: helper injection fixup state attempted=%d inProgress=%d success=%d' in manager
assert 'transitions=%@' in manager
for marker in (
    '"systemhook.dylib"',
    '"TweakLoader.dylib"',
    '"TweakInject.dylib"',
    '"libinjector.dylib"',
    '"libellekit.dylib"',
    '"libsubstrate.dylib"',
    '"CydiaSubstrate"',
    '@"/TweakInject/"',
    '@"/MobileSubstrate/DynamicLibraries/"',
    '@"/.jbroot-"',
):
    assert marker in helper, marker
assert 'NSMutableSet<NSString *> *otherTweaks' in helper
assert 'NSMutableSet<NSString *> *jailbreakImages' in helper
assert 'systemhook=%d loader=%d injector=%d ellekit=%d substrate=%d' in helper
assert 'jb=%lu jbSample=%@ other=%lu sample=%@' in helper
assert 'CraneSupportProbe' not in helper
assert 'flags=%d' not in helper
assert 'plain=%d' not in helper
assert 'bare=%d' not in helper
for process in ('cfprefsd', 'containermanagerd', 'securityd', 'pkd', 'lsd', 'accountsd', 'apsd'):
    assert f'@"{process}"' in helper, process
assert 'CRCrucialCraneSupportProcessNames(void)' in helper
assert 'processes = @[@"cfprefsd", @"containermanagerd", @"securityd"];' in helper
assert 'for (NSString *process in CRCrucialCraneSupportProcessNames())' in peer_code
assert '![runningSupport containsObject:process]' in peer_code
assert '![brokenSupport containsObject:process]' in peer_code
assert 'CRRuntimeHasComponentInProcess(@"CraneSupport", process)' in peer_code
assert 'BOOL supportComplete = supportInspectionAvailable &&' in peer_code
assert 'runningSupport.count > 0 && brokenSupport.count == 0;' in peer_code
assert 'xpc_dictionary_set_bool(reply, "support_inspection_available"' in peer_code
assert 'xpc_dictionary_set_bool(reply, "support_complete", supportComplete)' in peer_code
assert 'xpc_dictionary_set_string(reply, "broken_daemons"' in peer_code
assert 'preflight && injectionVerified && supportComplete' in peer_code
# The image mapper is diagnostic only; it must not be a success condition.
insurance_start = peer_code.index('if (strcmp(operation, "insurance") == 0)')
insurance_end = peer_code.index(
    '} else if (strcmp(operation, "component_loaded")', insurance_start)
insurance_body = peer_code[insurance_start:insurance_end]
works_start = insurance_body.index('xpc_dictionary_set_bool(reply, "works",')
works_end = insurance_body.index(');', works_start) + 2
works_expression = insurance_body[works_start:works_end]
assert 'preflight && injectionVerified && supportComplete' in works_expression
assert 'supportImageMap' not in works_expression
assert 'support_image_map' not in works_expression
assert 'fixup' not in works_expression
assert 'Crane helper: insurance caller=%@ authorized=%d preflight=%d supportInspect=%d running=%lu supportComplete=%d broken=%@' in peer_code
assert 'xpc_dictionary_set_bool(reply, "injection_verified", injectionVerified)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "preflight_ok", preflight)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "main_dylib_installed", installed)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "libsandy_loaded", sandy)' in peer_code
assert 'xpc_dictionary_get_bool(response, "injection_verified")' in manager
# Original CraneSB 0x1BAA4 callback takes exactly success, brokenDaemons,
# error. Connection state is derived separately from getLastError.
assert 'verifyCraneInsuranceAndReply:(void (^)(BOOL works, NSArray<NSString *> *brokenDaemons, NSError *error))reply;' in manager_header
assert 'verifyCraneInsuranceAndReply:(void (^)(BOOL, NSArray<NSString *> *, NSError *))reply' in manager
assert 'reply(works, brokenDaemons, error);' in manager
assert 'reply(works, brokenDaemons, error, connectionWorks)' not in manager
assert 'NSArray<NSString *> *brokenDaemons = nil;' in springboard
assert '^(BOOL works, NSArray<NSString *> *daemons,' in springboard
assert 'BOOL connWorks' not in springboard
assert 'xpc_dictionary_get_bool(response, "support_complete")' in manager
assert 'xpc_dictionary_get_string(response, "broken_daemons")' in manager
assert 'NSString *brokenString = [brokenDaemons componentsJoinedByString:@", "];' in manager
assert 'works, connectionWorks, brokenString, error' in manager
assert 'injectionVerified && supportComplete;' in manager

# PID inspection is caller-aware and target results require a live main-dylib
# report for the exact target PID/process.
assert 'CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID) ||' in peer_code
assert 'CRIsAuthenticatedCraneSupportPeer(peerProcess, peerSigningID)' in peer_code
assert 'CRRuntimeContainerForPid(targetPid, targetProcess)' in peer_code
assert 'entry[@"components"][@"Crane"]' in helper
assert 'xpc_dictionary_set_bool(reply, "authorized", authorized)' in peer_code
assert 'xpc_dictionary_set_bool(reply, "injection_verified", containerID.length > 0)' in peer_code

# Reconstruction-specific PID cache coherence. The original ClientContainerCache
# only clears on CraneSB/Loaded, but this build learns non-default PID mappings
# asynchronously from app runtime_report. A real Crane container proof must
# invalidate any earlier DEFAULT miss; disconnect must invalidate positive
# entries as well so PID reuse cannot inherit stale isolation state.
assert 'CR_NOTIFICATION_RUNTIME_REGISTRY_CHANGED' in paths
register_start = helper.index('if (strcmp(operation, "runtime_report") == 0)')
register_end = helper.index('if (strcmp(operation, "ping") != 0', register_start)
register_body = helper[register_start:register_end]
assert 'BOOL containerProof = [component isEqualToString:@"Crane"] &&' in register_body
assert 'if (containerProof)' in register_body
assert 'notify_post(CR_NOTIFICATION_RUNTIME_REGISTRY_CHANGED.UTF8String);' in register_body
accept_start = helper.index('static void CRAcceptHealthPeer(')
accept_end = helper.index('#pragma mark - main', accept_start)
accept_body = helper[accept_start:accept_end]
assert 'CRUnregisterRuntime(peerPid, peerToken);' in accept_body
assert accept_body.index('CRUnregisterRuntime(peerPid, peerToken);') < accept_body.index('notify_post(CR_NOTIFICATION_RUNTIME_REGISTRY_CHANGED.UTF8String);')
cache_impl_start = mcm.index('@implementation ClientContainerCache')
cache_register_start = mcm.index('- (void)_registerForClearMessages', cache_impl_start)
cache_register_end = mcm.index('- (NSString *)_getActiveContainerFromCacheForPid:', cache_register_start)
cache_register_body = mcm[cache_register_start:cache_register_end]
assert 'CR_NOTIFICATION_SB_LOADED' in cache_register_body
assert 'CR_NOTIFICATION_RUNTIME_REGISTRY_CHANGED' in cache_register_body
assert cache_register_body.count('CRClearActiveContainerCache') == 2

# Closing the in-flight reply race: a registry clear can occur after an old
# lookup starts but before its async cache write executes. Cache generation is
# incremented by every clear; lookup captures it before XPC and conditional set
# refuses to repopulate after any intervening proof/disconnect notification.
assert 'NSUInteger _activeContainerCacheGeneration;' in mcm
assert '- (NSUInteger)_activeContainerCacheGenerationSnapshot' in mcm
assert 'self->_activeContainerCacheGeneration += 1;' in mcm
assert 'NSUInteger lookupGeneration =' in mcm
assert '[self _activeContainerCacheGenerationSnapshot];' in mcm
assert 'if (self->_activeContainerCacheGeneration != generation)' in mcm
assert '[self _setActiveContainer:normalized' in mcm
assert 'ifGeneration:lookupGeneration];' in mcm
active_start = mcm.index('- (NSString *)activeContainerIdentifierForPid:(pid_t)pid', cache_impl_start)
active_end = mcm.index('\n}\n\n@end', active_start)
active_body = mcm[active_start:active_end]
assert active_body.index('[self _activeContainerCacheGenerationSnapshot]') < active_body.index('fetchActiveContainerIDForProcessWithPid:pid')
assert active_body.index('fetchActiveContainerIDForProcessWithPid:pid') < active_body.index('ifGeneration:lookupGeneration]')
assert '[self _setActiveContainer:normalized toCacheForPid:pid];' not in active_body

# Read-only component health checks are caller-authenticated and power the
# recovered CraneSupport 0x9B68 verifyCraneSBLoadedAndReply: path.
assert 'CRRuntimeHasComponentInProcess(component, process)' in peer_code
assert 'Crane helper: component_loaded caller=%@ process=%@ component=%@ authorized=%d loaded=%d' in peer_code
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
assert 'if (![daemon isEqualToString:@"pkd"] &&' in manager
assert '![daemon isEqualToString:@"apsd"])' in manager
assert '@"apsd": @"com.apple.apsd"' in helper
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
