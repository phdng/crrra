/*
 * CRApsd.m — CraneSupport apsd / per-container push token isolation.
 *
 * Transcribed from CraneSupport:
 *   APS helper fallbacks                         0x8670 / 0x8740 / 0x8854
 *   apsd_notificationSupportEnabled              0x8D90
 *   fetchTopicHash                               0x8E1C
 *   topicStorage helpers                         0x92C0..0x9618
 *   handleAppTokenGenerateResponseHook           0x96C8
 *   handleMessageMessageHook                     0x989C
 *   initApsd                                     0x9C4C
 *   APSCourierConnection / Courier wrappers      0x9F84..0xA9F4
 *
 * ApplePushService implementation classes and helper symbols are all resolved
 * dynamically, matching the original binary.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdint.h>
#import <stdlib.h>

#import "CRManager.h"
#import "CRPreferences.h"
#import "CRCommon.h"

@interface NSObject (CraneApsdRuntime)
- (id)delegate;
- (id)mainCourier;
- (id)environment;
- (id)domain;
- (id)topic;
- (id)identifier;
- (id)crane_topicStorage;
- (void)setCrane_topicStorage:(id)storage;
- (id)deserializedPersistedData:(id)data
                       withType:(uint64_t)type
              outPersistedInfo:(void *)info;
- (void)verifyCraneSBLoadedAndReply:(void (^)(BOOL loaded))reply;
@end

@interface CraneManager (CraneApsdPrivate)
- (void)runSafeXPCBlock:(dispatch_block_t)block;
@end

typedef NSData *(*CraneAPSCopyHashForStringFn)(NSString *string);
typedef NSMutableString *(*CraneAPSCopyStringRepresentationFn)(NSData *data);
typedef unsigned char *(*CraneCCSHA1Fn)(const void *data,
                                       unsigned int length,
                                       unsigned char *digest);

static CraneAPSCopyHashForStringFn gCraneAPSCopyHashForString;
static CraneAPSCopyStringRepresentationFn gCraneAPSCopyStringRepresentation;
static CFStringRef *gCraneAPSBundleIdentifier;

/* ------------------------------------------------------------------------- */
/* APS helper fallbacks                                                      */
/* ------------------------------------------------------------------------- */

static NSData *CraneAPSCopyHashForStringFallback(NSString *string)
{
    NSData *data = [string dataUsingEncoding:NSUTF8StringEncoding];
    if (!data)
        return nil;

    static CraneCCSHA1Fn sha1;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        sha1 = (CraneCCSHA1Fn)dlsym(RTLD_DEFAULT, "CC_SHA1");
    });
    if (!sha1)
        return nil;

    unsigned char digest[20] = {0};
    sha1(data.bytes, (unsigned int)data.length, digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}

static NSMutableString *CraneAPSCopyStringRepresentationFallback(NSData *data)
{
    const signed char *bytes = data.bytes;
    NSUInteger length = data.length;
    NSMutableString *result =
        [[NSMutableString alloc] initWithCapacity:length * 2];

    for (NSUInteger index = 0; index < length; index++) {
        /*
         * Preserve the recovered signed-char formatting. Negative bytes are
         * promoted and may render as "ffffffXX"; dataForStringRepresentation
         * explicitly knows how to decode that form.
         */
        [result appendFormat:@"%02x", (unsigned int)(int)bytes[index]];
    }
    return result;
}

static NSMutableData *CraneApsdDataForStringRepresentation(NSString *string)
{
    NSMutableData *result = [NSMutableData new];
    NSMutableString *remaining = [string mutableCopy];

    while (remaining.length) {
        BOOL hadSignExtension = [remaining hasPrefix:@"ffffff"];
        if (hadSignExtension)
            [remaining deleteCharactersInRange:NSMakeRange(0, 6)];

        if (remaining.length < 2)
            break;

        NSString *pair = [remaining substringWithRange:NSMakeRange(0, 2)];
        [remaining deleteCharactersInRange:NSMakeRange(0, 2)];

        unsigned value = 0;
        NSScanner *scanner = [NSScanner scannerWithString:pair];
        [scanner scanHexInt:&value];
        unsigned char byte = (unsigned char)(value & 0xFF);

        if (hadSignExtension) {
            NSData *one = [NSData dataWithBytes:&byte length:1];
            NSString *representation =
                gCraneAPSCopyStringRepresentation
                    ? gCraneAPSCopyStringRepresentation(one)
                    : CraneAPSCopyStringRepresentationFallback(one);
            if (representation.length == 2) {
                const unsigned char prefix[3] = {0xFF, 0xFF, 0xFF};
                [result appendBytes:prefix length:sizeof(prefix)];
            }
        }

        [result appendBytes:&byte length:1];
    }

    return result;
}

