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
sb = (root / "sources/cranesb/CRSpringBoard.m").read_text(encoding="utf-8")
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
assert "id stored = [self preferenceValueForKey:key];" in manager
assert "legacy = [self.applications[appID] copy];" in manager
assert "return CRManagerSettingsIncludingDefault(stored);" in manager
assert "settings = CRManagerSettingsIncludingDefault(settings);" in manager
support = section(manager, "- (BOOL)isApplicationSupportedByCrane:",
                  "- (NSArray<NSString *> *)identifiersOfAllSupportedApplications")
assert "checkIsApplicationWithIdentifier:appID" in support
assert "supportedByCraneAndReply:" in support
assert "applicationSettingsForApplicationWithIdentifier:appID" not in support
assert "return self.applications[appID]" not in support
assert 'CFPreferencesAppSynchronize((__bridge CFStringRef)CR_PREFS_DOMAIN)' in manager
assert 'CFPreferencesSetAppValue(CFSTR("applications")' not in manager
assert "self.lastError = error;" in manager
app_controller = ui[ui.index("@implementation CRPApplicationConfigurationListController"):]
add = section(app_controller, "- (void)addButtonPressed", "@end")
assert add.index("if (!identifier.length)") < add.index('NSLog(@"CranePrefs: created container')
assert "tools/container_menu_smoke.m" in workflow
smoke = (root / "tools/container_menu_smoke.m").read_text(encoding="utf-8")
# CI executes this Objective-C smoke on macOS. Keep its expectations aligned
# with the recovered libcrane 0x937C empty-settings DEFAULT projection.
assert "CRManagerSettingsIncludingDefault(nil).count == 0" not in smoke
assert "CRManagerSettingsIncludingDefault(@{}).count == 0" not in smoke
for fragment in (
    "NSDictionary *nativeDefault = @{",
    "CRCContainer_Name: @\"\",",
    "CRCContainer_Identifier: CR_DEFAULT_CONTAINER_IDENTIFIER",
    "CRCContainer_ActiveContainer: CR_DEFAULT_CONTAINER_IDENTIFIER",
    "assert([fromNil isEqual:nativeDefault]);",
    "assert([fromEmpty isEqual:nativeDefault]);",
    "assert([CRManagerSettingsIncludingDefault(fromNil) isEqual:fromNil]);",
):
    assert fragment in smoke, fragment

# Always Ask Before Launch is a per-app setting in original 0x1F008, not a
# global CFPreferences gate. CraneSB 0x17A14 installs three SBIconController
# launch hooks, all of which route through 0x12B3C only when that app opts in.
always = section(sb, "static BOOL CRAlwaysAskBeforeLaunch(NSString *appID)",
                 "/* 0x1EB9C")
assert "applicationSettingsForApplicationWithIdentifier:appID" in always
assert "CRAppSetting_AlwaysAskBeforeLaunchEnabled" in always
assert "CRPrefBool(CRPref_AlwaysAskBeforeLaunch)" not in always
for selector in (
    '@"_launchFromIconView:"',
    '@"_launchFromIconView:withActions:"',
    '@"_launchFromIconView:withActions:modifierFlags:"',
):
    assert selector in sb, selector
for hook in (
    "static void CRLaunchFromIconView(",
    "static void CRLaunchFromIconViewActions(",
    "static void CRLaunchFromIconViewActionsFlags(",
):
    body = section(sb, hook, "\n}\n")
    assert "CRAlwaysAskBeforeLaunch(appID)" in body
    assert "CRHandleAppLaunchContainerPicker(" in body
picker = section(sb, "static void CRHandleAppLaunchContainerPicker(",
                 "static id CRLaunchPickerPresenter(")
for fragment in (
    'CRLocalize(@"SELECT_CONTAINER")',
    "containerIdentifiersOfApplicationWithIdentifier:appID",
    "displayNameForContainerWithIdentifier:containerID",
    "shouldUseShortVersion:NO",
    'systemImageNamed:@"checkmark"',
    'CRIcon(@"SelectedContainerCheckmark")',
    "setActiveContainerIdentifier:containerID",
    "usingBiometricsIfNeededWithSuccessHandler:",
    "CROpenApplicationAfterContainerSwitch(appID);",
    'CRLocalize(@"CANCEL")',
    "popover.sourceView = sourceView;",
    "popover.sourceRect = ((UIView *)sourceView).bounds;",
):
    assert fragment in picker, fragment
assert picker.index("if ([containerID isEqualToString:active])") < picker.index(
    "setActiveContainerIdentifier:containerID")

native_always = original / "1F008.c"
if native_always.exists():
    evidence = native_always.read_text(encoding="utf-8")
    assert 'CFSTR("alwaysAskBeforeLaunchEnabled")' in evidence
    assert "applicationSettingsForApplicationWithIdentifier:" in evidence

print("Crane original shortcut/default-container source contracts: PASS (device unverified)")
