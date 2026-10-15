/*
 * G-11 Native Stage N0: shared Foundation-only backup manifest + read-only
 * original single-archive Info.plist preview. Not a ZIP extractor, backup
 * job, device inventory or permission to restore.
 *
 * No enumeration of app data and no filesystem mutation is performed here.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CRBackupNativeCore : NSObject

/* Reads ONLY first ZIP member Info.plist, supports original ZIP64 local
 * header and ZIP64 data descriptor, and validates CRC + binary plist.
 * Other ZIP entries/Keychain/app payloads are never opened. This is
 * NOT comprehensive archive validation. */
+ (nullable NSDictionary<NSString *, id> *)readSingleBackupInfoAtPath:(NSString *)path
                                                               error:(NSError * _Nullable * _Nullable)error;

/* Produces original single-container Info.plist binary data from explicit
 * caller-supplied values; no device identifiers are guessed and no source
 * filesystem is read. The caller must separately establish authority. */
+ (nullable NSData *)binarySingleInfoForApplicationIdentifier:(NSString *)applicationID
                                           containerIdentifier:(NSString *)containerID
                                                 containerName:(NSString *)containerName
                                                originalPaths:(NSDictionary<NSString *, NSString *> *)paths
                                     deviceIdentifierForVendor:(nullable NSString *)vendorID
                                                         error:(NSError * _Nullable * _Nullable)error;

/* Original 0x2301C/0x23124 allowlist, with types checked; does not chown,
 * chmod or apply values to a file. */
+ (NSDictionary<NSString *, id> *)writableMetadataAttributes:(NSDictionary *)attributes;

/* Prepare binary Metadata.plist from an explicit test/runtime attribute map.
 * No path is resolved, traversed, opened, chmod/chown'd or restored here. */
+ (nullable NSData *)binaryMetadataForIndexedAttributes:(NSDictionary<NSString *, NSDictionary *> *)entries
                                                  error:(NSError * _Nullable * _Nullable)error;

@end

NS_ASSUME_NONNULL_END
