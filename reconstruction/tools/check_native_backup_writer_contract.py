"""N2 source safety contract: native ZIP writer ONLY with memory dummy inputs.

Ensures the exported Objective-C writer cannot traverse original container
sources, read Keychain, overwrite an archive, or wire into production Restore.
"""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
root = repo / "reconstruction"
native = root / "sources/prefs"
src = (native / "CRBackupNativeFixtureWriter.m").read_text(encoding="utf8")
hdr = (native / "CRBackupNativeFixtureWriter.h").read_text(encoding="utf8")
smoke = (root / "tools/native_backup_fixture_writer_smoke.m").read_text(
    encoding="utf8")
verifier = (root / "tools/crane_native_writer_verify.py").read_text(
    encoding="utf8")
tests = (root / "tools/test_crane_native_writer_verify.py").read_text(
    encoding="utf8")
make = (native / "Makefile").read_text(encoding="utf8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")
prefs = (native / "CRPreferences.m").read_text(encoding="utf8")
audit = (root / "BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf8")

for required in (
    "writeDisposableSingleAtRoot:", "metadataData:", "files:",
    "directories:", "error:",
):
    assert required in hdr, required
assert "CRBackupNativeFixtureWriter.m" in make
assert "CranePrefs_LIBRARIES  = crane z iconv" in make
for required in (
    'CRMarkerBytes[] = "CRANE_DISPOSABLE_FIXTURE_V1\\n"',
    'CROutputName[] = "native-single.cranect"',
    "CRMaxFixtureBytes = 1024 * 1024",
    "CRMaxFixtureEntries = 64",
    "WBinaryPlist(info, NSDictionary.class)",
    "WBinaryPlist(metadata, NSDictionary.class)",
    "realpath(NSTemporaryDirectory().fileSystemRepresentation",
    "strncmp(realRoot, tempRoot, prefix)",
    "openat(rootFD, \".crane-disposable-fixture\"",
    "openat(rootFD, \"output\"",
    "openat(outputFD, CROutputName, flags, 0600)",
    "O_CREAT | O_EXCL",
    "O_NOFOLLOW",
    "unlinkat(outputFD, CROutputName, 0)",
    "W32(output, 0x04034b50)",
    "W32(output, UINT32_MAX); W32(output, UINT32_MAX)",
    "W64(output, 0); W64(output, 0)",
    "W32(output, 0x08074b50)",
    "W32(central, 0x02014b50)",
    "W16(central, 45); W16(central, 0x0808)",
    "W64(central, uncomp); W64(central, comp)",
    "W32(result, 0x06054b50)",
    "deflateInit2(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED",
    "if (files[prefix]) return NO",
    "[leaf.lowercaseString isEqualToString:@\"keychain.plist\"]",
    '@"restoreExecutable": @NO',
    '@"originalCompatibilityProven": @NO',
    '@"deviceDataTouched": @NO',
    '@"keychainContentsRead": @NO',
):
    assert required in src, required

for prohibited in (
    "SecItemCopyMatching", "SecItemAdd", "SecItemDelete",
    "CraneManager", "Cranehelperd", "opainject", "NSFileManager",
    "contentsOfDirectoryAtPath", "enumeratorAtPath",
    "readDataToEndOfFile", "kill(", "removeItemAtPath",
):
    assert prohibited not in src, prohibited

for required in (
    "readSingleBackupInfoAtPath:archive", "inspectSingleArchiveAtPath:archive",
    "infoData:info metadataData:metadata",
    "O_EXCL must prevent fixture overwrite",
    "path traversal should fail before filesystem access",
    "Keychain filename must never be written",
    "file/directory collision must fail",
    "unmarked non-disposable root",
    "CRANE_N2_FIXTURE=",
    "error.code == 1", "error.code == 2", "error.code == 3",
):
    assert required in smoke, required
for required in (
    "archive.read(\"Info.plist\")",
    "archive.read(\"Metadata.plist\")",
    "archive.read(\"com.example.crane.native/one.txt\")",
    "archive.read(\"com.example.crane.native/zero.txt\")",
    "member.flag_bits != 0x0808",
    "member.create_system != 19",
    "member.extract_version != 45",
    "struct.unpack_from(\"<IQQ\", descriptor, 4)",
    '"restoreExecutable": False',
    '"originalCompatibilityProven": False',
    '"keychainContentsRead": False',
    '"filesystemWrites": False',
):
    assert required in verifier, required
assert "test_cli_failure_has_fixed_redacted_status" in tests
assert "check_native_backup_writer_contract.py" in workflow
assert "test_crane_native_writer_verify.py" in workflow
assert "crane_native_writer_verify.py --archive" in workflow
assert "native_backup_fixture_writer_smoke.m" in workflow
assert "CRBackupNativeFixtureWriter.m" in workflow
assert "CRBackupNativeFixtureWriter.m" in audit
for disabled in (
    '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]',
    '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
):
    assert disabled in prefs
print("G-11 N2 disposable in-memory ZIP64 native writer contract: PASS")
