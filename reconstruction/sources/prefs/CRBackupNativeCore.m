/*
 * G-11 Native N0 - deliberately limited ZIP first-entry Info.plist reader.
 * No calls to CraneManager, app data paths, Keychain, or any mutating API.
 */
#import "CRBackupNativeCore.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

static NSString * const CRErrorDomain = @"com.crane.backup.native.readonly";
static const NSUInteger CRInfoLimit = 256 * 1024;
static const NSUInteger CRCompressedInfoLimit = 1024 * 1024;
static const uint64_t CRArchiveLimit = 512ULL * 1024 * 1024;

static void CRFail(NSError **error, NSInteger code)
{
    if (error)
        *error = [NSError errorWithDomain:CRErrorDomain code:code
                                userInfo:@{NSLocalizedDescriptionKey:
                                    @"Crane backup preview unavailable or unsupported"}];
}

static uint16_t CR16(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static uint32_t CR32(const uint8_t *p)
{
    return (uint32_t)CR16(p) | ((uint32_t)CR16(p + 2) << 16);
}

static uint64_t CR64(const uint8_t *p)
{
    return (uint64_t)CR32(p) | ((uint64_t)CR32(p + 4) << 32);
}

static BOOL CRRead(int fd, uint64_t offset, void *buffer, size_t bytes,
                   uint64_t length)
{
    if (offset > length || bytes > length - offset)
        return NO;
    uint8_t *out = buffer;
    size_t remaining = bytes;
    while (remaining) {
        ssize_t received = pread(fd, out, remaining, (off_t)offset);
        if (received < 0 && errno == EINTR)
            continue;
        if (received <= 0)
            return NO;
        remaining -= (size_t)received;
        out += received;
        offset += (uint64_t)received;
    }
    return YES;
}

static BOOL CRSafeID(id value)
{
    if (![value isKindOfClass:NSString.class])
        return NO;
    NSString *text = value;
    if (text.length == 0 || text.length > 200)
        return NO;
    static NSCharacterSet *allow = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allow = [NSCharacterSet characterSetWithCharactersInString:
                 @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
    });
    return [text rangeOfCharacterFromSet:allow.invertedSet].location == NSNotFound;
}

static BOOL CRValidInfo(NSDictionary *info)
{
    if (![info isKindOfClass:NSDictionary.class] ||
        !CRSafeID(info[@"applicationIdentifier"]) ||
        !CRSafeID(info[@"containerIdentifier"]) ||
        ![info[@"containerName"] isKindOfClass:NSString.class])
        return NO;

    NSDictionary *paths = info[@"originalPaths"];
    if (![paths isKindOfClass:NSDictionary.class] ||
        paths.count == 0 || paths.count > 64)
        return NO;
    for (id identifier in paths) {
        id path = paths[identifier];
        if (!CRSafeID(identifier) ||
            ![path isKindOfClass:NSString.class] ||
            [path length] > 4096 || ![path hasPrefix:@"/"])
            return NO;
        for (NSString *segment in [path componentsSeparatedByString:@"/"]) {
            if ([segment isEqualToString:@".."] ||
                [segment isEqualToString:@"."])
                return NO;
        }
    }
    id vendor = info[@"deviceIdentifierForVendor"];
    if (vendor && (![vendor isKindOfClass:NSString.class] ||
                   [vendor length] > 200))
        return NO;
    NSSet *accepted = [NSSet setWithArray:@[
        @"applicationIdentifier", @"containerIdentifier", @"containerName",
        @"originalPaths", @"deviceIdentifierForVendor",
    ]];
    for (id field in info) {
        if (![field isKindOfClass:NSString.class] ||
            ![accepted containsObject:field])
            return NO;
    }
    return YES;
}

