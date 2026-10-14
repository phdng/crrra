"""F-11 Device Identifier contracts.

Original cranehelperd 0x100006040/0x10000627C resolves
_LSDDeviceIdentifierService, obtains a synchronous XPC proxy, then invokes the
CraneSupport-added crane_getIdentifier:/crane_setIdentifier: methods using the
LSApplicationProxy vendorName and type 0. The reconstruction now carries that
backend through its authenticated helper transport. The current Preferences UI
still exposes only the guarded existing-value subset; generation/custom editor
parity is tracked separately.

Static/source checks only; native/device parity is still required.
"""
from pathlib import Path
from uuid import UUID

root = Path(__file__).resolve().parents[1]
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
helper = (root / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
lsd = (root / "sources/support/CRLsd.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRPreferences.h").read_text(encoding="utf-8")
manager_header = (root / "sources/common/CRManager.h").read_text(encoding="utf-8")

detail = prefs[prefs.index("@implementation CRPContainerConfigurationListController"):
               prefs.index("/* Minimal APPLICATIONS list for")]
start = detail.index("- (id)specifiers\n{")
end = detail.index("- (void)updateSizeGroupSpecifierAndReload:", start)
spec = detail[start:end]
group = spec[spec.index("/* CranePrefs 0x12EE8/0x10608/0xF8F0/0x12F74"):
             spec.index("/* Native CranePrefs 0x11734: expose container notification")]
actions = detail[detail.index("/* Device-ID editor subset from CranePrefs"):
                 detail.index("/* Native 0x11734 sets default=1")]

assert '#define CRPref_UseContainerIdentifierAsDeviceID' in header
for token in (
    '[manager applicationHasDeviceIdentifier:self.applicationIdentifier]',
    '![self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    'deviceIdentifierToUseForContainerWithIdentifier:self.containerIdentifier',
    '[[NSUUID alloc] initWithUUIDString:selected]',
    'CRLocalize(@"DEVICE_IDENTIFIER_FOR_VENDOR")',
    'CRLocalize(@"USE_CONTAINER_IDENTIFIER")',
    '[custom isKindOfClass:NSString.class]',
    '[[NSUUID alloc] initWithUUIDString:custom]',
    'get:@selector(readUseContainerIdentifierAsDeviceIdentifier:)',
    'set:@selector(setUseContainerIdentifierAsDeviceIdentifier:specifier:)',
    '[useContainer setProperty:@YES forKey:@"default"];',
    '[useContainer setProperty:CRPref_UseContainerIdentifierAsDeviceID',
):
    assert token in group, token

# UI editor/generator parity has not been enabled merely because the backend
# now exists. Keep the current guarded switch surface stable until device test.
assert 'GENERATE_NEW' not in group
assert 'SET_CUSTOM' not in group
assert 'generateNewIdentifierButtonPressed' not in detail
assert 'setCustomIdentifierButtonPressed' not in detail

for token in (
    'readUseContainerIdentifierAsDeviceIdentifier:(PSSpecifier *)specifier',
    'return use ? @([use boolValue]) : @YES;',
    'setUseContainerIdentifierAsDeviceIdentifier:(id)value',
    '![value respondsToSelector:@selector(boolValue)]',
    '[self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    '![manager applicationHasDeviceIdentifier:self.applicationIdentifier]',
    '![custom isKindOfClass:NSString.class]',
    '![[NSUUID alloc] initWithUUIDString:custom]',
    'BOOL previous = !old || [old boolValue];',
    'if (previous == requested)',
    'settings[CRPref_UseContainerIdentifierAsDeviceID] = @(requested);',
    '[manager setContainerSettings:settings',
):
    assert token in actions, token
assert 'NSUserDefaults' not in actions

# Original helper-to-LSD chain.
for token in (
    'NSClassFromString(@"_LSDDeviceIdentifierService")',
    'synchronousXPCProxyWithErrorHandler:',
    'crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:',
    'crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:',
    'NSSelectorFromString(@"vendorName")',
    'CRApplicationProxyForIdentifier(appID)',
):
    assert token in helper, token
assert '"read_device_vendor_identifier"' in helper
assert '"write_device_vendor_identifier"' in helper
assert '[[NSUUID alloc] initWithUUIDString:identifierString]' in helper

# LSD independently authenticates the original helper executable before cache
# access; the raw helper transport is therefore not the sole trust boundary.
assert 'CraneLSDCallerIsHelperd' in lsd
assert 'CRJailbreakRootPath(CR_HELPERD_BIN)' in lsd
assert 'proc_pidpath(pid, buffer, sizeof(buffer))' in lsd
assert 'if (!CraneLSDCallerIsHelperd(self))' in lsd
assert 'if (!identifier || !CraneLSDCallerIsHelperd(self))' in lsd

# Manager reads DEFAULT from the real LSD cache; non-default still follows the
# original per-container selected/custom UUID semantics.
assert '- (BOOL)setDeviceIdentifier:(NSString *)identifier' in manager_header
mstart = manager.index("- (NSString *)deviceIdentifierToUseForContainerWithIdentifier:")
mend = manager.index("- (BOOL)setDeviceIdentifier:", mstart)
getter = manager[mstart:mend]
for token in (
    'CRManagerSafePathComponent(appID)',
    'CRManagerSafePathComponent(containerID)',
    '[containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    'readDeviceVendorIdentifierFromApplicationWithIdentifier:appID',
    'id pref = settings[CRPref_UseContainerIdentifierAsDeviceID];',
    'settings[@"customDeviceIdentifier"]',
    'BOOL hasCustomUUID',
    '(!pref || [pref boolValue] || !hasCustomUUID)',
    '[[NSUUID alloc] initWithUUIDString:containerID]',
    'return hasCustomUUID ? customValue : nil;',
):
    assert token in getter, token

has_start = manager.index("- (BOOL)applicationHasDeviceIdentifier:")
has_end = manager.index("- (NSString *)deviceIdentifierToUseForContainerWithIdentifier:", has_start)
has_body = manager[has_start:has_end]
assert 'readDeviceVendorIdentifierFromApplicationWithIdentifier:appID' in has_body
assert 'crane_deviceIdentifier.' not in has_body

set_start = manager.index("- (BOOL)setDeviceIdentifier:")
set_end = manager.index("/* ---- process control", set_start)
setter = manager[set_start:set_end]
assert '[[NSUUID alloc] initWithUUIDString:identifier]' in setter
assert '[containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]' in setter
assert 'writeDeviceVendorIdentifier:identifier' in setter
assert 'readDeviceVendorIdentifierFromApplicationWithIdentifier:appID' in setter
assert '[requestedUUID isEqual:writtenUUID]' in setter
assert 'settings[@"customDeviceIdentifier"] = identifier;' in setter
assert 'crane_deviceIdentifier.' not in setter

# Same per-container preference drives the runtime LSD spoof.
assert 'settings[CRPref_UseContainerIdentifierAsDeviceID]' in lsd
assert 'useContainerIdentifier = @YES;' in lsd
assert 'selected =' in lsd and 'custom && !useContainerIdentifier.boolValue' in lsd


def valid_uuid(s):
    try:
        return isinstance(s, str) and bool(UUID(s))
    except (TypeError, ValueError, AttributeError):
        return False


def nondefault_id_to_use(container, custom, pref):
    valid_custom = valid_uuid(custom)
    if (pref is None or pref is True or not valid_custom) and valid_uuid(container):
        return container
    return custom if valid_custom else None


container = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
custom = "12345678-ABCD-4BCD-ABCD-123456789ABC"
assert nondefault_id_to_use(container, custom, None) == container
assert nondefault_id_to_use(container, custom, True) == container
assert nondefault_id_to_use(container, custom, False) == custom
assert nondefault_id_to_use(container, None, False) == container
assert nondefault_id_to_use(container, "garbage", False) == container
assert valid_uuid(custom)

print("Crane F-11 helper/LSD device ID contracts: PASS (native/device unverified)")
