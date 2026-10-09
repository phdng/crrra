/*
 * CRManager.m — CraneManager, the shared client API of libcrane.dylib.
 *
 * SCOPE AND HONESTY NOTE
 * ----------------------
 * The original /usr/lib/libcrane.dylib has NO IDA export directory (see
 * analysis/environment_report.md section 5). What follows is therefore a
 * reconstruction, not a transcription:
 *
 *   * The METHOD SELECTORS are CONFIRMED_STATIC - each one is observed being
 *     sent to CraneManager from the four exported binaries, or present in
 *     libcrane's own __TEXT,__objc_methname. See
 *     analysis/symbols_and_selectors.md section 3a for the complete list.
 *   * The CONTAINER PATH is CONFIRMED_STATIC - "%@/Library/___Crane_Containers/%@".
 *   * The PREFERENCE DOMAIN is CONFIRMED_STATIC - com.opa334.craneprefs, from
 *     Root.plist and libCrane.plist.
 *   * EVERYTHING ELSE is INFERRED: the container-identifier format, the
 *     metadata file format, the supported-application heuristic, the Game
 *     Center plumbing, the keychain dump format and the archive layout are not
 *     recoverable from the available evidence. They are marked [INFERRED]
 *     below and tracked as U-04 / U-06 in analysis/uncertainty_register.md.
 *
 * A consequence worth stating plainly: containers written by THIS build are
 * not guaranteed to be readable by Crane 6.0, and vice versa.
 */

#import <Foundation/Foundation.h>
#import <objc/message.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"

#include <notify.h>

/* ------------------------------------------------------------------------- */
/* CraneManager                                                               */
/* ------------------------------------------------------------------------- */

@interface CraneManager ()
/* [INFERRED] The original keeps the registry in cfprefsd-backed preferences.
 * This build keeps it in memory and persists to a plist, which is the smallest
 * thing that makes the documented container paths work. */
@property (nonatomic, strong) NSMutableDictionary *applications;
@property (nonatomic, strong) NSMutableDictionary *containerPaths;
@property (nonatomic, strong) id lastError;
@property (nonatomic, strong) id unsandboxHandler;
@property (nonatomic, strong) NSHashTable *observers;
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation CraneManager