static NSData *CRInflate(const uint8_t *source, size_t length,
                        NSUInteger targetSize, uint16_t method)
{
    if (targetSize > CRInfoLimit || length > CRCompressedInfoLimit)
        return nil;
    if (method == 0) {
        if (length != targetSize)
            return nil;
        return [NSData dataWithBytes:source length:targetSize];
    }
    if (method != 8)
        return nil;
    /* Leave one byte of output headroom: raw zlib streams can need to
     * finish reading an end-of-block marker after producing exactly the
     * advertised output. Still reject ANY excess uncompressed byte. */
    NSMutableData *buffer = [NSMutableData dataWithLength:targetSize + 1];
    z_stream strm = {0};
    strm.next_in = (Bytef *)source;
    strm.avail_in = (uInt)length;
    strm.next_out = buffer.mutableBytes;
    strm.avail_out = (uInt)buffer.length;
    if (inflateInit2(&strm, -MAX_WBITS) != Z_OK)
        return nil;
    int code = inflate(&strm, Z_FINISH);
    BOOL valid = (code == Z_STREAM_END && strm.total_in == length &&
                  strm.total_out == targetSize);
    inflateEnd(&strm);
    if (!valid)
        return nil;
    buffer.length = targetSize;
    return buffer;
}

/*
 * Read ONLY the first central-directory entry. ZIP writers using bit 3
 * (data descriptor) may leave both LOCAL ZIP64 size fields at zero.
 * The CENTRAL ZIP64 extra contains the actual sizes even in that case.
 *
 * This is intentionally not a whole-archive validator and can never
 * authorize extraction or a Restore operation.
 */
typedef struct {
    uint64_t compressed;
    uint64_t uncompressed;
    uint32_t crc;
    uint16_t flags;
    uint16_t method;
} CRCentralInfo;

static BOOL CRReadFirstCentralInfo(int fd, uint64_t fileSize,
                                   CRCentralInfo *found)
{
    if (fileSize < 22)
        return NO;
    const uint64_t tailSize = MIN(fileSize, (uint64_t)(65535 + 22));
    const uint64_t tailOffset = fileSize - tailSize;
    NSMutableData *tail = [NSMutableData dataWithLength:(NSUInteger)tailSize];
    if (!CRRead(fd, tailOffset, tail.mutableBytes, tail.length, fileSize))
        return NO;

    const uint8_t *bytes = tail.bytes;
    uint64_t directoryStart = 0;
    uint64_t directorySize = 0;
    BOOL sawEnd = NO;
    for (NSInteger position = (NSInteger)tailSize - 22; position >= 0; --position) {
        const uint8_t *eocd = bytes + position;
        if (CR32(eocd) != 0x06054b50 ||
            CR16(eocd + 20) != tailSize - (uint64_t)position - 22)
            continue;
        if (CR16(eocd + 4) != 0 || CR16(eocd + 6) != 0 ||
            CR16(eocd + 8) == 0 || CR16(eocd + 8) != CR16(eocd + 10))
            return NO; /* no split archives or ZIP64 EOCD yet */

        directorySize = CR32(eocd + 12);
        directoryStart = CR32(eocd + 16);
        const uint64_t endOffset = tailOffset + (uint64_t)position;
        if (directorySize == UINT32_MAX || directoryStart == UINT32_MAX ||
            directoryStart > endOffset ||
            directorySize != endOffset - directoryStart ||
            directorySize < 46)
            return NO;
        sawEnd = YES;
        break;
    }
    if (!sawEnd)
        return NO;

    uint8_t central[46];
    if (!CRRead(fd, directoryStart, central, sizeof(central), fileSize) ||
        CR32(central) != 0x02014b50)
        return NO;
    const uint16_t nameSize = CR16(central + 28);
    const uint16_t extraSize = CR16(central + 30);
    const uint16_t commentSize = CR16(central + 32);
    if (nameSize != 10 || extraSize > 1024 ||
        CR16(central + 34) != 0 || /* disk start */
        CR32(central + 42) != 0 || /* first LOCAL offset */
        (uint64_t)46 + nameSize + extraSize + commentSize > directorySize)
        return NO;
    uint8_t name[10];
    if (!CRRead(fd, directoryStart + 46, name, sizeof(name), fileSize) ||
        memcmp(name, "Info.plist", sizeof(name)) != 0)
        return NO;

    uint64_t compressed = CR32(central + 20);
    uint64_t uncompressed = CR32(central + 24);
    if (compressed == UINT32_MAX || uncompressed == UINT32_MAX) {
        uint8_t extra[1024];
        if (extraSize < 4 ||
            !CRRead(fd, directoryStart + 46 + nameSize, extra,
                    extraSize, fileSize))
            return NO;
        BOOL sizesFound = NO;
        for (NSUInteger at = 0; at + 4 <= extraSize;) {
            uint16_t tag = CR16(extra + at);
            uint16_t count = CR16(extra + at + 2);
            at += 4;
            if (count > extraSize - at)
                return NO;
            if (tag == 1) {
                NSUInteger required = (uncompressed == UINT32_MAX ? 8 : 0) +
                                      (compressed == UINT32_MAX ? 8 : 0);
                if (count < required)
                    return NO;
                NSUInteger cursor = at;
                if (uncompressed == UINT32_MAX) {
                    uncompressed = CR64(extra + cursor);
                    cursor += 8;
                }
                if (compressed == UINT32_MAX)
                    compressed = CR64(extra + cursor);
                sizesFound = YES;
                break;
            }
            at += count;
        }
        if (!sizesFound)
            return NO;
    }
    if (compressed > CRCompressedInfoLimit ||
        uncompressed > CRInfoLimit)
        return NO;
    found->compressed = compressed;
    found->uncompressed = uncompressed;
    found->crc = CR32(central + 16);
    found->flags = CR16(central + 8);
    found->method = CR16(central + 10);
    return YES;
}

