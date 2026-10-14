/*
 * CRManager.m — CraneManager, the shared client API of libcrane.dylib.
 *
 * SCOPE AND HONESTY NOTE
 * ----------------------
 * The original /usr/lib/libcrane.dylib has NO IDA export directory (see
 * analysis/environment_report.md section 5). What follows is therefore a
 * reconstruction, not a transcription:
 *
 *   * The METHOD SELECTORS are CONFIRMED_STATIC - each one is observed being
 *     sent to CraneManager from the four exported binaries, or present in
 *     libcrane's own __TEXT,__objc_methname. See
 *     analysis/symbols_and_selectors.md section 3a for the complete list.
 *   * The CONTAINER PATH is CONFIRMED_STATIC - "%@/Library/___Crane_Containers/%@".
 *   * The PREFERENCE DOMAIN is CONFIRMED_STATIC - com.opa334.craneprefs, from
 *     Root.plist and libCrane.plist.
 *   * EVERYTHING ELSE is INFERRED: the container-identifier format, the
 *     metadata file format, the supported-application heuristic, the Game
 *     Center plumbing, the keychain dump format and the archive layout are not
 *     recoverable from the available evidence. They are marked [INFERRED]
 *     below and tracked as U-04 / U-06 in analysis/uncertainty_register.md.
 *
 * A consequence worth stating plainly: containers written by THIS build are
 * not guaranteed to be readable by Crane 6.0, and vice versa.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <limits.h>
#import <objc/message.h>
#import <objc/runtime.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"
#import "CRContainerScaffold.h"
#import "CRContainerRegistry.h"
#import "CRGameCenterAccounts.h"
#import "CRXPCDiagnostics.h"
#import "CRXPCProtocols.h"

/* The native launch gate classifies transport errors through getLastError. */
@interface CraneManager (CRHelperTransportDiagnostics)
- (void)crane_recordHelperTransportError:(NSError *)error;
@end

static NSString *const CRHelperReplyErrorContext = @"com.opa334.crane.helper.replyError";

static void CRManagerRecordHelperTransportError(NSError *error)
{
    [[CraneManager sharedManager] crane_recordHelperTransportError:error];
}

/* Recovered callers fetch getLastError synchronously inside their reply.
 * Scope it to this request so a concurrent badge lookup cannot clear the
 * launch error. Restore the context after nested callbacks, including throws. */
static void CRManagerDeliverHelperReply(NSError *error, dispatch_block_t reply)
{
    CRManagerRecordHelperTransportError(error);
    NSMutableDictionary *context = NSThread.currentThread.threadDictionary;
    id previous = context[CRHelperReplyErrorContext];
    context[CRHelperReplyErrorContext] = error ?: NSNull.null;
    @try { reply(); }
    @finally {
        if (previous) context[CRHelperReplyErrorContext] = previous;
        else [context removeObjectForKey:CRHelperReplyErrorContext];
    }
}

#include <notify.h>
#include <xpc/xpc.h>
/* Match the private symbol spelling used by the reconstructed helperd;
 * the public iOS SDK marks this Mach-service entrypoint unavailable. */
extern xpc_connection_t CRManagerXPCConnectionCreateMachService(
    const char *name, dispatch_queue_t targetq, uint64_t flags)
    __asm("_xpc_connection_create_mach_service");

typedef void (^CRManagerPIDLookupReply)(NSString *containerID, BOOL connectionWorks);

typedef BOOL (^CRManagerXPCUnsandboxHandler)(void);

@interface CraneManager (CRXPCUnsandboxInternal)
- (BOOL)crane_prepareXPCUnsandbox;
@end

static xpc_connection_t CRManagerCreateHelperConnection(void)
{
    CraneManager *manager = [CraneManager sharedManager];
    if (![manager crane_prepareXPCUnsandbox]) {
        NSLog(@"CraneManager: helper XPC unsandbox handler refused connection");
        return NULL;
    }
    return CRManagerXPCConnectionCreateMachService(
        CR_HELPERD_MACH_SERVICE.UTF8String, NULL,
        XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
}

static void CRManagerLookupActiveContainerForPid(pid_t pid,
                                                  CRManagerPIDLookupReply reply)
{
    if (!reply)
        return;
    if (pid <= 0) {
        NSError *error = CRHelperTransportError(CRHelperInvalidPID,
            @"lookup_pid", @"Target PID is invalid");
        CRManagerDeliverHelperReply(error, ^{ reply(nil, NO); });
        return;
    }

    xpc_connection_t connection = CRManagerCreateHelperConnection();
    if (!connection) {
        NSError *error = CRHelperTransportError(CRHelperConnectionCreationFailed,
            @"lookup_pid", @"Unable to create XPC connection");
        CRManagerDeliverHelperReply(error, ^{ reply(nil, NO); });
        return;
    }

    NSObject *replyLock = [NSObject new];
    __block BOOL finished = NO;
    void (^finish)(NSString *, BOOL, NSError *) =
        ^(NSString *containerID, BOOL connectionWorks, NSError *error) {
        @synchronized(replyLock) {
            if (finished)
                return;
            finished = YES;
        }
        if (error) NSLog(@"CraneManager: helper lookup_pid target=%d error=%@", pid, error);
        CRManagerDeliverHelperReply(error, ^{ reply(containerID, connectionWorks); });
        xpc_connection_cancel(connection);
    };

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
            finish(nil, NO, CRHelperXPCEventError(event, @"lookup_pid"));
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (!request) {
        finish(nil, NO, CRHelperTransportError(CRHelperRequestAllocationFailed,
            @"lookup_pid", @"Unable to allocate XPC request"));
        return;
    }
    xpc_dictionary_set_string(request, "operation", "lookup_pid");
    xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    xpc_dictionary_set_int64(request, "pid", pid);
    xpc_connection_send_message_with_reply(connection, request,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t response) {
            NSError *error = nil;
            BOOL valid = CRHelperValidateHealthReply(response, @"lookup_pid", &error);
            BOOL authorized = valid &&
                xpc_dictionary_get_bool(response, "authorized");
            BOOL injected = authorized &&
                xpc_dictionary_get_bool(response, "injection_verified");
            const char *container = injected
                ? xpc_dictionary_get_string(response, "container_id") : NULL;
            NSString *containerID = container
                ? [NSString stringWithUTF8String:container] : nil;
            NSLog(@"CraneManager: helper lookup_pid target=%d authorized=%d injected=%d container=%@",
                  pid, authorized, injected, containerID);

            /* CraneSB 0x19608: second reply argument is 1 when helperd
             * answered but the app dylib/container proof is missing; 0 means
             * the daemon path itself failed. */
            if (valid && !authorized)
                error = CRHelperTransportError(CRHelperUnauthorizedPeer, @"lookup_pid",
                    @"Helper rejected caller identity");
            finish(containerID, authorized, error);
        });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            finish(nil, NO, CRHelperTransportError(CRHelperReplyTimedOut,
                @"lookup_pid", @"No helper reply within 2 seconds"));
        });
}

static void CRManagerVerifyRuntimeComponent(NSString *component,
                                            NSString *process,
                                            void (^reply)(BOOL loaded))
{
    if (!reply || !component.length)
        return;

    xpc_connection_t connection = CRManagerCreateHelperConnection();
    if (!connection) {
        reply(NO);
        return;
    }

    NSObject *replyLock = [NSObject new];
    __block BOOL finished = NO;
    void (^finish)(BOOL) = ^(BOOL loaded) {
        @synchronized(replyLock) {
            if (finished)
                return;
            finished = YES;
        }
        reply(loaded);
        xpc_connection_cancel(connection);
    };
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
            finish(NO);
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (!request) {
        finish(NO);
        return;
    }
    xpc_dictionary_set_string(request, "operation", "component_loaded");
    xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    xpc_dictionary_set_string(request, "component", component.UTF8String);
    if (process.length)
        xpc_dictionary_set_string(request, "process", process.UTF8String);
    xpc_connection_send_message_with_reply(connection, request,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t response) {
            BOOL valid = xpc_get_type(response) == XPC_TYPE_DICTIONARY;
            const char *version = valid
                ? xpc_dictionary_get_string(response, "protocol") : NULL;
            valid = valid && version &&
                strcmp(version, CR_HELPERD_PING_PROTOCOL_V1) == 0 &&
                xpc_dictionary_get_bool(response, "alive") &&
                xpc_dictionary_get_bool(response, "authorized");
            finish(valid && xpc_dictionary_get_bool(response, "loaded"));
        });
    /* Every component-health lookup, including pkd and apsd, must finish
     * even if helperd silently drops the message. finish() is single-shot
     * and cancels the raw-XPC connection on timeout. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)(2 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        finish(NO);
    });
}

/* ------------------------------------------------------------------------- */
typedef void (^CRManagerControlRequestBuilder)(xpc_object_t request);

/* Fixed-purpose privileged operations use the same authenticated raw-XPC
 * transport as health/fix-up, but keep synchronous proxy semantics because
 * original callers use cranehelperdGlobalSyncRemoteObjectProxy. */
static BOOL CRManagerSendSynchronousControlRequest(
    NSString *operation,
    CRManagerControlRequestBuilder configure,
    NSTimeInterval timeout,
    NSError **outError)
{
    if (outError)
        *outError = nil;
    if (!operation.length) {
        if (outError) {
            *outError = CRHelperTransportError(CRHelperUnexpectedReply,
                @"control", @"Missing helper operation");
        }
        return NO;
    }

    xpc_connection_t connection = CRManagerCreateHelperConnection();
    if (!connection) {
        if (outError) {
            *outError = CRHelperTransportError(CRHelperConnectionCreationFailed,
                operation, @"Unable to create XPC connection");
        }
        return NO;
    }

    NSObject *lock = [NSObject new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL finished = NO;
    __block BOOL operationSuccess = NO;
    __block NSError *resultError = nil;

    void (^finish)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        @synchronized(lock) {
            if (finished)
                return;
            finished = YES;
            operationSuccess = success;
            resultError = error;
        }
        dispatch_semaphore_signal(done);
    };

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
            finish(NO, CRHelperXPCEventError(event, operation));
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (!request) {
        resultError = CRHelperTransportError(CRHelperRequestAllocationFailed,
            operation, @"Unable to allocate XPC request");
        xpc_connection_cancel(connection);
        if (outError)
            *outError = resultError;
        return NO;
    }
    xpc_dictionary_set_string(request, "operation", operation.UTF8String);
    xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    if (configure)
        configure(request);

    xpc_connection_send_message_with_reply(
        connection, request,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^(xpc_object_t response) {
            NSError *error = nil;
            BOOL valid = CRHelperValidateHealthReply(response, operation, &error);
            BOOL authorized = valid &&
                xpc_dictionary_get_bool(response, "authorized");
            BOOL success = authorized &&
                xpc_dictionary_get_bool(response, "success");
            if (valid && !authorized) {
                error = CRHelperTransportError(CRHelperUnauthorizedPeer,
                    operation, @"Helper rejected caller identity");
            } else if (valid && authorized && !success) {
                const char *descriptionCString =
                    xpc_dictionary_get_string(response, "error_description");
                NSString *description = descriptionCString
                    ? [NSString stringWithUTF8String:descriptionCString]
                    : @"Privileged helper operation failed";
                error = CRHelperTransportError(CRHelperUnexpectedReply,
                    operation, description);
            }
            finish(success, error);
        });

    int64_t timeoutNanos = (int64_t)(MAX(timeout, 0.1) * NSEC_PER_SEC);
    long waitResult = dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, timeoutNanos));
    if (waitResult != 0) {
        finish(NO, CRHelperTransportError(CRHelperReplyTimedOut,
            operation, @"No helper reply before timeout"));
    }

    BOOL result;
    NSError *error;
    @synchronized(lock) {
        result = operationSuccess && resultError == nil;
        error = resultError;
    }
    xpc_connection_cancel(connection);
    if (outError)
        *outError = error;
    return result;
}

typedef id (^CRManagerQueryReplyParser)(xpc_object_t response);

