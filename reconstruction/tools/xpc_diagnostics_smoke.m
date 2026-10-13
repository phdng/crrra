/* Exercise the same response decoder used by libcrane; sends no device RPC. */
#import <Foundation/Foundation.h>
#import "CRXPCDiagnostics.h"

static void require(BOOL condition, NSString *message)
{
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}
int main(void)
{
    @autoreleasepool {
        NSError *error = nil;
        xpc_object_t invalids[] = {
            XPC_ERROR_CONNECTION_INVALID, XPC_ERROR_CONNECTION_INTERRUPTED,
            XPC_ERROR_TERMINATION_IMMINENT, NULL, xpc_string_create("invalid")
        };
        NSInteger codes[] = {
            CRHelperConnectionInvalid, CRHelperConnectionInterrupted,
            CRHelperTerminationImminent, CRHelperUnexpectedReply, CRHelperUnexpectedReply
        };
        for (NSUInteger i = 0; i < sizeof(codes)/sizeof(codes[0]); i++) {
            require(!CRHelperValidateHealthReply(invalids[i], @"lookup_pid", &error),
                    @"invalid response accepted");
            require(error.code == codes[i], @"wrong error category");
            require([error.localizedDescription containsString:CR_HELPERD_MACH_SERVICE] &&
                    [error.localizedDescription containsString:@"lookup_pid"],
                    @"missing service/operation diagnostic");
        }
        xpc_object_t reply = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_bool(reply, "alive", true);
        require(!CRHelperValidateHealthReply(reply, @"insurance", &error) &&
                error.code == CRHelperProtocolMismatch, @"missing protocol accepted");
        xpc_dictionary_set_string(reply, "protocol", "old-version");
        require(!CRHelperValidateHealthReply(reply, @"insurance", &error) &&
                [error.localizedDescription containsString:@"old-version"],
                @"wrong protocol accepted or hidden");
        xpc_dictionary_set_string(reply, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
        xpc_dictionary_set_bool(reply, "alive", false);
        require(!CRHelperValidateHealthReply(reply, @"insurance", &error) && error,
                @"dead reply accepted");
        xpc_dictionary_set_bool(reply, "alive", true);
        xpc_dictionary_set_bool(reply, "works", false);
        xpc_dictionary_set_bool(reply, "injection_verified", false);
        require(CRHelperValidateHealthReply(reply, @"insurance", &error) && !error,
                @"live transport misclassified as a transport failure");
        /* Decoder success means connectivity only. Injection remains false. */
        require(!xpc_dictionary_get_bool(reply, "works") &&
                !xpc_dictionary_get_bool(reply, "injection_verified"),
                @"decoder fabricated injection");
        NSError *timeout = CRHelperTransportError(CRHelperReplyTimedOut,
            @"insurance", @"No helper reply within 2 seconds");
        require(timeout.code == CRHelperReplyTimedOut &&
                [timeout.localizedDescription containsString:@"2 seconds"],
                @"timeout detail lost");
        NSLog(@"XPC diagnostic decoder: PASS (no daemon/runtime injection tested)");
    }
    return 0;
}