static NSDictionary<NSString *, id> *CRReadInfoFromFD(int fd,
                                                 NSInteger *failureStage)
{
    if (failureStage) *failureStage = 10;
    struct stat fileStat;
    if (fstat(fd, &fileStat) != 0 || !S_ISREG(fileStat.st_mode) ||
        fileStat.st_size < 30 || (uint64_t)fileStat.st_size > CRArchiveLimit)
        return nil;

    const uint64_t size = (uint64_t)fileStat.st_size;
    if (failureStage) *failureStage = 20;
    uint8_t header[30];
    if (!CRRead(fd, 0, header, sizeof(header), size) ||
        CR32(header) != 0x04034b50)
        return nil;
    const uint16_t generalFlags = CR16(header + 6);
    const uint16_t method = CR16(header + 8);
    if ((generalFlags & ~(uint16_t)0x0808) != 0 ||
        (method != 0 && method != 8))
        return nil;

    const uint16_t nameLength = CR16(header + 26);
    const uint16_t extraLength = CR16(header + 28);
    const uint64_t headerBytes = 30ULL + nameLength + extraLength;
    if (nameLength != 10 || extraLength > 1024 ||
        headerBytes > size)
        return nil;
    if (failureStage) *failureStage = 30;
    uint8_t name[10];
    if (!CRRead(fd, 30, name, sizeof(name), size) ||
        memcmp(name, "Info.plist", sizeof(name)) != 0)
        return nil;

    /*
     * In both original Crane and Python's non-seek fixture, bit 3 is set
     * and the local ZIP64 extra stores (0, 0). Locate the first CENTRAL
     * record for authoritative sizes; never attempt raw Deflate with the
     * empty local placeholders.
     */
    if (failureStage) *failureStage = 35;
    CRCentralInfo central = {0};
    if (!CRReadFirstCentralInfo(fd, size, &central) ||
        central.flags != generalFlags || central.method != method)
        return nil;

    uint64_t compressed = CR32(header + 18);
    uint64_t uncompressed = CR32(header + 22);
    BOOL zip64 = compressed == UINT32_MAX || uncompressed == UINT32_MAX;
    if (failureStage) *failureStage = 40;
    if (zip64) {
        if (extraLength < 20)
            return nil;
        uint8_t extra[1024];
        if (!CRRead(fd, 30 + nameLength, extra, extraLength, size))
            return nil;
        BOOL found = NO;
        for (NSUInteger cursor = 0; cursor + 4 <= extraLength;) {
            uint16_t type = CR16(extra + cursor);
            uint16_t fieldSize = CR16(extra + cursor + 2);
            cursor += 4;
            if (fieldSize > extraLength - cursor)
                return nil;
            if (type == 1 && fieldSize >= 16) {
                uncompressed = CR64(extra + cursor);
                compressed = CR64(extra + cursor + 8);
                found = YES;
                break;
            }
            cursor += fieldSize;
        }
        if (!found)
            return nil;
    }
    /* Local size 0 is legal only for a descriptor-based entry, provided
     * the central directory supplies bounded, nonzero actual sizes. */
    if (generalFlags & 0x0008) {
        if ((compressed != 0 && compressed != central.compressed) ||
            (uncompressed != 0 && uncompressed != central.uncompressed))
            return nil;
    } else if (compressed != central.compressed ||
               uncompressed != central.uncompressed ||
               CR32(header + 14) != central.crc) {
        return nil;
    }
    compressed = central.compressed;
    uncompressed = central.uncompressed;
    if (compressed > CRCompressedInfoLimit ||
        uncompressed > CRInfoLimit ||
        compressed > size - headerBytes)
        return nil;

    if (failureStage) *failureStage = 50;
    NSMutableData *compressedData = [NSMutableData dataWithLength:(NSUInteger)compressed];
    if (!CRRead(fd, headerBytes, compressedData.mutableBytes,
                (size_t)compressed, size))
        return nil;
    NSData *plistBytes = CRInflate(compressedData.bytes,
                                  compressedData.length,
                                  (NSUInteger)uncompressed, method);
    if (!plistBytes)
        return nil;

    if (failureStage) *failureStage = 60;
    uint32_t wantedCRC = CR32(header + 14);
    if (generalFlags & 0x0008) {
        uint64_t after = headerBytes + compressed;
        uint8_t descriptor[24];
        size_t length = zip64 ? 24 : 16;
        if (!CRRead(fd, after, descriptor, length, size) ||
            CR32(descriptor) != 0x08074b50)
            return nil;
        wantedCRC = CR32(descriptor + 4);
        uint64_t descriptorCompressed = zip64 ? CR64(descriptor + 8)
                                              : CR32(descriptor + 8);
        uint64_t descriptorUncompressed = zip64 ? CR64(descriptor + 16)
                                                : CR32(descriptor + 12);
        if (descriptorCompressed != compressed ||
            descriptorUncompressed != uncompressed ||
            wantedCRC != central.crc)
            return nil;
    }
    if (failureStage) *failureStage = 70;
    uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
    crc = (uint32_t)crc32(crc, plistBytes.bytes, (uInt)plistBytes.length);
    if (crc != wantedCRC)
        return nil;

    if (failureStage) *failureStage = 80;
    NSPropertyListFormat format = NSPropertyListBinaryFormat_v1_0;
    NSError *parseError = nil;
    id propertyList = [NSPropertyListSerialization
        propertyListWithData:plistBytes
                     options:NSPropertyListImmutable
                      format:&format
                       error:&parseError];
    if (format != NSPropertyListBinaryFormat_v1_0 ||
        !CRValidInfo(propertyList))
        return nil;

    if (failureStage) *failureStage = 90;
    struct stat endStat;
    if (fstat(fd, &endStat) != 0 ||
        endStat.st_dev != fileStat.st_dev ||
        endStat.st_ino != fileStat.st_ino ||
        endStat.st_size != fileStat.st_size ||
        endStat.st_mtime != fileStat.st_mtime)
        return nil;
    return propertyList;
}

