#ifndef CR_CONTAINER_SCAFFOLD_H
#define CR_CONTAINER_SCAFFOLD_H

#import <Foundation/Foundation.h>

/* Shared actual filesystem implementation; independently executable in CI.
 * The recovered app initializer (Crane 0x65D0/0x6BE0) skips existing paths.
 * This reconstruction additionally requires real directories, not symlinks. */
static inline BOOL CRManagerDirectoryComponentIsSafe(NSString *path)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm destinationOfSymbolicLinkAtPath:path error:NULL])
        return NO;
    BOOL isDirectory = NO;
    return ![fm fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory;
}

static inline BOOL CRManagerEnsureDirectory(NSString *path,
                                            BOOL intermediates,
                                            NSError **error)
{
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!path.length || !CRManagerDirectoryComponentIsSafe(path)) {
        if (error)
            *error = [NSError errorWithDomain:NSCocoaErrorDomain
                code:NSFileWriteFileExistsError userInfo:@{
                    NSFilePathErrorKey: path ?: @"",
                    NSLocalizedDescriptionKey:
                        @"A container directory is occupied by a file or symbolic link."
                }];
        return NO;
    }
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDirectory])
        return isDirectory;
    return [fm createDirectoryAtPath:path withIntermediateDirectories:intermediates
                         attributes:nil error:error];
}

static inline BOOL CRManagerCreateEmptyContainer(NSString *path, NSError **error)
{
    if (!path.length || !CRManagerDirectoryComponentIsSafe(path))
        return NO;
    if (!CRManagerEnsureDirectory(path, YES, error))
        return NO;
    /* Original Crane 0x65D0 scaffold, including Library/SplashBoard. Repeated
     * traversal of Library must skip creation once the real directory exists. */
    for (NSString *subdir in @[@"tmp", @"Library/Caches",
                               @"Library/Preferences", @"Library/SplashBoard",
                               @"Documents", @"SystemData"]) {
        NSString *next = path;
        for (NSString *component in [subdir pathComponents]) {
            next = [next stringByAppendingPathComponent:component];
            if (!CRManagerDirectoryComponentIsSafe(next) ||
                !CRManagerEnsureDirectory(next, NO, error))
                return NO;
        }
    }
    return YES;
}

#endif
