/*
 * CRSecurityd.m — per-container keychain isolation.
 *
 * The request/result/access-group transformations below are transcribed from
 * CraneSupport 0x10834..0x11E5C.  The original first resolves five private
 * securityd symbols with MSFindSymbol and only falls back to patchfindSecurityd
 * when one is hidden.  This reconstruction implements the exact symbol-visible
 * path and refuses a partial install when any symbol is unavailable; the
 * original 0x11C08 patchfinder fallback remains a separate porting task.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <dlfcn.h>
#import <xpc/xpc.h>

#import "CRPaths.h"

extern void *MSGetImageByName(const char *name);
extern void *MSFindSymbol(void *image, const char *name);
extern void MSHookFunction(void *symbol, void *replace, void **result);

@interface ClientContainerCache : NSObject
+ (instancetype)sharedInstance;
- (NSString *)activeContainerIdentifierForPid:(pid_t)pid;
@end

/*
 * CraneSupport 0x10C1C/0x10D90 accesses only offsets 0 and 8: SecTaskRef and
 * the client's allowed access-group array.  Do not infer any later fields.
 */
typedef struct {
    CFTypeRef task;
    CFArrayRef accessGroups;
} CRSecurityClientInfo;

typedef int64_t (*CRSecItemCopyMatchingFn)(CFDictionaryRef query,
                                           CRSecurityClientInfo *clientInfo,
                                           CFTypeRef *result,
                                           CFErrorRef *error);
typedef int64_t (*CRSecItemAddFn)(CFDictionaryRef attributes,
                                  CRSecurityClientInfo *clientInfo,
                                  CFTypeRef *result,
                                  CFErrorRef *error);
typedef int64_t (*CRSecItemDeleteFn)(CFDictionaryRef query,
                                     CRSecurityClientInfo *clientInfo,
                                     CFErrorRef *error);
typedef int64_t (*CRSecItemUpdateFn)(CFDictionaryRef query,
                                     CFDictionaryRef attributes,
                                     CRSecurityClientInfo *clientInfo,
                                     CFErrorRef *error);
typedef void (*CRSecurityDXPCHandlerFn)(xpc_object_t connection,
                                        xpc_object_t message);
typedef pid_t (*CRSecurityXPCConnectionGetPidFn)(xpc_connection_t connection);
typedef CFStringRef (*CRSecuritySecTaskCopySigningIdentifierFn)(CFTypeRef task,
                                                                CFErrorRef *error);

static CRSecurityDXPCHandlerFn gSecurityDXPCHandlerOrig;
static CRSecItemCopyMatchingFn gSecItemCopyMatchingOrig;
static CRSecItemAddFn gSecItemAddOrig;
static CRSecItemDeleteFn gSecItemDeleteOrig;
static CRSecItemUpdateFn gSecItemUpdateOrig;

/* CraneSupport 0x12FF8: same 32-byte hook record and libhooker-first dispatch
 * used by the recovered main dylib. */
struct CRSecurityHookEntry {
    void *original;
    void *replacement;
    void **originalStorage;
    void *reserved;
};

_Static_assert(sizeof(struct CRSecurityHookEntry) == 32,
               "CRSecurityHookEntry must preserve recovered hook stride");

typedef int (*CRSecurityLHHookFunctionsFn)(
    const struct CRSecurityHookEntry *hooks, int count);

static int CRSecurityHookFunctions(struct CRSecurityHookEntry *hooks, int count)
{
    static CRSecurityLHHookFunctionsFn lhHookFunctions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lhHookFunctions = (CRSecurityLHHookFunctionsFn)
            dlsym(RTLD_DEFAULT, "__LHHookFunctions");
        if (!lhHookFunctions)
            lhHookFunctions = (CRSecurityLHHookFunctionsFn)
                dlsym(RTLD_DEFAULT, "LHHookFunctions");
    });

    if (lhHookFunctions)
        return lhHookFunctions(hooks, count);

    for (int i = 0; i < count; ++i)
        MSHookFunction(hooks[i].original, hooks[i].replacement,
                       hooks[i].originalStorage);
    return 0;
}

static NSString * const CRSecurityHostPidKey = @"hostPid";
static NSString * const CRSecurityUnrestrictKey = @"craneprefs_unrestrict";
static NSString * const CRSecuritySuffixMarker = @".c_r_a_n_e";

/* CraneSupport 0x62BC -> 0x62FC, byte-for-byte list also present in
 * CraneSB 0x1FA84 and CranePrefs 0x3E074. */
