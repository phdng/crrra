"""G-11 N3 contract: non-Keychain streaming CRC32, no extraction/Restore."""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
pref = repo / "reconstruction/sources/prefs"
source = (pref / "CRBackupArchiveSurvey.m").read_text(encoding="utf8")
header = (pref / "CRBackupArchiveSurvey.h").read_text(encoding="utf8")
fixture = (repo / "reconstruction/tools/native_backup_survey_fixture.py").read_text(encoding="utf8")
tests = (repo / "reconstruction/tools/test_crane_native_crc_verification.py").read_text(encoding="utf8")
smoke = (repo / "reconstruction/tools/native_backup_crc_smoke.m").read_text(encoding="utf8")
n2 = (repo / "reconstruction/tools/native_backup_fixture_writer_smoke.m").read_text(encoding="utf8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")
doc = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf8")
prefs = (pref / "CRPreferences.m").read_text(encoding="utf8")

for term in (
    "verifyNonKeychainPayloadAtPath:", "no archive extraction",
):
    # The header describes the safety semantics even if the exact phrase
    # appears with different capitalization.
    assert term in header or (term == "no archive extraction" and
                             "no archive extraction" in header.lower()), term
for term in (
    "SVerifyEntryCRC(int fd", "uint8_t input[32768], output[32768]",
    "inflateInit2(&stream, -MAX_WBITS)", "inflate(&stream, Z_NO_FLUSH)",
    "crc32(crc, output, (uInt)got)", "crc32(crc, input, (uInt)count)",
    "got > uncompressed-produced", "stream.avail_in != 0 || consumed != compressed",
    "produced != uncompressed", "(uint32_t)crc != expectedCRC",
    'BOOL isKeychain = [[[name lastPathComponent] lowercaseString]',
    'isEqualToString:@"keychain.plist"]', 
    "if (verifyCRC && !isKeychain)",
    "SSurvey(fd, NO)", "SSurvey(fd, YES)",
    'report[@"nonKeychainPayloadCRCVerified"] = @YES;',
    'report[@"keychainEntriesSkipped"] = @(keychain);',
    'report[@"payloadCRCVerified"] = @(keychain == 0);',
    '@"restoreExecutable": @NO',
):
    assert term in source, term
for blocked in (
    "writeToFile:", "removeItemAtPath:", "moveItemAtPath:",
    "SecItemAdd", "SecItemCopyMatching", "SecItemDelete",
    "CraneManager", "opainject", "NSLog(", "createFileAtPath:",
):
    assert blocked not in source, blocked

for name in ("crane-survey-payload-corrupt.cranect",
             "crane-survey-keychain-corrupt.cranect",
             "crane-survey-large-payload.cranect",
             "crane-survey-stored-payload.cranect"):
    assert name in fixture, name
for test in (
    "test_crc_corrupted_ordinary_payload_with_intact_zip_headers",
    "test_tampered_keychain_compressed_bytes_are_not_read_by_n3",
    "test_large_incompressible_like_dummy_payload_crosses_buffer",
    "test_zip_stored_nonempty_dummy_file",
):
    assert test in tests, test
assert "verifyNonKeychainPayloadAtPath:path" in smoke
assert "inspectSingleArchiveAtPath:path" in smoke
assert "verifyNonKeychainPayloadAtPath:archive" in n2
assert "check_native_backup_crc_contract.py" in workflow
assert "test_crane_native_crc_verification.py" in workflow
assert "native_backup_crc_smoke.m" in workflow
assert "CRBackupArchiveSurvey.m" in workflow and " -lz " in workflow
assert "N3" in doc and "verifyNonKeychainPayloadAtPath" in doc
assert '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]' in prefs
print("G-11 N3 streamed non-Keychain CRC and Root Restore fail-closed: PASS")
