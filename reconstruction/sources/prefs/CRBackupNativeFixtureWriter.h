/*
 * G-11 N2 — disposable in-memory single-container ZIP64 writer.
 * Not a production backup API. No iPhone container or Keychain reads.
 */
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

@interface CRBackupNativeFixtureWriter : NSObject

/* Writes a NEW "native-single.cranect" in pre-existing `root/output`,
 * only if root is a non-symlink child of NSTemporaryDirectory() with
 * the exact .crane-disposable-fixture marker.
 *
 * Info/Metadata binary plist and ordinary data entries are supplied wholly
 * in memory from a synthetic test. No source files are traversed. No
 * Keychain, passwords, multiple containers, real metadata, or Restore.
 */
+ (nullable NSDictionary<NSString *, id> *)writeDisposableSingleAtRoot:(NSString *)root
                                                               infoData:(NSData *)info
                                                           metadataData:(NSData *)metadata
                                                                  files:(NSDictionary<NSString *, NSData *> *)files
                                                            directories:(NSArray<NSString *> *)directories
                                                                  error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
