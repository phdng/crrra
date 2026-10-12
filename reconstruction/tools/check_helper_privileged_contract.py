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
             "restoreKeychainItems", "setPreferenceValue:"):
    assert item not in raw, item
assert 'strcmp(operation, "insurance") == 0' in raw
assert 'strcmp(operation, "lookup_pid") == 0' in raw

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
print("Crane F-19/F-07 unavailable privileged delegate contracts: PASS (device unverified)")
