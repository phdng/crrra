/*
 * G-11 N4 native disposable fixture source collector.
 * Reads ONLY the fixed fake app tree beneath a double-marked OS-temp root.
 * No production container discovery, no symlink/hardlink/special files,
 * no arbitrary source path, no Keychain and no filesystem Restore.
 */
#import "CRBackupNativeFixtureCollector.h"
#import "CRBackupNativeCore.h"
#import "CRBackupNativeFixtureWriter.h"
#import <dirent.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <grp.h>
#import <limits.h>
#import <pwd.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString * const CN4ErrorDomain = @"com.crane.backup.native.fixture.collect";
static NSString * const CN4App = @"com.example.crane.native";
static const char CN4Marker[] = "CRANE_DISPOSABLE_FIXTURE_V1\n";
static const NSUInteger CN4MaxEntries = 30;
static const NSUInteger CN4MaxBytes = 512 * 1024;
static const NSUInteger CN4MaxSingleFile = 256 * 1024;
static const NSUInteger CN4MaxDepth = 6;

static void CN4Fail(NSError **error, NSInteger code)
{
    if (error) *error = [NSError errorWithDomain:CN4ErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey:
            @"Disposable fixture source capture rejected"}];
}

static int CN4DirectoryFlags(void)
{
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
    return flags;
}

static BOOL CN4SafeComponent(NSString *name)
{
    if (![name isKindOfClass:NSString.class] ||
        name.length == 0 || name.length > 120 ||
        [name isEqualToString:@"."] || [name isEqualToString:@".."])
        return NO;
    static NSCharacterSet *bad = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
        bad = [allowed invertedSet];
    });
    if ([name rangeOfCharacterFromSet:bad].location != NSNotFound)
        return NO;
    NSString *lower = name.lowercaseString;
    return ![lower isEqualToString:@"keychain.plist"] &&
           ![lower isEqualToString:@"info.plist"] &&
           ![lower isEqualToString:@"metadata.plist"];
}

/* Original writable Foundation keys backed by actual st_* values. We do
 * NOT invent NSFileExtensionHidden; stat cannot establish that Finder flag.
 */
static NSDictionary<NSString *, id> *CN4Attributes(const struct stat *st)
{
    char userBuffer[16384], groupBuffer[16384];
    struct passwd userValue, *userResult = NULL;
    struct group groupValue, *groupResult = NULL;
    if (getpwuid_r(st->st_uid, &userValue, userBuffer,
                   sizeof(userBuffer), &userResult) != 0 || !userResult ||
        getgrgid_r(st->st_gid, &groupValue, groupBuffer,
                   sizeof(groupBuffer), &groupResult) != 0 || !groupResult)
        return nil;
    NSString *user = [NSString stringWithUTF8String:userResult->pw_name];
    NSString *group = [NSString stringWithUTF8String:groupResult->gr_name];
    if (!user.length || !group.length)
        return nil;
    NSTimeInterval created = (NSTimeInterval)st->st_birthtimespec.tv_sec +
                            (NSTimeInterval)st->st_birthtimespec.tv_nsec / 1e9;
    NSTimeInterval modified = (NSTimeInterval)st->st_mtimespec.tv_sec +
                             (NSTimeInterval)st->st_mtimespec.tv_nsec / 1e9;
    return @{
        NSFileCreationDate:[NSDate dateWithTimeIntervalSince1970:created],
        NSFileModificationDate:[NSDate dateWithTimeIntervalSince1970:modified],
        NSFileOwnerAccountID:@(st->st_uid),
        NSFileOwnerAccountName:user,
        NSFileGroupOwnerAccountID:@(st->st_gid),
        NSFileGroupOwnerAccountName:group,
        NSFilePosixPermissions:@(st->st_mode & 07777),
    };
}

static BOOL CN4Count(NSUInteger *entries)
{
    if (*entries >= CN4MaxEntries) return NO;
    ++(*entries);
    return YES;
}

