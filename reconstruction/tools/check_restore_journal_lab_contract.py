"""G-11 D2 source contract: fixed-token temp-only journal, never live restore."""
from pathlib import Path
import ast

root = Path(__file__).resolve().parents[2]
tools = root / "reconstruction/tools"
lab = (tools / "crane_restore_journal_lab.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_restore_journal_lab.py").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/build.yml").read_text(encoding="utf-8")
audit = (root / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(
    encoding="utf-8")
prefs = (root / "reconstruction/sources/prefs/CRPreferences.m").read_text(
    encoding="utf-8")
helper = (root / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(
    encoding="utf-8")

tree = ast.parse(lab)
imports = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(item.name.split(".")[0] for item in node.names)
    if isinstance(node, ast.ImportFrom):
        imports.add((node.module or "").split(".")[0])
assert not imports.intersection({"shutil", "subprocess", "ctypes", "socket",
                                 "requests"})
assert "tempfile.gettempdir()" in lab
assert "temp_root in root.parents" in lab
assert 'LAB_MARKER = ".crane-transaction-lab"' in lab
assert "MARKER_CONTENT" in lab and "LAB_MARKER_CONTENT" in lab
assert "not path.is_symlink()" in lab
assert "st.st_nlink == 1" in lab
assert "O_NOFOLLOW" in lab
assert "MAX_SLOTS = 2" in lab
assert 'return f"slot-{i}.txt"' in lab
assert "CRANE_LAB_OLD_SLOT_" in lab and "CRANE_LAB_NEW_SLOT_" in lab
assert 'STATE = "state.json"' in lab
assert '"phase": phase' in lab
assert "os.O_EXCL" in lab
assert "os.fsync" in lab
assert "os.replace" in lab
assert '_create_file(journal / f"backup-{i}.txt", _old(i))' in lab
assert '_create_file(journal / f"staged-{i}.txt", _new(i))' in lab
assert '_update_state(journal, "prepared", mapping_count)' in lab
assert '_update_state(journal, "committed", mapping_count)' in lab
assert "if phase == \"prepared\":" in lab
assert '"committed"' in lab
assert "def recover_fixture(" in lab
assert "def _cleanup(" in lab
assert "preflight(args.archive, args.inventory)" in lab
assert 'checked["status"] == "preflight_advisory_only"' in lab
assert 'checked["restore_executable"] is False' in lab
assert 'output = recover_fixture(args.fixture_root)' in lab
assert 'output = run_fixture(args.fixture_root' in lab
assert 'except (LabError, PreflightError, InvalidArchive, UnsupportedArchive,' in lab
assert "real_rollback_implemented" in lab and "real_restore_supported" in lab
assert "import crane_backup_fixture_writer" not in lab
assert "write_fixture(" not in lab and "extractall(" not in lab
assert "fixture_interrupted_requires_recovery" in lab
assert "fixture_commit_preserved" in lab
assert "fixture_rolled_back" in lab
assert "fixture_lab_invalid_or_unsafe" in lab

for test_name in (
    "test_faults_before_commit_recover_both_slots",
    "test_crash_during_recovery_restarts_idempotently",
    "test_crash_after_commit_record_preserves_new_data",
    "test_missing_backup_refuses_rollback_if_target_new",
    "test_mutated_backup_refuses_recovery_without_touching_targets",
    "test_unfinished_state_update_is_fail_closed",
    "test_uncommitted_orphaned_backup_blocks_new_start",
    "test_unmarked_root_and_lab_marker_refused",
    "test_symlink_slot_is_rejected",
    "test_cli_interrupted_then_explicit_recovery",
    "test_cli_invalid_archive_does_not_echo_private_paths",
):
    assert test_name in tests, test_name
assert "check_restore_journal_lab_contract.py" in workflow
assert "test_crane_restore_journal_lab.py" in workflow
assert "crane_restore_journal_lab.py" in audit

for guard in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert guard in prefs
assert "keychain restore unavailable" in helper
original = root / "Library/PreferenceBundles/CranePrefs.bundle/CranePrefs_export_for_ai/decompile"
for addr, token in (
    ("2ADA0", "wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:"),
    ("2B228", "moveOrCopyContainerFromPath:toPath:move:"),
):
    path = original / (addr + ".c")
    if path.is_file():
        assert token in path.read_text(encoding="utf-8")
print("G-11 temp-only synthetic filesystem journal contract: PASS")
