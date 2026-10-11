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
#import <xpc/xpc.h>
#import <unistd.h>
#import <mach-o/dyld.h>

/* iOS SDKs mark the Mach-service constructor unavailable to app targets even
 * though the symbol is present and used by the recovered Crane binaries. */
extern xpc_connection_t CRCommonXPCConnectionCreateMachService(
    const char *name, dispatch_queue_t targetq, uint64_t flags)
    __asm("_xpc_connection_create_mach_service");

/* Crane 0x6924 ------------------------------------------------------------ */

static NSBundle *CRUIBundle(void)
{
    static NSBundle *bundle;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        bundle = [NSBundle bundleWithPath:CRJailbreakRootPath(CR_UI_BUNDLE_PATH)];
        /* Roothide may expose the UI bundle only beneath its physical jbroot. */
        if (!bundle || ![bundle pathForResource:@"Localizable" ofType:@"strings" inDirectory:@"en.lproj"]) {
            Class prefsClass = NSClassFromString(@"CRPRootListController");
            NSString *prefsPath = prefsClass ? [NSBundle bundleForClass:prefsClass].bundlePath : nil;
            NSRange marker = [prefsPath rangeOfString:@"/Library/PreferenceBundles/"];
            if (prefsPath.length && marker.location != NSNotFound) {
                NSString *root = [prefsPath substringToIndex:marker.location];
                NSBundle *candidate = [NSBundle bundleWithPath:
                    [root stringByAppendingString:CR_UI_BUNDLE_PATH]];
                if (candidate)
                    bundle = candidate;
            }
        }
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
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:path])
        return;

    NSDictionary *attributes = @{
        NSFilePosixPermissions: @0755,
        NSFileOwnerAccountID: @501,
        NSFileGroupOwnerAccountID: @501,
    };
    [fm createDirectoryAtPath:path
  withIntermediateDirectories:YES
                   attributes:attributes
                        error:NULL];
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
    /* CraneSupport 0x60C8 and CraneSB 0x1F850 compare each loaded image
     * against inserter paths in this order. The original walks every image;
     * a later match replaces the earlier cached platform. */
    static NSString *platform;
    if (platform)
        return platform;

    NSArray<NSArray<NSString *> *> *candidates = @[
        @[CR_INSERTER_SUBSTITUTE, @"Substitute"],
        @[CR_INSERTER_TWEAK_INJECT, @"libhooker"],
        @[CR_INSERTER_SUBSTRATE, @"Substrate"]
    ];
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *image = _dyld_get_image_name(i);
        if (!image)
            continue;
        NSString *imagePath = [NSString stringWithUTF8String:image];
        for (NSArray<NSString *> *candidate in candidates) {
            if ([imagePath isEqualToString:CRJailbreakRootPath(candidate[0])]) {
                platform = candidate[1];
                break;
            }
        }
    }
    return platform;
}

/* Reconstruction-only runtime attestation -------------------------------- */

void CRReportRuntimeInjection(NSString *component, NSString *containerID)
{
    if (!component.length)
        return;

    /* One long-lived peer per loaded CRCommon image. The daemon binds the
     * registration to this peer's kernel-provided PID and drops it when the
     * connection dies, avoiding stale PID/container claims after process exit. */
    static xpc_connection_t connection;
    static NSObject *connectionLock;
    static NSString *lastComponent;
    static NSString *lastContainerID;
    static NSUInteger generation;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{ connectionLock = [NSObject new]; });

    @synchronized(connectionLock) {
        lastComponent = [component copy];
        lastContainerID = [containerID copy];
        if (!connection) {
            xpc_connection_t created = CRCommonXPCConnectionCreateMachService(
                CR_HELPERD_MACH_SERVICE.UTF8String, NULL, 0);
            if (!created)
                return;
            connection = created;
            NSUInteger myGeneration = ++generation;
            xpc_connection_set_event_handler(created, ^(xpc_object_t event) {
                if (xpc_get_type(event) != XPC_TYPE_ERROR)
                    return;
                __block BOOL reconnect = NO;
                @synchronized(connectionLock) {
                    if (generation == myGeneration) {
                        connection = NULL;
                        reconnect = YES;
                    }
                }
                if (!reconnect)
                    return;
                /* Re-register after helperd restarts. Generation checking
                 * prevents old connection errors from replacing a new peer. */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        NSString *retryComponent;
                        NSString *retryContainer;
                        @synchronized(connectionLock) {
                            if (generation != myGeneration || connection)
                                return;
                            retryComponent = lastComponent;
                            retryContainer = lastContainerID;
                        }
                        CRReportRuntimeInjection(retryComponent, retryContainer);
                    });
            });
            xpc_connection_resume(created);
        }

        xpc_object_t report = xpc_dictionary_create(NULL, NULL, 0);
        if (!report)
            return;
        xpc_dictionary_set_string(report, "operation", "runtime_report");
        xpc_dictionary_set_string(report, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
        xpc_dictionary_set_string(report, "component", component.UTF8String);
        if (containerID.length)
            xpc_dictionary_set_string(report, "container_id", containerID.UTF8String);
        xpc_connection_send_message(connection, report);
    }
}
