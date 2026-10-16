/*
 * G-11 N7 type-aware source preflight macOS smoke, no real app data.
 * Replays the original CraneManager type0/type1/type2 enumerate contract
 * against a *mock* resolver with three throwaway OS-temp root directories.
 */
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import "CRBackupNativeTypedPreflight.h"

static NSString * const AppID = @"com.example.crane.native";
static NSString * const ContainerID = @"00000000-0000-4000-8000-000000000001";

@interface CR7FakeResolver : NSObject <CRBackupTypedSourceResolver>
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *mapping;
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@property (nonatomic) NSInteger mode;
@property (nonatomic) NSInteger passes;
@property (nonatomic) NSInteger supportCalls;
@property (nonatomic) NSInteger mapReads;
@end

@implementation CR7FakeResolver
- (BOOL)isApplicationSupportedByCrane:(NSString *)appID
{
    self.supportCalls++;
    /* N9: revoke eligibility only AFTER the first N5 root validation. */
    return [appID isEqualToString:AppID] &&
           !(self.mode == 7 && self.supportCalls >= 2);
}
- (NSArray<NSString *> *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)appID
{
    return [appID isEqualToString:AppID] ? @[ContainerID] : @[];
}
- (NSDictionary<NSString *, NSString *> *)pathsAssociatedToContainerWithIdentifier:(NSString *)container
                                                     ofApplicationWithIdentifier:(NSString *)appID
{
    self.mapReads++;
    if (![appID isEqualToString:AppID] ||
        !([container isEqualToString:ContainerID] ||
          [container isEqualToString:@"DEFAULT"]))
        return nil;
    /* N9: swap two different, still-readable root directories so the
     * late N5 check passes its path safety gate. Re-read comparison MUST
     * still catch that the mapping no longer matches typed enumeration. */
    if ((self.mode == 8 && self.mapReads >= 4) ||
        (self.mode == 9 && self.mapReads >= 5)) {
        return @{AppID:self.mapping[AppID],
                 @"group.com.example.crane.native":
                    self.mapping[@"com.example.crane.extension"],
                 @"com.example.crane.extension":
                    self.mapping[@"group.com.example.crane.native"]};
    }
    return self.mapping;
}
- (void)enumerate:(void (^)(NSInteger type, NSString *identifier,
                            NSString *path, BOOL *stop))block
 pathsAssociatedToContainerWithIdentifier:(NSString *)container
              ofApplicationWithIdentifier:(NSString *)appID
{
    if (![appID isEqualToString:AppID] ||
        !([container isEqualToString:ContainerID] ||
          [container isEqualToString:@"DEFAULT"]))
        return;
    self.passes++;
    for (NSUInteger i = 0; i < self.items.count; ++i) {
        NSDictionary *entry = self.items[i];
        NSInteger type = [entry[@"type"] integerValue];
        id key = entry[@"id"];
        id path = entry[@"path"];
        if (self.mode == 1 && i == 2) key = @"group.com.example.crane.native";
        if (self.mode == 2 && i == 2) type = 99;
        if (self.mode == 3 && i == 2) continue;
        if (self.mode == 4 && i == 1) path = entry[@"wrongPath"];
        if (self.mode == 5 && self.passes == 2 && i == 1) type = 2;
        if (self.mode == 6 && i == 0) type = 1;
        BOOL stop = NO;
        block(type, key, path, &stop);
        if (stop) break;
    }

    /* N10: replace the same path with a different directory inode only
     * after both enumerations. All directories are disposable OS-TEMP
     * fixtures; do not open or delete any child data. */
    if (self.mode == 10 && self.passes == 2) {
        NSString *path = self.mapping[AppID];
        NSString *prior = [path stringByAppendingString:@".n10-original"];
        NSFileManager *fm = NSFileManager.defaultManager;
        if (![fm moveItemAtPath:path toPath:prior error:NULL] ||
            ![fm createDirectoryAtPath:path withIntermediateDirectories:NO
                            attributes:nil error:NULL])
            abort();
    }
}
@end

static void Check(BOOL good, NSString *reason)
{
    if (!good) {
        NSLog(@"N7 typed source smoke: %@", reason);
        exit(1);
    }
}

