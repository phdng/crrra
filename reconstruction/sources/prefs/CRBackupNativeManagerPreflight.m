/*
 * G-11 N6 read-only bridge to the ACTUAL CraneManager singleton.
 *
 * CraneManager selectors are defined in the recovered CRManager.h;
 * dynamic class lookup permits a Foundation-only macOS mock smoke test
 * without linking libcrane or touching the real device. On iOS the class
 * resolves to the already linked libcrane implementation.
 *
 * This method is deliberately NOT called by CranePrefs Root controllers.
 * It can only inspect container root directories via N5, never traverse
 * their children or authorize actual Backup/Restore.
 */
#import "CRBackupNativeManagerPreflight.h"
#import "CRBackupNativeSourcePreflight.h"
#import "CRBackupNativeTypedPreflight.h"
#import "CRManager.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const CR6Domain = @"com.crane.backup.native.manager.preflight";

static void CR6Fail(NSError **error, NSInteger code)
{
    if (error) {
        *error = [NSError errorWithDomain:CR6Domain code:code
             userInfo:@{NSLocalizedDescriptionKey:
                  @"Crane read-only manager source preflight unavailable"}];
    }
}

@implementation CRBackupNativeManagerPreflight
+ (NSDictionary<NSString *, id> *)probeRegisteredApplication:(NSString *)applicationID
                                          containerIdentifier:(NSString *)containerID
                                                        error:(NSError **)error
{
    /* Class resolution only: no manager calls until the explicit probe. */
    Class managerClass = NSClassFromString(@"CraneManager");
    SEL sharedSEL = @selector(sharedManager);
    if (!managerClass || ![managerClass respondsToSelector:sharedSEL]) {
        CR6Fail(error, 1);
        return nil;
    }

    id manager = nil;
    @try {
        typedef id (*CR6SharedManagerIMP)(id, SEL);
        manager = ((CR6SharedManagerIMP)objc_msgSend)(managerClass, sharedSEL);
    } @catch (NSException *exception) {
        (void)exception;
        CR6Fail(error, 2);
        return nil;
    }
    if (!manager ||
        ![manager respondsToSelector:@selector(isApplicationSupportedByCrane:)] ||
        ![manager respondsToSelector:@selector(containerIdentifiersOfApplicationWithIdentifier:)] ||
        ![manager respondsToSelector:
           @selector(pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:)]) {
        CR6Fail(error, 3);
        return nil;
    }

    /* The REAL manager supplies the registry identity and associated root
     * map. N5 independently validates root topology, ownership-by-mapping,
     * and directory accessibility, and always returns backupReady:NO.
     * No cached/exported paths, no filesystem writes, no Keychain.
     */
    NSError *inner = nil;
    NSDictionary *report = [CRBackupNativeSourcePreflight
        preflightApplicationIdentifier:applicationID
        containerIdentifier:containerID
        resolver:(id<CRBackupSourceResolver>)manager
        error:&inner];
    if (!report) {
        /* Do not propagate an underlying path or appID in error.userInfo. */
        CR6Fail(error, 4);
        return nil;
    }
    if (![report[@"backupReady"] isEqual:@NO] ||
        ![report[@"restoreExecutable"] isEqual:@NO] ||
        ![report[@"sourceFilesEnumerated"] isEqual:@NO] ||
        ![report[@"sourceContentsRead"] isEqual:@NO] ||
        ![report[@"keychainContentsRead"] isEqual:@NO]) {
        CR6Fail(error, 5);
        return nil;
    }
    return report;
}

+ (NSDictionary<NSString *, id> *)probeTypedRegisteredApplication:(NSString *)applicationID
                                               containerIdentifier:(NSString *)containerID
                                                             error:(NSError **)error
{
    Class managerClass = NSClassFromString(@"CraneManager");
    SEL sharedSEL = @selector(sharedManager);
    if (!managerClass || ![managerClass respondsToSelector:sharedSEL]) {
        CR6Fail(error, 1);
        return nil;
    }
    id manager = nil;
    @try {
        typedef id (*CR6SharedManagerIMP)(id, SEL);
        manager = ((CR6SharedManagerIMP)objc_msgSend)(managerClass, sharedSEL);
    } @catch (NSException *exception) {
        (void)exception;
        CR6Fail(error, 2);
        return nil;
    }
    if (!manager ||
        ![manager respondsToSelector:
            @selector(enumerate:pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:)]) {
        CR6Fail(error, 3);
        return nil;
    }
    NSDictionary *report = [CRBackupNativeTypedPreflight
        inspectApplicationIdentifier:applicationID
        containerIdentifier:containerID
        resolver:(id<CRBackupTypedSourceResolver>)manager
        error:NULL];
    if (!report ||
        ![report[@"backupReady"] isEqual:@NO] ||
        ![report[@"restoreExecutable"] isEqual:@NO] ||
        ![report[@"sourceFilesEnumerated"] isEqual:@NO] ||
        ![report[@"sourceContentsRead"] isEqual:@NO] ||
        ![report[@"keychainContentsRead"] isEqual:@NO]) {
        CR6Fail(error, 6);
        return nil;
    }
    return report;
}
@end
