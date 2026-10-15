"""G-11 D5 contract: verifier is read-only and never authorizes Restore."""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[2]
tools = root / "reconstruction/tools"
source = (tools / "crane_restore_quarantine_verify.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_restore_quarantine_verify.py").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/build.yml").read_text(encoding="utf-8")
audit = (root / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")
prefs = (root / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
helper = (root / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf-8")

tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        assert not any(
            part.name.split(".")[0] in
            {"shutil", "subprocess", "socket", "ctypes", "requests"}
            for part in node.names)
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
        assert node.func.attr not in {
            "extract", "extractall", "write", "writestr", "unlink",
            "rename", "replace", "mkdir", "rmdir", "rmtree", "copy",
            "chmod", "chown", "symlink_to", "hardlink_to",
        }, node.func.attr

assert "from crane_restore_fixture_materializer import (" in source
assert "root, staging, published = _fixture_layout(fixture_root)" in source
assert "_source_path(root, archive, root / \"output\")" in source
assert "_source_path(root, inventory, root, \"inventory.json\")" in source
assert "plan_restore(path, manifest, verify_payload=True)" in source
assert 'checked["status"] == "work_plan_advisory_only"' in source
assert 'checked["restore_executable"] is False' in source
assert 'checked["non_keychain_crc_verified"] is True' in source
assert "MAX_FILES" in source and "MAX_TOTAL_BYTES" in source
assert "MAX_CONTAINERS" in source
assert "zipfile.ZipFile(path, \"r\")" in source
assert 'if remainder in ("Info.plist", "Metadata.plist", "Keychain.plist"):' in source
assert "stream.read(CHUNK)" in source
assert "hashlib.sha256()" in source
assert "O_NOFOLLOW" in source
assert "os.walk(batch, topdown=True, followlinks=False)" in source
assert "st_nlink != 1" in source
assert "missing_files" in source and "unexpected_files" in source
assert "missing_directories" in source and "unexpected_directories" in source
assert "unsafe_directory_entry" in source and "unsafe_file_entry" in source
assert "file_content_or_length_mismatch" in source
assert "_file_identity(path) != initial_archive" in source
assert "_file_identity(manifest) != initial_inventory" in source
assert "fixture_verified_read_only" in source
assert "fixture_integrity_mismatch" in source
assert "fixture_verify_invalid_or_unavailable" in source
for guard in (
    '"device_data_touched": False',
    '"keychain_contents_read": False',
    '"filesystem_writes": False',
    '"original_compatibility_proven": False',
    '"real_rollback_implemented": False',
    '"restore_executable": False',
):
    assert guard in source, guard

for test in (
    "test_single_published_matches_zip_sha256",
    "test_multi_all_containers_verified",
    "test_multi_subset_is_verified_without_unmapped_paths",
    "test_tampered_equal_size_file_is_detected",
    "test_truncated_file_detected",
    "test_removed_payload_file_is_detected",
    "test_extra_file_is_detected_but_not_opened",
    "test_extra_directory_is_detected",
    "test_missing_empty_directory_is_detected",
    "test_symlink_file_not_followed",
    "test_symlink_directory_not_traversed",
    "test_hardlinked_output_is_detected",
    "test_source_replacement_during_hash_is_refused",
    "test_read_only_guard_against_mutators",
    "test_cli_success_mismatch_and_redaction",
):
    assert test in tests, test

assert "check_restore_quarantine_verify_contract.py" in workflow
assert "test_crane_restore_quarantine_verify.py" in workflow
assert "crane_restore_quarantine_verify.py" in audit
for disabled in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert disabled in prefs
assert "keychain restore unavailable" in helper
print("G-11 D5 read-only quarantine integrity verification contract: PASS")