static NSSet<NSString *> *CRSecurityAccessGroupsToIgnore(void)
{
    static NSSet<NSString *> *set;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        set = [NSSet setWithObjects:
            @"com.apple.token",
            @"com.apple.certificates",
            @"com.apple.identities",
            @"apple",
            @"com.apple.cfnetwork",
            @"com.apple.ProtectedCloudStorage",
            @"com.apple.passd",
            @"com.apple.managed.vpn.shared",
            nil];
    });
    return set;
}

/* CraneSupport 0x10834 / 0x108B8. */
static NSString *CRSecurityContainerString(NSString *value, NSString *containerID)
{
    if (!value || !containerID)
        return nil;
    return [value stringByAppendingString:
        [@".c_r_a_n_e." stringByAppendingString:containerID]];
}

static NSString *CRSecurityUpdatedAccessGroup(NSString *accessGroup,
                                               NSString *oldContainer,
                                               NSString *newContainer)
{
    if (!accessGroup)
        return nil;
    if (!newContainer.length ||
        [oldContainer isEqualToString:newContainer])
        return accessGroup;

    BOOL oldIsDefault =
        [oldContainer isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER];
    BOOL newIsDefault =
        [newContainer isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER];

    NSString *base = accessGroup;

    if (newIsDefault) {
        if (oldContainer.length) {
            NSString *oldSuffix =
                [@".c_r_a_n_e." stringByAppendingString:oldContainer];
            return [base stringByReplacingOccurrencesOfString:oldSuffix
                                                   withString:@""];
        }
        NSRange marker = [base rangeOfString:CRSecuritySuffixMarker];
        return marker.location == NSNotFound
            ? base
            : [base substringToIndex:marker.location];
    }

    if (oldIsDefault) {
        NSRange marker = [base rangeOfString:CRSecuritySuffixMarker];
        if (marker.location != NSNotFound)
            base = [base substringToIndex:marker.location];
        return CRSecurityContainerString(base, newContainer);
    }

    if (oldContainer.length) {
        NSString *oldSuffix =
            [@".c_r_a_n_e." stringByAppendingString:oldContainer];
        NSString *newSuffix =
            [@".c_r_a_n_e." stringByAppendingString:newContainer];
        return [base stringByReplacingOccurrencesOfString:oldSuffix
                                               withString:newSuffix];
    }

    NSRange marker = [base rangeOfString:CRSecuritySuffixMarker];
    if (marker.location != NSNotFound)
        base = [base substringToIndex:marker.location];
    return CRSecurityContainerString(base, newContainer);
}

static CRSecuritySecTaskCopySigningIdentifierFn
CRSecurityCopySigningIdentifierFunction(void)
{
    static CRSecuritySecTaskCopySigningIdentifierFn function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        function = (CRSecuritySecTaskCopySigningIdentifierFn)
            dlsym(RTLD_DEFAULT, "SecTaskCopySigningIdentifier");
    });
    return function;
}

static CRSecurityXPCConnectionGetPidFn CRSecurityXPCGetPidFunction(void)
{
    static CRSecurityXPCConnectionGetPidFn function;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        function = (CRSecurityXPCConnectionGetPidFn)
            dlsym(RTLD_DEFAULT, "xpc_connection_get_pid");
    });
    return function;
}

/* Reconstruction-only device diagnostic. Log only when a live client's
 * PID/signing/container resolution changes, so normal SecItem traffic does not
 * flood the log. `container=<none>` means the hook ran but no non-default
 * container proof was available at that moment; it is not labeled DEFAULT. */
static void CRSecurityLogClientResolution(pid_t pid,
                                          NSString *signingID,
                                          NSString *containerID)
{
    if (pid <= 0)
        return;

    static NSMutableDictionary<NSNumber *, NSString *> *lastStateByPid;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lastStateByPid = [NSMutableDictionary new];
    });

    NSString *state = [NSString stringWithFormat:@"%@|%@",
        signingID ?: @"<unknown>", containerID ?: @"<none>"];
    @synchronized(lastStateByPid) {
        if ([lastStateByPid[@(pid)] isEqualToString:state])
            return;
        lastStateByPid[@(pid)] = state;
    }

    NSLog(@"CraneSupport: securityd client pid=%d signingID=%@ container=%@",
          pid, signingID ?: @"<unknown>", containerID ?: @"<none>");
}

