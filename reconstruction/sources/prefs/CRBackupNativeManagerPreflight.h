/*
 * G-11 N6 — explicit read-only integration point for the installed
 * CraneManager API. No UI entry point, no automatic startup probe, and
 * NO backup/restore, app activation, filesystem writes, or Keychain access.
 */
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface CRBackupNativeManagerPreflight : NSObject
/* When explicitly called, resolve the existing CraneManager singleton via
 * Objective-C runtime and pass it to N5's read-only root eligibility gate.
 * Success reports accessible ROOTS ONLY, never backup readiness.
 * Errors intentionally do not include app IDs, paths or container IDs. */
+ (nullable NSDictionary<NSString *, id> *)probeRegisteredApplication:(NSString *)applicationID
                                                   containerIdentifier:(NSString *)containerID
                                                                 error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
