/*
 * G-11 N4: native metadata snapshot of a disposable fake source tree.
 * Native collector -> N2 ZIP writer -> N0/N1/N3 read/verify.
 * All source data here is invented under a fresh OS TEMP directory.
 */
#import <Foundation/Foundation.h>
#import <stdio.h>
#import <stdlib.h>
#import <unistd.h>
#import <sys/stat.h>
#import "CRBackupNativeCore.h"
#import "CRBackupNativeFixtureWriter.h"
#import "CRBackupNativeFixtureCollector.h"
#import "CRBackupArchiveSurvey.h"

static void Check(BOOL pass, NSString *message)
{
    if (!pass) {
        NSLog(@"G-11 N4 smoke: %@", message);
        exit(1);
    }
}

static NSString *FreshRoot(void)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [[NSUUID UUID] UUIDString]];
    NSError *error = nil;
    Check([fm createDirectoryAtPath:root withIntermediateDirectories:NO
                         attributes:@{NSFilePosixPermissions:@0700}
                              error:&error], @"fixture root create");
    NSString *out = [root stringByAppendingPathComponent:@"output"];
    Check([fm createDirectoryAtPath:out withIntermediateDirectories:NO
                         attributes:@{NSFilePosixPermissions:@0700}
                              error:&error], @"fixture output create");
    NSString *source = [root stringByAppendingPathComponent:
        @"source/com.example.crane.native"];
    Check([fm createDirectoryAtPath:source withIntermediateDirectories:YES
                         attributes:@{NSFilePosixPermissions:@0700}
                              error:&error], @"fixture source create");
    Check([@"CRANE_DISPOSABLE_FIXTURE_V1\n" writeToFile:
        [root stringByAppendingPathComponent:@".crane-disposable-fixture"]
        atomically:NO encoding:NSUTF8StringEncoding error:&error],
        @"fixture marker create");
    return root;
}

static NSString *AppPath(NSString *root, NSString *relative)
{
    return [[root stringByAppendingPathComponent:
        @"source/com.example.crane.native"] stringByAppendingPathComponent:relative];
}

static void Put(NSString *path, NSData *data, mode_t mode)
{
    NSError *error = nil;
    Check([data writeToFile:path options:NSDataWritingWithoutOverwriting
                     error:&error], @"fake fixture file create");
    Check(chmod(path.fileSystemRepresentation, mode) == 0,
          @"fixture permission setup");
}

static void CheckNoOutput(NSString *root, NSInteger expected)
{
    NSError *error = nil;
    NSDictionary *result = [CRBackupNativeFixtureCollector
        writeDisposableSourceBackupAtRoot:root error:&error];
    Check(result == nil && error.code == expected,
          @"unsafe fixture was not rejected at the expected stage");
    Check(![[NSFileManager defaultManager] fileExistsAtPath:
            [root stringByAppendingPathComponent:@"output/native-single.cranect"]],
          @"unsafe source must be refused BEFORE archive creation");
}

