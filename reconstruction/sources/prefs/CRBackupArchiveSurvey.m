/*
 * G-11 N1: original single .cranect ZIP structural survey, read-only.
 * Verifies central/local headers, bounded member names, ZIP64 sizes,
 * descriptor CRC/size agreement and safe path topology. N1 reads headers
 * only; N3 streams ordinary payload bytes to verify actual CRC32 but NEVER
 * reads Keychain contents. Neither API authorizes Restore.
 */
#import "CRBackupArchiveSurvey.h"
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>
#import <zlib.h>

static NSString * const CRSurveyErrorDomain = @"com.crane.backup.archive.survey";
static const uint64_t CRSurveyArchiveLimit = 512ULL * 1024 * 1024;
static const uint64_t CRSurveyPayloadLimit = 256ULL * 1024 * 1024;
static const uint64_t CRSurveyDirectoryLimit = 16ULL * 1024 * 1024;
static const uint32_t CRSurveyMemberLimit = 10000;

static uint16_t S16(const uint8_t *p) { return (uint16_t)p[0] | (uint16_t)p[1] << 8; }
static uint32_t S32(const uint8_t *p) { return (uint32_t)S16(p) | (uint32_t)S16(p+2) << 16; }
static uint64_t S64(const uint8_t *p) { return (uint64_t)S32(p) | (uint64_t)S32(p+4) << 32; }

static BOOL SRead(int fd, uint64_t at, void *out, size_t amount, uint64_t length)
{
    if (at > length || amount > length - at)
        return NO;
    uint8_t *bytes = out;
    while (amount) {
        ssize_t n = pread(fd, bytes, amount, (off_t)at);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        at += (uint64_t)n;
        amount -= (size_t)n;
        bytes += n;
    }
    return YES;
}

static BOOL SName(NSString *name, BOOL directory)
{
    if (!name.length || name.length > 1024 || [name hasPrefix:@"/"] ||
        [name hasPrefix:@"\\"] || [name rangeOfString:@"\\"].location != NSNotFound ||
        [name rangeOfString:@":"].location != NSNotFound)
        return NO;
    if ([name hasSuffix:@"/"] != directory)
        return NO;
    NSString *normalized = directory ? [name substringToIndex:name.length-1] : name;
    if (!normalized.length)
        return NO;
    NSCharacterSet *controls = [NSCharacterSet controlCharacterSet];
    if ([normalized rangeOfCharacterFromSet:controls].location != NSNotFound)
        return NO;
    for (NSString *part in [normalized componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqualToString:@"."] ||
            [part isEqualToString:@".."])
            return NO;
    }
    return YES;
}

static BOOL SZIP64(const uint8_t *extra, NSUInteger length,
                   uint64_t *uncompressed, uint64_t *compressed,
                   uint64_t *localOffset)
{
    BOOL needU = *uncompressed == UINT32_MAX;
    BOOL needC = *compressed == UINT32_MAX;
    BOOL needO = *localOffset == UINT32_MAX;
    if (!needU && !needC && !needO)
        return YES;
    for (NSUInteger at = 0; at + 4 <= length;) {
        uint16_t tag = S16(extra+at);
        uint16_t size = S16(extra+at+2);
        at += 4;
        if (size > length - at) return NO;
        if (tag == 1) {
            NSUInteger needed = (needU ? 8 : 0) + (needC ? 8 : 0) + (needO ? 8 : 0);
            if (size < needed) return NO;
            NSUInteger valueAt = at;
            if (needU) { *uncompressed = S64(extra+valueAt); valueAt += 8; }
            if (needC) { *compressed = S64(extra+valueAt); valueAt += 8; }
            if (needO) *localOffset = S64(extra+valueAt);
            return YES;
        }
        at += size;
    }
    return NO;
}

/*
 * N3 streaming CRC32 for ONE already-bounded, structurally checked ZIP
 * entry. Fixed 32KiB input/output buffers, no extracted paths or writes.
 * Enforces central-directory claimed uncompressed byte count EXACTLY and
 * rejects trailing compressed bytes or a prematurely ended Deflate stream.
 */
