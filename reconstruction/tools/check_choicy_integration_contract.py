"""F-21 optional Choicy integration group contracts (CranePrefs 0x10BD4-111AC).

Static/behavioral checks for guarded bundle detection, per-container toggle
persistence and read-only preview. The dynamically subclassed Choicy editor
of the original is still not reconstructed; no runtime parity claim.
"""
from pathlib import Path
root = Path(__file__).resolve().parents[1]
source = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
constants = (root / "sources/common/CRPreferences.h").read_text(encoding="utf-8")
paths = (root / "sources/common/CRPaths.h").read_text(encoding="utf-8")

start = source.index("@implementation CRPContainerConfigurationListController")
end = source.index("@end", start)
controller = source[start:end]

assert '#define CR_CHOICY_PREFS_BUNDLE' in paths
assert 'CRCContainer_ChoicyConfigurationOverwriteEnabled' in constants
assert 'CRCContainer_ChoicyConfigurationOverwrite' in constants

# Native 0x10BD4: don't inject the integration group into DEFAULT or on a
# device with no loadable Choicy preferences bundle.
for snippet in [
    '![self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    '[self craneChoicyIntegrationAvailable]',
    'NSClassFromString(@"CHPProcessConfigurationListController")',
    'CRJailbreakRootPath(CR_CHOICY_PREFS_BUNDLE)',
    '[bundle load];',
    'CRLocalize(@"CHOICY_INTEGRATION")',
    'CRLocalize(@"OVERWRITE_CHOICY_CONFIGURATION")',
    'CRCContainer_ChoicyConfigurationOverwriteEnabled',
    'CRLocalize(@"CHOICY_CONFIGURATION")',
    'CRCContainer_ChoicyConfigurationOverwrite',
    'self.choicyConfigurationPreviewSpecifier = preview;',
]:
    assert snippet in controller, snippet

assert 'get:@selector(readPreferenceValue:)' in controller
assert 'set:@selector(setChoicyOverwriteEnabled:specifier:)' in controller
assert 'if ([settings[CRCContainer_ChoicyConfigurationOverwriteEnabled] boolValue])' in controller
assert 'self.choicyOverwriteToggleSpecifier = nil;' in controller
assert 'self.choicyConfigurationPreviewSpecifier = nil;' in controller

# Per-container settings, not Preferences.app's NSUserDefaults.
assert '- (id)readPreferenceValue:(PSSpecifier *)specifier' in controller
assert 'containerSettingsForContainerWithIdentifier:self.containerIdentifier' in controller
assert 'return settings[key];' in controller
assert '- (void)setChoicyOverwriteEnabled:(id)value specifier:(PSSpecifier *)specifier' in controller
assert 'settings[CRCContainer_ChoicyConfigurationOverwriteEnabled] = @([value boolValue]);' in controller
assert '[manager setContainerSettings:settings' in controller
assert 'forContainerWithIdentifier:self.containerIdentifier' in controller
assert 'NSUserDefaults' not in controller

# Native 0x10D84 uses Choicy's own preview method, never guesses the
# dictionary's contents. The missing native editor is not advertised.
assert 'NSSelectorFromString(@"previewStringForProcessPreferences:")' in controller
assert 'for (NSString *name in @[@"CHPListController", @"CHPApplication"])' in controller
assert 'return @"";' in controller
assert 'detail:NULL cell:4 edit:0' in controller

# 0x10CD0 toggles visibility and avoids duplicate editor-preview rows.
for fragment in (
    '[current containsObject:preview]',
    '[self insertSpecifier:preview afterSpecifier:specifier animated:YES];',
    '[self removeSpecifier:preview animated:YES];',
    '[updated insertObject:preview atIndex:index + 1];',
    '[updated removeObject:preview];',
    'self.craneContainerSpecifiers = [updated copy];',
):
    assert fragment in controller, fragment

def display_rows(container_id, installed, enabled):
    rows = ["group", "active", "rename"]
    if container_id != "DEFAULT" and installed:
        rows += ["choicy-group", "toggle"]
        if enabled:
            rows.append("preview")
    return rows

assert display_rows("DEFAULT", True, True) == ["group", "active", "rename"]
assert display_rows("C1", False, True) == ["group", "active", "rename"]
assert display_rows("C1", True, False)[-1] == "toggle"
assert display_rows("C1", True, True)[-1] == "preview"

print("Crane F-21 Choicy integration static contracts: PASS (editor/device unverified)")
