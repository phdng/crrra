"""F-12 PlugInKit reload and bounded termination contracts.

CraneSupport original 0xEC44 filters notification-service extensions
before terminating other extensions. The original/reconstructed reverse
enumeration mutated its own NSMutableArray and could raise
NSGenericException. Original 0xE888 waits FOREVER for older PKDServer
termination replies, which can hang pkd. Source port keeps filtering and
callback ABI, but avoids in-loop mutation and bounds the wait.

Static checks and independent behavior models only; test with actual pkd
and both modern/legacy PKDServer selectors on iOS before accepting parity.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "sources/support/CRPkd.m").read_text(encoding="utf-8")

term_start = source.index("static void CRPkdTerminatePlugIns(")
term_end = source.index("/* crane_updateActiveContainerID:", term_start)
terminate = source[term_start:term_end]

reload_start = source.index("static void CRPkdReloadApplication(")
reload_end = source.index("typedef void (^CRPkdEnableContinuation)", reload_start)
reload = source[reload_start:reload_end]

for token in (
    'NSClassFromString(@"PKDServer")',
    'terminatePlugIns:synchronously:reply:',
    'terminatePlugIns:reply:',
    'dispatch_semaphore_create(0)',
    'dispatch_semaphore_signal(semaphore)',
    'dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)',
    'dispatch_semaphore_wait(',
    'if (waitResult != 0)',
):
    assert token in source, token

assert 'DISPATCH_TIME_FOREVER' not in terminate
assert 'terminatePlugIns:proxies reply:^{' in terminate
assert terminate.index('dispatch_semaphore_signal(semaphore)') < terminate.index('dispatch_semaphore_wait(')
assert 'CRPkdTerminatePlugIns(@[self], YES);' in source
assert 'setCrane_activeContainerID:requested' in source

for token in (
    'info[@"applicationIdentifier"]',
    'NSClassFromString(@"LSApplicationProxy")',
    '[application plugInKitPlugins]',
    'if (![plugIns isKindOfClass:NSArray.class])',
    '[NSMutableArray arrayWithCapacity:plugIns.count]',
    'for (id plugIn in plugIns)',
    'pluginKitDictionary][@"NSExtensionPointIdentifier"]',
    '@"com.apple.usernotifications.service"',
    '[toTerminate addObject:plugIn]',
    'CRPkdTerminatePlugIns(toTerminate, NO);',
):
    assert token in reload, token

# Avoid mutations to the collection being enumerated, including reverse
# enumeration of its mutable copy; the rule remains unchanged.
assert '[plugIns reverseObjectEnumerator]' not in reload
assert '[plugIns removeObject:plugIn]' not in reload
assert '[toTerminate removeObject:plugIn]' not in reload
assert reload.index('if (![extensionPoint isEqualToString:') < reload.index('[toTerminate addObject:plugIn]')
assert reload.index('CRPkdTerminatePlugIns(toTerminate, NO);') > reload.index('for (id plugIn in plugIns)')

# No new behavior for Crane's notification-service extension, which uses
# per-PKDPlugIn container routing rather than a broad forced termination.
assert 'if ([extensionPoint isEqualToString:@"com.apple.usernotifications.service"])' in source
assert '[plugIn crane_activeContainerID]' in source
assert 'updated[CR_ENV_CONTAINER_IDENTIFIER] = containerIdentifier;' in source
assert 'CRPkdFindPlugIns(' in source

def select_for_termination(plugins):
    return [p for p in plugins
            if p["NSExtensionPointIdentifier"] != "com.apple.usernotifications.service"]

plugins = [
    {"name": "app-widget", "NSExtensionPointIdentifier": "com.apple.widgetkit-extension"},
    {"name": "push-service", "NSExtensionPointIdentifier": "com.apple.usernotifications.service"},
    {"name": "share", "NSExtensionPointIdentifier": "com.apple.share-services"},
    {"name": "push-service2", "NSExtensionPointIdentifier": "com.apple.usernotifications.service"},
]
filtered = select_for_termination(plugins)
assert [p["name"] for p in filtered] == ["app-widget", "share"]
assert len(plugins) == 4
assert select_for_termination([]) == []
assert len(select_for_termination(plugins[1:2])) == 0

def legacy_termination_decision(reply_arrives):
    # PKDServer has already received the termination request; timeout only
    # bounds waiting, it does not retry or claim termination was completed.
    return "callback" if reply_arrives else "timeout"

assert legacy_termination_decision(True) == "callback"
assert legacy_termination_decision(False) == "timeout"

print("Crane F-12 PlugInKit reload/termination contracts: PASS (device unverified)")
