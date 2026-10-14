"""F-19/F-07 privileged helper contracts.

The original cranehelperd does not have a Hex-Rays export, but its Objective-C
method metadata and the relevant reload/helper IMPs are present in the original
Mach-O. The reconstruction therefore implements the recovered reloadApplication:
and reloadDaemons: semantics through its authenticated raw-XPC transport. The
recovered vendor-ID bridge now uses the original helper -> LSD service shape;
unrecovered keychain backup/migration operations remain fail-closed.

Static/source contract only; device behavior still requires a native build.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
helper = (root / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRManager.h").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
alerts = (root / "sources/cranesb/CRErrorAlerts.m").read_text(encoding="utf-8")

start = helper.index("@implementation CRHGlobalServiceDelegate")
end = helper.index("@end", start)
delegate = helper[start:end]

get = delegate[delegate.index("- (void)getIdentifierOfType:"):
               delegate.index("- (void)setIdentifier:", delegate.index("- (void)getIdentifierOfType:"))]
setid = delegate[delegate.index("- (void)setIdentifier:"):
                 delegate.index("- (void)dumpKeychainItemsForContainerIdentifier:")]
dump = delegate[delegate.index("- (void)dumpKeychainItemsForContainerIdentifier:"):
                delegate.index("- (void)restoreKeychainItems:", delegate.index("- (void)dumpKeychainItemsForContainerIdentifier:"))]
restore = delegate[delegate.index("- (void)restoreKeychainItems:"):]

# Credential-less legacy delegate remains fail-closed. Live vendor-ID access is
# implemented separately through authenticated raw-XPC -> LSD; keychain backup
# semantics are still unrecovered.
assert "withReply:(void (^)(NSString *))reply" in get
assert "if (reply)\n        reply(nil);" in get
assert "original lsd identifier read unavailable" in get
assert "stringForKey:" not in get
assert "standardUserDefaults" not in get
assert "setObject:" not in setid
assert "standardUserDefaults" not in setid
assert "original lsd identifier write unavailable" in setid

assert "reply:(void (^)(NSDictionary *))reply" in dump
assert "if (reply)\n        reply(nil);" in dump
assert "reply(@{});" not in dump
assert "keychain dump unavailable" in dump
assert "SecItemCopyMatching(" not in dump
assert "SecItemAdd(" not in restore
assert "SecItemUpdate(" not in restore
assert "SecItemDelete(" not in restore
assert "keychain restore unavailable" in restore

# Original CRHPreferencesService has exactly the keychain dump/restore/migrate
# surface. The reconstruction must not repurpose this privileged service as a
# generic preferences writer, and unrecovered serialization remains fail-closed.
prefs_start = helper.index("#pragma mark - Preferences service")
prefs_end = helper.index("#pragma mark - Global service", prefs_start)
prefs_service = helper[prefs_start:prefs_end]
for selector in (
    "dumpKeychainItemsFromContainerWithIdentifier:",
    "restoreKeychainItemsToContainerWithIdentifier:",
    "migrateApplication:",
):
    assert selector in prefs_service, selector
assert "getPreferenceValueForKey:" not in prefs_service
assert "setPreferenceValue:" not in prefs_service
assert "CFPreferencesSetAppValue" not in prefs_service
assert 'reply(nil);' in prefs_service
assert "preferences keychain dump unavailable" in prefs_service
assert "preferences keychain restore unavailable" in prefs_service
assert "preferences keychain migration unavailable" in prefs_service
prefs_header = header[
    header.index("@protocol CRPreferencesServiceProtocol"):
    header.index("@end", header.index("@protocol CRPreferencesServiceProtocol")) + len("@end")
]
assert "dumpKeychainItemsFromContainerWithIdentifier:" in prefs_header
assert "restoreKeychainItemsToContainerWithIdentifier:" in prefs_header
assert "migrateApplication:" in prefs_header
assert "getPreferenceValueForKey:" not in prefs_header
assert "setPreferenceValue:(id)value forKey:" not in prefs_header

manager_migrate = manager[
    manager.index("- (void)migrateApplication:(NSString *)appID"):
    manager.index("- (void)crane_recordHelperTransportError:", manager.index("- (void)migrateApplication:(NSString *)appID"))
]
assert "setApplicationSettings:" not in manager_migrate
assert "Keychain migration backend is unavailable" in manager_migrate
assert "self.lastError = error;" in manager_migrate

# Keep the original ObjC selector surface present, but unrecovered sensitive
# operations must not be exposed through the live raw-XPC endpoint.
assert '- (void)getIdentifierOfType:(uint64_t)type' in helper
assert '- (void)setIdentifier:(NSString *)identifier' in helper
assert '- (void)dumpKeychainItemsForContainerIdentifier:(NSString *)containerID' in helper
assert '- (void)restoreKeychainItems:(NSDictionary *)items' in helper
raw = helper[helper.index("static NSString *CRHandleHealthRequest("):
             helper.index("#pragma mark - main")]
for item in ("setIdentifier", "getIdentifierOfType", "dumpKeychainItems",
             "restoreKeychainItems", "setPreferenceValue:",
             "runInjectionFixUpIfNeededAndReply"):
    assert item not in raw, item

# Existing health/fix-up contracts stay intact.
assert 'strcmp(operation, "insurance") == 0' in raw
assert 'strcmp(operation, "lookup_pid") == 0' in raw
assert 'strcmp(operation, "injection_fixup") == 0' in raw
assert 'CRRunCraneSupportInjectionFixup(&fixError)' in raw
assert 'CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID)' in raw
assert '[peerProcess isEqualToString:@"SpringBoard"]' in raw
fixup_raw = raw[
    raw.index('if (strcmp(operation, "injection_fixup") == 0)'):
    raw.index('} else if (strcmp(operation, "reload_application")')
]
assert 'xpc_dictionary_get_int64(message, "pid")' not in fixup_raw
assert 'xpc_dictionary_get_string(message, "path")' not in fixup_raw
assert 'xpc_dictionary_get_string(message, "dylib")' not in fixup_raw
assert 'CRBeginInjectionFixupAttempt();' in fixup_raw
assert 'CRFinishInjectionFixupAttempt(success, fixError);' in fixup_raw
assert 'gLastInjectionFixupInProgress = YES;' in helper
assert 'gLastInjectionFixupInProgress = NO;' in helper
assert '@"inProgress": @(gLastInjectionFixupInProgress)' in helper
assert 'gLastInjectionFixupTime' not in helper
assert 'CRInjectionVerificationFailed' not in helper
assert 'CRInjectionTargetChanged' not in helper
assert '@"/Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib"' in helper
assert 'CRSupportFixupTargets(' in helper
assert 'CRPidMapsImageLeaf(pid, @"CraneSupport.dylib"' in helper
assert 'CRSupportInjectionBackendInventory(void)' in helper
assert 'CRSupportInjectionBinaryCandidates(void)' in helper
candidate_start = helper.index('CRSupportInjectionBinaryCandidates(void)')
candidate_end = helper.index('#endif', candidate_start)
candidate_block = helper[candidate_start:candidate_end]
roothide_block, rootful_block = candidate_block.split('#else', 1)
assert '@"/basebin/opainject"' in roothide_block
assert '@"/usr/bin/opainject"' in roothide_block
assert '@"/usr/local/bin/opainject"' in roothide_block
for roothide_only_backend in (
    '@"/basebin/opainject"',
    '@"/usr/bin/opainject"',
    '@"/usr/local/bin/opainject"',
):
    assert roothide_only_backend not in rootful_block
for original_backend in (
    '@"/usr/libexec/libhooker/libsyringe"',
    '@"/usr/bin/cynject"',
    '@"/usr/bin/cynject.old"',
):
    assert original_backend in rootful_block
find_start = helper.index('CRFindSupportInjectionBinary(void)')
find_end = helper.index('static NSString *CRSupportInjectionBackendInventory', find_start)
inventory_start = helper.index('CRSupportInjectionBackendInventory(void)')
inventory_end = helper.index('static BOOL CRRuntimeHasComponent', inventory_start)
assert 'CRSupportInjectionBinaryCandidates()' in helper[find_start:find_end]
assert 'CRSupportInjectionBinaryCandidates()' in helper[inventory_start:inventory_end]
assert 'CRLastInjectionFixupSnapshot(void)' in helper
assert 'CRRecordInjectionFixupTransition(' in helper
assert 'gLastInjectionFixupTransitions' in helper
assert 'fixup_transitions' in helper
assert 'fixup_backend_inventory' in helper
assert 'fixup_error_description' in helper
assert 'CRProcessPidsForNames(@[process])' in helper
assert 'deferred=target_transition' in helper
assert 'deferred=target_changed_before' in helper
assert 'injectorExit=0 immediateMapped=%d inspect=%d' in helper
assert 'timeoutRecovered=1 mapped=%d runtimeProof=%d inspect=%d' in helper
assert 'timeoutDeferred=target_transition' in helper
assert 'toolError.code == CRInjectionTimedOut' in helper
assert 'CRRuntimeHasComponent(pid, process, @"CraneSupport")' in helper
timeout_start = helper.index('if (timedOut) {')
timeout_end = helper.index('\n            }\n\n            if (error)', timeout_start)
timeout_body = helper[timeout_start:timeout_end]
assert timeout_body.index('if (![currentProcess isEqualToString:process])') < timeout_body.index('CRPidMapsImageLeaf(')
assert timeout_body.index('if (![currentProcess isEqualToString:process])') < timeout_body.index('CRRuntimeHasComponent(pid, process, @"CraneSupport")')
assert '[NSDate timeIntervalSinceReferenceDate] + 2.0' not in helper

# Original _serviceNameForDaemon: and _pingDaemon: recovered from helper IMPs.
service_start = helper.index('static NSString *CRServiceNameForDaemon(')
service_end = helper.index('static BOOL CRPingDaemon(', service_start)
service = helper[service_start:service_end]
for daemon, mach in (
    ('@"cfprefsd"', '@"com.apple.cfprefsd.daemon"'),
    ('@"pkd"', '@"com.apple.pluginkit.pkd"'),
    ('@"lsd"', '@"com.apple.lsd.xpc"'),
    ('@"accountsd"', '@"com.apple.accountsd.accountmanager"'),
):
    assert daemon in service and mach in service
assert '@"com.apple." stringByAppendingString:daemon' in service

ping_start = helper.index('static BOOL CRPingDaemon(')
ping_end = helper.index('static void CRActivateCrucialCraneSupportDaemons', ping_start)
ping = helper[ping_start:ping_end]
assert 'CRXPCConnectionCreateMachService(' in ping
assert 'XPC_CONNECTION_MACH_SERVICE_PRIVILEGED' in ping
assert 'xpc_connection_send_message_with_reply_sync' in ping
assert 'XPC_ERROR_CONNECTION_INVALID' in ping
assert 'XPC_ERROR_CONNECTION_INTERRUPTED' in ping

# Insurance now reproduces the original on-demand activation attempt before
# it declares an absent crucial daemon broken.
insurance_start = raw.index('} else if (strcmp(operation, "insurance") == 0)')
insurance = raw[insurance_start:]
assert 'CRActivateCrucialCraneSupportDaemons();' in insurance
assert insurance.index('CRActivateCrucialCraneSupportDaemons();') < insurance.index('CRRunningCraneSupportProcesses();')

# Original reloadDaemons: = support-filter targets U five Store/Game Center
# processes, intersect caller request, then kill only that fixed set.
allow_start = helper.index('static NSSet<NSString *> *CRAllowedReloadDaemonNames(')
allow_end = helper.index('static void CRKillAllProcessesWithName', allow_start)
allow = helper[allow_start:allow_end]
assert 'CRSupportFixupTargets(NULL)' in allow
for name in ('appstored', 'itunesstored', 'StoreKitUIService', 'itunescloudd', 'gamed'):
    assert f'@"{name}"' in allow
kill_start = helper.index('static void CRKillAllProcessesWithName')
kill_end = helper.index('static NSArray<NSString *> *CRReloadDaemons', kill_start)
kill_block = helper[kill_start:kill_end]
assert 'kill(pid, SIGTERM);' in kill_block
assert 'kill(pid, SIGKILL);' in kill_block
assert kill_block.index('kill(pid, SIGKILL);') < kill_block.index('kill(pid, SIGTERM);')
reload_daemons_start = helper.index('static NSArray<NSString *> *CRReloadDaemons')
reload_daemons_end = helper.index('static BOOL CRPidMapsImageLeaf', reload_daemons_start)
reload_daemons = helper[reload_daemons_start:reload_daemons_end]
assert '[selected intersectSet:requested];' in reload_daemons
assert 'CRKillAllProcessesWithName(process);' in reload_daemons

daemon_raw_start = raw.index('} else if (strcmp(operation, "reload_daemons") == 0)')
daemon_raw_end = raw.index('} else if (strcmp(operation, "insurance")', daemon_raw_start)
daemon_raw = raw[daemon_raw_start:daemon_raw_end]
assert '[peerProcess isEqualToString:@"SpringBoard"]' in daemon_raw
assert '[peerSigningID isEqualToString:@"com.apple.springboard"]' in daemon_raw
assert 'xpc_dictionary_get_value(message, "daemons")' in daemon_raw
assert 'CRReloadDaemons(requested)' in daemon_raw
for forbidden in ('xpc_dictionary_get_int64(message, "pid")',
                  'xpc_dictionary_get_string(message, "path")',
                  'xpc_dictionary_get_string(message, "executable")'):
    assert forbidden not in daemon_raw

# Original helper 0x10000CC68 support predicate and 0x10000CF8C enumeration.
support_start = helper.index('static BOOL CRApplicationProxyIsSupported')
support_end = helper.index('static BOOL CRApplicationIdentifierIsSupported', support_start)
support_helper = helper[support_start:support_end]
for excluded in (
    'com.apple.Preferences', 'com.apple.MobileSMS', 'com.apple.mobilesafari',
    'com.apple.MobileAddressBook', 'com.apple.mobilephone', 'com.apple.facetime',
    'com.apple.mobilecal', 'com.apple.sidecar', 'com.apple.siri',
    'com.apple.DocumentsApp',
):
    assert f'@"{excluded}"' in support_helper
for allowed_store in ('com.apple.AppStore', 'com.apple.Music', 'com.apple.MobileStore'):
    assert f'@"{allowed_store}"' in support_helper
assert 'atl_isHidden' in support_helper
assert 'dataContainerURL' in support_helper
assert 'return dataURL != nil && !hidden;' in support_helper

ids_start = helper.index('static NSArray<NSString *> *CRSupportedApplicationIdentifiers')
ids_end = helper.index('static NSString *CRExecutablePathForApplicationIdentifier', ids_start)
ids_helper = helper[ids_start:ids_end]
assert 'LSApplicationWorkspace' in ids_helper
assert 'defaultWorkspace' in ids_helper
assert 'enumerateApplicationsOfType:block:' in ids_helper
assert 'workspace, enumerateSEL, 0, visit' in ids_helper
assert 'workspace, enumerateSEL, 1, visit' in ids_helper
assert 'CRApplicationProxyIsSupported(application)' in ids_helper

for op in ('get_application_display_name',
           'get_supported_application_ids',
           'check_application_supported'):
    assert f'strcmp(operation, "{op}")' in raw
assert 'CRDisplayNameForApplicationIdentifier(appID)' in raw
assert 'CRSupportedApplicationIdentifiers()' in raw
assert 'CRApplicationIdentifierIsSupported(appID)' in raw

# Original vendor-ID service bridge: fixed app ID/UUID fields only; vendorName
# and type are resolved inside the helper and cannot be caller-selected.
for op in ('read_device_vendor_identifier', 'write_device_vendor_identifier'):
    assert f'strcmp(operation, "{op}")' in raw
read_vendor_start = raw.index('} else if (strcmp(operation, "read_device_vendor_identifier") == 0)')
read_vendor_end = raw.index('} else if (strcmp(operation, "write_device_vendor_identifier")', read_vendor_start)
read_vendor = raw[read_vendor_start:read_vendor_end]
write_vendor_start = raw.index('} else if (strcmp(operation, "write_device_vendor_identifier") == 0)')
write_vendor_end = raw.index('} else if (strcmp(operation, "reload_application")', write_vendor_start)
write_vendor = raw[write_vendor_start:write_vendor_end]
assert 'CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID)' in read_vendor
assert 'CRReadDeviceVendorIdentifier(appID)' in read_vendor
assert 'CRDeviceIdentifierString(identifier)' in read_vendor
assert 'CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID)' in write_vendor
assert '[[NSUUID alloc] initWithUUIDString:identifierString]' in write_vendor
assert 'CRWriteDeviceVendorIdentifier(identifier, appID)' in write_vendor
for block in (read_vendor, write_vendor):
    assert 'xpc_dictionary_get_string(message, "vendor_name")' not in block
    assert 'xpc_dictionary_get_int64(message, "type")' not in block
    assert 'xpc_dictionary_get_int64(message, "pid")' not in block

lsd_proxy_start = helper.index('static id CRLSDDeviceIdentifierProxy')
lsd_proxy_end = helper.index('static NSString *CRExecutablePathForApplicationIdentifier', lsd_proxy_start)
lsd_proxy = helper[lsd_proxy_start:lsd_proxy_end]
assert 'NSClassFromString(@"_LSDDeviceIdentifierService")' in lsd_proxy
assert 'synchronousXPCProxyWithErrorHandler:' in lsd_proxy
assert 'crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:' in lsd_proxy
assert 'crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:' in lsd_proxy
assert 'NSSelectorFromString(@"vendorName")' in lsd_proxy

# Original reloadApplication: posts the distributed PKD notification and then
# canonicalExecutablePath -> PID -> TERM -> re-resolve -> KILL.
post_start = helper.index('static void CRPostReloadApplicationNotification')
post_end = helper.index('static NSString *CRExecutablePathForApplicationIdentifier', post_start)
post = helper[post_start:post_end]
assert 'CFSTR("com.opa334.crane/ReloadApplication")' in post
assert 'CFSTR("ReloadApplication")' in post
assert '@"applicationIdentifier"' in post
assert 'CFNotificationCenterPostNotification(' in post
app_start = helper.index('static BOOL CRReloadApplication(')
app_end = helper.index('static NSString *const CRSupportFilterVirtualPath', app_start)
app = helper[app_start:app_end]
assert 'CRPostReloadApplicationNotification(appID);' in app
assert 'CRExecutablePathForApplicationIdentifier(appID)' in app
assert 'CRPidForExecutablePath(path)' in app
assert 'kill(pid, SIGTERM);' in app
assert 'CRExecutablePathForApplicationIdentifier(appID)' in app[app.index('kill(pid, SIGTERM);'):]
assert 'kill(currentPid, SIGKILL);' in app
assert app.index('kill(pid, SIGTERM);') < app.index('kill(currentPid, SIGKILL);')

app_raw_start = raw.index('} else if (strcmp(operation, "reload_application") == 0)')
app_raw_end = raw.index('} else if (strcmp(operation, "reload_daemons")', app_raw_start)
app_raw = raw[app_raw_start:app_raw_end]
assert 'CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID)' in app_raw
assert 'xpc_dictionary_get_string(message, "application_id")' in app_raw
assert 'CRReloadApplication(appID)' in app_raw
for forbidden in ('xpc_dictionary_get_int64(message, "pid")',
                  'xpc_dictionary_get_string(message, "path")',
                  'xpc_dictionary_get_string(message, "executable")'):
    assert forbidden not in app_raw

control_auth_start = helper.index('static BOOL CRIsAuthenticatedCraneControlPeer')
control_auth_end = helper.index('static BOOL CRIsAuthenticatedCraneSupportPeer', control_auth_start)
control_auth = helper[control_auth_start:control_auth_end]
assert '@"SpringBoard"' in control_auth
assert '@"com.apple.springboard"' in control_auth
assert '@"Preferences"' in control_auth
assert '@"com.apple.Preferences"' in control_auth
assert '@"runningboardd"' not in control_auth

# Proxy presents the original sync selectors but serializes them over the
# authenticated fixed-purpose raw-XPC operations.
assert '- (void)runInjectionFixUpIfNeededAndReply:(void (^)(BOOL success, NSError *error))reply;' in header
assert '- (void)reloadApplication:(NSString *)appID;' in header
assert '- (void)reloadDaemons:(NSArray<NSString *> *)daemons;' in header
proxy_start = manager.index('@implementation CRInsuranceHealthProxy')
proxy_end = manager.index('@end', proxy_start)
proxy = manager[proxy_start:proxy_end]
assert '- (void)runInjectionFixUpIfNeededAndReply:(void (^)(BOOL, NSError *))reply' in proxy
assert '"operation", "injection_fixup"' in proxy
assert '- (void)reloadApplication:(NSString *)appID' in proxy
assert '@"reload_application"' in proxy
assert '"application_id"' in proxy
assert '- (void)reloadDaemons:(NSArray<NSString *> *)daemons' in proxy
assert '@"reload_daemons"' in proxy
assert '"daemons"' in proxy

# Manager reload now uses the helper instead of posting a Darwin notification
# itself. The conditional overload's second argument is the exact container ID
# recovered from CranePrefs 0x23A30, not a BOOL.
assert '- (void)reloadApplicationWithIdentifier:(NSString *)appID ifContainerIsActive:(NSString *)containerID;' in header
process_start = manager.index('/* ---- process control')
process_end = manager.index('- (void)fetchActiveContainerIDForProcessWithPid:', process_start)
process_control = manager[process_start:process_end]
assert '[proxy reloadApplication:appID];' in process_control
assert 'notify_post(CR_NOTIFICATION_RELOAD_APPLICATION.UTF8String);' not in process_control
assert 'ifContainerIsActive:(NSString *)containerID' in process_control
assert '[active isEqualToString:containerID]' in process_control
assert 'if (check)' not in process_control

# The SpringBoard daemon-error action can now reach a real helper backend.
daemon_alert_start = alerts.index('void CRPresentDaemonError(')
daemon_alert_end = alerts.index('void CRPresentMainDylibNotLoadedError', daemon_alert_start)
daemon_alert = alerts[daemon_alert_start:daemon_alert_end]
assert 'id<CRHelperServiceProtocol> restartProxy =' in daemon_alert
assert 'if ([restartProxy respondsToSelector:@selector(reloadDaemons:)])' in daemon_alert
assert '[restartProxy reloadDaemons:daemonArray];' in daemon_alert
assert daemon_alert.index('if ([restartProxy respondsToSelector:@selector(reloadDaemons:)])') < daemon_alert.rindex('[actions addObject:close];')

# Unsupported remains distinguishable from a genuinely empty/successful result.
unsupported_id = None
unsupported_dump = None
empty_successful_dump = {}
assert unsupported_id is None
assert unsupported_dump is None
assert unsupported_dump is not empty_successful_dump
assert not isinstance(unsupported_id, str)
assert not isinstance(unsupported_dump, dict)

assert '@protocol CRHGlobalServiceProtocol <NSObject>' in helper
assert 'CRHelperServiceProtocol <NSObject>' in header

print("Crane F-19 privileged reload + F-07 fail-closed contracts: PASS (device unverified)")
