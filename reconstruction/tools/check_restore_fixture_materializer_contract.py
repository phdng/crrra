"""G-11 D4 contract: quarantine fixture only, never on-device restore."""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[2]
tools = root / "reconstruction/tools"
code = (tools / "crane_restore_fixture_materializer.py").read_text(encoding="utf8")
tests = (tools / "test_crane_restore_fixture_materializer.py").read_text(encoding="utf8")
workflow = (root / ".github/workflows/build.yml").read_text(encoding="utf8")
audit = (root / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf8")
prefs = (root / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf8")
helper = (root / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf8")
tree = ast.parse(code)
imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(part.name.split(".")[0] for part in node.names)
    if isinstance(node, ast.ImportFrom):
        imports.add((node.module or "").split(".")[0])
assert not imports.intersection({"subprocess", "socket", "ctypes", "requests"})
assert "from crane_backup_fixture_writer import MARKER, MARKER_CONTENT" in code
assert "tempfile.gettempdir()" in code
assert "temporary in root.parents" in code
assert 'LAB_MARKER = ".crane-materialize-lab"' in code
assert "LAB_MARKER_VALUE" in code and "STAGE_VALUE" in code
assert "not path.is_symlink()" in code
assert "os.O_EXCL" in code and "O_NOFOLLOW" in code
assert "MAX_CONTAINERS = 2" in code
assert "MAX_FILES = 200" in code
assert "MAX_TOTAL_BYTES = 16 * 1024 * 1024" in code
assert 'name: str | None = None' in code and '"inventory.json"' in code
assert 'file.parent.resolve(strict=True) == expected_directory' in code
assert "plan_restore(archive_path, inventory_path, verify_payload=True)" in code
assert 'report["status"] == "work_plan_advisory_only"' in code
assert 'report["restore_executable"] is False' in code
assert "selected, _ = _inventory(inventory_path)" in code
assert "not destination.exists() and not destination.is_symlink()" in code
assert "with zf.open(member, \"r\") as stream:" in code
assert "files_written == report[\"selected_payload_files\"]" in code
assert "os.rename(stage, destination)" in code
assert "shutil.rmtree(stage)" in code
assert "_safe_stage_cleanup(stage, staging)" in code
assert 'stage == staging / "batch"' in code
assert "original_compatibility_proven" in code
assert '"real_rollback_implemented": False' in code
assert '"restore_executable": False' in code
assert '"device_data_touched": False' in code
assert "fixture_materialized_not_restore" in code
assert "fixture_stage_rolled_back" in code
assert "fixture_invalid_or_unsafe" in code
assert "write_fixture(" not in code
assert "extractall(" not in code
assert "extract(" not in code
assert "CraneManager" in code  # negative docstring only
assert "check_restore_fixture_materializer_contract.py" in workflow
assert "test_crane_restore_fixture_materializer.py" in workflow
assert "crane_restore_fixture_materializer.py" in audit
for name in (
    "test_single_archive_materializes_file_bytes_and_empty_paths",
    "test_multi_atomic_single_directory_publish",
    "test_injected_failure_rolls_back_staged_files",
    "test_existing_published_directory_refused_no_overwrite",
    "test_orphan_staging_refused_without_auto_cleanup",
    "test_outside_archive_refused",
    "test_inventory_outside_root_refused",
    "test_active_or_existing_target_blocks_all_writes",
    "test_keychain_archive_never_materialized",
    "test_zip_bad_traversal_refused",
    "test_disallowed_platform_filename_refused_after_preflight",
    "test_cli_fault_status_and_privacy",
    "test_no_preexisting_source_mutation",
):
    assert name in tests, name
for guard in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert guard in prefs
assert "keychain restore unavailable" in helper
print("G-11 D4 TEMP-only quarantine materialization source contract: PASS")
