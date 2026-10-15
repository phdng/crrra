"""G-11 original-reference evidence contract: READ ONLY, PRIVATE ZIP not in Git."""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[2]
base = root / "reconstruction/tools"
source = (base / "crane_original_archive_audit.py").read_text(encoding="utf8")
tests = (base / "test_crane_original_archive_audit.py").read_text(encoding="utf8")
workflow = (root / ".github/workflows/build.yml").read_text(encoding="utf8")
docs = (root / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf8")
prefs = (root / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf8")
helper = (root / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf8")

tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        assert all(part.name.split(".")[0] not in {
            "shutil", "subprocess", "socket", "ctypes", "requests",
        } for part in node.names)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        assert node.func.attr not in {
            "extract", "extractall", "write", "writestr", "unlink",
            "remove", "rename", "replace", "mkdir", "rmdir", "rmtree",
            "chmod", "chown", "link", "move", "copy", "open",
        }, node.func.attr
assert "with zipfile.ZipFile(source, mode=\"r\") as zf:" in source
assert "inspect_archive(source, verify_payload=verify_payload)" in source
assert "archive_profile(source, verify_payload=False)" in source
assert "_read_small_plist(zf, zf.getinfo(metadata_member))" in source
assert "WRITABLE_FILE_ATTRIBUTES" in source
assert 'or item.filename.endswith("/Keychain.plist")' in source
assert "keychain_contents_read" in source
assert '"original_compatibility_proven": False' in source
assert '"payload_extracted": False' in source
assert '"filesystem_writes": False' in source
assert '"restore_safe": False' in source
assert "orphaned_metadata_records" in source
assert "zip_data_without_metadata" in source
assert "attribute_presence_counts" in source
assert "attribute_value_types" in source
assert "attribute_set_variants" in source
assert "original_structure_accepted_not_parity_proof" in source
assert "original_format_inspector_rejected" in source
assert "original_format_unsupported" in source
assert "original_archive_unavailable_or_invalid" in source
assert "test_crane_original_archive_audit.py" in workflow
assert "check_original_archive_audit_contract.py" in workflow
assert "crane_original_archive_audit.py" in docs
for testcase in (
    "test_synthetic_audit_report_is_redacted",
    "test_fixture_metadata_key_counts_are_statically_named",
    "test_keychain_presence_only_not_contents",
    "test_invalid_archive_is_fixed_status_without_member_name",
    "test_cli_redacts_all_source_values",
    "test_local_genuine_crane_fixture_metadata_and_crc",
):
    assert testcase in tests, testcase
assert "@unittest.skipUnless(ORIGINAL_FIXTURE.is_file()" in tests
assert "test_Chrome_bg_10.15.2026_09-25-24.cranect" in tests
assert 'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"' in prefs
assert 'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"' in prefs
assert "keychain restore unavailable" in helper
print("G-11 original disposable-archive audit and local-only sample contract: PASS")
