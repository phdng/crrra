"""G-11 D3 contract: no executable ZIP restore plan or private path output."""
import ast
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
tools = repo / "reconstruction/tools"
source = (tools / "crane_restore_work_plan.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_restore_work_plan.py").read_text(encoding="utf-8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")
prefs = (repo / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
helper = (repo / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf-8")

tree = ast.parse(source)
calls = {node.func.attr for node in ast.walk(tree)
         if isinstance(node, ast.Call) and
         isinstance(node.func, ast.Attribute)}
for operation in ("extract", "extractall", "write", "writestr",
                  "unlink", "remove", "rename", "replace", "rmtree",
                  "mkdir", "chmod", "chown", "move", "copy"):
    assert operation not in calls, operation
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        assert all(part.name.split(".")[0] not in
                   ("shutil", "subprocess", "socket", "ctypes", "requests")
                   for part in node.names)
assert 'zipfile.ZipFile(path, mode="r")' in source
assert "inspect_archive(path, verify_payload=verify_payload)" in source
assert "checked = preflight(path, inventory_path)" in source
assert "selected, _capacity = _inventory(inventory_path)" in source
assert "archive_identity = _file_identity(path)" in source
assert "_file_identity(path) != archive_identity" in source
assert "_original_identifiers(info, source_id[0])" in source
assert "_read_small_plist(zf, per_source[metadata_name])" in source
assert "WRITABLE_FILE_ATTRIBUTES" in source
assert "metadata_paths_without_zip_entries" in source
assert "metadata_unknown_attributes" in source
assert "metadata_invalid_attributes" in source
assert "metadata_privileged_or_world_writable" in source
assert "associated_data_absent_from_archive" in source
assert "keychain_restore_backend_unavailable" in source
assert 'relative not in (' in source
assert "original_compatibility_proven" in source
assert '"restore_executable": False' in source
assert '"device_target_paths_verified": False' in source
assert '"wrote_files": False' in source
assert '"extracted": False' in source
assert '"keychain_contents_read": False' in source
assert '"rollback_implemented": False' in source
assert '"work_plan_invalid_or_unavailable"' in source
assert "except (PlanError, PreflightError, InvalidArchive, UnsupportedArchive," in source
assert "test_crane_restore_work_plan.py" in workflow
assert "check_restore_work_plan_contract.py" in workflow
assert "crane_restore_work_plan.py" in audit
for testcase in (
    "test_multi_subset_only_selected_entries_counted",
    "test_metadata_orphan_requires_review",
    "test_unknown_attribute_redacted",
    "test_bad_metadata_types_review",
    "test_preflight_target_active_and_existing_data",
    "test_no_group_root_entry_detected",
    "test_keychain_presence_never_read",
    "test_optional_crc_fails_closed_for_corrupted_file",
    "test_no_zip_extract_or_app_payload_reads",
    "test_cli_success_blocked_and_identity_redaction",
):
    assert testcase in tests, testcase
for guard in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert guard in prefs
assert "keychain restore unavailable" in helper

decompile = repo / (
    "Library/PreferenceBundles/CranePrefs.bundle/"
    "CranePrefs_export_for_ai/decompile")
for imp, evidence in {
    "2A298": ("originalPaths", "DEFAULT"),
    "2A848": ("Metadata.plist", "allWritableFileAttributes"),
    "2ADA0": ("wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:",),
}.items():
    path = decompile / (imp + ".c")
    if path.is_file():
        text = path.read_text(encoding="utf-8")
        for item in evidence:
            assert item in text, (imp, item)
print("G-11 D3 read-only redacted restore ZIP work-plan contract: PASS")
