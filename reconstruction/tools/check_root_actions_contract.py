"""CranePrefs Root.plist action binding and native localization regression.

This restores original safe Root action selectors 0x213CC/0x16F9C and
0x16DA0 label/footer localization while deliberately NOT claiming backup
or restore backend parity (G-11 remains unported).
"""
from pathlib import Path
import json
import plistlib
import re

repo = Path(__file__).resolve().parents[2]
root = repo / "reconstruction"
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
credits = (root / "sources/prefs/CRCredits.m").read_text(encoding="utf-8")
links = (root / "sources/prefs/CRCreditsLinks.h").read_text(encoding="utf-8")
make = (root / "sources/prefs/Makefile").read_text(encoding="utf-8")
workflow = (repo / ".github/workflows/build.yml").read_text(encoding="utf-8")
layout = plistlib.loads((root / "layout/Library/PreferenceBundles/CranePrefs.bundle/Root.plist").read_bytes())
methods = {
    m["sel"]: m["imp"]
    for m in json.loads((repo / "analysis/objc_classes.json").read_text(
        encoding="utf-8"))["CranePrefs"]["CRPRootListController"]["instance_methods"]
}

assert "CRPreferences.m" in make and "CRCredits.m" in make
assert 'void CRCreditsOpenTwitter(NSString *username);' in links
assert 'void CRCreditsOpenTwitter(NSString *username)' in credits
assert 'static void CRCreditsOpenTwitter' not in credits
assert '#import "CRCreditsLinks.h"' in credits
assert '#import "CRCreditsLinks.h"' in prefs
assert '"twitter://user?screen_name=%@"' in credits
assert '"https://twitter.com/%@"' in credits

controller = prefs[prefs.index("@implementation CRPRootListController"):
                   prefs.index("/* The original CRPActiveContainerListItemsController")]
assert "CRLocalize(name)" in controller
assert "CRLocalize(footer)" in controller
assert '[row setName:localized]' in controller
assert '[row setProperty:localizedFooter forKey:@"footerText"]' in controller
assert '[self localizeSpecifiers:rootRows];' in controller
assert controller.index('[CRPRootPageSuggestionProvider suggestionSpecifiers]') < (
    controller.index('[self localizeSpecifiers:rootRows];'))
assert controller.index('[self localizeSpecifiers:rootRows];') < (
    controller.index('self.craneAllRootSpecifiers = [rootRows copy];'))
assert controller.count('[self localizeSpecifiers:rootRows];') == 1
assert '- (void)openTwitter\n{' in controller
assert 'CRCreditsOpenTwitter(@"opa334dev");' in controller

actions = {
    row["action"]
    for row in layout["items"]
    if row.get("action")
}
assert actions == {
    "createMultiBackupTapped",
    "restoreMultiBackupTapped",
    "openTwitter"
}
for action in actions:
    assert f'- (void){action}\n{{' in controller, action
for action, address in {
    "createMultiBackupTapped": "0x20E64",
    "restoreMultiBackupTapped": "0x211A8",
    "openTwitter": "0x213CC",
}.items():
    assert methods[action].upper() == address.upper()

# No fake-success return, file write/restore, backup archive creation, or
# indirect provider startup inside the intentionally fail-closed callbacks.
unavailable = controller[controller.index("- (void)presentUnavailableBackupAction:"):
                         controller.index("/* Original 0x2074C")]
assert "No data has been changed" in unavailable
assert 'style:UIAlertActionStyleCancel handler:nil' in unavailable
assert 'CRLocalize(@"CLOSE")' in unavailable
assert '[self presentUnavailableBackupAction:@"CREATE_MULTI_CONTAINER_BACKUP"];' in unavailable
assert '[self presentUnavailableBackupAction:@"RESTORE_MULTI_CONTAINER_BACKUP"];' in unavailable
for dangerous in (
    "configureAndStartMultiBackup",
    "configureAndStartMultiRestore",
    "writeToFile:", "removeItemAtPath:", "createFileAtPath:",
    "didFinishBackupAtPath:",
):
    assert dangerous not in unavailable, dangerous

decompile = repo / "Library/PreferenceBundles/CranePrefs.bundle/CranePrefs_export_for_ai/decompile"
for address, marker in {
    "213CC": 'CFSTR("opa334dev")',
    "16F9C": 'CFSTR("twitter://user?screen_name=%@")',
    "16DA0": 'CFSTR("footerText")',
}.items():
    path = decompile / (address + ".c")
    if path.is_file():
        assert marker in path.read_text(encoding="utf-8"), address

assert "check_root_actions_contract.py" in workflow
print("Crane Root localized labels / safe original action selectors: PASS (device unverified)")