static NSData *CN4ReadRegular(int parent, const char *name,
                               const struct stat *expected, dev_t device,
                               NSUInteger *totalBytes)
{
    if (!S_ISREG(expected->st_mode) || expected->st_nlink != 1 ||
        expected->st_dev != device || expected->st_size < 0 ||
        (uint64_t)expected->st_size > CN4MaxSingleFile ||
        (NSUInteger)expected->st_size > CN4MaxBytes - *totalBytes)
        return nil;
    int flags = O_RDONLY;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
    int fd = openat(parent, name, flags);
    if (fd < 0) return nil;
    NSData *data = nil;
    @try {
        struct stat first, last;
        if (fstat(fd, &first) != 0 || !S_ISREG(first.st_mode) ||
            first.st_nlink != 1 || first.st_dev != expected->st_dev ||
            first.st_ino != expected->st_ino ||
            first.st_size != expected->st_size ||
            first.st_mode != expected->st_mode ||
            first.st_uid != expected->st_uid ||
            first.st_gid != expected->st_gid ||
            first.st_ctimespec.tv_sec != expected->st_ctimespec.tv_sec ||
            first.st_ctimespec.tv_nsec != expected->st_ctimespec.tv_nsec ||
            first.st_mtimespec.tv_sec != expected->st_mtimespec.tv_sec ||
            first.st_mtimespec.tv_nsec != expected->st_mtimespec.tv_nsec)
            return nil;
        NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)first.st_size];
        NSUInteger position = 0;
        while (position < buffer.length) {
            ssize_t got = read(fd, (uint8_t *)buffer.mutableBytes + position,
                               buffer.length - position);
            if (got < 0 && errno == EINTR) continue;
            if (got <= 0) return nil;
            position += (NSUInteger)got;
        }
        if (fstat(fd, &last) != 0 ||
            last.st_dev != first.st_dev || last.st_ino != first.st_ino ||
            last.st_size != first.st_size ||
            last.st_mode != first.st_mode ||
            last.st_uid != first.st_uid || last.st_gid != first.st_gid ||
            last.st_mtimespec.tv_sec != first.st_mtimespec.tv_sec ||
            last.st_mtimespec.tv_nsec != first.st_mtimespec.tv_nsec ||
            last.st_ctimespec.tv_sec != first.st_ctimespec.tv_sec ||
            last.st_ctimespec.tv_nsec != first.st_ctimespec.tv_nsec)
            return nil;
        data = buffer;
    } @finally { close(fd); }
    if (data) *totalBytes += data.length;
    return data;
}

/* dirfd is already verified to be a non-symlink directory. Directory
 * iteration never resolves paths through Foundation and never follows links.
 */
static BOOL CN4Walk(int fd, NSString *prefix, NSUInteger depth, dev_t device,
                    NSMutableDictionary<NSString *, NSData *> *files,
                    NSMutableArray<NSString *> *directories,
                    NSMutableDictionary<NSString *, NSDictionary *> *attributes,
                    NSUInteger *entries, NSUInteger *bytes)
{
    if (depth > CN4MaxDepth) return NO;
    struct stat dirStat;
    if (fstat(fd, &dirStat) != 0 || !S_ISDIR(dirStat.st_mode) ||
        dirStat.st_dev != device || !CN4Count(entries))
        return NO;
    NSDictionary *dirAttributes = CN4Attributes(&dirStat);
    if (!dirAttributes) return NO;
    [directories addObject:[prefix stringByAppendingString:@"/"]];
    attributes[prefix] = dirAttributes;

    int dupFD = dup(fd);
    if (dupFD < 0) return NO;
    DIR *dir = fdopendir(dupFD);
    if (!dir) { close(dupFD); return NO; }
    BOOL success = YES;
    for (;;) {
        errno = 0;
        struct dirent *entry = readdir(dir);
        if (!entry) {
            if (errno != 0) success = NO;
            break;
        }
        if (strcmp(entry->d_name, ".") == 0 ||
            strcmp(entry->d_name, "..") == 0)
            continue;
        NSString *component = [NSString stringWithUTF8String:entry->d_name];
        if (!CN4SafeComponent(component)) { success = NO; break; }
        struct stat before;
        if (fstatat(fd, entry->d_name, &before, AT_SYMLINK_NOFOLLOW) != 0 ||
            before.st_dev != device) { success = NO; break; }
        NSString *name = [prefix stringByAppendingFormat:@"/%@", component];
        if (name.length > 512 || [attributes objectForKey:name] ||
            [files objectForKey:name]) { success = NO; break; }
        if (S_ISDIR(before.st_mode)) {
            int child = openat(fd, entry->d_name, CN4DirectoryFlags());
            if (child < 0) { success = NO; break; }
            struct stat opened;
            BOOL same = fstat(child, &opened) == 0 &&
                        S_ISDIR(opened.st_mode) && opened.st_dev == before.st_dev &&
                        opened.st_ino == before.st_ino;
            if (same)
                same = CN4Walk(child, name, depth+1, device, files, directories,
                               attributes, entries, bytes);
            close(child);
            if (!same) { success = NO; break; }
        } else if (S_ISREG(before.st_mode)) {
            if (!CN4Count(entries)) { success = NO; break; }
            NSData *content = CN4ReadRegular(fd, entry->d_name, &before,
                                            device, bytes);
            NSDictionary *fileAttributes = CN4Attributes(&before);
            if (!content || !fileAttributes) { success = NO; break; }
            files[name] = content;
            attributes[name] = fileAttributes;
        } else {
            success = NO; /* symlink, socket, pipe and device rejected */
            break;
        }
    }
    closedir(dir);
    if (success) {
        struct stat endStat;
        success = fstat(fd, &endStat) == 0 &&
                  dirStat.st_dev == endStat.st_dev &&
                  dirStat.st_ino == endStat.st_ino &&
                  dirStat.st_mtimespec.tv_sec == endStat.st_mtimespec.tv_sec &&
                  dirStat.st_mtimespec.tv_nsec == endStat.st_mtimespec.tv_nsec &&
                  dirStat.st_ctimespec.tv_sec == endStat.st_ctimespec.tv_sec &&
                  dirStat.st_ctimespec.tv_nsec == endStat.st_ctimespec.tv_nsec;
    }
    return success;
}