static NSString *CraneApsdHexStringForData(NSData *data)
{
    const unsigned char *bytes = data.bytes;
    if (!bytes)
        return @"";

    NSMutableString *result =
        [NSMutableString stringWithCapacity:data.length * 2];
    for (NSUInteger index = 0; index < data.length; index++)
        [result appendFormat:@"%02lx", (unsigned long)bytes[index]];
    return [NSString stringWithString:result];
}

static NSData *CraneApsdDataForHexString(NSString *string)
{
    NSUInteger byteCount = string.length / 2;
    unsigned char *bytes = malloc(byteCount);
    if (!bytes && byteCount)
        return nil;

    for (NSUInteger index = 0; index < byteCount; index++) {
        NSString *pair =
            [string substringWithRange:NSMakeRange(index * 2, 2)];
        bytes[index] = (unsigned char)strtoul(pair.UTF8String, NULL, 16);
    }

    return [NSData dataWithBytesNoCopy:bytes
                                length:byteCount
                          freeWhenDone:YES];
}

/* ------------------------------------------------------------------------- */
/* Topic helpers / storage                                                   */
/* ------------------------------------------------------------------------- */

static BOOL CraneApsdNotificationSupportEnabled(void)
{
    id value =
        [[CraneManager sharedManager]
            preferenceValueForKey:CRPref_NotificationsSupportEnabled];
    return value ? [value boolValue] : YES;
}

static BOOL CraneApsdIsCraneTopic(NSString *topic)
{
    return [topic containsString:@".c_r_a_n_e."];
}

static void CraneApsdDecodeCraneTopic(NSString *topic,
                                      NSString **baseTopic,
                                      NSString **containerIdentifier)
{
    if (!topic)
        return;

    NSArray *parts =
        [topic componentsSeparatedByString:@".c_r_a_n_e."];
    if (baseTopic)
        *baseTopic = parts.firstObject;
    if (containerIdentifier)
        *containerIdentifier = parts.lastObject;
}

static NSString *CraneApsdTopicStorageKey(NSData *uncranedHash,
                                          uint16_t appId)
{
    return [NSString stringWithFormat:@"%@/%hu",
                                      CraneApsdHexStringForData(uncranedHash),
                                      appId];
}

static void CraneApsdDecodeTopicStorageKey(NSString *key,
                                           NSData **uncranedHash,
                                           uint16_t *appId)
{
    if (!key)
        return;

    NSArray *parts = [key componentsSeparatedByString:@"/"];
    if (uncranedHash)
        *uncranedHash = CraneApsdDataForHexString(parts.firstObject);

    if (appId) {
        NSNumberFormatter *formatter = [NSNumberFormatter new];
        formatter.numberStyle = NSNumberFormatterDecimalStyle;
        NSNumber *value = [formatter numberFromString:parts.lastObject];
        *appId = value.unsignedShortValue;
    }
}

static NSData *CraneApsdTopicStorageGetCranedHash(
    NSMutableDictionary *storage,
    uint16_t appId,
    NSData *uncranedHash)
{
    return storage[CraneApsdTopicStorageKey(uncranedHash, appId)];
}

static NSData *CraneApsdTopicStorageGetUncranedHash(
    NSMutableDictionary *storage,
    NSData *cranedHash)
{
    NSString *key = [[storage allKeysForObject:cranedHash] firstObject];
    NSData *uncraned = nil;
    CraneApsdDecodeTopicStorageKey(key, &uncraned, NULL);
    return uncraned;
}

static void CraneApsdTopicStorageWritePair(NSMutableDictionary *storage,
                                           uint16_t appId,
                                           NSData *uncranedHash,
                                           NSData *cranedHash)
{
    if (!storage || !uncranedHash || !cranedHash)
        return;
    storage[CraneApsdTopicStorageKey(uncranedHash, appId)] = cranedHash;
}

