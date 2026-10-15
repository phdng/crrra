"""G-10 root suggestion providers against original CranePrefs 0x21470..0x21B40.

Static/source-level protection against regressions; does not verify UIKit
runtime linkage or device presentation. The native actions and gate selectors
are also present in tracked objc_classes.json.
"""
from pathlib import Path
import json
import plistlib

root = Path(__file__).resolve().parents[1]
provider = (root / "sources/prefs/CRRootSuggestions.m").read_text(encoding="utf-8")
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
make = (root / "sources/prefs/Makefile").read_text(encoding="utf-8")
stub = (root / "vendor/Preferences.framework/Preferences.tbd").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")
classes = json.loads((root.parent / "analysis/objc_classes.json").read_text(
    encoding="utf-8"))["CranePrefs"]
root_plist = plistlib.loads((root / "layout/Library/PreferenceBundles/CranePrefs.bundle/Root.plist").read_bytes())

assert "CRRootSuggestions.m" in make
assert "'_OBJC_CLASS_$_PSTableCell'" in stub
assert "'_OBJC_METACLASS_$_PSTableCell'" in stub
assert "check_root_suggestions_contract.py" in workflow
assert any(row.get("label") == "REPLACE_WITH_SUGGESTIONS"
           for row in root_plist["items"])
assert "@implementation CRPRootPageSuggestionProvider" in provider
assert "@implementation CRPInfoTableCell" in provider
assert ": PSTableCell" in provider
assert "[super refreshCellContentsWithSpecifier:specifier]" in provider
assert "UITableViewCellAccessoryDetailButton" in provider
assert "cell:7 edit:0" in provider

for fragment in (
    "shouldShowChoicyLoaderSuggestion",
    "shouldShowActivatorInfoSuggestion",
    "shouldShowShortcutsInfoSuggestion",
    "alertControllerForSpecifierIdentifier:",
    "suggestionSpecifiers",
    'CRLocalize(@"SUGGESTIONS")',
    '@"suggestionsGroup"',
    '@"choicyLoaderSuggestion"',
    '@"activatorInfoSuggestion"',
    '@"shortcutsInfoSuggestion"',
    "setProperty:[CRPInfoTableCell class]",
    "if (!choicy && !activator && !shortcuts)",
    "if (!entries || error)",
    "contentsOfDirectoryAtPath:directory",
    "CRJailbreakRootPath(@\"/usr/lib/ChoicyLoader.dylib\")",
    'CRGetInjectionPlatform() isEqualToString:@"Substrate"',
    '@"/Library/MobileSubstrate/DynamicLibraries"',
    '@"/usr/lib/libactivator.dylib"',
    '@"LSApplicationProxy"',
    'NSSelectorFromString(@"applicationProxyForIdentifier:")',
    'NSSelectorFromString(@"isInstalled")',
    '@"com.apple.shortcuts"',
    "CRLocalize(titleKey)",
    "CRLocalize(messageKey)",
    'CRLocalize(@"OPEN_REPO")',
    'CRLocalize(@"CLOSE")',
    "https://opa334.github.io",
    "return nil;",
):
    assert fragment in provider, fragment
assert provider.index('if (!choicy && !activator && !shortcuts)') < provider.index(
    '[PSSpecifier emptyGroupSpecifier]')
assert "removeItemAtPath:" not in provider
assert "killall" not in provider
assert "opendir(" not in provider
assert "readdir(" not in provider

root_controller = prefs[prefs.index("@implementation CRPRootListController"):
                        prefs.index("/* The original CRPActiveContainerListItemsController")]
assert "replaceObjectsInRange:NSMakeRange(markerIndex, 1)" in root_controller
assert "[CRPRootPageSuggestionProvider suggestionSpecifiers]" in root_controller
assert 'row.name isEqualToString:@"REPLACE_WITH_SUGGESTIONS"' in root_controller
assert "accessoryButtonTappedForRowWithIndexPath:" in root_controller
assert "alertControllerForSpecifierIdentifier:[row identifier]" in root_controller
assert "if (alert)" in root_controller
assert "[self presentViewController:alert animated:YES completion:nil]" in root_controller

def recovered_methods(name, method_type):
    return {m["sel"]: m["imp"] for m in classes[name][method_type]}

for sel, addr in {
    "shouldShowChoicyLoaderSuggestion": "0x21470",
    "shouldShowActivatorInfoSuggestion": "0x216E0",
    "shouldShowShortcutsInfoSuggestion": "0x217BC",
    "alertControllerForSpecifierIdentifier:": "0x21818",
    "suggestionSpecifiers": "0x21B40",
}.items():
    assert recovered_methods("CRPRootPageSuggestionProvider", "class_methods")[sel].upper() == addr.upper()
assert recovered_methods("CRPInfoTableCell", "instance_methods")[
    "refreshCellContentsWithSpecifier:"].upper() == "0X168CC"
assert recovered_methods("CRPRootListController", "instance_methods")[
    "tableView:accessoryButtonTappedForRowWithIndexPath:"].upper() == "0X1FE80"

decompile = (root.parent / "Library/PreferenceBundles/CranePrefs.bundle/"
             "CranePrefs_export_for_ai/decompile")
for address, token in {
    "21470": 'CFSTR("/usr/lib/ChoicyLoader.dylib")',
    "216E0": 'CFSTR("/usr/lib/libactivator.dylib")',
    "217BC": 'CFSTR("com.apple.shortcuts")',
    "21818": 'CFSTR("choicyLoaderSuggestion")',
    "21AC0": 'CFSTR("https://opa334.github.io")',
    "21B40": 'CFSTR("suggestionsGroup")',
    "168CC": '"setAccessoryType:"',
    "1FE80": '"alertControllerForSpecifierIdentifier:"',
}.items():
    path = decompile / (address + ".c")
    if path.is_file():
        assert token in path.read_text(encoding="utf-8"), address

print("Crane G-10 root suggestions source and original hooks: PASS (device unverified)")
