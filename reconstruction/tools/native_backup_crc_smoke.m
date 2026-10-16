/*
 * G-11 N3: verifies CRC32 of all non-Keychain ZIP entries in the
 * synthetic test archive, without extracting any files or reading
 * Keychain. Reports only fixed counts/booleans.
 */
#import <Foundation/Foundation.h>
#import "CRBackupArchiveSurvey.h"

static void Check(BOOL ok, NSString *reason)
{
    if (!ok) {
        NSLog(@"G-11 N3 smoke: %@", reason);
        exit(1);
    }
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        Check(argc == 7, @"requires six disposable ZIP fixtures");
        for (int index = 1; index < argc; ++index) {
            NSString *path = [NSString stringWithUTF8String:argv[index]];
            NSError *error = nil;
            NSDictionary *structure = [CRBackupArchiveSurvey
                inspectSingleArchiveAtPath:path error:&error];
            Check(structure && error == nil &&
                  ![structure[@"payloadCRCVerified"] boolValue],
                  @"N1 header-only survey must accept the constructed fixture");
            error = nil;
            NSDictionary *result = [CRBackupArchiveSurvey
                verifyNonKeychainPayloadAtPath:path error:&error];
            if (index == 2) {
                Check(!result && error && error.code == 4,
                      @"changed ordinary payload must FAIL CRC");
                continue;
            }
            Check(result && error == nil,
                  @"valid non-Keychain CRC scan failed");
            Check([result[@"status"] isEqualToString:
                   @"non_keychain_crc_verified_not_restorable"] &&
                  [result[@"nonKeychainPayloadCRCVerified"] boolValue] &&
                  ![result[@"keychainContentsRead"] boolValue] &&
                  ![result[@"restoreExecutable"] boolValue],
                  @"N3 must remain read-only and non-restorable");

            BOOL containsKeychain = index == 3 || index == 4;
            Check([result[@"keychainEntriesSkipped"] integerValue] ==
                  (containsKeychain ? 1 : 0) &&
                  [result[@"payloadCRCVerified"] boolValue] == !containsKeychain,
                  @"Keychain must be explicitly excluded from full-payload CRC");
            Check([result[@"verifiedNonKeychainMembers"] integerValue] == 4,
                  @"unexpected count of CRC-verified members");
        }
        NSLog(@"G-11 N3 bounded non-Keychain CRC32 verification: PASS");
    }
    return 0;
}