static BOOL SVerifyEntryCRC(int fd, uint64_t body, uint64_t compressed,
                            uint64_t uncompressed, uint16_t method,
                            uint32_t expectedCRC, uint64_t archiveSize)
{
    uint8_t input[32768], output[32768];
    uint64_t consumed = 0, produced = 0;
    uLong crc = crc32(0L, Z_NULL, 0);
    if (method == 0) {
        if (compressed != uncompressed)
            return NO;
        while (consumed < compressed) {
            size_t count = (size_t)MIN((uint64_t)sizeof(input), compressed-consumed);
            if (!SRead(fd, body+consumed, input, count, archiveSize))
                return NO;
            crc = crc32(crc, input, (uInt)count);
            consumed += count;
        }
        return (uint32_t)crc == expectedCRC;
    }
    if (method != 8)
        return NO;

    z_stream stream = {0};
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK)
        return NO;
    BOOL ok = YES, ended = NO;
    while (consumed < compressed && !ended) {
        size_t count = (size_t)MIN((uint64_t)sizeof(input), compressed-consumed);
        if (!SRead(fd, body+consumed, input, count, archiveSize)) {
            ok = NO;
            break;
        }
        consumed += count;
        stream.next_in = input;
        stream.avail_in = (uInt)count;
        do {
            uInt oldInput = stream.avail_in;
            stream.next_out = output;
            stream.avail_out = (uInt)sizeof(output);
            int status = inflate(&stream, Z_NO_FLUSH);
            size_t got = sizeof(output) - stream.avail_out;
            if (got > uncompressed-produced) {
                ok = NO; /* archive expands beyond its declared size */
                break;
            }
            if (got) {
                crc = crc32(crc, output, (uInt)got);
                produced += got;
            }
            if (status == Z_STREAM_END) {
                ended = YES;
                if (stream.avail_in != 0 || consumed != compressed)
                    ok = NO; /* trailing stream or extra bytes */
                break;
            }
            if (status != Z_OK || (!got && oldInput == stream.avail_in)) {
                ok = NO; /* truncated, invalid or stalled Deflate */
                break;
            }
        } while (stream.avail_in != 0 || stream.avail_out == 0);
        if (!ok)
            break;
    }
    if (!ended || produced != uncompressed || (uint32_t)crc != expectedCRC)
        ok = NO;
    inflateEnd(&stream);
    return ok;
}

