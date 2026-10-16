"""G-11 N8: explicit, test-bundle-only read-only root diagnostic contract."""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
prefs_dir = repo / "reconstruction/sources/prefs"
header = (prefs_dir / "CRBackupDisposableDiagnostic.h").read_text(encoding="utf8")
source = (prefs_dir / "CRBackupDisposableDiagnostic.m").read_text(encoding="utf8")
ui = (prefs_dir / "CRPreferences.m").read_text(encoding="utf8")
make = (prefs_dir / "Makefile").read_text(encoding="utf8")
mock = (repo / "reconstruction/tools/native_backup_manager_bridge_smoke.m").read_text(encoding="utf8")
ci = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")

assert "CRBackupDisposableDiagnostic.m" in make
assert "isEligibleApplicationIdentifier:" in header
assert "userConfirmedOnce:(BOOL)confirmed" in header
assert 'CR8FixtureApplicationID = @"com.example.crane.native"' in source
assert "[[NSUUID alloc] initWithUUIDString:containerID]" in source
assert "if (!confirmed ||" in source
assert "isEligibleApplicationIdentifier:applicationID" in source
assert "probeTypedRegisteredApplication:applicationID" in source
assert "containerIdentifier:containerID error:NULL" in source
assert '@"backupReady":@NO' in source
assert '@"restoreExecutable":@NO' in source
assert '@"sourceFilesEnumerated":@NO' in source
assert '@"sourceContentsRead":@NO' in source
assert '@"keychainContentsRead":@NO' in source
for forbidden in (
    "NSLog(", "readdir(", "open(", "fstatat(", "write(", "SecItem",
    "KeychainItems", "removeItemAtPath:", "setActiveContainer",
    "createNewContainer", "moveItemAtPath:", "pathsAssociatedToContainerWithIdentifier:",
    "setPreferenceValue:", "createMultiBackupTapped", "restoreMultiBackupTapped",
):
    assert forbidden not in source, forbidden

assert '#import "CRBackupDisposableDiagnostic.h"' in ui
assert "runDisposableSourceDiagnostic" in ui
assert "setButtonAction:@selector(runDisposableSourceDiagnostic)" in ui
assert "UIAlertActionStyleCancel handler:nil" in ui
assert "userConfirmedOnce:YES error:&error" in ui
assert "[strongSelf.applicationIdentifier isEqualToString:appID]" in ui
assert "[strongSelf.containerIdentifier isEqualToString:containerID]" in ui
assert 'isEligibleApplicationIdentifier:self.applicationIdentifier' in ui
assert 'presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"' in ui
assert 'presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"' in ui
assert "userConfirmedOnce:NO error:&diagnosticError" in mock
assert "com.example.other" in mock
assert "gReadCalls == gatedCalls" in mock
assert "diagnostic.count == 10" in mock
assert "CRBackupDisposableDiagnostic.m" in ci
assert "check_disposable_source_diagnostic_contract.py" in ci
assert "test_crane_disposable_source_diagnostic.py" in ci
print("G-11 N8 disposable app opt-in source diagnostic contract: PASS")
