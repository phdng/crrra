/*
 * G-11 N7 typed CraneManager source-root inventory, READ ONLY.
 * CraneManager's flattened associated-path dictionary drops original
 * enumeration type and overwrites duplicate IDs. Cross-check that map
 * against TWO bounded typed enumerate passes, fail closed on mismatch.
 * N9 re-checks registration, root accessibility and flattened map after
 * enumeration; this is detection, NOT a stable filesystem snapshot.
 *
 * Only the N5 root-directory fstat metadata is inspected; no child files,
 * names, payload, Keychain, filesystems writes or process control.
 */
#import "CRBackupNativeTypedPreflight.h"

static NSString * const CR7Domain = @"com.crane.backup.native.typed.preflight";
static const NSUInteger CR7MaxRoots = 32;

static void CR7Fail(NSError **error, NSInteger code)
{
    if (error)
        *error = [NSError errorWithDomain:CR7Domain code:code
            userInfo:@{NSLocalizedDescriptionKey:
                       @"Typed read-only source inventory unavailable"}];
}

/* Never return names/paths/identifiers in a report or error. */
static NSDictionary<NSString *, NSDictionary<NSString *, id> *> *
CR7TypedSnapshot(id<CRBackupTypedSourceResolver> resolver,
                 NSString *appID, NSString *containerID,
                 BOOL *valid)
{
    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *rows =
        [NSMutableDictionary dictionary];
    __block BOOL failed = NO;
    __block NSUInteger appRoots = 0;
    __block NSUInteger groupRoots = 0;
    __block NSUInteger plugInRoots = 0;
    @try {
        [resolver enumerate:^(NSInteger type, NSString *identifier,
                              NSString *path, BOOL *stop) {
            if (failed) { *stop = YES; return; }
            BOOL recognized = type == 0 || type == 1 || type == 2;
            BOOL validTypes = [identifier isKindOfClass:NSString.class] &&
                              [path isKindOfClass:NSString.class];
            BOOL appMatch = validTypes && (type == 0 ?
                [identifier isEqualToString:appID] :
                ![identifier isEqualToString:appID]);
            if (!recognized || !validTypes || !appMatch ||
                !identifier.length || !path.length ||
                [rows objectForKey:identifier] || rows.count >= CR7MaxRoots) {
                failed = YES;
                *stop = YES;
                return;
            }
            if (type == 0) appRoots++;
            else if (type == 1) groupRoots++;
            else plugInRoots++;
            rows[identifier] = @{@"type":@(type), @"path":[path copy]};
        } pathsAssociatedToContainerWithIdentifier:containerID
                        ofApplicationWithIdentifier:appID];
    } @catch (NSException *exception) {
        (void)exception;
        failed = YES;
    }
    *valid = !failed && appRoots == 1 &&
             rows.count == appRoots + groupRoots + plugInRoots;
    return *valid ? [rows copy] : nil;
}

