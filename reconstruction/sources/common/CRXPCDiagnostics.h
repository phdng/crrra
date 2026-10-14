/* Reconstruction transport diagnostics, not the unrecovered original RPC.
 * Only a matching, live reply proves connectivity; errors never prove injection. */
#ifndef CR_XPC_DIAGNOSTICS_H
#define CR_XPC_DIAGNOSTICS_H
#import <Foundation/Foundation.h>
#include <xpc/xpc.h>
#include <string.h>
#import "CRPaths.h"

typedef NS_ENUM(NSInteger, CRHelperTransportErrorCode) {
    CRHelperConnectionCreationFailed = 1001,
    CRHelperConnectionInterrupted = 1002,
    CRHelperConnectionInvalid = 1003,
    CRHelperTerminationImminent = 1004,
    CRHelperUnexpectedReply = 1005,
    CRHelperProtocolMismatch = 1006,
    CRHelperReplyTimedOut = 1007,
    CRHelperRequestAllocationFailed = 1008,
    CRHelperInvalidPID = 1009,
    CRHelperUnauthorizedPeer = 1010,
    CRHelperInvalidRequest = 1011,
    CRHelperOperationFailed = 1012
};

static inline NSError *CRHelperTransportError(CRHelperTransportErrorCode code,
                                              NSString *operation,
                                              NSString *reason)
{
    NSString *description = [NSString stringWithFormat:@"%@ (%@): %@",
        CR_HELPERD_MACH_SERVICE, operation ?: @"unknown", reason ?: @"Unknown XPC error"];
    return [NSError errorWithDomain:@"com.opa334.crane.helper.transport"
                              code:code userInfo:@{NSLocalizedDescriptionKey: description}];
}

static inline NSError *CRHelperXPCEventError(xpc_object_t event, NSString *operation)
{
    CRHelperTransportErrorCode code = CRHelperUnexpectedReply;
    if (event == XPC_ERROR_CONNECTION_INTERRUPTED) code = CRHelperConnectionInterrupted;
    else if (event == XPC_ERROR_CONNECTION_INVALID) code = CRHelperConnectionInvalid;
    else if (event == XPC_ERROR_TERMINATION_IMMINENT) code = CRHelperTerminationImminent;
    const char *description = event && xpc_get_type(event) == XPC_TYPE_ERROR
        ? xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION) : NULL;
    return CRHelperTransportError(code, operation, description
        ? [NSString stringWithUTF8String:description] : @"Unexpected XPC response type");
}

static inline BOOL CRHelperValidateHealthReply(xpc_object_t response,
                                                NSString *operation,
                                                NSError **error)
{
    if (error) *error = nil;
    if (!response || xpc_get_type(response) != XPC_TYPE_DICTIONARY) {
        if (error) *error = CRHelperXPCEventError(response, operation);
        return NO;
    }
    const char *protocol = xpc_dictionary_get_string(response, "protocol");
    if (!protocol || strcmp(protocol, CR_HELPERD_PING_PROTOCOL_V1) != 0) {
        NSString *actual = protocol ? [NSString stringWithUTF8String:protocol] : @"missing";
        if (error) *error = CRHelperTransportError(CRHelperProtocolMismatch, operation,
            [NSString stringWithFormat:@"Incompatible helper protocol: %@ (expected %s)",
                                       actual, CR_HELPERD_PING_PROTOCOL_V1]);
        return NO;
    }
    if (!xpc_dictionary_get_bool(response, "alive")) {
        if (error) *error = CRHelperTransportError(CRHelperUnexpectedReply, operation,
                                                  @"Helper did not confirm a live service");
        return NO;
    }
    return YES;
}
#endif
