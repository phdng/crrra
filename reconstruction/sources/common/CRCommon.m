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
#import "CRLocalization.h"
#import "CRXPCDiagnostics.h"
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
    /* Crane 0x6924 retries bundleWithPath: whenever its cached result is nil;
     * dispatch_once would permanently cache a failed first lookup. */
    if (!bundle) {
        NSString *path = CRJailbreakRootPath(CR_UI_BUNDLE_PATH);
        bundle = [NSBundle bundleWithPath:path];
        NSLog(@"Crane: localization bundle path=%@ available=%@", path,
              bundle ? @"YES" : @"NO");
    }
    return bundle;
}

NSString *CRLocalize(NSString *key)
{
    static NSDictionary *english;
    return CRLocalizedStringFromBundle(CRUIBundle(), key, &english);
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

    /* Original Crane 0x6E08 captures the calling thread before policy
     * evaluation, then reuses that result in the 0x6F40 reply block. */
    BOOL onMainThread = NSThread.isMainThread;
    LAContext *context = [[LAContext alloc] init];
    NSError *error = nil;

    if ([context canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                             error:&error]) {
        CRBiometricHandler block = ^{
            if (onMainThread)
                dispatch_async(dispatch_get_main_queue(), handler);
            else
                dispatch_async(dispatch_get_global_queue(0, 0), handler);
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
    static NSMutableDictionary<NSString *, id> *reports;
    static NSUInteger generation;
    static BOOL creationRetryScheduled;
    static dispatch_once_t lockOnce;
    dispatch_once(&lockOnce, ^{
        connectionLock = [NSObject new];
        reports = [NSMutableDictionary new];
    });

    @synchronized(connectionLock) {
        reports[component] = containerID.length ? [containerID copy] : NSNull.null;
        if (!connection) {
            xpc_connection_t created = CRCommonXPCConnectionCreateMachService(
                CR_HELPERD_MACH_SERVICE.UTF8String, NULL, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED);
            if (!created) {
                /* A temporary launchd/Mach-service failure must not leave
                 * constructor-only injection reports permanently unregistered. */
                if (!creationRetryScheduled) {
                    creationRetryScheduled = YES;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                            NSString *name;
                            id value;
                            @synchronized(connectionLock) {
                                creationRetryScheduled = NO;
                                if (connection)
                                    return;
                                name = reports.allKeys.firstObject;
                                value = name ? reports[name] : nil;
                            }
                            if (name)
                                CRReportRuntimeInjection(name,
                                    value == NSNull.null ? nil : value);
                        });
                }
                return;
            }
            connection = created;
            NSUInteger myGeneration = ++generation;
            xpc_connection_set_event_handler(created, ^(xpc_object_t event) {
                if (xpc_get_type(event) != XPC_TYPE_ERROR)
                    return;
                __block BOOL reconnect = NO;
                __block BOOL retire = NO;
                @synchronized(connectionLock) {
                    if (generation == myGeneration && connection == created) {
                        connection = NULL;
                        retire = YES;
                        /* Share the retry gate with initial creation failures. */
                        if (!creationRetryScheduled) {
                            creationRetryScheduled = YES;
                            reconnect = YES;
                        }
                    }
                }
                if (!retire)
                    return;
                NSLog(@"Crane: helper runtime_report error=%@",
                      CRHelperXPCEventError(event, @"runtime_report"));
                /* Retire the failed peer even when another retry is queued. */
                xpc_connection_cancel(created);
                if (!reconnect)
                    return;
                /* Re-register after helperd restarts. Generation checking
                 * prevents old connection errors from replacing a new peer. */
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                    dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        NSString *name;
                        id value;
                        @synchronized(connectionLock) {
                            creationRetryScheduled = NO;
                            if (generation != myGeneration || connection)
                                return;
                            name = reports.allKeys.firstObject;
                            value = name ? reports[name] : nil;
                        }
                        /* Opening a connection replays every cached claim;
                         * even a concurrent new report cannot skip older ones. */
                        if (name)
                            CRReportRuntimeInjection(name,
                                value == NSNull.null ? nil : value);
                    });
            });
            xpc_connection_resume(created);
            /* The new connection must receive every component's latest
             * claim, not merely the report that caused reconnection. */
            for (NSString *name in reports) {
                id value = reports[name];
                xpc_object_t replay = xpc_dictionary_create(NULL, NULL, 0);
                if (!replay)
                    continue;
                xpc_dictionary_set_string(replay, "operation", "runtime_report");
                xpc_dictionary_set_string(replay, "protocol", CR_HELPERD_PING_PROTOCOL_V1);
                xpc_dictionary_set_string(replay, "component", name.UTF8String);
                if (value != NSNull.null)
                    xpc_dictionary_set_string(replay, "container_id", [(NSString *)value UTF8String]);
                xpc_connection_send_message(created, replay);
            }
            return;
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
