/*
 * G-11 N1: read-only, bounded ZIP CENTRAL/LOCAL structure survey.
 * N1 inspects only ZIP headers and does not read app or Keychain payload.
 * N3 explicitly streams non-Keychain payload bytes for bounded CRC checks.
 * Both modes expose counts only, never paths or contents, and never Restore.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CRBackupArchiveSurvey : NSObject
+ (nullable NSDictionary<NSString *, id> *)inspectSingleArchiveAtPath:(NSString *)path
                                                               error:(NSError * _Nullable * _Nullable)error;

/* Verify actual CRC32 of EVERY non-Keychain ZIP member by streaming raw
 * Deflate or Store. All payload buffers are discarded; Keychain.plist
 * (including nested occurrences) is never opened/decompressed. Still
 * no archive extraction, filesystem writes, or Restore permission. */
+ (nullable NSDictionary<NSString *, id> *)verifyNonKeychainPayloadAtPath:(NSString *)path
                                                                  error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
