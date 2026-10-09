/*
 * CRCommon.h — small helpers shared by every reconstructed component.
 */

#ifndef CR_COMMON_H
#define CR_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <string.h>
#import <unistd.h>

#import "CRPaths.h"
#import "CRManager.h"
#import "CRPreferences.h"

/* Substrate/ElleKit surface. Declared here rather than pulled from a header so
 * the reconstruction builds against either Substrate or libhooker without a
 * vendored copy of either header. */
#ifdef __cplusplus
extern "C" {
#endif

typedef void (*MSHookFunctionPointer)(void);
extern void MSHookFunction(void *symbol, void *replacement, void **result);
extern void MSHookMessageEx(Class target, SEL selector, IMP replacement, IMP *result);

typedef void (*LHHookFunctionPointer)(void);
extern void *dlsym(void *handle, const char *symbol);

#ifdef __cplusplus
}
#endif

/* libroot path shim recovered independently in Crane, CraneSB, CraneSupport
 * and CranePrefs. Upstream resolves libroot_jbrootpath from @rpath/libroot.dylib
 * once. Its built-in fallback only prefixes /var/jb when /var/LIY exists,
 * leaves /var/mobile paths untouched, and otherwise returns the input path. */
typedef char *(*CRLibrootJbrootPathFn)(const char *path, char *buffer);

static inline NSString *CRJailbreakRootPath(NSString *path)
{
    if (!path)
        return nil;

    static CRLibrootJbrootPathFn jbrootPath;
    static void *librootHandle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        librootHandle = dlopen("@rpath/libroot.dylib", RTLD_NOW);
        if (librootHandle)
            jbrootPath = (CRLibrootJbrootPathFn)dlsym(librootHandle, "libroot_jbrootpath");
    });

    const char *input = path.fileSystemRepresentation;
    if (!input)
        return nil;

    char buffer[1024];
    const char *resolved = NULL;
    if (jbrootPath) {
        resolved = jbrootPath(input, buffer);
    } else {
        /* Equivalent result to the recovered fallback at Crane 0x631C. */
        BOOL rootlessMarkerPresent = (access("/var/LIY", F_OK) == 0);
        BOOL isAbsolute = (input[0] == '/');
        BOOL isVarMobile = (strncmp(input, "/var/mobile", 11) == 0);
        if (rootlessMarkerPresent && isAbsolute && !isVarMobile) {
            strlcpy(buffer, "/var/jb", sizeof(buffer));
            strlcat(buffer, input, sizeof(buffer));
        } else {
            strlcpy(buffer, input, sizeof(buffer));
        }
        resolved = buffer;
    }

    return resolved ? [NSString stringWithUTF8String:resolved] : nil;
}

/* Presence check for an optional tweak. Upstream calls this
 * `getInjectionPlatform` / `isDylibLoaded`; the recovered implementation
 * translates the jailbreak path, dlopen()s it and dlcloses it. */
static inline BOOL CRIsDylibLoaded(NSString *path)
{
    NSString *resolvedPath = CRJailbreakRootPath(path);
    if (!resolvedPath)
        return NO;
    void *handle = dlopen(resolvedPath.fileSystemRepresentation, RTLD_NOW);
    if (!handle)
        return NO;
    dlclose(handle);
    return YES;
}

/* The four icons Crane ships in /Library/Application Support/Crane.bundle/Icons. */
static inline NSBundle *CRIconBundle(void)
{
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle bundleWithPath:CRJailbreakRootPath(CR_ICON_BUNDLE_PATH)];
    });
    return bundle;
}

static inline UIImage *CRIcon(NSString *name)
{
    if (name.length == 0)
        return nil;

    NSString *path = [CRIconBundle() pathForResource:name ofType:@"png"];
    if (!path) {
        /* Icons is a plain directory in the recovered bundle, not an NSBundle
         * exposing a private imageForResource: selector. Resolve the PNG path
         * explicitly so this compiles against the public iOS SDK. */
        NSBundle *bundle = [NSBundle bundleWithPath:CRJailbreakRootPath(CR_UI_BUNDLE_PATH)];
        path = [bundle pathForResource:name ofType:@"png" inDirectory:@"Icons"];
    }
    return path ? [UIImage imageWithContentsOfFile:path] : nil;
}

/* ---- helpers transcribed from " Crane.dylib" --------------------------- */
/* Declared here because CraneSB, CraneSupport, CranePrefs and libcrane all use
 * them; the original compiles its own copy into each dylib. Implementations
 * live in CRCommon.m and are the faithful transcriptions documented there. */

typedef void (^CRBiometricHandler)(void);

/* Crane 0x6924 - resolves through /Library/Application Support/Crane.bundle
 * with an en.lproj NSDictionary fallback. */
extern NSString *CRLocalize(NSString *key);

/* Crane 0x6BE0 - mkdir -p with mode 0755, uid/gid 501; errors ignored. */
extern void CRCreateDirectoryIfNotExists(NSString *path);

/* Crane 0x6E08 + 0x6F40 - LAContext biometrics; runs `handler` even when
 * biometrics are unavailable. */
extern void CRRequestAuthentication(NSString *reason, CRBiometricHandler handler);

/* Crane 0x6544 */
extern NSString *CRSafeGetBundleIdentifier(void);

/* CraneSupport 0x647C - last path component of the running executable. */
extern NSString *CRGetProcessName(void);

/* CraneSupport 0x60C8 / CraneSB 0x1F850 - first existing injection inserter. */
extern NSString *CRGetInjectionPlatform(void);

#endif /* CR_COMMON_H */