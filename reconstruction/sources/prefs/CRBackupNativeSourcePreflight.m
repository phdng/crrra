/*
 * G-11 N5 — authoritative-container-map preflight, read-only.
 * Path mappings originate from a resolver implementing CraneManager's
 * documented selectors. Never infer a path from an application identifier.
 *
 * Validates roots only: NO readdir/openat of children, file data, Keychain,
 * ZIP writing, app switching, daemon or helper calls.
 */
#import "CRBackupNativeSourcePreflight.h"
#import <TargetConditionals.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const CR5Domain = @"com.crane.backup.native.source.preflight";
static const NSUInteger CR5MaxRoots = 32;

static void CR5Fail(NSError **error, NSInteger code)
{
    if (error)
        *error = [NSError errorWithDomain:CR5Domain code:code
            userInfo:@{NSLocalizedDescriptionKey:
                @"Crane source roots unavailable for read-only preflight"}];
}

static BOOL CR5SafeID(id value)
{
    if (![value isKindOfClass:NSString.class]) return NO;
    NSString *name = value;
    if (!name.length || name.length > 200 ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."] ||
        [name containsString:@".."])
        return NO;
    static NSCharacterSet *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bad = [[NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"]
            invertedSet];
    });
    return [name rangeOfCharacterFromSet:bad].location == NSNotFound;
}

static BOOL CR5Ancestor(NSString *a, NSString *b)
{
    return b.length > a.length && [b hasPrefix:a] &&
           [b characterAtIndex:a.length] == '/';
}

static BOOL CR5CanonicalAllowed(const char *canonical)
{
#if TARGET_OS_IPHONE
    const char prefix[] = "/private/var/mobile/Containers/";
    return strncmp(canonical, prefix, sizeof(prefix)-1) == 0 &&
           canonical[sizeof(prefix)-1] != '\0';
#else
    char temp[PATH_MAX];
    if (!realpath(NSTemporaryDirectory().fileSystemRepresentation, temp))
        return NO;
    size_t count = strlen(temp);
    return strncmp(canonical, temp, count) == 0 &&
           canonical[count] == '/' && canonical[count+1] != '\0';
#endif
}

/* On iOS/macOS /var is normally a legacy alias for /private/var.
 * All other intermediate symlinks are rejected by this comparison.
 * No child of the source root is ever opened by this preflight.
 */