@implementation CRBackupNativeTypedPreflight
+ (NSDictionary<NSString *, id> *)inspectApplicationIdentifier:(NSString *)applicationID
                                             containerIdentifier:(NSString *)containerID
                                                        resolver:(id<CRBackupTypedSourceResolver>)resolver
                                                           error:(NSError **)error
{
    if (!resolver ||
        ![resolver respondsToSelector:
            @selector(enumerate:pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:)]) {
        CR7Fail(error, 1);
        return nil;
    }
    /* N5 rejects unsupported/unregistered container IDs, missing roots,
     * unsafe directory topology, duplicate/nested root path mappings.
     */
    NSDictionary *n5 = [CRBackupNativeSourcePreflight
        preflightApplicationIdentifier:applicationID
        containerIdentifier:containerID resolver:resolver error:NULL];
    if (!n5 || ![n5[@"backupReady"] isEqual:@NO] ||
        ![n5[@"restoreExecutable"] isEqual:@NO] ||
        ![n5[@"sourceDirectoryRootsReadable"] isEqual:@YES]) {
        CR7Fail(error, 2);
        return nil;
    }

    /* N10: record root device/inode identity immediately after initial N5.
     * Keep this opaque token ONLY on the stack of this diagnostic call.
     * This still cannot pin or lock the directories for any later backup. */
    NSDictionary *initialMapping = nil;
    @try {
        initialMapping = [[resolver pathsAssociatedToContainerWithIdentifier:containerID
                                                 ofApplicationWithIdentifier:applicationID] copy];
    } @catch (NSException *exception) {
        (void)exception;
        CR7Fail(error, 10);
        return nil;
    }
    if (![initialMapping isKindOfClass:NSDictionary.class] ||
        initialMapping.count != [n5[@"rootCount"] unsignedIntegerValue]) {
        CR7Fail(error, 10);
        return nil;
    }
    CRBackupNativeRootIdentitySnapshot *rootIdentity =
        [CRBackupNativeSourcePreflight captureRootIdentityForMapping:initialMapping];
    if (!rootIdentity) {
        CR7Fail(error, 10);
        return nil;
    }

    BOOL firstValid = NO, secondValid = NO;
    NSDictionary *first = CR7TypedSnapshot(resolver, applicationID,
                                           containerID, &firstValid);
    NSDictionary *second = firstValid ?
        CR7TypedSnapshot(resolver, applicationID,
                         containerID, &secondValid) : nil;
    if (!firstValid || !secondValid || ![first isEqualToDictionary:second]) {
        CR7Fail(error, 3);
        return nil; /* mapping changed, duplicate or invalid type */
    }

    /* Take the dictionary AGAIN. A typed list is NOT sufficient when the
     * manager's flattened mapping silently drops duplicate identifiers.
     */
    NSDictionary *mapping = nil;
    @try {
        /* Freeze the returned map: a mutable manager cache must not change
         * the baseline while we compare it to the typed snapshots. */
        mapping = [[resolver pathsAssociatedToContainerWithIdentifier:containerID
                                           ofApplicationWithIdentifier:applicationID] copy];
    } @catch (NSException *exception) {
        (void)exception;
        CR7Fail(error, 4);
        return nil;
    }
    if (![mapping isKindOfClass:NSDictionary.class] ||
        mapping.count != first.count ||
        [n5[@"rootCount"] unsignedIntegerValue] != first.count) {
        CR7Fail(error, 5);
        return nil;
    }

    NSUInteger appRoots = 0, groups = 0, plugins = 0;
    for (NSString *identifier in first) {
        NSDictionary *entry = first[identifier];
        NSString *path = mapping[identifier];
        if (![path isKindOfClass:NSString.class] ||
            ![path isEqualToString:entry[@"path"]]) {
            CR7Fail(error, 6);
            return nil;
        }
        NSInteger type = [entry[@"type"] integerValue];
        if (type == 0) appRoots++;
        else if (type == 1) groups++;
        else plugins++;
    }
    if (appRoots != 1 ||
        groups + plugins != [n5[@"associatedGroupCount"] unsignedIntegerValue]) {
        CR7Fail(error, 7);
        return nil;
    }

    /* N9: late registration or root state can change after the first N5
     * validation. Re-evaluate the same manager-authorized roots after both
     * typed enumerations. No file children are opened by N5.
     *
     * Even the final check is NOT atomic with a later backup. Never promote
     * this result into an authorization to read data or perform Restore.
     */
    NSDictionary *lastRoots = [CRBackupNativeSourcePreflight
        preflightApplicationIdentifier:applicationID
        containerIdentifier:containerID resolver:resolver error:NULL];
    if (!lastRoots ||
        ![lastRoots[@"backupReady"] isEqual:@NO] ||
        ![lastRoots[@"restoreExecutable"] isEqual:@NO] ||
        ![lastRoots[@"sourceDirectoryRootsReadable"] isEqual:@YES] ||
        [lastRoots[@"rootCount"] unsignedIntegerValue] != first.count ||
        [lastRoots[@"associatedGroupCount"] unsignedIntegerValue] != groups + plugins) {
        CR7Fail(error, 8);
        return nil;
    }

    /* N5's report deliberately omits private paths. Take a final COPY
     * from the resolver to prove that its late root check examined the
     * same mapping already compared to the two typed snapshots. */
    NSDictionary *lastMapping = nil;
    @try {
        lastMapping = [[resolver pathsAssociatedToContainerWithIdentifier:containerID
                                              ofApplicationWithIdentifier:applicationID] copy];
    } @catch (NSException *exception) {
        (void)exception;
        CR7Fail(error, 9);
        return nil;
    }
    if (![lastMapping isKindOfClass:NSDictionary.class] ||
        ![mapping isEqualToDictionary:lastMapping]) {
        CR7Fail(error, 9);
        return nil;
    }

    /* A directory may have been replaced in-place between N5 scans.
     * Canonical mapping strings remain identical, but st_dev/st_ino do not.
     * Refuse a misleading diagnostic result if root identity has drifted. */
    if (![CRBackupNativeSourcePreflight
            isRootIdentityUnchangedFromSnapshot:rootIdentity mapping:lastMapping]) {
        CR7Fail(error, 11);
        return nil;
    }

    return @{
        @"status":@"typed_roots_consistent_not_backup_ready",
        @"rootCount":@(first.count),
        @"applicationRootCount":@(appRoots),
        @"appGroupRootCount":@(groups),
        @"plugInKitRootCount":@(plugins),
        @"rootDirectoryMetadataChecked":@(first.count),
        @"sourceFilesEnumerated":@NO,
        @"sourceContentsRead":@NO,
        @"keychainContentsRead":@NO,
        @"backupReady":@NO,
        @"restoreExecutable":@NO,
    };
}
@end
