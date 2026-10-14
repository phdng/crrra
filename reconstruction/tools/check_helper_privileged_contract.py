"""F-19/F-07 conservative daemon XPC delegate contracts.

The original cranehelperd binary is not decompiled (U-01). Its helperd
identifier persistence and keychain backup schema are unknown. A previous
reconstruction replied with a daemon-local NSUserDefaults identifier and
with an empty dictionary for any keychain dump; both can be misread as real
successful state. This contract requires unsupported operations to be
clearly distinguishable from success, while leaving the small authenticated
raw-XPC health surface unchanged.

Static/source + independent result model only, not an iOS runtime test.
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

# Don't replace the original protocol ABI nor allow these privileged calls
# through the only live authenticated reconstruction raw-XPC surface.
assert '- (void)getIdentifierOfType:(uint64_t)type' in helper
assert '- (void)setIdentifier:(NSString *)identifier' in helper
assert '- (void)dumpKeychainItemsForContainerIdentifier:(NSString *)containerID' in helper
assert '- (void)restoreKeychainItems:(NSDictionary *)items' in helper
raw = helper[helper.index("static NSString *CRHandleHealthRequest("):
             helper.index("#pragma mark - main")]
for item in ("setIdentifier", "getIdentifierOfType", "dumpKeychainItems",
             "restoreKeychainItems", "setPreferenceValue:",
             "runInjectionFixUpIfNeededAndReply", "reload_daemons"):
    assert item not in raw, item
assert 'strcmp(operation, "insurance") == 0' in raw
assert 'strcmp(operation, "lookup_pid") == 0' in raw
assert 'strcmp(operation, "injection_fixup") == 0' in raw
assert 'CRRunCraneSupportInjectionFixup(&fixError)' in raw
assert 'CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID)' in raw
assert '[peerProcess isEqualToString:@"SpringBoard"]' in raw
fixup_raw = raw[
    raw.index('if (strcmp(operation, "injection_fixup") == 0)'):
    raw.index('} else if (strcmp(operation, "insurance")')
]
assert 'xpc_dictionary_get_int64(message, "pid")' not in fixup_raw
assert 'xpc_dictionary_get_string(message, "path")' not in fixup_raw
assert 'xpc_dictionary_get_string(message, "dylib")' not in fixup_raw
assert '@"/Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib"' in helper
assert 'CRSupportFixupTargets(' in helper
assert 'CRPidMapsImageLeaf(pid, @"CraneSupport.dylib"' in helper

# Independent model: unsupported is None, whereas a genuinely empty dump
# would be {} and a genuine vendor-ID read would be a nonempty string.
unsupported_id = None
unsupported_dump = None
empty_successful_dump = {}
assert unsupported_id is None
assert unsupported_dump is None
assert unsupported_dump is not empty_successful_dump
assert not isinstance(unsupported_id, str)
assert not isinstance(unsupported_dump, dict)

# The service declarations remain in place; no speculative connection to
# the live CraneSupport/lsd transport has been added.
assert '@protocol CRHGlobalServiceProtocol <NSObject>' in helper
assert 'CRHelperServiceProtocol <NSObject>' in header

# CraneSB 0x1782C sends the original privileged fix-up selector through the
# async helper proxy. U-01 means its helper implementation is unavailable: the
# reconstruction must preserve the selector/reply ABI but return an explicit
# failure rather than fabricate a successful fix-up or add a raw-XPC command.
assert '- (void)runInjectionFixUpIfNeededAndReply:(void (^)(BOOL success, NSError *error))reply;' in header
proxy_start = manager.index('@implementation CRInsuranceHealthProxy')
proxy_end = manager.index('@end', proxy_start)
proxy = manager[proxy_start:proxy_end]
assert '- (void)runInjectionFixUpIfNeededAndReply:(void (^)(BOOL, NSError *))reply' in proxy
assert '"operation", "injection_fixup"' in proxy
assert 'CRHelperValidateHealthReply(' in proxy
assert 'xpc_dictionary_get_bool(response, "authorized")' in proxy
assert 'xpc_dictionary_get_bool(response, "success")' in proxy
assert 'CRHelperUnauthorizedPeer' in proxy
assert '(int64_t)(30 * NSEC_PER_SEC)' in proxy
async_start = manager.index('- (id)cranehelperdGlobalAsyncRemoteObjectProxy')
async_end = manager.index('/* A filter plist', async_start)
async_proxy = manager[async_start:async_end]
assert 'return [self cranehelperdGlobalSyncRemoteObjectProxy];' in async_proxy

# Original CraneSB 0x1A53C calls privileged reloadDaemons: before relaunching
# SpringBoard. U-01 does not recover that root implementation and the narrow
# raw-XPC adapter deliberately does not expose it. Do not show a restart action
# that would only relaunch SpringBoard while leaving the affected daemons stale.
assert '- (void)reloadDaemons:(NSArray<NSString *> *)daemons {}' in delegate
assert '- (void)reloadDaemons:' not in proxy
daemon_alert_start = alerts.index('void CRPresentDaemonError(')
daemon_alert_end = alerts.index('void CRPresentMainDylibNotLoadedError', daemon_alert_start)
daemon_alert = alerts[daemon_alert_start:daemon_alert_end]
assert 'id<CRHelperServiceProtocol> restartProxy =' in daemon_alert
assert 'if ([restartProxy respondsToSelector:@selector(reloadDaemons:)])' in daemon_alert
assert '[restartProxy reloadDaemons:daemonArray];' in daemon_alert
assert 'daemon restart action unavailable; privileged reloadDaemons backend is not reconstructed' in daemon_alert
assert daemon_alert.index('if ([restartProxy respondsToSelector:@selector(reloadDaemons:)])') < daemon_alert.rindex('[actions addObject:close];')

print("Crane F-19/F-07 unavailable privileged delegate contracts: PASS (device unverified)")