static id CRManagerSendSynchronousQueryRequest(
    NSString *operation,
    CRManagerControlRequestBuilder configure,
    CRManagerQueryReplyParser parser,
    NSTimeInterval timeout,
    NSError **outError)
{
    if (outError)
        *outError = nil;
    if (!operation.length || !parser) {
        if (outError) {
            *outError = CRHelperTransportError(CRHelperUnexpectedReply,
                @"query", @"Missing helper query contract");
        }
        return nil;
    }

    xpc_connection_t connection = CRManagerCreateHelperConnection();
    if (!connection) {
        if (outError) {
            *outError = CRHelperTransportError(CRHelperConnectionCreationFailed,
                operation, @"Unable to create XPC connection");
        }
        return nil;
    }

    NSObject *lock = [NSObject new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL finished = NO;
    __block id result = nil;
    __block NSError *resultError = nil;

    void (^finish)(id, NSError *) = ^(id value, NSError *error) {
        @synchronized(lock) {
            if (finished)
                return;
            finished = YES;
            result = value;
            resultError = error;
        }
        dispatch_semaphore_signal(done);
    };

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
            finish(nil, CRHelperXPCEventError(event, operation));
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (!request) {
        resultError = CRHelperTransportError(CRHelperRequestAllocationFailed,
            operation, @"Unable to allocate XPC request");
        xpc_connection_cancel(connection);
        if (outError)
            *outError = resultError;
        return nil;
    }
    xpc_dictionary_set_string(request, "operation", operation.UTF8String);
    xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    if (configure)
        configure(request);

    xpc_connection_send_message_with_reply(
        connection, request,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
        ^(xpc_object_t response) {
            NSError *error = nil;
            BOOL valid = CRHelperValidateHealthReply(response, operation, &error);
            BOOL authorized = valid &&
                xpc_dictionary_get_bool(response, "authorized");
            BOOL success = authorized &&
                xpc_dictionary_get_bool(response, "success");
            if (valid && !authorized) {
                error = CRHelperTransportError(CRHelperUnauthorizedPeer,
                    operation, @"Helper rejected caller identity");
            } else if (valid && authorized && !success) {
                const char *descriptionCString =
                    xpc_dictionary_get_string(response, "error_description");
                NSString *description = descriptionCString
                    ? [NSString stringWithUTF8String:descriptionCString]
                    : @"Helper query failed";
                error = CRHelperTransportError(CRHelperUnexpectedReply,
                    operation, description);
            }
            finish(valid && authorized && success ? parser(response) : nil, error);
        });

    int64_t timeoutNanos = (int64_t)(MAX(timeout, 0.1) * NSEC_PER_SEC);
    long waitResult = dispatch_semaphore_wait(
        done, dispatch_time(DISPATCH_TIME_NOW, timeoutNanos));
    if (waitResult != 0) {
        finish(nil, CRHelperTransportError(CRHelperReplyTimedOut,
            operation, @"No helper reply before timeout"));
    }

    id finalResult;
    NSError *error;
    @synchronized(lock) {
        finalResult = result;
        error = resultError;
    }
    xpc_connection_cancel(connection);
    if (outError)
        *outError = error;
    return finalResult;
}

/* CraneManager                                                               */
/* ------------------------------------------------------------------------- */

/* Authenticated helper adapter. Health queries remain read-only; only the
 * fixed-purpose original reload selectors are exposed as privileged controls. */
@interface CRInsuranceHealthProxy : NSObject
- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL, NSArray<NSString *> *, NSError *))reply;
- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name
                                      reply:(void (^)(BOOL))reply;
- (void)verifyCraneSBLoadedAndReply:(void (^)(BOOL))reply;
- (void)runInjectionFixUpIfNeededAndReply:(void (^)(BOOL, NSError *))reply;
- (void)verifyCraneSupportLoadedIntoDaemon:(NSString *)daemon
                                      reply:(void (^)(BOOL))reply;
- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                           reply:(void (^)(NSString *, BOOL))reply;
- (void)reloadApplication:(NSString *)appID;
- (void)reloadDaemons:(NSArray<NSString *> *)daemons;
- (void)moveKeychainItemsFromContainerWithIdentifier:(NSString *)sourceContainer
                           toContainerWithIdentifier:(NSString *)destinationContainer
                        forApplicationWithIdentifier:(NSString *)appID
                                              reply:(void (^)(BOOL success))reply;
- (void)deleteKeychainItemsForContainerWithIdentifier:(NSString *)containerID
                             forApplicationIdentifier:(NSString *)appID;
- (void)getDisplayNameOfApplicationWithIdentifier:(NSString *)appID
                                             reply:(void (^)(NSString *))reply;
- (void)getIdentifiersOfAllSupportedApplicationsAndReply:(void (^)(NSArray<NSString *> *))reply;
- (void)checkIsApplicationWithIdentifier:(NSString *)appID
                     supportedByCraneAndReply:(void (^)(BOOL))reply;
- (void)readDeviceVendorIdentifierFromApplicationWithIdentifier:(NSString *)appID
                                                          reply:(void (^)(NSString *))reply;
- (void)writeDeviceVendorIdentifier:(NSString *)identifier
          toApplicationWithIdentifier:(NSString *)appID;
@end
@implementation CRInsuranceHealthProxy
- (void)verifyCraneInsuranceAndReply:(void (^)(BOOL, NSArray<NSString *> *, NSError *))reply
{
    if (!reply)
        return;

    xpc_connection_t connection = CRManagerCreateHelperConnection();
    if (!connection) {
        NSError *error = CRHelperTransportError(CRHelperConnectionCreationFailed,
            @"insurance", @"Unable to create XPC connection");
        CRManagerDeliverHelperReply(error, ^{ reply(NO, @[@"cranehelperd"], error); });
        return;
    }

    NSObject *replyLock = [NSObject new];
    __block BOOL finished = NO;
    void (^finish)(BOOL, NSArray<NSString *> *, NSError *) =
        ^(BOOL works, NSArray<NSString *> *brokenDaemons, NSError *error) {
            @synchronized(replyLock) {
                if (finished)
                    return;
                finished = YES;
            }
            BOOL connectionWorks = error == nil;
            NSString *brokenString = [brokenDaemons componentsJoinedByString:@", "];
            NSLog(@"CraneManager: helper insurance works=%d connection=%d broken=%@ error=%@",
                  works, connectionWorks, brokenString, error);
            /* Original CraneSB 0x1BAA4 reply ABI is exactly
             * (BOOL success, brokenDaemons, NSError *error). Transport state is
             * consumed separately through CraneManager getLastError. */
            CRManagerDeliverHelperReply(error, ^{
                reply(works, brokenDaemons, error);
            });
            xpc_connection_cancel(connection);
        };

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
            finish(NO, @[@"cranehelperd"], CRHelperXPCEventError(event, @"insurance"));
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (!request) {
        finish(NO, @[@"cranehelperd"], CRHelperTransportError(CRHelperRequestAllocationFailed,
            @"insurance", @"Unable to allocate XPC request"));
        return;
    }
    xpc_dictionary_set_string(request, "operation", "insurance");
    xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    xpc_connection_send_message_with_reply(connection, request,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t response) {
            NSError *error = nil;
            BOOL valid = CRHelperValidateHealthReply(response, @"insurance", &error);

            BOOL injectionVerified = valid &&
                xpc_dictionary_get_bool(response, "injection_verified");
            BOOL supportInspectionAvailable = valid &&
                xpc_dictionary_get_bool(response, "support_inspection_available");
            BOOL supportComplete = valid &&
                xpc_dictionary_get_bool(response, "support_complete");
            BOOL works = valid && xpc_dictionary_get_bool(response, "works") &&
                injectionVerified && supportComplete;

            if (valid) {
                BOOL fixupAttempted =
                    xpc_dictionary_get_bool(response, "fixup_attempted");
                BOOL fixupInProgress =
                    xpc_dictionary_get_bool(response, "fixup_in_progress");
                BOOL fixupSuccess =
                    xpc_dictionary_get_bool(response, "fixup_success");
                const char *fixupProcessCString =
                    xpc_dictionary_get_string(response, "fixup_process");
                const char *fixupBackendCString =
                    xpc_dictionary_get_string(response, "fixup_backend");
                const char *fixupTransitionsCString =
                    xpc_dictionary_get_string(response, "fixup_transitions");
                const char *fixupErrorCString =
                    xpc_dictionary_get_string(response, "fixup_error_description");
                const char *backendInventoryCString =
                    xpc_dictionary_get_string(response, "fixup_backend_inventory");
                NSString *fixupProcess = fixupProcessCString
                    ? [NSString stringWithUTF8String:fixupProcessCString] : nil;
                NSString *fixupBackend = fixupBackendCString
                    ? [NSString stringWithUTF8String:fixupBackendCString] : nil;
                NSString *fixupTransitions = fixupTransitionsCString
                    ? [NSString stringWithUTF8String:fixupTransitionsCString] : nil;
                NSString *fixupError = fixupErrorCString
                    ? [NSString stringWithUTF8String:fixupErrorCString] : nil;
                NSString *backendInventory = backendInventoryCString
                    ? [NSString stringWithUTF8String:backendInventoryCString] : nil;
                int64_t fixupErrorCode =
                    xpc_dictionary_get_int64(response, "fixup_error_code");
                NSLog(@"CraneManager: helper injection fixup state attempted=%d inProgress=%d success=%d process=%@ backend=%@ transitions=%@ errorCode=%lld error=%@ backends=%@",
                      fixupAttempted, fixupInProgress, fixupSuccess,
                      fixupProcess, fixupBackend, fixupTransitions,
                      fixupErrorCode, fixupError, backendInventory);
            }

            NSMutableArray *broken = [NSMutableArray new];
            if (valid && !xpc_dictionary_get_bool(response, "main_dylib_installed"))
                [broken addObject:@"Crane.dylib"];
            if (valid && !xpc_dictionary_get_bool(response, "libsandy_loaded"))
                [broken addObject:@"libsandy"];
            if (valid && !injectionVerified)
                [broken addObject:@"CraneSB"];
            if (valid && !supportComplete) {
                const char *brokenCString =
                    xpc_dictionary_get_string(response, "broken_daemons");
                NSString *brokenSupport = brokenCString
                    ? [NSString stringWithUTF8String:brokenCString] : nil;
                if (brokenSupport.length)
                    [broken addObjectsFromArray:
                        [brokenSupport componentsSeparatedByString:@", "]];
                else if (!supportInspectionAvailable)
                    [broken addObject:@"CraneSupport verification"];
                else
                    [broken addObject:@"CraneSupport"];

                /* Reconstruction-only read-only helper diagnostic. This is
                 * never consulted when calculating works; it only exposes
                 * the mapped CraneSupport/injection stack when insurance fails. */
                const char *imageMapCString =
                    xpc_dictionary_get_string(response, "support_image_map");
                NSString *imageMap = imageMapCString
                    ? [NSString stringWithUTF8String:imageMapCString] : nil;
                if (imageMap.length)
                    NSLog(@"CraneManager: helper support image map %@", imageMap);
            }
            if (!valid)
                [broken addObject:@"cranehelperd"];
            finish(works, [broken copy], error);
        });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            finish(NO, @[@"cranehelperd"], CRHelperTransportError(CRHelperReplyTimedOut,
                @"insurance", @"No helper reply within 2 seconds"));
        });
}

- (void)verifySupportLoadedIntoProcessNamed:(NSString *)name
                                      reply:(void (^)(BOOL))reply
{
    CRManagerVerifyRuntimeComponent(@"CraneSupport", name, reply);
}

- (void)verifyCraneSBLoadedAndReply:(void (^)(BOOL))reply
{
    /* CraneSupport 0x9B68 asks specifically whether SpringBoard-side CraneSB
     * is live before rewriting incoming APS traffic. */
    CRManagerVerifyRuntimeComponent(@"CraneSB", @"SpringBoard", reply);
}

- (void)runInjectionFixUpIfNeededAndReply:(void (^)(BOOL, NSError *))reply
{
    if (!reply)
        return;

    xpc_connection_t connection = CRManagerCreateHelperConnection();
    if (!connection) {
        NSError *error = CRHelperTransportError(CRHelperConnectionCreationFailed,
            @"injection_fixup", @"Unable to create XPC connection");
        CRManagerDeliverHelperReply(error, ^{ reply(NO, error); });
        return;
    }

    NSObject *replyLock = [NSObject new];
    __block BOOL finished = NO;
    void (^finish)(BOOL, NSError *) = ^(BOOL success, NSError *error) {
        @synchronized(replyLock) {
            if (finished)
                return;
            finished = YES;
        }
        NSLog(@"CraneManager: helper injection fixup success=%d error=%@",
              success, error);
        CRManagerDeliverHelperReply(error, ^{ reply(success, error); });
        xpc_connection_cancel(connection);
    };

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
            finish(NO, CRHelperXPCEventError(event, @"injection_fixup"));
    });
    xpc_connection_resume(connection);

    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (!request) {
        finish(NO, CRHelperTransportError(CRHelperRequestAllocationFailed,
            @"injection_fixup", @"Unable to allocate XPC request"));
        return;
    }

    xpc_dictionary_set_string(request, "operation", "injection_fixup");
    xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
    xpc_connection_send_message_with_reply(connection, request,
        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^(xpc_object_t response) {
            NSError *error = nil;
            BOOL valid = CRHelperValidateHealthReply(
                response, @"injection_fixup", &error);
            BOOL authorized = valid &&
                xpc_dictionary_get_bool(response, "authorized");
            BOOL success = authorized &&
                xpc_dictionary_get_bool(response, "success");

            if (valid && !authorized) {
                error = CRHelperTransportError(CRHelperUnauthorizedPeer,
                    @"injection_fixup",
                    @"Helper rejected caller identity");
            } else if (valid && authorized && !success) {
                const char *domainCString =
                    xpc_dictionary_get_string(response, "error_domain");
                const char *descriptionCString =
                    xpc_dictionary_get_string(response, "error_description");
                NSString *domain = domainCString
                    ? [NSString stringWithUTF8String:domainCString]
                    : @"cranehelperdErrorDomain";
                NSString *description = descriptionCString
                    ? [NSString stringWithUTF8String:descriptionCString]
                    : @"CraneSupport injection fix-up failed";
                NSInteger code = (NSInteger)
                    xpc_dictionary_get_int64(response, "error_code");
                error = [NSError errorWithDomain:domain
                    code:code userInfo:@{NSLocalizedDescriptionKey: description}];
            }

            NSLog(@"CraneManager: helper injection fixup authorized=%d success=%d error=%@",
                  authorized, success, error);
            finish(success, error);
        });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                       (int64_t)(30 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        finish(NO, CRHelperTransportError(CRHelperReplyTimedOut,
            @"injection_fixup", @"No helper fix-up reply within 30 seconds"));
    });
}

