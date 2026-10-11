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
# CraneSB 0x1BD44 compares returned environment by object identity, not
# dictionary contents. Avoid pre-copying an unchanged launch environment.
assert source.count('CRApplyEnvironmentChanges((NSMutableDictionary *)original, appID)') == 2
assert 'if (updated != original)' in source
assert 'if (updated == original)' in source
# CraneSB 0x1B45C uses the insurance success bit for redirection;
# lastError is only used to classify a failed check.
assert 'if (insuranceOK)' in source
assert 'if (insuranceOK && !lastError)' not in source
# 0x1B45C derives the daemon alert's connection flag from getLastError,
# while the original 0x1BAA4 callback has just three parameters.
assert 'Crane helper XPC insurance service is unavailable' in source
assert 'if (!proxy || ![proxy respondsToSelector:@selector(verifyCraneInsuranceAndReply:)])' in source
assert 'replyClosed = YES;' in source
assert '@synchronized(replyLock)' in source
assert 'if (waitResult != 0) insuranceOK = NO;' in source
assert 'lastError == nil);' in source
assert 'CRPresentDaemonError(brokenDaemons,\n                         insuranceError ?: lastError,\n                         lastError == nil);' in source
# 0x194EC/0x19608 fetches the launched PID and receives a two-argument reply:
# container ID plus a connection/status bit. nil+true is a missing main dylib;
# nil+false is a runningboardd/helper communication error.
assert 'reply:^(NSString *actualContainer, BOOL connectionWorks)' in source
assert '(void)[actualContainer isEqualToString:expectedContainer];' in source
assert 'if (connectionWorks == YES)' in source
assert 'CRPresentMainDylibNotLoadedError(processName);' in source
assert 'CRPresentDaemonError(@[@"runningboardd"], nil, NO);' in source
assert 'reply lacks the original second status' not in source
badge = (Path(__file__).resolve().parents[1] / 'sources/cranesb/CRBadgeStore.m').read_text(encoding='utf-8')
# CraneSB original 0x108F4: deliveredDate: variant tags content before
# forwarding request, BOOL repost, date, bundle ID, and completion unchanged.
assert 'static void CRBadgeSaveDatedRequest(id self, SEL cmd, id request, BOOL repost,' in badge
assert 'gCRBadgeSaveDatedRequestOriginal' in badge
assert 'original(self, cmd, request, repost, deliveredDate, appID, completion);' in badge
assert '@"_saveNotificationRequest:shouldRepost:deliveredDate:forBundleIdentifier:withCompletionHandler:"' in badge
assert '(IMP)CRBadgeSaveDatedRequest' in badge
assert 'tagged[@"crane_sourceContainerID"] = container;' in badge
print('CraneSB runningboardd + dated notification ABI contracts: PASS (runtime unverified)')
