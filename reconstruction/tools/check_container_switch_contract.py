"""Crane container selection callback/launch source contracts.

Recovered CraneSB 0x14214, 0x14294, 0x143CC and 0x18A3C.
Source/behavior-shape checks only; iOS callback ABI needs device verification.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
menu = (root / "sources/cranesb/CRMenuHooks.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
header = (root / "sources/common/CRManager.h").read_text(encoding="utf-8")
badge = (root / "sources/cranesb/CRBadgeStore.m").read_text(encoding="utf-8")
activator = (root / "sources/cranesb/CRActivator.m").read_text(encoding="utf-8")

# Original 0x143CC consumes a BOOL supplied by CraneManager's successful
# switch callback, unlike a void dispatch_block_t.
assert header.count("usingBiometricsIfNeededWithSuccessHandler:(void (^)(BOOL authenticated))handler;") == 2
assert "usingBiometricsIfNeededWithSuccessHandler:(dispatch_block_t)" not in header
assert manager.count("usingBiometricsIfNeededWithSuccessHandler:(void (^)(BOOL authenticated))handler") == 2
assert "void (^apply)(BOOL) = ^(BOOL authenticated) {" in manager
assert "handler(authenticated);" in manager
assert "CRRequestAuthentication(CRLocalize(@\"CONFIRM_PASSWORD\"), ^{ apply(YES); });" in manager
assert "apply(NO);" in manager
assert "CRRequestAuthentication(CRLocalize(@\"CONFIRM_PASSWORD\"), apply)" not in manager

# Native launch action 0x14214 routes through FBSOpenApplicationService.
assert 'NSClassFromString(@"FBSOpenApplicationService")' in menu
assert 'NSSelectorFromString(@"openApplication:withOptions:completion:")' in menu

# 0x14294: selected current container launches immediately; selecting a new
# container calls CraneManager and lets 0x143CC delay iff biometric + old CF.
assert 'if ([target isEqualToString:capturedActive]) {' in menu
assert 'CRLaunchAfterContainerSwitch(launch, authenticated);' in menu
assert 'usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated)' in menu
assert 'if (authenticated && kCFCoreFoundationVersionNumber < 1740.0)' in menu
assert 'dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),' in menu
assert 'dispatch_get_main_queue(), launch);' in menu
assert 'launch();' in menu

# All other callers must accept the BOOL ABI, even if they do not consume
# the old-iOS launch delay: legacy shortcuts, bulletin actions, Activator.
assert 'usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {' in badge
assert 'usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {' in activator
assert menu.count('usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {') == 2

# Independent model of 0x143CC dispatch decision.
def delay_launch(authenticated: bool, core_foundation_version: float) -> bool:
    return authenticated and core_foundation_version < 1740.0

assert delay_launch(True, 1739.99)
assert not delay_launch(True, 1740.0)
assert not delay_launch(False, 1739.99)
assert not delay_launch(False, 1932.101)

print("Crane F-13 container switch callback contracts: PASS (runtime unverified)")
