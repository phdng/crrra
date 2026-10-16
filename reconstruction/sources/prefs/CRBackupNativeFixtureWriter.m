/*
 * G-11 N2 native disposable test ZIP writer. This deliberately creates
 * ZIP64 local/central extras and signed ZIP64 descriptors as observed in
 * an original Crane single .cranect archive. This is NOT an app backup.
 *
 * Inputs are NSData-only, output is NEW under double-gated OS-temp fixture.
 * It NEVER opens application data paths, reads Keychain or permits Restore.
 */
#import "CRBackupNativeFixtureWriter.h"
#import <errno.h>
#import <fcntl.h>
#import <limits.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

static NSString * const CRWriteErrorDomain = @"com.crane.backup.native.fixture";
static const NSUInteger CRMaxFixtureEntries = 64;
static const NSUInteger CRMaxFixtureBytes = 1024 * 1024;
static const char CRMarkerBytes[] = "CRANE_DISPOSABLE_FIXTURE_V1\n";
static const char CROutputName[] = "native-single.cranect";

static void CRWriterFail(NSError **error, NSInteger code)
{
    if (error)
        *error = [NSError errorWithDomain:CRWriteErrorDomain code:code
            userInfo:@{NSLocalizedDescriptionKey:
                @"Disposable synthetic ZIP writer refused unsafe input"}];
}

static void W16(NSMutableData *data, uint16_t x)
{
    const uint8_t out[] = {(uint8_t)x, (uint8_t)(x >> 8)};
    [data appendBytes:out length:2];
}
static void W32(NSMutableData *data, uint32_t x)
{
    W16(data, (uint16_t)x);
    W16(data, (uint16_t)(x >> 16));
}
static void W64(NSMutableData *data, uint64_t x)
{
    W32(data, (uint32_t)x);
    W32(data, (uint32_t)(x >> 32));
}

static BOOL WSafeName(NSString *name, BOOL directory)
{
    if (![name isKindOfClass:NSString.class] ||
        name.length < 1 || name.length > 512 ||
        [name hasPrefix:@"/"] || [name hasPrefix:@"\\"] ||
        [name rangeOfString:@"\\"].location != NSNotFound ||
        [name rangeOfString:@":"].location != NSNotFound ||
        [name rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return NO;
    if ([name hasSuffix:@"/"] != directory) return NO;
    NSString *trimmed = directory ?
        [name substringToIndex:name.length - 1] : name;
    if (!trimmed.length) return NO;
    for (NSString *part in [trimmed componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqualToString:@"."] ||
            [part isEqualToString:@".."])
            return NO;
    }
    NSString *leaf = [[trimmed componentsSeparatedByString:@"/"] lastObject];
    if ([leaf.lowercaseString isEqualToString:@"keychain.plist"] ||
        [leaf.lowercaseString isEqualToString:@"info.plist"] ||
        [leaf.lowercaseString isEqualToString:@"metadata.plist"])
        return NO; /* Only code, not the caller, inserts reserved root plists */
    return YES;
}

static BOOL WBinaryPlist(NSData *data, Class type)
{
    if (![data isKindOfClass:NSData.class] || data.length < 8 ||
        data.length > 256 * 1024 ||
        memcmp(data.bytes, "bplist00", 8) != 0)
        return NO;
    NSPropertyListFormat format = NSPropertyListOpenStepFormat;
    id object = [NSPropertyListSerialization
        propertyListWithData:data options:NSPropertyListImmutable
                      format:&format error:NULL];
    return format == NSPropertyListBinaryFormat_v1_0 &&
           [object isKindOfClass:type];
}

static NSData *WDeflate(NSData *raw)
{
    if (raw.length > CRMaxFixtureBytes)
        return nil;
    uLong bound = compressBound((uLong)raw.length);
    if (bound > CRMaxFixtureBytes + 4096)
        return nil;
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)bound + 16];
    z_stream z = {0};
    z.next_in = (Bytef *)raw.bytes;
    z.avail_in = (uInt)raw.length;
    z.next_out = buffer.mutableBytes;
    z.avail_out = (uInt)buffer.length;
    if (deflateInit2(&z, Z_DEFAULT_COMPRESSION, Z_DEFLATED,
                     -MAX_WBITS, MAX_MEM_LEVEL, Z_DEFAULT_STRATEGY) != Z_OK)
        return nil;
    int result = deflate(&z, Z_FINISH);
    BOOL ok = result == Z_STREAM_END &&
              z.total_in == raw.length && z.total_out <= buffer.length;
    deflateEnd(&z);
    if (!ok) return nil;
    buffer.length = (NSUInteger)z.total_out;
    return buffer;
}