static BOOL CN4OpenMarkedRoot(NSString *root, int *appFD)
{
    if (![root isKindOfClass:NSString.class] || !root.length)
        return NO;
    struct stat before;
    if (lstat(root.fileSystemRepresentation, &before) != 0 ||
        !S_ISDIR(before.st_mode)) return NO;
    char actual[PATH_MAX], temp[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation, actual) ||
        !realpath(NSTemporaryDirectory().fileSystemRepresentation, temp))
        return NO;
    size_t length = strlen(temp);
    if (strncmp(actual, temp, length) != 0 || actual[length] != '/')
        return NO;

    int top = open(actual, CN4DirectoryFlags());
    if (top < 0) return NO;
    BOOL valid = NO;
    int marker = openat(top, ".crane-disposable-fixture", O_RDONLY
#ifdef O_NOFOLLOW
                        | O_NOFOLLOW
#endif
    );
    if (marker >= 0) {
        struct stat st;
        char bytes[sizeof(CN4Marker)] = {0};
        valid = fstat(marker, &st) == 0 && S_ISREG(st.st_mode) &&
                st.st_size == sizeof(CN4Marker)-1 &&
                read(marker, bytes, sizeof(CN4Marker)-1) ==
                    (ssize_t)(sizeof(CN4Marker)-1) &&
                memcmp(bytes, CN4Marker, sizeof(CN4Marker)-1) == 0;
        close(marker);
    }
    int source = valid ? openat(top, "source", CN4DirectoryFlags()) : -1;
    int app = source >= 0 ? openat(source, CN4App.UTF8String,
                                  CN4DirectoryFlags()) : -1;
    if (app >= 0) {
        struct stat rootStat, sourceStat, appStat;
        valid = fstat(top, &rootStat) == 0 &&
                fstat(source, &sourceStat) == 0 &&
                fstat(app, &appStat) == 0 &&
                rootStat.st_dev == sourceStat.st_dev &&
                sourceStat.st_dev == appStat.st_dev &&
                S_ISDIR(sourceStat.st_mode) && S_ISDIR(appStat.st_mode);
    } else valid = NO;
    if (source >= 0) close(source);
    close(top);
    if (!valid && app >= 0) close(app);
    if (valid) *appFD = app;
    return valid;
}

@implementation CRBackupNativeFixtureCollector
+ (NSDictionary<NSString *, id> *)writeDisposableSourceBackupAtRoot:(NSString *)root
                                                              error:(NSError **)error
{
    int app = -1;
    if (!CN4OpenMarkedRoot(root, &app)) {
        CN4Fail(error, 1);
        return nil;
    }
    NSMutableDictionary<NSString *, NSData *> *files = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSDictionary *> *metadata = [NSMutableDictionary dictionary];
    NSUInteger entries = 0, bytes = 0;
    struct stat statInfo;
    BOOL valid = fstat(app, &statInfo) == 0 &&
                 CN4Walk(app, CN4App, 0, statInfo.st_dev, files, dirs,
                         metadata, &entries, &bytes);
    close(app);
    if (!valid) {
        CN4Fail(error, 2);
        return nil;
    }
    NSError *encodeError = nil;
    NSData *info = [CRBackupNativeCore
        binarySingleInfoForApplicationIdentifier:CN4App
        containerIdentifier:@"00000000-0000-4000-8000-000000000001"
        containerName:@"test-only"
        originalPaths:@{CN4App:@"/disposable/not-a-real-application"}
        deviceIdentifierForVendor:@"00000000-0000-4000-8000-000000000002"
        error:&encodeError];
    NSData *meta = [CRBackupNativeCore
        binaryMetadataForIndexedAttributes:metadata error:&encodeError];
    if (!info || !meta) {
        CN4Fail(error, 3);
        return nil;
    }
    NSDictionary *written = [CRBackupNativeFixtureWriter
        writeDisposableSingleAtRoot:root infoData:info metadataData:meta
        files:files directories:dirs error:&encodeError];
    if (!written) {
        CN4Fail(error, 4);
        return nil;
    }
    return @{
        @"status":@"disposable_source_metadata_backup_not_production",
        @"fileCount":@(files.count),
        @"directoryCount":@(dirs.count),
        @"sourceBytes":@(bytes),
        @"archiveBytes":written[@"archiveBytes"],
        @"metadataFromFilesystem":@YES,
        @"keychainContentsRead":@NO,
        @"productionBackupAvailable":@NO,
        @"restoreExecutable":@NO,
    };
}
@end
