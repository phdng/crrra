/*
 * G-11 N1: read-only, bounded ZIP CENTRAL/LOCAL structure survey.
 * DOES NOT read app payload or Keychain bytes, decompress files, test their
 * CRCs, or authorize Restore. Counts only; no filenames/paths exposed.
 */
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface CRBackupArchiveSurvey : NSObject
+ (nullable NSDictionary<NSString *, id> *)inspectSingleArchiveAtPath:(NSString *)path
                                                               error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
