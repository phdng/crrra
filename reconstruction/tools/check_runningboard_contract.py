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
assert 'static void CRBadgePendingRequests(id self, SEL cmd, NSString *appID, id completion)' in badge
assert '@"getPendingNotificationRequestsForBundleIdentifier:withCompletionHandler:"' in badge
assert 'gCRBadgePendingRequestsOriginal' in badge
assert 'crane_copyWithoutContainerID' in badge
assert 'reply([filtered copy]);' in badge
for selector in ('removePendingNotificationRequestsWithIdentifiers:forBundleIdentifier:completionHandler:', 'removePendingNotificationRequestsWithIdentifiers:forBundleIdentifier:', 'removeAllPendingNotificationRequestsForBundleIdentifier:completionHandler:', 'removeAllPendingNotificationRequestsForBundleIdentifier:'):
    assert selector in badge
assert 'CRBadgeResolveRemovalIdentifiers(self, appID, identifiers, NO' in badge
assert 'CRBadgeResolveRemovalIdentifiers(self, appID, nil, YES' in badge
assert 'original(self, cmd, filtered, appID, completion);' in badge
assert 'original(self, cmd, filtered, appID);' in badge
assert 'static id CRBadgeProxyBundleID(id self, SEL cmd)' in badge
assert 'un_applicationBundleIdentifier' in badge
assert 'crane_requestOriginContainerID' in badge
assert '(IMP)CRBadgeProxyBundleID' in badge
manager = (Path(__file__).resolve().parents[1] / 'sources/libcrane/CRManager.m').read_text(encoding='utf-8')
assert 'containerNameToDisplayInNotificationWithUserInfoOrContext:' in manager
assert 'info[@"crane_sourceContainerID"]' in manager
assert 'shouldUseShortVersion:YES' in manager
assert 'static id CRBadgeNotificationTitle(id self, SEL cmd)' in badge
assert '@"NCNotificationRequestContentProvider"' in badge
assert '@"setHeader:"' in badge
assert 'containerNameToDisplayInNotificationWithUserInfoOrContext:ofApplicationWithIdentifier:' in badge
assert 'return [NSString stringWithFormat:@"%@ (%@)", title, [name uppercaseString]];' in badge
assert 'static id CRBadgeBulletinForNotification(id self, SEL cmd, id notification)' in badge
assert '@"_queue_bulletinForNotification:"' in badge
assert '(IMP)CRBadgeBulletinForNotification' in badge
assert 'tagged[@"crane_sourceContainerID"] = source;' in badge
assert 'id source = @"DEFAULT";' in badge
assert 'if (info && appID)' in badge
assert 'if (!source && CRBadgeRedirectionEnabled(appID))' in badge
assert 'static BOOL CRBadgeSystemForeground(id self, SEL cmd, NSString *appID)' in badge
assert 'gCRBadgeForegroundContainer = [container copy];' in badge
assert 'if (userInfo && appID)' in badge
assert 'if (!container && CRBadgeRedirectionEnabled(appID))' in badge
assert 'NSString *container = @"DEFAULT";' in badge
assert 'dispatch_async(queue, ^{ gCRBadgeForegroundContainer = nil; });' in badge
assert '@"isApplicationForeground:"' in badge
assert '@"processesForBundleIdentifier:"' in badge
assert 'static void CRBadgeBulletinAction(id self, SEL cmd, id response, id completion)' in badge
assert 'actionType == 8 || actionType == 5' in badge
assert '@"handleBulletinActionResponse:withCompletion:"' in badge
assert 'usingBiometricsIfNeededWithSuccessHandler:^' in badge
assert 'original(self, cmd, response, completion);' in badge
assert 'static id CRBadgeMutateContent(id self, SEL cmd, id request, id error)' in badge
assert '@"mutateContentForNotificationRequest:error:"' in badge
assert 'extension = NSClassFromString(@"UNCNotificationServiceExtension");' in badge
assert 'gCRBadgeMutateContentOriginal' in badge
assert 'tagged[@"crane_sourceContainerID"] = source;' in badge
assert '[mutated setValue:[tagged copy] forKey:@"_userInfo"]' in badge
assert 'static id CRBadgeRecordCopyWithoutContainer(id self, SEL cmd)' in badge
assert 'static id CRBadgeRequestCopyWithoutContainer(id self, SEL cmd)' in badge
assert 'class_addMethod(recordClass, copySEL' in badge
assert 'class_addMethod(requestClass, copySEL' in badge
assert '[stripped removeObjectForKey:@"crane_sourceContainerID"]' in badge
assert 'return self;' in badge
assert 'static BOOL CRBadgeRecordIsSimilar(id self, SEL cmd, id other)' in badge
assert '@"isSimilar:"' in badge
assert 'gCRBadgeRecordSimilarOriginal' in badge
assert 'return [lhsContainer isEqualToString:rhsContainer];' in badge
assert 'static id CRBadgeRecordLookup(id self, SEL cmd, id identifier, NSString *appID)' in badge
assert 'static id CRBadgeRecordsLookup(id self, SEL cmd, NSString *appID)' in badge
assert '@"notificationRecordForForIdentifier:bundleIdentifier:"' in badge
assert '@"notificationRecordsForBundleIdentifier:"' in badge
assert 'CRBadgeRecordSource(record)' in badge
assert 'static void CRBadgeRecordsLookupWithReply(id self, SEL cmd,' in badge
assert '@"notificationRecordsForBundleIdentifier:withCompletionHandler:"' in badge
assert 'gCRBadgeRecordsLookupWithReplyOriginal' in badge
assert 'reply([filtered copy]);' in badge
assert 'static void CRBadgeRemoveRecordsPassingTest(id self, SEL cmd, id predicate,' in badge
assert '@"removeNotificationRecordsPassingTest:forBundleIdentifier:"' in badge
assert 'if (!test(record))' in badge
assert 'return [CRBadgeRecordSource(record) isEqualToString:container];' in badge
assert 'static void CRBadgeRemoveAllRecords(id self, SEL cmd, NSString *appID)' in badge
assert '@"removeAllNotificationRecordsForBundleIdentifier:"' in badge
assert 'self, removeSEL, ^BOOL(id record) { (void)record; return YES; }, appID' in badge
assert 'static void CRBadgeRegisterNotificationAdditionsProtocol(void)' in badge
assert '"v32@0:8@16@24", YES, YES' in badge
assert '"v40@0:8@16@24@32", YES, YES' in badge
assert 'CRBadgeRegisterNotificationAdditionsProtocol();' in badge
assert 'static void CRBadgeUnregisterNotifications(id self, SEL cmd,' in badge
assert '(IMP)CRBadgeUnregisterNotifications, "v@:@@"' in badge
assert '@"_remoteNotificationService"' in badge
assert '@"invalidateTokenForRemoteNotificationsForBundleIdentifier:"' in badge
assert 'static void CRBadgeXPCSetProtocol(id self, SEL cmd, Protocol *protocol)' in badge
assert 'protocol_addProtocol(extended, additions);' in badge
assert 'protocol_addProtocol(extended, base);' in badge
assert 'objc_registerProtocol(extended);' in badge
assert 'if (base && additions && protocol && protocol_isEqual(protocol, base))' in badge
assert 'static void CRBadgeCleanupUninstalledSources(id server, id sources)' in badge
assert 'dispatch_queue_set_specific(queue, &gCRBadgeUninstallQueueSpecificKey,' in badge
assert '(__bridge void *)queue, NULL);' in badge
assert 'if (dispatch_get_specific(&gCRBadgeUninstallQueueSpecificKey) ==' in badge
assert '(__bridge void *)queue)' in badge
assert 'dispatch_sync(queue, cleanup);' in badge
assert 'if (![appID isKindOfClass:[NSString class]] ||' in badge
assert 'if (![container isKindOfClass:[NSString class]])' in badge
assert '@"notificationSourcesDidUninstall:"' in badge
assert '@"applicationsDidUninstall:"' in badge
assert '@"_queue_invalidateTokenForBundleIdentifier:"' in badge
assert '@"_queue_calculateTopics"' in badge
assert 'static id CRBadgeExtensionMatchingAttributes(id attributes)' in badge
assert 'tagged[@"crane_containerID"] = container;' in badge
assert 'static void CRBadgeExtensionsSync(id self, SEL cmd, id attributes,' in badge
assert 'static void CRBadgeExtensionsAsync(id self, SEL cmd, id attributes,' in badge
assert '@"extensionsWithMatchingAttributes:synchronously:completion:"' in badge
assert '@"extensionsWithMatchingAttributes:completion:"' in badge
assert 'static BOOL CRBadgeNotificationPermission(id self, SEL cmd, NSString *topic)' in badge
assert '@"uns_isAllowedToRequestUserNotificationsForBundleIdentifier:"' in badge
assert 'NSString *active = CRBadgeContainerForConnection(self);' in badge
assert 'NSArray *parts = [topic componentsSeparatedByString:@".c_r_a_n_e."];' in badge
assert 'NSString *container = [parts lastObject];' in badge
assert 'if (![active isEqualToString:container])' in badge
assert 'id record = [allocated respondsToSelector:initSEL] && representation' in badge
assert '0x1172C constructs a UNSNotificationRecord from its dictionary' in badge
assert 'if (!record && [self respondsToSelector:@selector(copyWithZone:)])' not in badge
assert 'if (!record || record == self ||' in badge
assert 'verifiedInfo[@"crane_sourceContainerID"]' in badge
assert 'if (![verifiedInfo isKindOfClass:[NSDictionary class]] ||' in badge
assert '![record respondsToSelector:@selector(setUserInfo:)])' in badge
assert 'record, @selector(setUserInfo:), [stripped copy]);\n    } @catch (NSException *exception)' in badge
assert 'static id CRBadgeRecordSource(id record)' in badge
# CraneSB 0xBE18: nil userInfo differs from present keyed userInfo with
# missing tag (DEFAULT); never narrow the original to NSDictionary.
assert 'if (!info)\n        return nil;' in badge
assert 'if (![info respondsToSelector:keyedSEL])' in badge
assert 'info, keyedSEL, @"crane_sourceContainerID"' in badge
assert 'return value ?: @"DEFAULT";' in badge
assert 'static NSString *CRBadgeContainerForConnectionAndApplication(' in badge
# Original 0xFD9C updates the badge with intValue and clears scoped
# notifications when the NSNumber is exactly equal to zero.
assert 'CRBadgeStoreSetContainerCount(appID, container,\n                                          [number intValue]);' in badge
assert 'if ([number isEqual:[NSNumber numberWithInt:0]])' in badge
assert '@"removeAllNotificationRecordsForBundleIdentifier:"' in badge
assert '((void (*)(id, SEL, id))objc_msgSend)(self, removeSEL, appID);' in badge
assert 'version.majorVersion < 17' in badge
assert 'processesForBundleIdentifier:' in badge
assert 'if ([processes count] != 1)' in badge
assert badge.count('CRBadgeContainerForConnectionAndApplication(') == 10
assert 'static id CRBadgeSanitizedRecord(id record)' in badge
assert 'if (tagged && clean == record)' in badge
assert 'return clean;\n    } @catch (NSException *exception) {' in badge
assert badge.count('CRBadgeSanitizedRecord(record);') == 3
assert 'info[@"crane_sourceContainerID"]' in badge
assert '((id (*)(id, SEL))objc_msgSend)(record, copySEL) : record;' not in badge
assert 'if (!copiedContent || copiedContent == content)' in badge
assert 'verifiedInfo[@"crane_sourceContainerID"]' in badge
assert 'id request = [self copy];' in badge
assert 'if (!request || request == self)' in badge
assert 'id copiedInfo = [copiedContent respondsToSelector:@selector(userInfo)]' in badge
assert 'copiedInfo[@"crane_sourceContainerID"]' in badge
assert 'Original 0xE730 skips decoration only when the name is nil.' in badge
assert 'if (![name isKindOfClass:[NSString class]] || ![name length])' not in badge
assert '0xEBA0 skips DEFAULT, not an empty identifier.' in badge
assert '![identifier length] ||' not in badge
print('CraneSB runningboardd + notification ABI contracts: PASS (runtime unverified)')
