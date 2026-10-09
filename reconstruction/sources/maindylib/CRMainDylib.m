/*
 * " Crane.dylib" — the per-app container redirection library.
 *
 * FAITHFUL RECONSTRUCTION. Every function in this file corresponds 1:1 to a
 * function recovered from Crane.dylib_export_for_ai, and the control flow is
 * transcribed from the decompiled pseudocode without adding behaviour.
 * Where the upstream code is unsafe the unsafe form is kept and flagged.
 *
 *   InitFunc_0 (0x65D0)                  -> CRInitFunc
 *   sandbox_container_path_for_pid_hook  -> CRSandboxContainerPathForPidHook
 *   containerPathForContainer (0x6B2C)   -> CRContainerPathForContainer (in CRPaths.h)
 *   normalizedContainerID (0x6DC0)       -> CRNormalizedContainerID (in CRPaths.h)
 *   initProtection (0x7268)              -> CRInitProtection
 *   new_unlink (0x721C)                  -> CRNewUnlink
 *   new_readdir (0x71C0)                 -> CRNewReaddir
 *   new_readdir_r (0x7140)               -> CRNewReaddirR
 *   new_URLEnumeratorGetNextURL (0x70B0) -> CRNewURLEnumeratorGetNextURL
 *   HCHookFunctions (0x7360)             -> CRHookFunctions
 *   localize (0x6924)                    -> CRLocalize      (CRCommon.m)
 *   requestAuthentication (0x6E08)       -> CRRequestAuthentication (CRCommon.m)
 *   sub_6F40                             -> CRCommon.m
 *   safe_getBundleIdentifier (0x6544)    -> CRSafeGetBundleIdentifier (CRCommon.m)
 *   createDirectoryIfNotExists (0x6BE0)  -> CRCreateDirectoryIfNotExists (CRCommon.m)
 *
 * The library has no Objective-C classes (no __objc_classlist section) and
 * links libobjc, Foundation, CoreFoundation, CydiaSubstrate, libc++ and
 * LocalAuthentication.
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#import <dlfcn.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>
#import <dirent.h>

#import "../common/CRPaths.h"
#import "../common/CRCommon.h"

/* ------------------------------------------------------------------------- */
/* Hook table                                                                */
/* ------------------------------------------------------------------------- */

/* Struct as laid out by the recovered code: three 8-byte words per entry,
 * consumed as {original, hook, original_storage} by HCHookFunctions. */
struct CRHookEntry {
    void *original;
    void *hook;
    void *originalStorage;
};

static struct CRHookEntry _crHookTable[16];
static unsigned _crHookCount = 0;

static void *org_sandbox_container_path_for_pid;
static void *org_unlink;
static void *org_readdir;
static void *org_readdir_r;
static void *org_URLEnumeratorGetNextURL;

/* crane_activeContainerIdentifier - global in the original at
 * _crane_activeContainerIdentifier; it is only ever written here, from the
 * CRANE_CONTAINER_IDENTIFIER environment variable. */
static NSString *_crActiveContainerIdentifier = nil;

/* ------------------------------------------------------------------------- */
/* Protection hooks (0x7268 and friends)                                      */
/* ------------------------------------------------------------------------- */

/* Offset of d_name within `struct dirent` on Darwin. Recovered from the
 * `strstr(entry + 21, ...)` argument in Crane 0x7140 / 0x71C0. */
#define CR_DIRENT_D_NAME_OFFSET 21

/* FAITHFUL: upstream does not null-check the path. Kept verbatim; a NULL path
 * to unlink() is a caller bug that upstream also crashes on. Recorded in
 * final/KNOWN_DIFFERENCES.md as a preserved upstream latent crash. */
static int CRNewUnlink(const char *path)
{
    if (strstr(path, CR_CONTAINERS_DIR_TRAILER.UTF8String))
        return 0;
    return ((int (*)(const char *))org_unlink)(path);
}

