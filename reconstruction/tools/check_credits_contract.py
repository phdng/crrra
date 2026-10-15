"""G-10 original CranePrefs Credits & Licenses source/package contracts.

Recovered controller IMPs 0x146D4..0x14A88, original Credits.plist link
destinations and the two binary license plist assets. The local Library/
exports are optional on CI; the recovered method index and fixed SHA256
fixtures are tracked with the reconstruction.
"""
import hashlib
import json
import plistlib
from pathlib import Path

root = Path(__file__).resolve().parents[1]
layout = root / "layout/Library/PreferenceBundles/CranePrefs.bundle"
source = (root / "sources/prefs/CRCredits.m").read_text(encoding="utf-8")
make = (root / "sources/prefs/Makefile").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")
classes = json.loads((root.parent / "analysis/objc_classes.json").read_text(
    encoding="utf-8"))["CranePrefs"]

assert "CranePrefs_FILES" in make
for compiled_file in ("CRPreferences.m", "CRCredits.m", "CRChoicyEditor.m"):
    assert compiled_file in make, compiled_file
assert "check_credits_contract.py" in workflow
assert '#import "CRCommon.h"' in source
assert "CRCreditsLocalizedRows(self, @\"Credits\", YES)" in source
assert "CRCreditsLocalizedRows(self, @\"MiniZipLicense\", NO)" in source
assert "CRCreditsLocalizedRows(self, @\"ZipArchiveLicense\", NO)" in source
assert 'CRLocalize(@"CREDITS_AND_LICENSES")' in source
assert 'CRLocalize(footer)' in source
assert "setDetailControllerClass:detail" in source
assert 'NSClassFromString(licenseIndex == 0' in source
assert "CRCreditsInstallBacking(self, self.craneCreditsSpecifiers)" in source
assert '@try {' in source and '@catch (NSException *exception)' in source
assert "twitter://user?screen_name=%@" in source
assert "https://twitter.com/%@" in source
assert "https://github.com/ZipArchive/ZipArchive" in source
assert "https://github.com/nmoinvaz/minizip" in source
assert "https://github.com/rdaraujo" in source
# Confirm every social action's original constant destination, not merely
# the existence of a method with the same selector name.
twitter_actions = {
    "trithucLink": "Trithuc16",
    "nvbikLink": "nvbik584",
    "sn0wl3r0kerLink": "Sn0wl3r0ker",
    "nzar1988Link": "nzar1988",
    "bwntyHntrLink": "BwntyHntr",
    "guezomriLink": "guezomri",
    "torrekieLink": "Torrekie",
    "ian_dxxLink": "ian_dxx",
    "Vitalik2187836Link": "Vitalik2187836",
    "frknvkilicLink": "frknvkilic",
    "RedenticDevLink": "RedenticDev",
    "cySxLLink": "CySxL",
}
for method, username in twitter_actions.items():
    assert f'- (void){method} {{ CRCreditsOpenTwitter(@"{username}"); }}' in source, method
assert '- (void)rdaraujoLink' in source and "https://github.com/rdaraujo" in source

methods = {x["sel"]: x["imp"] for x in classes["CRPCreditsController"]["instance_methods"]}
# Original Credits.plist action rows must resolve on the controller.
credits = plistlib.loads((layout / "Credits.plist").read_bytes())
original_actions = {row["action"] for row in credits["items"] if row.get("action")}
for selector in original_actions:
    assert selector in methods, selector
    assert f"- (void){selector}" in source, selector

details = {row["detail"] for row in credits["items"] if row.get("detail")}
assert details == {
    "CRPCreditsZipArchiveController", "CRPCreditsMiniZipController"
}
assert "CRPCreditsController" in {
    row.get("detail") for row in plistlib.loads((layout / "Root.plist").read_bytes())["items"]
}
assert "CRPCreditsMiniZipController" in source
assert "CRPCreditsZipArchiveController" in source

for name, imp in (
    ("CRPCreditsController", "0x146D4"),
    ("CRPCreditsMiniZipController", "0x14A20"),
    ("CRPCreditsZipArchiveController", "0x14A88"),
):
    cls = classes[name]
    assert next(m["imp"] for m in cls["instance_methods"]
                if m["sel"] == "specifiers").upper() == imp.upper()

license_digests = {
    "MiniZipLicense.plist": "876ae96d3d08267425117c36eac5a2733215fc8a4b8536335f4e81cb3c91a3e2",
    "ZipArchiveLicense.plist": "c8cccfbccf9072231ce6e0cbacf352c3f232c44ed075391d7a33c77b3c4afe48",
}
for name, expected_digest in license_digests.items():
    data = (layout / name).read_bytes()
    assert hashlib.sha256(data).hexdigest() == expected_digest, name
    rows = plistlib.loads(data)["items"]
    assert len(rows) == 1 and rows[0]["cell"] == "PSGroupCell"
    assert len(rows[0]["footerText"]) >= 600
    original = root.parent / "Library/PreferenceBundles/CranePrefs.bundle" / name
    if original.is_file():
        assert original.read_bytes() == data, name

# Compare tracked class metadata to any available workstation-only decompile.
native = root.parent / "Library/PreferenceBundles/CranePrefs.bundle/CranePrefs_export_for_ai/decompile"
for address, snippet in {
    "146D4": 'CFSTR("Credits")',
    "147B0": "https://github.com/ZipArchive/ZipArchive",
    "14830": "https://github.com/nmoinvaz/minizip",
    "14978": "https://github.com/rdaraujo",
    "14A20": 'CFSTR("MiniZipLicense")',
    "14A88": 'CFSTR("ZipArchiveLicense")',
}.items():
    path = native / (address + ".c")
    if path.is_file():
        assert snippet in path.read_text(encoding="utf-8"), address

print("Crane G-10 Credits/License native resource contracts: PASS (UI device unverified)")
