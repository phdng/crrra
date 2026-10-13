"""F-21 optional Choicy integration group contracts (CranePrefs 0x10BD4-111AC).

Static/behavioral checks for guarded bundle detection, per-container toggle
persistence and dynamically subclassed editor. Resolves original selectors
from exported memory. Native mock smoke is separate; no device parity claim.
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
# dictionary's contents. Link the editor only when its private ABI is usable.
assert 'NSSelectorFromString(@"previewStringForProcessPreferences:")' in controller
assert 'for (NSString *name in @[@"CHPListController", @"CHPApplication"])' in controller
assert 'return @"";' in controller
assert 'Class editorClass = CRChoicyContainerEditorClass();' in controller
assert 'detail:editorClass cell:(editorClass ? 2 : 4) edit:0' in controller
assert '[preview setDetailControllerClass:editorClass];' in controller

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

# Resolve the five hidden initialization selectors from native evidence.
# Full CranePrefs memory dumps are ignored by Git (Library/ in .gitignore),
# so a GitHub Actions checkout cannot read virtual address 0x3F180.
# A small checked-in byte-for-byte fixture is the CI source of evidence.
# If the native export is present locally, cross-check ALL sampled bytes.
import json
import os
import re
import struct

expected = [
    (0x3F180, 0x58FD0, "shouldShowAppPlugIns"),
    (0x3F1A0, 0x58FD8, "shouldShowTweak:"),
    (0x3F1C0, 0x58FE0, "readPreferences"),
    (0x3F1E0, 0x58FE8, "writePreferences"),
    (0x3F200, 0x58FF0, "sendPostNotification"),
]
fixture_file = root / "tools/fixtures/choicy_native_selectors.json"
fixture = json.loads(fixture_file.read_text(encoding="utf-8"))
assert fixture["architecture"] == "arm64"
assert len(fixture["entries"]) == len(expected)

editor = (root / "sources/prefs/CRChoicyEditor.m").read_text(encoding="utf-8")
samples = []
for (pc, slot, selector), record in zip(expected, fixture["entries"]):
    assert int(record["pc"], 16) == pc
    assert int(record["slot"], 16) == slot
    assert record["selector"] == selector
    instruction_bytes = bytes.fromhex(record["instruction"])
    slot_bytes = bytes.fromhex(record["slot_bytes"])
    string_bytes = bytes.fromhex(record["string_bytes"])
    assert len(instruction_bytes) == 4
    assert len(slot_bytes) == 8
    assert string_bytes == selector.encode("utf-8") + b"\0"
    instruction = struct.unpack("<I", instruction_bytes)[0]
    assert instruction & 0xFF00001F == 0x58000001  # LDR x1, literal
    immediate = (instruction >> 5) & 0x7FFFF
    if immediate & 0x40000:
        immediate -= 0x80000
    assert pc + immediate * 4 == slot
    pointer = struct.unpack("<Q", slot_bytes)[0]
    assert pointer == int(record["string_address"], 16)
    assert '{"' + selector + '", (IMP)CRChoicy' in editor
    samples.append((pc, instruction_bytes, slot, slot_bytes, pointer, string_bytes))

export = root.parent / "Library/PreferenceBundles/CranePrefs.bundle/CranePrefs_export_for_ai"
dump_files = sorted((export / "memory").glob("*.txt"))
skip_native = os.environ.get("CRANE_CHOICY_SKIP_NATIVE_EXPORT") == "1"
require_native = os.environ.get("CRANE_CHOICY_REQUIRE_NATIVE_EXPORT") == "1"
assert not (skip_native and require_native)
if require_native:
    assert dump_files, "Native CranePrefs memory export is required but missing"

if dump_files and not skip_native:
    memory = {}
    line_pattern = re.compile(r"^([0-9A-Fa-f]+)\s\|\s([0-9A-Fa-f\s]+?)\s*\|")
    for dump in dump_files:
        for line in dump.read_text(encoding="utf-8").splitlines():
            match = line_pattern.match(line)
            if match:
                address = int(match[1], 16)
                data = bytes.fromhex(match[2])
                memory.update((address + i, byte) for i, byte in enumerate(data))

    def read_native(address, size):
        missing = [address + i for i in range(size) if address + i not in memory]
        assert not missing, (
            f"Incomplete CranePrefs memory export at 0x{missing[0]:X}; "
            "checked-in selector fixture remains available"
        )
        return bytes(memory[address + i] for i in range(size))

    for pc, instruction_bytes, slot, slot_bytes, pointer, string_bytes in samples:
        assert read_native(pc, 4) == instruction_bytes
        assert read_native(slot, 8) == slot_bytes
        assert read_native(pointer, len(string_bytes)) == string_bytes
    print("CranePrefs selector evidence: tracked fixture + native export cross-check PASS")
else:
    print("CranePrefs selector evidence: tracked fixture PASS (native export unavailable/skipped)")

for fragment in (
    'objc_allocateClassPair(parent,',
    '"CRPContainerChoicyOverwriteListController"',
    'method_getTypeEncoding(inherited)',
    'CRChoicyMethodMatches(parent,',
    'objc_disposeClassPair(editor)',
    'objc_registerClassPair(editor)',
    '[name isEqualToString:@" Crane"]',
    'return gCRChoicyOriginalShouldShowTweak(self, selector, tweak);',
    '[configuration mutableCopy] ?: [NSMutableDictionary new]',
    'settings[CRCContainer_ChoicyConfigurationOverwrite] = [preferences copy];',
    'isValidForFormat:NSPropertyListBinaryFormat_v1_0',
    '[manager reloadApplicationWithIdentifier:appID]',
):
    assert fragment in editor, fragment
assert 'NSUserDefaults' not in editor
assert 'CRCContainer_ChoicyConfigurationOverwriteEnabled] =' not in editor
assert 'CRChoicyEditor.m' in (root / "sources/prefs/Makefile").read_text()
workflow = (root.parent / ".github/workflows/build.yml").read_text()
assert 'sources/prefs/CRChoicyEditor.m tools/choicy_editor_smoke.m' in workflow
assert 'for mode in missing incomplete incompatible collision valid;' in workflow
print("Crane F-21 Choicy editor source/evidence contracts: PASS (native/device unverified)")
