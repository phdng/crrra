/*
 * Runtime smoke test for NSXPCInterface extended protocol signatures.
 *
 * Executed on the macOS CI runner with Apple's Clang + Foundation before
 * building CraneSB / CraneSupport. The iOS 15.8.8 Safe Mode report came from
 * NSXPCInterface rejecting a dynamically constructed additions protocol:
 * it lacked Clang's extended method type metadata.
 *
 * This fixture intentionally uses the EXACT project header. Compiling
 * ad-hoc replica protocols here would not test what Crane actually builds.
 *
 * macOS is NOT iOS 15.8.8; successful execution is only additional evidence.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "CRXPCProtocols.h"

static BOOL CRSmokeInterface(Protocol *protocol, NSString *label)
{
    if (!protocol) {
        NSLog(@"XPC smoke: missing protocol %@", label);
        return NO;
    }
    @try {
        NSXPCInterface *interface = [NSXPCInterface interfaceWithProtocol:protocol];
        if (!interface || ![interface protocol]) {
            NSLog(@"XPC smoke: no interface for %@", label);
            return NO;
        }
        NSLog(@"XPC smoke: accepted %@", label);
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"XPC smoke: REJECTED %@: %@", label, exception);
        return NO;
    }
}

static BOOL CRSmokeComposite(Protocol *additions, const char *name)
{
    Protocol *composite = objc_getProtocol(name);
    if (!composite) {
        composite = objc_allocateProtocol(name);
        if (!composite)
            return NO;
        protocol_addProtocol(composite, additions);
        objc_registerProtocol(composite);
    }
    return CRSmokeInterface(composite, [NSString stringWithUTF8String:name]);
}

int main(void)
{
    @autoreleasepool {
        Protocol *notification =
            @protocol(UNUserNotificationProtocolCraneAdditions);
        Protocol *deviceIDs =
            @protocol(_LSDDeviceIdentifierProtocolCraneAdditions);

        if (!CRSmokeInterface(notification, @"UNUserNotificationProtocolCraneAdditions"))
            return 1;
        if (!CRSmokeInterface(deviceIDs, @"_LSDDeviceIdentifierProtocolCraneAdditions"))
            return 2;

        if (!CRSmokeComposite(notification,
                              "CRXPCSmokeNotificationPlusCraneAdditions"))
            return 3;
        if (!CRSmokeComposite(deviceIDs,
                              "CRXPCSmokeDeviceIDPlusCraneAdditions"))
            return 4;

        NSLog(@"XPC smoke: all Clang-emitted and runtime-composite interfaces accepted");
        return 0;
    }
}
