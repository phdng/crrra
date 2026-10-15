"""G-07 staged non-destructive deletion: UNUSED Game Center profiles only.

Original CranePrefs 0x1502C deletes a live accountsd SQLite database and
is intentionally NOT reproduced until device/transaction evidence exists.
The reconstruction can only prune a disposable, unreferenced UUID profile
when all database and registry inspections succeed.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRGameCenterAccounts.h").read_text(encoding="utf-8")
smoke = (root / "tools/container_menu_smoke.m").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

begin = prefs.index("@implementation CRPGameCenterAccountsController")
end = prefs.index("/* Initial container detail controller reconstructed", begin)
ui = prefs[begin:end]
check_start = ui.index("- (BOOL)canRemoveUnusedAccountWithIdentifier:")
check_end = ui.index("- (BOOL)removeUnusedAccountWithIdentifier:", check_start)
checks = ui[check_start:check_end]
write_start = check_end
write_end = ui.index("/* Original 0x15F90 opens a rename alert", write_start)
write = ui[write_start:write_end]
alert = ui[write_end:]

for field in (
    "[[NSUUID alloc] initWithUUIDString:identifier]",
    "CR_DEFAULT_CONTAINER_IDENTIFIER",
    'preferenceValueForKey:@"gameCenterAccounts"',
    '@"crane_gameCenter.availableAccounts"',
    "CRGameCenterAccountsAreValidForWrite(stored)",
    "dictionaryForAccountWithIdentifier:identifier",
    "[manager gameCenter_activeAccount]",
    "CFPreferencesCopyKeyList(",
    "kCFPreferencesCurrentUser, kCFPreferencesAnyHost",
    '[key hasPrefix:@"appSettings_"]',
    "CRGameCenterAccountReferencedInSettings(",
    "if (!valid || referenced)",
    '@"/var/mobile/Library/Accounts/Crane"',
    "attributesOfItemAtPath:directory",
    "NSFileTypeDirectory",
    "isReadableFileAtPath:directory",
    "contentsOfDirectoryAtPath:directory",
    '[identifier stringByAppendingString:@"."]',
    "[name hasPrefix:prefix]",
):
    assert field in checks, field

assert write.index("[self canRemoveUnusedAccountWithIdentifier:identifier]") < write.index(
    "[accounts removeObjectAtIndex:index]")
assert write.index("[accounts removeObjectAtIndex:index]") < write.index(
    "[manager gameCenter_setAvailableAccounts:accounts]")
assert "CRGameCenterAccountIdentifierExists(" in write
assert "return NO;" in write
assert "[self reloadListInParentController]" in write
assert "[self scheduleAccountListReload]" in write

for token in (
    "[self canRemoveUnusedAccountWithIdentifier:identifier]",
    "UIAlertActionStyleDestructive",
    'CRLocalize(@"GAME_CENTER_ACCOUNT_DELETE_CONFIRMATION_TITLE")',
    'CRLocalize(@"GAME_CENTER_ACCOUNT_DELETE_CONFIRMATION_MESSAGE")',
    'CRLocalize(@"CANCEL")',
    "removeUnusedAccountWithIdentifier:identifier",
):
    assert token in alert, token

# No original filesystem-destructive method is invoked. This is metadata-only.
assert "[manager _removeAccountsDatabaseIfExistsForIdentifier:" not in ui
assert "removeItemAtPath:" not in ui
assert "performDeletionActionForSpecifier:" not in ui

assert 'id containers = appSettings[@"Containers"]' in header
assert 'item[@"associatedGameCenterAccount"]' in header
assert "if (valid)" in header
assert "CRGameCenterAccountReferencedInSettings(" in smoke
assert "NSNull.null" in smoke

assert "check_gamecenter_unused_delete_contract.py" in workflow
print("Crane G-07 unused-account safe metadata removal contract: PASS (native/device unverified)")