static BOOL WEntry(NSMutableData *output, NSMutableData *central,
                   NSString *name, NSData *data, BOOL directory)
{
    NSData *nameBytes = [name dataUsingEncoding:NSUTF8StringEncoding];
    if (!nameBytes || !nameBytes.length || nameBytes.length > 1024 ||
        data.length > CRMaxFixtureBytes || output.length > UINT32_MAX)
        return NO;
    NSData *compressed = directory ? [NSData data] : WDeflate(data);
    if (!compressed) return NO;

    uint16_t method = directory ? 0 : 8;
    uint32_t localOffset = (uint32_t)output.length;
    uint32_t crc = (uint32_t)crc32(0, Z_NULL, 0);
    crc = (uint32_t)crc32(crc, data.bytes, (uInt)data.length);
    uint64_t comp = compressed.length, uncomp = data.length;

    /* Local header: ZIP64 placeholders are zero because flag bit3 enables
     * a signed 24-byte descriptor after data. This matches original shape.
     */
    W32(output, 0x04034b50);
    W16(output, 45); W16(output, 0x0808); W16(output, method);
    W16(output, 0); W16(output, 0); W32(output, 0);
    W32(output, UINT32_MAX); W32(output, UINT32_MAX);
    W16(output, (uint16_t)nameBytes.length); W16(output, 20);
    [output appendData:nameBytes];
    W16(output, 1); W16(output, 16); W64(output, 0); W64(output, 0);
    [output appendData:compressed];
    W32(output, 0x08074b50);
    W32(output, crc); W64(output, comp); W64(output, uncomp);

    /* Central directory: actual sizes in ZIP64 extra; macOS creator=19,
     * version needed=45, flags=0x0808, no synthetic host UID/GID.
     */
    W32(central, 0x02014b50);
    W16(central, (uint16_t)((19 << 8) | 45));
    W16(central, 45); W16(central, 0x0808); W16(central, method);
    W16(central, 0); W16(central, 0); W32(central, crc);
    W32(central, UINT32_MAX); W32(central, UINT32_MAX);
    W16(central, (uint16_t)nameBytes.length); W16(central, 20);
    W16(central, 0); W16(central, 0); W16(central, 0);
    W32(central, ((uint32_t)(directory ? 0040700 : 0100600)) << 16);
    W32(central, localOffset);
    [central appendData:nameBytes];
    W16(central, 1); W16(central, 16);
    W64(central, uncomp); W64(central, comp);
    return YES;
}

