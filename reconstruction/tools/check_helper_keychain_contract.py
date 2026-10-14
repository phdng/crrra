"""Recovered cranehelperd keychain move/delete contracts.

The original helper has eight CRHKeychain class methods. This contract locks the
high-confidence move/delete subset recovered directly from the original Mach-O:
access-group derivation is helper-side, all five SecItem classes are updated or
deleted, errSecItemNotFound is success, and raw-XPC callers can only supply
app/container identifiers (never arbitrary access groups/queries).
"""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[1]
workspace = root.parent
helper = (root / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRManager.h").read_text(encoding="utf-8")
diag = (root / "sources/common/CRXPCDiagnostics.h").read_text(encoding="utf-8")
classes = json.loads((workspace / "analysis/objc_classes.json").read_text(encoding="utf-8"))

keychain = classes["cranehelperd"]["CRHKeychain"]
class_methods = {m["sel"]: m for m in keychain["class_methods"]}
expected = {
    "craneStringForContainerIdentifier:": "0x100007B2C",
    "redirectedAccessGroupForAccessGroup:containerIdentifier:": "0x100007B40",
    "accessGroupsForApplicationWithIdentifier:": "0x100007C04",
    "moveKeychainItemsFromContainerWithIdentifier:toContainerWithIdentifier:forApplicationWithIdentifier:": "0x100007D88",
    "deleteKeychainItemsForContainerWithIdentifier:forApplicationIdentifier:": "0x100008048",
    "dumpKeychainItemsFromContainerWithIdentifier:forApplicationIdentifier:": "0x100008220",
    "restoreKeychainItemsToContainerWithIdentifier:forApplicationIdentifier:fromDictionary:": "0x1000086CC",
    "migrateApplication:withAppSettings:": "0x100008A68",
}
assert set(expected).issubset(class_methods), set(expected) - set(class_methods)
for selector, imp in expected.items():
    assert class_methods[selector]["imp"].upper() == imp.upper(), (
        selector, class_methods[selector]["imp"], imp
    )

# Exact recovered access-group namespace + ignore list.
for token in (
    '@".c_r_a_n_e."',
    "CR_DEFAULT_CONTAINER_IDENTIFIER",
    '@"keychain-access-groups"',
    '@"com.apple.security.application-groups"',
    '@"application-identifier"',
    '@"com.apple.token"',
    '@"com.apple.certificates"',
    '@"com.apple.identities"',
    '@"apple"',
    '@"com.apple.cfnetwork"',
    '@"com.apple.ProtectedCloudStorage"',
    '@"com.apple.passd"',
    '@"com.apple.managed.vpn.shared"',
):
    assert token in helper, token

# The original loops all five classes and treats not-found as success.
for token in (
    "kSecClassGenericPassword",
    "kSecClassInternetPassword",
    "kSecClassCertificate",
    "kSecClassKey",
    "kSecClassIdentity",
    "status == errSecSuccess || status == errSecItemNotFound",
    'classQuery[@"craneprefs_unrestrict"] = @YES;',
    "SecItemUpdate(",
    "SecItemDelete(",
    "kSecAttrAccessGroup",
    "kSecAttrSynchronizableAny",
):
    assert token in helper, token

impl_start = helper.index("@implementation CRHKeychain")
move_start = helper.index(
    "+ (BOOL)moveKeychainItemsFromContainerWithIdentifier:", impl_start
)
move_end = helper.index(
    "+ (BOOL)deleteKeychainItemsForContainerWithIdentifier:", move_start
)
move = helper[move_start:move_end]
assert "accessGroupsForApplicationWithIdentifier:appID" in move
assert "redirectedAccessGroupForAccessGroup:baseGroup" in move
assert "CRHSecItemUpdateAllClasses(query, update)" in move

delete_start = move_end
delete_end = helper.index("@end", delete_start)
delete = helper[delete_start:delete_end]
assert "accessGroupsForApplicationWithIdentifier:appID" in delete
assert "CRHSecItemDeleteAllClasses(query)" in delete

# Fixed-purpose raw-XPC surface: caller cannot provide access group/Sec query.
for op in ('"move_keychain_items"', '"delete_keychain_items"'):
    assert op in helper, op
for field in (
    '"application_id"',
    '"source_container_id"',
    '"destination_container_id"',
    '"container_id"',
):
    assert field in helper, field
assert "CRIsAuthenticatedCraneControlPeer(peerProcess, peerSigningID)" in helper
assert 'xpc_dictionary_get_string(message, "access_group")' not in helper
assert 'xpc_dictionary_get_value(message, "query")' not in helper

# Client adapter exposes the recovered original selector shapes.
for token in (
    "moveKeychainItemsFromContainerWithIdentifier:(NSString *)sourceContainer",
    "toContainerWithIdentifier:(NSString *)destinationContainer",
    "forApplicationWithIdentifier:(NSString *)appID",
    "reply:(void (^)(BOOL success))reply",
    "deleteKeychainItemsForContainerWithIdentifier:(NSString *)containerID",
    "forApplicationIdentifier:(NSString *)appID",
):
    assert token in header, token
    assert token in manager, token
assert '@"move_keychain_items"' in manager
assert '@"delete_keychain_items"' in manager

assert "CRHelperInvalidRequest = 1011" in diag
assert "CRHelperOperationFailed = 1012" in diag

# Keep the raw-XPC keychain error helper defined before any call to it.
# A missing definition previously passed source contracts but failed the
# macOS Theos/Clang build with -Wimplicit-function-declaration.
error_helper = helper.index("static void CRSetReplyError(")
request_handler = helper.index("static NSString *CRHandleHealthRequest(")
assert error_helper < request_handler
error_body = helper[error_helper:request_handler]
for field in (
    'xpc_dictionary_set_string(reply, "error_domain",',
    '"com.opa334.crane.helper.transport"',
    'xpc_dictionary_set_int64(reply, "error_code", (int64_t)code)',
    'xpc_dictionary_set_string(reply, "error_description",',
):
    assert field in error_body, field
assert helper.count("CRSetReplyError(reply, CRHelperInvalidRequest,") == 2
assert helper.count("CRSetReplyError(reply, CRHelperOperationFailed,") == 2

print("Crane helper keychain move/delete contracts: PASS (device unverified)")