/* CraneSupport 0x10C1C. */
static void CRSecurityFetchClientInfo(CRSecurityClientInfo *clientInfo,
                                      NSString **signingIdentifierOut,
                                      NSString **containerOut,
                                      pid_t *pidOut)
{
    NSNumber *hostPid =
        NSThread.currentThread.threadDictionary[CRSecurityHostPidKey];
    pid_t pid = [hostPid intValue];
    if (pidOut && hostPid)
        *pidOut = pid;

    NSString *signingID = nil;
    if (clientInfo && clientInfo->task) {
        CRSecuritySecTaskCopySigningIdentifierFn copySigningID =
            CRSecurityCopySigningIdentifierFunction();
        if (copySigningID) {
            CFStringRef copied = copySigningID(clientInfo->task, NULL);
            signingID = CFBridgingRelease(copied);
        }
    }
    if (signingIdentifierOut)
        *signingIdentifierOut = signingID;

    static NSSet<NSString *> *ignoredSigningIDs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ignoredSigningIDs =
            [NSSet setWithObjects:@"watchdogd", @"com.apple.springboard", nil];
    });

    if (containerOut && hostPid &&
        (!signingID || ![ignoredSigningIDs containsObject:signingID])) {
        *containerOut = [[ClientContainerCache sharedInstance]
            activeContainerIdentifierForPid:pid];
        CRSecurityLogClientResolution(pid, signingID, *containerOut);
    }
}

/* CraneSupport 0x10D90.  The original temporarily replaces the access-group
 * array in securityd's clientInfo structure and restores it after the private
 * SecItem routine returns. */
static CFArrayRef CRSecurityApplyClientInfoContainer(
    CRSecurityClientInfo *clientInfo, NSString *containerID)
{
    if (!clientInfo || !containerID.length ||
        [containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
        !clientInfo->accessGroups)
        return NULL;

    CFArrayRef original = clientInfo->accessGroups;
    CFMutableArrayRef updated =
        CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, original);
    if (!updated)
        return NULL;

    NSSet<NSString *> *ignored = CRSecurityAccessGroupsToIgnore();
    CFIndex count = CFArrayGetCount(original);
    for (CFIndex i = 0; i < count; ++i) {
        CFTypeRef value = CFArrayGetValueAtIndex(original, i);
        if (!value || CFGetTypeID(value) != CFStringGetTypeID() ||
            [ignored containsObject:(__bridge NSString *)value])
            continue;
        NSString *rewritten = CRSecurityUpdatedAccessGroup(
            (__bridge NSString *)value,
            CR_DEFAULT_CONTAINER_IDENTIFIER,
            containerID);
        if (rewritten)
            CFArraySetValueAtIndex(updated, i, (__bridge CFStringRef)rewritten);
    }

    clientInfo->accessGroups = updated;
    return original;
}

static void CRSecurityRestoreClientInfoAccessGroups(
    CRSecurityClientInfo *clientInfo, CFArrayRef original)
{
    if (!clientInfo || !original)
        return;
    CFArrayRef temporary = clientInfo->accessGroups;
    clientInfo->accessGroups = original;
    if (temporary)
        CFRelease(temporary);
}

/* CraneSupport 0x10EB0. */
static CFArrayRef CRSecurityUnrestrictClientInfo(
    CRSecurityClientInfo *clientInfo,
    CFDictionaryRef query,
    CFDictionaryRef attributes)
{
    if (!clientInfo || !clientInfo->accessGroups)
        return NULL;

    CFTypeRef queryGroup =
        query ? CFDictionaryGetValue(query, kSecAttrAccessGroup) : NULL;
    CFTypeRef attributeGroup =
        attributes ? CFDictionaryGetValue(attributes, kSecAttrAccessGroup) : NULL;
    if (!queryGroup && !attributeGroup)
        return NULL;

    CFArrayRef original = clientInfo->accessGroups;
    CFMutableArrayRef updated =
        CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, original);
    if (!updated)
        return NULL;

    if (queryGroup) {
        CFRange range = CFRangeMake(0, CFArrayGetCount(updated));
        if (!CFArrayContainsValue(updated, range, queryGroup))
            CFArrayAppendValue(updated, queryGroup);
    }
    if (attributeGroup) {
        CFRange range = CFRangeMake(0, CFArrayGetCount(updated));
        if (!CFArrayContainsValue(updated, range, attributeGroup))
            CFArrayAppendValue(updated, attributeGroup);
    }

    clientInfo->accessGroups = updated;
    return original;
}

