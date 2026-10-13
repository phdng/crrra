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
# while the original 0x1BAA4 callback has exactly three parameters.
assert '^(BOOL works, NSArray<NSString *> *daemons,' in source
assert 'NSError *error) {' in source
assert 'BOOL connWorks' not in source
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
assert 'if (actualContainer.length)' in source
assert 'expectedContainer, actualContainer);' in source
assert 'CRVerifyProcessInjectionAfterLaunch(launched, pid, expectedContainer, 0);' in source
assert 'if (connectionWorks == YES && attempt < 2)' in source
assert 'CRVerifyProcessInjectionAfterLaunch(again, pid,' in source
assert 'CRPresentMainDylibNotLoadedError(processName);' in source
assert 'if (connectionWorks == YES)' in source
assert 'CRPresentMainDylibNotLoadedError(processName);' in source
assert 'CRPresentDaemonError(@[@"runningboardd"], lookupError, NO);' in source
assert 'NSError *lookupError = [CraneManager.sharedManager getLastError];' in source
# Reconstruction adapter now retains the underlying transport error; the
# recovered nil/false -> communication-error branch and two-argument ABI stay.
assert 'reply lacks the original second status' not in source
badge = (Path(__file__).resolve().parents[1] / 'sources/cranesb/CRBadgeStore.m').read_text(encoding='utf-8')
# Native 0xB00C -> 0xAC2C projects corrected badge counts after startup
# reconciliation. Defer until dispatch_once completes to avoid recursion via
# CRBadgeAggregateCount -> CRBadgeStoreInitialize and ensure once-only replay.
initialization = badge[badge.index('void CRBadgeStoreInitialize(void)'):badge.index('/* 0xB00C: LSApplicationProxy')]
assert initialization.index('CRBadgeStoreReconcileContainerKeys();') < initialization.index('NSArray<NSString *> *refresh = nil;')
assert 'refresh = gCRBadgeInitialRefresh;' in initialization
assert 'gCRBadgeInitialRefresh = nil;' in initialization
assert 'for (NSString *appID in refresh)\n        CRBadgeProjectApplicationCount(appID, YES);' in initialization
reconcile = badge[badge.index('static void CRBadgeStoreReconcileContainerKeys(void)\n{'):badge.index('NSInteger CRBadgeStoreContainerCount(')]
assert 'for (id countValue in [counts allValues])' in reconcile
assert 'for (id countValue in [updated allValues])' not in reconcile
assert reconcile.index('for (id countValue in [counts allValues])') < reconcile.index('for (id containerID in counts)')
assert reconcile.index('[refresh addObject:appID];') < reconcile.index('gCRBadgeInitialRefresh = [refresh copy];')
assert 'updated[@"DEFAULT"] = @([iconCount intValue]);' in reconcile
assert 'if (iconCount &&\n            storedPositive != (uint32_t)[iconCount intValue])' in reconcile
assert '[validIDs containsObject:@"DEFAULT"]' not in reconcile
assert '[refresh addObject:appID];' in reconcile
assert 'gCRBadgeInitialRefresh = [refresh copy];' in reconcile
assert 'uint32_t storedPositive = 0;' in reconcile
assert 'int32_t count = [countValue intValue];' in reconcile
assert 'storedPositive += (uint32_t)count;' in reconcile
assert 'storedPositive != (uint32_t)[iconCount intValue]' in reconcile
assert 'if ([iconCount integerValue] == 0)' not in reconcile
assert '? [value intValue] : 0;' in badge
assert 'NSNumber *value = @((int)count);' in badge
assert 'int nativeCount = (int)count;' in badge
assert 'counts[containerID] = @(nativeCount);' in badge
# 0xAA00/0xAB44 use signed 32-bit counts but _DWORD (wrapping) sum.
aggregate = badge[badge.index('static NSInteger CRBadgeAggregateCount(NSString *appID, BOOL validate)\n{'):badge.index('static id CRBadgeRecordSource(id record);')]
assert 'uint32_t positive = 0;' in aggregate
assert 'uint32_t negative = 0;' in aggregate
assert 'int32_t count = (int32_t)CRBadgeStoreContainerCount(' in aggregate
assert 'positive += (uint32_t)count;' in aggregate
assert 'negative += (uint32_t)count;' in aggregate
assert '(int32_t)negative < 0 ? negative : 0' in aggregate
assert 'NSInteger positive = 0;' not in aggregate
private_set = badge[badge.index('static void CRBadgePrivateSet(id self, SEL cmd, NSNumber *number,'):badge.index('static void CRBadgeQueueSet(')]
assert '[number respondsToSelector:@selector(intValue)]' not in private_set
assert 'Objective-C returns 0' in private_set
assert '[number intValue]' in private_set
assert '[number isEqual:@0]' in private_set
assert 'NSNumber *aggregate = @((int)CRBadgeAggregateCount(appID, YES));' in private_set
assert '[number integerValue]' not in private_set

