"""G-11 N5: source-map provenance and redacted, read-only preflight guard."""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
native = repo / "reconstruction/sources/prefs"
src = (native / "CRBackupNativeSourcePreflight.m").read_text(encoding="utf8")
hdr = (native / "CRBackupNativeSourcePreflight.h").read_text(encoding="utf8")
mgr = (repo / "reconstruction/sources/common/CRManager.h").read_text(encoding="utf8")
smoke = (repo / "reconstruction/tools/native_backup_source_preflight_smoke.m").read_text(encoding="utf8")
tests = (repo / "reconstruction/tools/test_crane_native_source_preflight.py").read_text(encoding="utf8")
make = (native / "Makefile").read_text(encoding="utf8")
ci = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf8")
prefs = (native / "CRPreferences.m").read_text(encoding="utf8")

assert "@protocol CRBackupSourceResolver" in hdr
for selector in (
    "isApplicationSupportedByCrane:",
    "containerIdentifiersOfApplicationWithIdentifier:",
    "pathsAssociatedToContainerWithIdentifier:",
    "ofApplicationWithIdentifier:",
):
    assert selector in hdr and selector in mgr
assert "preflightApplicationIdentifier:" in hdr
assert "CRBackupNativeSourcePreflight.m" in make
for required in (
    "CR5SafeID(applicationID)", "CR5SafeID(containerID)",
    "[resolver isApplicationSupportedByCrane:applicationID]",
    "[registered containsObject:containerID]",
    "mapping[applicationID]",
    "mapping.count > CR5MaxRoots",
    "CR5SafeID(identifier)", "CR5RootPath(mapping[identifier], NULL)",
    "CR5Ancestor(existing, canonical)", "CR5Ancestor(canonical, existing)",
    '"/private/var/mobile/Containers/"',
    "realpath(NSTemporaryDirectory().fileSystemRepresentation",
    "lstat(", "fstat(", "O_NOFOLLOW",
    "first.st_dev == opened.st_dev", "after.st_ino == opened.st_ino",
    "captureRootIdentityForMapping:", "isRootIdentityUnchangedFromSnapshot:",
    "CR5RootPath(mapping[identifier], &identity)",
    '@"device":@((unsigned long long)identity.st_dev)',
    '@"inode":@((unsigned long long)identity.st_ino)',
    "snapshot.identityByID isEqualToDictionary:current.identityByID",
    '@"sourceFilesEnumerated":@NO',
    '@"sourceContentsRead":@NO',
    '@"keychainContentsRead":@NO',
    '@"backupReady":@NO',
    '@"restoreExecutable":@NO',
):
    assert required in src, required
for prohibited in (
    "readdir(", "fstatat(", "read(", "write(",
    "SecItemCopyMatching", "SecItemDelete", "SecItemAdd",
    "[CraneManager sharedManager]", "removeItemAtPath", "moveItemAtPath",
    "contentsOfDirectoryAtPath", "createFileAtPath", "opainject",
    "NSLog(",
):
    assert prohibited not in src, prohibited
for marker in (
    "CR5FakeResolver", "createSymbolicLinkAtPath:alias",
    "ExpectError(resolver, App, Container, 7)",
    "ExpectError(resolver, App, Container, 8)",
    "ExpectError(resolver, App, Container, 6)",
    "ExpectError(resolver, App, Container, 5)",
    "registered_source_roots_accessible_not_backup_ready",
):
    assert marker in smoke, marker
assert "test_preflight_must_not_grant_permission_to_backup_or_restore" in tests
assert "check_native_source_preflight_contract.py" in ci
assert "test_crane_native_source_preflight.py" in ci
assert "native_backup_source_preflight_smoke.m" in ci
assert "CRBackupNativeSourcePreflight.m" in ci
assert "CRBackupNativeSourcePreflight.m" in audit
assert "preflightApplicationIdentifier:" not in prefs
for action in (
    '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]',
    '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
):
    assert action in prefs
print("G-11 N5 resolver-backed source-roots preflight read-only contract: PASS")
