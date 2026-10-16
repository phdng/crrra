"""G-11 N6 real CraneManager runtime adapter remains explicit and read-only."""
from pathlib import Path

repo = Path(__file__).resolve().parents[2]
pref = repo / "reconstruction/sources/prefs"
h = (pref / "CRBackupNativeManagerPreflight.h").read_text(encoding="utf8")
m = (pref / "CRBackupNativeManagerPreflight.m").read_text(encoding="utf8")
source = (pref / "CRBackupNativeSourcePreflight.m").read_text(encoding="utf8")
smoke = (repo / "reconstruction/tools/native_backup_manager_bridge_smoke.m").read_text(encoding="utf8")
tests = (repo / "reconstruction/tools/test_crane_native_manager_bridge.py").read_text(encoding="utf8")
mgr = (repo / "reconstruction/sources/common/CRManager.h").read_text(encoding="utf8")
make = (pref / "Makefile").read_text(encoding="utf8")
ci = (repo / ".github/workflows/build.yml").read_text(encoding="utf8")
audit = (repo / "reconstruction/BACKUP_RESTORE_SOURCE_AUDIT.md").read_text(encoding="utf8")
prefs = (pref / "CRPreferences.m").read_text(encoding="utf8")

assert "probeRegisteredApplication:" in h
assert "CRBackupNativeManagerPreflight.m" in make
assert "CranePrefs_LIBRARIES  = crane z iconv" in make

for required in (
    '#import "CRManager.h"', "NSClassFromString(@\"CraneManager\")",
    "SEL sharedSEL = @selector(sharedManager)",
    "objc_msgSend)(managerClass, sharedSEL)",
    "respondsToSelector:@selector(isApplicationSupportedByCrane:)",
    "respondsToSelector:@selector(containerIdentifiersOfApplicationWithIdentifier:)",
    "pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:",
    "CRBackupNativeSourcePreflight",
    "resolver:(id<CRBackupSourceResolver>)manager",
    '[report[@"backupReady"] isEqual:@NO]',
    '[report[@"restoreExecutable"] isEqual:@NO]',
    '[report[@"sourceFilesEnumerated"] isEqual:@NO]',
    '[report[@"sourceContentsRead"] isEqual:@NO]',
    '[report[@"keychainContentsRead"] isEqual:@NO]',
    'CR6Fail(error, 4)',
):
    assert required in m, required
for selector in (
    "isApplicationSupportedByCrane:",
    "containerIdentifiersOfApplicationWithIdentifier:",
    "pathsAssociatedToContainerWithIdentifier:",
    "ofApplicationWithIdentifier:",
):
    assert selector in mgr, selector
for prohibited in (
    "setActiveContainer", "createNewContainer", "deleteContentOfContainer",
    "wipeContainer", "makeDefaultForContainer", "reloadApplicationWithIdentifier:",
    "SecItem", "KeychainItems", "removeItemAtPath", "writeToFile:",
    "readdir(", "opainject", "NSLog(", "CFPreferencesSet",
):
    assert prohibited not in m, prohibited
assert "SSurvey(fd, NO)" in (pref / "CRBackupArchiveSurvey.m").read_text(encoding="utf8")
assert "registered_source_roots_accessible_not_backup_ready" in source
assert "CR6MockShared" in smoke
assert 'objc_allocateClassPair([NSObject class], "CraneManager", 0)' in smoke
assert "gReadCalls == 3" in smoke
assert "test_no_mutating_selector_in_adapter" in tests
assert "check_native_manager_bridge_contract.py" in ci
assert "test_crane_native_manager_bridge.py" in ci
assert "native_backup_manager_bridge_smoke.m" in ci
assert "CRBackupNativeManagerPreflight.m" in ci
assert "CRBackupNativeManagerPreflight.m" in audit
assert "probeRegisteredApplication:" not in prefs
for action in (
    '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"]',
    '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"]',
):
    assert action in prefs
print("G-11 N6 real singleton-to-N5 read-only resolver adapter contract: PASS")