int main(void)
{
    @autoreleasepool {
        NSString *root = FreshRoot();
        NSString *library = AppPath(root, @"Library/Preferences");
        NSError *error = nil;
        Check([[NSFileManager defaultManager] createDirectoryAtPath:library
            withIntermediateDirectories:YES
            attributes:@{NSFilePosixPermissions:@0750} error:&error],
            @"fake Preferences directory");
        NSString *settings = AppPath(root, @"Library/Preferences/settings.bin");
        NSData *marker = [@"DUMMY-SOURCE-METADATA-ONLY\n"
                         dataUsingEncoding:NSUTF8StringEncoding];
        Put(settings, marker, 0640);
        NSString *zero = AppPath(root, @"zero.txt");
        Put(zero, [NSData data], 0600);
        NSString *nested = AppPath(root, @"nested");
        Check([[NSFileManager defaultManager] createDirectoryAtPath:nested
            withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0755}
            error:&error], @"nested fake directory");
        Put(AppPath(root, @"nested/child.dat"),
            [@"FAKE-NESTED" dataUsingEncoding:NSUTF8StringEncoding], 0644);

        NSDictionary *report = [CRBackupNativeFixtureCollector
            writeDisposableSourceBackupAtRoot:root error:&error];
        Check(report != nil && error == nil,
              @"N4 fake tree capture + native ZIP generation");
        Check([report[@"fileCount"] intValue] == 3 &&
              [report[@"directoryCount"] intValue] == 4 &&
              [report[@"metadataFromFilesystem"] boolValue] &&
              ![report[@"productionBackupAvailable"] boolValue] &&
              ![report[@"restoreExecutable"] boolValue],
              @"N4 summary should contain only counts and safety flags");

        NSString *archive = [root stringByAppendingPathComponent:
            @"output/native-single.cranect"];
        error = nil;
        NSDictionary *info = [CRBackupNativeCore readSingleBackupInfoAtPath:
                              archive error:&error];
        Check(info && error == nil && [info[@"containerName"] isEqual:@"test-only"],
              @"N0 native Info reader must accept captured fixture");
        NSDictionary *structure = [CRBackupArchiveSurvey
            inspectSingleArchiveAtPath:archive error:&error];
        Check(structure && !error && [structure[@"entryCount"] intValue] == 9 &&
              [structure[@"directoryCount"] intValue] == 4,
              @"N1 ZIP structure must contain all seven fake entries");
        NSDictionary *crc = [CRBackupArchiveSurvey
            verifyNonKeychainPayloadAtPath:archive error:&error];
        Check(crc && !error && [crc[@"payloadCRCVerified"] boolValue] &&
              [crc[@"verifiedNonKeychainMembers"] intValue] == 9 &&
              ![crc[@"restoreExecutable"] boolValue],
              @"N3 must independently check every native ZIP payload CRC");

        error = nil;
        Check(![CRBackupNativeFixtureCollector
                writeDisposableSourceBackupAtRoot:root error:&error] &&
              error.code == 4, @"second N4 call must not overwrite");
        NSString *symlinkRoot = FreshRoot();
        NSString *symlinkPath = AppPath(symlinkRoot, @"linked.txt");
        Check(symlink(settings.fileSystemRepresentation,
                      symlinkPath.fileSystemRepresentation) == 0,
              @"create disposable symlink test");
        CheckNoOutput(symlinkRoot, 2);

        NSString *hardlinkRoot = FreshRoot();
        NSString *outside = AppPath(hardlinkRoot, @"outside.dat");
        NSString *linked = AppPath(hardlinkRoot, @"linked.dat");
        Put(outside, marker, 0600);
        Check(link(outside.fileSystemRepresentation,
                   linked.fileSystemRepresentation) == 0, @"fake hardlink setup");
        CheckNoOutput(hardlinkRoot, 2);

        NSString *reservedRoot = FreshRoot();
        Put(AppPath(reservedRoot, @"Keychain.plist"), marker, 0600);
        CheckNoOutput(reservedRoot, 2);

        NSString *largeRoot = FreshRoot();
        Put(AppPath(largeRoot, @"oversize.bin"),
            [NSMutableData dataWithLength:300 * 1024], 0600);
        CheckNoOutput(largeRoot, 2);

        NSString *missingMarker = FreshRoot();
        Check([[NSFileManager defaultManager] removeItemAtPath:
            [missingMarker stringByAppendingPathComponent:
              @".crane-disposable-fixture"] error:&error],
              @"remove disposable marker test");
        CheckNoOutput(missingMarker, 1);

        fprintf(stdout, "CRANE_N4_FIXTURE=%s\n", root.fileSystemRepresentation);
        NSLog(@"G-11 N4 fake source + actual filesystem metadata + N0/N1/N3: PASS");
    }
    return 0;
}