static BOOL WBuild(NSData *info, NSData *metadata,
                   NSDictionary<NSString *, NSData *> *files,
                   NSArray<NSString *> *directories,
                   NSMutableData **finished, NSUInteger *count)
{
    if (!WBinaryPlist(info, NSDictionary.class) ||
        !WBinaryPlist(metadata, NSDictionary.class) ||
        ![files isKindOfClass:NSDictionary.class] ||
        ![directories isKindOfClass:NSArray.class] ||
        files.count + directories.count + 2 > CRMaxFixtureEntries)
        return NO;

    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSString *folder in directories) {
        if (!WSafeName(folder, YES)) return NO;
        NSString *logical = [folder substringToIndex:folder.length-1];
        if ([seen containsObject:logical]) return NO;
        [seen addObject:logical];
    }
    NSUInteger contentBytes = info.length + metadata.length;
    for (id name in files) {
        if (!WSafeName(name, NO) ||
            ![files[name] isKindOfClass:NSData.class] ||
            [seen containsObject:name])
            return NO;
        NSUInteger size = [files[name] length];
        if (size > CRMaxFixtureBytes ||
            contentBytes > CRMaxFixtureBytes-size)
            return NO;
        contentBytes += size;
        [seen addObject:name];
    }
    for (NSString *name in seen) {
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@"/"];
        NSMutableString *prefix = [NSMutableString string];
        for (NSUInteger i=0; i+1<parts.count; ++i) {
            if (i) [prefix appendString:@"/"];
            [prefix appendString:parts[i]];
            if (files[prefix]) return NO; /* file cannot be a folder */
        }
    }

    NSMutableData *result = [NSMutableData data];
    NSMutableData *central = [NSMutableData data];
    if (!WEntry(result, central, @"Info.plist", info, NO))
        return NO;
    for (NSString *name in [directories sortedArrayUsingSelector:@selector(compare:)]) {
        if (!WEntry(result, central, name, [NSData data], YES))
            return NO;
    }
    for (NSString *name in [[files allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (!WEntry(result, central, name, files[name], NO))
            return NO;
    }
    if (!WEntry(result, central, @"Metadata.plist", metadata, NO))
        return NO;
    if (result.length > UINT32_MAX || central.length > UINT32_MAX ||
        result.length + central.length + 22 > 2 * CRMaxFixtureBytes)
        return NO;

    uint32_t cdOffset = (uint32_t)result.length;
    uint32_t cdSize = (uint32_t)central.length;
    [result appendData:central];
    uint16_t entries = (uint16_t)(files.count + directories.count + 2);
    W32(result, 0x06054b50);
    W16(result, 0); W16(result, 0);
    W16(result, entries); W16(result, entries);
    W32(result, cdSize); W32(result, cdOffset); W16(result, 0);
    *finished = result;
    *count = entries;
    return YES;
}

static BOOL WFixtureDirectory(NSString *root, int *outputFD)
{
    if (![root isKindOfClass:NSString.class] || !root.length)
        return NO;
    struct stat inputStat;
    if (lstat(root.fileSystemRepresentation, &inputStat) != 0 ||
        !S_ISDIR(inputStat.st_mode))
        return NO; /* also rejects root symlinks */
    char realRoot[PATH_MAX], tempRoot[PATH_MAX];
    if (!realpath(root.fileSystemRepresentation, realRoot) ||
        !realpath(NSTemporaryDirectory().fileSystemRepresentation, tempRoot))
        return NO;
    size_t prefix = strlen(tempRoot);
    if (strncmp(realRoot, tempRoot, prefix) != 0 ||
        realRoot[prefix] != '/')
        return NO; /* disposable root MUST be a child of OS temp */

    int directoryFlags = O_RDONLY;
#ifdef O_DIRECTORY
    directoryFlags |= O_DIRECTORY;
#endif
#ifdef O_NOFOLLOW
    directoryFlags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    directoryFlags |= O_CLOEXEC;
#endif
    int rootFD = open(realRoot, directoryFlags);
    if (rootFD < 0) return NO;
    int markerFlags = O_RDONLY;
#ifdef O_NOFOLLOW
    markerFlags |= O_NOFOLLOW;
#endif
    int marker = openat(rootFD, ".crane-disposable-fixture", markerFlags);
    BOOL ready = NO;
    if (marker >= 0) {
        char bytes[sizeof(CRMarkerBytes)] = {0};
        struct stat metadata;
        if (fstat(marker, &metadata) == 0 && S_ISREG(metadata.st_mode) &&
            metadata.st_size == sizeof(CRMarkerBytes)-1 &&
            read(marker, bytes, sizeof(CRMarkerBytes)-1) ==
                (ssize_t)(sizeof(CRMarkerBytes)-1) &&
            memcmp(bytes, CRMarkerBytes, sizeof(CRMarkerBytes)-1) == 0)
            ready = YES;
        close(marker);
    }
    if (ready)
        *outputFD = openat(rootFD, "output", directoryFlags);
    close(rootFD);
    return ready && *outputFD >= 0;
}

@implementation CRBackupNativeFixtureWriter
+ (NSDictionary<NSString *, id> *)writeDisposableSingleAtRoot:(NSString *)root
                                                       infoData:(NSData *)info
                                                   metadataData:(NSData *)metadata
                                                          files:(NSDictionary<NSString *, NSData *> *)files
                                                    directories:(NSArray<NSString *> *)directories
                                                          error:(NSError **)error
{
    NSMutableData *archive = nil;
    NSUInteger entries = 0;
    if (!WBuild(info, metadata, files, directories, &archive, &entries)) {
        CRWriterFail(error, 1);
        return nil;
    }
    int outputFD = -1;
    if (!WFixtureDirectory(root, &outputFD)) {
        CRWriterFail(error, 2);
        return nil;
    }
    int flags = O_WRONLY | O_CREAT | O_EXCL;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
    int fd = openat(outputFD, CROutputName, flags, 0600);
    if (fd < 0) {
        close(outputFD);
        CRWriterFail(error, 3);
        return nil;
    }
    const uint8_t *bytes = archive.bytes;
    size_t left = archive.length;
    BOOL written = YES;
    while (left) {
        ssize_t count = write(fd, bytes, left);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) { written = NO; break; }
        bytes += count;
        left -= (size_t)count;
    }
    if (written && fsync(fd) != 0)
        written = NO;
    if (close(fd) != 0)
        written = NO;
    if (!written)
        unlinkat(outputFD, CROutputName, 0); /* only the new O_EXCL file */
    close(outputFD);
    if (!written) {
        CRWriterFail(error, 4);
        return nil;
    }
    return @{
        @"status": @"disposable_single_zip_written_not_original_backup",
        @"entryCount": @(entries),
        @"archiveBytes": @(archive.length),
        @"deviceDataTouched": @NO,
        @"keychainContentsRead": @NO,
        @"originalCompatibilityProven": @NO,
        @"restoreExecutable": @NO,
    };
}
@end
