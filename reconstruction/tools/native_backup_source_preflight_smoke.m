/*
 * G-11 N5 macOS Foundation smoke: fake manager-resolved root map.
 * No CraneManager/XPC, app container access, user payload or ZIP writes.
 */
#import <Foundation/Foundation.h>
#import <stdlib.h>
#import "CRBackupNativeSourcePreflight.h"

static NSString * const App = @"com.example.crane.native";
static NSString * const Container = @"00000000-0000-4000-8000-000000000001";

@interface CR5FakeResolver : NSObject <CRBackupSourceResolver>
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *mapping;
@property (nonatomic, copy) NSArray<NSString *> *registered;
@property (nonatomic) BOOL supported;
@end

@implementation CR5FakeResolver
- (BOOL)isApplicationSupportedByCrane:(NSString *)identifier
{
    return self.supported && [identifier isEqualToString:App];
}
- (NSArray<NSString *> *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)identifier
{
    return [identifier isEqualToString:App] ? self.registered : @[];
}
- (NSDictionary<NSString *, NSString *> *)pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
                                                     ofApplicationWithIdentifier:(NSString *)identifier
{
    return [identifier isEqualToString:App] &&
           ([containerID isEqualToString:Container] ||
            [containerID isEqualToString:@"DEFAULT"]) ?
           self.mapping : nil;
}
@end

static void Check(BOOL condition, NSString *message)
{
    if (!condition) {
        NSLog(@"N5 native source-root preflight: %@", message);
        exit(1);
    }
}

static void ExpectError(CR5FakeResolver *resolver, NSString *appID,
                        NSString *containerID, NSInteger code)
{
    NSError *error = nil;
    NSDictionary *result = [CRBackupNativeSourcePreflight
        preflightApplicationIdentifier:appID
        containerIdentifier:containerID resolver:resolver error:&error];
    Check(!result && error.code == code, @"unexpected preflight result/error code");
    Check([error.localizedDescription isEqual:
           @"Crane source roots unavailable for read-only preflight"],
          @"must not leak root names or paths in error");
}

int main(void)
{
    @autoreleasepool {
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:
                           [[NSUUID UUID] UUIDString]];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        Check([fm createDirectoryAtPath:
               [root stringByAppendingPathComponent:@"app"]
               withIntermediateDirectories:YES attributes:nil error:&error],
              @"fake source directory");
        Check([fm createDirectoryAtPath:
               [root stringByAppendingPathComponent:@"group"]
               withIntermediateDirectories:NO attributes:nil error:&error],
              @"fake app-group directory");
        NSString *app = [root stringByAppendingPathComponent:@"app"];
        NSString *group = [root stringByAppendingPathComponent:@"group"];
        CR5FakeResolver *resolver = [CR5FakeResolver new];
        resolver.supported = YES;
        resolver.registered = @[Container];
        resolver.mapping = @{
            App:app,
            @"group.com.example.crane.native":group,
        };
        NSDictionary *result = [CRBackupNativeSourcePreflight
            preflightApplicationIdentifier:App containerIdentifier:Container
            resolver:resolver error:&error];
        Check(result != nil && error == nil, @"valid manager mapping failed");
        Check([result[@"status"] isEqual:
             @"registered_source_roots_accessible_not_backup_ready"] &&
              [result[@"rootCount"] integerValue] == 2 &&
              [result[@"associatedGroupCount"] integerValue] == 1 &&
              [result[@"sourceDirectoryRootsReadable"] boolValue] &&
              ![result[@"sourceContentsRead"] boolValue] &&
              ![result[@"sourceFilesEnumerated"] boolValue] &&
              ![result[@"backupReady"] boolValue] &&
              ![result[@"restoreExecutable"] boolValue] &&
              result.count == 9, @"preflight report must be fixed/redacted");

        error = nil;
        NSDictionary *defaultResult = [CRBackupNativeSourcePreflight
            preflightApplicationIdentifier:App containerIdentifier:@"DEFAULT"
            resolver:resolver error:&error];
        Check(defaultResult && !error && [defaultResult[@"rootCount"] intValue] == 2,
              @"DEFAULT source selection should use manager-resolved mapping");
        ExpectError(resolver, App, @"00000000-0000-4000-8000-000000000999", 3);
        ExpectError(resolver, @"com.example.not.registered", Container, 2);
        ExpectError(resolver, @"../unsafe", Container, 1);

        resolver.mapping = @{App:app,
                             @"group.com.example.crane.native":app};
        ExpectError(resolver, App, Container, 7); /* duplicate canonical root */
        resolver.mapping = @{App:root, @"group.com.example.crane.native":app};
        ExpectError(resolver, App, Container, 8); /* nested source root */
        resolver.mapping = @{App:app,
                             @"group.com.example.crane.native":@"/"};
        ExpectError(resolver, App, Container, 7); /* outside OS temp */
        resolver.mapping = @{App:app,
                             @"group.com.example.crane.native":@"/missing/dummy"};
        ExpectError(resolver, App, Container, 7); /* non-existent */
        resolver.mapping = @{App:app, @"../bad.group":group};
        ExpectError(resolver, App, Container, 6);
        resolver.mapping = @{@"group.com.example.crane.native":group};
        ExpectError(resolver, App, Container, 5);

        NSString *alias = [root stringByAppendingPathComponent:@"alias"];
        Check([fm createSymbolicLinkAtPath:alias withDestinationPath:app
                                    error:&error], @"fake symlink create");
        resolver.mapping = @{App:alias};
        ExpectError(resolver, App, Container, 7); /* source symlink */
        resolver.mapping = @{App:app};
        resolver.supported = NO;
        ExpectError(resolver, App, Container, 2);

        NSLog(@"G-11 N5 resolver-backed source root preflight (no payload): PASS");
    }
    return 0;
}
