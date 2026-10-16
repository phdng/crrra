"""G-11 N1: enforce native read-only ZIP central/local survey boundaries."""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
native = repo / "reconstruction/sources/prefs"
source = (native / "CRBackupArchiveSurvey.m").read_text(encoding="utf-8")
header = (native / "CRBackupArchiveSurvey.h").read_text(encoding="utf-8")
makefile = (native / "Makefile").read_text(encoding="utf-8")
tests = (repo / "reconstruction/tools/test_crane_native_backup_survey.py").read_text(encoding="utf-8")
fixture = (repo / "reconstruction/tools/native_backup_survey_fixture.py").read_text(encoding="utf-8")
smoke = (repo / "reconstruction/tools/native_backup_survey_smoke.m").read_text(encoding="utf-8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf-8")
prefs = (native / "CRPreferences.m").read_text(encoding="utf-8")

assert "inspectSingleArchiveAtPath:" in header
assert "CRBackupArchiveSurvey.m" in makefile
for expected in (
    "O_RDONLY", "O_NOFOLLOW", "S_ISREG", "pread(fd, bytes",
    "CRSurveyArchiveLimit", "CRSurveyPayloadLimit",
    "CRSurveyMemberLimit", "CRSurveyDirectoryLimit",
    "S32(e) != 0x06054b50", "S32(c) != 0x02014b50",
    "S32(lh) != 0x04034b50", "SZIP64(extra, extraSize",
    "SName(name, isDirectory)", "paths containsObject:logical",
    '![name isEqualToString:@"Info.plist"]',
    '![actualFiles containsObject:@"Info.plist"]',
    "i != entries-1 || hasMetadata", "kind == 0120000",
    "memcmp(localName, rawName, nameSize)",
    "S32(descriptor) != 0x08074b50",
    "S32(descriptor+4) != S32(c+16)",
    "dComp != comp || dUncomp != uncomp",
    "totalUncompressed > CRSurveyPayloadLimit-uncomp",
    "local < previousEnd", "i == 0 && local != 0",
    "[actualFiles containsObject:ancestor]",
    '"payloadCRCVerified": @NO',
    '"keychainContentsRead": @NO',
    '"restoreExecutable": @NO',
    "single_archive_structure_inspected_not_restorable",
):
    assert expected in source, expected
for blocked in (
    "writeToFile:", "writestr", "extractall", "ZipArchive", "SecItemCopyMatching",
    "SecItemAdd", "SecItemDelete", "CraneManager", "opainject",
    "removeItemAtPath", "moveItemAtPath", "createFileAtPath",
    "NSLog(",
):
    assert blocked not in source, blocked
assert "report.count == 10" in smoke
assert "SSurvey(fd, NO)" in source  # N1 remains header-only
assert "SSurvey(fd, YES)" in source  # N3 separate explicit CRC API
assert "crane-survey-keychain-shape.cranect" in fixture
assert "crane-survey-descriptor-mismatch.cranect" in fixture
assert "test_keychain_only_presence_not_contents" in tests
assert "test_original_single_central_header_evidence_only" in tests
assert "check_native_backup_survey_contract.py" in workflow
assert "test_crane_native_backup_survey.py" in workflow
assert "native_backup_survey_smoke.m" in workflow
assert "CRBackupArchiveSurvey.m" in workflow
assert "CRBackupArchiveSurvey.m" in audit
assert '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]' in prefs
print("G-11 N1 central/local ZIP survey read-only native contract: PASS")
