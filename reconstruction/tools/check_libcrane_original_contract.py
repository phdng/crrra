"""Direct libcrane parity contracts recovered from original Mach-O metadata/disassembly.

The original libcrane has no IDA export directory, but its Objective-C metadata
lives in __DATA_CONST,__objc_classlist. The tracked analysis/objc_classes.json
fixture provides CI-stable evidence; the workstation-only tools/objc_classes.py
parser is checked only when available. The reconstructed source must preserve
high-value contracts: appSettings_<bundleID> storage, DEFAULT projection,
associated paths, lifecycle, keychainVersion=2, daemon reload groups,
notification XPC bridge, and cfprefsd flush after reload-if-active.
"""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[1]
workspace = root.parent
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRManager.h").read_text(encoding="utf-8")
registry = (root / "sources/common/CRContainerRegistry.h").read_text(encoding="utf-8")
parser_path = workspace / "tools/objc_classes.py"
# The parser belongs to local reverse-engineering tooling and is ignored by
# Git. GitHub Actions checks out the committed evidence fixture instead.
# If the original parser is available locally, also validate its classlist.
if parser_path.is_file():
    parser = parser_path.read_text(encoding="utf-8")
    assert '"__DATA_CONST,__objc_classlist"' in parser

fixture_path = workspace / "analysis/objc_classes.json"
assert fixture_path.is_file(), f"Tracked ObjC evidence fixture missing: {fixture_path}"
classes = json.loads(fixture_path.read_text(encoding="utf-8"))
lib = classes.get("libcrane.dylib", {})
assert list(lib) == ["CraneManager"], lib.keys()
methods = lib["CraneManager"]["instance_methods"]
assert len(methods) == 99, len(methods)
by_sel = {m["sel"]: m for m in methods}
expected_imps = {
    "applicationSettingsForApplicationWithIdentifier:": "0x937C",
    "setApplicationSettings:forApplicationWithIdentifier:": "0x955C",
    "_handleDaemonReloadingForContainerIdentifier:ofApplicationWithIdentifier:": "0xA9B8",
    "_removeAccountsDatabaseIfExistsForIdentifier:": "0xAB00",
    "_deleteUserLibraryPreferencesForContainerWithIdentifier:applicationIdentifier:": "0xBF98",
    "makeDefaultForContainerWithIdentifier:forApplicationWithIdentifier:": "0xCBA0",
    "enumerate:pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:": "0xE09C",
    "pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:": "0xE574",
    "isKeychainVersionUpToDate": "0xF470",
    "updateKeychainVersion": "0xF4D8",
    "flushCFPrefsdCacheForApplicationWithIdentifier:": "0xF538",
    "_initUserNotificationsServerConnection": "0xF8C8",
    "_userNotificationsSyncRemoteProxy": "0xFA68",
    "unregisterFromNotificationsIfNeededForContainerIdentifier:ofApplicationWithIdentifier:": "0xFB0C",
    "switchBadgesOfContainerWithIdentifier:andContainerWithIdentifier:ofApplicationWithIdentifier:": "0xFBB0",
    "resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:": "0xFC80",
    "reloadAccountsdDaemon": "0xFD24",
    "reloadAppstoreDaemons": "0xFE3C",
    "reloadMusicDaemons": "0xFF70",
    "reloadGameDaemons": "0x10088",
    "reloadApplicationWithIdentifier:": "0x101A0",
    "reloadApplicationWithIdentifier:ifContainerIsActive:": "0x10288",
}
for selector, imp in expected_imps.items():
    assert selector in by_sel, selector
    assert by_sel[selector]["imp"].upper() == imp.upper(), (
        selector, by_sel[selector]["imp"], imp
    )

# Native per-app schema; legacy aggregate domain may appear only as a
# compatibility-read/migration source.
assert 'return appID.length ? [@"appSettings_" stringByAppendingString:appID]' in manager
assert "[self preferenceValueForKey:key]" in manager
assert "[self setPreferenceValue:settings" in manager
assert "CRApplicationSettingsPreferenceKey(appID)" in manager
assert "migrated legacy app settings" in manager
assert 'CFSTR("com.opa334.cranereconstruction.apps")' in manager
assert 'CFPreferencesSetAppValue(CFSTR("applications")' not in manager

# Native no-settings projection.
for token in (
    'CRCContainer_Name: @""',
    "CRCContainer_Identifier: CR_DEFAULT_CONTAINER_IDENTIFIER",
    "CRCContainer_ActiveContainer: CR_DEFAULT_CONTAINER_IDENTIFIER",
):
    assert token in registry, token

# Native app/group/plugin associated paths.
for token in (
    "- (void)enumerate:(void (^)(NSInteger type, NSString *identifier,",
    'NSSelectorFromString(@"groupContainerURLs")',
    'NSSelectorFromString(@"plugInKitPlugins")',
    "block(0, appID, path, &stop);",
    "block(1, identifier, path, &stop);",
    "block(2, identifier, path, &stop);",
    "paths[identifier] = path;",
):
    assert token in manager, token
assert "NSDictionary<NSString *, NSString *> *)pathsAssociated" in header

