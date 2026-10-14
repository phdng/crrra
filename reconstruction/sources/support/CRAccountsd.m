/*
 * CRAccountsd.m — CraneSupport accountsd / per-container system accounts.
 *
 * Transcribed from CraneSupport:
 *   separateSystemAccountsEnabledForBundleID 0x6E88
 *   initNoStartUsingiCloudHooks              0x7024
 *   initAccountsd                            0x7200
 *   bundle-load observer                     0x76B8
 *   crane_containerToRedirectToForClient:    0x7784
 *   modern init/apply redirection            0x7AE8 / 0x7CB8
 *   legacy shared coordinator                0x8104
 *   legacy init/apply redirection            0x8204 / 0x8324
 */

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreData/CoreData.h>
#import <objc/runtime.h>

#import "CRManager.h"
#import "CRPreferences.h"
#import "CRCommon.h"

extern void *MSGetImageByName(const char *name);
extern void *MSFindSymbol(void *image, const char *name);

@interface ClientContainerCache : NSObject
+ (instancetype)sharedInstance;
- (NSString *)activeContainerIdentifierForPid:(pid_t)pid;
@end

@interface NSObject (CraneAccountsdRuntime)
- (NSString *)name;
- (NSString *)bundleID;
- (NSNumber *)pid;

- (id)databaseConnection;
- (id)delegate;
- (NSURL *)databaseURL;
- (NSString *)path;

- (NSString *)crane_activeContainer;
- (void)setCrane_activeContainer:(NSString *)identifier;
- (NSMutableDictionary *)crane_databasesByContainerIdentifiers;
- (void)setCrane_databasesByContainerIdentifiers:(NSMutableDictionary *)dictionary;
- (NSMutableDictionary *)crane_storeCoordinatorsByContainerIdentifiers;
- (void)setCrane_storeCoordinatorsByContainerIdentifiers:(NSMutableDictionary *)dictionary;
- (NSString *)crane_containerToRedirectToForClient:(id)client;
- (BOOL)crane_applyRedirectionForContainerWithIdentifier:(NSString *)identifier;

- (void)_setupManagedObjectContextWithPersistentStoreCoodinator:(id)coordinator;
- (instancetype)initWithDatabaseConnection:(id)connection;
- (instancetype)initWithPath:(NSString *)path;
- (void)updateDefaultContentIfNecessary:(BOOL)force;
@end

/* ------------------------------------------------------------------------- */
/* Associated state added to ACDAccountStore                                 */
/* ------------------------------------------------------------------------- */

static id CraneAccountsdActiveContainer(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self, (const void *)&CraneAccountsdActiveContainer);
}

static void CraneAccountsdSetActiveContainer(id self, SEL _cmd, id value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             (const void *)&CraneAccountsdActiveContainer,
                             value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id CraneAccountsdStoreCoordinators(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self, (const void *)&CraneAccountsdStoreCoordinators);
}

static void CraneAccountsdSetStoreCoordinators(id self, SEL _cmd, id value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             (const void *)&CraneAccountsdStoreCoordinators,
                             value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id CraneAccountsdDatabases(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self, (const void *)&CraneAccountsdDatabases);
}