/* CraneSB 0x11CA4 expects a synchronous reply from its "sync" proxy.
 * This reconstruction's raw-XPC component check is asynchronous, so bridge
 * it with a bounded wait; never turn a timeout/error into proof of injection.
 * Only pkd and apsd are allowed: these are the two recovered CraneSB
 * notification registration gates 0x11CA4 and 0x11E44. */
- (void)verifyCraneSupportLoadedIntoDaemon:(NSString *)daemon
                                      reply:(void (^)(BOOL))reply
{
    if (!reply)
        return;
    if (![daemon isEqualToString:@"pkd"] &&
        ![daemon isEqualToString:@"apsd"]) {
        reply(NO);
        return;
    }
    NSObject *lock = [NSObject new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block BOOL finished = NO;
    __block BOOL loaded = NO;
    CRManagerVerifyRuntimeComponent(@"CraneSupport", daemon, ^(BOOL value) {
        @synchronized(lock) {
            if (finished)
                return;
            loaded = value;
            finished = YES;
            dispatch_semaphore_signal(done);
        }
    });
    /* Allow the underlying two-second raw-XPC deadline to deliver its
     * fail-closed callback before this outer synchronous wait expires. */
    long wait = dispatch_semaphore_wait(done,
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)));
    BOOL result = NO;
    @synchronized(lock) {
        result = (wait == 0 && loaded);
        finished = YES; /* A late callback cannot alter the result. */
    }
    reply(result);
}

- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                           reply:(void (^)(NSString *, BOOL))reply
{
    CRManagerLookupActiveContainerForPid(pid, reply);
}

