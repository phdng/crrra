"""G-11 D1 safety guard: transaction model is IN-MEMORY and never restores.

Fault injection tests cover all model promotion/rollback stages; this is
NOT actual filesystem/Keychain rollback nor permission to enable restore.
"""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[2]
tools = root / "reconstruction/tools"
source = (tools / "crane_restore_transaction_model.py").read_text(encoding="utf-8")
tests = (tools / "test_crane_restore_transaction_model.py").read_text(encoding="utf-8")
workflow = (root / ".github/workflows/build.yml").read_text(encoding="utf-8")
docs = (root / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf-8")
prefs = (root / "reconstruction/sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
helper = (root / "reconstruction/sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")

tree = ast.parse(source)
imports = set()
calls = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import):
        imports.update(part.name.split(".")[0] for part in node.names)
    if isinstance(node, ast.ImportFrom):
        imports.add((node.module or "").split(".")[0])
    if isinstance(node, ast.Call):
        if isinstance(node.func, ast.Attribute):
            calls.add(node.func.attr)
        if isinstance(node.func, ast.Name):
            calls.add(node.func.id)
assert not imports.intersection({"shutil", "subprocess", "ctypes", "socket", "os",
                                "zipfile", "pathlib", "requests"})
assert not calls.intersection({
    "extract", "extractall", "ZipFile", "open", "write", "writestr",
    "remove", "unlink", "replace", "rename", "rmtree", "copyfile", "move",
    "mkdir", "link", "chmod", "chown", "wipe",
})
assert "from crane_restore_preflight import preflight, PreflightError" in source
assert "preflight(args.archive, args.inventory)" in source
assert "inject_failure not in FAILPOINTS" in source
assert "state = {i: (\"old\", i)" in source
assert "snapshot = dict(state)" in source
assert "staged = {i: (\"new\", i)" in source
assert "state = dict(snapshot) if snapshot else dict(baseline)" in source
assert '"device_data_touched": False' in source
assert '"restore_executable": False' in source
assert '"real_rollback_implemented": False' in source
assert '"filesystem_writes": False' in source
assert '"zip_extracted": False' in source
assert '"keychain_contents_read": False' in source
assert "simulation_rolled_back_virtual_only" in source
assert "simulation_committed_virtual_only" in source
assert "simulation_not_run_blocked" in source
assert "snapshot" in source and "after_first_promotion" in source
assert "test_crane_restore_transaction_model.py" in workflow
assert "check_restore_transaction_model_contract.py" in workflow
assert "crane_restore_transaction_model.py" in docs
for test in (
    "test_faults_single_each_revert_snapshot",
    "test_faults_multi_revert_all_virtual_targets",
    "test_multi_partial_promotion_always_rolled_back",
    "test_blocked_preflight_never_even_simulates",
    "test_malformed_or_forged_preflight_denied",
    "test_cli_blocked_and_invalid_are_redacted",
    "test_success_multi_simulates_single_commit_boundary",
):
    assert test in tests, test
native = (root / "Library/PreferenceBundles/CranePrefs.bundle/"
          "CranePrefs_export_for_ai/decompile")
for addr, required in {
    "2B9B0": ("handleFreeSpaceCheck", "retrievePasswordIfNeeded",
              "loadBackupInfo", "determineBackupsToRestore",
              "handleAppIdentifierCheck", "extractBackup"),
    "2ADA0": ("wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:",),
    "2B228": ("moveOrCopyContainerFromPath:toPath:move:",),
}.items():
    f = native / (addr + ".c")
    if f.is_file():
        body = f.read_text(encoding="utf-8")
        for key in required:
            assert key in body, (addr, key)
for guard in (
    'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"',
    'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"',
):
    assert guard in prefs
assert "keychain restore unavailable" in helper
print("G-11 virtual-only restore transaction model + fault injection: PASS")