static void CraneAccountsdSetDatabases(id self, SEL _cmd, id value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             (const void *)&CraneAccountsdDatabases,
                             value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static NSString *CraneAccountsdNormalizedContainerID(NSString *identifier)
{
    return identifier ?: CR_DEFAULT_CONTAINER_IDENTIFIER;
}

static BOOL CraneAccountsdSeparateSystemAccountsEnabled(NSString *bundleIdentifier)
{
    if (!bundleIdentifier)
        return NO;

    NSDictionary *settings =
        [[CraneManager sharedManager]
            applicationSettingsForApplicationWithIdentifier:bundleIdentifier];
    return [settings[CRAppSetting_SeparateSystemAccountsEnabled] boolValue];
}

/* 0x7784. */
static id CraneAccountsdContainerForClient(id self, SEL _cmd, id client)
{
    (void)self;
    (void)_cmd;

    NSString *name = [client name];
    BOOL isStoreDaemon =
        [name isEqualToString:@"appstored"] ||
        [name isEqualToString:@"itunesstored"] ||
        [name isEqualToString:@"StoreKitUIServic"];
    BOOL isItunesCloud = [name isEqualToString:@"itunescloudd"];
    BOOL isGamed = [name isEqualToString:@"gamed"];

    NSString *bundleIdentifier = [client bundleID];
    if (isStoreDaemon)
        bundleIdentifier = @"com.apple.AppStore";
    else if (isItunesCloud)
        bundleIdentifier = @"com.apple.Music";

    if (!isGamed &&
        !CraneAccountsdSeparateSystemAccountsEnabled(bundleIdentifier)) {
        return nil;
    }

    CraneManager *manager = [CraneManager sharedManager];

    if (isGamed) {
        SEL enabledSelector =
            NSSelectorFromString(@"gameCenter_enabledApplicationIdentifiers");
        if (![manager respondsToSelector:enabledSelector])
            return nil;

        NSArray *enabled = [manager gameCenter_enabledApplicationIdentifiers];
        if (enabled.count == 0)
            return nil;
        return [manager gameCenter_activeAccount];
    }

    if (isStoreDaemon)
        return [manager
            activeContainerIdentifierForApplicationWithIdentifier:@"com.apple.AppStore"];

    if (isItunesCloud)
        return [manager
            activeContainerIdentifierForApplicationWithIdentifier:@"com.apple.Music"];

    pid_t pid = [[client pid] intValue];
    return [[ClientContainerCache sharedInstance]
        activeContainerIdentifierForPid:pid];
}

/* ------------------------------------------------------------------------- */
/* Start-Using-iCloud follow-up suppression                                  */
/* ------------------------------------------------------------------------- */

static IMP gOrigModernICloudFollowUp;
static IMP gOrigLegacyICloudFollowUp;

static void CraneAccountsdModernICloudFollowUp(id self,
                                               SEL _cmd,
                                               id accountStore,
                                               id account,
                                               id oldAccount)
{
    /*
     * 0x70A0: when the account store is currently pointed at a Crane
     * container, suppress the follow-up entirely.
     */
    if ([accountStore crane_activeContainer])
        return;

    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gOrigModernICloudFollowUp;
    original(self, _cmd, accountStore, account, oldAccount);
}

static void CraneAccountsdLegacyICloudFollowUp(id self,
                                               SEL _cmd,
                                               NSString *identifier,
                                               id userInfo,
                                               id completion)
{
    if ([identifier
            isEqualToString:@"com.apple.AAFollowUpIdentifier.StartUsing"]) {
        return;
    }

    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))gOrigLegacyICloudFollowUp;
    original(self, _cmd, identifier, userInfo, completion);
}

static void CraneAccountsdInstallICloudFollowUpHooks(void)
{
    if (kCFCoreFoundationVersionNumber >= 1740.0) {
        Class cls =
            NSClassFromString(@"AAAccountNotificationFollowUpController");
        if (!cls || gOrigModernICloudFollowUp)
            return;

        MSHookMessageEx(
            cls,
            NSSelectorFromString(
                @"_updateStartUsingiCloudFollowupForAccountStore:account:oldAccount:"),
            (IMP)CraneAccountsdModernICloudFollowUp,
            &gOrigModernICloudFollowUp);
    } else {
        Class cls = NSClassFromString(@"AAFollowUpController");
        if (!cls || gOrigLegacyICloudFollowUp)
            return;

        MSHookMessageEx(
            cls,
            NSSelectorFromString(@"postFollowUpWithIdentifier:userInfo:completion:"),
            (IMP)CraneAccountsdLegacyICloudFollowUp,
            &gOrigLegacyICloudFollowUp);
    }
}

static void CraneAccountsdBundleDidLoad(CFNotificationCenterRef center,
                                        void *observer,
                                        CFStringRef name,
                                        const void *object,
                                        CFDictionaryRef userInfo)
{
    (void)center;
    (void)observer;
    (void)name;
    (void)userInfo;

    NSBundle *bundle = (__bridge NSBundle *)object;
    if (kCFCoreFoundationVersionNumber >= 1740.0) {
        if ([bundle.bundleIdentifier
                isEqualToString:@"com.apple.AAAccountNotificationPlugin"]) {
            CraneAccountsdInstallICloudFollowUpHooks();
        }
    } else if (NSClassFromString(@"AAFollowUpController")) {
        CraneAccountsdInstallICloudFollowUpHooks();
    }
}

