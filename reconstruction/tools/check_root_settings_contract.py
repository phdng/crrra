"""Native CranePrefs 0x2074C, 0x20828, 0x20BCC Root preferences.

Verify source recovery plus actual Foundation projection smoke in macOS CI.
This intentionally does NOT certify the separate notifications side effects
of original 0x20DE8/0x2220C (unregister/reload, device pending).
"""
from pathlib import Path
import plistlib
import json

root = Path(__file__).resolve().parents[1]
source = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRRootSettingsProjection.h").read_text(encoding="utf-8")
smoke = (root / "tools/root_settings_projection_smoke.m").read_text(encoding="utf-8")
flow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")
native = json.loads((root.parent / "analysis/objc_classes.json").read_text(
    encoding="utf-8"))["CranePrefs"]["CRPRootListController"]["instance_methods"]
methods = {m["sel"]: m["imp"] for m in native}
for selector, addr in {
    "readPreferenceValue:": "0x2074C",
    "removeDisabledGroups:": "0x20828",
    "setPreferenceValue:specifier:": "0x20BCC",
    "setNotificationsSupportEnabled:specifier:": "0x20DE8",
}.items():
    assert methods[selector].upper() == addr.upper()

root_controller = source[source.index("@implementation CRPRootListController"):
                         source.index("/* The original CRPActiveContainerListItemsController")]

for needle in (
    '#import "CRRootSettingsProjection.h"',
    "craneAllRootSpecifiers",
    "self.craneAllRootSpecifiers = [rootRows copy];",
    "if (!self.craneAllRootSpecifiers)",
    "CRRootVisibleNestedItems(",
    'propertyForKey:@"nestedEntryCount"',
    "[[self readPreferenceValue:item] boolValue]",
    'preferenceValueForKey:key',
    'stored ?: [specifier propertyForKey:@"default"]',
    "setPreferenceValue:@(enabled) forKey:key",
    "CRPref_AppShortcutEnabled",
    "CRPref_NotificationsSupportEnabled",
    "if (enabled == oldEnabled)",
    "- (void)scheduleRootSettingsReload",
    "dispatch_async(dispatch_get_main_queue()",
    "self.craneRootSpecifiers = nil;",
    "[self reloadSpecifiers]",
):
    assert needle in source, needle
assert "self.craneAllRootSpecifiers = [rootRows copy];" in root_controller
assert root_controller.index("self.craneAllRootSpecifiers = [rootRows copy];") < (
    root_controller.index("CRRootVisibleNestedItems("))
assert root_controller.index("setPreferenceValue:@(enabled) forKey:key") < (
    root_controller.index("[self scheduleRootSettingsReload]"))
root_write = root_controller[root_controller.index("- (void)setPreferenceValue:(id)value"):
                             root_controller.index("- (void)scheduleRootSettingsReload")]
assert "[CraneManager.sharedManager setPreferenceValue:@(enabled) forKey:key]" in root_write
assert "if (enabled == oldEnabled)" in root_write
assert "if ([specifier propertyForKey:@\"nestedEntryCount\"])" in root_write
assert "removeItemAtPath:" not in root_write
assert "reloadApplicationWithIdentifier:" not in root_write

# Root source and actual production projector: never lose the five shortcut
# dependents or the notification title row when a parent is toggled.
rows = plistlib.loads((root / "layout/Library/PreferenceBundles/CranePrefs.bundle/Root.plist").read_bytes())["items"]
nested = [(i, item["key"], item["nestedEntryCount"]) for i, item in enumerate(rows)
          if "nestedEntryCount" in item]
assert nested == [(2, "applicationShortcutEnabled", 5),
                  (9, "notificationsSupportEnabled", 1)]
assert "CRRootVisibleNestedItems(" in header
assert "if (nested <= 0 || (NSUInteger)nested > remaining)" in header
assert "index += (NSUInteger)nested;" in header
for scenario in (
    '@"applicationShortcutEnabled": @NO',
    '@"notificationsSupportEnabled": @NO',
    '@"parent": @NO',
    '@"inner": @YES',
    '@"badTooLong"',
):
    assert scenario in smoke, scenario
assert "tools/root_settings_projection_smoke.m" in flow
# C assert(x) treats commas inside Objective-C @[] as extra macro args unless
# the entire expression is protected by an extra pair of parentheses.
assert smoke.count("assert(([Keys(Visible(") == 6
assert "assert([Keys(Visible(nested," not in smoke
assert "check_root_settings_contract.py" in flow

# Original 0x2220C performs application reload + registration reset, which
# cannot be treated as simply a switch write without real device verification.
notification_handler = root_controller[root_controller.index(
    "- (void)setNotificationsSupportEnabled:"):root_controller.index(
    "/* Native 0x1FE80")]
assert "[self setPreferenceValue:value specifier:specifier]" in notification_handler
assert "unregisterFromNotificationsIfNeededForContainerIdentifier" not in notification_handler
print("Crane G-10 Root nested preference projection: PASS (UI device unverified)")