static void Reject(CR7FakeResolver *resolver, NSInteger expected)
{
    NSError *error = nil;
    NSDictionary *report = [CRBackupNativeTypedPreflight
        inspectApplicationIdentifier:AppID
        containerIdentifier:ContainerID resolver:resolver error:&error];
    Check(!report && error.code == expected,
          @"invalid or changing type mapping accepted");
    Check([error.localizedDescription isEqualToString:
           @"Typed read-only source inventory unavailable"],
          @"typed source identity leaked in NSError");
}

int main(void)
{
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                          [[NSUUID UUID] UUIDString]];
        NSFileManager *fm = NSFileManager.defaultManager;
        NSError *error = nil;
        NSMutableDictionary *mapping = [NSMutableDictionary dictionary];
        NSArray *ids = @[AppID, @"group.com.example.crane.native",
                         @"com.example.crane.extension"];
        NSArray *names = @[@"app", @"group", @"plugin"];
        for (NSUInteger i = 0; i < ids.count; ++i) {
            NSString *path = [root stringByAppendingPathComponent:names[i]];
            Check([fm createDirectoryAtPath:path withIntermediateDirectories:YES
                          attributes:nil error:&error], @"create mock root");
            mapping[ids[i]] = path;
        }

        CR7FakeResolver *resolver = [CR7FakeResolver new];
        resolver.mapping = mapping;
        resolver.items = @[
            @{@"type":@0, @"id":AppID, @"path":mapping[AppID]},
            @{@"type":@1, @"id":ids[1], @"path":mapping[ids[1]],
              @"wrongPath":mapping[ids[2]]},
            @{@"type":@2, @"id":ids[2], @"path":mapping[ids[2]]},
        ];

        NSDictionary *report = [CRBackupNativeTypedPreflight
            inspectApplicationIdentifier:AppID containerIdentifier:ContainerID
            resolver:resolver error:&error];
        Check(report && !error && resolver.passes == 2 &&
              [report[@"rootCount"] intValue] == 3 &&
              [report[@"applicationRootCount"] intValue] == 1 &&
              [report[@"appGroupRootCount"] intValue] == 1 &&
              [report[@"plugInKitRootCount"] intValue] == 1 &&
              [report[@"rootDirectoryMetadataChecked"] intValue] == 3 &&
              ![report[@"sourceFilesEnumerated"] boolValue] &&
              ![report[@"sourceContentsRead"] boolValue] &&
              ![report[@"backupReady"] boolValue] &&
              ![report[@"restoreExecutable"] boolValue] &&
              report.count == 11,
              @"incorrect redacted type-aware root inventory");
        error = nil;
        NSDictionary *defaultReport = [CRBackupNativeTypedPreflight
            inspectApplicationIdentifier:AppID containerIdentifier:@"DEFAULT"
            resolver:resolver error:&error];
        Check(defaultReport && !error &&
              [defaultReport[@"plugInKitRootCount"] intValue] == 1,
              @"typed DEFAULT paths must be resolved by manager");

        resolver.mode = 1; Reject(resolver, 3); /* duplicate ID */
        resolver.mode = 2; Reject(resolver, 3); /* unsupported type */
        resolver.mode = 3; Reject(resolver, 5); /* missing PlugInKit entry */
        resolver.mode = 4; Reject(resolver, 6); /* wrong registered path */
        resolver.mode = 5; resolver.passes = 0;
        Reject(resolver, 3); /* changes between enumeration passes */
        resolver.mode = 6; Reject(resolver, 3); /* app root with group type */

        resolver.mode = 7; resolver.supportCalls = 0;
        Reject(resolver, 8); /* source app revoked after initial N5 */
        resolver.mode = 8; resolver.mapReads = 0;
        Reject(resolver, 9); /* root mapping swaps at late N5 */
        resolver.mode = 9; resolver.mapReads = 0;
        Reject(resolver, 9); /* map swaps after late root validation */
        resolver.mode = 10; resolver.passes = 0;
        Reject(resolver, 11); /* same path, replacement directory inode */

        resolver.mode = 0;
        resolver.mapping = @{AppID:mapping[AppID], ids[1]:mapping[ids[1]],
                             ids[2]:mapping[ids[1]]};
        Reject(resolver, 2); /* N5 rejects duplicate root */

        NSLog(@"G-11 N7 app/group/PlugInKit type-map cross-check: PASS");
    }
    return 0;
}