/* The original 0x7CB8/0x8324 creates <container>.sqlite files without
 * validating component names or the result of SQLite attachment. On a
 * reconstruction with an incomplete manager/transport that is dangerous:
 * refuse traversal/symlinks and retain the previous store if opening fails.
 * This is an intentional defensive deviation from native control flow. */
static BOOL CraneAccountsdSafeStoreIdentifier(NSString *identifier)
{
    if (![identifier isKindOfClass:NSString.class] ||
        !identifier.length || identifier.length > 128 ||
        [identifier isEqualToString:@"."] ||
        [identifier isEqualToString:@".."])
        return NO;
    static NSCharacterSet *unsafe;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"];
        unsafe = [allowed invertedSet];
    });
    return [identifier rangeOfCharacterFromSet:unsafe].location == NSNotFound;
}

static BOOL CraneAccountsdSafeStoreDirectory(NSString *path)
{
    if (!path.length)
        return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if ([fm destinationOfSymbolicLinkAtPath:path error:NULL])
        return NO;
    BOOL directory = NO;
    if (![fm fileExistsAtPath:path isDirectory:&directory]) {
        /* Retain native 0x6BE0 ownership/permissions on first creation. */
        CRCreateDirectoryIfNotExists(path);
        if (![fm fileExistsAtPath:path isDirectory:&directory])
            return NO;
    }
    return directory && ![fm destinationOfSymbolicLinkAtPath:path error:NULL];
}

static BOOL CraneAccountsdSafeStorePath(NSString *path)
{
    if (!path.length)
        return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *suffix in @[@"", @"-wal", @"-shm"]) {
        NSString *candidate = [path stringByAppendingString:suffix];
        if ([fm destinationOfSymbolicLinkAtPath:candidate error:NULL])
            return NO;
        BOOL isDirectory = NO;
        if ([fm fileExistsAtPath:candidate isDirectory:&isDirectory] &&
            isDirectory)
            return NO;
    }
    return YES;
}

/* ------------------------------------------------------------------------- */
/* Modern (CF >= 1665.15) coordinator-per-container path                     */
/* ------------------------------------------------------------------------- */

typedef id (*CraneACDManagedObjectModelFn)(void);
static CraneACDManagedObjectModelFn gACDManagedObjectModel;
static IMP gOrigModernAccountStoreInit;
static NSURL *gModernAccountsBaseURL;

