"""G-11 N0 contract: native Foundation ZIP64 Info reader + manifest builder.

No production Restore, app data traversal, Keychain access, ZIP creation,
device reload or override of currently unavailable Root action callbacks.
"""
from pathlib import Path
import re

repo = Path(__file__).resolve().parents[2]
native = repo / "reconstruction/sources/prefs"
header = (native / "CRBackupNativeCore.h").read_text(encoding="utf8")
source = (native / "CRBackupNativeCore.m").read_text(encoding="utf8")
make = (native / "Makefile").read_text(encoding="utf8")
smoke = (repo / "reconstruction/tools/native_backup_core_smoke.m").read_text(
    encoding="utf8")
fixtures = (repo / "reconstruction/tools/native_backup_reader_fixture.py").read_text(
    encoding="utf8")
tests = (repo / "reconstruction/tools/test_crane_native_backup_core.py").read_text(
    encoding="utf8")
prefs = (native / "CRPreferences.m").read_text(encoding="utf8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")
doc = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf8")

for marker in (
    "@interface CRBackupNativeCore",
    "readSingleBackupInfoAtPath:",
    "binarySingleInfoForApplicationIdentifier:",
    "writableMetadataAttributes:",
):
    assert marker in header
assert "CRBackupNativeCore.m" in make
assert "CranePrefs_LIBRARIES  = crane z iconv" in make
for marker in (
    "O_RDONLY", "O_NOFOLLOW",
    "fstat(fd, &fileStat)", "S_ISREG(fileStat.st_mode)",
    "CRArchiveLimit", "CRInfoLimit", "CRCompressedInfoLimit",
    "pread(fd, out, remaining, (off_t)offset)",
    "memcmp(name, \"Info.plist\"", "0x04034b50",
    "CR64(extra + cursor)", "UINT32_MAX",
    "CRReadFirstCentralInfo(fd, size, &central)",
    "CR32(eocd) != 0x06054b50", "CR32(central) != 0x02014b50",
    "central.flags != generalFlags", "central.method != method",
    "compressed = central.compressed;",
    "uncompressed = central.uncompressed;",
    "wantedCRC != central.crc",
    "(generalFlags & ~(uint16_t)0x0808)",
    "inflateInit2(&strm, -MAX_WBITS)",
    "dataWithLength:targetSize + 1",
    "CRReadInfoFromFD(fd, &failureStage)",
    "CRFail(error, failureStage)",
    "CR32(descriptor) != 0x08074b50",
    "crc32(0L, Z_NULL, 0)", "crc != wantedCRC",
    "NSPropertyListBinaryFormat_v1_0",
    "CRValidInfo(propertyList)", "originalPaths",
    "deviceIdentifierForVendor",
    "NSFileOwnerAccountID", "NSFileExtensionHidden",
    "NSFilePosixPermissions", "NSFileCreationDate",
    "CFGetTypeID", "CFBooleanGetTypeID",
    "return result;",
):
    assert marker in source, marker
assert "readSingleBackupInfoAtPath:" not in prefs
for illegal in (
    "wipeContainerWithIdentifier", "removeItemAtPath:",
    "writeToFile:", "moveItemAtPath:", "restoreKeychain",
    "SecItemAdd", "SecItemDelete", "kill(", "extractall",
    "opainject", "CraneManager.sharedManager",
):
    assert illegal not in source, illegal
for selector in (
    '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]',
    '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
):
    assert selector in prefs
assert 'NSLog(@"G-11 N0 native Foundation' in smoke
assert "readSingleBackupInfoAtPath:badCRC" in smoke
assert "binarySingleInfoForApplicationIdentifier:" in smoke
assert "writableMetadataAttributes:" in smoke
assert "force_zip64=True" in fixtures and "PK\\x07\\x08" in fixtures
assert "test_zip64_local_first_info_binary_plist" in tests
assert "test_bad_crc_descriptor_rejected_by_native_test_vector" in tests
assert "test_valid_zip64_descriptor_and_raw_deflate_stream_complete" in tests
assert "test_local_zip64_zero_sizes_resolve_to_central_actual_sizes" in tests
assert "test_tampered_central_size_and_crc_are_distinct_invalid_vectors" in tests
assert "crane-native-bad-central-size.cranect" in fixtures
assert "crane-native-bad-central-crc.cranect" in fixtures
assert "readSingleBackupInfoAtPath:badCentralSize" in smoke
assert "readSingleBackupInfoAtPath:badCentralCRC" in smoke
assert "crane-native-bad-central-size.cranect" in workflow
assert "crane-native-bad-central-crc.cranect" in workflow
assert "reader rejected synthetic ZIP at stage %ld" in smoke
assert "test_original_single_local_zip64_descriptor_matches_native_contract" in tests
assert "@unittest.skipUnless(ORIGINAL_FIXTURE.is_file()" in tests
assert "check_native_backup_core_contract.py" in workflow
assert "test_crane_native_backup_core.py" in workflow
assert "native_backup_core_smoke.m" in workflow
assert "CRBackupNativeCore.m" in workflow
assert "CRBackupNativeCore.m" in doc
print("G-11 N0 native Backup Info + read-only ZIP64 preview safety contract: PASS")
