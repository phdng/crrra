"""G-11 Stage C: compare original ZIP shape without revealing source identities.

Source-level guard: both archive handles read-only, no payload printing,
Keychain reads or live restore/wipe, no claim of byte-accurate equivalence.
"""
import ast
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
tools = repo / "reconstruction/tools"
source = (tools / "crane_backup_shape_compare.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_backup_shape_compare.py").read_text(encoding="utf-8")
inspector = (tools / "crane_backup_inspector.py").read_text(encoding="utf-8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
prefs = (repo / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")
tree = ast.parse(source)
calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
unsafe = {"extract", "extractall", "writestr", "write", "unlink", "remove",
          "replace", "rename", "mkdir", "link"}
called = {node.func.attr for node in calls if isinstance(node.func, ast.Attribute)}
assert not unsafe.intersection(called), unsafe.intersection(called)
assert "ZipFile(path, \"r\")" in source
assert "inspect_archive(path, verify_payload=verify_payload)" in source
assert 'with archive.open(info, "r") as stream' in source
assert "MAX_PLIST_BYTES" in source
assert "Keychain.plist" in source
assert "archive.read(" not in source
assert "zf.read(" not in source
assert "KNOWN_INFO_KEYS" in source and "KNOWN_METADATA_KEYS" in source
assert "_keys_signature(" in source
assert "original_compatibility_proven" in source
assert "restore_safe" in source
assert "keychain_contents_read" in source and "extracted" in source
assert "structural_shape_match_not_proven" in source
assert "structural_differences_found" in source
assert "unavailable_or_invalid" in source
assert 'except (ComparisonUnavailable, InvalidArchive, OSError, ValueError,' in source
assert "Never echo raw exception text" in source
assert "reference and candidate are the same file" in source
assert '"--reference"' in source and '"--candidate"' in source
assert "container_count" in source and "associated_path_count" in source
assert "sort(key=lambda row: json.dumps(row, sort_keys=True))" in source
assert "test_crane_backup_shape_compare.py" in workflow
assert "check_backup_shape_compare_contract.py" in workflow
assert "crane_backup_shape_compare.py" in audit
assert 'reply(nil);' in (repo / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf-8")
for token in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert token in prefs
for test in (
    "test_identical_shape_even_when_different_zip_files",
    "test_multi_container_order_independent",
    "test_detects_keychain_presence_without_reading_contents",
    "test_different_compression_method_detected",
    "test_xml_plist_difference_detected",
    "test_mismatch_metadata_keys_is_structural_only",
    "test_cli_redacts_invalid_archive_entry_names",
    "test_input_sources_not_changed",
):
    assert test in tests
print("G-11 redacted original-vs-fixture archive shape contract: PASS (original fixture pending)")
