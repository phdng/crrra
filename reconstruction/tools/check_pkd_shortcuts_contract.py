"""F-12/F-22 Crane Shortcuts extension fallback contract.

CraneSupport 0x101CC asks LSApplicationWorkspace for matching plugins and,
ONLY when none exists, matches IntentsSupported + containing CraneApplication
path + com.apple.intents-service, falling back to a specific Shortcuts proxy.

Native code trusts query types and a private class method; this port guards
NSNull/unexpected XPC data and unavailable private APIs so pkd does not crash.
Source and independent model checks only. Does not implement Siri intent
handlers or verify the extension bundle is packaged/installed.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
src = (root / "sources/support/CRPkd.m").read_text(encoding="utf-8")
a = src.index("static NSArray *CRPkdPluginsMatchingQuery(")
b = src.index("static id CRPkdServerInit(", a)
fallback = src[a:b]

assert 'id proxy' in fallback
assert 'NSArray *result = original(self, _cmd, query, applyFilter);' in fallback
assert 'if (result.count != 0)' in fallback
assert 'return result;' in fallback
assert 'if (![query isKindOfClass:NSDictionary.class])' in fallback
for s in (
    'query[@"IntentsSupported"]',
    'query[@"NSExtensionContainingApp"]',
    'query[@"NSExtensionPointName"]',
    '[containingApp isKindOfClass:NSString.class]',
    '[extensionPoint isKindOfClass:NSString.class]',
    '[containingApp containsString:@"/Applications/CraneApplication.app"]',
    '[extensionPoint isEqualToString:@"com.apple.intents-service"]',
    'NSClassFromString(@"LSPlugInKitProxy")',
    '[(id)proxyClass respondsToSelector:@selector(pluginKitProxyForIdentifier:)]',
    'pluginKitProxyForIdentifier:@"com.opa334.CraneApplication.CraneShortcuts"',
    'return proxy ? @[proxy] : result;',
):
    assert s in fallback, s

assert fallback.index('if (result.count != 0)') < fallback.index('query[@"IntentsSupported"]')
assert fallback.index('if (![query isKindOfClass:NSDictionary.class])') < fallback.index('query[@"IntentsSupported"]')
assert fallback.index('[containingApp isKindOfClass:NSString.class]') < fallback.index('[containingApp containsString:')
assert fallback.index('respondsToSelector:@selector(pluginKitProxyForIdentifier:)') < fallback.index('pluginKitProxyForIdentifier:@"com.opa334.CraneApplication.CraneShortcuts"')
assert 'setActiveContainerIdentifier:' not in fallback
assert 'xpc_dictionary_set_' not in fallback

def fallback_query(original, query, proxy_available):
    if original:
        return original
    if not isinstance(query, dict):
        return original
    app = query.get("NSExtensionContainingApp")
    point = query.get("NSExtensionPointName")
    if (query.get("IntentsSupported") is None or
            not isinstance(app, str) or not isinstance(point, str) or
            "/Applications/CraneApplication.app" not in app or
            point != "com.apple.intents-service"):
        return original
    return ["CraneShortcuts"] if proxy_available else original

valid = {
    "IntentsSupported": ["com.opa334.CraneApplication.OpenContainer"],
    "NSExtensionContainingApp": "/Applications/CraneApplication.app",
    "NSExtensionPointName": "com.apple.intents-service",
}
assert fallback_query(["ApplePlugin"], valid, True) == ["ApplePlugin"]
assert fallback_query([], valid, True) == ["CraneShortcuts"]
assert fallback_query([], valid, False) == []
assert fallback_query([], None, True) == []
for bad in (
    {**valid, "IntentsSupported": None},
    {**valid, "NSExtensionContainingApp": None},
    {**valid, "NSExtensionContainingApp": object()},
    {**valid, "NSExtensionPointName": []},
    {**valid, "NSExtensionPointName": "com.apple.usernotifications.service"},
    {**valid, "NSExtensionContainingApp": "/Applications/Other.app"},
):
    assert fallback_query([], bad, True) == []

print("Crane F-12/F-22 Shortcuts discovery guards: PASS (intent handler/device unverified)")