static NSDictionary<NSString *, id> *SSurvey(int fd, BOOL verifyCRC)
{
    struct stat before;
    if (fstat(fd, &before) != 0 || !S_ISREG(before.st_mode) ||
        before.st_size < 22 || (uint64_t)before.st_size > CRSurveyArchiveLimit)
        return nil;
    uint64_t fileSize = (uint64_t)before.st_size;
    uint64_t tailLength = MIN(fileSize, (uint64_t)(65535 + 22));
    NSMutableData *tail = [NSMutableData dataWithLength:(NSUInteger)tailLength];
    if (!SRead(fd, fileSize-tailLength, tail.mutableBytes, tail.length, fileSize))
        return nil;
    const uint8_t *tailBytes = tail.bytes;
    uint64_t cdOffset = 0, cdSize = 0;
    uint32_t entries = 0;
    BOOL endFound = NO;
    for (NSInteger at = (NSInteger)tailLength-22; at >= 0; --at) {
        const uint8_t *e = tailBytes+at;
        if (S32(e) != 0x06054b50 ||
            S16(e+20) != tailLength-(uint64_t)at-22) continue;
        if (S16(e+4) || S16(e+6) || S16(e+8) == 0 ||
            S16(e+8) != S16(e+10)) return nil;
        entries = S16(e+10);
        cdSize = S32(e+12);
        cdOffset = S32(e+16);
        uint64_t eocdAt = fileSize-tailLength+(uint64_t)at;
        if (entries > CRSurveyMemberLimit || cdSize > CRSurveyDirectoryLimit ||
            cdOffset == UINT32_MAX || cdSize == UINT32_MAX ||
            cdOffset > eocdAt || cdSize != eocdAt-cdOffset || cdSize < 46)
            return nil; /* ZIP64 EOCD / multi-disk not supported */
        endFound = YES;
        break;
    }
    if (!endFound) return nil;

    NSMutableSet<NSString *> *paths = [NSMutableSet setWithCapacity:entries];
    NSMutableSet<NSString *> *actualFiles = [NSMutableSet setWithCapacity:entries];
    uint64_t cursor = cdOffset, previousEnd = 0, totalUncompressed = 0;
    NSUInteger directories = 0, files = 0, keychain = 0;
    uint64_t verifiedBytes = 0;
    NSUInteger verifiedMembers = 0;
    BOOL hasMetadata = NO;

    for (uint32_t i = 0; i < entries; ++i) {
        if (cursor > cdOffset+cdSize ||
            cdOffset+cdSize-cursor < 46) return nil;
        uint8_t c[46];
        if (!SRead(fd, cursor, c, sizeof(c), fileSize) ||
            S32(c) != 0x02014b50) return nil;
        uint16_t nameSize = S16(c+28), extraSize = S16(c+30), commentSize = S16(c+32);
        uint64_t recordLength = (uint64_t)46+nameSize+extraSize+commentSize;
        if (!nameSize || nameSize > 1024 || extraSize > 1024 ||
            recordLength > cdOffset+cdSize-cursor || S16(c+34) != 0)
            return nil;
        uint16_t flags = S16(c+8), method = S16(c+10);
        if ((flags & (uint16_t)~0x0808) != 0 ||
            (method != 0 && method != 8)) return nil;

        uint8_t rawName[1024], extra[1024];
        if (!SRead(fd, cursor+46, rawName, nameSize, fileSize) ||
            !SRead(fd, cursor+46+nameSize, extra, extraSize, fileSize))
            return nil;
        NSString *name = [[NSString alloc] initWithBytes:rawName length:nameSize
                                                 encoding:NSUTF8StringEncoding];
        BOOL isDirectory = rawName[nameSize-1] == '/';
        if (!name || !SName(name, isDirectory)) return nil;
        NSString *logical = isDirectory ?
            [name substringToIndex:name.length-1] : name;
        if ([paths containsObject:logical]) return nil; /* duplicate/collision */
        [paths addObject:logical];
        if (i == 0 && ![name isEqualToString:@"Info.plist"]) return nil;
        if ([name isEqualToString:@"Info.plist"] && i != 0) return nil;
        if ([name isEqualToString:@"Metadata.plist"]) {
            if (i != entries-1 || hasMetadata) return nil;
            hasMetadata = YES;
        }
        /* Also skip case variants and nested Keychain names; never stream
         * a potential credential payload in N3, even on malformed archives. */
        BOOL isKeychain = [[[name lastPathComponent] lowercaseString]
                           isEqualToString:@"keychain.plist"];
        if (isKeychain) keychain++;
        if (isDirectory) {
            directories++;
        } else {
            files++;
            [actualFiles addObject:logical];
        }

        if (c[5] == 3) {
            uint32_t mode = S32(c+38) >> 16;
            uint32_t kind = mode & 0170000;
            if (kind == 0120000 || (kind != 0 &&
                kind != (isDirectory ? 0040000 : 0100000)))
                return nil; /* no symlinks or special nodes */
        }

        uint64_t comp = S32(c+20), uncomp = S32(c+24), local = S32(c+42);
        if (!SZIP64(extra, extraSize, &uncomp, &comp, &local))
            return nil;
        if (uncomp > CRSurveyPayloadLimit ||
            totalUncompressed > CRSurveyPayloadLimit-uncomp)
            return nil;
        totalUncompressed += uncomp;
        if ((i == 0 && local != 0) || local < previousEnd ||
            local >= cdOffset || cdOffset-local < 30)
            return nil;
        uint8_t lh[30];
        if (!SRead(fd, local, lh, sizeof(lh), fileSize) ||
            S32(lh) != 0x04034b50 ||
            S16(lh+6) != flags || S16(lh+8) != method ||
            S16(lh+26) != nameSize)
            return nil;
        uint64_t localExtra = S16(lh+28);
        uint64_t body = local+30+nameSize+localExtra;
        if (body > cdOffset || comp > cdOffset-body)
            return nil;
        uint8_t localName[1024];
        if (!SRead(fd, local+30, localName, nameSize, fileSize) ||
            memcmp(localName, rawName, nameSize) != 0)
            return nil;
        uint64_t localComp = S32(lh+18), localUncomp = S32(lh+22);
        BOOL localZip64 = localComp == UINT32_MAX || localUncomp == UINT32_MAX;
        if (localZip64) {
            if (localExtra < 20 || localExtra > 1024) return nil;
            uint8_t le[1024];
            if (!SRead(fd, local+30+nameSize, le, (size_t)localExtra, fileSize))
                return nil;
            BOOL foundZip64 = NO;
            for (NSUInteger at = 0; at+4 <= localExtra;) {
                uint16_t tag = S16(le+at), width = S16(le+at+2);
                at += 4;
                if (width > localExtra-at) return nil;
                if (tag == 1 && width >= 16) {
                    localUncomp = S64(le+at);
                    localComp = S64(le+at+8);
                    foundZip64 = YES;
                    break;
                }
                at += width;
            }
            if (!foundZip64) return nil;
        }
        if (flags & 8) {
            if ((localComp && localComp != comp) ||
                (localUncomp && localUncomp != uncomp))
                return nil;
        } else if (localComp != comp || localUncomp != uncomp ||
                   S32(lh+14) != S32(c+16)) {
            return nil;
        }
        uint64_t dataEnd = body+comp;
        if (flags & 8) {
            size_t descriptorLen = localZip64 ? 24 : 16;
            uint8_t descriptor[24];
            if (dataEnd > cdOffset || descriptorLen > cdOffset-dataEnd ||
                !SRead(fd, dataEnd, descriptor, descriptorLen, fileSize) ||
                S32(descriptor) != 0x08074b50 ||
                S32(descriptor+4) != S32(c+16))
                return nil;
            uint64_t dComp = localZip64 ? S64(descriptor+8) : S32(descriptor+8);
            uint64_t dUncomp = localZip64 ? S64(descriptor+16) : S32(descriptor+12);
            if (dComp != comp || dUncomp != uncomp) return nil;
            dataEnd += descriptorLen;
        }
        if (dataEnd > cdOffset) return nil;
        /* Never call the content reader on Keychain member bytes. */
        if (verifyCRC && !isKeychain) {
            if (!SVerifyEntryCRC(fd, body, comp, uncomp, method,
                                 S32(c+16), fileSize))
                return nil;
            verifiedBytes += uncomp;
            verifiedMembers++;
        }
        previousEnd = dataEnd;
        cursor += recordLength;
    }
    if (cursor != cdOffset+cdSize || !hasMetadata ||
        files < 2 || ![actualFiles containsObject:@"Info.plist"])
        return nil;
    /* Reject ZIP tree collisions: a regular file cannot be a parent
     * directory of another entry, even if each path is individually safe. */
    for (NSString *name in paths) {
        NSArray<NSString *> *parts = [name componentsSeparatedByString:@"/"];
        NSMutableString *ancestor = [NSMutableString string];
        for (NSUInteger part = 0; part+1 < parts.count; ++part) {
            if (part) [ancestor appendString:@"/"];
            [ancestor appendString:parts[part]];
            if ([actualFiles containsObject:ancestor])
                return nil;
        }
    }
    struct stat after;
    if (fstat(fd, &after) != 0 || before.st_dev != after.st_dev ||
        before.st_ino != after.st_ino || before.st_size != after.st_size ||
        before.st_mtime != after.st_mtime)
        return nil;

    NSMutableDictionary<NSString *, id> *report = [@{
        @"status": @"single_archive_structure_inspected_not_restorable",
        @"entryCount": @(entries), @"fileCount": @(files),
        @"directoryCount": @(directories),
        @"uncompressedBytesClaimed": @(totalUncompressed),
        @"keychainEntryCount": @(keychain),
        @"archiveStructureOnly": @YES,
        @"payloadCRCVerified": @NO,
        @"keychainContentsRead": @NO,
        @"restoreExecutable": @NO,
    } mutableCopy];
    if (verifyCRC) {
        report[@"status"] = @"non_keychain_crc_verified_not_restorable";
        report[@"nonKeychainPayloadCRCVerified"] = @YES;
        report[@"payloadCRCVerified"] = @(keychain == 0);
        report[@"keychainEntriesSkipped"] = @(keychain);
        report[@"verifiedNonKeychainMembers"] = @(verifiedMembers);
        report[@"verifiedNonKeychainBytes"] = @(verifiedBytes);
    }
    return report;
}