# Independent boundary models for the recovered 0xAA00 priority/fallback.
# They guard expected 32-bit semantics, not native-device execution.
def _i32(value):
    value &= 0xFFFFFFFF
    return value if value < 0x80000000 else value - 0x100000000

def _aggregate_native(values):
    positive = 0
    negative = 0
    for value in values:
        value = _i32(value)
        if value >= 0:
            positive = (positive + value) & 0xFFFFFFFF
        else:
            negative = (negative + value) & 0xFFFFFFFF
    return _i32(positive if positive else negative if _i32(negative) < 0 else 0)

assert _aggregate_native([3, 5, -1]) == 8
assert _aggregate_native([-2, -3]) == -5
assert _aggregate_native([0, -1]) == -1
assert _aggregate_native([0x7FFFFFFF, 1]) == -0x80000000
assert _aggregate_native([0x7FFFFFFF, 0x7FFFFFFF, 2, -9]) == -9
assert _aggregate_native([-0x80000000, -0x80000000]) == 0
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
assert 'id source = CRBadgeContainerForNotificationInfo(info, appID);' in badge
assert 'source, @selector(objectForKeyedSubscript:)' not in badge
assert 'static BOOL CRBadgeSystemForeground(id self, SEL cmd, NSString *appID)' in badge
assert 'gCRBadgeForegroundContainer = [container copy];' in badge
assert 'static NSObject *CRBadgeForegroundLock(void)' in badge
assert 'foregroundContainer = gCRBadgeForegroundContainer;' in badge
assert 'return [foregroundContainer isEqualToString:active];' in badge
assert 'if (!info || !appID)' in badge
assert 'NSString *container = CRBadgeContainerForNotificationInfo(userInfo, appID);' in badge
assert 'return CRBadgeRedirectionEnabled(appID) ? @"DEFAULT" : nil;' in badge
assert 'foregroundGeneration = ++gCRBadgeForegroundGeneration;' in badge
assert 'if (foregroundGeneration == gCRBadgeForegroundGeneration)' in badge
assert 'dispatch_async(queue, clearForeground);' in badge
assert 'clearForeground();' in badge
assert 'foreground metadata cannot persist after a failed save' in badge
assert 'if (queue)\n            dispatch_async(queue, clearForeground);' in badge
assert '@"isApplicationForeground:"' in badge
assert '@"processesForBundleIdentifier:"' in badge
assert 'static void CRBadgeBulletinAction(id self, SEL cmd, id response, id completion)' in badge
assert 'actionType == 8 || actionType == 5' in badge
assert 'id container = CRBadgeContainerForNotificationInfo(context, appID);' in badge
assert '@"handleBulletinActionResponse:withCompletion:"' in badge
assert 'usingBiometricsIfNeededWithSuccessHandler:^' in badge
assert 'original(self, cmd, response, completion);' in badge
assert 'static id CRBadgeMutateContent(id self, SEL cmd, id request, id error)' in badge
assert '@"mutateContentForNotificationRequest:error:"' in badge
assert 'extension = NSClassFromString(@"UNCNotificationServiceExtension");' in badge
assert 'gCRBadgeMutateContentOriginal' in badge
assert 'tagged[@"crane_sourceContainerID"] = source;' in badge
assert '[mutated setValue:[tagged copy] forKey:@"_userInfo"]' in badge
# 0x115F4 -> 0x1235C copies arbitrary keyed userInfo (not just NSDictionary),
# with an independent mutable copy and a typed private objc_msgSend.
mutation = badge[badge.index('static id CRBadgeMutateContent(id self, SEL cmd, id request, id error)'):badge.index('static id CRBadgeUserInfoCopyWithoutTag(id info)')]
assert '[mutatedInfo respondsToSelector:@selector(mutableCopy)]' in mutation
assert 'tagged != mutatedInfo' in mutation
assert 'SEL setSEL = @selector(setObject:forKeyedSubscript:);' in mutation
assert '((void (*)(id, SEL, id, id))objc_msgSend)(tagged, setSEL,' in mutation
assert 'source, @"crane_sourceContainerID"' in mutation
assert '[mutatedInfo isKindOfClass:[NSDictionary class]]' not in mutation
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
assert 'static NSString *CRBadgeMutationContainer(id request, id appID)' in badge
assert 'static BOOL CRBadgePkdSupportVerified(void)' in badge
assert '@"verifyCraneSupportLoadedIntoDaemon:reply:"' in badge
assert 'proxy, verifySEL, daemon, reply' in badge
assert 'return CRBadgeDaemonSupportVerified(@"pkd");' in badge
# Original 0x11D74 / 0x11E44 gates all Crane APNs token operations on
# authenticated CraneSupport injection into apsd, falling back to native.
assert 'static BOOL CRBadgeDaemonSupportVerified(NSString *daemon)' in badge
assert 'if (!CRBadgeDaemonSupportVerified(@"apsd")) {' in badge
assert 'CRPresentApsdRegistrationError(appID);' in badge
assert 'CRBadgeRedirectionEnabled(appID) &&\n        CRBadgeDaemonSupportVerified(@"apsd")' in badge
assert 'legacyDescriptionMissing ? appID : topic' in badge
assert 'BOOL legacyListener = class_getInstanceVariable(object_getClass(self),' in badge
assert 'if (!legacyListener)\n        context[key] = container;' in badge
assert 'if (legacyListener) {\n        legacyDescriptionMissing = YES;' in badge
assert 'if (!legacyListener) {\n            if (previous)' in badge
assert 'return replied && verified;' in badge
assert badge.count('if (container && !CRBadgePkdSupportVerified())') == 2
assert badge.count('CRPresentPkdRegistrationError(appID);') == 2
assert 'SEL keyedSEL = @selector(objectForKeyedSubscript:);' in badge
assert 'info, keyedSEL, @"crane_sourceContainerID"' in badge
assert 'if (!CRBadgeRedirectionEnabled(appID))\n        return nil;' in badge
assert 'static void CRBadgeIncomingMessage(id self, SEL cmd, id connection, id message)' in badge
# Native 0xEDF4 always calls 0xBE18, even for nil/non-dictionary userInfo.
assert 'id source = CRBadgeSourceMarkerFromInfo(info);' in badge
assert 'containerSettingsForContainerWithIdentifier:source' in badge
assert 'static void CRBadgeRemoveAllRecords(id self, SEL cmd, NSString *appID)' in badge
assert '@"removeAllNotificationRecordsForBundleIdentifier:"' in badge
assert 'self, removeSEL, ^BOOL(id record) { (void)record; return YES; }, appID' in badge
# iOS 15 NSXPCInterface requires Clang-emitted extended protocol method
# metadata; runtime-created addition methods crash SpringBoard at setProtocol:.
assert '#import "CRXPCProtocols.h"' in badge
assert 'Protocol *additions = @protocol(UNUserNotificationProtocolCraneAdditions);' in badge
assert 'objc_allocateProtocol(\n        "UNUserNotificationProtocolCraneAdditions")' not in badge
assert 'protocol_addMethodDescription(' not in badge
assert 'CRBadgeRegisterNotificationAdditionsProtocol();' not in badge
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
assert badge.count('CRBadgeExplicitSourceTagFromInfo(verifiedInfo)') == 2
assert badge.count('![verifiedInfo respondsToSelector:@selector(objectForKeyedSubscript:)]') == 2
assert '![record respondsToSelector:@selector(setUserInfo:)])' in badge
assert 'record, @selector(setUserInfo:), [stripped copy]);\n    } @catch (NSException *exception)' in badge
assert 'static id CRBadgeContainerForNotificationInfo(id info, NSString *appID)' in badge
assert 'if (!info || !appID)\n        return @"DEFAULT";' in badge
assert 'return CRBadgeRedirectionEnabled(appID) ? @"DEFAULT" : nil;' in badge
assert 'NSString *container = CRBadgeContainerForNotificationInfo(userInfo, appID);' in badge
assert 'return CRBadgeContainerForNotificationInfo(info, appID);' in badge
assert 'static id CRBadgeRecordSource(id record)' in badge
# CraneSB 0xBE18: nil userInfo differs from present keyed userInfo with
# missing tag (DEFAULT); never narrow the original to NSDictionary.
assert 'static id CRBadgeSourceMarkerFromInfo(id info)' in badge
# Native 0x126E8 finds explicit tag from keyed userInfo, not exclusively
# NSDictionary. Tag-bearing items must be copied and checked fail-closed.
assert 'static id CRBadgeExplicitSourceTagFromInfo(id info)' in badge
assert 'info, @selector(objectForKeyedSubscript:), @"crane_sourceContainerID"' in badge
assert 'static id CRBadgeUserInfoCopyWithoutTag(id info)' in badge
assert badge.count('if (!CRBadgeExplicitSourceTagFromInfo(info))') == 3
assert badge.count('id stripped = CRBadgeUserInfoCopyWithoutTag(info);') == 2
assert 'if (!stripped || stripped == info ||' in badge
assert '[stripped removeObjectForKey:@"crane_sourceContainerID"]' in badge
assert 'CRBadgeExplicitSourceTagFromInfo(clean))' in badge
assert '@catch (NSException *exception)' in badge
assert 'BOOL tagged = CRBadgeExplicitSourceTagFromInfo(originalInfo) != nil;' in badge
assert 'CRBadgeExplicitSourceTagFromInfo(info))' in badge
assert 'if (![info isKindOfClass:[NSDictionary class]] ||\n        !info[@"crane_sourceContainerID"])' not in badge
# 0xBF00 / 0x10138 must use the same 0xBA6C resolver for queue saves.
assert 'NSString *containerID = CRBadgeSourceForRecord(record, appID);' in badge
assert 'id source = CRBadgeRecordSource(record);' in badge
assert 'return [source isEqualToString:containerID];' in badge
assert 'static void CRBadgeSaveRecord(id self, SEL cmd, id record,' in badge
assert 'if (!info || ![info respondsToSelector:@selector(objectForKeyedSubscript:)])' in badge
assert 'return marker ?: @"DEFAULT";' in badge
assert badge.count('id source = CRBadgeSourceMarkerFromInfo(info);') >= 2
assert 'id lhsContainer = CRBadgeSourceMarkerFromInfo(lhs);' in badge
assert 'id rhsContainer = CRBadgeSourceMarkerFromInfo(rhs);' in badge
assert 'return CRBadgeSourceMarkerFromInfo(info);' in badge
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
assert 'CRBadgeExplicitSourceTagFromInfo(info))' in badge
assert '((id (*)(id, SEL))objc_msgSend)(record, copySEL) : record;' not in badge
assert 'if (!copiedContent || copiedContent == content)' in badge
assert 'id request = [self copy];' in badge
assert 'if (!request || request == self)' in badge
assert 'id copiedInfo = [copiedContent respondsToSelector:@selector(userInfo)]' in badge
assert 'CRBadgeExplicitSourceTagFromInfo(copiedInfo))' in badge
assert '(CRBadgeExplicitSourceTagFromInfo(info) && copied == request)' in badge
assert 'Original 0xE730 skips decoration only when the name is nil.' in badge
assert 'if (![name isKindOfClass:[NSString class]] || ![name length])' not in badge
assert '0xEBA0 skips DEFAULT, not an empty identifier.' in badge
assert '![identifier length] ||' not in badge
print('CraneSB runningboardd + notification ABI contracts: PASS (runtime unverified)')