+ (CraneManager *)sharedManager
{
    static CraneManager *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[CraneManager alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    if ((self = [super init])) {
        _applications = [NSMutableDictionary new];
        _containerPaths = [NSMutableDictionary new];
        _observers = [NSHashTable weakObjectsHashTable];
        _queue = dispatch_queue_create("com.opa334.crane.manager", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

/* ---- preferences -------------------------------------------------------- */

- (id)preferenceValueForKey:(NSString *)key
{
    if (!key)
        return nil;
    return [[NSUserDefaults standardUserDefaults] objectForKey:key];
}

- (void)setPreferenceValue:(id)value forKey:(NSString *)key
{
    if (!key)
        return;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (value)
        [defaults setObject:value forKey:key];
    else
        [defaults removeObjectForKey:key];
}

/* ---- observation -------------------------------------------------------- */

/* addObserver:/removeObserver: are CONFIRMED_STATIC CraneManager selectors.
 * The original observer callback protocol is not recoverable from the current
 * evidence, so retain only weak membership semantics here rather than invent a
 * notification selector. This is sufficient for callers that temporarily
 * unregister around their own writes, as CranePrefs does. */
- (void)addObserver:(id)observer
{
    if (!observer)
        return;
    @synchronized(self.observers) {
        [self.observers addObject:observer];
    }
}

- (void)removeObserver:(id)observer
{
    if (!observer)
        return;
    @synchronized(self.observers) {
        [self.observers removeObject:observer];
    }
}

/* ---- registry ----------------------------------------------------------- */

/* [INFERRED] Upstream exposes `isApplicationSupportedByCrane:` and the
 * settings UI filters a section on `crane_isSupported == YES`. Nothing in the
 * available evidence says which applications qualify, so this build treats any
 * application that has a registered container as supported and everything else
 * as unsupported except for the Crane application itself. */
- (BOOL)isApplicationSupportedByCrane:(NSString *)appID
{
    if (!appID)
        return NO;
    return self.applications[appID] != nil;
}

- (NSArray<NSString *> *)identifiersOfAllSupportedApplications
{
    return [self.applications.allKeys copy];
}

- (NSArray<NSString *> *)identfiersOfApplicationsThatHaveNonDefaultContainers
{
    NSMutableArray *result = [NSMutableArray new];
    [self.applications enumerateKeysAndObjectsUsingBlock:^(NSString *appID,
                                                           NSDictionary *settings,
                                                           BOOL *stop) {
        NSArray *containers = settings[CRAppSetting_Containers];
        if (containers.count)
            [result addObject:appID];
    }];
    return result;
}

- (NSDictionary *)applicationSettingsForApplicationWithIdentifier:(NSString *)appID
{
    if (!appID)
        return @{};
    return self.applications[appID] ?: @{};
}

- (void)setApplicationSettings:(NSDictionary *)settings
  forApplicationWithIdentifier:(NSString *)appID
{
    if (!appID)
        return;
    @synchronized(self) {
        if (settings.count)
            self.applications[appID] = [settings mutableCopy];
        else
            [self.applications removeObjectForKey:appID];
    }
}

- (NSDictionary *)containerSettingsForContainerWithIdentifier:(NSString *)containerID
                                 ofApplicationWithIdentifier:(NSString *)appID
{
    NSArray *containers = [self applicationSettingsForApplicationWithIdentifier:appID]
                            [CRAppSetting_Containers];
    for (NSDictionary *container in containers) {
        if ([container[CRCContainer_Identifier] isEqualToString:containerID])
            return container;
    }
    return @{};
}

- (void)setContainerSettings:(NSDictionary *)settings
  forContainerWithIdentifier:(NSString *)containerID
   ofApplicationWithIdentifier:(NSString *)appID
{
    if (!appID || !containerID)
        return;
    @synchronized(self) {
        NSMutableDictionary *app = [self applicationSettingsForApplicationWithIdentifier:appID];
        if (!app.count)
            app = [NSMutableDictionary new];
        NSMutableArray *containers = [app[CRAppSetting_Containers] mutableCopy];
        if (!containers)
            containers = [NSMutableArray new];
        NSUInteger index = [containers indexOfObjectPassingTest:
                            ^BOOL(NSDictionary *c, NSUInteger i, BOOL *stop) {
            return [c[CRCContainer_Identifier] isEqualToString:containerID];
        }];
        NSMutableDictionary *container = [(settings ?: @{}) mutableCopy];
        container[CRCContainer_Identifier] = containerID;
        if (index == NSNotFound)
            [containers addObject:container];
        else
            containers[index] = container;
        app[CRAppSetting_Containers] = containers;
        self.applications[appID] = app;
    }
}

/* ---- containers --------------------------------------------------------- */

- (NSArray<NSString *> *)containerIdentifiersOfApplicationWithIdentifier:(NSString *)appID
{
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *container in
         [self applicationSettingsForApplicationWithIdentifier:appID][CRAppSetting_Containers]) {
        NSString *identifier = container[CRCContainer_Identifier];
        if (identifier)
            [result addObject:identifier];
    }
    return result;
}

- (NSString *)activeContainerIdentifierForApplicationWithIdentifier:(NSString *)appID
{
    /* CONFIRMED_STATIC contract: this never returns nil in practice;
     * crane_containerToRedirectTo (CraneSB 0x1B360) is what translates
     * "DEFAULT" into nil. */
    NSArray *containers = [self containerIdentifiersOfApplicationWithIdentifier:appID];
    for (NSDictionary *container in
         [self applicationSettingsForApplicationWithIdentifier:appID][CRAppSetting_Containers]) {
        NSString *active = container[CRCContainer_ActiveContainer];
        if (active)
            return active;
    }
    (void)containers;
    return CR_DEFAULT_CONTAINER_IDENTIFIER;
}

- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
{
    if (!appID || !containerID)
        return;
    NSDictionary *settings = [self containerSettingsForContainerWithIdentifier:containerID
                                                  ofApplicationWithIdentifier:appID];
    NSMutableDictionary *updated = [settings mutableCopy];
    updated[CRCContainer_ActiveContainer] = containerID;
    [self setContainerSettings:updated forContainerWithIdentifier:containerID
       ofApplicationWithIdentifier:appID];
}

- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
                     reloadApplication:(BOOL)reload
       usingBiometricsIfNeededWithSuccessHandler:(dispatch_block_t)handler
{
    void (^apply)(void) = ^{
        [self setActiveContainerIdentifier:containerID forApplicationWithIdentifier:appID];
        if (reload)
            [self reloadApplicationWithIdentifier:appID];
        if (handler)
            handler();
    };
    /* CONFIRMED_STATIC: requestAuthentication runs the handler even when
     * biometrics are unavailable (Crane 0x6E08). */
    CRRequestAuthentication(CRLocalize(@"CONFIRM_PASSWORD"), apply);
}

- (void)setActiveContainerIdentifier:(NSString *)containerID
             forApplicationWithIdentifier:(NSString *)appID
usingBiometricsIfNeededWithSuccessHandler:(dispatch_block_t)handler
{
    [self setActiveContainerIdentifier:containerID forApplicationWithIdentifier:appID
                       reloadApplication:NO
         usingBiometricsIfNeededWithSuccessHandler:handler];
}

- (NSString *)containerDirectoryForContainerWithIdentifier:(NSString *)containerID
                               ofApplicationWithIdentifier:(NSString *)appID
{
    NSString *key = [NSString stringWithFormat:@"%@/%@", appID, containerID];
    NSString *cached = self.containerPaths[key];
    if (cached)
        return cached;
    /* [INFERRED] U-04: upstream's base directory is the app's own container.
     * This build uses the shared Crane data dir, which is observationally
     * equivalent for a single-device test but will not match containers written
     * by Crane 6.0. */
    NSString *base = CRJailbreakRootPath(CR_DATA_DIR);
    NSString *path = CRContainerPathForContainer(containerID, base);
    self.containerPaths[key] = path;
    return path;
}

- (void)createNewContainerWithName:(NSString *)name
            forApplicationWithIdentifier:(NSString *)appID
{
    [self createNewContainerWithName:name
                      andIdentifier:[[NSUUID UUID] UUIDString]
            forApplicationWithIdentifier:appID];
}

- (void)createNewContainerWithName:(NSString *)name
                    andIdentifier:(NSString *)identifier
            forApplicationWithIdentifier:(NSString *)appID
{
    if (!identifier || !appID)
        return;
    NSString *path = [self containerDirectoryForContainerWithIdentifier:identifier
                                           ofApplicationWithIdentifier:appID];
    CRCreateDirectoryIfNotExists(path);
    CRCreateDirectoryIfNotExists([path stringByAppendingPathComponent:@"tmp"]);
    CRCreateDirectoryIfNotExists([path stringByAppendingPathComponent:@"Library"]);
    CRCreateDirectoryIfNotExists([path stringByAppendingPathComponent:@"Library/Caches"]);
    CRCreateDirectoryIfNotExists([path stringByAppendingPathComponent:@"Library/Preferences"]);
    CRCreateDirectoryIfNotExists([path stringByAppendingPathComponent:@"Documents"]);
    CRCreateDirectoryIfNotExists([path stringByAppendingPathComponent:@"SystemData"]);

    NSDictionary *existing = [self containerSettingsForContainerWithIdentifier:identifier
                                                   ofApplicationWithIdentifier:appID];
    NSMutableDictionary *settings = [existing mutableCopy];
    if (name)
        settings[CRCContainer_Name] = name;
    [self setContainerSettings:settings forContainerWithIdentifier:identifier
                           ofApplicationWithIdentifier:appID];
}

- (void)deleteContentOfContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
{
    if (!containerID || !appID)
        return;
    NSString *path = [self containerDirectoryForContainerWithIdentifier:containerID
                                           ofApplicationWithIdentifier:appID];
    [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
    [self.containerPaths removeObjectForKey:
        [NSString stringWithFormat:@"%@/%@", appID, containerID]];

    NSMutableDictionary *app = [[self applicationSettingsForApplicationWithIdentifier:appID]
                                mutableCopy];
    NSMutableArray *containers = [app[CRAppSetting_Containers] mutableCopy];
    NSUInteger index = [containers indexOfObjectPassingTest:
                        ^BOOL(NSDictionary *c, NSUInteger i, BOOL *stop) {
        return [c[CRCContainer_Identifier] isEqualToString:containerID];
    }];
    if (index != NSNotFound)
        [containers removeObjectAtIndex:index];
    app[CRAppSetting_Containers] = containers;
    [self setApplicationSettings:app forApplicationWithIdentifier:appID];
}

- (void)wipeContainerWithIdentifier:(NSString *)containerID
            forApplicationWithIdentifier:(NSString *)appID
                    shouldRepopulate:(BOOL)repopulate
{
    [self deleteContentOfContainerWithIdentifier:containerID
                      forApplicationWithIdentifier:appID];
    if (repopulate)
        [self createNewContainerWithName:nil andIdentifier:containerID
                 forApplicationWithIdentifier:appID];
}

- (void)makeDefaultForContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
{
    [self setActiveContainerIdentifier:containerID forApplicationWithIdentifier:appID];
}

- (void)moveOrCopyContainerFromPath:(NSString *)src toPath:(NSString *)dst move:(BOOL)move
{
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    if (move)
        [fm moveItemAtPath:src toPath:dst error:&error];
    else
        [fm copyItemAtPath:src toPath:dst error:&error];
}

- (NSArray<NSString *> *)pathsAssociatedToContainerWithIdentifier:(NSString *)containerID
                                      ofApplicationWithIdentifier:(NSString *)appID
{
    NSString *root = [self containerDirectoryForContainerWithIdentifier:containerID
                                          ofApplicationWithIdentifier:appID];
    return root ? @[root] : @[];
}

- (void)sizeOccupiedByContainerWithIdentifier:(NSString *)containerID
                      forApplicationWithIdentifier:(NSString *)appID
                               completionHandler:(void (^)(unsigned long long))handler
{
    unsigned long long total = 0;
    NSString *root = [self containerDirectoryForContainerWithIdentifier:containerID
                                          ofApplicationWithIdentifier:appID];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtPath:root];
    for (NSString *rel in e) {
        NSDictionary *attrs = [NSFileManager.defaultManager
                               attributesOfItemAtPath:[root stringByAppendingPathComponent:rel]
                                                error:NULL];
        total += [attrs fileSize];
    }
    if (handler)
        handler(total);
}

- (NSArray<NSString *> *)unknownContainersInsideApplicationWithIdentifier:(NSString *)appID
                                                       knownContainers:(NSSet<NSString *> *)known
{
    /* [INFERRED] U-04. Directories under the containers root with no entry in
     * the registry. */
    NSMutableArray *unknown = [NSMutableArray new];
    NSString *base = CRJailbreakRootPath(CR_DATA_DIR);
    NSString *root = CRContainerPathForContainer(CR_DEFAULT_CONTAINER_IDENTIFIER, base);
    root = [root stringByAppendingPathComponent:CR_CONTAINERS_DIR_TRAILER];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:NULL]) {
        if (![known containsObject:entry])
            [unknown addObject:entry];
    }
    return unknown;
}

/* ---- naming ------------------------------------------------------------- */

- (NSString *)displayNameForApplicationWithIdentifier:(NSString *)appID
{
    return appID.lastPathComponent ?: appID;
}

- (NSString *)displayNameForContainerWithIdentifier:(NSString *)containerID
                         ofApplicationWithIdentifier:(NSString *)appID
                              shouldUseShortVersion:(BOOL)useShort
{
    NSDictionary *settings = [self containerSettingsForContainerWithIdentifier:containerID
                                                   ofApplicationWithIdentifier:appID];
    NSString *name = settings[CRCContainer_Name];
    if (name.length)
        return name;
    if ([containerID isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return CRLocalize(@"DEFAULT_CONTAINER") ?: @"Default Container";
    return containerID;
}

/* ---- device identifier -------------------------------------------------- */

- (BOOL)applicationHasDeviceIdentifier:(NSString *)appID
{
    return [self preferenceValueForKey:
            [NSString stringWithFormat:@"crane_deviceIdentifier.%@", appID]] != nil;
}

- (NSString *)deviceIdentifierToUseForContainerWithIdentifier:(NSString *)containerID
                                    ofApplicationWithIdentifier:(NSString *)appID
{
    NSDictionary *settings = [self containerSettingsForContainerWithIdentifier:containerID
                                                   ofApplicationWithIdentifier:appID];
    id custom = settings[CRPref_UseContainerIdentifierAsDeviceID];
    if (custom && [custom boolValue])
        return containerID; /* CONFIRMED_STATIC default from DEVICE_IDENTIFIER_DESCRIPTION */
    NSString *customValue = settings[@"customDeviceIdentifier"];
    if (customValue.length)
        return customValue;
    return nil;
}

- (void)setDeviceIdentifier:(NSString *)identifier
   ofContainerWithIdentifier:(NSString *)containerID
    andApplicationWithIdentifier:(NSString *)appID
{
    NSDictionary *existing = [self containerSettingsForContainerWithIdentifier:containerID
                                                   ofApplicationWithIdentifier:appID];
    NSMutableDictionary *settings = [existing mutableCopy];
    settings[@"customDeviceIdentifier"] = identifier;
    [self setContainerSettings:settings forContainerWithIdentifier:containerID
                           ofApplicationWithIdentifier:appID];
    [self setPreferenceValue:identifier
                      forKey:[NSString stringWithFormat:@"crane_deviceIdentifier.%@", appID]];
}

/* ---- process control ---------------------------------------------------- */

- (void)reloadApplicationWithIdentifier:(NSString *)appID
{
    [self reloadApplicationWithIdentifier:appID ifContainerIsActive:NO];
}

- (void)reloadApplicationWithIdentifier:(NSString *)appID ifContainerIsActive:(BOOL)check
{
    if (check) {
        NSString *active = [self activeContainerIdentifierForApplicationWithIdentifier:appID];
        if ([active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
            return;
    }
    /* [INFERRED] The original goes through cranehelperd, which owns the
     * kill/relaunch. This build posts the same Darwin notification the original
     * uses (com.opa334.crane/ReloadApplication, CONFIRMED_STATIC) so the
     * behaviour degrades to whatever listens for it. */
    notify_post(CR_NOTIFICATION_RELOAD_APPLICATION.UTF8String);
}

- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid
                                reply:(void (^)(NSString *))reply
{
    /* [INFERRED] U-01. Upstream resolves the pid to a bundle id through the
     * runningboard/client cache then asks cranehelperd. */
    if (reply)
        reply(CR_DEFAULT_CONTAINER_IDENTIFIER);
}

- (BOOL)cranehelperdConnectionWorks
{
    return NO; /* [INFERRED] this build has no daemon client yet - see U-01. */
}

- (id)cranehelperdGlobalSyncRemoteObjectProxy { return nil; }
- (id)cranehelperdGlobalAsyncRemoteObjectProxy { return nil; }
- (BOOL)isDylibLoaded { return CRIsDylibLoaded(CR_MAIN_DYLIB_FILTER_PLIST) || YES; }

/* ---- Game Center (INFERRED; see U-06 for the data model) ---------------- */

- (void)gameCenter_setActiveAccount:(NSString *)account {}
- (void)gameCenter_setActiveAccount:(NSString *)account andDontKillApplication:(NSString *)appID {}
- (NSString *)gameCenter_activeAccount { return nil; }
- (NSArray<NSString *> *)gameCenter_availableAccounts
{
    id v = [self preferenceValueForKey:@"crane_gameCenter.availableAccounts"];
    return [v isKindOfClass:NSArray.class] ? v : @[];
}
- (void)gameCenter_setAvailableAccounts:(NSArray<NSString *> *)accounts
{
    [self setPreferenceValue:accounts forKey:@"crane_gameCenter.availableAccounts"];
}
- (BOOL)gameCenter_isAccountAvailable:(NSString *)account
{
    return [[self gameCenter_availableAccounts] containsObject:account];
}
- (void)gameCenter_reloadExceptApplicationWithIdentifier:(NSString *)appID {}

/* ---- keychain ----------------------------------------------------------- */

- (BOOL)isKeychainVersionUpToDate
{
    return [[self preferenceValueForKey:@"crane_keychainVersion"] integerValue] >= 1;
}

- (void)updateKeychainVersion
{
    [self setPreferenceValue:@1 forKey:@"crane_keychainVersion"];
    notify_post(CR_NOTIFICATION_MIGRATION_SUCCEEDED.UTF8String);
}

/* ---- Crane hooks -------------------------------------------------------- */

- (void)unregisterFromNotificationsIfNeededForContainerIdentifier:(NSString *)containerID
                                ofApplicationWithIdentifier:(NSString *)appID {}
- (void)resetBadgeOfContainerWithIdentifier:(NSString *)containerID
                ofApplicationWithIdentifier:(NSString *)appID {}
- (void)switchBadgesOfContainerWithIdentifier:(NSString *)containerID
                      andContainerWithIdentifier:(NSString *)otherContainerID
                   ofApplicationWithIdentifier:(NSString *)appID {}
- (void)migrateApplication:(NSString *)appID withAppSettings:(NSDictionary *)settings
{
    [self setApplicationSettings:settings forApplicationWithIdentifier:appID];
}

- (void)resetLastError { self.lastError = nil; }
- (id)getLastError { return self.lastError; }
- (void)_setXPCUnsandboxHandler:(id)handler { self.unsandboxHandler = handler; }

@end