# Native delete-content lifecycle. CranePrefs removes the registry entry after
# this call, so the manager method must only clean data and related side effects.
delete_start = manager.index(
    "- (void)deleteContentOfContainerWithIdentifier:(NSString *)containerID"
)
delete_end = manager.index(
    "- (void)wipeContainerWithIdentifier:(NSString *)containerID", delete_start
)
delete_body = manager[delete_start:delete_end]
delete_steps = (
    "[self reloadApplicationWithIdentifier:appID ifContainerIsActive:containerID]",
    "[self pathsAssociatedToContainerWithIdentifier:containerID",
    "deleteKeychainItemsForContainerWithIdentifier:containerID",
    "[self _removeAccountsDatabaseIfExistsForIdentifier:containerID]",
    "[self unregisterFromNotificationsIfNeededForContainerIdentifier:containerID",
    "[self resetBadgeOfContainerWithIdentifier:containerID",
    "[self _deleteUserLibraryPreferencesForContainerWithIdentifier:containerID",
    "[self _handleDaemonReloadingForContainerIdentifier:containerID",
)
positions = [delete_body.index(step) for step in delete_steps]
assert positions == sorted(positions), positions
assert "setApplicationSettings:" not in delete_body
assert "CR_DEFAULT_CONTAINER_IDENTIFIER" in delete_body

daemon_start = manager.rindex(
    "- (void)_handleDaemonReloadingForContainerIdentifier:", 0, delete_start
)
accounts_start = manager.rindex(
    "- (void)_removeAccountsDatabaseIfExistsForIdentifier:", 0, delete_start
)
prefs_delete_start = manager.rindex(
    "- (void)_deleteUserLibraryPreferencesForContainerWithIdentifier:", 0, delete_start
)
daemon_helper = manager[daemon_start:accounts_start]
assert '@"com.apple.AppStore"' in daemon_helper
assert "CRAppSetting_SeparateSystemAccountsEnabled" in daemon_helper
assert "[containerID isEqualToString:active]" in daemon_helper
assert "[self reloadAppstoreDaemons]" in daemon_helper

accounts_helper = manager[accounts_start:prefs_delete_start]
for token in (
    '@"sqlite"',
    '@"sqlite-shm"',
    '@"sqlite-wal"',
    '@"/var/mobile/Library/Accounts/Crane/%@.%@"',
):
    assert token in accounts_helper, token

prefs_delete = manager[prefs_delete_start:delete_start]
for token in (
    '@"/var/mobile/Library/Preferences"',
    '@"%@.plist"',
    '@"%@.c_r_a_n_e.%@.plist"',
    "removeItemAtURL:url",
):
    assert token in prefs_delete, token

# Native keychain schema/version: exact equality to 2, no notification here.
keychain = manager[
    manager.index("- (BOOL)isKeychainVersionUpToDate"):
    manager.index("/* ---- UserNotifications bridge")
]
assert '@"keychainVersion"' in keychain
assert "integerValue] == 2" in keychain
assert '[self setPreferenceValue:@2 forKey:@"keychainVersion"]' in keychain
assert "MigrationSucceeded" not in keychain
assert "crane_keychainVersion" not in keychain

# Native fixed daemon reload groups.
for literal in (
    '@[@"accountsd"]',
    '@[@"appstored", @"itunesstored"',
    '@[@"itunescloudd"]',
    '@[@"gamed"]',
):
    assert literal in manager, literal

# Native UserNotifications service split and protocol additions.
for token in (
    '"UNUserNotificationServerProtocolPlusCraneAdditions"',
    'NSClassFromString(@"UNSUserNotificationServer")',
    '@"com.apple.usernotifications.usernotificationservice"',
    '@"_userNotificationServerConnectionListener"',
    "synchronousRemoteObjectProxyWithErrorHandler:",
    "crane_unregisterFromNotificationsIfNeededForContainerIdentifier:",
    "crane_switchBadgesOfContainerWithIdentifier:",
    "crane_resetBadgeOfContainerWithIdentifier:",
):
    assert token in manager, token

# Native reload-if-active always follows with cfprefsd flush.
reload_start = manager.index(
    "- (void)reloadApplicationWithIdentifier:(NSString *)appID\n"
    "                    ifContainerIsActive:(NSString *)containerID"
)
reload_end = manager.index(
    "- (void)flushCFPrefsdCacheForApplicationWithIdentifier:", reload_start
)
reload_body = manager[reload_start:reload_end]
assert "[active isEqualToString:containerID]" in reload_body
assert "[self reloadApplicationWithIdentifier:appID]" in reload_body
assert "[self flushCFPrefsdCacheForApplicationWithIdentifier:appID]" in reload_body
assert reload_body.index("[self reloadApplicationWithIdentifier:appID]") < (
    reload_body.index("[self flushCFPrefsdCacheForApplicationWithIdentifier:appID]")
)

flush_end = manager.index(
    "- (void)fetchActiveContainerIDForProcessWithPid:", reload_end
)
flush = manager[reload_end:flush_end]
for token in (
    'NSClassFromString(@"_CFXPreferences")',
    'NSSelectorFromString(@"copyDefaultPreferences")',
    'NSSelectorFromString(@"flushCachesForAppIdentifier:user:")',
    "kCFPreferencesCurrentUser",
    "pathsAssociatedToContainerWithIdentifier:active",
    '@"Library/Preferences"',
    '[entry pathExtension] isEqualToString:@"plist"',
):
    assert token in flush, token

print("Crane original libcrane direct-parity contracts: PASS (device unverified)")