static BOOL CraneAccountsdApplyModernRedirection(id self,
                                                 SEL _cmd,
                                                 NSString *identifier)
{
    (void)_cmd;

    id databaseConnection = [self databaseConnection];
    NSString *current =
        CraneAccountsdNormalizedContainerID([self crane_activeContainer]);
    NSString *requested =
        CraneAccountsdNormalizedContainerID(identifier);

    if (!databaseConnection ||
        !CraneAccountsdSafeStoreIdentifier(requested) ||
        !CraneAccountsdSafeStoreIdentifier(current))
        return NO;
    if ([current isEqualToString:requested])
        return NO;

    id existingCoordinator =
        [databaseConnection valueForKey:@"_persistentStoreCoordinator"];
    if (existingCoordinator) {
        NSMutableDictionary *cache =
            [self crane_storeCoordinatorsByContainerIdentifiers];
        cache[current] = existingCoordinator;
    }

    NSMutableDictionary *cache =
        [self crane_storeCoordinatorsByContainerIdentifiers];
    NSPersistentStoreCoordinator *coordinator = cache[requested];
    /* Never reuse a failed/empty coordinator from an earlier attempt. */
    if (coordinator && coordinator.persistentStores.count == 0)
        return NO;

    if (!coordinator) {
        NSManagedObjectModel *model =
            gACDManagedObjectModel ? gACDManagedObjectModel() : nil;
        if (!model)
            return NO;

        coordinator =
            [[NSPersistentStoreCoordinator alloc]
                initWithManagedObjectModel:model];

        id delegate = [databaseConnection delegate];
        NSDictionary *storeOptions =
            [delegate valueForKey:@"_storeOptions"];

        if (!gModernAccountsBaseURL) {
            NSURL *databaseURL = [delegate databaseURL];
            if (![databaseURL isKindOfClass:NSURL.class] ||
                ![databaseURL isFileURL])
                return NO;
            NSURL *candidate =
                [[databaseURL URLByDeletingLastPathComponent]
                    URLByAppendingPathComponent:@"Crane"];
            if (!CraneAccountsdSafeStoreDirectory(candidate.path))
                return NO;
            gModernAccountsBaseURL = candidate;
        }
        if (!CraneAccountsdSafeStoreDirectory(gModernAccountsBaseURL.path))
            return NO;

        NSString *filename =
            [NSString stringWithFormat:@"%@.sqlite", requested];
        NSURL *storeURL =
            [gModernAccountsBaseURL URLByAppendingPathComponent:filename];
        if (!CraneAccountsdSafeStorePath(storeURL.path))
            return NO;

        NSError *storeError = nil;
        NSPersistentStore *opened =
            [coordinator addPersistentStoreWithType:NSSQLiteStoreType
                                      configuration:nil
                                                URL:storeURL
                                            options:storeOptions
                                              error:&storeError];
        if (!opened) {
            NSLog(@"CraneSupport: accountsd refused invalid SQLite store %@: %@",
                  storeURL.path, storeError);
            return NO; /* Never install an unattached coordinator. */
        }
    }

    [databaseConnection
        setValue:coordinator
          forKey:@"_persistentStoreCoordinator"];
    [databaseConnection
        _setupManagedObjectContextWithPersistentStoreCoodinator:coordinator];

    Class initializerClass = NSClassFromString(@"ACDDatabaseInitializer");
    id initializer =
        initializerClass
            ? [[initializerClass alloc]
                initWithDatabaseConnection:databaseConnection]
            : nil;
    [initializer updateDefaultContentIfNecessary:NO];

    [self setCrane_activeContainer:identifier];
    return YES;
}

static id CraneAccountsdModernInit(id self,
                                   SEL _cmd,
                                   id client,
                                   id databaseConnection)
{
    [self setCrane_activeContainer:nil];
    [self setCrane_storeCoordinatorsByContainerIdentifiers:
        [NSMutableDictionary new]];

    /*
     * 0x7AE8 only enters redirect mode when client + pid + connection +
     * ACDManagedObjectModel are all present.
     */
    if (!client ||
        ![client pid] ||
        [[client pid] intValue] == 0 ||
        !databaseConnection ||
        !gACDManagedObjectModel) {
        id (*original)(id, SEL, id, id) =
            (id (*)(id, SEL, id, id))gOrigModernAccountStoreInit;
        return original(self, _cmd, client, databaseConnection);
    }

    NSString *container =
        [self crane_containerToRedirectToForClient:client];

    id (*original)(id, SEL, id, id) =
        (id (*)(id, SEL, id, id))gOrigModernAccountStoreInit;
    id result = original(self, _cmd, client, databaseConnection);
    [result crane_applyRedirectionForContainerWithIdentifier:container];
    return result;
}

/* ------------------------------------------------------------------------- */
/* Legacy (< CF 1665.15) database-per-container path                         */
/* ------------------------------------------------------------------------- */

static IMP gOrigLegacyAccountStoreInit;
static IMP gOrigSharedPersistentCoordinator;
static NSMutableDictionary *gLegacySharedCoordinators;
static NSString *gLegacyAccountsBasePath;
static dispatch_once_t *gOriginalPersistentCoordinatorOnceToken;
static CFTypeRef *gOriginalPersistentStoreCoordinator;

