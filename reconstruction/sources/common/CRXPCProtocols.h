/*
 * Clang-emitted Objective-C XPC protocol metadata.
 *
 * CraneSB original __objc_protolist contains
 * _OBJC_PROTOCOL_$_UNUserNotificationProtocolCraneAdditions;
 * CraneSupport original __objc_protolist contains
 * _OBJC_PROTOCOL_$_UNUserNotificationProtocolCraneAdditions and
 * _OBJC_PROTOCOL_$_LSDDeviceIdentifierProtocolCraneAdditions.
 *
 * NSXPCInterface (notably iOS 15) requires Clang's extended method
 * signatures. protocol_addMethodDescription() supplies only regular
 * runtime type encodings and crashes when the XPC interface is built.
 * Keep the dynamic composite "PlusCraneAdditions" protocols, which
 * simply adopt these compiler-emitted protocols and the system base.
 */
#ifndef CR_XPC_PROTOCOLS_H
#define CR_XPC_PROTOCOLS_H

#import <Foundation/Foundation.h>
#import <stdint.h>

@protocol UNUserNotificationProtocolCraneAdditions
- (void)crane_unregisterFromNotificationsIfNeededForContainerIdentifier:
            (NSString *)containerID
    ofApplicationWithIdentifier:(NSString *)applicationID;
- (void)crane_switchBadgesOfContainerWithIdentifier:(NSString *)firstID
           andContainerWithIdentifier:(NSString *)secondID
         ofApplicationWithIdentifier:(NSString *)applicationID;
- (void)crane_resetBadgeOfContainerWithIdentifier:(NSString *)containerID
                    ofApplicationWithIdentifier:(NSString *)applicationID;
@end

@protocol _LSDDeviceIdentifierProtocolCraneAdditions
- (void)crane_getIdentifier:(void (^)(NSArray *identifiers))reply
                    ofType:(int64_t)type
             forVendorName:(NSString *)vendorName
       andBundleIdentifier:(NSString *)bundleIdentifier;
- (void)crane_setIdentifier:(id)identifier
                    ofType:(int64_t)type
             forVendorName:(NSString *)vendorName
       andBundleIdentifier:(NSString *)bundleIdentifier;
@end

#endif /* CR_XPC_PROTOCOLS_H */
