"""Guard the original CraneSB runningboardd launch hook selector/ABI.

Evidence: CraneSB export 0x1BF10 registers both :withError: selectors;
0x1BF74 and 0x1BFEC forward the request and error arguments.
This is a source contract, not a runtime test.
"""
from pathlib import Path

source = (Path(__file__).resolve().parents[1] / "sources/cranesb/CRSpringBoard.m").read_text(encoding="utf-8")
assert 'NSSelectorFromString(@"executeLaunchRequest:withError:")' in source
assert 'NSSelectorFromString(@"_executeLaunchRequest:withError:")' in source
assert 'NSSelectorFromString(@"_executeLaunchRequest:")' not in source
assert 'static id (*gOriginalRBPrivateExecuteLaunchRequest)(id, SEL, id, id);' in source
assert 'static id CRRBPrivateExecuteLaunchRequest(id self, SEL command, id request, id error)' in source
assert 'gOriginalRBPrivateExecuteLaunchRequest(self, command, request, error)' in source
assert 'CRModifyRunningBoardLaunchRequest(request);' in source
assert 'applyProfile("CraneRB")' in source
print('CraneSB runningboardd launch ABI contract: PASS (runtime unverified)')
