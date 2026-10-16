/*
 * G-11 N5: independent read-only source root preflight.
 *
 * The resolver may be CraneManager in a future explicit caller, but this
 * module neither creates/migrates/activates containers nor enumerates files.
 * A successful result DOES NOT authorize actual Backup or Restore.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@protocol CRBackupSourceResolver <NSObject>
- (BOOL)isApplicationSupportedByCrane:(NSString *)applicationID;
- (NSArray<NSString *> *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)applicationID;
- (NSDictionary<NSString *, NSString *> *)pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
                                                     ofApplicationWithIdentifier:(NSString *)applicationID;
@end

/* N10: private in-memory identity token. Carries root path and dev/inode
 * metadata only while an explicit preflight is running; never return it in
 * a public diagnostic report, log, persist or use it for authorization. */
@interface CRBackupNativeRootIdentitySnapshot : NSObject
@end

@interface CRBackupNativeSourcePreflight : NSObject
+ (nullable CRBackupNativeRootIdentitySnapshot *)captureRootIdentityForMapping:
    (NSDictionary<NSString *, NSString *> *)mapping;
+ (BOOL)isRootIdentityUnchangedFromSnapshot:(CRBackupNativeRootIdentitySnapshot *)snapshot
                                   mapping:(NSDictionary<NSString *, NSString *> *)mapping;
+ (nullable NSDictionary<NSString *, id> *)preflightApplicationIdentifier:(NSString *)applicationID
                                                       containerIdentifier:(NSString *)containerID
                                                                  resolver:(id<CRBackupSourceResolver>)resolver
                                                                     error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
