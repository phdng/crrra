/*
 * CRCommon.m — helpers transcribed verbatim from " Crane.dylib".
 *
 * The original compiles these into the main dylib and, where needed, into the
 * others. Keeping one copy here is a deliberate deviation that has no
 * externally observable effect (the functions are pure and stateless apart
 * from two cached bundles).
 *
 * Provenance for each function is in the comment above it; see
 * analysis/hook_reconstruction.md for the full analysis.
 */

#import "CRCommon.h"
#import <LocalAuthentication/LocalAuthentication.h>
#import <unistd.h>

/* Crane 0x6924 ------------------------------------------------------------ */

static NSBundle *CRUIBundle(void)
{
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle bundleWithPath:CR_UI_BUNDLE_PATH];
    });
    return bundle;
}

NSString *CRLocalize(NSString *key)
{
    if (!key)
        return nil;

    NSString *value = [CRUIBundle() localizedStringForKey:key value:key table:nil];

    /* Upstream falls back to the raw en.lproj table when localizedStringForKey
     * returns the key unchanged, which happens for keys present only as an
     * uppercase identifier. */
    if ([value isEqualToString:key]) {
        static NSDictionary *english;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSString *path = [CRUIBundle() pathForResource:@"Localizable"
                                                     ofType:@"strings"
                                                inDirectory:@"en.lproj"];
            english = [NSDictionary dictionaryWithContentsOfFile:path];
        });
        value = english[key] ?: key;
    }

    return value;
}

/* Crane 0x6BE0 ------------------------------------------------------------ */

void CRCreateDirectoryIfNotExists(NSString *path)
{
    if (!path.length)
        return;
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDirectory = NO;
    if ([fm fileExistsAtPath:path isDirectory:&isDirectory])
        return;
    [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:NULL];
}

/* Crane 0x6E08 + 0x6F40 --------------------------------------------------- */

void CRRequestAuthentication(NSString *reason, CRBiometricHandler handler)
{
    if (!handler)
        return;

    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                             error:&error]) {
        BOOL onMainThread = NSThread.isMainThread;
        CRBiometricHandler block = ^{
            if (onMainThread)
                dispatch_async(dispatch_get_main_queue(), handler);
            else
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), handler);
        };
        [context evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                localizedReason:reason
                          reply:^(BOOL success, NSError *evaluateError) {
            /* Upstream ignores `success == NO` entirely: nothing is invoked. */
            if (success)
                block();
        }];
    } else {
        /* Upstream calls the handler directly when biometrics are unavailable
         * rather than surfacing an error. Reproduced deliberately. */
        handler();
    }
}

/* Crane 0x6544 ------------------------------------------------------------ */

NSString *CRSafeGetBundleIdentifier(void)
{
    CFBundleRef mainBundle = CFBundleGetMainBundle();
    if (!mainBundle)
        return nil;
    return (__bridge NSString *)CFBundleGetIdentifier(mainBundle);
}

/* CraneSupport 0x647C ----------------------------------------------------- */

NSString *CRGetProcessName(void)
{
    char buf[1024];
    uint32_t size = sizeof(buf);
    extern int _NSGetExecutablePath(char *buf, uint32_t *bufsize);
    if (_NSGetExecutablePath(buf, &size) != 0)
        return nil;
    return @(buf).lastPathComponent;
}

/* CraneSupport 0x60C8 / CraneSB 0x1F850 ------------------------------------- */

NSString *CRGetInjectionPlatform(void)
{
    static NSString *platform;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        for (NSString *candidate in @[CR_INSERTER_TWEAK_INJECT,
                                      CR_INSERTER_SUBSTITUTE,
                                      CR_INSERTER_SUBSTRATE]) {
            if (CRIsDylibLoaded(candidate)) {
                platform = candidate;
                break;
            }
        }
    });
    return platform;
}