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
    NSMutableData *buffer = [NSMutableData dataWithLength:MAX(targetSize, (NSUInteger)1)];
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

static NSDictionary<NSString *, id> *CRReadInfoFromFD(int fd)
{
    struct stat fileStat;
    if (fstat(fd, &fileStat) != 0 || !S_ISREG(fileStat.st_mode) ||
        fileStat.st_size < 30 || (uint64_t)fileStat.st_size > CRArchiveLimit)
        return nil;

    const uint64_t size = (uint64_t)fileStat.st_size;
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
    uint8_t name[10];
    if (!CRRead(fd, 30, name, sizeof(name), size) ||
        memcmp(name, "Info.plist", sizeof(name)) != 0)
        return nil;

    uint64_t compressed = CR32(header + 18);
    uint64_t uncompressed = CR32(header + 22);
    BOOL zip64 = compressed == UINT32_MAX || uncompressed == UINT32_MAX;
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
    if (compressed > CRCompressedInfoLimit ||
        uncompressed > CRInfoLimit ||
        compressed > size - headerBytes)
        return nil;

    NSMutableData *compressedData = [NSMutableData dataWithLength:(NSUInteger)compressed];
    if (!CRRead(fd, headerBytes, compressedData.mutableBytes,
                (size_t)compressed, size))
        return nil;
    NSData *plistBytes = CRInflate(compressedData.bytes,
                                  compressedData.length,
                                  (NSUInteger)uncompressed, method);
    if (!plistBytes)
        return nil;

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
            descriptorUncompressed != uncompressed)
            return nil;
    }
    uint32_t crc = (uint32_t)crc32(0L, Z_NULL, 0);
    crc = (uint32_t)crc32(crc, plistBytes.bytes, (uInt)plistBytes.length);
    if (crc != wantedCRC)
        return nil;

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
    @try {
        result = CRReadInfoFromFD(fd);
    } @finally {
        close(fd);
    }
    if (!result)
        CRFail(error, 3);
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
