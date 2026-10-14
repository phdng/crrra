"""CranePrefs G-07 per-container Game Center picker (native 0x11734/0x14038).

The picker must be visible only when two app-level switches are enabled,
persist only a known identifier to the selected container, and retain the
original F3D0 no-op reload(nil) call rather than adding destructive behavior.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRGameCenterAccounts.h").read_text(encoding="utf-8")
prefs = (root / "sources/common/CRPreferences.h").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

assert '#import "CRGameCenterAccounts.h"' in source
assert 'CRCContainer_AssociatedGameCenterAccount   @"associatedGameCenterAccount"' in prefs

spec_start = source.index("- (id)specifiers\n{", source.index(
    "@implementation CRPContainerConfigurationListController"))
spec_end = source.index("/* Native CranePrefs 0x11520 displays size", spec_start)
build = source[spec_start:spec_end]
for piece in (
    "appSettings[CRAppSetting_SeparateSystemAccountsEnabled]",
    "appSettings[CRAppSetting_GameCenterSupportEnabled]",
    'CRLocalize(@"GAME_CENTER_SECTION_HEADER")',
    'CRLocalize(@"GAME_CENTER_SECTION_FOOTER")',
    'CRLocalize(@"GAME_CENTER_ACCOUNT")',
    "set:@selector(setAssociatedGameCenterAccount:specifier:)",
    "get:@selector(readAssociatedGameCenterAccount:)",
    "detail:[PSListItemsController class] cell:2 edit:0",
    "setDetailControllerClass:[PSListItemsController class]",
    '"availableGameCenterAccountIdentifiers"',
    '"availableGameCenterAccountNames"',
    "CRCContainer_AssociatedGameCenterAccount",
):
    assert piece in build, piece

start = source.index("- (NSArray<NSString *> *)availableGameCenterAccountNames")
end = source.index("- (NSString *)previewStringForChoicyConfiguration:", start)
slice = source[start:end]
assert 'CRLocalize(@"SYSTEM_DEFAULT")' in slice
assert "CR_DEFAULT_CONTAINER_IDENTIFIER" in slice
assert 'account[@"name"]' in slice
assert 'account[@"identifier"]' in slice
assert "CRGameCenterResolvedActiveAccount(" in slice
assert "CRGameCenterAccountIdentifierExists(" in slice
assert "containsObject:self.containerIdentifier" in slice
assert "setContainerSettings:settings" in slice
assert "if (!settings.count)" in slice
assert "settings[CRCContainer_AssociatedGameCenterAccount] = value;" in slice
assert "[self reloadGameCenterIfThisContainerIsActive];" in slice
assert "gameCenter_reloadExceptApplicationWithIdentifier:nil" in slice
assert slice.index("CRGameCenterAccountIdentifierExists(") < slice.index(
    "settings[CRCContainer_AssociatedGameCenterAccount] = value;")
assert slice.index("settings[CRCContainer_AssociatedGameCenterAccount] = value;") < slice.index(
    "[self reloadGameCenterIfThisContainerIsActive];")
assert "CRGameCenterResolvedActiveAccount(" in header
assert "check_gamecenter_picker_contract.py" in workflow

# Original IDA decompile lives only in local workstation's reverse-engineering
# sources; CI can rely on recorded selectors and source invariants above.
decompile = (root.parent / "Library/PreferenceBundles/CranePrefs.bundle/"
             "CranePrefs_export_for_ai/decompile")
for address, tokens in {
    "11734": ('CFSTR("separateSystemAccountsEnabled")', 'CFSTR("gameCenterSupportEnabled")',
              'CFSTR("associatedGameCenterAccount")',
              'CFSTR("valuesDataSource")', 'CFSTR("titlesDataSource")'),
    "1312C": ('CFSTR("name")', 'CFSTR("SYSTEM_DEFAULT")'),
    "13310": ('CFSTR("identifier")', 'CFSTR("DEFAULT")'),
    "14038": ('"readAssociatedGameCenterAccount:"',
              '"setPreferenceValue:specifier:"',
              '"reloadGameCenterIfThisContainerIsActive"'),
    "F3D0": ('"gameCenter_reloadExceptApplicationWithIdentifier:"',),
}.items():
    path = decompile / f"{address}.c"
    if path.is_file():
        original = path.read_text(encoding="utf-8")
        for token in tokens:
            assert token in original, (address, token)

print("Crane G-07 container Game Center picker contracts: PASS (native/device unverified)")