static NSString *CR5RootPath(id value, struct stat *rootIdentity)
{
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *original = value;
    if (original.length < 3 || original.length > 4096 ||
        ![original hasPrefix:@"/"] ||
        [original rangeOfString:@"//"].location != NSNotFound ||
        [original rangeOfString:@"\\"].location != NSNotFound ||
        [original rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound ||
        ![original.stringByStandardizingPath isEqualToString:original])
        return nil;
    char resolved[PATH_MAX];
    if (!realpath(original.fileSystemRepresentation, resolved) ||
        !CR5CanonicalAllowed(resolved))
        return nil;
    NSString *canonical = [NSString stringWithUTF8String:resolved];
    if (!canonical) return nil;
    NSString *allowedAlias = [canonical hasPrefix:@"/private/var/"] ?
        [canonical substringFromIndex:8] : canonical;
    if (![original isEqualToString:canonical] &&
        ![original isEqualToString:allowedAlias])
        return nil;

    struct stat first, opened, after;
    if (lstat(original.fileSystemRepresentation, &first) != 0 ||
        !S_ISDIR(first.st_mode))
        return nil;
    int flags = O_RDONLY;
#ifdef O_DIRECTORY
    flags |= O_DIRECTORY;
#endif
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
    int fd = open(original.fileSystemRepresentation, flags);
    if (fd < 0)
        return nil;
    BOOL acceptable = (fstat(fd, &opened) == 0 &&
                       lstat(original.fileSystemRepresentation, &after) == 0 &&
                       S_ISDIR(opened.st_mode) && S_ISDIR(after.st_mode) &&
                       first.st_dev == opened.st_dev &&
                       first.st_ino == opened.st_ino &&
                       after.st_dev == opened.st_dev &&
                       after.st_ino == opened.st_ino);
    if (acceptable && rootIdentity)
        *rootIdentity = opened;
    close(fd);
    return acceptable ? canonical : nil;
}

/* No public properties: a token is transient, opaque and never serialized.
 * The snapshot is strictly diagnostic metadata, NOT a filesystem lock. */
@interface CRBackupNativeRootIdentitySnapshot ()
@property (nonatomic, copy) NSDictionary<NSString *, NSDictionary<NSString *, id> *> *identityByID;
@end
@implementation CRBackupNativeRootIdentitySnapshot
@end

@implementation CRBackupNativeSourcePreflight

+ (CRBackupNativeRootIdentitySnapshot *)captureRootIdentityForMapping:
    (NSDictionary<NSString *, NSString *> *)mapping
{
    if (![mapping isKindOfClass:NSDictionary.class] ||
        !mapping.count || mapping.count > CR5MaxRoots)
        return nil;

    NSMutableDictionary<NSString *, NSDictionary<NSString *, id> *> *identities =
        [NSMutableDictionary dictionaryWithCapacity:mapping.count];
    NSMutableSet<NSString *> *seenPaths = [NSMutableSet set];
    for (id identifier in mapping) {
        if (!CR5SafeID(identifier))
            return nil;
        struct stat identity;
        NSString *canonical = CR5RootPath(mapping[identifier], &identity);
        if (!canonical || [seenPaths containsObject:canonical])
            return nil;
        for (NSString *previous in seenPaths) {
            if (CR5Ancestor(previous, canonical) ||
                CR5Ancestor(canonical, previous))
                return nil;
        }
        [seenPaths addObject:canonical];
        identities[identifier] = @{
            @"canonical":canonical,
            @"device":@((unsigned long long)identity.st_dev),
            @"inode":@((unsigned long long)identity.st_ino),
        };
    }
    CRBackupNativeRootIdentitySnapshot *token =
        [CRBackupNativeRootIdentitySnapshot new];
    token.identityByID = [identities copy];
    return token;
}

+ (BOOL)isRootIdentityUnchangedFromSnapshot:(CRBackupNativeRootIdentitySnapshot *)snapshot
                                   mapping:(NSDictionary<NSString *, NSString *> *)mapping
{
    if (![snapshot isKindOfClass:CRBackupNativeRootIdentitySnapshot.class] ||
        !snapshot.identityByID.count)
        return NO;
    CRBackupNativeRootIdentitySnapshot *current =
        [self captureRootIdentityForMapping:mapping];
    return current && [snapshot.identityByID isEqualToDictionary:current.identityByID];
}

+ (NSDictionary<NSString *, id> *)preflightApplicationIdentifier:(NSString *)applicationID
                                              containerIdentifier:(NSString *)containerID
                                                         resolver:(id<CRBackupSourceResolver>)resolver
                                                            error:(NSError **)error
{
    if (!CR5SafeID(applicationID) || !CR5SafeID(containerID) ||
        !resolver ||
        ![resolver respondsToSelector:
            @selector(pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:)] ||
        ![resolver respondsToSelector:
            @selector(containerIdentifiersOfApplicationWithIdentifier:)] ||
        ![resolver respondsToSelector:
            @selector(isApplicationSupportedByCrane:)]) {
        CR5Fail(error, 1);
        return nil;
    }

    NSArray *registered = nil;
    NSDictionary *mapping = nil;
    @try {
        if (![resolver isApplicationSupportedByCrane:applicationID]) {
            CR5Fail(error, 2);
            return nil;
        }
        registered = [resolver containerIdentifiersOfApplicationWithIdentifier:applicationID];
        if (![registered isKindOfClass:NSArray.class] ||
            ( ![containerID isEqualToString:@"DEFAULT"] &&
              ![registered containsObject:containerID])) {
            CR5Fail(error, 3);
            return nil;
        }
        mapping = [resolver pathsAssociatedToContainerWithIdentifier:containerID
                                          ofApplicationWithIdentifier:applicationID];
    } @catch (NSException *exception) {
        (void)exception;
        CR5Fail(error, 4);
        return nil;
    }
    if (![mapping isKindOfClass:NSDictionary.class] ||
        mapping.count == 0 || mapping.count > CR5MaxRoots ||
        ![mapping[applicationID] isKindOfClass:NSString.class]) {
        CR5Fail(error, 5);
        return nil;
    }

    NSMutableSet<NSString *> *roots = [NSMutableSet set];
    NSUInteger associatedGroups = 0;
    for (id identifier in mapping) {
        if (!CR5SafeID(identifier)) {
            CR5Fail(error, 6);
            return nil;
        }
        NSString *canonical = CR5RootPath(mapping[identifier], NULL);
        if (!canonical || [roots containsObject:canonical]) {
            CR5Fail(error, 7);
            return nil;
        }
        for (NSString *existing in roots) {
            if (CR5Ancestor(existing, canonical) ||
                CR5Ancestor(canonical, existing)) {
                CR5Fail(error, 8);
                return nil;
            }
        }
        [roots addObject:canonical];
        if (![identifier isEqualToString:applicationID])
            associatedGroups++;
    }
    /* This only establishes that a manager-authorized mapping exists and
     * its root directories are accessible. It does not imply snapshot
     * consistency, byte-level access, or authority to create a backup.
     */
    return @{
        @"status":@"registered_source_roots_accessible_not_backup_ready",
        @"rootCount":@(roots.count),
        @"associatedGroupCount":@(associatedGroups),
        @"sourceDirectoryRootsReadable":@YES,
        @"sourceFilesEnumerated":@NO,
        @"sourceContentsRead":@NO,
        @"keychainContentsRead":@NO,
        @"backupReady":@NO,
        @"restoreExecutable":@NO,
    };
}
@end
