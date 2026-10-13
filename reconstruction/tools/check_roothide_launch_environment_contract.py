"""Roothide iOS 15 SpringBoard launch-environment compatibility contract.

Native CraneSB 0x180F0 only returns a container identifier after iOS 13 and
expects runningboardd (0x1BD44) to mutate _additionalEnvironment. Some
Roothide Bootstrap installations do not inject ordinary tweaks into daemons;
the device demonstrates the app's ' Crane.dylib' loaded with env absent.
The compatibility path MAY set the native pre-iOS-13 context.environment
property in SpringBoard if available, but never bypasses helper/libSandy
insurance, invents an ID, or disables the post-launch proof alert.

Static contract and independent decision model: device/runtime not verified.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sb = (root / "sources/cranesb/CRSpringBoard.m").read_text(encoding="utf-8")
mk = (root / "Makefile").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

start = sb.index("static id CRApplyModificationsIfNeededToExecutionContext(")
end = sb.index("/* FBProcessManager launch interception", start)
section = sb[start:end]
modern = section[section.index('if (kCFCoreFoundationVersionNumber >= 1665.15) {'):
                 section.index("/* Pre-iOS 13 path")]
for token in (
    'NSString *containerID = CRContainerToRedirectTo(appID);',
    '#if defined(CRANE_ROOTHIDE)',
    'SEL getEnvironment = @selector(environment);',
    'SEL setEnvironment = @selector(setEnvironment:);',
    'SEL modernRead = NSSelectorFromString(@"_additionalEnvironment");',
    'SEL modernWrite = NSSelectorFromString(@"_setAdditionalEnvironment:");',
    '[executionContext respondsToSelector:modernRead]',
    '[executionContext respondsToSelector:modernWrite]',
    'surface = @"additionalEnvironment";',
    '[executionContext respondsToSelector:getEnvironment]',
    '[executionContext respondsToSelector:setEnvironment]',
    'if (original && ![original isKindOfClass:NSDictionary.class])',
    'CRApplyEnvironmentChanges(',
    'updated[CR_ENV_CONTAINER_IDENTIFIER]',
    'isEqualToString:containerID',
    'if (updated != original &&',
    'executionContext, setEnvironment, updated',
    'roothide SpringBoard launch fallback applied',
    'roothide SpringBoard launch fallback blocked',
    'return containerID;',
    '#endif',
):
    assert token in modern, token
assert modern.index('CRApplyEnvironmentChanges(') < modern.index('executionContext, setEnvironment, updated')
assert modern.index('updated != original') < modern.index('executionContext, setEnvironment, updated')
assert modern.index('#endif') < modern.index('return containerID;')
assert section.index('if (!hasFinishedLaunching || !appID.length)') < section.index('if (kCFCoreFoundationVersionNumber >= 1665.15)')
assert section.count('CRApplyEnvironmentChanges(') == 2
assert 'export ADDITIONAL_CFLAGS += -DCRANE_ROOTHIDE=1' in mk
assert 'if (insuranceOK)' in sb
assert 'CRPresentDaemonError(brokenDaemons,' in sb
assert 'if (connectionWorks == YES && attempt < 2)' in sb
assert 'CRPresentMainDylibNotLoadedError(processName);' in sb
assert 'check_roothide_launch_environment_contract.py' in workflow

def modern_request(selected, has_get, has_set, env_type_ok, insurance, same_id):
    if not selected:
        return "no-switch"
    if not has_get or not has_set:
        return "no-selector"
    if not env_type_ok:
        return "invalid-context"
    if not insurance:
        return "insurance-blocked"
    if not same_id:
        return "proof-mismatch"
    return "applied"

assert modern_request(True, True, True, True, True, True) == "applied"
assert modern_request(True, True, True, True, False, True) == "insurance-blocked"
assert modern_request(True, True, True, True, True, False) == "proof-mismatch"
assert modern_request(True, False, True, True, True, True) == "no-selector"
assert modern_request(True, True, False, True, True, True) == "no-selector"
assert modern_request(True, True, True, False, True, True) == "invalid-context"
assert modern_request(False, True, True, True, True, True) == "no-switch"

print("Crane Roothide SpringBoard launch-environment fallback contract: PASS (runtime unverified)")
