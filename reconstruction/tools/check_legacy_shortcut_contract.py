"""Legacy CraneSB iOS 11/12 Force Touch shortcut contracts.

Export evidence: 0x14D18 (private hooks), 0x151E4, 0x1555C,
0x16A90, 0x170A4, 0x18A3C, 0x18B4C, 0x18CFC,
0x18D08, 0x18E84, 0x18F04 and 0x19000.
These are source-shape/model checks, NOT SpringBoard runtime tests.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
menu = (root / "sources/cranesb/CRMenuHooks.m").read_text(encoding="utf-8")
alerts = (root / "sources/cranesb/CRErrorAlerts.m").read_text(encoding="utf-8")

def section(start: str, end: str) -> str:
    return menu[menu.index(start):menu.index(end, menu.index(start))]

items = section(
    "static NSArray *CRLegacyApplicationShortcutItems(id self, SEL _cmd)\n{",
    "static void CRInitLegacyApplicationShortcutHooks(void)")
assert 'if (containers.count <= 1 &&' in items
assert 'CRPrefBool(CRPref_OnlyShowIfContainersExist)' in items
assert 'if (CRPrefBool(CRPref_ExpandContainersShortcut)) {' in items
assert 'if (!existing)\n            return craneItems;' in items
assert 'if (!existing.count)' not in items
assert 'NSMutableArray *combined = [existing mutableCopy];' in items
assert 'if (separator)\n            [combined addObject:separator];' in items
assert '[combined addObjectsFromArray:craneItems];' in items
assert 'return existing ? [existing arrayByAddingObject:parent] : @[parent];' in items

# Native 0x170A4: nil original list receives Crane items unchanged,
# while an existing NSArray -- including [] -- gains a separator.
def expanded_items(existing, crane):
    if existing is None:
        return list(crane)
    return list(existing) + ["separator"] + list(crane)

assert expanded_items(None, ["container"]) == ["container"]
assert expanded_items([], ["container"]) == ["separator", "container"]
assert expanded_items(["system"], ["container"]) == [
    "system", "separator", "container"
]
assert expanded_items([], []) == ["separator"]

container_items = section(
    "static NSArray *CRLegacyContainerShortcutItems(id self)\n{",
    "static NSArray *CRLegacyContainerShortcutItemsMethod")
assert 'CRShouldShowContainerBadges(appID, settings, manager)' in container_items
assert '[NSString stringWithFormat:@"⬤ %d", (int)count]' in container_items
assert '[NSString stringWithFormat:@"%d ⬤", (int)count]' in container_items
assert 'kLegacyContainerTypePrefix' in container_items
assert 'kLegacyNewContainerType' in container_items
assert 'kLegacyPreferencesType' in container_items

# 0x18A3C/0x18B4C: dismiss original menu, reconfigure with gesture,
# suppress the nested dismissal, then clear the suppression on completion
# (0x18CFC). Failure to offer private present selector must also clear it.
expand = section(
    "static void CRLegacyExpandContainerOptions(id shortcutController)\n{",
    "static void CRLegacyHandleContainerSelection")
for fragment in (
    "CRLegacyDismissShortcutController(shortcutController, ^{",
    '@"_dataProvider"', # present via KVC helper
    '@"_setupWithGestureRecognizer:"',
    "gCRPreventDismissingForceTouchMenu = YES;",
    '@"_peekAnimated:withRelativeTouchForce:allowSmoothing:"',
    '@"_presentAnimated:withCompletionHandler:"',
    "gCRPreventDismissingForceTouchMenu = NO;",
):
    assert fragment in expand, fragment
assert 'if (gCRPreventDismissingForceTouchMenu)\n        return;' in menu

selection = section(
    "static void CRLegacyHandleContainerSelection(id shortcutController,",
    "static void CRLegacyDismissHook")
assert 'if ([containerID isEqualToString:activeContainerID]) {' in selection
assert 'CRLegacyDismissShortcutController(shortcutController, nil);' in selection
assert 'usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated)' in selection
assert 'CRLegacyActivateShortcutItem(shortcutController, shortcutItem)' in selection

# Original 0x1555C creates the actions and overrides the handlers.
action = section(
    "static id CRLegacyActionFromShortcutItem(id self,",
    "static id CRLegacyNewShortcutItem(")
for fragment in (
    'NSSelectorFromString(@"type")',
    "CRLegacyTemplateIcon(@\"ContainersIcon\")",
    "CRLegacyTemplateIcon(@\"SelectedContainerCheckmark\")",
    "CRLegacyBlankIcon()",
    "CRLegacyTemplateIcon(@\"AddIcon\")",
    "CRLegacyTemplateIcon(@\"SettingsIcon\")",
    "CRLegacyExpandContainerOptions(self);",
    "CRLegacyHandleContainerSelection(",
    "CRPresentNewContainerAlert(appID);",
    "CROpenCraneSettings(appID);",
    'NSSelectorFromString(@"setCrane_isSeparator:")',
):
    assert fragment in action, fragment

# Native 0x12720 serves both 0x14484 and 0x19068 settings actions.
# Nil appID keeps an empty path, while a non-nil empty appID retains
# APPLICATIONS/; Shuffle keeps the percent-escaped configured group even
# when the suite preference is the empty string.
settings = section(
    'static void CROpenCraneSettings(NSString *appID)\n{',
    'static NSInteger CRStoredContainerBadgeCount(')
assert 'NSString *path = appID\n' in settings
assert '? [NSString stringWithFormat:@"APPLICATIONS/%@", appID]\n        : @"";' in settings
assert 'if (!group)\n                group = @"Tweaks";' in settings
assert '[group stringByAddingPercentEscapesUsingEncoding:' in settings
assert 'NSUTF8StringEncoding];' in settings
assert 'settingsPath = [NSString stringWithFormat:@"Crane/%@", path];' in settings
assert '@"prefs:root=%@&path=%@", root, settingsPath' in settings
assert 'if (!group.length)' not in settings
assert 'NSCharacterSet.URLQueryAllowedCharacterSet' not in settings

def _native_settings_parts(app_id, shuffle=False, group=None):
    path = f"APPLICATIONS/{app_id}" if app_id is not None else ""
    if shuffle:
        return ("Tweaks" if group is None else group, f"Crane/{path}")
    return ("Crane", path)

assert _native_settings_parts(None) == ("Crane", "")
assert _native_settings_parts("") == ("Crane", "APPLICATIONS/")
assert _native_settings_parts("com.example.app") == ("Crane", "APPLICATIONS/com.example.app")
assert _native_settings_parts(None, True) == ("Tweaks", "Crane/")
assert _native_settings_parts("com.example.app", True, "") == ("", "Crane/APPLICATIONS/com.example.app")

# 0x18F04 / 0x19000 and 0x1448C: dismiss then present the
# CRNewContainerAlert using a single async activation on main queue.
# The presenter itself schedules activation; do not queue it twice.
new_container = action[action.index('if ([type isEqualToString:kLegacyNewContainerType])'):action.index('if ([type isEqualToString:kLegacyPreferencesType])')]
assert 'CRLegacyDismissShortcutController(self, nil);' in new_container
assert 'CRPresentNewContainerAlert(appID);' in new_container
assert 'dispatch_async(dispatch_get_main_queue()' not in new_container
presenter = alerts[alerts.index('void CRPresentNewContainerAlert(NSString *appID)'):alerts.index('static UIAlertAction *CRCloseAction')]
assert 'SEL setter = NSSelectorFromString(@"setApplicationID:");' in presenter
assert 'if (!alert || ![alert respondsToSelector:setter])' in presenter
assert '((void (*)(id, SEL, id))objc_msgSend)(alert, setter, appID);' in presenter
assert '[alert setValue:appID forKey:@"applicationID"];' not in presenter
assert 'CRActivateErrorAlert(alert);' in presenter
activate = alerts[alerts.index('static void CRActivateErrorAlert(id alert)'):alerts.index('void CRPresentNewContainerAlert(NSString *appID)')]
assert 'dispatch_async(dispatch_get_main_queue(), ^{' in activate

print("Crane iOS 11/12 legacy shortcut static contracts: PASS (runtime unverified)")