static void CraneApsdTopicStorageRemovePair(NSMutableDictionary *storage,
                                            uint16_t appId,
                                            NSData *uncranedHash)
{
    [storage removeObjectForKey:
        CraneApsdTopicStorageKey(uncranedHash, appId)];
}

static id CraneApsdTopicStorageGetter(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self,
                                    (const void *)&CraneApsdTopicStorageGetter);
}

static void CraneApsdTopicStorageSetter(id self, SEL _cmd, id storage)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             (const void *)&CraneApsdTopicStorageGetter,
                             storage,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSMutableDictionary *CraneApsdEnsureTopicStorage(id courier)
{
    NSMutableDictionary *storage = [courier crane_topicStorage];
    if (!storage) {
        storage = [NSMutableDictionary new];
        [courier setCrane_topicStorage:storage];
    }
    return storage;
}

/* ------------------------------------------------------------------------- */
/* Token-store / keychain topic lookup                                       */
/* ------------------------------------------------------------------------- */

static NSMutableData *CraneApsdFetchTopicHash(NSString *domain,
                                              NSData *token,
                                              id courier)
{
    if (!domain || !token || !gCraneAPSBundleIdentifier ||
        !*gCraneAPSBundleIdentifier) {
        return nil;
    }

    NSString *service =
        [NSString stringWithFormat:@"%@%@", domain, @",PerAppToken.v0"];

    NSMutableDictionary *query = [NSMutableDictionary dictionary];
    query[(__bridge id)kSecClass] = (__bridge id)kSecClassGenericPassword;
    query[(__bridge id)kSecAttrAccessGroup] =
        (__bridge id)*gCraneAPSBundleIdentifier;
    query[(__bridge id)kSecAttrService] = service;
    query[(__bridge id)kSecMatchLimit] = (__bridge id)kSecMatchLimitAll;
    query[(__bridge id)kSecReturnAttributes] = @YES;
    query[(__bridge id)kSecReturnPersistentRef] = @YES;
    query[(__bridge id)kSecReturnData] = @YES;

    CFTypeRef rawResult = NULL;
    OSStatus status =
        SecItemCopyMatching((__bridge CFDictionaryRef)query, &rawResult);
    if (status != errSecSuccess || !rawResult)
        return nil;

    id result = CFBridgingRelease(rawResult);
    if (![result isKindOfClass:[NSArray class]])
        return nil;

    NSMutableData *topicHash = nil;
    for (NSDictionary *entry in (NSArray *)result) {
        NSData *persisted = entry[@"v_Data"];
        NSData *decoded = persisted;

        if (kCFCoreFoundationVersionNumber >= 2000.0) {
            id tokenStore = [courier valueForKey:@"_tokenStore"];
            if ([tokenStore
                    respondsToSelector:
                        NSSelectorFromString(
                            @"deserializedPersistedData:withType:outPersistedInfo:")]) {
                decoded =
                    [tokenStore deserializedPersistedData:persisted
                                                 withType:0
                                        outPersistedInfo:NULL];
            }
        }

        if (![decoded isEqual:token])
            continue;

        NSString *account = entry[(__bridge id)kSecAttrAccount];
        NSString *representation =
            [[account componentsSeparatedByString:@","] lastObject];
        NSMutableData *candidate =
            CraneApsdDataForStringRepresentation(representation);
        if (candidate)
            topicHash = candidate;
    }

    return topicHash;
}

/* ------------------------------------------------------------------------- */
/* CraneSB-loaded gate                                                       */
/* ------------------------------------------------------------------------- */

