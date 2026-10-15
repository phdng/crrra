"""Contract: G-11 offline restore preflight has no mutating native behavior."""
import ast
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
tools = repo / "reconstruction/tools"
source = (tools / "crane_restore_preflight.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_restore_preflight.py").read_text(encoding="utf-8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")
prefs = (repo / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
helper = (repo / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf-8")

tree = ast.parse(source)
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        assert not any(part.name.split(".")[0] in
                       {"subprocess", "shutil", "ctypes", "socket"}
                       for part in node.names)
calls = [node for node in ast.walk(tree) if isinstance(node, ast.Call)]
called = {node.func.attr for node in calls
          if isinstance(node.func, ast.Attribute)}
assert not called.intersection({
    "extract", "extractall", "write", "writestr", "unlink", "remove",
    "rmtree", "replace", "rename", "mkdir", "link", "chmod", "chown",
}), called
assert "ZipFile(archive, \"r\")" in source
assert "inspect_archive(archive, verify_payload=False)" in source
assert "_read_small_plist" in source
assert "Keychain.plist" not in source  # explicitly uses index flags only
assert '"restore_executable": False' in source
assert '"rollback_implemented": False' in source
assert '"wrote_files": False' in source
assert '"keychain_contents_read": False' in source
assert '"original_compatibility_proven": False' in source
assert "preflight_advisory_only" in source
assert "preflight_blocked" in source
assert "preflight_unavailable_or_invalid" in source
for mandatory in (
    "application_identifier_mismatch",
    "associated_identifier_confirmation_required",
    "target_associated_identifier_unavailable",
    "overwrite_requires_snapshot_and_rollback",
    "target_active_reload_unverified",
    "keychain_restore_backend_unavailable",
    "free_space_unknown", "insufficient_estimated_free_space",
    "duplicate target", "reused source or target mapping",
):
    assert mandatory in source, mandatory
for name in (
    "test_wrong_app_id_is_blocked",
    "test_missing_group_in_default_requires_confirmation",
    "test_multi_explicit_subset_mapping_is_supported",
    "test_multi_mapping_same_target_refused",
    "test_keychain_flag_blocks_without_reading_contents",
    "test_no_capacity_and_insufficient_estimate",
    "test_no_actual_device_path_is_read_from_inventory",
    "test_cli_statuses_and_private_identifiers_are_hidden",
):
    assert name in tests, name

original = repo / "Library/PreferenceBundles/CranePrefs.bundle/CranePrefs_export_for_ai/decompile"
checks = {
    "29A84": ("containersInBackup", "pauseRestoreWithEvent:withParameters:"),
    "29CAC": ("APP_ID_MISMATCH_ERROR", "isEqualToString:"),
    "2A298": ("originalPaths", "applicationGroups", "DEFAULT"),
    "2A7CC": ("objectForKeyedSubscript:",),
    "2ADA0": ("wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:",),
}
for address, strings in checks.items():
    path = original / (address + ".c")
    if path.is_file():
        body = path.read_text(encoding="utf8")
        for token in strings:
            assert token in body, (address, token)

assert "test_crane_restore_preflight.py" in workflow
assert "check_restore_preflight_contract.py" in workflow
assert "crane_restore_preflight.py" in audit
for guard in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert guard in prefs
assert "keychain restore unavailable" in helper
print("Crane G-11 read-only restore preflight original-source safety: PASS")
