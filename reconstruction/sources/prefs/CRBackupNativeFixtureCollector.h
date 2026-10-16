/*
 * G-11 N4 — capture real POSIX metadata and file bytes from a disposable
 * *fake* app tree under OS temp, then feed N2's safe ZIP writer.
 * Never accepts an arbitrary application/container path.
 */
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface CRBackupNativeFixtureCollector : NSObject
/* The only source is root/source/com.example.crane.native, with the N2
 * disposable marker and output directory under NSTemporaryDirectory().
 * No caller-supplied source path, app ID, vendor ID, or Keychain access.
 * Source scan is read-only and bounded; output is N2's exclusive fixture. */
+ (nullable NSDictionary<NSString *, id> *)writeDisposableSourceBackupAtRoot:(NSString *)root
                                                                       error:(NSError * _Nullable * _Nullable)error;
@end
NS_ASSUME_NONNULL_END
