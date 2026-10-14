"""F-15 notification permission/reset + libcrane UserNotifications bridge.

Native CranePrefs 0x11734 adds ALLOW_NOTIFICATIONS and
RESET_NOTIFICATION_REGISTRATION when global/per-app notification separation is
enabled. Native libcrane 0xF8C8..0xFC80 connects to the UserNotifications
service (or the in-process SpringBoard listener) and forwards three Crane
protocol additions. Static/source contract only.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
prefs = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRPreferences.h").read_text(encoding="utf-8")
xpc_header = (root / "sources/common/CRXPCProtocols.h").read_text(encoding="utf-8")
badge = (root / "sources/cranesb/CRBadgeStore.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")

start = prefs.index("@implementation CRPContainerConfigurationListController")
end = prefs.index("/* Minimal APPLICATIONS list for", start)
detail = prefs[start:end]
spec = detail[detail.index("- (id)specifiers\n{"):detail.index("- (void)updateSizeGroupSpecifierAndReload:")]
permission = spec[
    spec.index("/* Native CranePrefs 0x11734: expose container notification"):
    spec.index("/* CranePrefs 0x10BD4/0x10E68/0x11734:")
]
read = detail[
    detail.index("- (id)readContainerNotificationsAllowed:"):
    detail.index("/* ChoicyPrefs is optional;")
]

assert '#define CRCContainer_NotificationsAllowed          @"notificationsAllowed"' in header
for token in (
    "CRPref_NotificationsSupportEnabled",
    "CRAppSetting_SeparateNotificationRegistrationsEnabled",
    "(!globalNotifications || [globalNotifications boolValue])",
    "(!separateRegistrations || [separateRegistrations boolValue])",
    'CRLocalize(@"NOTIFICATIONS")',
    'CRLocalize(@"NOTIFICATIONS_FOOTER")',
    'CRLocalize(@"ALLOW_NOTIFICATIONS")',
    "get:@selector(readContainerNotificationsAllowed:)",
    "set:@selector(setContainerNotificationsAllowed:specifier:)",
    '[allow setProperty:@YES forKey:@"default"];',
    "[allow setProperty:CRCContainer_NotificationsAllowed",
    'CRLocalize(@"RESET_NOTIFICATION_REGISTRATION")',
    "[reset setButtonAction:@selector(resetNotificationRegistrationButtonPressed)]",
):
    assert token in permission, token

for token in (
    "- (id)readContainerNotificationsAllowed:(PSSpecifier *)specifier",
    "return allowed ? @([allowed boolValue]) : @YES;",
    "- (void)setContainerNotificationsAllowed:(id)value",
    "settings[CRCContainer_NotificationsAllowed] = allowed;",
    "[manager setContainerSettings:settings",
    "- (void)resetNotificationRegistrationButtonPressed",
    "unregisterFromNotificationsIfNeededForContainerIdentifier:",
    "self.containerIdentifier",
    "ofApplicationWithIdentifier:self.applicationIdentifier",
):
    assert token in read, token

assert '[settings objectForKey:@"notificationsAllowed"]' in badge
assert "![allowed boolValue])" in badge

for token in (
    "@protocol UNUserNotificationProtocolCraneAdditions",
    "crane_unregisterFromNotificationsIfNeededForContainerIdentifier:",
    "crane_switchBadgesOfContainerWithIdentifier:",
    "crane_resetBadgeOfContainerWithIdentifier:",
):
    assert token in xpc_header, token

for token in (
    "CRUserNotificationsExtendedProtocol",
    '"UNUserNotificationServerProtocol"',
    '"UNUserNotificationServerProtocolPlusCraneAdditions"',
    'NSClassFromString(@"UNSUserNotificationServer")',
    '@"com.apple.usernotifications.usernotificationservice"',
    "synchronousRemoteObjectProxyWithErrorHandler:",
    '@"_userNotificationServerConnectionListener"',
    "- (void)unregisterFromNotificationsIfNeededForContainerIdentifier:",
    "- (void)resetBadgeOfContainerWithIdentifier:",
    "- (void)switchBadgesOfContainerWithIdentifier:",
    "crane_unregisterFromNotificationsIfNeededForContainerIdentifier:",
    "crane_resetBadgeOfContainerWithIdentifier:",
    "crane_switchBadgesOfContainerWithIdentifier:",
):
    assert token in manager, token

for stub in (
    "ofApplicationWithIdentifier:(NSString *)appID {}",
    "andContainerWithIdentifier:(NSString *)otherContainerID\n                   ofApplicationWithIdentifier:(NSString *)appID {}",
):
    assert stub not in manager

def show_notification_group(global_enabled, app_enabled):
    return global_enabled is not False and app_enabled is not False

for global_state in (None, True, False):
    for app_state in (None, True, False):
        assert show_notification_group(global_state, app_state) == (
            global_state is not False and app_state is not False
        )

def allowed_value(persisted):
    return True if persisted is None else bool(persisted)

assert allowed_value(None)
assert allowed_value(True)
assert not allowed_value(False)

print("Crane F-15 notification permission/reset contracts: PASS (device unverified)")
