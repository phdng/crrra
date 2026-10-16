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

@interface CRBackupNativeSourcePreflight : NSObject
+ (nullable NSDictionary<NSString *, id> *)preflightApplicationIdentifier:(NSString *)applicationID
                                                       containerIdentifier:(NSString *)containerID
                                                                  resolver:(id<CRBackupSourceResolver>)resolver
                                                                     error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