static BOOL CRSecurityShouldUnrestrict(CFDictionaryRef dictionary)
{
    if (!dictionary)
        return NO;
    CFTypeRef value =
        CFDictionaryGetValue(dictionary, (__bridge CFStringRef)CRSecurityUnrestrictKey);
    return value && CFEqual(value, kCFBooleanTrue);
}

static CFMutableDictionaryRef
CRSecurityDictionaryWithoutUnrestrict(CFDictionaryRef dictionary)
{
    if (!dictionary)
        return NULL;
    CFMutableDictionaryRef copy =
        CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dictionary);
    if (copy)
        CFDictionaryRemoveValue(copy,
            (__bridge CFStringRef)CRSecurityUnrestrictKey);
    return copy;
}

/* CraneSupport 0x11034.  Returned object follows Create Rule so every caller
 * can unconditionally CFRelease it after the private SecItem invocation. */
static CFDictionaryRef CRSecurityDictionaryForContainer(
    CFDictionaryRef dictionary, NSString *containerID)
{
    if (!dictionary)
        return NULL;

    if (CFGetTypeID(dictionary) == CFDictionaryGetTypeID() &&
        containerID.length &&
        ![containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
        CFTypeRef value =
            CFDictionaryGetValue(dictionary, kSecAttrAccessGroup);
        if (value && CFGetTypeID(value) == CFStringGetTypeID() &&
            ![CRSecurityAccessGroupsToIgnore()
                containsObject:(__bridge NSString *)value]) {
            CFMutableDictionaryRef copy =
                CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dictionary);
            NSString *updated = CRSecurityUpdatedAccessGroup(
                (__bridge NSString *)value,
                CR_DEFAULT_CONTAINER_IDENTIFIER,
                containerID);
            if (copy && updated)
                CFDictionarySetValue(copy, kSecAttrAccessGroup,
                                     (__bridge CFStringRef)updated);
            return copy;
        }
    }

    CFRetain(dictionary);
    return dictionary;
}

/* CraneSupport 0x11130 / 0x111E4: hide Crane's suffix from application-visible
 * keychain results after securityd has matched the container-specific item. */
static CFDictionaryRef
CRSecurityApplicationDictionary(CFDictionaryRef dictionary)
{
    if (!dictionary)
        return NULL;

    if (CFGetTypeID(dictionary) == CFDictionaryGetTypeID()) {
        CFTypeRef value =
            CFDictionaryGetValue(dictionary, kSecAttrAccessGroup);
        if (value && CFGetTypeID(value) == CFStringGetTypeID()) {
            CFMutableDictionaryRef copy =
                CFDictionaryCreateMutableCopy(kCFAllocatorDefault, 0, dictionary);
            NSString *updated = CRSecurityUpdatedAccessGroup(
                (__bridge NSString *)value, nil,
                CR_DEFAULT_CONTAINER_IDENTIFIER);
            if (copy && updated)
                CFDictionarySetValue(copy, kSecAttrAccessGroup,
                                     (__bridge CFStringRef)updated);
            return copy;
        }
    }

    CFRetain(dictionary);
    return dictionary;
}

static void CRSecurityProcessResult(CFTypeRef *result)
{
    if (!result || !*result)
        return;

    CFTypeID type = CFGetTypeID(*result);
    if (type == CFDictionaryGetTypeID()) {
        CFTypeRef original = *result;
        *result = CRSecurityApplicationDictionary((CFDictionaryRef)original);
        CFRelease(original);
        return;
    }

    if (type == CFArrayGetTypeID()) {
        CFArrayRef original = (CFArrayRef)*result;
        CFMutableArrayRef updated =
            CFArrayCreateMutableCopy(kCFAllocatorDefault, 0, original);
        if (!updated)
            return;
        CFIndex count = CFArrayGetCount(original);
        for (CFIndex i = 0; i < count; ++i) {
            CFTypeRef value = CFArrayGetValueAtIndex(original, i);
            if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID())
                continue;
            CFDictionaryRef applicationValue =
                CRSecurityApplicationDictionary((CFDictionaryRef)value);
            if (applicationValue) {
                CFArraySetValueAtIndex(updated, i, applicationValue);
                CFRelease(applicationValue);
            }
        }
        *result = updated;
        CFRelease(original);
    }
}

static BOOL CRSecurityIsHelperUnrestrictedCaller(NSString *signingID,
                                                  CFDictionaryRef query)
{
    return signingID.length &&
        [signingID hasPrefix:@"cranehelperd"] &&
        CRSecurityShouldUnrestrict(query);
}

