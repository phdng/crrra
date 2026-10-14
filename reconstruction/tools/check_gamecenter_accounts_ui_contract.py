"""G-07 Game Center account management Settings controller contract.

Non-destructive Create + Rename + parent refresh follow original CranePrefs
0x14BF4/0x14D00/0x14D8C/0x15250/0x15448/0x15564/0x157E4/0x15BE0/0x15F90.
Original removeAccountWithIdentifier: also deletes accountsd SQLite storage, so
we intentionally do not expose a destructive Delete action before device proof.
"""
from pathlib import Path
import json

root = Path(__file__).resolve().parents[1]
source = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")
schema = (root / "sources/common/CRGameCenterAccounts.h").read_text(encoding="utf-8")

start = source.index("@interface CRPGameCenterAccountsController : PSListController")
end = source.index("/* Initial container detail controller reconstructed", start)
controller = source[start:end]
assert "@implementation CRPGameCenterAccountsController" in controller

for needle in (
    "- (id)specifiers",
    'CRLocalize(@"GAME_CENTER_MANAGER_FOOTER")',
    'CRLocalize(@"SYSTEM_DEFAULT")',
    'CRLocalize(@"GAME_CENTER_ACCOUNTS")',
    'entry[@"identifier"]',
    'entry[@"name"]',
    'setButtonAction:@selector(accountPressed:)',
    "UIBarButtonSystemItemAdd",
    "- (void)addButtonPressed",
    'CRLocalize(@"GAME_CENTER_ADD_ACCOUNT_TITLE")',
    'CRLocalize(@"GAME_CENTER_ADD_ACCOUNT_MESSAGE")',
    "- (NSString *)addAccountWithName:",
    "[NSUUID UUID].UUIDString",
    "- (void)accountPressed:(PSSpecifier *)specifier",
    'CRLocalize(@"GAME_CENTER_RENAME_ACCOUNT_TITLE")',
    "- (void)renameAccountWithIdentifier:(NSString *)identifier toName:",
    "- (NSDictionary *)dictionaryForAccountWithIdentifier:",
    "- (void)reloadListInParentController",
    "@selector(reloadAssociatedGameCenterAccount)",
    "- (BOOL)writeAccountWithIdentifier:",
    "CRGameCenterAccountsAreValidForWrite(raw)",
    'preferenceValueForKey:@"gameCenterAccounts"',
    'preferenceValueForKey:@"crane_gameCenter.availableAccounts"',
    "[manager gameCenter_availableAccounts]",
    "indexOfObjectPassingTest:",
    'accounts addObject:@{@"identifier":identifier, @"name":cleanName}',
    'updated[@"name"] = cleanName;',
    "[manager gameCenter_setAvailableAccounts:accounts]",
    "[self scheduleAccountListReload]",
):
    assert needle in controller, needle

# Native DEFAULT is UI-only; neither Add nor Rename can mutate it.
assert '[identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]' in controller
assert "return NO;" in controller
assert "CRGameCenterAccountsAreValidForWrite" in schema
assert "removeAccountWithIdentifier:" not in controller
assert "_removeAccountsDatabaseIfExistsForIdentifier:" not in controller
assert "performDeletionActionForSpecifier:" not in controller

picker_start = source.index(
    "@implementation CRPContainerConfigurationListController")
picker_end = source.index(
    "@implementation CRPApplication", picker_start)
picker = source[picker_start:picker_end]
for needle in (
    'CRLocalize(@"MANAGE_GAME_CENTER_ACCOUNTS")',
    "detail:[CRPGameCenterAccountsController class] cell:2 edit:0",
    "setDetailControllerClass:[CRPGameCenterAccountsController class]",
    "- (void)reloadAssociatedGameCenterAccount",
    "[self scheduleContainerConfigurationReload]",
):
    assert needle in picker, needle

assert "check_gamecenter_accounts_ui_contract.py" in workflow
methods = json.loads((root.parent / "analysis/objc_classes.json").read_text(
    encoding="utf-8"))["CranePrefs"]["CRPGameCenterAccountsController"]["instance_methods"]
indexed = {method["sel"]: method["imp"] for method in methods}
for sel, imp in {
    "reloadListInParentController": "0x14BF4",
    "loadGameCenterAccounts": "0x14D00",
    "saveGameCenterAccounts": "0x14D8C",
    "renameAccountWithIdentifier:toName:": "0x15250",
    "addAccountWithIdentifier:name:": "0x15448",
    "addAccountWithName:": "0x15564",
    "specifiers": "0x157E4",
    "addButtonPressed": "0x15BE0",
    "accountPressed:": "0x15F90",
}.items():
    assert indexed[sel].upper() == imp.upper(), sel

# Decompiler artifacts are local, not tracked in CI.
native = (root.parent / "Library/PreferenceBundles/CranePrefs.bundle/"
          "CranePrefs_export_for_ai/decompile")
for addr, symbols in {
    "14BF4": ('"reloadAssociatedGameCenterAccount"',),
    "15448": ('CFSTR("name")', 'CFSTR("identifier")',),
    "15564": ('"UUID"', '"UUIDString"'),
    "157E4": ('CFSTR("GAME_CENTER_MANAGER_FOOTER")', 'CFSTR("DEFAULT")'),
    "15BE0": ('CFSTR("GAME_CENTER_ADD_ACCOUNT_TITLE")',),
    "15F90": ('CFSTR("GAME_CENTER_RENAME_ACCOUNT_TITLE")',),
    "1502C": ('"_removeAccountsDatabaseIfExistsForIdentifier:"',),
}.items():
    path = native / f"{addr}.c"
    if path.exists():
        orig = path.read_text(encoding="utf-8")
        for symbol in symbols:
            assert symbol in orig, (addr, symbol)

print("Crane G-07 Game Center account manager UI: PASS (macOS/device unverified)")
