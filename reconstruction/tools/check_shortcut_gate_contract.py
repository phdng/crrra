"""Original CraneSB shortcut gate regression, portable across Git checkouts.

Native evidence: 0x1ECD8/1EE64/1EEF0/1EF7C explicit nil->YES,
0x15E20/170A4 DEFAULT-inclusive count >1, 0x1611C capture before original,
0x145B8 children before title, 0x137FC DEFAULT + custom selection actions.
Original libcrane registry storage is not exported; its adapter is explicit.
"""
from pathlib import Path
import plistlib
import re

root = Path(__file__).resolve().parents[1]
prefs = (root / "sources/common/CRPreferences.h").read_text(encoding="utf-8")
registry = (root / "sources/common/CRContainerRegistry.h").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
menu = (root / "sources/cranesb/CRMenuHooks.m").read_text(encoding="utf-8")
ui = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

constants = dict(re.findall(r'#define\s+(CRPref_\w+)\s+@"([^"]+)"', prefs))
value_helper = prefs[prefs.index("static inline BOOL CRPrefBoolValue"):
                     prefs.index("static inline BOOL CRPrefBool(")]
yes_constants = set(re.findall(r'isEqualToString:(CRPref_\w+)', value_helper))
fallback_yes = {constants[key] for key in yes_constants}
table = plistlib.loads((root / "layout/Library/PreferenceBundles/CranePrefs.bundle/Root.plist").read_bytes())
native_yes = {item["key"] for item in table["items"]
              if item.get("default") is True and "key" in item}
assert fallback_yes == native_yes
assert "if (value)" in value_helper and "return [value boolValue];" in value_helper
assert "CRPrefBoolValue(key," in prefs

# When original exports are present, also validate the exact recovered branches.
# CI can run from the tracked Root.plist without the ignored Library/ exports.
original = root.parent / "Library/MobileSubstrate/DynamicLibraries/CraneSB.dylib_export_for_ai/decompile"
for offset, key in (("1ECD8", "applicationShortcutEnabled"),
                    ("1EE64", "onlyShowIfContainersExistEnabled"),
                    ("1EEF0", "newContainerShortcutEnabled"),
                    ("1EF7C", "showContainerNotificationBadgesEnabled")):
    evidence = original / (offset + ".c")
    if evidence.exists():
        native = evidence.read_text(encoding="utf-8")
        assert 'CFSTR("' + key + '")' in native
        assert "if ( v1 )" in native and "else" in native
        assert "v2 = &dword_0 + 1;" in native

def section(source, start, end):
    begin = source.index(start)
    return source[begin:source.index(end, begin)]

query = section(menu, "static NSArray *CRApplicationShortcutItems(",
                "static id CRContextMenuConfiguration(")
for native_fragment in (
    "if (!CRPrefBool(CRPref_AppShortcutEnabled))",
    "isApplicationSupportedByCrane:appID",
    "applicationSettingsForApplicationWithIdentifier:appID",
    "if (containers.count <= 1 &&",
    "CRPrefBool(CRPref_OnlyShowIfContainersExist)",
    'NSClassFromString(@"SBSApplicationShortcutItem")',
    'NSSelectorFromString(@"setLocalizedTitle:")',
    "kMenuPlaceholder", "kApplicationContainerType",
    "return existing ? [@[placeholder] arrayByAddingObjectsFromArray:existing]",
):
    assert native_fragment in query, native_fragment
context = section(menu, "static id CRContextMenuConfiguration(",
                  "static id CRMenuInitWithOverrideChildren(")
assert context.index("[CRShortcutApplicationIdentifier(self) copy]") < context.index(
    "return original ? original(self, _cmd, interaction, location)")

for begin, end in (("static id CRUIMenuInitModern(", "static id CRUIMenuInitLegacy("),
                   ("static id CRUIMenuInitLegacy(", "void CRInitUIMenuHooks(")):
    fn = section(menu, begin, end)
    assert fn.index("CRChildrenByReplacingPlaceholder(children)") < fn.index(
        "if (replaced == children && [title isEqualToString:kMenuPlaceholder])")
    assert "return replacement;" in fn

builder = section(menu, "static UIMenu *CRBuildReplacementMenu(void)\n{",
                  "/* UIMenu placeholder replacement")
assert "gCRSelectedApplicationIdentifier = nil;" in builder
assert "for (NSDictionary *container in containers)" in builder
assert 'CRLocalize(@"CONTAINER")' in builder
assert 'CRLocalize(@"NEW_CONTAINER")' in builder
assert "children.reverseObjectEnumerator.allObjects" in builder

# Restore the array model expected by both the original gate and renderer.
assert "if (![seen containsObject:CR_DEFAULT_CONTAINER_IDENTIFIER])" in registry
assert "insertObject:@{CRCContainer_Identifier:CR_DEFAULT_CONTAINER_IDENTIFIER}" in registry
assert "atIndex:0" in registry
assert "#import \"CRContainerRegistry.h\"" in manager
assert "return CRManagerSettingsIncludingDefault(self.applications[appID]);" in manager
assert "settings = CRManagerSettingsIncludingDefault(settings);" in manager
support = section(manager, "- (BOOL)isApplicationSupportedByCrane:",
                  "- (NSArray<NSString *> *)identifiersOfAllSupportedApplications")
assert "applicationSettingsForApplicationWithIdentifier:appID" in support
assert "return self.applications[appID]" not in support
assert 'CFPreferencesAppSynchronize(CFSTR("com.opa334.cranereconstruction.apps"))' in manager
assert "self.lastError = error;" in manager
add = section(ui, "- (void)addButtonPressed", "@end")
assert add.index("if (!identifier.length)") < add.index('NSLog(@"CranePrefs: created container')
assert "tools/container_menu_smoke.m" in workflow

print("Crane original shortcut/default-container source contracts: PASS (device unverified)")
