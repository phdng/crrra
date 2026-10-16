/*
 * G-11 N8 — one-shot read-only diagnostic for a DEDICATED disposable app.
 *
 * The only manager work is N6 -> N7 -> N5 root metadata inspection:
 * no child enumeration, no user data reads, no Keychain and no mutations.
 * Even successful diagnostics always indicate backupReady/restoreExecutable NO.
 */
#import "CRBackupDisposableDiagnostic.h"
#import "CRBackupNativeManagerPreflight.h"

static NSString * const CR8FixtureApplicationID = @"com.example.crane.native";
static NSString * const CR8Domain = @"com.crane.backup.disposable.diagnostic";

static void CR8Fail(NSError **error, NSInteger code)
{
    if (error) {
        *error = [NSError errorWithDomain:CR8Domain code:code
                userInfo:@{NSLocalizedDescriptionKey:
                           @"Read-only disposable source diagnostic unavailable"}];
    }
}

@implementation CRBackupDisposableDiagnostic

+ (BOOL)isEligibleApplicationIdentifier:(NSString *)applicationID
                    containerIdentifier:(NSString *)containerID
{
    /* Exact dedicated test bundle; a DEFAULT or malformed container is
     * never inspected by this UI diagnostic even if N7 supports DEFAULT.
     * The N5 manager resolver additionally verifies actual registration. */
    return [applicationID isKindOfClass:NSString.class] &&
           [applicationID isEqualToString:CR8FixtureApplicationID] &&
           [containerID isKindOfClass:NSString.class] &&
           [[NSUUID alloc] initWithUUIDString:containerID] != nil;
}

+ (NSDictionary<NSString *, id> *)probeApplicationIdentifier:(NSString *)applicationID
                                          containerIdentifier:(NSString *)containerID
                                            userConfirmedOnce:(BOOL)confirmed
                                                        error:(NSError **)error
{
    /* Never contact CraneManager without BOTH gates: explicit confirmation
     * and an exact, dedicated disposable app/container identity. */
    if (!confirmed ||
        ![self isEligibleApplicationIdentifier:applicationID
                           containerIdentifier:containerID]) {
        CR8Fail(error, 1);
        return nil;
    }

    NSDictionary *report = [CRBackupNativeManagerPreflight
        probeTypedRegisteredApplication:applicationID
        containerIdentifier:containerID error:NULL];
    if (!report ||
        ![report[@"backupReady"] isEqual:@NO] ||
        ![report[@"restoreExecutable"] isEqual:@NO] ||
        ![report[@"sourceFilesEnumerated"] isEqual:@NO] ||
        ![report[@"sourceContentsRead"] isEqual:@NO] ||
        ![report[@"keychainContentsRead"] isEqual:@NO] ||
        ![report[@"applicationRootCount"] isEqual:@1] ||
        ![report[@"rootDirectoryMetadataChecked"]
              isEqual:report[@"rootCount"]]) {
        CR8Fail(error, 2);
        return nil;
    }

    /* Redacted counters only. Nothing identifying the app or root leaves
     * this method, including nested error.userInfo from lower layers. */
    return @{
        @"status":@"disposable_roots_checked_not_backup_ready",
        @"rootCount":report[@"rootCount"],
        @"applicationRootCount":report[@"applicationRootCount"],
        @"appGroupRootCount":report[@"appGroupRootCount"],
        @"plugInKitRootCount":report[@"plugInKitRootCount"],
        @"sourceFilesEnumerated":@NO,
        @"sourceContentsRead":@NO,
        @"keychainContentsRead":@NO,
        @"backupReady":@NO,
        @"restoreExecutable":@NO,
    };
}
@end
