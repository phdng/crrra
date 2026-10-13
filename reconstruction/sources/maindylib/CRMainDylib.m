/*
 * " Crane.dylib" — the per-app container redirection library.
 *
 * Recovered functions map to Crane.dylib_export_for_ai. The hook backend ABI
 * is verified from ARM64 instructions. Environment snapshots and bounded
 * sandbox pathname writes are explicit safety deviations from the original;
 * device behavior still requires validation.
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
#import <stdint.h>

#import "../common/CRPaths.h"
#import "../common/CRCommon.h"

/* ------------------------------------------------------------------------- */
/* Hook table                                                                */
/* ------------------------------------------------------------------------- */

/* Struct as laid out by the recovered code: four 8-byte words per entry.
 * HCHookFunctions consumes the first three as {original, hook,
 * original_storage} and advances by 32 bytes; the fourth word is reserved and
 * explicitly zeroed at every recovered registration site. */
struct CRHookEntry {
    void *original;
    void *hook;
    void *originalStorage;
    void *reserved;
};

_Static_assert(sizeof(struct CRHookEntry) == 32,
               "CRHookEntry must preserve the recovered 32-byte stride");

static struct CRHookEntry _crHookTable[16];
static unsigned _crHookCount = 0;

extern int sandbox_container_path_for_pid(int pid, char *buffer, size_t size);

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
    } while (result && rc == 0 && *result &&
             strstr((const char *)*result + CR_DIRENT_D_NAME_OFFSET,
                    CR_CONTAINERS_DIR_TRAILER.UTF8String));
    return rc;
}

/* Signature taken from the recovered call site: the original is resolved as
 * `_URLEnumeratorGetNextURL` in CoreServicesInternal and invoked as
 * org_URLEnumeratorGetNextURL(self, &currentURL, urlEnumerator). The third
 * argument's meaning is not recoverable; it is forwarded opaquely. */
typedef int64_t (*CRURLEnumeratorGetNextURLFn)(void *self, CFURLRef *current, void *enumerator);

static int64_t CRNewURLEnumeratorGetNextURL(void *self, CFURLRef *current, void *enumerator)
{
    int64_t status;
    CFStringRef currentString = NULL;
    do {
        status = ((CRURLEnumeratorGetNextURLFn)org_URLEnumeratorGetNextURL)(self, current, enumerator);
        if (!current)
            break;
        if (status != 1)
            break;
        if (!*current)
            break;
        currentString = CFURLGetString(*current);
        if (!currentString)
            break;
    } while (CFStringFind(currentString,
                          (__bridge CFStringRef)CR_CONTAINERS_DIR_TRAILER,
                          0).location != kCFNotFound);
    return status;
}

/* initProtection (0x7268): registers unlink/readdir/readdir_r unconditionally
 * and URLEnumeratorGetNextURL only if the symbol resolves. */
static void CRInitProtection(struct CRHookEntry *table, unsigned *count)
{
    table[0].original = (void *)&unlink;
    table[0].hook = (void *)CRNewUnlink;
    table[0].originalStorage = (void *)&org_unlink;
    table[0].reserved = NULL;

    table[1].original = (void *)&readdir;
    table[1].hook = (void *)CRNewReaddir;
    table[1].originalStorage = (void *)&org_readdir;
    table[1].reserved = NULL;

    table[2].original = (void *)&readdir_r;
    table[2].hook = (void *)CRNewReaddirR;
    table[2].originalStorage = (void *)&org_readdir_r;
    table[2].reserved = NULL;

    *count += 3;

    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreServicesInternal.framework/"
                          "CoreServicesInternal", RTLD_NOW);
    if (handle) {
        void *sym = dlsym(handle, "_URLEnumeratorGetNextURL");
        if (sym) {
            table[3].original = sym;
            table[3].hook = (void *)CRNewURLEnumeratorGetNextURL;
            table[3].originalStorage = (void *)&org_URLEnumeratorGetNextURL;
            table[3].reserved = NULL;
            ++*count;
        }
    }
}

/* ------------------------------------------------------------------------- */
/* HCHookFunctions (0x7360)                                                    */
/* ------------------------------------------------------------------------- */

/* Upstream prefers libhooker when `__LHHookFunctions` is present and otherwise
 * falls back to MSHookFunction using the first three words of each 32-byte
 * hook-table record. Reproduced so the dylib works on both Substrate and
 * ElleKit installs. */
typedef int (*CRLHHookFunctionsFn)(const struct CRHookEntry *table, int count);

static int CRHookFunctions(struct CRHookEntry *table, int count)
{
    static CRLHHookFunctionsFn lhHookFunctions;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lhHookFunctions = (CRLHHookFunctionsFn)dlsym(RTLD_DEFAULT, "__LHHookFunctions");
        if (!lhHookFunctions)
            lhHookFunctions = (CRLHHookFunctionsFn)dlsym(RTLD_DEFAULT, "LHHookFunctions");
    });

    if (lhHookFunctions) {
        /* Native 0x7380 tail-branches with x0=table and w1=count intact.
         * The decompiler's empty argument list is not the call ABI. */
        return lhHookFunctions(table, count);
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
        /* Do not crash on absent HOME or return a partial C pathname. */
        if (buffer && size && home && strlen(home) < size)
            strlcpy(buffer, home, size);
    }

    return rc;
}

