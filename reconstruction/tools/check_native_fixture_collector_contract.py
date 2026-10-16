"""N4 source contract: hardcoded OS-temp fake app root, bounded POSIX scan.

No production restore or app-container traversal. The macOS native smoke is
the only positive integration test, verified with independent Python ZIP CRC
and stat-backed metadata comparisons.
"""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
native = repo / "reconstruction/sources/prefs"
h = (native / "CRBackupNativeFixtureCollector.h").read_text(encoding="utf8")
m = (native / "CRBackupNativeFixtureCollector.m").read_text(encoding="utf8")
smoke = (repo / "reconstruction/tools/native_backup_fixture_collector_smoke.m").read_text(encoding="utf8")
verifier = (repo / "reconstruction/tools/crane_native_collector_verify.py").read_text(encoding="utf8")
tests = (repo / "reconstruction/tools/test_crane_native_fixture_collector.py").read_text(encoding="utf8")
make = (native / "Makefile").read_text(encoding="utf8")
ci = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf8")
prefs = (native / "CRPreferences.m").read_text(encoding="utf8")

assert "writeDisposableSourceBackupAtRoot:" in h
assert "containerPath:" not in h and "sourcePath:" not in h
assert "CRBackupNativeFixtureCollector.m" in make
for term in (
    'CN4App = @"com.example.crane.native"',
    'CN4Marker[] = "CRANE_DISPOSABLE_FIXTURE_V1\\n"',
    "CN4MaxEntries = 30", "CN4MaxBytes = 512 * 1024",
    "CN4MaxSingleFile = 256 * 1024", "CN4MaxDepth = 6",
    "NSTemporaryDirectory().fileSystemRepresentation", "realpath(",
    'openat(top, ".crane-disposable-fixture"',
    'openat(top, "source"', "CN4App.UTF8String",
    "fstatat(fd, entry->d_name, &before, AT_SYMLINK_NOFOLLOW)",
    "CN4DirectoryFlags()", "openat(parent, name, flags)",
    "expected->st_nlink != 1", "first.st_nlink != 1",
    "first.st_ino != expected->st_ino",
    "last.st_ctimespec.tv_nsec != first.st_ctimespec.tv_nsec",
    "CN4Count(entries)", "CN4ReadRegular(",
    "getpwuid_r(", "getgrgid_r(",
    "st->st_birthtimespec", "st->st_mtimespec",
    "NSFileOwnerAccountID", "NSFileOwnerAccountName",
    "NSFileGroupOwnerAccountID", "NSFileGroupOwnerAccountName",
    "NSFileCreationDate", "NSFileModificationDate",
    "NSFilePosixPermissions",
    "binaryMetadataForIndexedAttributes:metadata",
    "writeDisposableSingleAtRoot:root infoData:info metadataData:meta",
    '@"metadataFromFilesystem":@YES',
    '@"productionBackupAvailable":@NO', '@"restoreExecutable":@NO',
):
    assert term in m, term
for illegal in (
    "SecItemCopyMatching", "SecItemAdd", "SecItemDelete",
    "CraneManager", "Cranehelperd", "opainject", "containerURLFor",
    "NSFileExtensionHidden:", "removeItemAtPath:", "moveItemAtPath:",
    "createFileAtPath:", "chmod(", "chown(", "unlinkat(", "renameat(",
):
    assert illegal not in m, illegal
for term in (
    "writeDisposableSourceBackupAtRoot:root", "writeDisposableSourceBackupAtRoot:root error:&error",
    "readSingleBackupInfoAtPath:", "inspectSingleArchiveAtPath:",
    "verifyNonKeychainPayloadAtPath:",
    "symlink(", "link(", "Keychain.plist", "oversize.bin",
    "CRANE_N4_FIXTURE=", "CheckNoOutput(",
):
    assert term in smoke, term
for term in (
    "zf.testzip()", "metadata = plistlib.loads(",
    "pwd.getpwuid(", "grp.getgrgid(",
    "NSFilePosixPermissions", "NSFileCreationDate",
    "NSFileOwnerAccountName",
    '"productionBackupAvailable": False',
    '"restoreExecutable": False', '"filesystemWrites": False',
):
    assert term in verifier, term
assert "NSFileExtensionHidden:" not in m
assert "test_cli_returns_fixed_status_without_disclosing_fixture_root" in tests
assert "check_native_fixture_collector_contract.py" in ci
assert "test_crane_native_fixture_collector.py" in ci
assert "native_backup_fixture_collector_smoke.m" in ci
assert "crane_native_collector_verify.py --fixture-root" in ci
assert "CRBackupNativeFixtureCollector.m" in ci
assert "CRBackupNativeFixtureCollector.m" in audit
for key in (
    '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]',
    '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
):
    assert key in prefs
print("G-11 N4 disposable native source scan + stat metadata contract: PASS")
