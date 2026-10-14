"""G-07 first safe slice: original Game Center account registry shape.

The original CranePrefs methods 0x15448, 0x14D00, 0x14D8C, 0x1312C and
0x13310 prove the persisted value is an array of {identifier, name} dictionaries,
not the old reconstruction's NSArray<NSString *> model.
This is only schema parity; no gamed/accountsd switch side effects are claimed.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
header = (root / "sources/common/CRManager.h").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
schema = (root / "sources/common/CRGameCenterAccounts.h").read_text(encoding="utf-8")
smoke = (root / "tools/container_menu_smoke.m").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

for token in (
    "- (NSArray<NSDictionary *> *)gameCenter_availableAccounts",
    "- (void)gameCenter_setAvailableAccounts:(NSArray<NSDictionary *> *)accounts",
):
    assert token in header, token
    assert token in manager, token

assert '#import "CRGameCenterAccounts.h"' in manager
assert "CRGameCenterValidatedAccounts(stored)" in manager
assert "CRGameCenterAccountsAreValidForWrite(accounts)" in manager
assert "[self setPreferenceValue:[accounts copy]" in manager
# Disassembly of original libcrane 0x9608/0x961C resolves a CFString
# literal "gameCenterAccounts", not the older reconstruction-specific key.
assert 'id stored = [self preferenceValueForKey:@"gameCenterAccounts"]' in manager
assert 'forKey:@"gameCenterAccounts"]' in manager
assert 'if (!stored)' in manager
assert 'stored = [self preferenceValueForKey:@"crane_gameCenter.availableAccounts"]' in manager
assert manager.index('preferenceValueForKey:@"gameCenterAccounts"') < manager.index(
    'preferenceValueForKey:@"crane_gameCenter.availableAccounts"')
assert "CRGameCenterAccountIdentifierExists(" in manager
assert "containsObject:account" not in manager[
    manager.index("- (BOOL)gameCenter_isAccountAvailable:"):
    manager.index("- (void)gameCenter_reloadExceptApplicationWithIdentifier:")
]

for token in (
    'entry[@"identifier"]',
    'entry[@"name"]',
    'identifier isEqualToString:@"DEFAULT"',
    "[identifiers containsObject:identifier]",
    "[entry copy]",
    "CRGameCenterValidatedAccounts(value).count == [(NSArray *)value count]",
    'identifier isEqualToString:@"DEFAULT"',
):
    assert token in schema, token

for token in (
    '#import "CRGameCenterAccounts.h"',
    "CRGameCenterValidatedAccounts(nil)",
    "CRGameCenterAccountsAreValidForWrite(@[gameA, gameA])",
    "CRGameCenterAccountIdentifierExists(validGames",
):
    assert token in smoke, token
assert "tools/container_menu_smoke.m" in workflow

# Workstation-original exports are intentionally excluded from Git. Validate
# them when locally available, without breaking GitHub Actions checkout.
decompile = root.parent / (
    "Library/PreferenceBundles/CranePrefs.bundle/"
    "CranePrefs_export_for_ai/decompile"
)
for address, fragments in {
    "15448": ('CFSTR("name")', 'CFSTR("identifier")', '"addObject:"'),
    "14D00": ('"gameCenter_availableAccounts"', '"mutableCopy"'),
    "14D8C": ('"gameCenter_setAvailableAccounts:"',),
    "1312C": ('CFSTR("name")', '"gameCenter_availableAccounts"'),
    "13310": ('CFSTR("identifier")', '"gameCenter_availableAccounts"'),
}.items():
    path = decompile / (address + ".c")
    if path.is_file():
        original = path.read_text(encoding="utf-8")
        for fragment in fragments:
            assert fragment in original, (address, fragment)

# Additional original libcrane IMPs recovered directly from Mach-O classlist
# and targeted ARM64 disassembly (workstation-only binary, tracked metadata).
import json
evidence = json.loads((root.parent / "analysis/objc_classes.json").read_text(encoding="utf-8"))
methods = {
    method["sel"]: method["imp"]
    for method in evidence["libcrane.dylib"]["CraneManager"]["instance_methods"]
}
for selector, imp in {
    "gameCenter_enabledApplicationIdentifiers": "0x9800",
    "gameCenter_reloadExceptApplicationWithIdentifier:": "0x99BC",
    "gameCenter_activeAccount": "0x9AE4",
    "gameCenter_setActiveAccount:": "0x9BC0",
    "gameCenter_setActiveAccount:andDontKillApplication:": "0x9BD0",
}.items():
    assert methods[selector].upper() == imp.upper(), selector

assert "- (NSArray<NSString *> *)gameCenter_enabledApplicationIdentifiers;" in header
enable_start = manager.index("- (NSArray<NSString *> *)gameCenter_enabledApplicationIdentifiers\n{")
active_start = manager.index("- (NSString *)gameCenter_activeAccount", enable_start)
enable = manager[enable_start:active_start]
for fragment in (
    "CFPreferencesCopyKeyList(",
    'NSString *prefix = @"appSettings_";',
    "[key hasPrefix:prefix]",
    "[self preferenceValueForKey:key]",
    "CRAppSetting_GameCenterSupportEnabled",
    "substringFromIndex:prefix.length",
):
    assert fragment in enable, fragment
assert "applicationSettingsForApplicationWithIdentifier:" not in enable
assert "setPreferenceValue:" not in enable

active_end = manager.index("- (NSArray<NSDictionary *> *)gameCenter_availableAccounts", active_start)
active = manager[active_start:active_end]
assert 'preferenceValueForKey:@"activeGameCenterAccount"' in active
assert "CRGameCenterResolvedActiveAccount(" in active
assert "[self gameCenter_setActiveAccount:account andDontKillApplication:nil];" in active
assert "[self gameCenter_activeAccount] isEqualToString:resolved" in active
assert '[self setPreferenceValue:resolved forKey:@"activeGameCenterAccount"]' in active
assert "[self gameCenter_reloadExceptApplicationWithIdentifier:appID]" in active
assert active.index("isEqualToString:resolved") < active.index("setPreferenceValue:resolved")
assert active.index("setPreferenceValue:resolved") < active.index(
    "gameCenter_reloadExceptApplicationWithIdentifier:appID")

reload_start = manager.index(
    "- (void)gameCenter_reloadExceptApplicationWithIdentifier:(NSString *)appID"
)
reload_end = manager.index("/* ---- keychain", reload_start)
reload = manager[reload_start:reload_end]
assert "if (![appID isKindOfClass:NSString.class] || !appID.length)" in reload
assert "[self reloadGameDaemons];" in reload
assert "[self gameCenter_enabledApplicationIdentifiers]" in reload
assert "if (![enabledApp isEqualToString:appID])" in reload
assert "[self reloadApplicationWithIdentifier:enabledApp];" in reload
assert reload.index("!appID.length") < reload.index("[self reloadGameDaemons]")
assert reload.index("[self reloadGameDaemons]") < reload.index(
    "[self reloadApplicationWithIdentifier:enabledApp]")
assert "CRGameCenterResolvedActiveAccount(" in schema
assert "CRGameCenterAccountIdentifierExists(accounts, stored)" in schema
assert "CRGameCenterResolvedActiveAccount(validGames, nil)" in smoke
assert "CRGameCenterResolvedActiveAccount(validGames, @42)" in smoke

accountsd = (root / "sources/support/CRAccountsd.m").read_text(encoding="utf-8")
assert "[manager gameCenter_enabledApplicationIdentifiers]" in accountsd
assert "[manager gameCenter_activeAccount]" in accountsd
assert "@interface CraneManager (CraneAccountsdPrivate)" not in accountsd

print("Crane G-07 native account schema + active switching contracts: PASS (device unverified)")