@implementation CRBackupNativeCore

+ (NSDictionary<NSString *, id> *)readSingleBackupInfoAtPath:(NSString *)path
                                                        error:(NSError **)error
{
    if (![path isKindOfClass:NSString.class] || !path.length) {
        CRFail(error, 1);
        return nil;
    }
    int flags = O_RDONLY;
#ifdef O_NOFOLLOW
    flags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
    flags |= O_CLOEXEC;
#endif
    int fd = open(path.fileSystemRepresentation, flags);
    if (fd < 0) {
        CRFail(error, 2);
        return nil;
    }
    NSDictionary *result = nil;
    NSInteger failureStage = 10;
    @try {
        result = CRReadInfoFromFD(fd, &failureStage);
    } @finally {
        close(fd);
    }
    if (!result)
        CRFail(error, failureStage);
    return result;
}

+ (NSData *)binarySingleInfoForApplicationIdentifier:(NSString *)applicationID
                                  containerIdentifier:(NSString *)containerID
                                        containerName:(NSString *)containerName
                                       originalPaths:(NSDictionary<NSString *,NSString *> *)paths
                            deviceIdentifierForVendor:(NSString *)vendorID
                                                error:(NSError **)error
{
    NSMutableDictionary *info = [@{
        @"applicationIdentifier": applicationID ?: @"",
        @"containerIdentifier": containerID ?: @"",
        @"containerName": containerName ?: @"",
        @"originalPaths": paths ?: @{},
    } mutableCopy];
    if (vendorID)
        info[@"deviceIdentifierForVendor"] = vendorID;
    if (!CRValidInfo(info)) {
        CRFail(error, 4);
        return nil;
    }
    NSData *encoded = [NSPropertyListSerialization
        dataWithPropertyList:info format:NSPropertyListBinaryFormat_v1_0
                    options:0 error:error];
    if (!encoded || encoded.length > CRInfoLimit) {
        CRFail(error, 5);
        return nil;
    }
    return encoded;
}

