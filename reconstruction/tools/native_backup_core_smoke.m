/* macOS Foundation smoke: native single Info read, binary Info writer and
 * writable metadata filter. Archives contain synthetic identifiers only.
 * No CraneManager/iOS environment or any archive extraction required. */
#import <Foundation/Foundation.h>
#import "CRBackupNativeCore.h"

static void Check(BOOL yes, NSString *message)
{
    if (!yes) {
        NSLog(@"native G-11 smoke: %@", message);
        exit(1);
    }
}

int main(int argc, const char **argv)
{
    @autoreleasepool {
        Check(argc == 6, @"requires synthetic good / bad-CRC / invalid-info / bad-central-size / bad-central-CRC ZIP");
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *badCRC = [NSString stringWithUTF8String:argv[2]];
        NSString *badPlist = [NSString stringWithUTF8String:argv[3]];
        NSString *badCentralSize = [NSString stringWithUTF8String:argv[4]];
        NSString *badCentralCRC = [NSString stringWithUTF8String:argv[5]];
        NSError *error = nil;
        NSDictionary *info = [CRBackupNativeCore
            readSingleBackupInfoAtPath:path error:&error];
        if (!info || error) {
            /* Fixed numeric stage only, never path / app ID / plist payload. */
            NSLog(@"native G-11 reader rejected synthetic ZIP at stage %ld",
                  (long)error.code);
        }
        Check(info != nil && error == nil, @"valid first-entry ZIP64 Info rejected");
        Check([info[@"applicationIdentifier"] isEqual:@"com.example.crane.native"],
              @"incorrect fake app identifier");
        Check([info[@"containerIdentifier"]
               isEqual:@"00000000-0000-4000-8000-000000000001"],
              @"incorrect fake container ID");
        Check([info[@"deviceIdentifierForVendor"]
               isEqual:@"00000000-0000-4000-8000-000000000002"],
              @"vendor-ID string read failed");
        Check([info[@"originalPaths"] count] == 2,
              @"originalPaths dictionary count mismatch");

        error = nil;
        Check(![CRBackupNativeCore readSingleBackupInfoAtPath:badCRC error:&error]
              && error != nil, @"corrupted data descriptor CRC accepted");
        error = nil;
        Check(![CRBackupNativeCore readSingleBackupInfoAtPath:badPlist error:&error]
              && error != nil, @"invalid Info binary plist accepted");
        error = nil;
        Check(![CRBackupNativeCore readSingleBackupInfoAtPath:badCentralSize error:&error]
              && error != nil, @"contradictory central-directory compressed size accepted");
        error = nil;
        Check(![CRBackupNativeCore readSingleBackupInfoAtPath:badCentralCRC error:&error]
              && error != nil, @"contradictory central-directory CRC accepted");
        error = nil;
        Check(![CRBackupNativeCore readSingleBackupInfoAtPath:
                   @"/nonexistent-crane-test.cranect" error:&error]
              && error != nil, @"missing archive accepted");

        error = nil;
        NSData *binary = [CRBackupNativeCore
            binarySingleInfoForApplicationIdentifier:info[@"applicationIdentifier"]
            containerIdentifier:info[@"containerIdentifier"]
            containerName:info[@"containerName"]
            originalPaths:info[@"originalPaths"]
            deviceIdentifierForVendor:info[@"deviceIdentifierForVendor"]
            error:&error];
        Check(binary.length > 8 && error == nil, @"binary manifest failed");
        Check(memcmp(binary.bytes, "bplist00", 8) == 0,
              @"binary Info.plist magic missing");
        id roundTrip = [NSPropertyListSerialization
            propertyListWithData:binary
                         options:NSPropertyListImmutable
                          format:NULL error:&error];
        Check([roundTrip isEqual:info] && error == nil,
              @"Info.plist binary roundtrip unequal");

        error = nil;
        Check(![CRBackupNativeCore
                binarySingleInfoForApplicationIdentifier:@""
                containerIdentifier:@"DEFAULT"
                containerName:@"invalid"
                originalPaths:@{@"com.example.crane.native":@"/tmp/test"}
                deviceIdentifierForVendor:nil error:&error] && error != nil,
              @"invalid app identity accepted");
        error = nil;
        Check(![CRBackupNativeCore
                binarySingleInfoForApplicationIdentifier:@"com.example.a"
                containerIdentifier:@"DEFAULT"
                containerName:@"invalid"
                originalPaths:@{@"com.example.a":@"/tmp/../escape"}
                deviceIdentifierForVendor:nil error:&error] && error != nil,
              @"traversal originalPaths accepted");

        NSDictionary *filtered = [CRBackupNativeCore writableMetadataAttributes:@{
            NSFilePosixPermissions: @0644,
            NSFileCreationDate: [NSDate dateWithTimeIntervalSince1970:1000],
            NSFileOwnerAccountName: @"disposable-owner",
            NSFileExtensionHidden: @NO,
            NSFileOwnerAccountID: @1000,
            @"NSFileUnknownDangerousAttribute": @"NO",
            NSFileImmutable: @"invalid-boolean",
            NSFileGroupOwnerAccountID: @YES,
        }];
        Check(filtered.count == 5, @"writable attribute type filter mismatch");
        Check(filtered[NSFileOwnerAccountID] != nil &&
              filtered[NSFileGroupOwnerAccountID] == nil &&
              filtered[@"NSFileUnknownDangerousAttribute"] == nil,
              @"unsafe or unexpected metadata accepted");
        error = nil;
        NSData *metadataData = [CRBackupNativeCore binaryMetadataForIndexedAttributes:@{
            @"com.example.crane.native/Library/file.txt": @{
                NSFilePosixPermissions: @0640, NSFileImmutable: @NO,
                @"NSFileNotWritablySerializable": @"discarded",
            },
        } error:&error];
        Check(metadataData.length > 8 && error == nil,
              @"binary Metadata.plist creation failed");
        NSDictionary *metadata = [NSPropertyListSerialization
            propertyListWithData:metadataData
                         options:NSPropertyListImmutable
                          format:NULL error:&error];
        NSDictionary *metadataRow = metadata[@"com.example.crane.native/Library/file.txt"];
        Check(metadataRow.count == 2 && metadataRow[NSFilePosixPermissions] != nil,
              @"Metadata.plist writable attributes incorrectly filtered");
        error = nil;
        Check(![CRBackupNativeCore binaryMetadataForIndexedAttributes:@{
                @"com.example.crane.native/../escape": @{
                    NSFilePosixPermissions: @0600,
                },
            } error:&error] && error != nil, @"unsafe ZIP metadata path accepted");

        NSLog(@"G-11 N0 native Foundation Info preview + binary manifest: PASS");
    }
    return 0;
}
