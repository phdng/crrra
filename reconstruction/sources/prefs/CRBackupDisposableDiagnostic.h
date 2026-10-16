/*
 * G-11 N8 — explicit, disposable-app-only, root-metadata diagnostic.
 * No automatic invocation, file traversal, Keychain, Backup or Restore.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CRBackupDisposableDiagnostic : NSObject
/* A dedicated throwaway test bundle, never a general installed user app. */
+ (BOOL)isEligibleApplicationIdentifier:(NSString *)applicationID
                    containerIdentifier:(NSString *)containerID;

/* Only called after a fresh user confirmation in the test app's container
 * Settings pane. Never exports application/container IDs or paths.
 * A successful probe is NOT permission to back up or restore anything. */
+ (nullable NSDictionary<NSString *, id> *)probeApplicationIdentifier:(NSString *)applicationID
                                                  containerIdentifier:(NSString *)containerID
                                                    userConfirmedOnce:(BOOL)confirmed
                                                                error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
