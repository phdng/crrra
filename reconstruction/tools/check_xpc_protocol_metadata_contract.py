"""Prevent iOS 15 NSXPCInterface crashes from runtime-only protocol types.

The original CraneSB/CraneSupport binaries contain compiler-emitted
_OBJC_PROTOCOL_...CraneAdditions data, while their combined PlusCraneAdditions
protocols are assembled at runtime. objc_allocateProtocol followed by
protocol_addMethodDescription does NOT emit the extended method metadata
NSXPCInterface requires, and causes NSInvalidArgumentException on iOS 15.8.8.

Source-level regression only. Actual Mach-O and device runtime need testing.
"""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
header = (root / "sources/common/CRXPCProtocols.h").read_text(encoding="utf-8")
badge = (root / "sources/cranesb/CRBadgeStore.m").read_text(encoding="utf-8")
lsd = (root / "sources/support/CRLsd.m").read_text(encoding="utf-8")

names = [
    "UNUserNotificationProtocolCraneAdditions",
    "_LSDDeviceIdentifierProtocolCraneAdditions",
]
for name in names:
    assert re.search(r"@protocol\s+" + re.escape(name) + r"\s*\n", header), name
    start = header.index("@protocol " + name)
    body = header[start:header.index("@end", start)]
    assert "protocol_addMethodDescription" not in body

# These method names/arity correspond to the binary's ObjC protocol lists.
notification = header[header.index("@protocol " + names[0]):]
notification = notification[:notification.index("@end")]
for selector in (
    "crane_unregisterFromNotificationsIfNeededForContainerIdentifier:",
    "ofApplicationWithIdentifier:",
    "crane_switchBadgesOfContainerWithIdentifier:",
    "andContainerWithIdentifier:",
    "crane_resetBadgeOfContainerWithIdentifier:",
):
    assert selector in notification, selector
assert notification.count("- (void)") == 3
assert notification.count("(NSString *)") == 7

device = header[header.index("@protocol " + names[1]):]
device = device[:device.index("@end")]
assert "crane_getIdentifier:(void (^)(NSArray *identifiers))reply" in device
assert "crane_setIdentifier:(id)identifier" in device
assert device.count("- (void)") == 2
assert device.count("ofType:(int64_t)type") == 2
assert device.count("forVendorName:(NSString *)vendorName") == 2
assert device.count("andBundleIdentifier:(NSString *)bundleIdentifier") == 2

assert '#import "CRXPCProtocols.h"' in badge
assert '#import "CRXPCProtocols.h"' in lsd

# Force each injection binary to reference the compiler-emitted metadata.
assert 'Protocol *additions = @protocol(UNUserNotificationProtocolCraneAdditions);' in badge
assert 'Protocol *additions = @protocol(_LSDDeviceIdentifierProtocolCraneAdditions);' in lsd
assert 'objc_getProtocol("UNUserNotificationServerProtocol")' in badge
assert 'objc_getProtocol("_LSDDeviceIdentifierProtocol")' in lsd

# A runtime composite is fine because it only adopts precompiled additions
# and the private system base protocol, without creating new method entries.
assert 'objc_allocateProtocol(\n                "UNUserNotificationServerProtocolPlusCraneAdditions")' in badge
assert 'protocol_addProtocol(extended, additions);' in badge
assert 'protocol_addProtocol(extended, base);' in badge
assert 'objc_allocateProtocol("_LSDDeviceIdentifierProtocolPlusCraneAdditions")' in lsd
assert 'protocol_addProtocol(plus, additions);' in lsd
assert 'protocol_addProtocol(plus, base);' in lsd

for source in (badge, lsd):
    assert 'protocol_addMethodDescription(' not in source
    for name in names:
        assert 'objc_allocateProtocol("' + name + '")' not in source
        assert 'objc_allocateProtocol(\n        "' + name + '")' not in source

# The hook continues to forward unmodified protocols except when the exact
# private base protocol is being extended.
assert 'if (base && additions && protocol && protocol_isEqual(protocol, base))' in badge
assert 'original(self, cmd, protocol);' in badge
assert 'original(self, cmd, extended);' in badge
assert 'extended notification XPC interface rejected' in badge
assert '@catch (NSException *exception)' in badge[badge.index('static void CRBadgeXPCSetProtocol('):badge.index('/* CraneSB 0xF19C/')]
assert 'if (base && plus && protocol && protocol_isEqual(protocol, base))' in lsd
assert 'original(self, _cmd, effective);' in lsd
assert 'original(self, _cmd, protocol);' in lsd
assert 'LSD extended XPC interface rejected' in lsd
assert '@catch (NSException *exception)' in lsd[lsd.index('static void CraneLSDSetProtocol('):lsd.index('/* Normal LSD getIdentifier spoof')]

print("Crane Clang XPC protocol metadata contracts: PASS (device runtime unverified)")