+ (NSDictionary<NSString *, id> *)writableMetadataAttributes:(NSDictionary *)attributes
{
    if (![attributes isKindOfClass:NSDictionary.class])
        return @{};
    NSSet *numbers = [NSSet setWithArray:@[
        NSFileOwnerAccountID, NSFileGroupOwnerAccountID, NSFilePosixPermissions,
        NSFileHFSCreatorCode, NSFileHFSTypeCode,
    ]];
    NSSet *booleans = [NSSet setWithArray:@[
        NSFileBusy, NSFileExtensionHidden, NSFileImmutable,
    ]];
    NSSet *dates = [NSSet setWithArray:@[
        NSFileCreationDate, NSFileModificationDate,
    ]];
    NSSet *names = [NSSet setWithArray:@[
        NSFileOwnerAccountName, NSFileGroupOwnerAccountName,
    ]];
    NSMutableDictionary *filtered = [NSMutableDictionary dictionary];
    for (id field in attributes) {
        if (![field isKindOfClass:NSString.class])
            continue;
        id value = attributes[field];
        if ([numbers containsObject:field]) {
            if (![value isKindOfClass:NSNumber.class] ||
                CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ||
                [value longLongValue] < 0)
                continue;
        } else if ([booleans containsObject:field]) {
            if (![value isKindOfClass:NSNumber.class] ||
                CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID())
                continue;
        } else if ([dates containsObject:field]) {
            if (![value isKindOfClass:NSDate.class])
                continue;
        } else if ([names containsObject:field]) {
            if (![value isKindOfClass:NSString.class])
                continue;
        } else {
            continue;
        }
        filtered[field] = value;
    }
    return filtered;
}

+ (NSData *)binaryMetadataForIndexedAttributes:(NSDictionary<NSString *, NSDictionary *> *)entries
                                         error:(NSError **)error
{
    if (![entries isKindOfClass:NSDictionary.class] ||
        entries.count > 10000) {
        CRFail(error, 6);
        return nil;
    }
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
    for (id path in entries) {
        if (![path isKindOfClass:NSString.class] || [path length] == 0 ||
            [path length] > 4096 || [path hasPrefix:@"/"] ||
            [path rangeOfCharacterFromSet:controls].location != NSNotFound) {
            CRFail(error, 7);
            return nil;
        }
        NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
        if (parts.count < 1 || !CRSafeID(parts[0])) {
            CRFail(error, 8);
            return nil;
        }
        for (NSString *part in parts) {
            if (!part.length || [part isEqualToString:@"."] ||
                [part isEqualToString:@".."]) {
                CRFail(error, 9);
                return nil;
            }
        }
        id original = entries[path];
        if (![original isKindOfClass:NSDictionary.class]) {
            CRFail(error, 10);
            return nil;
        }
        safe[path] = [self writableMetadataAttributes:original];
    }
    NSData *result = [NSPropertyListSerialization
        dataWithPropertyList:safe format:NSPropertyListBinaryFormat_v1_0
                    options:0 error:error];
    if (!result || result.length > 2 * 1024 * 1024) {
        CRFail(error, 11);
        return nil;
    }
    return result;
}

@end
