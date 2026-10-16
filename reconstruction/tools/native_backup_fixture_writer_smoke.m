/*
 * G-11 N2: macOS-only disposable in-memory ZIP64 writer smoke.
 * Builds binary Info/Metadata in memory, stores fake payload, checks N0/N1.
 * No iPhone app container is ever opened or modified.
 */
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import <stdio.h>
#import <string.h>
#import "CRBackupNativeCore.h"
#import "CRBackupArchiveSurvey.h"
#import "CRBackupNativeFixtureWriter.h"

static void Check(BOOL value, NSString *label)
{
    if (!value) {
        NSLog(@"G-11 N2 synthetic writer: %@", label);
        exit(1);
    }
}

int main(void)
{
    @autoreleasepool {
        NSString *parent = NSTemporaryDirectory();
        NSString *root = [parent stringByAppendingPathComponent:
            [[NSUUID UUID] UUIDString]];
        NSFileManager *manager = [NSFileManager defaultManager];
        NSError *error = nil;
        Check([manager createDirectoryAtPath:root withIntermediateDirectories:NO
                                  attributes:@{NSFilePosixPermissions:@0700}
                                       error:&error], @"temp fixture root create");
        NSString *output = [root stringByAppendingPathComponent:@"output"];
        Check([manager createDirectoryAtPath:output withIntermediateDirectories:NO
                                  attributes:@{NSFilePosixPermissions:@0700}
                                       error:&error], @"temp output create");
        NSString *marker = [root stringByAppendingPathComponent:@".crane-disposable-fixture"];
        Check([@"CRANE_DISPOSABLE_FIXTURE_V1\n" writeToFile:marker
                                            atomically:NO
                                              encoding:NSUTF8StringEncoding
                                                 error:&error], @"fixture marker create");
        NSDictionary *paths = @{
            @"com.example.crane.native":@"/disposable/not-a-real-application",
        };
        NSData *info = [CRBackupNativeCore
            binarySingleInfoForApplicationIdentifier:@"com.example.crane.native"
            containerIdentifier:@"00000000-0000-4000-8000-000000000001"
            containerName:@"test-only"
            originalPaths:paths
            deviceIdentifierForVendor:@"00000000-0000-4000-8000-000000000002"
            error:&error];
        Check(info != nil && !error, @"binary Info.plist");
        NSData *metadata = [CRBackupNativeCore binaryMetadataForIndexedAttributes:@{
            @"com.example.crane.native": @{NSFilePosixPermissions:@0700},
            @"com.example.crane.native/one.txt": @{NSFilePosixPermissions:@0600},
            @"com.example.crane.native/zero.txt": @{NSFilePosixPermissions:@0600},
        } error:&error];
        Check(metadata != nil && !error, @"binary Metadata.plist");
        NSData *token = [@"DUMMY-SYNTHETIC-ONLY\n" dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *files = @{
            @"com.example.crane.native/one.txt":token,
            @"com.example.crane.native/zero.txt":[NSData data],
        };
        NSArray *directories = @[@"com.example.crane.native/"];
        error = nil;
        NSDictionary *result = [CRBackupNativeFixtureWriter
            writeDisposableSingleAtRoot:root
            infoData:info metadataData:metadata files:files
            directories:directories error:&error];
        Check(result && !error, @"native fixture ZIP write");
        Check([result[@"entryCount"] intValue] == 5 &&
              [result[@"archiveBytes"] intValue] > 100 &&
              ![result[@"deviceDataTouched"] boolValue] &&
              ![result[@"originalCompatibilityProven"] boolValue] &&
              ![result[@"restoreExecutable"] boolValue],
              @"native fixture result must remain non-production");

        NSString *archive = [output stringByAppendingPathComponent:@"native-single.cranect"];
        NSDictionary *nativeInfo = [CRBackupNativeCore
            readSingleBackupInfoAtPath:archive error:&error];
        Check(nativeInfo && !error, @"N0 must read writer ZIP64 Info.plist");
        Check([nativeInfo[@"applicationIdentifier"]
               isEqualToString:@"com.example.crane.native"],
              @"N0 Info identity mismatch");
        NSDictionary *survey = [CRBackupArchiveSurvey
            inspectSingleArchiveAtPath:archive error:&error];
        Check(survey && !error, @"N1 must accept native ZIP64 writer envelope");
        Check([survey[@"entryCount"] intValue] == 5 &&
              [survey[@"fileCount"] intValue] == 4 &&
              [survey[@"directoryCount"] intValue] == 1 &&
              [survey[@"keychainEntryCount"] intValue] == 0 &&
              ![survey[@"payloadCRCVerified"] boolValue] &&
              ![survey[@"restoreExecutable"] boolValue],
              @"N1 must report structure only");

        NSDictionary *nonKeychainCRC = [CRBackupArchiveSurvey
            verifyNonKeychainPayloadAtPath:archive error:&error];
        Check(nonKeychainCRC && !error &&
              [nonKeychainCRC[@"nonKeychainPayloadCRCVerified"] boolValue] &&
              [nonKeychainCRC[@"payloadCRCVerified"] boolValue] &&
              [nonKeychainCRC[@"verifiedNonKeychainMembers"] integerValue] == 5 &&
              ![nonKeychainCRC[@"restoreExecutable"] boolValue],
              @"N3 must stream and CRC-check every dummy entry");

        NSData *before = [NSData dataWithContentsOfFile:archive];
        error = nil;
        Check(![CRBackupNativeFixtureWriter writeDisposableSingleAtRoot:root
                   infoData:info metadataData:metadata files:files
                   directories:directories error:&error] && error.code == 3,
              @"O_EXCL must prevent fixture overwrite");
        Check([before isEqualToData:[NSData dataWithContentsOfFile:archive]],
              @"failed overwrite must leave archive unchanged");

        error = nil;
        Check(![CRBackupNativeFixtureWriter writeDisposableSingleAtRoot:root
                   infoData:info metadataData:metadata
                   files:@{@"com.example.crane.native/../escape":token}
                   directories:directories error:&error] && error.code == 1,
              @"path traversal should fail before filesystem access");
        error = nil;
        Check(![CRBackupNativeFixtureWriter writeDisposableSingleAtRoot:root
                   infoData:info metadataData:metadata
                   files:@{@"Keychain.plist":token}
                   directories:directories error:&error] && error.code == 1,
              @"Keychain filename must never be written");
        error = nil;
        Check(![CRBackupNativeFixtureWriter writeDisposableSingleAtRoot:root
                   infoData:info metadataData:metadata files:files
                   directories:@[@"com.example.crane.native/one.txt/"]
                   error:&error] && error.code == 1,
              @"file/directory collision must fail");
        error = nil;
        Check(![CRBackupNativeFixtureWriter
                 writeDisposableSingleAtRoot:@"/"
                 infoData:info metadataData:metadata
                 files:files directories:directories error:&error] && error.code == 2,
              @"must reject an unmarked non-disposable root");

        NSLog(@"G-11 N2 native dummy-data single ZIP64 writer + N0/N1: PASS");
        /* Emit ONLY a disposable synthetic temp path for CI's independent
         * Python ZIP CRC verifier; never a source/container path. */
        fprintf(stdout, "CRANE_N2_FIXTURE=%s\n", archive.fileSystemRepresentation);
        fflush(stdout);
    }
    return 0;
}