static struct dirent *CRNewReaddir(DIR *dirp)
{
    struct dirent *entry;
    do {
        entry = ((struct dirent *(*)(DIR *))org_readdir)(dirp);
    } while (entry && strstr((const char *)entry + CR_DIRENT_D_NAME_OFFSET,
                             CR_CONTAINERS_DIR_TRAILER.UTF8String));
    return entry;
}

static int CRNewReaddirR(DIR *dirp, struct dirent *entry, struct dirent **result)
{
    int rc;
    do {
        rc = ((int (*)(DIR *, struct dirent *, struct dirent **))org_readdir_r)(dirp, entry, result);
    } while (rc == 0 && *result &&
             strstr((const char *)*result + CR_DIRENT_D_NAME_OFFSET,
                    CR_CONTAINERS_DIR_TRAILER.UTF8String));
    return rc;
}

/* Signature taken from the recovered call site: the original is resolved as
 * `_URLEnumeratorGetNextURL` in CoreServicesInternal and invoked as
 * org_URLEnumeratorGetNextURL(self, &currentURL, urlEnumerator). The third
 * argument's meaning is not recoverable; it is forwarded opaquely. */
typedef CFURLRef (*CRURLEnumeratorGetNextURLFn)(void *self, CFURLRef *current, void *enumerator);

static CFURLRef CRNewURLEnumeratorGetNextURL(void *self, CFURLRef *current, void *enumerator)
{
    CFURLRef next;
    do {
        next = ((CRURLEnumeratorGetNextURLFn)org_URLEnumeratorGetNextURL)(self, current, enumerator);
        if (!current)
            break;
        if (next != NULL)
            break;
        if (!*current)
            break;
        CFStringRef s = CFURLGetString(*current);
        if (!s)
            break;
    } while (CFStringFind(s, CFSTR(CR_CONTAINERS_DIR_TRAILER), 0).location != kCFNotFound);
    return next;
}

/* initProtection (0x7268): registers unlink/readdir/readdir_r unconditionally
 * and URLEnumeratorGetNextURL only if the symbol resolves. */
static void CRInitProtection(struct CRHookEntry *table, unsigned *count)
{
    table[0].original = (void *)&unlink;
    table[0].hook = (void *)CRNewUnlink;
    table[0].originalStorage = (void *)&org_unlink;

    table[1].original = (void *)&readdir;
    table[1].hook = (void *)CRNewReaddir;
    table[1].originalStorage = (void *)&org_readdir;

    table[2].original = (void *)&readdir_r;
    table[2].hook = (void *)CRNewReaddirR;
    table[2].originalStorage = (void *)&org_readdir_r;

    *count += 3;

    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreServicesInternal.framework/"
                          "CoreServicesInternal", RTLD_NOW);
    if (handle) {
        void *sym = dlsym(handle, "_URLEnumeratorGetNextURL");
        if (sym) {
            table[3].original = sym;
            table[3].hook = (void *)CRNewURLEnumeratorGetNextURL;
            table[3].originalStorage = (void *)&org_URLEnumeratorGetNextURL;
            ++*count;
        }
    }
}

/* ------------------------------------------------------------------------- */
/* HCHookFunctions (0x7360)                                                    */
/* ------------------------------------------------------------------------- */

/* Upstream prefers libhooker when `__LHHookFunctions` is present and otherwise
 * falls back to MSHookFunction triples. Reproduced so the dylib works on both
 * Substrate and ElleKit installs. */
typedef void (*CRLHHookFunctionsFn)(void);

static int CRHookFunctions(struct CRHookEntry *table, int count)
{
    static CRLHHookFunctionsFn lhHookFunctions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lhHookFunctions = (CRLHHookFunctionsFn)dlsym(RTLD_DEFAULT, "__LHHookFunctions");
    });

    if (lhHookFunctions) {
        lhHookFunctions();
        return 0;
    }

    for (int i = 0; i < count; ++i) {
        struct CRHookEntry *e = &table[i];
        MSHookFunction(e->original, e->hook, e->originalStorage);
    }
    return 0;
}

/* ------------------------------------------------------------------------- */
/* sandbox_container_path_for_pid hook (0x6564)                               */
/* ------------------------------------------------------------------------- */

