#!/usr/bin/env python3
"""Safety/diagnostic invariants for the reconstruction adapter, no runtime claim."""
from pathlib import Path
from verify_helper_entitlements import check_sources
ROOT = Path(__file__).resolve().parents[1]
manager = (ROOT / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
common = (ROOT / "sources/common/CRCommon.m").read_text(encoding="utf-8")
helper = (ROOT / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
for source in (manager, common):
    assert "CR_HELPERD_MACH_SERVICE.UTF8String, NULL, 0);" not in source
    assert "XPC_CONNECTION_MACH_SERVICE_PRIVILEGED" in source
lookup = manager[manager.index("static void CRManagerLookupActiveContainerForPid"):manager.index("static void CRManagerVerifyRuntimeComponent")]
start = manager.index("- (void)verifyCraneInsuranceAndReply:", manager.index("@implementation CRInsuranceHealthProxy"))
insurance = manager[start:manager.index("- (void)verifySupportLoadedIntoProcessNamed:", start)]
for body in (lookup, insurance):
    assert "CRHelperValidateHealthReply(response," in body
    assert "CRHelperXPCEventError(event," in body
    assert "CRHelperRequestAllocationFailed" in body
    assert "CRHelperReplyTimedOut" in body
    assert "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC))" in body
    finish = body[body.index("void (^finish)"):body.index("xpc_connection_set_event_handler")]
    assert finish.index("if (finished)") < finish.index("finished = YES;") < finish.index("CRManagerDeliverHelperReply(error,")
assert 'finish(NO, @"cranehelperd", nil, NO)' not in insurance
assert "finish(nil, NO);" not in lookup
assert 'xpc_dictionary_get_bool(response, "injection_verified")' in insurance
assert 'CRIsAuthenticatedCraneSBPeer(peerProcess, peerSigningID)' in helper
assert 'CRHelperXPCEventError(event, @"listen_global")' in helper
for name in ("cranehelperd", "cranehelperd_start"):
    make = (ROOT / "sources" / name / "Makefile").read_text(encoding="utf-8")
    assert f"{name}_CODESIGN_FLAGS = -Sentitlements.original.plist" in make
    assert f"{name}_CODESIGN_FLAGS = -Sentitlements.roothide.plist" in make
check_sources()
print("Helper transport contract: PASS (native/device tests still required)")
