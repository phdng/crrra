"""G-11 N7: type-aware app/App Group/PlugInKit roots, read-only."""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
pref = repo / "reconstruction/sources/prefs"
header = (pref / "CRBackupNativeTypedPreflight.h").read_text(encoding="utf8")
source = (pref / "CRBackupNativeTypedPreflight.m").read_text(encoding="utf8")
n6 = (pref / "CRBackupNativeManagerPreflight.m").read_text(encoding="utf8")
n6h = (pref / "CRBackupNativeManagerPreflight.h").read_text(encoding="utf8")
manager = (repo / "reconstruction/sources/libcrane/CRManager.m").read_text(encoding="utf8")
tests = (repo / "reconstruction/tools/test_crane_native_typed_preflight.py").read_text(encoding="utf8")
smoke = (repo / "reconstruction/tools/native_backup_typed_preflight_smoke.m").read_text(encoding="utf8")
n6smoke = (repo / "reconstruction/tools/native_backup_manager_bridge_smoke.m").read_text(encoding="utf8")
ci = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")
make = (pref / "Makefile").read_text(encoding="utf8")
prefs = (pref / "CRPreferences.m").read_text(encoding="utf8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf8")

assert "@protocol CRBackupTypedSourceResolver <CRBackupSourceResolver>" in header
assert "CRBackupNativeTypedPreflight.m" in make
for term in (
    "block(0, appID, path, &stop)", "block(1, identifier, path, &stop)",
    "block(2, identifier, path, &stop)",
):
    assert term in manager, term
for required in (
    "CR7MaxRoots = 32",
    "CRBackupNativeSourcePreflight",
    "preflightApplicationIdentifier:applicationID",
    "CR7TypedSnapshot(resolver, applicationID",
    "BOOL firstValid = NO, secondValid = NO",
    "![first isEqualToDictionary:second]",
    "mapping.count != first.count",
    "type == 0 || type == 1 || type == 2",
    "appRoots == 1",
    "[rows objectForKey:identifier]",
    "rows.count >= CR7MaxRoots",
    "[path isEqualToString:entry[@\"path\"]]",
    '[n5[@"rootCount"] unsignedIntegerValue]',
    '[n5[@"associatedGroupCount"] unsignedIntegerValue]',
    '@"applicationRootCount":@(appRoots)',
    '@"appGroupRootCount":@(groups)',
    '@"plugInKitRootCount":@(plugins)',
    '@"rootDirectoryMetadataChecked":@(first.count)',
    "NSDictionary *lastRoots = [CRBackupNativeSourcePreflight",
    '![lastRoots[@"sourceDirectoryRootsReadable"] isEqual:@YES]',
    '[lastRoots[@"rootCount"] unsignedIntegerValue] != first.count',
    '[lastRoots[@"associatedGroupCount"] unsignedIntegerValue] != groups + plugins',
    "CR7Fail(error, 8)",
    "NSDictionary *lastMapping = nil",
    "NSDictionary *initialMapping = nil",
    "CRBackupNativeRootIdentitySnapshot *rootIdentity",
    "captureRootIdentityForMapping:initialMapping",
    "isRootIdentityUnchangedFromSnapshot:rootIdentity mapping:lastMapping",
    "CR7Fail(error, 10)", "CR7Fail(error, 11)",
    "![mapping isEqualToDictionary:lastMapping]",
    "CR7Fail(error, 9)",
    '@"sourceFilesEnumerated":@NO',
    '@"sourceContentsRead":@NO',
    '@"keychainContentsRead":@NO',
    '@"backupReady":@NO',
    '@"restoreExecutable":@NO',
):
    assert required in source, required

for denied in (
    "readdir(", "open(", "fstatat(", "read(", "write(",
    "NSLog(", "SecItem", "KeychainItems", "CraneManager sharedManager",
    "setActiveContainer", "createNewContainer", "removeItemAtPath:",
    "moveItemAtPath:", "CFPreferencesSet",
):
    assert denied not in source, denied
assert "probeTypedRegisteredApplication:" in n6h
assert "resolver:(id<CRBackupTypedSourceResolver>)manager" in n6
assert "probeTypedRegisteredApplication:app" in n6smoke
assert "CR6MockTypedEnumerate" in n6smoke
assert "resolver.mode = 1; Reject(resolver, 3)" in smoke
assert "resolver.mode = 5; resolver.passes = 0;" in smoke
assert source.count("preflightApplicationIdentifier:applicationID") == 2
assert source.index("NSDictionary *initialMapping") < source.index("BOOL firstValid")
assert source.index("NSDictionary *lastMapping") < source.index("isRootIdentityUnchangedFromSnapshot")
assert "resolver.mode = 10; resolver.passes = 0;" in smoke
assert "Reject(resolver, 11)" in smoke
assert source.index("NSDictionary *lastRoots") < source.index("NSDictionary *lastMapping")
for marker in (
    "resolver.mode = 7; resolver.supportCalls = 0;",
    "resolver.mode = 8; resolver.mapReads = 0;",
    "resolver.mode = 9; resolver.mapReads = 0;",
    "resolver.mode = 10; resolver.passes = 0;",
    "Reject(resolver, 8)", "Reject(resolver, 9)",
):
    assert marker in smoke, marker
assert "test_recovered_original_typed_api_from_manager" in tests
assert "check_native_typed_preflight_contract.py" in ci
assert "test_crane_native_typed_preflight.py" in ci
assert "native_backup_typed_preflight_smoke.m" in ci
assert "CRBackupNativeTypedPreflight.m" in ci
assert "CRBackupNativeTypedPreflight.m" in audit
assert "probeTypedRegisteredApplication:" not in prefs
assert '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]' in prefs
assert '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]' in prefs

print("G-11 N7/N9/N10 typed root and inode identity diagnostic contract: PASS")
