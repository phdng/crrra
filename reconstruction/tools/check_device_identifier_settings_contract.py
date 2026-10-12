"""F-11 guarded Device Identifier settings subset (CranePrefs 0x10608/F8F0/12F74).

CranePrefs native uses applicationHasDeviceIdentifier: to gate the group.
For non-DEFAULT containers it shows an identifier and defaults
useContainerIdentifierAsDeviceIdentifier to YES. The reconstruction
does not have a trusted implementation of generate/set-custom via the
original helperd/lsd protocol, so mutation is offered ONLY when a
valid custom UUID is already saved and the app is reported supported.

These are source-level and independent model checks, not iOS runtime parity.
"""
from pathlib import Path
from uuid import UUID

root = Path(__file__).resolve().parents[1]
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
lsd = (root / "sources/support/CRLsd.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRPreferences.h").read_text(encoding="utf-8")

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

assert 'GENERATE_NEW' not in group
assert 'SET_CUSTOM' not in group
assert 'generateNewIdentifierButtonPressed' not in detail
assert 'setCustomIdentifierButtonPressed' not in detail
assert 'setDeviceIdentifier:' not in actions, "Do not invoke partial helperd setter"

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
assert actions.index('![[NSUUID alloc] initWithUUIDString:custom]') < actions.index('settings[CRPref_UseContainerIdentifierAsDeviceID] = @(requested);')
assert 'NSUserDefaults' not in actions

mstart = manager.index("- (NSString *)deviceIdentifierToUseForContainerWithIdentifier:")
mend = manager.index("- (void)setDeviceIdentifier:", mstart)
getter = manager[mstart:mend]
for token in (
    'CRManagerSafePathComponent(appID)',
    'CRManagerSafePathComponent(containerID)',
    'id pref = settings[CRPref_UseContainerIdentifierAsDeviceID];',
    'settings[@"customDeviceIdentifier"]',
    'BOOL hasCustomUUID',
    '(!pref || [pref boolValue] || !hasCustomUUID)',
    '![containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]',
    '[[NSUUID alloc] initWithUUIDString:containerID]',
    'return hasCustomUUID ? customValue : nil;',
):
    assert token in getter, token

# Ensure the same preference drives the existing LSD runtime hook.
assert 'settings[CRPref_UseContainerIdentifierAsDeviceID]' in lsd
assert 'useContainerIdentifier = @YES;' in lsd
assert 'selected =' in lsd and 'custom && !useContainerIdentifier.boolValue' in lsd

def valid_uuid(s):
    try:
        return isinstance(s, str) and bool(UUID(s))
    except (TypeError, ValueError, AttributeError):
        return False

def id_to_use(container, custom, pref):
    valid_custom = valid_uuid(custom)
    if (pref is None or pref is True or not valid_custom) and \
            container != "DEFAULT" and valid_uuid(container):
        return container
    return custom if valid_custom else None

container = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
custom = "12345678-ABCD-4BCD-ABCD-123456789ABC"
assert id_to_use(container, custom, None) == container
assert id_to_use(container, custom, True) == container
assert id_to_use(container, custom, False) == custom
assert id_to_use(container, None, False) == container
assert id_to_use(container, "garbage", False) == container
assert id_to_use("DEFAULT", None, None) is None
assert id_to_use("DEFAULT", custom, False) == custom
assert id_to_use("unsafe/child", None, True) is None

def show_group(default, supported, selected):
    return not default and supported and valid_uuid(selected)

assert show_group(False, True, container)
assert not show_group(True, True, container)
assert not show_group(False, False, container)
assert not show_group(False, True, None)
assert valid_uuid(custom)
print("Crane F-11 guarded device ID settings contracts: PASS (native/device unverified)")