static int64_t CRSecItemCopyMatchingHook(
    CFDictionaryRef query, CRSecurityClientInfo *clientInfo,
    CFTypeRef *result, CFErrorRef *error)
{
    NSString *signingID = nil;
    NSString *containerID = nil;
    CRSecurityFetchClientInfo(clientInfo, &signingID, &containerID, NULL);

    if (containerID.length) {
        CFDictionaryRef rewritten =
            CRSecurityDictionaryForContainer(query, containerID);
        CFArrayRef oldGroups =
            CRSecurityApplyClientInfoContainer(clientInfo, containerID);
        int64_t status =
            gSecItemCopyMatchingOrig(rewritten, clientInfo, result, error);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        if (!error || !*error)
            CRSecurityProcessResult(result);
        if (rewritten)
            CFRelease(rewritten);
        return status;
    }

    if (query &&
        CRSecurityIsHelperUnrestrictedCaller(signingID, query)) {
        CFArrayRef oldGroups =
            CRSecurityUnrestrictClientInfo(clientInfo, query, NULL);
        CFMutableDictionaryRef clean =
            CRSecurityDictionaryWithoutUnrestrict(query);
        int64_t status =
            gSecItemCopyMatchingOrig(clean ?: query, clientInfo, result, error);
        if (clean)
            CFRelease(clean);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        return status;
    }

    return gSecItemCopyMatchingOrig(query, clientInfo, result, error);
}

static int64_t CRSecItemAddHook(
    CFDictionaryRef attributes, CRSecurityClientInfo *clientInfo,
    CFTypeRef *result, CFErrorRef *error)
{
    NSString *signingID = nil;
    NSString *containerID = nil;
    CRSecurityFetchClientInfo(clientInfo, &signingID, &containerID, NULL);

    if (containerID.length) {
        CFDictionaryRef rewritten =
            CRSecurityDictionaryForContainer(attributes, containerID);
        CFArrayRef oldGroups =
            CRSecurityApplyClientInfoContainer(clientInfo, containerID);
        int64_t status =
            gSecItemAddOrig(rewritten, clientInfo, result, error);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        if (!error || !*error)
            CRSecurityProcessResult(result);
        if (rewritten)
            CFRelease(rewritten);
        return status;
    }

    if (attributes &&
        CRSecurityIsHelperUnrestrictedCaller(signingID, attributes)) {
        CFArrayRef oldGroups =
            CRSecurityUnrestrictClientInfo(clientInfo, NULL, attributes);
        CFMutableDictionaryRef clean =
            CRSecurityDictionaryWithoutUnrestrict(attributes);
        int64_t status =
            gSecItemAddOrig(clean ?: attributes, clientInfo, result, error);
        if (clean)
            CFRelease(clean);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        return status;
    }

    return gSecItemAddOrig(attributes, clientInfo, result, error);
}

static int64_t CRSecItemDeleteHook(
    CFDictionaryRef query, CRSecurityClientInfo *clientInfo,
    CFErrorRef *error)
{
    NSString *signingID = nil;
    NSString *containerID = nil;
    CRSecurityFetchClientInfo(clientInfo, &signingID, &containerID, NULL);

    if (containerID.length) {
        CFDictionaryRef rewritten =
            CRSecurityDictionaryForContainer(query, containerID);
        CFArrayRef oldGroups =
            CRSecurityApplyClientInfoContainer(clientInfo, containerID);
        int64_t status =
            gSecItemDeleteOrig(rewritten, clientInfo, error);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        if (rewritten)
            CFRelease(rewritten);
        return status;
    }

    if (query &&
        CRSecurityIsHelperUnrestrictedCaller(signingID, query)) {
        CFArrayRef oldGroups =
            CRSecurityUnrestrictClientInfo(clientInfo, query, NULL);
        CFMutableDictionaryRef clean =
            CRSecurityDictionaryWithoutUnrestrict(query);
        int64_t status =
            gSecItemDeleteOrig(clean ?: query, clientInfo, error);
        if (clean)
            CFRelease(clean);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        return status;
    }

    return gSecItemDeleteOrig(query, clientInfo, error);
}

