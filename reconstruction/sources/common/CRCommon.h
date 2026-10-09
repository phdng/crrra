/*
 * CRCommon.h — small helpers shared by every reconstructed component.
 */

#ifndef CR_COMMON_H
#define CR_COMMON_H

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

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
extern void *MSHookMessageEx(void *target, SEL selector, void *replacement, void *result);

typedef void (*LHHookFunctionPointer)(void);
extern void *dlsym(void *handle, const char *symbol);

#ifdef __cplusplus
}
#endif

/* Presence check for an optional tweak. Upstream calls this
 * `getInjectionPlatform` / `isDylibLoaded`; the recovered implementation
 * dlopen()s the candidate path and dlcloses it. */
static inline BOOL CRIsDylibLoaded(NSString *path)
{
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW);
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
        bundle = [NSBundle bundleWithPath:CR_ICON_BUNDLE_PATH];
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
        NSBundle *bundle = [NSBundle bundleWithPath:CR_UI_BUNDLE_PATH];
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