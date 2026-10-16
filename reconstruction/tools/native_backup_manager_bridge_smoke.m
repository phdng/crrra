/*
 * G-11 N6 macOS smoke: exercise the real singleton bridge code, but supply
 * a dynamic in-process fake CraneManager class with ONLY three READ methods.
 * No device app or helper is ever loaded on macOS.
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdlib.h>
#import "CRBackupNativeManagerPreflight.h"

static id gManager = nil;
static NSString *gAppRoot = nil;
static NSString *gGroupRoot = nil;
static BOOL gSupported = YES;
static NSInteger gReadCalls = 0;
static BOOL gDuplicate = NO;

static id CR6MockShared(id self, SEL selector)
{
    (void)self; (void)selector;
    return gManager;
}
static BOOL CR6MockIsSupported(id self, SEL selector, NSString *appID)
{
    (void)self; (void)selector;
    ++gReadCalls;
    return gSupported && [appID isEqualToString:@"com.example.crane.native"];
}
static id CR6MockRegistered(id self, SEL selector, NSString *appID)
{
    (void)self; (void)selector;
    ++gReadCalls;
    return [appID isEqualToString:@"com.example.crane.native"] ?
        @[@"00000000-0000-4000-8000-000000000001"] : @[];
}
static id CR6MockAssociated(id self, SEL selector,
                             NSString *containerID, NSString *appID)
{
    (void)self; (void)selector;
    ++gReadCalls;
    if (![appID isEqualToString:@"com.example.crane.native"] ||
        !([containerID isEqualToString:@"DEFAULT"] ||
          [containerID isEqualToString:@"00000000-0000-4000-8000-000000000001"]))
        return nil;
    return @{
        @"com.example.crane.native":gAppRoot,
        @"group.com.example.crane.native":(gDuplicate ? gAppRoot : gGroupRoot),
    };
}
static void Check(BOOL ok, NSString *reason)
{
    if (!ok) {
        NSLog(@"N6 native manager bridge smoke: %@", reason);
        exit(1);
    }
}
static void ExpectFailure(NSString *appID, NSString *container, NSInteger code)
{
    NSError *error = nil;
    NSDictionary *report = [CRBackupNativeManagerPreflight
        probeRegisteredApplication:appID containerIdentifier:container
        error:&error];
    Check(report == nil && error && error.code == code,
          @"expected a fail-closed redacted error");
    Check([error.localizedDescription isEqualToString:
          @"Crane read-only manager source preflight unavailable"] &&
          ![error.localizedDescription containsString:@"com.example"],
          @"source identity leaked in error");
}

int main(void)
{
    @autoreleasepool {
        /* Validate failure if the real manager class is missing. */
        ExpectFailure(@"com.example.crane.native", @"DEFAULT", 1);

        Class cls = objc_allocateClassPair([NSObject class], "CraneManager", 0);
        Check(cls != Nil, @"cannot register disposable fake CraneManager");
        Check(class_addMethod(object_getClass(cls), @selector(sharedManager),
                              (IMP)CR6MockShared, "@@:"),
              @"missing mock singleton method");
        Check(class_addMethod(cls, @selector(isApplicationSupportedByCrane:),
                              (IMP)CR6MockIsSupported, "B@:@"),
              @"missing mock supported-app selector");
        Check(class_addMethod(cls,
                              @selector(containerIdentifiersOfApplicationWithIdentifier:),
                              (IMP)CR6MockRegistered, "@@:@"),
              @"missing mock registered-container selector");
        Check(class_addMethod(cls,
             @selector(pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:),
             (IMP)CR6MockAssociated, "@@:@@"),
             @"missing mock associated paths selector");
        objc_registerClassPair(cls);

        gManager = [[cls alloc] init];
        NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [[NSUUID UUID] UUIDString]];
        NSFileManager *fm = [NSFileManager defaultManager];
        NSError *error = nil;
        gAppRoot = [folder stringByAppendingPathComponent:@"app"];
        gGroupRoot = [folder stringByAppendingPathComponent:@"group"];
        Check([fm createDirectoryAtPath:gAppRoot withIntermediateDirectories:YES
             attributes:nil error:&error], @"synthetic app root creation");
        Check([fm createDirectoryAtPath:gGroupRoot withIntermediateDirectories:NO
             attributes:nil error:&error], @"synthetic group root creation");

        NSString *app = @"com.example.crane.native";
        NSString *container = @"00000000-0000-4000-8000-000000000001";
        NSDictionary *report = [CRBackupNativeManagerPreflight
            probeRegisteredApplication:app containerIdentifier:container
            error:&error];
        Check(report != nil && error == nil && gReadCalls == 3,
              @"real bridge failed to query all three manager selectors");
        Check([report[@"rootCount"] intValue] == 2 &&
              [report[@"associatedGroupCount"] intValue] == 1 &&
              [report[@"sourceDirectoryRootsReadable"] boolValue] &&
              ![report[@"sourceFilesEnumerated"] boolValue] &&
              ![report[@"sourceContentsRead"] boolValue] &&
              ![report[@"backupReady"] boolValue] &&
              ![report[@"restoreExecutable"] boolValue] &&
              report.count == 9,
              @"must return N5 read-only redacted counters only");

        NSInteger before = gReadCalls;
        NSDictionary *defaultReport = [CRBackupNativeManagerPreflight
            probeRegisteredApplication:app containerIdentifier:@"DEFAULT" error:&error];
        Check(defaultReport != nil && gReadCalls == before + 3,
              @"DEFAULT must resolve from CraneManager, never inferred");

        ExpectFailure(app, @"00000000-0000-4000-8000-000000000999", 4);
        ExpectFailure(@"com.example.not.registered", container, 4);
        gDuplicate = YES;
        ExpectFailure(app, container, 4);
        gDuplicate = NO;
        gSupported = NO;
        ExpectFailure(app, container, 4);
        gSupported = YES;
        gManager = nil;
        ExpectFailure(app, container, 3);

        NSLog(@"G-11 N6 read-only real CraneManager bridge mock: PASS");
    }
    return 0;
}