@implementation CRBackupArchiveSurvey
+ (NSDictionary<NSString *, id> *)inspectSingleArchiveAtPath:(NSString *)path
                                                       error:(NSError **)error
{
    int fd = -1;
    if ([path isKindOfClass:NSString.class] && path.length) {
        int flags = O_RDONLY;
#ifdef O_NOFOLLOW
        flags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
        flags |= O_CLOEXEC;
#endif
        fd = open(path.fileSystemRepresentation, flags);
    }
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:CRSurveyErrorDomain code:1
            userInfo:@{NSLocalizedDescriptionKey: @"Read-only ZIP survey unavailable"}];
        return nil;
    }
    NSDictionary *result = nil;
    @try { result = SSurvey(fd, NO); }
    @finally { close(fd); }
    if (!result && error)
        *error = [NSError errorWithDomain:CRSurveyErrorDomain code:2
            userInfo:@{NSLocalizedDescriptionKey: @"ZIP structure rejected"}];
    return result;
}

+ (NSDictionary<NSString *, id> *)verifyNonKeychainPayloadAtPath:(NSString *)path
                                                           error:(NSError **)error
{
    int fd = -1;
    if ([path isKindOfClass:NSString.class] && path.length) {
        int flags = O_RDONLY;
#ifdef O_NOFOLLOW
        flags |= O_NOFOLLOW;
#endif
#ifdef O_CLOEXEC
        flags |= O_CLOEXEC;
#endif
        fd = open(path.fileSystemRepresentation, flags);
    }
    if (fd < 0) {
        if (error) *error = [NSError errorWithDomain:CRSurveyErrorDomain code:3
            userInfo:@{NSLocalizedDescriptionKey: @"Read-only CRC scan unavailable"}];
        return nil;
    }
    NSDictionary *result = nil;
    @try { result = SSurvey(fd, YES); }
    @finally { close(fd); }
    if (!result && error)
        *error = [NSError errorWithDomain:CRSurveyErrorDomain code:4
            userInfo:@{NSLocalizedDescriptionKey: @"Non-Keychain CRC validation rejected"}];
    return result;
}
@end
