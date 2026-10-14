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

print("Crane G-07 Game Center original account schema contracts: PASS (runtime unverified)")