static int64_t CRSecItemUpdateHook(
    CFDictionaryRef query, CFDictionaryRef attributes,
    CRSecurityClientInfo *clientInfo, CFErrorRef *error)
{
    NSString *signingID = nil;
    NSString *containerID = nil;
    CRSecurityFetchClientInfo(clientInfo, &signingID, &containerID, NULL);

    if (containerID.length) {
        CFDictionaryRef rewrittenQuery =
            CRSecurityDictionaryForContainer(query, containerID);
        CFDictionaryRef rewrittenAttributes =
            CRSecurityDictionaryForContainer(attributes, containerID);
        CFArrayRef oldGroups =
            CRSecurityApplyClientInfoContainer(clientInfo, containerID);
        int64_t status = gSecItemUpdateOrig(
            rewrittenQuery, rewrittenAttributes, clientInfo, error);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        if (rewrittenQuery)
            CFRelease(rewrittenQuery);
        if (rewrittenAttributes)
            CFRelease(rewrittenAttributes);
        return status;
    }

    if (query &&
        CRSecurityIsHelperUnrestrictedCaller(signingID, query)) {
        CFArrayRef oldGroups =
            CRSecurityUnrestrictClientInfo(clientInfo, query, attributes);
        CFMutableDictionaryRef clean =
            CRSecurityDictionaryWithoutUnrestrict(query);
        int64_t status = gSecItemUpdateOrig(
            clean ?: query, attributes, clientInfo, error);
        if (clean)
            CFRelease(clean);
        CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups);
        return status;
    }

    return gSecItemUpdateOrig(query, attributes, clientInfo, error);
}

/* CraneSupport 0x112D8. */
static void CRSecurityDXPCHandlerHook(xpc_object_t connection,
                                      xpc_object_t message)
{
    if (!connection) {
        gSecurityDXPCHandlerOrig(NULL, message);
        return;
    }

    if (xpc_get_type(connection) != XPC_TYPE_CONNECTION)
        return;

    CRSecurityXPCConnectionGetPidFn getPid =
        CRSecurityXPCGetPidFunction();
    if (!getPid) {
        gSecurityDXPCHandlerOrig(connection, message);
        return;
    }

    pid_t pid = getPid((xpc_connection_t)connection);
    NSMutableDictionary *threadDictionary =
        NSThread.currentThread.threadDictionary;
    threadDictionary[CRSecurityHostPidKey] = @(pid);
    @try {
        gSecurityDXPCHandlerOrig(connection, message);
    } @finally {
        [threadDictionary removeObjectForKey:CRSecurityHostPidKey];
    }
}

void CRInstallSecuritydHooks(void)
{
    void *image = MSGetImageByName("/usr/libexec/securityd");
    if (!image) {
        NSLog(@"CraneSupport: securityd keychain isolation unavailable reason=no_image");
        return;
    }

    void *xpcHandler =
        MSFindSymbol(image, "_securityd_xpc_dictionary_handler");
    void *copyMatching =
        MSFindSymbol(image, "__SecItemCopyMatching");
    void *add =
        MSFindSymbol(image, "__SecItemAdd");
    void *deleteItem =
        MSFindSymbol(image, "__SecItemDelete");
    void *update =
        MSFindSymbol(image, "__SecItemUpdate");

    /*
     * Original 0x11E5C invokes patchfindSecurityd only when one of these five
     * symbols is hidden.  Never install only a subset: that would allow reads,
     * writes, deletes, or updates to escape the same container policy.
     */
    if (!xpcHandler || !copyMatching || !add || !deleteItem || !update) {
        NSLog(@"CraneSupport: securityd keychain isolation unavailable reason=missing_private_symbols xpc=%d copy=%d add=%d delete=%d update=%d",
              xpcHandler != NULL, copyMatching != NULL, add != NULL,
              deleteItem != NULL, update != NULL);
        return;
    }

    struct CRSecurityHookEntry hooks[5] = {
        { xpcHandler, (void *)CRSecurityDXPCHandlerHook,
          (void **)&gSecurityDXPCHandlerOrig, NULL },
        { copyMatching, (void *)CRSecItemCopyMatchingHook,
          (void **)&gSecItemCopyMatchingOrig, NULL },
        { add, (void *)CRSecItemAddHook,
          (void **)&gSecItemAddOrig, NULL },
        { deleteItem, (void *)CRSecItemDeleteHook,
          (void **)&gSecItemDeleteOrig, NULL },
        { update, (void *)CRSecItemUpdateHook,
          (void **)&gSecItemUpdateOrig, NULL },
    };
    int hookStatus = CRSecurityHookFunctions(hooks, 5);
    NSLog(@"CraneSupport: securityd keychain isolation hooks=5 status=%d",
          hookStatus);
}
