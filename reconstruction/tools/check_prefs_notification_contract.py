"""F-15 per-container notification permission UI, native CranePrefs 0x11734.

The native pane conditionally adds NOTIFICATIONS, NOTIFICATIONS_FOOTER,
ALLOW_NOTIFICATIONS with default=1 and key=notificationsAllowed when
global/per-app separation is enabled (missing preferences count as YES).
CraneSB already filters notifications using this key. The native Reset
Notification Registration button remains withheld until libcrane's stub
unregisterFromNotificationsIfNeeded... has an actual implementation.

These are source and independent model checks, not device tests.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRPreferences.h").read_text(encoding="utf-8")
badge = (root / "sources/cranesb/CRBadgeStore.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")

start = prefs.index("@implementation CRPContainerConfigurationListController")
end = prefs.index("/* Minimal APPLICATIONS list for", start)
detail = prefs[start:end]
spec = detail[detail.index("- (id)specifiers\n{"):detail.index("- (void)updateSizeGroupSpecifierAndReload:")]
permission = spec[spec.index("/* Native CranePrefs 0x11734: expose container notification"):
                  spec.index("/* CranePrefs 0x10BD4/0x10E68/0x11734:")]
read = detail[detail.index("- (id)readContainerNotificationsAllowed:"):
              detail.index("/* ChoicyPrefs is optional;")]

assert '#define CRCContainer_NotificationsAllowed          @"notificationsAllowed"' in header
assert 'CRPref_NotificationsSupportEnabled' in permission
assert 'CRAppSetting_SeparateNotificationRegistrationsEnabled' in permission
assert '(!globalNotifications || [globalNotifications boolValue])' in permission
assert '(!separateRegistrations || [separateRegistrations boolValue])' in permission
assert 'CRLocalize(@"NOTIFICATIONS")' in permission
assert 'CRLocalize(@"NOTIFICATIONS_FOOTER")' in permission
assert 'CRLocalize(@"ALLOW_NOTIFICATIONS")' in permission
assert 'get:@selector(readContainerNotificationsAllowed:)' in permission
assert 'set:@selector(setContainerNotificationsAllowed:specifier:)' in permission
assert '[allow setProperty:@YES forKey:@"default"];' in permission
assert '[allow setProperty:CRCContainer_NotificationsAllowed forKey:@"key"];' in permission
assert 'CR_DEFAULT_CONTAINER_IDENTIFIER' not in permission, "Native notification group is not nondefault-only"
assert 'resetNotificationRegistrationButtonPressed' not in permission, "Backend is stub; do not show no-op action"

for token in (
    'isEqualToString:CRCContainer_NotificationsAllowed',
    '- (id)readContainerNotificationsAllowed:(PSSpecifier *)specifier',
    'return allowed ? @([allowed boolValue]) : @YES;',
    '- (void)setContainerNotificationsAllowed:(id)value',
    '![value respondsToSelector:@selector(boolValue)]',
    'if ([settings[CRCContainer_NotificationsAllowed] isEqual:allowed])',
    'settings[CRCContainer_NotificationsAllowed] = allowed;',
    '[manager setContainerSettings:settings',
    'forContainerWithIdentifier:self.containerIdentifier',
    'ofApplicationWithIdentifier:self.applicationIdentifier',
):
    assert token in read, token
assert 'NSUserDefaults' not in read
assert read.index('if ([settings[CRCContainer_NotificationsAllowed] isEqual:allowed])') < read.index('settings[CRCContainer_NotificationsAllowed] = allowed;')
assert read.index('settings[CRCContainer_NotificationsAllowed] = allowed;') < read.index('[manager setContainerSettings:settings')

# The already implemented notification routing must have identical
# unset-means-allowed semantics; otherwise the toggle would misrepresent it.
assert '[settings objectForKey:@"notificationsAllowed"]' in badge
assert 'if (allowed && [allowed respondsToSelector:@selector(boolValue)] &&' in badge
assert '![allowed boolValue])' in badge
assert 'unregisterFromNotificationsIfNeededForContainerIdentifier:(NSString *)containerID' in manager
stub = manager[manager.index('- (void)unregisterFromNotificationsIfNeededForContainerIdentifier:'):
               manager.index('- (void)resetBadgeOfContainerWithIdentifier:', manager.index('- (void)unregisterFromNotificationsIfNeededForContainerIdentifier:'))]
assert 'ofApplicationWithIdentifier:(NSString *)appID {}' in stub

# Independent model of missing/disabled combinations and three-state value.
def show_notification_group(global_enabled, app_enabled):
    return global_enabled is not False and app_enabled is not False

for global_state in (None, True, False):
    for app_state in (None, True, False):
        assert show_notification_group(global_state, app_state) == (
            global_state is not False and app_state is not False
        )
assert show_notification_group(None, None)
assert show_notification_group(True, True)
assert not show_notification_group(False, True)
assert not show_notification_group(True, False)

def allowed_value(persisted):
    return True if persisted is None else bool(persisted)

assert allowed_value(None)
assert allowed_value(True)
assert not allowed_value(False)

print("Crane F-15 per-container notification permission contracts: PASS (device unverified)")
