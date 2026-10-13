"""Roothide Chrome injection diagnostics: separate missing main dylib from no
CRANE_CONTAINER_IDENTIFIER, and avoid duplicate after-launch checks per FBProcess.

Source+fixture assertions only. On-device proof requires installed native
CraneSB in runningboardd and ' Crane.dylib' inside Chrome.
"""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
main = (root / "sources/maindylib/CRMainDylib.m").read_text(encoding="utf-8")
sb = (root / "sources/cranesb/CRSpringBoard.m").read_text(encoding="utf-8")
master = (root / "Makefile").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

constr = main[main.index("static void CRInitFunc(void)"):]
for token in (
    "const char *identifier = getenv(CR_ENV_CONTAINER_IDENTIFIER.UTF8String);",
    "if (!identifier) {",
    "NSString *bundleID = CRSafeGetBundleIdentifier();",
    '![bundleID hasPrefix:@"com.apple."]',
    'Crane: app dylib loaded bundle=%@ pid=%d containerEnvPresent=0',
    'if (identifier) {',
    'Crane: app init bundle=%@ container=%@ protection=%d spoof=%d',
    'CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);',
):
    assert token in constr, token
assert constr.index('Crane: app dylib loaded bundle=') < constr.index('unsetenv(')
assert constr.index('Crane: app dylib loaded bundle=') < constr.index('if (identifier) {')
assert constr.index('CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier)') > constr.index('if (_crActiveContainerIdentifier.length)')
assert '\n        setenv(CR_ENV_CONTAINER_IDENTIFIER' not in constr

checks = sb[sb.index("static char kCRInjectionCheckedPIDAssociation;"):
            sb.index("/* crane_applyModificationsIfNeededToExecutionContext:")]
for token in (
    "objc_getAssociatedObject(",
    "objc_setAssociatedObject(launched, &kCRInjectionCheckedPIDAssociation,",
    "OBJC_ASSOCIATION_RETAIN_NONATOMIC",
    "@synchronized(launched)",
    "if (alreadyChecked && alreadyChecked.intValue == pid)",
    "CraneSB: duplicate post-launch check ignored pid=%d",
    "CRVerifyProcessInjectionAfterLaunch(launched, pid, expectedContainer, 0);",
):
    assert token in checks, token
assert checks.index('if (pid <= 0)') < checks.index('@synchronized(launched)')
assert checks.index('objc_setAssociatedObject(') < checks.index('CRVerifyProcessInjectionAfterLaunch(launched, pid, expectedContainer, 0);')
assert 'static NSMutableSet' not in checks

rb = sb[sb.index("static void CRInitRunningBoardd(void)"):
        sb.index("/* ------------------------------------------------------------------------- */\n/* InitFunc_2", sb.index("static void CRInitRunningBoardd(void)"))]
assert 'NSClassFromString(@"RBProcessManager")' in rb
assert 'executeLaunchRequest:withError:' in rb
assert '_executeLaunchRequest:withError:' in rb
assert 'runningboardd hook selectors execute=%d private=%d' in rb

main_filter = root / "layout/Library/MobileSubstrate/DynamicLibraries/ Crane.plist"
sb_filter = root / "layout/Library/MobileSubstrate/DynamicLibraries/CraneSB.plist"
assert plistlib.loads(main_filter.read_bytes()) == {"Filter":{"Bundles":["com.apple.Foundation"], "Flags":0}}
assert plistlib.loads(sb_filter.read_bytes()) == {"Filter":{"Bundles":["com.apple.springboard"],"Executables":["runningboardd"]}}
assert 'Library/MobileSubstrate/DynamicLibraries/ Crane.dylib' in master
assert 'Library/MobileSubstrate/DynamicLibraries/ Crane.plist' in master
assert 'check_main_injection_diagnostics_contract.py' in workflow

# Per-object+pid one-shot model; same pid on different objects remains
# independent, and a new pid on a reused process object may be checked.
record = {}
def should_check(object_id, pid):
    if pid <= 0 or record.get(object_id) == pid:
        return False
    record[object_id] = pid
    return True
assert should_check("A", 2339)
assert not should_check("A", 2339)
assert should_check("B", 2339)
assert should_check("A", 2340)
assert not should_check("A", 2340)
assert not should_check("A", -1)

print("Crane app dylib/no-env and duplicate-check diagnostic contracts: PASS (device unverified)")