- (void)reloadApplication:(NSString *)appID
{
    if (!appID.length)
        return;
    NSError *error = nil;
    BOOL success = CRManagerSendSynchronousControlRequest(
        @"reload_application",
        ^(xpc_object_t request) {
            xpc_dictionary_set_string(
                request, "application_id", appID.UTF8String);
        },
        3.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    NSLog(@"CraneManager: helper reload application=%@ success=%d error=%@",
          appID, success, error);
}

- (void)reloadDaemons:(NSArray<NSString *> *)daemons
{
    NSArray<NSString *> *requested =
        [daemons isKindOfClass:NSArray.class] ? daemons : @[];
    NSError *error = nil;
    BOOL success = CRManagerSendSynchronousControlRequest(
        @"reload_daemons",
        ^(xpc_object_t request) {
            xpc_object_t values = xpc_array_create(NULL, 0);
            for (id value in requested) {
                if (![value isKindOfClass:NSString.class] || ![value length])
                    continue;
                xpc_object_t item =
                    xpc_string_create([(NSString *)value UTF8String]);
                if (item)
                    xpc_array_append_value(values, item);
            }
            xpc_dictionary_set_value(request, "daemons", values);
        },
        5.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    NSLog(@"CraneManager: helper reload daemons=%@ success=%d error=%@",
          requested, success, error);
}

- (void)moveKeychainItemsFromContainerWithIdentifier:(NSString *)sourceContainer
                           toContainerWithIdentifier:(NSString *)destinationContainer
                        forApplicationWithIdentifier:(NSString *)appID
                                              reply:(void (^)(BOOL success))reply
{
    if (!sourceContainer.length || !destinationContainer.length || !appID.length) {
        if (reply)
            reply(NO);
        return;
    }

    NSError *error = nil;
    BOOL success = CRManagerSendSynchronousControlRequest(
        @"move_keychain_items",
        ^(xpc_object_t request) {
            xpc_dictionary_set_string(
                request, "application_id", appID.UTF8String);
            xpc_dictionary_set_string(
                request, "source_container_id", sourceContainer.UTF8String);
            xpc_dictionary_set_string(
                request, "destination_container_id",
                destinationContainer.UTF8String);
        },
        5.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    NSLog(@"CraneManager: helper move keychain app=%@ source=%@ destination=%@ success=%d error=%@",
          appID, sourceContainer, destinationContainer, success, error);
    if (reply)
        reply(success);
}

- (void)deleteKeychainItemsForContainerWithIdentifier:(NSString *)containerID
                             forApplicationIdentifier:(NSString *)appID
{
    if (!containerID.length || !appID.length)
        return;

    NSError *error = nil;
    BOOL success = CRManagerSendSynchronousControlRequest(
        @"delete_keychain_items",
        ^(xpc_object_t request) {
            xpc_dictionary_set_string(
                request, "application_id", appID.UTF8String);
            xpc_dictionary_set_string(
                request, "container_id", containerID.UTF8String);
        },
        5.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    NSLog(@"CraneManager: helper delete keychain app=%@ container=%@ success=%d error=%@",
          appID, containerID, success, error);
}

- (void)getDisplayNameOfApplicationWithIdentifier:(NSString *)appID
                                             reply:(void (^)(NSString *))reply
{
    if (!reply)
        return;
    if (!appID.length) {
        reply(nil);
        return;
    }
    NSError *error = nil;
    NSString *name = CRManagerSendSynchronousQueryRequest(
        @"get_application_display_name",
        ^(xpc_object_t request) {
            xpc_dictionary_set_string(
                request, "application_id", appID.UTF8String);
        },
        ^id(xpc_object_t response) {
            const char *value =
                xpc_dictionary_get_string(response, "display_name");
            return value ? [NSString stringWithUTF8String:value] : nil;
        },
        3.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    reply([name isKindOfClass:NSString.class] ? name : nil);
}

- (void)getIdentifiersOfAllSupportedApplicationsAndReply:
    (void (^)(NSArray<NSString *> *))reply
{
    if (!reply)
        return;
    NSError *error = nil;
    NSArray *identifiers = CRManagerSendSynchronousQueryRequest(
        @"get_supported_application_ids",
        nil,
        ^id(xpc_object_t response) {
            xpc_object_t values =
                xpc_dictionary_get_value(response, "application_ids");
            if (!values || xpc_get_type(values) != XPC_TYPE_ARRAY)
                return nil;
            NSMutableArray<NSString *> *result = [NSMutableArray new];
            xpc_array_apply(values, ^bool(size_t index, xpc_object_t value) {
                (void)index;
                if (xpc_get_type(value) != XPC_TYPE_STRING)
                    return true;
                const char *string = xpc_string_get_string_ptr(value);
                NSString *identifier = string
                    ? [NSString stringWithUTF8String:string] : nil;
                if (identifier.length)
                    [result addObject:identifier];
                return true;
            });
            return [result copy];
        },
        4.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    reply([identifiers isKindOfClass:NSArray.class] ? identifiers : nil);
}

- (void)checkIsApplicationWithIdentifier:(NSString *)appID
                     supportedByCraneAndReply:(void (^)(BOOL))reply
{
    if (!reply)
        return;
    if (!appID.length) {
        reply(NO);
        return;
    }
    NSError *error = nil;
    NSNumber *supported = CRManagerSendSynchronousQueryRequest(
        @"check_application_supported",
        ^(xpc_object_t request) {
            xpc_dictionary_set_string(
                request, "application_id", appID.UTF8String);
        },
        ^id(xpc_object_t response) {
            return @(xpc_dictionary_get_bool(response, "supported"));
        },
        3.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    reply([supported isKindOfClass:NSNumber.class] && supported.boolValue);
}

- (void)readDeviceVendorIdentifierFromApplicationWithIdentifier:(NSString *)appID
                                                          reply:(void (^)(NSString *))reply
{
    if (!reply)
        return;
    if (!appID.length) {
        reply(nil);
        return;
    }
    NSError *error = nil;
    NSString *identifier = CRManagerSendSynchronousQueryRequest(
        @"read_device_vendor_identifier",
        ^(xpc_object_t request) {
            xpc_dictionary_set_string(
                request, "application_id", appID.UTF8String);
        },
        ^id(xpc_object_t response) {
            const char *value =
                xpc_dictionary_get_string(response, "identifier");
            return value ? [NSString stringWithUTF8String:value] : nil;
        },
        4.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    reply([identifier isKindOfClass:NSString.class] ? identifier : nil);
}

- (void)writeDeviceVendorIdentifier:(NSString *)identifier
          toApplicationWithIdentifier:(NSString *)appID
{
    if (!appID.length || !identifier.length)
        return;
    NSError *error = nil;
    BOOL success = CRManagerSendSynchronousControlRequest(
        @"write_device_vendor_identifier",
        ^(xpc_object_t request) {
            xpc_dictionary_set_string(
                request, "application_id", appID.UTF8String);
            xpc_dictionary_set_string(
                request, "identifier", identifier.UTF8String);
        },
        4.0,
        &error);
    CRManagerRecordHelperTransportError(error);
    NSLog(@"CraneManager: helper write vendor-id app=%@ success=%d error=%@",
          appID, success, error);
}
@end

/* U-04 safety gate: reconstructed libcrane cannot yet resolve the original
 * per-app home-directory layout. Reject traversal or DEFAULT as a delete
 * target instead of treating the shared Crane data root as app data. */
static BOOL CRManagerSafePathComponent(NSString *component)
{
    if (![component isKindOfClass:[NSString class]] || !component.length ||
        [component isEqualToString:@"."] ||
        [component isEqualToString:@".."])
        return NO;
    static NSCharacterSet *invalid;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSCharacterSet *valid = [NSCharacterSet
            characterSetWithCharactersInString:
                @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
        invalid = [valid invertedSet];
    });
    return [component rangeOfCharacterFromSet:invalid].location == NSNotFound;
}

/* CR_CONTAINERS_DIR_COMPONENT includes "Library/". Checking only
 * root/___Crane_Containers misses the actual root/Library/___Crane_Containers
 * symlink. Check both real path components before filesystem operations. */
static BOOL CRManagerAppContainerParentsAreSafe(NSString *home)
{
    if (![home isKindOfClass:[NSString class]] || !home.length)
        return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *relative in @[@"Library", CR_CONTAINERS_DIR_COMPONENT]) {
        NSString *candidate = [home stringByAppendingPathComponent:relative];
        if ([fm destinationOfSymbolicLinkAtPath:candidate error:NULL])
            return NO;
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory] &&
            !isDirectory)
            return NO;
    }
    return YES;
}

/* CRMCM 0xC2BC/0xC3E4 redirects from the OS-assigned application
 * data container, NOT from CR_DATA_DIR. The original libcrane resolver is
 * missing (U-04). Resolve a guarded, existing LSApplicationProxy home,
 * never synthesize or create an application's data-container UUID. */
static NSString *CRManagerVerifiedApplicationHome(NSString *appID)
{
    if (!CRManagerSafePathComponent(appID))
        return nil;
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL lookupSEL = NSSelectorFromString(@"applicationProxyForIdentifier:");
    SEL homeSEL = NSSelectorFromString(@"dataContainerURL");
    if (!proxyClass || ![proxyClass respondsToSelector:lookupSEL])
        return nil;
    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
            proxyClass, lookupSEL, appID);
        if (!proxy || ![proxy respondsToSelector:homeSEL])
            return nil;
        id candidate = ((id (*)(id, SEL))objc_msgSend)(
            proxy, homeSEL);
        if (![candidate isKindOfClass:[NSURL class]] ||
            ![(NSURL *)candidate isFileURL])
            return nil;
        NSString *root = [[(NSURL *)candidate path]
            stringByStandardizingPath];
        root = [root stringByResolvingSymlinksInPath];
        NSString *uuidString = [root lastPathComponent];
        NSString *parent = [root stringByDeletingLastPathComponent];
        /* OS-owned app data homes normally live directly under this UUID
         * directory. Reject arbitrary file URLs with a look-alike suffix. */
        if (![[NSUUID alloc] initWithUUIDString:uuidString] ||
            !([parent isEqualToString:@"/private/var/mobile/Containers/Data/Application"] ||
              [parent isEqualToString:@"/var/mobile/Containers/Data/Application"]))
            return nil;
        BOOL isDirectory = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:root
                                                isDirectory:&isDirectory] ||
            !isDirectory)
            return nil;
        NSString *craneRoot = [CRJailbreakRootPath(CR_DATA_DIR)
            stringByResolvingSymlinksInPath];
        if ([root isEqualToString:craneRoot])
            return nil;
        /* Library and Library/___Crane_Containers may not exist yet;
         * reject symlinked or non-directory entries at either level. */
        if (!CRManagerAppContainerParentsAreSafe(root))
            return nil;
        return root;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}

static BOOL CRManagerSafeManagedPath(NSString *appID, NSString *containerID,
                                     NSString *path)
{
    if (!CRManagerSafePathComponent(appID) ||
        !CRManagerSafePathComponent(containerID) ||
        [containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
        ![path isKindOfClass:[NSString class]])
        return NO;
    NSString *base = CRManagerVerifiedApplicationHome(appID);
    if (!base)
        return NO;
    NSString *expected = CRContainerPathForContainer(containerID, base);
    return expected.length && [path isEqualToString:expected] &&
        ![path isEqualToString:base];
}

/* Idempotent, symlink-guarded app directory scaffolding lives in
 * CRContainerScaffold.h so the production implementation can run in CI. */

@interface CraneManager ()
/* [INFERRED] The original keeps the registry in cfprefsd-backed preferences.
 * This build keeps it in memory and persists to a plist, which is the smallest
 * thing that makes the documented container paths work. */
@property (nonatomic, strong) NSMutableDictionary *applications; /* legacy migration snapshot */
@property (nonatomic, strong) NSXPCConnection *userNotificationsServerXpcConnection;
@property (nonatomic, assign) Class userNotificationsServerClass;
@property (nonatomic, assign) BOOL isRunningInSpringBoard;
@property (atomic, strong) id lastError;
@property (nonatomic, strong) id unsandboxHandler;
@property (nonatomic, strong) NSHashTable *observers;
@property (nonatomic, strong) dispatch_queue_t queue;
- (void)_handleDaemonReloadingForContainerIdentifier:(NSString *)containerID
                              ofApplicationWithIdentifier:(NSString *)appID;
- (void)_removeAccountsDatabaseIfExistsForIdentifier:(NSString *)identifier;
- (void)_deleteUserLibraryPreferencesForContainerWithIdentifier:(NSString *)containerID
                                           applicationIdentifier:(NSString *)appID;
@end
static Protocol *CRUserNotificationsExtendedProtocol(void)
{
    Protocol *base = objc_getProtocol("UNUserNotificationServerProtocol");
    Protocol *additions = @protocol(UNUserNotificationProtocolCraneAdditions);
    if (!base || !additions)
        return nil;

    Protocol *extended =
        objc_getProtocol("UNUserNotificationServerProtocolPlusCraneAdditions");
    if (extended)
        return extended;

    @synchronized([CraneManager class]) {
        extended = objc_getProtocol(
            "UNUserNotificationServerProtocolPlusCraneAdditions");
        if (!extended) {
            extended = objc_allocateProtocol(
                "UNUserNotificationServerProtocolPlusCraneAdditions");
            if (extended) {
                protocol_addProtocol(extended, additions);
                protocol_addProtocol(extended, base);
                objc_registerProtocol(extended);
            }
        }
    }
    return extended;
}

@implementation CraneManager

+ (CraneManager *)sharedManager
{
    static CraneManager *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[CraneManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _isRunningInSpringBoard = [[[NSBundle mainBundle] bundleIdentifier]
            isEqualToString:@"com.apple.springboard"];
        /* Persist app switches across Preferences restarts in a dedicated
         * preference domain, rather than the process-only registry. */
        NSDictionary *saved = CFBridgingRelease(CFPreferencesCopyAppValue(
            CFSTR("applications"), CFSTR("com.opa334.cranereconstruction.apps")));
        _applications = [saved isKindOfClass:NSDictionary.class] ? [saved mutableCopy] : [NSMutableDictionary new];
        NSLog(@"CraneManager: legacy registry candidates=%lu", (unsigned long)_applications.count);
        _observers = [NSHashTable weakObjectsHashTable];
        _queue = dispatch_queue_create("com.opa334.crane.manager", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

/* ---- preferences -------------------------------------------------------- */

- (id)preferenceValueForKey:(NSString *)key
{
    if (!key)
        return nil;
    /* Root.plist writes to com.opa334.craneprefs, not to the hosting
     * process' standard defaults domain (which varies by process). */
    return CFBridgingRelease(CFPreferencesCopyAppValue(
        (__bridge CFStringRef)key, (__bridge CFStringRef)CR_PREFS_DOMAIN));
}

- (void)setPreferenceValue:(id)value forKey:(NSString *)key
{
    if (!key)
        return;
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
        (__bridge CFPropertyListRef)value,
        (__bridge CFStringRef)CR_PREFS_DOMAIN);
    BOOL synced = CFPreferencesAppSynchronize((__bridge CFStringRef)CR_PREFS_DOMAIN);
    NSLog(@"CraneManager: global preference write key=%@ sync=%@",
          key, synced ? @"YES" : @"NO");
}

/* ---- observation -------------------------------------------------------- */

/* addObserver:/removeObserver: are CONFIRMED_STATIC CraneManager selectors.
 * The original observer callback protocol is not recoverable from the current
 * evidence, so retain only weak membership semantics here rather than invent a
 * notification selector. This is sufficient for callers that temporarily
 * unregister around their own writes, as CranePrefs does. */
- (void)addObserver:(id)observer
{
    if (!observer)
        return;
    @synchronized(self.observers) {
        [self.observers addObject:observer];
    }
}

- (void)removeObserver:(id)observer
{
    if (!observer)
        return;
    @synchronized(self.observers) {
        [self.observers removeObject:observer];
    }
}

/* ---- registry ----------------------------------------------------------- */

/* Original cranehelperd 0x100005EA8 delegates this to helper 0x10000CC68.
 * Query the recovered LaunchServices predicate instead of using registry
 * membership as a proxy for whether an installed application is supported. */
- (BOOL)isApplicationSupportedByCrane:(NSString *)appID
{
    if (!appID.length)
        return NO;
    id<CRHelperServiceProtocol> proxy =
        (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
    if (![proxy respondsToSelector:
        @selector(checkIsApplicationWithIdentifier:supportedByCraneAndReply:)])
        return NO;
    __block BOOL replied = NO;
    __block BOOL supported = NO;
    [proxy checkIsApplicationWithIdentifier:appID
        supportedByCraneAndReply:^(BOOL value) {
            supported = value;
            replied = YES;
        }];
    return replied && supported;
}

- (NSArray<NSString *> *)identifiersOfAllSupportedApplications
{
    id<CRHelperServiceProtocol> proxy =
        (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
    if (![proxy respondsToSelector:
        @selector(getIdentifiersOfAllSupportedApplicationsAndReply:)])
        return @[];
    __block NSArray<NSString *> *identifiers = nil;
    [proxy getIdentifiersOfAllSupportedApplicationsAndReply:
        ^(NSArray<NSString *> *value) {
            identifiers = [value copy];
        }];
    return [identifiers isKindOfClass:NSArray.class] ? identifiers : @[];
}

- (NSArray<NSString *> *)identfiersOfApplicationsThatHaveNonDefaultContainers
{
    NSMutableArray *result = [NSMutableArray new];
    for (NSString *appID in [self identifiersOfAllSupportedApplications]) {
        NSArray *containers = [self applicationSettingsForApplicationWithIdentifier:appID]
            [CRAppSetting_Containers];
        for (NSDictionary *container in containers) {
            if (![container[CRCContainer_Identifier]
                isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
                [result addObject:appID];
                break;
            }
        }
    }
    return result;
}

static NSString *CRApplicationSettingsPreferenceKey(NSString *appID)
{
    return appID.length ? [@"appSettings_" stringByAppendingString:appID] : nil;
}

- (NSDictionary *)applicationSettingsForApplicationWithIdentifier:(NSString *)appID
{
    if (!appID.length)
        return nil;

    NSString *key = CRApplicationSettingsPreferenceKey(appID);
    id stored = [self preferenceValueForKey:key];

    /* Compatibility bridge only: older reconstruction builds used an
     * aggregate domain. The recovered original schema is appSettings_<bundleID>
     * in com.opa334.craneprefs. Copy legacy data forward once and never delete
     * the legacy source here. */
    if (![stored isKindOfClass:NSDictionary.class]) {
        NSDictionary *legacy = nil;
        @synchronized(self) {
            legacy = [self.applications[appID] copy];
        }
        if ([legacy isKindOfClass:NSDictionary.class] && legacy.count) {
            NSDictionary *normalized = CRManagerSettingsIncludingDefault(legacy);
            [self setPreferenceValue:normalized forKey:key];
            stored = normalized;
            NSLog(@"CraneManager: migrated legacy app settings app=%@ key=%@",
                  appID, key);
        }
    }

    return CRManagerSettingsIncludingDefault(stored);
}

- (void)setApplicationSettings:(NSDictionary *)settings
  forApplicationWithIdentifier:(NSString *)appID
{
    if (!appID.length || ![settings isKindOfClass:NSDictionary.class])
        return;
    settings = CRManagerSettingsIncludingDefault(settings);
    NSArray *previousContainers = [[self applicationSettingsForApplicationWithIdentifier:appID][CRAppSetting_Containers] valueForKey:CRCContainer_Identifier];
    NSArray *newContainers = [settings[CRAppSetting_Containers] valueForKey:CRCContainer_Identifier];
    BOOL containerListChanged = ![(previousContainers ?: @[]) isEqual:(newContainers ?: @[])];
    [self setPreferenceValue:settings
                     forKey:CRApplicationSettingsPreferenceKey(appID)];
    /* CranePrefs 0x7BD4 / 0x7CC8 receive manager notifications.
     * Snapshot the weak observer set and notify outside the registry lock. */
    NSArray *observers = nil;
    @synchronized(self.observers) {
        observers = self.observers.allObjects;
    }
    SEL changed = @selector(didChangeSettingsForApplicationWithIdentifier:);
    SEL containersChanged = @selector(didChangeContainersOfApplicationWithIdentifier:);
    for (id observer in observers) {
        if (containerListChanged && [observer respondsToSelector:containersChanged])
            ((void (*)(id, SEL, id))objc_msgSend)(observer, containersChanged, appID);
        else if ([observer respondsToSelector:changed])
            ((void (*)(id, SEL, id))objc_msgSend)(observer, changed, appID);
    }
}

- (NSDictionary *)containerSettingsForContainerWithIdentifier:(NSString *)containerID
                                 ofApplicationWithIdentifier:(NSString *)appID
{
    NSArray *containers = [self applicationSettingsForApplicationWithIdentifier:appID]
                            [CRAppSetting_Containers];
    for (NSDictionary *container in containers) {
        if ([container[CRCContainer_Identifier] isEqualToString:containerID])
            return container;
    }
    return @{};
}

- (void)setContainerSettings:(NSDictionary *)settings
  forContainerWithIdentifier:(NSString *)containerID
   ofApplicationWithIdentifier:(NSString *)appID
{
    if (!appID || !containerID)
        return;
    @synchronized(self) {
        NSMutableDictionary *app = [[self applicationSettingsForApplicationWithIdentifier:appID] mutableCopy];
        if (!app)
            app = [NSMutableDictionary new];
        NSMutableArray *containers = [app[CRAppSetting_Containers] mutableCopy];
        if (!containers)
            containers = [NSMutableArray new];
        NSUInteger index = [containers indexOfObjectPassingTest:
                            ^BOOL(NSDictionary *c, NSUInteger i, BOOL *stop) {
            return [c[CRCContainer_Identifier] isEqualToString:containerID];
        }];
        NSMutableDictionary *container = [(settings ?: @{}) mutableCopy];
        container[CRCContainer_Identifier] = containerID;
        if (index == NSNotFound)
            [containers addObject:container];
        else
            containers[index] = container;
        app[CRAppSetting_Containers] = containers;
        [self setApplicationSettings:app forApplicationWithIdentifier:appID];
    }
    NSArray *observers = nil;
    @synchronized(self.observers) { observers = self.observers.allObjects; }
    SEL changed = @selector(didChangeContainerSettingsForContainerWithIdentifier:onApplicationWithIdentifier:);
    for (id observer in observers) {
        if ([observer respondsToSelector:changed])
            ((void (*)(id, SEL, id, id))objc_msgSend)(observer, changed, containerID, appID);
    }
}

/* ---- containers --------------------------------------------------------- */

- (NSArray<NSString *> *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)appID
{
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *container in
         [self applicationSettingsForApplicationWithIdentifier:appID][CRAppSetting_Containers]) {
        NSString *identifier = container[CRCContainer_Identifier];
        if (identifier)
            [result addObject:identifier];
    }
    return result;
}

- (NSString *)activeContainerIdentifierForApplicationWithIdentifier:(NSString *)appID
{
    /* CONFIRMED_STATIC contract: this never returns nil in practice;
     * crane_containerToRedirectTo (CraneSB 0x1B360) is what translates
     * "DEFAULT" into nil. */
    NSDictionary *settings = [self applicationSettingsForApplicationWithIdentifier:appID];
    NSString *active = settings[CRCContainer_ActiveContainer];
    if (active.length)
        return active;
    for (NSDictionary *container in settings[CRAppSetting_Containers]) {
        active = container[CRCContainer_ActiveContainer];
        if (active.length)
            return active;
    }
    return CR_DEFAULT_CONTAINER_IDENTIFIER;
}

- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
{
    if (!appID || !containerID)
        return;
    if (![containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
        ![[self containerIdentifiersOfApplicationWithIdentifier:appID] containsObject:containerID])
        return;
    NSMutableDictionary *settings = [[self applicationSettingsForApplicationWithIdentifier:appID] mutableCopy];
    settings[CRCContainer_ActiveContainer] = containerID;
    NSMutableArray *containers = [NSMutableArray new];
    for (NSDictionary *container in settings[CRAppSetting_Containers]) {
        NSMutableDictionary *item = [container mutableCopy];
        [item removeObjectForKey:CRCContainer_ActiveContainer];
        [containers addObject:item];
    }
    if (settings[CRAppSetting_Containers])
        settings[CRAppSetting_Containers] = containers;
    [self setApplicationSettings:settings forApplicationWithIdentifier:appID];
    NSLog(@"CraneManager: active container app=%@ id=%@", appID, containerID);
}

- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
                     reloadApplication:(BOOL)reload
       usingBiometricsIfNeededWithSuccessHandler:(void (^)(BOOL authenticated))handler
{
    void (^apply)(BOOL) = ^(BOOL authenticated) {
        [self setActiveContainerIdentifier:containerID forApplicationWithIdentifier:appID];
        if (reload)
            [self reloadApplicationWithIdentifier:appID];
        if (handler)
            handler(authenticated);
    };
    /* Only protected containers require authentication. The exported
     * CranePrefs 0x74D8 checks requireBiometricAuthentication before
     * continuing selection; shortcut selection must respect that too. */
    NSDictionary *targetSettings = [self containerSettingsForContainerWithIdentifier:containerID
        ofApplicationWithIdentifier:appID];
    if ([targetSettings[@"requireBiometricAuthentication"] boolValue])
        CRRequestAuthentication(CRLocalize(@"CONFIRM_PASSWORD"), ^{ apply(YES); });
    else
        apply(NO);
}

- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
usingBiometricsIfNeededWithSuccessHandler:(void (^)(BOOL authenticated))handler
{
    [self setActiveContainerIdentifier:containerID forApplicationWithIdentifier:appID
                       reloadApplication:NO
         usingBiometricsIfNeededWithSuccessHandler:handler];
}

/* CraneSupport 0xC2BC and 0xC8E8 send this observed private selector.
 * libcrane's original implementation is unavailable. Only populate the
 * non-default app-data path whose exact structure is confirmed by
 * CRContainerPathForContainer; refuse group, DEFAULT, and arbitrary paths. */
- (void)_populateContainerDirectory:(NSString *)path ofType:(NSUInteger)type
{
    if (type != 1 || ![path isKindOfClass:[NSString class]] ||
        !path.length || ![[path stringByStandardizingPath] isEqualToString:path])
        return;

    NSString *containerID = [path lastPathComponent];
    if (!CRManagerSafePathComponent(containerID) ||
        [containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
        [containerID hasPrefix:@".crane-"])
        return;
    NSString *appHome = [[[path stringByDeletingLastPathComponent]
        stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    if (![CRContainerPathForContainer(containerID, appHome)
          isEqualToString:path])
        return;
    NSString *canonicalHome = [appHome stringByResolvingSymlinksInPath];
    NSString *homeParent = [canonicalHome stringByDeletingLastPathComponent];
    NSString *homeUUID = [canonicalHome lastPathComponent];
    if (![[NSUUID alloc] initWithUUIDString:homeUUID] ||
        !([homeParent isEqualToString:@"/private/var/mobile/Containers/Data/Application"] ||
          [homeParent isEqualToString:@"/var/mobile/Containers/Data/Application"]))
        return;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:appHome isDirectory:&isDirectory] ||
        !isDirectory)
        return;
    if (!CRManagerAppContainerParentsAreSafe(appHome) ||
        !CRManagerDirectoryComponentIsSafe(path))
        return;

    NSError *error = nil;
    if (!CRManagerCreateEmptyContainer(path, &error))
        NSLog(@"CraneManager: refusing/failed container population %@: %@", path, error);
}

- (NSString *)containerDirectoryForContainerWithIdentifier:(NSString *)containerID
                               ofApplicationWithIdentifier:(NSString *)appID
{
    if (!CRManagerSafePathComponent(appID) ||
        !CRManagerSafePathComponent(containerID))
        return nil;
    /* Resolve on every call: reinstalling an app can change its data UUID.
     * Never fall back to a synthetic shared Crane directory. */
    NSString *base = CRManagerVerifiedApplicationHome(appID);
    return base ? CRContainerPathForContainer(containerID, base) : nil;
}

/* Conservatively reject duplicate identifiers registered to another app.
 * The native registry now lives under appSettings_<bundleID>; the aggregate
 * reconstruction domain is read only as a migration/source-of-app-IDs bridge.
 * Include currently supported applications so collision checks do not silently
 * stop working after an app has already been migrated out of the legacy map. */
- (BOOL)cr_containerIdentifierShared:(NSString *)identifier
                       withOtherThan:(NSString *)appID
{
    if (!identifier.length)
        return YES;

    NSDictionary *legacyApps = CFBridgingRelease(CFPreferencesCopyAppValue(
        CFSTR("applications"), CFSTR("com.opa334.cranereconstruction.apps")));
    if (legacyApps && ![legacyApps isKindOfClass:[NSDictionary class]])
        return YES;

    NSMutableSet<NSString *> *candidateAppIDs = [NSMutableSet new];

    /* Native settings can outlive installation/support discovery. Inspect
     * every appSettings_<bundleID> key so cross-app collisions cannot be
     * missed merely because a helper listing is temporarily incomplete. */
    NSArray *nativeKeys = CFBridgingRelease(CFPreferencesCopyKeyList(
        (__bridge CFStringRef)CR_PREFS_DOMAIN,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    for (id key in nativeKeys) {
        if (![key isKindOfClass:[NSString class]] ||
            ![key hasPrefix:@"appSettings_"])
            continue;
        NSString *otherID = [key substringFromIndex:[@"appSettings_" length]];
        if (otherID.length)
            [candidateAppIDs addObject:otherID];
    }
    NSArray *supported = [self identifiersOfAllSupportedApplications];
    if ([supported isKindOfClass:[NSArray class]])
        [candidateAppIDs addObjectsFromArray:supported];
    if ([legacyApps isKindOfClass:[NSDictionary class]])
        [candidateAppIDs addObjectsFromArray:legacyApps.allKeys];
    @synchronized(self) {
        [candidateAppIDs addObjectsFromArray:self.applications.allKeys];
    }

    for (id otherID in candidateAppIDs) {
        if (![otherID isKindOfClass:[NSString class]] ||
            [otherID isEqual:appID])
            continue;
        /* A read-only collision check must not migrate an unrelated app.
         * Reject corrupt saved entries rather than assuming no collision. */
        id settings = [self preferenceValueForKey:
            CRApplicationSettingsPreferenceKey(otherID)];
        if (!settings) {
            settings = [legacyApps isKindOfClass:[NSDictionary class]]
                ? legacyApps[otherID] : nil;
            if (!settings) {
                @synchronized(self) {
                    settings = self.applications[otherID];
                }
            }
        }
        if (!settings)
            continue;
        if (![settings isKindOfClass:[NSDictionary class]])
            return YES;
        id containers = settings[CRAppSetting_Containers];
        if (containers && ![containers isKindOfClass:[NSArray class]])
            return YES;
        for (id entry in containers) {
            if (![entry isKindOfClass:[NSDictionary class]])
                return YES;
            if ([entry[CRCContainer_Identifier] isEqual:identifier])
                return YES;
        }
    }
    return NO;
}

- (BOOL)cr_canModifyStoredContainer:(NSString *)identifier
                       application:(NSString *)appID
                               path:(NSString *)path
{
    if (!CRManagerSafePathComponent(appID) ||
        !CRManagerSafeManagedPath(appID, identifier, path) ||
        ![[self containerIdentifiersOfApplicationWithIdentifier:appID]
            containsObject:identifier] ||
        [[self activeContainerIdentifierForApplicationWithIdentifier:appID]
            isEqualToString:identifier] ||
        [self cr_containerIdentifierShared:identifier withOtherThan:appID])
        return NO;
    return ![NSFileManager.defaultManager
        destinationOfSymbolicLinkAtPath:path error:NULL];
}

- (NSString *)createNewContainerWithName:(NSString *)name
            forApplicationWithIdentifier:(NSString *)appID
{
    if (!CRManagerSafePathComponent(appID))
        return nil;
    [self resetLastError];
    NSString *identifier = [[NSUUID UUID] UUIDString];
    [self createNewContainerWithName:name
                      andIdentifier:identifier
            forApplicationWithIdentifier:appID];
    /* Do not return a made-up identifier when storage setup failed. */
    return [[self containerIdentifiersOfApplicationWithIdentifier:appID]
        containsObject:identifier] ? identifier : nil;
}

- (void)createNewContainerWithName:(NSString *)name
                    andIdentifier:(NSString *)identifier
            forApplicationWithIdentifier:(NSString *)appID
{
    if (!CRManagerSafePathComponent(appID) ||
        !CRManagerSafePathComponent(identifier) ||
        [identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return;
    NSString *path = [self containerDirectoryForContainerWithIdentifier:identifier
                                           ofApplicationWithIdentifier:appID];
    if (!CRManagerSafeManagedPath(appID, identifier, path) ||
        [self cr_containerIdentifierShared:identifier withOtherThan:appID])
        return;
    NSFileManager *fm = NSFileManager.defaultManager;
    /* Even an already registered container may have been replaced by a
     * symlink; do not follow it while creating the directory scaffold. */
    if ([fm destinationOfSymbolicLinkAtPath:path error:NULL])
        return;
    BOOL registered = [[self containerIdentifiersOfApplicationWithIdentifier:appID]
        containsObject:identifier];
    /* Never adopt an unknown on-disk directory just because a caller
     * supplied its identifier. The layout is not app-scoped yet. */
    BOOL existed = [fm fileExistsAtPath:path];
    if (!registered && existed) {
        NSLog(@"CraneManager: refusing unregistered path %@", path);
        return;
    }
    NSError *error = nil;
    /* New identifiers use a private temporary scaffold, then an atomic
     * same-volume rename. An unexpected destination collision cannot lead
     * to deleting somebody else's partially created container. */
    NSString *staging = registered ? path :
        [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:
            [NSString stringWithFormat:@".crane-create-%@", [[NSUUID UUID] UUIDString]]];
    /* The cleanup below must never remove a pre-existing staging path,
     * even if a collision is extremely unlikely with a fresh UUID. */
    if (!registered &&
        ([fm fileExistsAtPath:staging] ||
         [fm destinationOfSymbolicLinkAtPath:staging error:NULL])) {
        NSLog(@"CraneManager: refusing staging path collision %@", staging);
        return;
    }
    if (!CRManagerCreateEmptyContainer(staging, &error)) {
        if (!registered)
            [fm removeItemAtPath:staging error:NULL];
        self.lastError = error;
        NSLog(@"CraneManager: container creation failed %@: %@", identifier, error);
        return;
    }
    if (!registered && ![fm moveItemAtPath:staging toPath:path error:&error]) {
        [fm removeItemAtPath:staging error:NULL];
        self.lastError = error;
        NSLog(@"CraneManager: container creation collision %@: %@", identifier, error);
        return;
    }
    NSDictionary *existing = [self containerSettingsForContainerWithIdentifier:identifier
                                                   ofApplicationWithIdentifier:appID];
    NSMutableDictionary *settings = [existing mutableCopy];
    if (name)
        settings[CRCContainer_Name] = name;
    [self setContainerSettings:settings forContainerWithIdentifier:identifier
                           ofApplicationWithIdentifier:appID];
}

- (void)_handleDaemonReloadingForContainerIdentifier:(NSString *)containerID
                              ofApplicationWithIdentifier:(NSString *)appID
{
    /* Original libcrane 0xA9B8: this special-case exists only for App Store
     * account separation, and only when the affected container is active. */
    if (![appID isEqualToString:@"com.apple.AppStore"])
        return;
    NSDictionary *settings =
        [self applicationSettingsForApplicationWithIdentifier:appID];
    if (![settings[CRAppSetting_SeparateSystemAccountsEnabled] boolValue])
        return;
    NSString *active =
        [self activeContainerIdentifierForApplicationWithIdentifier:appID];
    if ([containerID isEqualToString:active])
        [self reloadAppstoreDaemons];
}

- (void)_removeAccountsDatabaseIfExistsForIdentifier:(NSString *)identifier
{
    /* Original libcrane 0xAB00 removes the three SQLite sidecars belonging
     * to /var/mobile/Library/Accounts/Crane/<container>.*. */
    if (!CRManagerSafePathComponent(identifier))
        return;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *extension in @[@"sqlite", @"sqlite-shm", @"sqlite-wal"]) {
        NSString *path = [NSString stringWithFormat:
            @"/var/mobile/Library/Accounts/Crane/%@.%@", identifier, extension];
        if (![fm fileExistsAtPath:path])
            continue;
        NSError *error = nil;
        if (![fm removeItemAtPath:path error:&error])
            NSLog(@"CraneManager: account database cleanup failed %@: %@", path, error);
    }
}

- (void)_deleteUserLibraryPreferencesForContainerWithIdentifier:(NSString *)containerID
                                           applicationIdentifier:(NSString *)appID
{
    /* Original libcrane 0xBF98:
     *   DEFAULT -> <bundle>.plist
     *   custom  -> <bundle>.c_r_a_n_e.<container>.plist */
    if (!CRManagerSafePathComponent(appID) ||
        (containerID &&
         ![containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
         !CRManagerSafePathComponent(containerID)))
        return;

    NSString *filename = nil;
    if (!containerID ||
        [containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
        filename = [NSString stringWithFormat:@"%@.plist", appID];
    } else {
        filename = [NSString stringWithFormat:@"%@.c_r_a_n_e.%@.plist",
                    appID, containerID];
    }
    NSURL *directory =
        [NSURL fileURLWithPath:@"/var/mobile/Library/Preferences" isDirectory:YES];
    NSURL *url = [directory URLByAppendingPathComponent:filename];
    if (![url checkResourceIsReachableAndReturnError:NULL])
        return;
    NSError *error = nil;
    if (![NSFileManager.defaultManager removeItemAtURL:url error:&error])
        NSLog(@"CraneManager: preference cleanup failed %@: %@", url.path, error);
}

- (void)deleteContentOfContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
{
    /* Original libcrane 0xC74C and CranePrefs 0x86A8 separate content cleanup
     * from registry mutation. CranePrefs removes the entry from Containers only
     * after this method returns, so do not modify app settings here. */
    if (!CRManagerSafePathComponent(appID) ||
        !CRManagerSafePathComponent(containerID) ||
        [containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
        ![[self containerIdentifiersOfApplicationWithIdentifier:appID]
            containsObject:containerID] ||
        [self cr_containerIdentifierShared:containerID withOtherThan:appID]) {
        NSLog(@"CraneManager: refusing unsafe/unregistered delete app=%@ id=%@",
              appID, containerID);
        return;
    }

    [self reloadApplicationWithIdentifier:appID ifContainerIsActive:containerID];

    NSDictionary<NSString *, NSString *> *paths =
        [self pathsAssociatedToContainerWithIdentifier:containerID
                           ofApplicationWithIdentifier:appID];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *path in paths.allValues) {
        if (![path isKindOfClass:NSString.class] || !path.length)
            continue;
        if ([fm destinationOfSymbolicLinkAtPath:path error:NULL]) {
            NSLog(@"CraneManager: refusing symlink during container delete %@", path);
            continue;
        }
        if (![fm fileExistsAtPath:path])
            continue;
        NSError *error = nil;
        if (![fm removeItemAtPath:path error:&error])
            NSLog(@"CraneManager: container path cleanup failed %@: %@", path, error);
    }

    [self runSafeXPCBlock:^{
        id<CRHelperServiceProtocol> proxy =
            (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
        if ([proxy respondsToSelector:
                @selector(deleteKeychainItemsForContainerWithIdentifier:
                          forApplicationIdentifier:)]) {
            [proxy deleteKeychainItemsForContainerWithIdentifier:containerID
                                        forApplicationIdentifier:appID];
        }
    }];

    [self _removeAccountsDatabaseIfExistsForIdentifier:containerID];
    [self unregisterFromNotificationsIfNeededForContainerIdentifier:containerID
                                        ofApplicationWithIdentifier:appID];
    [self resetBadgeOfContainerWithIdentifier:containerID
                  ofApplicationWithIdentifier:appID];
    [self _deleteUserLibraryPreferencesForContainerWithIdentifier:containerID
                                             applicationIdentifier:appID];
    [self _handleDaemonReloadingForContainerIdentifier:containerID
                                ofApplicationWithIdentifier:appID];
}

- (void)wipeContainerWithIdentifier:(NSString *)containerID
            forApplicationWithIdentifier:(NSString *)appID
                    shouldRepopulate:(BOOL)repopulate
{
    NSString *path = [self containerDirectoryForContainerWithIdentifier:containerID
                                           ofApplicationWithIdentifier:appID];
    if (![self cr_canModifyStoredContainer:containerID
                              application:appID path:path]) {
        NSLog(@"CraneManager: refusing unsafe/active wipe app=%@ id=%@",
              appID, containerID);
        return;
    }
    /* Wiping data must not erase container name, biometric policy, or
     * registration. The former implementation called deleteContent..., which
     * removed settings and silently ignored failed filesystem deletion. */
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    if (!repopulate) {
        if ([fm fileExistsAtPath:path] &&
            ![fm removeItemAtPath:path error:&error])
            NSLog(@"CraneManager: wipe failed %@: %@", path, error);
        return;
    }
    /* Stage the replacement and keep the old contents until the empty
     * scaffold has been created successfully. Both paths share a parent,
     * so the swaps are on the same volume. */
    NSString *parent = [path stringByDeletingLastPathComponent];
    NSString *suffix = [[NSUUID UUID] UUIDString];
    NSString *replacement = [parent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".crane-new-%@", suffix]];
    NSString *backup = [parent stringByAppendingPathComponent:
        [NSString stringWithFormat:@".crane-old-%@", suffix]];
    /* Neither temporary slot may already belong to another operation.
     * Never remove/reuse an existing path during failed wipe cleanup. */
    if ([fm fileExistsAtPath:replacement] ||
        [fm destinationOfSymbolicLinkAtPath:replacement error:NULL] ||
        [fm fileExistsAtPath:backup] ||
        [fm destinationOfSymbolicLinkAtPath:backup error:NULL]) {
        NSLog(@"CraneManager: refusing wipe staging collision %@", parent);
        return;
    }
    if (!CRManagerCreateEmptyContainer(replacement, &error)) {
        [fm removeItemAtPath:replacement error:NULL];
        NSLog(@"CraneManager: wipe preparation failed: %@", error);
        return;
    }
    BOOL hadOriginal = [fm fileExistsAtPath:path];
    if (hadOriginal && ![fm moveItemAtPath:path toPath:backup error:&error]) {
        [fm removeItemAtPath:replacement error:NULL];
        NSLog(@"CraneManager: wipe staging failed: %@", error);
        return;
    }
    if (![fm moveItemAtPath:replacement toPath:path error:&error]) {
        if (hadOriginal && ![fm moveItemAtPath:backup toPath:path error:NULL])
            NSLog(@"CraneManager: wipe rollback failed; old data at %@", backup);
        [fm removeItemAtPath:replacement error:NULL];
        NSLog(@"CraneManager: wipe replacement failed: %@", error);
        return;
    }
    if (hadOriginal && ![fm removeItemAtPath:backup error:&error])
        NSLog(@"CraneManager: wipe completed, old backup at %@: %@", backup, error);
}

- (void)makeDefaultForContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
{
    [self setActiveContainerIdentifier:containerID forApplicationWithIdentifier:appID];
}

- (void)moveOrCopyContainerFromPath:(NSString *)src toPath:(NSString *)dst move:(BOOL)move
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    if (move)
        [fm moveItemAtPath:src toPath:dst error:&error];
    else
        [fm copyItemAtPath:src toPath:dst error:&error];
}

- (void)enumerate:(void (^)(NSInteger type, NSString *identifier,
                                           NSString *path, BOOL *stop))block
 pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
              ofApplicationWithIdentifier:(NSString *)appID
{
    if (!block || !CRManagerSafePathComponent(containerID) ||
        !CRManagerSafePathComponent(appID))
        return;

    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    SEL lookupSEL = NSSelectorFromString(@"applicationProxyForIdentifier:");
    if (!proxyClass || ![proxyClass respondsToSelector:lookupSEL])
        return;

    @try {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(
            proxyClass, lookupSEL, appID);
        if (!proxy)
            return;

        BOOL stop = NO;
        SEL dataSEL = NSSelectorFromString(@"dataContainerURL");
        if ([proxy respondsToSelector:dataSEL]) {
            id url = ((id (*)(id, SEL))objc_msgSend)(proxy, dataSEL);
            NSString *base = [url respondsToSelector:@selector(path)]
                ? ((id (*)(id, SEL))objc_msgSend)(url, @selector(path)) : nil;
            NSString *path = CRContainerPathForContainer(containerID, base);
            if (path.length)
                block(0, appID, path, &stop);
        }
        if (stop)
            return;

        /* Original 0xE09C enumerates LSApplicationProxy.groupContainerURLs as
         * identifier -> NSURL and emits type 1. */
        SEL groupsSEL = NSSelectorFromString(@"groupContainerURLs");
        id groups = [proxy respondsToSelector:groupsSEL]
            ? ((id (*)(id, SEL))objc_msgSend)(proxy, groupsSEL) : nil;
        if ([groups isKindOfClass:NSDictionary.class]) {
            [(NSDictionary *)groups enumerateKeysAndObjectsUsingBlock:
                ^(id identifier, id url, BOOL *dictionaryStop) {
                    (void)dictionaryStop;
                    if (stop || ![identifier isKindOfClass:NSString.class])
                        return;
                    NSString *base = [url respondsToSelector:@selector(path)]
                        ? ((id (*)(id, SEL))objc_msgSend)(url, @selector(path)) : nil;
                    NSString *path = CRContainerPathForContainer(containerID, base);
                    if (path.length)
                        block(1, identifier, path, &stop);
                }];
        }
        if (stop)
            return;

        /* Original 0xE09C then emits PlugInKit data containers as type 2. */
        SEL pluginsSEL = NSSelectorFromString(@"plugInKitPlugins");
        id plugins = [proxy respondsToSelector:pluginsSEL]
            ? ((id (*)(id, SEL))objc_msgSend)(proxy, pluginsSEL) : nil;
        if ([plugins isKindOfClass:NSArray.class]) {
            for (id plugin in (NSArray *)plugins) {
                if (stop)
                    break;
                SEL pluginIDSEL = NSSelectorFromString(@"pluginIdentifier");
                SEL pluginDataSEL = NSSelectorFromString(@"dataContainerURL");
                NSString *identifier = [plugin respondsToSelector:pluginIDSEL]
                    ? ((id (*)(id, SEL))objc_msgSend)(plugin, pluginIDSEL) : nil;
                id url = [plugin respondsToSelector:pluginDataSEL]
                    ? ((id (*)(id, SEL))objc_msgSend)(plugin, pluginDataSEL) : nil;
                NSString *base = [url respondsToSelector:@selector(path)]
                    ? ((id (*)(id, SEL))objc_msgSend)(url, @selector(path)) : nil;
                NSString *path = CRContainerPathForContainer(containerID, base);
                if (identifier.length && path.length)
                    block(2, identifier, path, &stop);
            }
        }
    } @catch (NSException *exception) {
        NSLog(@"CraneManager: associated path enumeration failed app=%@ id=%@: %@",
              appID, containerID, exception);
    }
}

- (NSDictionary<NSString *, NSString *> *)pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
                                      ofApplicationWithIdentifier:(NSString *)appID
{
    if (!CRManagerSafePathComponent(containerID) ||
        !CRManagerSafePathComponent(appID))
        return nil;

    NSMutableDictionary<NSString *, NSString *> *paths = [NSMutableDictionary new];
    [self enumerate:^(NSInteger type, NSString *identifier, NSString *path,
                      BOOL *stop) {
        (void)type;
        (void)stop;
        if (identifier.length && path.length)
            paths[identifier] = path;
    } pathsAssociatedToContainerWithIdentifier:containerID
                    ofApplicationWithIdentifier:appID];
    return [paths copy];
}

/* CranePrefs 0x113A4/0x1148C expects an asynchronous size completion.
 * Resolve the app-scoped root before scanning; do not fall back to the
 * shared Crane root, nor traverse symlinked container entries. */
- (void)sizeOccupiedByContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
                               completionHandler:(void (^)(unsigned long long))handler
{
    if (!handler)
        return;
    NSString *root = [self containerDirectoryForContainerWithIdentifier:containerID
                                          ofApplicationWithIdentifier:appID];
    BOOL valid = NO;
    if ([containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
        NSString *appHome = CRManagerVerifiedApplicationHome(appID);
        valid = appHome.length && [root isEqualToString:appHome];
    } else {
        valid = CRManagerSafeManagedPath(appID, containerID, root);
    }
    if (!valid) {
        dispatch_async(dispatch_get_main_queue(), ^{ handler(0); });
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = [NSFileManager new];
        BOOL isDirectory = NO;
        unsigned long long total = 0;
        if ([fm fileExistsAtPath:root isDirectory:&isDirectory] &&
            isDirectory &&
            ![fm destinationOfSymbolicLinkAtPath:root error:NULL]) {
            NSDirectoryEnumerator *enumerator = [fm enumeratorAtPath:root];
            for (NSString *relative in enumerator) {
                NSString *path = [root stringByAppendingPathComponent:relative];
                NSDictionary *attrs = [fm attributesOfItemAtPath:path error:NULL];
                NSString *kind = attrs[NSFileType];
                if ([kind isEqualToString:NSFileTypeSymbolicLink]) {
                    [enumerator skipDescendants];
                    continue;
                }
                if ([kind isEqualToString:NSFileTypeRegular]) {
                    unsigned long long bytes = [attrs fileSize];
                    total = ULLONG_MAX - total < bytes ? ULLONG_MAX : total + bytes;
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ handler(total); });
    });
}

- (NSArray<NSString *> *)unknownContainersInsideApplicationWithIdentifier:(NSString *)appID
                                                       knownContainers:(NSSet<NSString *> *)known
{
    /* Only enumerate the scoped, LaunchServices-confirmed app data home.
     * Never enumerate CR_DATA_DIR, which could contain another app's data. */
    NSString *base = CRManagerVerifiedApplicationHome(appID);
    if (!base)
        return @[];
    NSString *root = [base stringByAppendingPathComponent:
        CR_CONTAINERS_DIR_COMPONENT];
    BOOL rootIsDir = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:root isDirectory:&rootIsDir] || !rootIsDir ||
        [fm destinationOfSymbolicLinkAtPath:root error:NULL])
        return @[];
    NSSet<NSString *> *registered = [NSSet setWithArray:
        [self containerIdentifiersOfApplicationWithIdentifier:appID]];
    NSMutableArray<NSString *> *result = [NSMutableArray new];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:NULL];
    for (NSString *entry in entries) {
        if (!CRManagerSafePathComponent(entry) ||
            [entry isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
            [entry hasPrefix:@".crane-"] ||
            [registered containsObject:entry] ||
            [known containsObject:entry])
            continue;
        NSString *candidate = [root stringByAppendingPathComponent:entry];
        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:candidate isDirectory:&isDirectory] ||
            !isDirectory ||
            [fm destinationOfSymbolicLinkAtPath:candidate error:NULL])
            continue;
        [result addObject:entry];
    }
    return [result sortedArrayUsingSelector:@selector(compare:)];
}

/* ---- naming ------------------------------------------------------------- */

- (NSString *)displayNameForApplicationWithIdentifier:(NSString *)appID
{
    if (!appID.length)
        return appID;
    id<CRHelperServiceProtocol> proxy =
        (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
    if (![proxy respondsToSelector:
        @selector(getDisplayNameOfApplicationWithIdentifier:reply:)])
        return appID;
    __block NSString *displayName = nil;
    [proxy getDisplayNameOfApplicationWithIdentifier:appID
        reply:^(NSString *value) {
            displayName = [value copy];
        }];
    return displayName.length ? displayName : appID;
}

/* Inferred: the selector/arguments are confirmed in CraneSB 0xE730 and
 * 0x1119C; the original libcrane implementation is not recovered. */
- (NSString *)containerNameToDisplayInNotificationWithUserInfoOrContext:(NSDictionary *)info
                                         ofApplicationWithIdentifier:(NSString *)appID
{
    if (![info isKindOfClass:[NSDictionary class]] || !appID.length)
        return nil;
    id source = info[@"crane_sourceContainerID"];
    NSString *container = [source isKindOfClass:[NSString class]] ? source : nil;
    if (!container.length)
        return nil;
    return [self displayNameForContainerWithIdentifier:container
                           ofApplicationWithIdentifier:appID
                                shouldUseShortVersion:YES];
}

- (NSString *)displayNameForContainerWithIdentifier:(NSString *)containerID
                         ofApplicationWithIdentifier:(NSString *)appID
                              shouldUseShortVersion:(BOOL)useShort
{
    NSDictionary *settings = [self containerSettingsForContainerWithIdentifier:containerID
                                                   ofApplicationWithIdentifier:appID];
    NSString *name = settings[CRCContainer_Name];
    if (name.length)
        return name;
    if ([containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return CRLocalize(@"DEFAULT_CONTAINER") ?: @"Default Container";
    return containerID;
}

/* ---- device identifier -------------------------------------------------- */

- (BOOL)applicationHasDeviceIdentifier:(NSString *)appID
{
    if (!appID.length)
        return NO;
    id<CRHelperServiceProtocol> proxy =
        (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
    if (![proxy respondsToSelector:
        @selector(readDeviceVendorIdentifierFromApplicationWithIdentifier:reply:)])
        return NO;
    __block NSString *identifier = nil;
    [proxy readDeviceVendorIdentifierFromApplicationWithIdentifier:appID
        reply:^(NSString *value) {
            identifier = [value copy];
        }];
    return [[NSUUID alloc] initWithUUIDString:identifier] != nil;
}

- (NSString *)deviceIdentifierToUseForContainerWithIdentifier:(NSString *)containerID
                                    ofApplicationWithIdentifier:(NSString *)appID
{
    if (!CRManagerSafePathComponent(appID) ||
        !CRManagerSafePathComponent(containerID))
        return nil;
    if ([containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
        id<CRHelperServiceProtocol> proxy =
            (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
        if (![proxy respondsToSelector:
            @selector(readDeviceVendorIdentifierFromApplicationWithIdentifier:reply:)])
            return nil;
        __block NSString *systemIdentifier = nil;
        [proxy readDeviceVendorIdentifierFromApplicationWithIdentifier:appID
            reply:^(NSString *value) {
                systemIdentifier = [value copy];
            }];
        return [[NSUUID alloc] initWithUUIDString:systemIdentifier]
            ? systemIdentifier : nil;
    }

    NSDictionary *settings = [self containerSettingsForContainerWithIdentifier:containerID
                                                   ofApplicationWithIdentifier:appID];
    id pref = settings[CRPref_UseContainerIdentifierAsDeviceID];
    NSString *customValue = settings[@"customDeviceIdentifier"];
    BOOL hasCustomUUID = [customValue isKindOfClass:NSString.class] &&
        [[NSUUID alloc] initWithUUIDString:customValue] != nil;
    /* CranePrefs 0xF8F0 defaults this option to YES when absent.
     * CraneSupport/CRLsd.m also falls back to the container identifier
     * when custom is unavailable. Never return the literal DEFAULT as a
     * vendor UUID: only non-default IDs are valid fallback candidates. */
    if ((!pref || [pref boolValue] || !hasCustomUUID) &&
        ![containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
        [[NSUUID alloc] initWithUUIDString:containerID])
        return containerID;
    return hasCustomUUID ? customValue : nil;
}

- (BOOL)setDeviceIdentifier:(NSString *)identifier
   ofContainerWithIdentifier:(NSString *)containerID
    andApplicationWithIdentifier:(NSString *)appID
{
    if (!CRManagerSafePathComponent(appID) ||
        !CRManagerSafePathComponent(containerID) ||
        ![[NSUUID alloc] initWithUUIDString:identifier])
        return NO;

    if ([containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]) {
        id<CRHelperServiceProtocol> proxy =
            (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
        if (![proxy respondsToSelector:
            @selector(writeDeviceVendorIdentifier:toApplicationWithIdentifier:)] ||
            ![proxy respondsToSelector:
            @selector(readDeviceVendorIdentifierFromApplicationWithIdentifier:reply:)])
            return NO;

        [proxy writeDeviceVendorIdentifier:identifier
               toApplicationWithIdentifier:appID];
        __block NSString *written = nil;
        [proxy readDeviceVendorIdentifierFromApplicationWithIdentifier:appID
            reply:^(NSString *value) {
                written = [value copy];
            }];
        NSUUID *requestedUUID = [[NSUUID alloc] initWithUUIDString:identifier];
        NSUUID *writtenUUID = [[NSUUID alloc] initWithUUIDString:written];
        return requestedUUID && writtenUUID &&
            [requestedUUID isEqual:writtenUUID];
    }

    NSDictionary *existing = [self containerSettingsForContainerWithIdentifier:containerID
                                                   ofApplicationWithIdentifier:appID];
    NSMutableDictionary *settings = [existing mutableCopy];
    if (!settings)
        settings = [NSMutableDictionary new];
    settings[@"customDeviceIdentifier"] = identifier;
    [self setContainerSettings:settings forContainerWithIdentifier:containerID
                           ofApplicationWithIdentifier:appID];
    return YES;
}

/* ---- process control ---------------------------------------------------- */

- (void)reloadAccountsdDaemon
{
    [self runSafeXPCBlock:^{
        id<CRHelperServiceProtocol> proxy =
            (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
        if ([proxy respondsToSelector:@selector(reloadDaemons:)])
            [proxy reloadDaemons:@[@"accountsd"]];
    }];
}

- (void)reloadAppstoreDaemons
{
    [self runSafeXPCBlock:^{
        id<CRHelperServiceProtocol> proxy =
            (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
        if ([proxy respondsToSelector:@selector(reloadDaemons:)])
            [proxy reloadDaemons:@[@"appstored", @"itunesstored",
                                    @"StoreKitUIService"]];
    }];
}

- (void)reloadMusicDaemons
{
    [self runSafeXPCBlock:^{
        id<CRHelperServiceProtocol> proxy =
            (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
        if ([proxy respondsToSelector:@selector(reloadDaemons:)])
            [proxy reloadDaemons:@[@"itunescloudd"]];
    }];
}

- (void)reloadGameDaemons
{
    [self runSafeXPCBlock:^{
        id<CRHelperServiceProtocol> proxy =
            (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
        if ([proxy respondsToSelector:@selector(reloadDaemons:)])
            [proxy reloadDaemons:@[@"gamed"]];
    }];
}

- (void)reloadApplicationWithIdentifier:(NSString *)appID
{
    if (!appID.length)
        return;
    id<CRHelperServiceProtocol> proxy =
        (id<CRHelperServiceProtocol>)[self cranehelperdGlobalSyncRemoteObjectProxy];
    if ([proxy respondsToSelector:@selector(reloadApplication:)])
        [proxy reloadApplication:appID];
}

/* CranePrefs 0x23A30 passes CRPBackupContainer._containerID here. */
- (void)reloadApplicationWithIdentifier:(NSString *)appID
                    ifContainerIsActive:(NSString *)containerID
{
    if (!appID.length || !containerID.length)
        return;
    NSString *active =
        [self activeContainerIdentifierForApplicationWithIdentifier:appID];
    if ([active isEqualToString:containerID])
        [self reloadApplicationWithIdentifier:appID];
    /* Native libcrane 0x10288 always flushes cfprefsd after the conditional
     * reload, even when the requested container is not currently active. */
    [self flushCFPrefsdCacheForApplicationWithIdentifier:appID];
}

- (void)flushCFPrefsdCacheForApplicationWithIdentifier:(NSString *)appID
{
    if (!appID.length)
        return;

    Class prefsClass = NSClassFromString(@"_CFXPreferences");
    SEL copySEL = NSSelectorFromString(@"copyDefaultPreferences");
    SEL flushSEL = NSSelectorFromString(@"flushCachesForAppIdentifier:user:");
    if (!prefsClass || ![prefsClass respondsToSelector:copySEL])
        return;

    id preferences = ((id (*)(id, SEL))objc_msgSend)(prefsClass, copySEL);
    if (!preferences || ![preferences respondsToSelector:flushSEL])
        return; /* Original has an older private fallback; fail closed here. */

    NSString *active =
        [self activeContainerIdentifierForApplicationWithIdentifier:appID];
    NSDictionary<NSString *, NSString *> *paths =
        [self pathsAssociatedToContainerWithIdentifier:active
                           ofApplicationWithIdentifier:appID];
    id user = (__bridge id)kCFPreferencesCurrentUser;
    NSFileManager *fm = NSFileManager.defaultManager;

    for (NSString *identifier in paths) {
        NSString *containerPath = paths[identifier];
        if (!identifier.length || !containerPath.length)
            continue;

        ((void (*)(id, SEL, id, id))objc_msgSend)(
            preferences, flushSEL, identifier, user);

        NSString *prefsPath =
            [containerPath stringByAppendingPathComponent:@"Library/Preferences"];
        NSArray<NSString *> *entries =
            [fm contentsOfDirectoryAtPath:prefsPath error:NULL];
        for (NSString *entry in entries) {
            if (![[entry pathExtension] isEqualToString:@"plist"])
                continue;
            NSString *domain = [entry stringByDeletingPathExtension];
            if (!domain.length || [domain isEqualToString:identifier])
                continue;
            ((void (*)(id, SEL, id, id))objc_msgSend)(
                preferences, flushSEL, domain, user);
        }
    }
}

- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                reply:(void (^)(NSString *, BOOL))reply
{
    CRManagerLookupActiveContainerForPid(pid, reply);
}

/* Reconstruction-specific low-level health probe. This does not establish
 * compatibility with the original daemon or its NSXPC protocol. */
- (BOOL)cranehelperdConnectionWorks
{
    /* On the main thread, use a short-lived cached result and schedule
     * one probe on a worker. An unknown/expired result fails closed. */
    /* systemUptime is monotonic across wall-clock adjustments. */
    static NSTimeInterval lastProbeUptime;
    static BOOL cachedAlive;
    static BOOL probeInFlight;
    if ([NSThread isMainThread]) {
        BOOL result = NO;
        @synchronized([CraneManager class]) {
            NSTimeInterval now = [NSProcessInfo processInfo].systemUptime;
            NSTimeInterval age = now - lastProbeUptime;
            BOOL fresh = lastProbeUptime > 0.0 &&
                age >= 0.0 && age < 5.0;
            if (fresh)
                result = cachedAlive;
            if (!fresh && !probeInFlight) {
                probeInFlight = YES;
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                    BOOL aliveNow = [[CraneManager sharedManager]
                        cranehelperdConnectionWorks];
                    @synchronized([CraneManager class]) {
                        cachedAlive = aliveNow;
                        lastProbeUptime = [NSProcessInfo processInfo].systemUptime;
                        probeInFlight = NO;
                    }
                });
            }
        }
        return result;
    }
    /* The callback may arrive after timeout. Keep its result in heap-backed
     * block storage and only read it after a successful semaphore wait. */
    __block BOOL alive = NO;
    __block BOOL completed = NO;
    NSObject *completionLock = [NSObject new];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    xpc_connection_t connection = CRManagerCreateHelperConnection();
    if (!connection)
        return NO;
    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        if (xpc_get_type(event) != XPC_TYPE_ERROR)
            return;
        @synchronized(completionLock) {
            if (!completed) {
                completed = YES;
                dispatch_semaphore_signal(done);
            }
        }
    });
    xpc_connection_resume(connection);
    xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
    if (request) {
        xpc_dictionary_set_string(request, "operation", "ping");
        xpc_dictionary_set_string(request, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
        xpc_connection_send_message_with_reply(connection, request,
            dispatch_get_global_queue(QOS_CLASS_UTILITY, 0),
            ^(xpc_object_t response) {
                BOOL replyAlive = NO;
                if (xpc_get_type(response) == XPC_TYPE_DICTIONARY) {
                    const char *protocol = xpc_dictionary_get_string(response, "protocol");
                    replyAlive = protocol && strcmp(protocol, CR_HELPERD_PING_PROTOCOL_V1) == 0 &&
                        xpc_dictionary_get_bool(response, "alive");
                }
                @synchronized(completionLock) {
                    if (!completed) {
                        alive = replyAlive;
                        completed = YES;
                        dispatch_semaphore_signal(done);
                    }
                }
            });
        long waitResult = dispatch_semaphore_wait(done,
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)));
        BOOL result;
        @synchronized(completionLock) {
            result = waitResult == 0 && alive;
            completed = YES; /* Ignore callbacks arriving after timeout. */
        }
        xpc_connection_cancel(connection);
        return result;
    }
    xpc_connection_cancel(connection);
    return NO;
}

/* Recovered libcrane selector. The original NSXPC locking/retry internals
 * are unavailable; execute synchronously and serialize callers while the
 * bounded proxy adapter handles error/timeout fail-closed. */
- (void)runSafeXPCBlock:(dispatch_block_t)block
{
    if (!block)
        return;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSObject new]; });
    @synchronized(lock) {
        @try { block(); }
        @catch (NSException *exception) { (void)exception; }
    }
}

- (id)cranehelperdGlobalSyncRemoteObjectProxy
{
    /* Minimal read-only reconstruction adapter. Each raw-XPC request is
     * authenticated by helperd; privileged original NSXPC methods stay absent. */
    static CRInsuranceHealthProxy *proxy;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ proxy = [CRInsuranceHealthProxy new]; });
    return proxy;
}
- (id)cranehelperdGlobalAsyncRemoteObjectProxy
{
    /* CraneSB 0x1782C uses the async proxy for the recovered
     * runInjectionFixUpIfNeededAndReply: operation. The same narrow adapter
     * carries a fixed-purpose authenticated helper request; it exposes no
     * caller-selected PID or dylib path. */
    return [self cranehelperdGlobalSyncRemoteObjectProxy];
}
/* A filter plist is not a dylib and must not be passed to dlopen().
 * This is an installation-presence check, not proof of injection into a
 * particular process.  Never report success unconditionally. */
- (BOOL)isDylibLoaded
{
    NSString *filterPath = CRJailbreakRootPath(CR_MAIN_DYLIB_FILTER_PLIST);
    return filterPath.length &&
        [[NSFileManager defaultManager] fileExistsAtPath:filterPath];
}

/* ---- Game Center (INFERRED; see U-06 for the data model) ---------------- */

/* Original libcrane 0x9800 iterates appSettings_* records and selects the
 * bundle identifiers whose gameCenterSupportEnabled flag is true. Read native
 * preference keys directly: helper application discovery can omit an app
 * whose settings remain after uninstall, and reading must not cause a legacy
 * copy-forward write from the accountsd process. */
- (NSArray<NSString *> *)gameCenter_enabledApplicationIdentifiers
{
    NSArray *nativeKeys = CFBridgingRelease(CFPreferencesCopyKeyList(
        (__bridge CFStringRef)CR_PREFS_DOMAIN,
        kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    NSMutableSet<NSString *> *enabled = [NSMutableSet new];
    NSString *prefix = @"appSettings_";
    for (id key in nativeKeys) {
        if (![key isKindOfClass:NSString.class] ||
            ![key hasPrefix:prefix] || [key length] <= prefix.length)
            continue;
        id settings = [self preferenceValueForKey:key];
        if (![settings isKindOfClass:NSDictionary.class] ||
            ![settings[CRAppSetting_GameCenterSupportEnabled] boolValue])
            continue;
        NSString *appID = [key substringFromIndex:prefix.length];
        if (appID.length)
            [enabled addObject:appID];
    }
    return [[enabled allObjects] sortedArrayUsingSelector:@selector(compare:)];
}

/* Original libcrane 0x9AE4 reads activeGameCenterAccount, then validates it
 * against the known account identifiers. Missing or stale IDs select DEFAULT,
 * never an orphaned account database. */
- (NSString *)gameCenter_activeAccount
{
    id stored = [self preferenceValueForKey:@"activeGameCenterAccount"];
    return CRGameCenterResolvedActiveAccount(
        [self gameCenter_availableAccounts], stored);
}

- (void)gameCenter_setActiveAccount:(NSString *)account
{
    [self gameCenter_setActiveAccount:account andDontKillApplication:nil];
}

/* Original 0x9BD0 changes the preference only if the effective account
 * differs; 0x9BC0 forwards here with a nil exemption. */
- (void)gameCenter_setActiveAccount:(NSString *)account
            andDontKillApplication:(NSString *)appID
{
    NSString *resolved = CRGameCenterResolvedActiveAccount(
        [self gameCenter_availableAccounts], account);
    if ([[self gameCenter_activeAccount] isEqualToString:resolved])
        return;
    [self setPreferenceValue:resolved forKey:@"activeGameCenterAccount"];
    [self gameCenter_reloadExceptApplicationWithIdentifier:appID];
}
- (NSArray<NSDictionary *> *)gameCenter_availableAccounts
{
    /* Native CranePrefs 0x14D00/0x15448 uses {identifier, name} dictionaries,
     * not the string array the old reconstruction expected. Reads are
     * deliberately non-destructive when preferences contain malformed data. */
    /* Original libcrane 0x9608 reads the CFSTR "gameCenterAccounts".
     * Old reconstruction builds mistakenly used a different key; read that
     * only when the native record is absent, without writing during lookup. */
    id stored = [self preferenceValueForKey:@"gameCenterAccounts"];
    if (!stored)
        stored = [self preferenceValueForKey:@"crane_gameCenter.availableAccounts"];
    return CRGameCenterValidatedAccounts(stored);
}
- (void)gameCenter_setAvailableAccounts:(NSArray<NSDictionary *> *)accounts
{
    /* An invalid entry must never cause account deletion through filtering. */
    if (!CRGameCenterAccountsAreValidForWrite(accounts)) {
        NSLog(@"CraneManager: rejected malformed Game Center account list");
        return;
    }
    [self setPreferenceValue:[accounts copy]
                     forKey:@"gameCenterAccounts"];
}
- (BOOL)gameCenter_isAccountAvailable:(NSString *)account
{
    return CRGameCenterAccountIdentifierExists(
        [self gameCenter_availableAccounts], account);
}
/* Original 0x99BC exits when the exempt bundle ID is nil/empty.
 * Otherwise reload gamed and every configured Game Center application
 * except the currently launching one (0x9A8C). Never send arbitrary
 * caller-provided process names to the privileged daemon. */
- (void)gameCenter_reloadExceptApplicationWithIdentifier:(NSString *)appID
{
    if (![appID isKindOfClass:NSString.class] || !appID.length)
        return;
    [self reloadGameDaemons];
    for (NSString *enabledApp in [self gameCenter_enabledApplicationIdentifiers]) {
        if (![enabledApp isEqualToString:appID])
            [self reloadApplicationWithIdentifier:enabledApp];
    }
}

/* ---- keychain ----------------------------------------------------------- */

- (BOOL)isKeychainVersionUpToDate
{
    return [[self preferenceValueForKey:@"keychainVersion"] integerValue] == 2;
}

- (void)updateKeychainVersion
{
    [self setPreferenceValue:@2 forKey:@"keychainVersion"];
}

/* ---- UserNotifications bridge ------------------------------------------ */

- (void)_initUserNotificationsServerConnection
{
    @synchronized(self) {
        if (self.userNotificationsServerClass ||
            self.userNotificationsServerXpcConnection)
            return;

        NSBundle *bundle = [NSBundle bundleWithPath:
            @"/System/Library/Frameworks/UserNotifications.framework"];
        [bundle load];

        if (self.isRunningInSpringBoard) {
            self.userNotificationsServerClass =
                NSClassFromString(@"UNSUserNotificationServer");
            return;
        }

        Protocol *protocol = CRUserNotificationsExtendedProtocol();
        if (!protocol)
            return;

        SEL initSEL = NSSelectorFromString(@"initWithMachServiceName:");
        id allocated = [NSXPCConnection alloc];
        if (![allocated respondsToSelector:initSEL])
            return;
        NSXPCConnection *connection =
            ((id (*)(id, SEL, id))objc_msgSend)(
                allocated, initSEL,
                @"com.apple.usernotifications.usernotificationservice");
        if (!connection)
            return;
        connection.remoteObjectInterface =
            [NSXPCInterface interfaceWithProtocol:protocol];
        [connection resume];
        self.userNotificationsServerXpcConnection = connection;
    }
}

- (id)_userNotificationsSyncRemoteProxy
{
    [self _initUserNotificationsServerConnection];

    if (self.isRunningInSpringBoard) {
        Class serverClass = self.userNotificationsServerClass;
        SEL sharedSEL = NSSelectorFromString(@"sharedInstance");
        if (!serverClass || ![serverClass respondsToSelector:sharedSEL])
            return nil;
        @try {
            id server =
                ((id (*)(id, SEL))objc_msgSend)(serverClass, sharedSEL);
            return [server valueForKey:@"_userNotificationServerConnectionListener"];
        } @catch (NSException *exception) {
            NSLog(@"CraneManager: notification listener unavailable: %@",
                  exception);
            return nil;
        }
    }

    NSXPCConnection *connection = self.userNotificationsServerXpcConnection;
    if (!connection)
        return nil;
    return [connection synchronousRemoteObjectProxyWithErrorHandler:
        ^(NSError *error) {
            NSLog(@"CraneManager: UserNotifications XPC error: %@", error);
        }];
}

/* ---- Crane hooks -------------------------------------------------------- */

- (void)unregisterFromNotificationsIfNeededForContainerIdentifier:(NSString *)containerID
                                ofApplicationWithIdentifier:(NSString *)appID
{
    if (!containerID.length || !appID.length)
        return;
    id proxy = [self _userNotificationsSyncRemoteProxy];
    SEL selector = @selector(
        crane_unregisterFromNotificationsIfNeededForContainerIdentifier:
        ofApplicationWithIdentifier:);
    if ([proxy respondsToSelector:selector]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            proxy, selector, containerID, appID);
    }
}

- (void)resetBadgeOfContainerWithIdentifier:(NSString *)containerID
                ofApplicationWithIdentifier:(NSString *)appID
{
    if (!containerID.length || !appID.length)
        return;
    id proxy = [self _userNotificationsSyncRemoteProxy];
    SEL selector =
        @selector(crane_resetBadgeOfContainerWithIdentifier:
                  ofApplicationWithIdentifier:);
    if ([proxy respondsToSelector:selector]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            proxy, selector, containerID, appID);
    }
}

- (void)switchBadgesOfContainerWithIdentifier:(NSString *)containerID
                      andContainerWithIdentifier:(NSString *)otherContainerID
                   ofApplicationWithIdentifier:(NSString *)appID
{
    if (!containerID.length || !otherContainerID.length || !appID.length)
        return;
    id proxy = [self _userNotificationsSyncRemoteProxy];
    SEL selector =
        @selector(crane_switchBadgesOfContainerWithIdentifier:
                  andContainerWithIdentifier:
                  ofApplicationWithIdentifier:);
    if ([proxy respondsToSelector:selector]) {
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            proxy, selector, containerID, otherContainerID, appID);
    }
}
- (void)migrateApplication:(NSString *)appID
          withAppSettings:(NSDictionary *)settings
{
    /* Original CranePrefs sends this selector to CRHPreferencesService to
     * migrate keychain material for an already-existing app configuration.
     * Rewriting application settings here is unrelated and can make a failed
     * migration look successful. Keep the public selector fail-closed until
     * the original keychain serialization/migration backend is transcribed. */
    (void)appID;
    (void)settings;
    NSError *error = CRHelperTransportError(
        CRHelperUnexpectedReply,
        @"migrate_application",
        @"Keychain migration backend is unavailable");
    self.lastError = error;
    NSLog(@"CraneManager: keychain migration unavailable app=%@ error=%@",
          appID, error);
}

- (void)crane_recordHelperTransportError:(NSError *)error { self.lastError = error; }
- (void)resetLastError { self.lastError = nil; }
- (id)getLastError
{
    id scoped = NSThread.currentThread.threadDictionary[CRHelperReplyErrorContext];
    return scoped ? (scoped == NSNull.null ? nil : scoped) : self.lastError;
}
- (BOOL)crane_prepareXPCUnsandbox
{
    CRManagerXPCUnsandboxHandler handler =
        (CRManagerXPCUnsandboxHandler)self.unsandboxHandler;
    return handler ? handler() : YES;
}

- (void)_setXPCUnsandboxHandler:(id)handler
{
    self.unsandboxHandler = [handler copy];
}

@end