"""F-15 Preferences.app interactive Game Center settings contract.

Native CranePrefs export 0xA4B8: setSeparateSystemAccountsValue:specifier:
persist the setting; add/remove cached Game Center specifier immediately
after the switch; reload app only when active container != DEFAULT.
Static shape + independent state model, device UI unverified.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "sources/prefs/CRPreferences.m").read_text(encoding="utf-8")
start = source.index("- (void)setSeparateSystemAccountsValue:(id)value specifier:(id)specifier\n{")
end = source.index("- (void)setGameCenterSupportValue:", start)
fn = source[start:end]
assert "- (void)insertSpecifier:(id)specifier afterSpecifier:(id)after animated:(BOOL)animated;" in source
assert "- (void)removeSpecifier:(id)specifier animated:(BOOL)animated;" in source
assert "[self setPreferenceValue:value specifier:specifier];" in fn
assert "PSSpecifier *gameCenter = self.gameCenterSupportEnabledSpecifier;" in fn
assert "BOOL visible = [current containsObject:gameCenter];" in fn
assert "BOOL shouldShow = [value boolValue];" in fn
assert "if (shouldShow && !visible &&" in fn
assert "[self insertSpecifier:gameCenter afterSpecifier:specifier animated:YES];" in fn
assert "if (index != NSNotFound)" in fn
assert "[updated insertObject:gameCenter atIndex:index + 1];" in fn
assert "else if (!shouldShow && visible &&" in fn
assert "[self removeSpecifier:gameCenter animated:YES];" in fn
assert "[updated removeObject:gameCenter];" in fn
assert fn.count("self.craneConfigurationSpecifiers = [updated copy];") == 2
assert "activeContainerIdentifierForApplicationWithIdentifier:" in fn
assert "if (![active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])" in fn
assert "[manager reloadApplicationWithIdentifier:self.applicationIdentifier];" in fn
assert fn.index("[self setPreferenceValue:value specifier:specifier];") < fn.index("if (shouldShow && !visible")
assert fn.index("if (shouldShow && !visible") < fn.index("if (![active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])")

def toggle(rows, enabled):
    rows = list(rows)
    has = "game" in rows
    if enabled and not has:
        rows.insert(rows.index("accounts") + 1, "game")
    elif not enabled and has:
        rows.remove("game")
    return rows

base = ["accounts", "protection"]
enabled = toggle(base, True)
assert enabled == ["accounts", "game", "protection"]
assert toggle(enabled, True) == enabled
assert toggle(enabled, False) == base
assert toggle(base, False) == base
assert toggle(toggle(base, True), False) == base
assert all(active != "DEFAULT" for active in ("C1", "", None))
assert not ("DEFAULT" != "DEFAULT")
# Native 0xA670: every change sends a Game Center reload request;
# disabling also reloads the affected application. The actual global Game
# Center manager implementation is still a stub tracked by F-10.
begin = source.index("- (void)setGameCenterSupportValue:(id)value specifier:(id)specifier\n{")
finish = source.index("- (void)setActiveContainer:", begin)
support = source[begin:finish]
assert "[self setPreferenceValue:value specifier:specifier];" in support
assert "[manager gameCenter_reloadExceptApplicationWithIdentifier:nil];" in support
assert "if (![value boolValue])" in support
assert "[manager reloadApplicationWithIdentifier:self.applicationIdentifier];" in support
assert support.index("[self setPreferenceValue:") < support.index("[manager gameCenter_reloadExceptApplicationWithIdentifier:nil]")
assert support.index("[manager gameCenter_reloadExceptApplicationWithIdentifier:nil]") < support.index("if (![value boolValue])")
print("Crane F-15 Game Center specifier lifecycle contracts: PASS (runtime unverified)")