typedef int (*CRSandboxContainerPathForPidFn)(int pid, char *buffer, size_t size);

static int CRSandboxContainerPathForPidHook(int pid, char *buffer, size_t size)
{
    int rc = ((CRSandboxContainerPathForPidFn)org_sandbox_container_path_for_pid)(pid, buffer, size);

    /* The original ALWAYS runs first. Only for the current process is the
     * caller-provided buffer overwritten with $HOME. The return value is
     * forwarded unchanged. */
    if (pid == getpid()) {
        const char *home = getenv(CR_ENV_HOME.UTF8String);
        strncpy(buffer, home, size);
    }

    return rc;
}

/* ------------------------------------------------------------------------- */
/* InitFunc_0 (0x65D0)                                                        */
/* ------------------------------------------------------------------------- */

__attribute__((constructor))
static void CRInitFunc(void)
{
    /* 1. Consume the three launch-environment variables. Each is unset exactly
     *    once so the app cannot discover the container from environ. */
    const char *identifier = getenv(CR_ENV_CONTAINER_IDENTIFIER.UTF8String);
    const char *protect = getenv(CR_ENV_PROTECT_CONTAINERS.UTF8String);
    const char *spoof = getenv(CR_ENV_SPOOF_SANDBOX_LOOKUPS.UTF8String);

    if (identifier) {
        unsetenv(CR_ENV_CONTAINER_IDENTIFIER.UTF8String);
        _crActiveContainerIdentifier = [[NSString alloc] initWithUTF8String:identifier];
    }

    int protectContainers = 0;
    if (protect) {
        unsetenv(CR_ENV_PROTECT_CONTAINERS.UTF8String);
        protectContainers = (strcmp(protect, CR_ENV_PROTECT_VALUE) == 0);
    }

    unsigned count = 0;
    if (spoof) {
        _crHookTable[count].original = (void *)&sandbox_container_path_for_pid;
        _crHookTable[count].hook = (void *)CRSandboxContainerPathForPidHook;
        _crHookTable[count].originalStorage = (void *)&org_sandbox_container_path_for_pid;
        count = 1;
        unsetenv(CR_ENV_SPOOF_SANDBOX_LOOKUPS.UTF8String);
    }

    if (_crActiveContainerIdentifier) {
        /* 2. Materialise the container skeleton. The exact list is recovered
         *    from Crane 0x65D0. Library/SplashBoard is included because the
         *    original creates it (purpose unknown - U-11). */
        NSString *home = NSHomeDirectory();
        NSString *container = CRContainerPathForContainer(_crActiveContainerIdentifier, home);
        NSString *tmp = [container stringByAppendingPathComponent:@"tmp"];

        CRCreateDirectoryIfNotExists(container);
        CRCreateDirectoryIfNotExists(tmp);
        CRCreateDirectoryIfNotExists([container stringByAppendingPathComponent:@"Library"]);
        CRCreateDirectoryIfNotExists([container stringByAppendingPathComponent:@"Library/Caches"]);
        CRCreateDirectoryIfNotExists([container stringByAppendingPathComponent:@"Library/Preferences"]);
        CRCreateDirectoryIfNotExists([container stringByAppendingPathComponent:@"Library/SplashBoard"]);
        CRCreateDirectoryIfNotExists([container stringByAppendingPathComponent:@"Documents"]);
        CRCreateDirectoryIfNotExists([container stringByAppendingPathComponent:@"SystemData"]);

        /* 3. Re-point the process environment at the container. */
        setenv(CR_ENV_FIXED_USER_HOME.UTF8String, container.UTF8String, 1);
        setenv(CR_ENV_HOME.UTF8String, container.UTF8String, 1);
        setenv(CR_ENV_TMPDIR.UTF8String, tmp.UTF8String, 1);
    } else if (protectContainers) {
        CRInitProtection(_crHookTable + count, &count);
    }

    if (count >= 1)
        CRHookFunctions(_crHookTable, (int)count);
}