static id CraneAccountsdSharedPersistentCoordinator(id self,
                                                    SEL _cmd,
                                                    NSString *storePath)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLegacySharedCoordinators = [NSMutableDictionary new];
    });

    id coordinator = gLegacySharedCoordinators[storePath];
    if (coordinator)
        return coordinator;

    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gOrigSharedPersistentCoordinator;
    coordinator = original(self, _cmd, storePath);

    /*
     * 0x8104 deliberately resets AccountsDaemon's global once token and
     * coordinator after every first lookup so each redirected sqlite path can
     * get its own coordinator.
     */
    if (gOriginalPersistentCoordinatorOnceToken)
        *gOriginalPersistentCoordinatorOnceToken = 0;
    if (gOriginalPersistentStoreCoordinator &&
        *gOriginalPersistentStoreCoordinator) {
        CFRelease(*gOriginalPersistentStoreCoordinator);
        *gOriginalPersistentStoreCoordinator = NULL;
    }

    if (coordinator)
        gLegacySharedCoordinators[storePath] = coordinator;
    return coordinator;
}

static BOOL CraneAccountsdApplyLegacyRedirection(id self,
                                                 SEL _cmd,
                                                 NSString *identifier)
{
    (void)_cmd;

    id database = [self valueForKey:@"_database"];
    if (!database)
        return NO;

    NSString *current =
        CraneAccountsdNormalizedContainerID([self crane_activeContainer]);
    NSString *requested =
        CraneAccountsdNormalizedContainerID(identifier);
    if (!CraneAccountsdSafeStoreIdentifier(current) ||
        !CraneAccountsdSafeStoreIdentifier(requested))
        return NO;
    if ([current isEqualToString:requested])
        return NO;

    if (!gLegacyAccountsBasePath) {
        NSString *databasePath = [database path];
        if (![databasePath isKindOfClass:NSString.class] || !databasePath.length)
            return NO;
        gLegacyAccountsBasePath =
            [[databasePath stringByDeletingLastPathComponent]
                stringByAppendingPathComponent:@"Crane"];
    }
    if (!CraneAccountsdSafeStoreDirectory(gLegacyAccountsBasePath))
        return NO;

    NSMutableDictionary *cache =
        [self crane_databasesByContainerIdentifiers];
    cache[current] = database;

    id redirectedDatabase = cache[requested];
    if (!redirectedDatabase) {
        NSString *filename =
            [NSString stringWithFormat:@"%@.sqlite", requested];
        NSString *path =
            [gLegacyAccountsBasePath stringByAppendingPathComponent:filename];
        if (!CraneAccountsdSafeStorePath(path))
            return NO;

        Class databaseClass = NSClassFromString(@"ACDDatabase");
        redirectedDatabase =
            databaseClass
                ? [[databaseClass alloc] initWithPath:path]
                : nil;
        if (redirectedDatabase)
            cache[requested] = redirectedDatabase;
    }

    if (!redirectedDatabase)
        return NO;

    [self setValue:redirectedDatabase forKey:@"_database"];
    [self setCrane_activeContainer:identifier];
    return YES;
}

static id CraneAccountsdLegacyInit(id self,
                                   SEL _cmd,
                                   id client)
{
    [self setCrane_activeContainer:nil];
    [self setCrane_databasesByContainerIdentifiers:
        [NSMutableDictionary new]];

    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gOrigLegacyAccountStoreInit;

    if (!client)
        return original(self, _cmd, client);

    NSString *container =
        [self crane_containerToRedirectToForClient:client];
    id result = original(self, _cmd, client);
    [result crane_applyRedirectionForContainerWithIdentifier:container];
    return result;
}

/* ------------------------------------------------------------------------- */
/* Hook installation                                                         */
/* ------------------------------------------------------------------------- */

