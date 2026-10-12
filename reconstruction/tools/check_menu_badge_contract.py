"""CraneSB F-14 native context-menu badge contract (source-level only).

References: recovered CraneSB 0x137FC, 0x16A90, 0x1C064, 0x7F58,
0x7E80/0x7E8C/0x8438/0x8444/0x84A0, 0x8530 and 0x8ED4.
Does not replace native Theos compilation or iPhone UI tests.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
menu = (root / "sources/cranesb/CRMenuHooks.m").read_text(encoding="utf-8")
action = (root / "sources/cranesb/CRBadgeAction.m").read_text(encoding="utf-8")

# The original 0x137FC chooses CRBadgeAction only for positive counts
# with redirection and badge presentation enabled; use its six-arg factory.
assert 'if (showBadges)' in menu
assert 'if (count > 0 && [badgeClass respondsToSelector:factorySEL])' in menu
assert 'actionWithTitle:badgeText:image:identifier:associatedApplicationIdentifier:handler:' in menu
assert 'badgeClass, factorySEL, title ?: containerID, badgeText,' in menu
assert 'NSString *badgeText = [NSString stringWithFormat:@"%d", (int)count];' in menu
assert 'if (!action)' in menu and '[UIAction actionWithTitle:title ?: containerID' in menu
assert 'actionWithTitle:(NSString *)title' in action
assert 'object_setClass(action, self);' in action

# The original 0x16A90 puts the dot before the count in RTL, after in LTR.
assert 'UIUserInterfaceLayoutDirectionRightToLeft' in menu
assert '[NSString stringWithFormat:@"⬤ %d", (int)count]' in menu
assert '[NSString stringWithFormat:@"%d ⬤", (int)count]' in menu

# Recover the original fake-icon badge producer only when private APIs exist.
assert 'static Class CRMenuFakeIconClass(void)' in menu
assert 'NSClassFromString(@"SBApplicationIcon")' in menu
assert 'objc_allocateClassPair(baseClass, "CRFakeIcon", 0)' in menu
for selector in ('text', 'setText:', 'accessoryTextForLocation:',
                 'applicationBundleID', 'valueForUndefinedKey:'):
    assert selector in menu
assert '[key isEqualToString:@"_application"]' in menu
assert 'id application = CRDynamicValueForKey(self, @"_application");' in menu
assert 'gCRMenuFakeIconUndefinedKeyOriginal = method_getImplementation(inherited);' in menu
assert 'NSClassFromString(@"SBIconBadgeView")' in menu
assert 'NSClassFromString(@"SBApplicationController")' in menu
assert 'applicationWithBundleIdentifier:' in menu
assert 'configureForIcon:infoProvider:' in menu
assert 'if (!application)' in menu
assert 'if (![badge isKindOfClass:[UIView class]])' in menu

# A missing/throwing private selector retains the lightweight label fallback;
# a reused view must not show a badge belonging to the previous UIAction.
assert 'static UIView *CRMenuCreateNativeBadgeView(' in menu
assert 'static void CRApplyBadgeToActionView(id actionView, id element)' in menu
assert 'CRApplyBadgeToActionView(actionView, element);' in menu
assert 'CRApplyBadgeToActionView(customView, element);' in menu
assert 'if (isBadge) {\n            if (![customView isKindOfClass:[UIView class]]) {' in menu
assert 'SEL initSEL = NSSelectorFromString(@"initWithTitle:subtitle:image:");' in menu
assert 'id configured = ((id (*)(id, SEL, id, id, id))objc_msgSend)(' in menu
assert '[interfaceAction setValue:configured' in menu
assert 'customView = CRDynamicObjectGetter(interfaceAction,' in menu
assert 'CRApplyBadgeToActionView(customView, element);\n            return;' in menu
assert 'if (![badgeText isKindOfClass:[NSString class]] || !badgeText.length)' in menu
assert 'objc_setAssociatedObject(view, &kCRMenuNativeBadgeViewKey,' in menu
assert 'if (native && native.superview == view &&' in menu
assert '[previousText isEqualToString:badgeText]' in menu
assert '[native removeFromSuperview];' in menu
assert 'UIView *replacement = CRMenuCreateNativeBadgeView(appID, badgeText);' in menu
assert '[NSLayoutConstraint activateConstraints:@[' in menu
assert 'if (replacement)' in menu
# Native 0x8778 reserves badge intrinsic width + 5pt by shifting either
# trailingView.centerX or labelStackView.trailing relative to view.trailing.
# The reconstruction must restore that baseline when UIKit reuses a view.
assert 'static void CRMenuRestoreBadgeSpacing(UIView *view)' in menu
assert 'static void CRMenuReserveBadgeSpacing(UIView *view, CGFloat width)' in menu
assert 'CRMenuRestoreBadgeSpacing(view);' in menu
assert 'NSSelectorFromString(@"trailingView")' in menu
assert 'NSSelectorFromString(@"labelStackView")' in menu
assert 'NSSelectorFromString(@"imageView")' in menu
assert 'NSSelectorFromString(@"iconImageView")' in menu
assert 'constraint.firstAnchor' in menu and 'constraint.secondAnchor' in menu
assert 'constraint.constant = baseline - (width + 5.0);' in menu
assert 'adjusted.constant = [baseline doubleValue];' in menu
assert 'CGFloat badgeWidth = replacement ? replacement.intrinsicContentSize.width : 0.0;' in menu
assert 'if (!(badgeWidth > 0.0 && badgeWidth < 300.0))' in menu
assert '[replacement.widthAnchor constraintEqualToConstant:badgeWidth]' in menu
assert 'CRMenuReserveBadgeSpacing(view, badgeWidth);' in menu
assert 'MAX(20.0, label.intrinsicContentSize.width + 10.0)' in menu
assert 'if (!label)' in menu and 'label.text = badgeText;' in menu
assert 'object_setClass(actionView' not in menu
assert 'object_setClass(view,' not in menu

print("Crane modern/legacy badge menu static contracts: PASS (runtime unverified)")