/* Reconstruction-only app-to-helper attestation access.
 *
 * Native libSandy profiles grant the helper Mach name to runningboardd,
 * CraneSupport daemons and CraneShortcuts, but not ordinary app sandboxes.
 * Chrome's Code=1003 report confirms the app XPC client cannot reach the
 * same Helper listener used by SpringBoard. Ask libSandy for only the
 * com.opa334.cranehelperd.xpc Mach extension before reporting injection.
 * No app credential, filesystem capability, helper authorization or
 * message ABI is changed by this attempt. */
static BOOL CRPrepareAppRuntimeMachLookup(void)
{
    /* This marker permits a mobile-shell check of the installed binary.
     * A deployed profile file alone does not prove this code was built. */
    static const char * const kRuntimeDiagnosticMarker =
        "APP_RUNTIME_MACH_DIAGNOSTIC_V2";
    NSLog(@"Crane: app runtime Mach profile begin pid=%d marker=%s",
          getpid(), kRuntimeDiagnosticMarker);
    NSString *path = CRJailbreakRootPath(CR_LIB_SANDY);
    if (!path.length) {
        NSLog(@"Crane: app runtime Mach profile failed pid=%d reason=no_libSandy_path",
              getpid());
        return NO;
    }
    dlerror();
    void *handle = dlopen(path.fileSystemRepresentation, RTLD_NOW);
    if (!handle) {
        const char *failure = dlerror();
        NSLog(@"Crane: app runtime Mach profile failed pid=%d reason=dlopen path=%@ detail=%s",
              getpid(), path, failure ?: "unknown");
        return NO;
    }
    dlerror();
    int (*applyProfile)(const char *) =
        (int (*)(const char *))dlsym(handle, "libSandy_applyProfile");
    if (!applyProfile) {
        const char *failure = dlerror();
        NSLog(@"Crane: app runtime Mach profile failed pid=%d reason=no_apply_symbol detail=%s",
              getpid(), failure ?: "unknown");
        dlclose(handle);
        return NO;
    }
    int rc = applyProfile("CraneAppRuntime");
    NSLog(@"Crane: app runtime Mach profile pid=%d status=%d",
          getpid(), rc);
    dlclose(handle);
    return rc == 0;
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
    /* A loaded main dylib without the launch environment previously emitted
     * no log, indistinguishable from failed injection. Log once for non-Apple
     * app bundles before rewriting any environment state; never invent an ID. */
    if (!identifier) {
        NSString *bundleID = CRSafeGetBundleIdentifier();
        if (bundleID.length && ![bundleID hasPrefix:@"com.apple."])
            NSLog(@"Crane: app dylib loaded bundle=%@ pid=%d containerEnvPresent=0",
                  bundleID, getpid());
    }

    if (identifier) {
        /* getenv storage is borrowed; snapshot before mutating environ. */
        _crActiveContainerIdentifier = [[NSString alloc] initWithUTF8String:identifier];
    }

    int protectContainers = 0;
    if (protect) {
        protectContainers = (strcmp(protect, CR_ENV_PROTECT_VALUE) == 0);
    }

    /* Snapshot every borrowed value before the first unsetenv, including
     * whether the spoof flag exists. Native 0x65D0 reads pointers afterwards. */
    BOOL spoofLookups = spoof != NULL;
    if (identifier)
        unsetenv(CR_ENV_CONTAINER_IDENTIFIER.UTF8String);
    if (protect)
        unsetenv(CR_ENV_PROTECT_CONTAINERS.UTF8String);

    /* Reconstruction-only runtime proof is deliberately sent as early as
     * possible after the launch claim has been snapshotted and hidden from
     * environ. System daemons use this live PID→container proof for prefs,
     * keychain and container lookup; sending it before directory/HOME work
     * narrows the window in which their first request could see DEFAULT.
     * It does not claim that the remaining 0x65D0 environment setup is done. */
    if (_crActiveContainerIdentifier.length) {
        CRPrepareAppRuntimeMachLookup();
        CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);
    }

    unsigned count = 0;
    if (spoofLookups) {
        _crHookTable[count].original = (void *)&sandbox_container_path_for_pid;
        _crHookTable[count].hook = (void *)CRSandboxContainerPathForPidHook;
        _crHookTable[count].originalStorage = (void *)&org_sandbox_container_path_for_pid;
        _crHookTable[count].reserved = NULL;
        count = 1;
        unsetenv(CR_ENV_SPOOF_SANDBOX_LOOKUPS.UTF8String);
    }

    if (_crActiveContainerIdentifier || protectContainers || spoofLookups)
        NSLog(@"Crane: app init bundle=%@ container=%@ protection=%d spoof=%d",
              CRSafeGetBundleIdentifier(), _crActiveContainerIdentifier,
              protectContainers, (int)spoofLookups);

    if (_crActiveContainerIdentifier) {
        /* 2. Materialise the container skeleton. The exact list is recovered
         *    from Crane 0x65D0. Library/SplashBoard is included because the
         *    original creates it (purpose unknown - U-11). */
        NSString *home = NSHomeDirectory();
        NSString *container = CRContainerPathForContainer(_crActiveContainerIdentifier, home);
        NSString *tmp = [container stringByAppendingPathComponent:@"tmp"];
        NSLog(@"Crane: redirect home base=%@ target=%@", home, container);

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

    if (_crActiveContainerIdentifier || protectContainers || spoofLookups)
        NSLog(@"Crane: app environment ready container=%@ hooks=%u",
              _crActiveContainerIdentifier, count);

}