void CRInitAccountsd(void)
{
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        NULL,
        CraneAccountsdBundleDidLoad,
        (__bridge CFStringRef)NSBundleDidLoadNotification,
        NULL,
        CFNotificationSuspensionBehaviorCoalesce);

    void *accountsDaemonImage =
        MSGetImageByName(
            "/System/Library/PrivateFrameworks/AccountsDaemon.framework/AccountsDaemon");

    Class accountStoreClass = NSClassFromString(@"ACDAccountStore");
    if (!accountStoreClass)
        return;

    objc_property_attribute_t stringProperty[] = {
        { "T", "@\"NSString\"" },
        { "&", "" },
        { "N", "" },
    };
    class_addProperty(accountStoreClass,
                      "crane_activeContainer",
                      stringProperty,
                      3);
    class_addMethod(accountStoreClass,
                    NSSelectorFromString(@"crane_activeContainer"),
                    (IMP)CraneAccountsdActiveContainer,
                    "@@:");
    class_addMethod(accountStoreClass,
                    NSSelectorFromString(@"setCrane_activeContainer:"),
                    (IMP)CraneAccountsdSetActiveContainer,
                    "v@:@");
    class_addMethod(accountStoreClass,
                    NSSelectorFromString(@"crane_containerToRedirectToForClient:"),
                    (IMP)CraneAccountsdContainerForClient,
                    "@@:@");

    if (kCFCoreFoundationVersionNumber >= 1665.15) {
        gACDManagedObjectModel =
            accountsDaemonImage
                ? (CraneACDManagedObjectModelFn)
                    MSFindSymbol(accountsDaemonImage,
                                 "__ACDManagedObjectModel")
                : NULL;

        objc_property_attribute_t dictionaryProperty[] = {
            { "T", "@\"NSMutableDictionary\"" },
            { "&", "" },
            { "N", "" },
        };
        class_addProperty(accountStoreClass,
                          "crane_storeCoordinatorsByContainerIdentifiers",
                          dictionaryProperty,
                          3);
        class_addMethod(
            accountStoreClass,
            NSSelectorFromString(
                @"crane_storeCoordinatorsByContainerIdentifiers"),
            (IMP)CraneAccountsdStoreCoordinators,
            "@@:");
        class_addMethod(
            accountStoreClass,
            NSSelectorFromString(
                @"setCrane_storeCoordinatorsByContainerIdentifiers:"),
            (IMP)CraneAccountsdSetStoreCoordinators,
            "v@:@");

        MSHookMessageEx(
            accountStoreClass,
            NSSelectorFromString(@"initWithClient:databaseConnection:"),
            (IMP)CraneAccountsdModernInit,
            &gOrigModernAccountStoreInit);
        class_addMethod(
            accountStoreClass,
            NSSelectorFromString(
                @"crane_applyRedirectionForContainerWithIdentifier:"),
            (IMP)CraneAccountsdApplyModernRedirection,
            "B@:@");
    } else {
        if (accountsDaemonImage) {
            gOriginalPersistentCoordinatorOnceToken =
                (dispatch_once_t *)
                    MSFindSymbol(
                        accountsDaemonImage,
                        "___persistentStoreCoordinatorOnceToken");
            gOriginalPersistentStoreCoordinator =
                (CFTypeRef *)
                    MSFindSymbol(
                        accountsDaemonImage,
                        "___persistentStoreCoordinator");
        }

        Class databaseClass = NSClassFromString(@"ACDDatabase");
        if (databaseClass) {
            MSHookMessageEx(
                object_getClass(databaseClass),
                NSSelectorFromString(
                    @"_sharedPersistentCoordinatorForStoreAtPath:"),
                (IMP)CraneAccountsdSharedPersistentCoordinator,
                &gOrigSharedPersistentCoordinator);
        }

        objc_property_attribute_t dictionaryProperty[] = {
            { "T", "@\"NSMutableDictionary\"" },
            { "&", "" },
            { "N", "" },
        };
        class_addProperty(accountStoreClass,
                          "crane_databasesByContainerIdentifiers",
                          dictionaryProperty,
                          3);
        class_addMethod(
            accountStoreClass,
            NSSelectorFromString(@"crane_databasesByContainerIdentifiers"),
            (IMP)CraneAccountsdDatabases,
            "@@:");
        class_addMethod(
            accountStoreClass,
            NSSelectorFromString(
                @"setCrane_databasesByContainerIdentifiers:"),
            (IMP)CraneAccountsdSetDatabases,
            "v@:@");

        MSHookMessageEx(
            accountStoreClass,
            NSSelectorFromString(@"initWithClient:"),
            (IMP)CraneAccountsdLegacyInit,
            &gOrigLegacyAccountStoreInit);
        class_addMethod(
            accountStoreClass,
            NSSelectorFromString(
                @"crane_applyRedirectionForContainerWithIdentifier:"),
            (IMP)CraneAccountsdApplyLegacyRedirection,
            "B@:@");
    }
}
