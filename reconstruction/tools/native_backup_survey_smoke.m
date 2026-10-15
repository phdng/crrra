/*
 * G-11 N1 macOS Foundation smoke — headers only, never payload extraction.
 * Args: valid, traversal, duplicate, symlink, missing-metadata,
 * local-name-tamper, central-method-tamper, descriptor-CRC-tamper,
 * synthetic Keychain-presence-only ZIP.
 */
#import <Foundation/Foundation.h>
#import "CRBackupArchiveSurvey.h"

static void Check(BOOL ok, NSString *reason)
{
    if (!ok) {
        NSLog(@"native G-11 N1 smoke: %@", reason);
        exit(1);
    }
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        Check(argc == 10, @"wrong synthetic ZIP fixture argument count");
        for (int index = 1; index < argc; ++index) {
            NSString *path = [NSString stringWithUTF8String:argv[index]];
            NSError *error = nil;
            NSDictionary *report = [CRBackupArchiveSurvey
                inspectSingleArchiveAtPath:path error:&error];
            if (index == 1 || index == 9) {
                Check(report != nil && error == nil,
                      @"legitimate ZIP structure was rejected");
                Check([report[@"status"] isEqualToString:
                    @"single_archive_structure_inspected_not_restorable"],
                    @"missing fixed non-restorable result");
                Check([report[@"entryCount"] integerValue] == (index == 9 ? 5 : 4),
                      @"incorrect archive entry count");
                Check([report[@"fileCount"] integerValue] == (index == 9 ? 4 : 3),
                      @"incorrect ZIP file count");
                Check([report[@"directoryCount"] integerValue] == 1,
                      @"incorrect ZIP directory count");
                Check([report[@"keychainEntryCount"] integerValue] ==
                      (index == 9 ? 1 : 0),
                      @"incorrect non-content Keychain presence count");
                Check(![report[@"payloadCRCVerified"] boolValue] &&
                      ![report[@"keychainContentsRead"] boolValue] &&
                      ![report[@"restoreExecutable"] boolValue],
                      @"unsafe verified/restorable result");
                Check(report.count == 10, @"unexpected sensitive report fields");
            } else {
                Check(report == nil && error != nil,
                      @"unsafe or tampered ZIP structure was accepted");
            }
        }
        NSLog(@"G-11 N1 bounded read-only whole ZIP structural survey: PASS");
    }
    return 0;
}