static BOOL CraneApsdCraneSBLoaded(void)
{
    CraneManager *manager = [CraneManager sharedManager];
    __block BOOL loaded = NO;

    dispatch_block_t check = ^{
        id proxy = [manager cranehelperdGlobalSyncRemoteObjectProxy];
        SEL selector = NSSelectorFromString(@"verifyCraneSBLoadedAndReply:");
        if (!proxy || ![proxy respondsToSelector:selector])
            return;

        void (^reply)(BOOL) = ^(BOOL value) {
            loaded = value;
        };
        ((void (*)(id, SEL, id))objc_msgSend)(proxy, selector, reply);
    };

    SEL safeSelector = NSSelectorFromString(@"runSafeXPCBlock:");
    if ([manager respondsToSelector:safeSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(manager,
                                               safeSelector,
                                               check);
    } else {
        check();
    }

    return loaded;
}

/* ------------------------------------------------------------------------- */
/* Shared response / incoming-message transforms                             */
/* ------------------------------------------------------------------------- */

typedef void (^CraneApsdDictionaryContinuation)(NSDictionary *dictionary);

static void CraneApsdHandleAppTokenGenerateResponse(
    id courier,
    NSDictionary *response,
    CraneApsdDictionaryContinuation continuation)
{
    if (!continuation)
        return;

    if (!CraneApsdNotificationSupportEnabled()) {
        continuation(response);
        return;
    }

    NSData *topicHash =
        response[@"APSProtocolAppTokenGenerateResponseTopicHash"];
    NSNumber *appIdNumber =
        response[@"APSProtocolAppTokenGenerateResponseAppId"];
    if (!topicHash || !appIdNumber) {
        continuation(response);
        return;
    }

    uint16_t appId = appIdNumber.unsignedShortValue;
    NSMutableDictionary *storage = [courier crane_topicStorage];
    NSData *cranedHash =
        CraneApsdTopicStorageGetCranedHash(storage, appId, topicHash);
    if (!cranedHash) {
        continuation(response);
        return;
    }

    NSMutableDictionary *updated = [response mutableCopy];
    updated[@"APSProtocolAppTokenGenerateResponseTopicHash"] = cranedHash;
    CraneApsdTopicStorageRemovePair(storage, appId, topicHash);
    continuation(updated);
}

static void CraneApsdHandleMessage(
    id courier,
    NSDictionary *message,
    CraneApsdDictionaryContinuation continuation)
{
    if (!continuation)
        return;

    if (!CraneApsdNotificationSupportEnabled() ||
        !CraneApsdCraneSBLoaded()) {
        continuation(message);
        return;
    }

    NSData *token = message[@"APSProtocolToken"];
    NSString *domain = [[courier environment] domain];
    NSData *topicHash = message[@"APSProtocolTopicHash"];
    if (!topicHash) {
        continuation(message);
        return;
    }

    NSMutableData *actualTopicHash =
        CraneApsdFetchTopicHash(domain, token, courier);
    if (!actualTopicHash || [actualTopicHash isEqual:topicHash]) {
        continuation(message);
        return;
    }

    NSMutableDictionary *updated = [message mutableCopy];
    updated[@"APSProtocolTopicHash"] = actualTopicHash;
    continuation([updated copy]);
}

/* ------------------------------------------------------------------------- */
/* Hook wrappers                                                             */
/* ------------------------------------------------------------------------- */

static IMP gOrigSendAppTokenGenerate;
static IMP gOrigSendTokenGenerate;
static IMP gOrigRequestPerAppToken;
static IMP gOrigRequestTokenForInfo;
static IMP gOrigAppTokenResponseInterface;
static IMP gOrigAppTokenResponseProtocolConnection;
static IMP gOrigMessageProtocolConnection;
static IMP gOrigMessageInterfaceWaking;
static IMP gOrigMessageInterfaceAgent;
static IMP gOrigMessageInterfaceMaster;

static NSMutableDictionary *CraneApsdStorageForTokenConnection(id connection)
{
    id delegate = [connection delegate];
    Class courierClass = NSClassFromString(@"APSCourier");
    if (courierClass && [delegate isKindOfClass:courierClass])
        return [delegate crane_topicStorage];

    id delegateDelegate = [delegate delegate];
    id mainCourier = [delegateDelegate mainCourier];
    return [mainCourier crane_topicStorage];
}

static void CraneApsdSendAppTokenGenerate(
    id self,
    SEL _cmd,
    NSData *topicHash,
    id baseToken,
    uint64_t appId,
    id interface)
{
    NSData *effectiveHash = topicHash;
    if (CraneApsdNotificationSupportEnabled()) {
        NSMutableDictionary *storage =
            [[self delegate] crane_topicStorage];
        NSData *uncraned =
            CraneApsdTopicStorageGetUncranedHash(storage, topicHash);
        if (uncraned)
            effectiveHash = uncraned;
    }

    void (*original)(id, SEL, id, id, uint64_t, id) =
        (void (*)(id, SEL, id, id, uint64_t, id))
            gOrigSendAppTokenGenerate;
    original(self, _cmd, effectiveHash, baseToken, appId, interface);
}

static void CraneApsdSendTokenGenerate(
    id self,
    SEL _cmd,
    NSData *topicHash,
    id baseToken,
    uint64_t appId,
    uint64_t expirationTTL,
    id vapidPublicKeyHash,
    uint64_t type,
    id interface)
{
    NSData *effectiveHash = topicHash;
    if (CraneApsdNotificationSupportEnabled()) {
        NSMutableDictionary *storage =
            CraneApsdStorageForTokenConnection(self);
        NSData *uncraned =
            CraneApsdTopicStorageGetUncranedHash(storage, topicHash);
        if (uncraned)
            effectiveHash = uncraned;
    }

    void (*original)(id, SEL, id, id, uint64_t, uint64_t, id, uint64_t, id) =
        (void (*)(id, SEL, id, id, uint64_t, uint64_t, id, uint64_t, id))
            gOrigSendTokenGenerate;
    original(self,
             _cmd,
             effectiveHash,
             baseToken,
             appId,
             expirationTTL,
             vapidPublicKeyHash,
             type,
             interface);
}

static void CraneApsdRequestPerAppToken(id self,
                                        SEL _cmd,
                                        id connection,
                                        NSString *topic,
                                        NSString *identifier)
{
    if (CraneApsdNotificationSupportEnabled()) {
        NSMutableDictionary *storage = CraneApsdEnsureTopicStorage(self);

        if (CraneApsdIsCraneTopic(topic)) {
            NSString *baseTopic = nil;
            CraneApsdDecodeCraneTopic(topic, &baseTopic, NULL);

            NSData *identifierHash =
                gCraneAPSCopyHashForString
                    ? gCraneAPSCopyHashForString(identifier)
                    : CraneAPSCopyHashForStringFallback(identifier);
            uint16_t appId = 0;
            [identifierHash getBytes:&appId length:sizeof(appId)];

            NSData *cranedHash =
                gCraneAPSCopyHashForString
                    ? gCraneAPSCopyHashForString(topic)
                    : CraneAPSCopyHashForStringFallback(topic);
            NSData *uncranedHash =
                gCraneAPSCopyHashForString
                    ? gCraneAPSCopyHashForString(baseTopic)
                    : CraneAPSCopyHashForStringFallback(baseTopic);

            CraneApsdTopicStorageWritePair(storage,
                                           appId,
                                           uncranedHash,
                                           cranedHash);
        }
    }

    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gOrigRequestPerAppToken;
    original(self, _cmd, connection, topic, identifier);
}

static void CraneApsdRequestTokenForInfo(id self,
                                         SEL _cmd,
                                         id connection,
                                         id info)
{
    if (CraneApsdNotificationSupportEnabled()) {
        NSMutableDictionary *storage = CraneApsdEnsureTopicStorage(self);
        NSString *topic = [info topic];

        if (CraneApsdIsCraneTopic(topic)) {
            NSString *baseTopic = nil;
            CraneApsdDecodeCraneTopic(topic, &baseTopic, NULL);

            NSString *identifier = [info identifier];
            NSData *identifierHash =
                gCraneAPSCopyHashForString
                    ? gCraneAPSCopyHashForString(identifier)
                    : CraneAPSCopyHashForStringFallback(identifier);
            uint16_t appId = 0;
            [identifierHash getBytes:&appId length:sizeof(appId)];

            NSData *cranedHash =
                gCraneAPSCopyHashForString
                    ? gCraneAPSCopyHashForString(topic)
                    : CraneAPSCopyHashForStringFallback(topic);
            NSData *uncranedHash =
                gCraneAPSCopyHashForString
                    ? gCraneAPSCopyHashForString(baseTopic)
                    : CraneAPSCopyHashForStringFallback(baseTopic);

            CraneApsdTopicStorageWritePair(storage,
                                           appId,
                                           uncranedHash,
                                           cranedHash);
        }
    }

    void (*original)(id, SEL, id, id) =
        (void (*)(id, SEL, id, id))gOrigRequestTokenForInfo;
    original(self, _cmd, connection, info);
}

static void CraneApsdAppTokenResponseInterface(id self,
                                               SEL _cmd,
                                               NSDictionary *response,
                                               id interface)
{
    CraneApsdHandleAppTokenGenerateResponse(
        self,
        response,
        ^(NSDictionary *rewritten) {
            void (*original)(id, SEL, id, id) =
                (void (*)(id, SEL, id, id))
                    gOrigAppTokenResponseInterface;
            original(self, _cmd, rewritten, interface);
        });
}

static void CraneApsdAppTokenResponseProtocolConnection(
    id self,
    SEL _cmd,
    NSDictionary *response,
    id protocolConnection)
{
    CraneApsdHandleAppTokenGenerateResponse(
        self,
        response,
        ^(NSDictionary *rewritten) {
            void (*original)(id, SEL, id, id) =
                (void (*)(id, SEL, id, id))
                    gOrigAppTokenResponseProtocolConnection;
            original(self, _cmd, rewritten, protocolConnection);
        });
}

static void CraneApsdMessageProtocolConnection(id self,
                                               SEL _cmd,
                                               NSDictionary *message,
                                               id protocolConnection,
                                               uint64_t generation,
                                               BOOL isWakingMessage,
                                               BOOL fromAgent)
{
    CraneApsdHandleMessage(
        self,
        message,
        ^(NSDictionary *rewritten) {
            void (*original)(id, SEL, id, id, uint64_t, BOOL, BOOL) =
                (void (*)(id, SEL, id, id, uint64_t, BOOL, BOOL))
                    gOrigMessageProtocolConnection;
            original(self,
                     _cmd,
                     rewritten,
                     protocolConnection,
                     generation,
                     isWakingMessage,
                     fromAgent);
        });
}

static void CraneApsdMessageInterfaceWaking(id self,
                                            SEL _cmd,
                                            NSDictionary *message,
                                            id interface,
                                            uint64_t generation,
                                            BOOL isWakingMessage,
                                            BOOL fromAgent)
{
    CraneApsdHandleMessage(
        self,
        message,
        ^(NSDictionary *rewritten) {
            void (*original)(id, SEL, id, id, uint64_t, BOOL, BOOL) =
                (void (*)(id, SEL, id, id, uint64_t, BOOL, BOOL))
                    gOrigMessageInterfaceWaking;
            original(self,
                     _cmd,
                     rewritten,
                     interface,
                     generation,
                     isWakingMessage,
                     fromAgent);
        });
}

static void CraneApsdMessageInterfaceAgent(id self,
                                           SEL _cmd,
                                           NSDictionary *message,
                                           id interface,
                                           uint64_t generation,
                                           BOOL fromAgent)
{
    CraneApsdHandleMessage(
        self,
        message,
        ^(NSDictionary *rewritten) {
            void (*original)(id, SEL, id, id, uint64_t, BOOL) =
                (void (*)(id, SEL, id, id, uint64_t, BOOL))
                    gOrigMessageInterfaceAgent;
            original(self,
                     _cmd,
                     rewritten,
                     interface,
                     generation,
                     fromAgent);
        });
}

static void CraneApsdMessageInterfaceMaster(id self,
                                            SEL _cmd,
                                            NSDictionary *message,
                                            id interface,
                                            uint64_t generation,
                                            BOOL fromMaster)
{
    CraneApsdHandleMessage(
        self,
        message,
        ^(NSDictionary *rewritten) {
            void (*original)(id, SEL, id, id, uint64_t, BOOL) =
                (void (*)(id, SEL, id, id, uint64_t, BOOL))
                    gOrigMessageInterfaceMaster;
            original(self,
                     _cmd,
                     rewritten,
                     interface,
                     generation,
                     fromMaster);
        });
}

/* ------------------------------------------------------------------------- */
/* initApsd 0x9C4C                                                          */
/* ------------------------------------------------------------------------- */

void CRInitApsd(void)
{
    void *apsdImage =
        dlopen("/System/Library/PrivateFrameworks/ApplePushService.framework/apsd",
               RTLD_NOW);
    if (apsdImage) {
        gCraneAPSCopyHashForString =
            (CraneAPSCopyHashForStringFn)
                dlsym(apsdImage, "APSCopyHashForString");
        gCraneAPSCopyStringRepresentation =
            (CraneAPSCopyStringRepresentationFn)
                dlsym(apsdImage, "APSCopyStringRepresentationOfData");
    }

    if (!gCraneAPSCopyHashForString)
        gCraneAPSCopyHashForString = CraneAPSCopyHashForStringFallback;
    if (!gCraneAPSCopyStringRepresentation)
        gCraneAPSCopyStringRepresentation =
            CraneAPSCopyStringRepresentationFallback;

    void *apsFramework =
        dlopen("/System/Library/PrivateFrameworks/ApplePushService.framework/ApplePushService",
               RTLD_NOW);
    if (apsFramework) {
        gCraneAPSBundleIdentifier =
            (CFStringRef *)dlsym(apsFramework, "APSBundleIdentifier");
    }

    Class connectionClass =
        NSClassFromString(@"APSCourierConnection");
    if (connectionClass) {
        MSHookMessageEx(
            connectionClass,
            NSSelectorFromString(
                @"sendAppTokenGenerateMessageWithTopicHash:baseToken:appId:onInterface:"),
            (IMP)CraneApsdSendAppTokenGenerate,
            &gOrigSendAppTokenGenerate);
        MSHookMessageEx(
            connectionClass,
            NSSelectorFromString(
                @"sendTokenGenerateMessageWithTopicHash:baseToken:appId:"
                 "expirationTTL:vapidPublicKeyHash:type:onInterface:"),
            (IMP)CraneApsdSendTokenGenerate,
            &gOrigSendTokenGenerate);
    }

    Class courierClass = NSClassFromString(@"APSCourier");
    Class userCourierClass = NSClassFromString(@"APSUserCourier");
    if (userCourierClass)
        courierClass = userCourierClass;
    if (!courierClass)
        return;

    objc_property_attribute_t attributes[] = {
        { "T", "@\"NSMutableDictionary\"" },
        { "&", "" },
        { "N", "" },
    };
    class_addProperty(courierClass,
                      "crane_topicStorage",
                      attributes,
                      3);
    class_addMethod(courierClass,
                    NSSelectorFromString(@"crane_topicStorage"),
                    (IMP)CraneApsdTopicStorageGetter,
                    "@@:");
    class_addMethod(courierClass,
                    NSSelectorFromString(@"setCrane_topicStorage:"),
                    (IMP)CraneApsdTopicStorageSetter,
                    "v@:@");

    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(
            @"connection:didRequestPerAppTokenForTopic:identifier:"),
        (IMP)CraneApsdRequestPerAppToken,
        &gOrigRequestPerAppToken);
    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(@"connection:didRequestTokenForInfo:"),
        (IMP)CraneApsdRequestTokenForInfo,
        &gOrigRequestTokenForInfo);
    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(@"_handleAppTokenGenerateResponse:onInterface:"),
        (IMP)CraneApsdAppTokenResponseInterface,
        &gOrigAppTokenResponseInterface);
    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(
            @"_handleAppTokenGenerateResponse:onProtocolConnection:"),
        (IMP)CraneApsdAppTokenResponseProtocolConnection,
        &gOrigAppTokenResponseProtocolConnection);
    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(
            @"_handleMessageMessage:onProtocolConnection:withGeneration:"
             "isWakingMessage:fromAgent:"),
        (IMP)CraneApsdMessageProtocolConnection,
        &gOrigMessageProtocolConnection);
    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(
            @"_handleMessageMessage:onInterface:withGeneration:"
             "isWakingMessage:fromAgent:"),
        (IMP)CraneApsdMessageInterfaceWaking,
        &gOrigMessageInterfaceWaking);
    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(
            @"_handleMessageMessage:onInterface:withGeneration:fromAgent:"),
        (IMP)CraneApsdMessageInterfaceAgent,
        &gOrigMessageInterfaceAgent);
    MSHookMessageEx(
        courierClass,
        NSSelectorFromString(
            @"_handleMessageMessage:onInterface:withGeneration:fromMaster:"),
        (IMP)CraneApsdMessageInterfaceMaster,
        &gOrigMessageInterfaceMaster);
}
