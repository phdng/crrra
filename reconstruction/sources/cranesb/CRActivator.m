/*
 * CraneActivatorManager — Activator integration recovered from CraneSB.dylib.
 *
 * Core listener/event registration and container switching are transcribed from
 * 0x1C4D4..0x1E284. Activator and LaunchServices remain runtime-only
 * dependencies: the original dlopen()s libactivator and talks to the private
 * classes through Objective-C messages.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRCommon.h"

/* Runtime-only surfaces. Declaring the selectors avoids a hard framework or
 * libactivator link while preserving the recovered objc_msgSend contract. */
@interface NSObject (CraneActivatorRuntime)
+ (id)sharedInstance;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
+ (id)defaultWorkspace;
- (BOOL)isInstalled;
- (void)addObserver:(id)observer;
- (void)removeObserver:(id)observer;

- (void)registerListener:(id)listener forName:(NSString *)name;
- (void)unregisterListenerWithName:(NSString *)name;
- (void)registerEventDataSource:(id)dataSource forEventName:(NSString *)name;
- (void)unregisterEventDataSourceWithEventName:(NSString *)name;

- (NSDictionary *)userInfo;
- (void)setUserInfo:(NSDictionary *)userInfo;
@end

static id gCRActivator;
static void *gCRActivatorHandle;

static BOOL CRActivatorApplicationIsInstalled(NSString *applicationIdentifier)
{
    Class proxyClass = NSClassFromString(@"LSApplicationProxy");
    if (!proxyClass)
        return NO;
    id proxy = [(id)proxyClass applicationProxyForIdentifier:applicationIdentifier];
    return [proxy isInstalled];
}

static id CRActivatorWorkspace(void)
{
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    return workspaceClass ? [(id)workspaceClass defaultWorkspace] : nil;
}

@interface CraneActivatorManager : NSObject
@property (nonatomic, strong) NSMutableArray<NSString *> *setActiveContainerListenersCache;
@property (nonatomic, strong) NSMutableArray<NSString *> *changedToContainerEventCache;
+ (instancetype)sharedInstance;
+ (void)startIfPossible;
@end

@implementation CraneActivatorManager

+ (instancetype)sharedInstance
{
    static CraneActivatorManager *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}

+ (void)startIfPossible
{
    NSString *activatorPath = CRJailbreakRootPath(CR_ACTIVATOR_LIB);
    gCRActivatorHandle = dlopen(activatorPath.fileSystemRepresentation, RTLD_LAZY);
    if (!gCRActivatorHandle) {
        gCRActivator = nil;
        return;
    }

    Class activatorClass = NSClassFromString(@"LAActivator");
    gCRActivator = activatorClass ? [(id)activatorClass sharedInstance] : nil;
    if (gCRActivator)
        (void)[self sharedInstance];
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _setActiveContainerListenersCache = [NSMutableArray new];
        _changedToContainerEventCache = [NSMutableArray new];
        [self updateAvailableListeners];
        [self updateProvidedEvents];
        [[CraneManager sharedManager] addObserver:self];
        [CRActivatorWorkspace() addObserver:self];
    }
    return self;
}

- (void)dealloc
{
    [self unregisterAllListeners];
    [self unregisterAllEvents];
    [[CraneManager sharedManager] removeObserver:self];
    [CRActivatorWorkspace() removeObserver:self];
}

/* CraneManager / LSApplicationWorkspace observer callbacks. */
- (void)didChangeContainersOfApplicationWithIdentifier:(NSString *)applicationIdentifier
{
    (void)applicationIdentifier;
    [self updateAvailableListeners];
    [self updateProvidedEvents];
}

- (void)applicationsDidInstall:(id)applications
{
    (void)applications;
    [self updateAvailableListeners];
    [self updateProvidedEvents];
}

- (void)applicationsDidUninstall:(id)applications
{
    (void)applications;
    [self updateAvailableListeners];
    [self updateProvidedEvents];
}

/* ---- set-active-container listeners ------------------------------------ */

- (NSString *)listenerNameForSettingActiveContainerOfApplicationWithIdentifier:(NSString *)applicationIdentifier
                                              toActiveContainerWithIdentifier:(NSString *)containerIdentifier
{
    return [NSString stringWithFormat:CR_ACTIVATOR_LISTENER_FMT,
                                      CR_ACTIVATOR_LISTENER_PREFIX,
                                      applicationIdentifier,
                                      containerIdentifier];
}

- (BOOL)listenerNameIsSetActiveContainerListener:(NSString *)listenerName
{
    return [listenerName containsString:@"SetActiveContainer"];
}

- (NSString *)applicationIdentifierForSetActiveContainerListenerName:(NSString *)listenerName
{
    if (![self listenerNameIsSetActiveContainerListener:listenerName])
        return nil;
    NSArray<NSString *> *parts = [listenerName componentsSeparatedByString:@"|"];
    return parts.count >= 3 ? parts[1] : nil;
}

- (NSString *)containerIdentifierForSetActiveContainerListenerName:(NSString *)listenerName
{
    if (![self listenerNameIsSetActiveContainerListener:listenerName])
        return nil;
    NSArray<NSString *> *parts = [listenerName componentsSeparatedByString:@"|"];
    return parts.count >= 3 ? parts[2] : nil;
}

- (void)unregisterAllListeners
{
    [self unregisterSetActiveContainerListeners];
}

- (void)updateAvailableListeners
{
    [self updateSetActiveContainerListeners];
}

- (void)updateSetActiveContainerListeners
{
    CraneManager *manager = [CraneManager sharedManager];

    for (NSString *listenerName in [self.setActiveContainerListenersCache copy]) {
        NSString *applicationIdentifier =
            [self applicationIdentifierForSetActiveContainerListenerName:listenerName];
        NSString *containerIdentifier =
            [self containerIdentifierForSetActiveContainerListenerName:listenerName];
        NSArray *containers =
            [manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier];

        if (![containers containsObject:containerIdentifier] ||
            !CRActivatorApplicationIsInstalled(applicationIdentifier)) {
            [self.setActiveContainerListenersCache removeObject:listenerName];
            [gCRActivator unregisterListenerWithName:listenerName];
        }
    }

    for (NSString *applicationIdentifier in
         [manager identfiersOfApplicationsThatHaveNonDefaultContainers]) {
        if (!CRActivatorApplicationIsInstalled(applicationIdentifier))
            continue;

        for (NSString *containerIdentifier in
             [manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier]) {
            NSString *listenerName =
                [self listenerNameForSettingActiveContainerOfApplicationWithIdentifier:applicationIdentifier
                                                        toActiveContainerWithIdentifier:containerIdentifier];
            if (![self.setActiveContainerListenersCache containsObject:listenerName]) {
                [self.setActiveContainerListenersCache addObject:listenerName];
                [gCRActivator registerListener:self forName:listenerName];
            }
        }
    }
}

- (void)unregisterSetActiveContainerListeners
{
    for (NSString *listenerName in [self.setActiveContainerListenersCache copy])
        [gCRActivator unregisterListenerWithName:listenerName];
    [self.setActiveContainerListenersCache removeAllObjects];
}

- (void)activator:(id)activator receiveEvent:(id)event forListenerName:(NSString *)listenerName
{
    (void)activator;
    NSString *applicationIdentifier =
        [self applicationIdentifierForSetActiveContainerListenerName:listenerName];
    NSString *containerIdentifier =
        [self containerIdentifierForSetActiveContainerListenerName:listenerName];

    CraneManager *manager = [CraneManager sharedManager];
    NSString *previousContainerIdentifier =
        [manager activeContainerIdentifierForApplicationWithIdentifier:applicationIdentifier];

    if (![containerIdentifier isEqualToString:previousContainerIdentifier]) {
        [event setUserInfo:@{ @"previousContainerID": previousContainerIdentifier }];
        [manager setActiveContainerIdentifier:containerIdentifier
                 forApplicationWithIdentifier:applicationIdentifier
 usingBiometricsIfNeededWithSuccessHandler:^{}];
    }
}

- (void)activator:(id)activator abortEvent:(id)event forListenerName:(NSString *)listenerName
{
    (void)activator;
    NSString *previousContainerIdentifier = [event userInfo][@"previousContainerID"];
    if (!previousContainerIdentifier)
        return;

    NSString *applicationIdentifier =
        [self applicationIdentifierForSetActiveContainerListenerName:listenerName];
    [[CraneManager sharedManager]
        setActiveContainerIdentifier:previousContainerIdentifier
        forApplicationWithIdentifier:applicationIdentifier];
}

- (BOOL)activator:(id)activator
receiveUnlockingDeviceEvent:(id)event
   forListenerName:(NSString *)listenerName
{
    (void)activator;
    (void)event;
    (void)listenerName;
    return NO;
}

/* ---- listener metadata ------------------------------------------------- */

- (NSString *)activator:(id)activator requiresLocalizedTitleForListenerName:(NSString *)listenerName
{
    (void)activator;
    if (![self listenerNameIsSetActiveContainerListener:listenerName])
        return @"";

    NSString *applicationIdentifier =
        [self applicationIdentifierForSetActiveContainerListenerName:listenerName];
    NSString *containerIdentifier =
        [self containerIdentifierForSetActiveContainerListenerName:listenerName];
    CraneManager *manager = [CraneManager sharedManager];
    NSString *applicationName =
        [manager displayNameForApplicationWithIdentifier:applicationIdentifier];
    NSString *containerName =
        [manager displayNameForContainerWithIdentifier:containerIdentifier
                           ofApplicationWithIdentifier:applicationIdentifier
                                shouldUseShortVersion:YES];
    return [NSString stringWithFormat:@"%@ -> %@", applicationName, containerName];
}

- (NSString *)activator:(id)activator
requiresLocalizedDescriptionForListenerName:(NSString *)listenerName
{
    (void)activator;
    if (![self listenerNameIsSetActiveContainerListener:listenerName])
        return @"";

    NSString *applicationIdentifier =
        [self applicationIdentifierForSetActiveContainerListenerName:listenerName];
    NSString *containerIdentifier =
        [self containerIdentifierForSetActiveContainerListenerName:listenerName];
    NSString *containerName =
        [[CraneManager sharedManager]
            displayNameForContainerWithIdentifier:containerIdentifier
                       ofApplicationWithIdentifier:applicationIdentifier
                            shouldUseShortVersion:YES];
    return [NSString stringWithFormat:CRLocalize(@"SET_AS_THE_ACTIVE_CRANE_CONTAINER"),
                                      containerName];
}

- (NSString *)activator:(id)activator requiresLocalizedGroupForListenerName:(NSString *)listenerName
{
    (void)activator;
    (void)listenerName;
    return @"Crane";
}

- (NSNumber *)activator:(id)activator requiresRequiresAssignmentForListenerName:(NSString *)listenerName
{
    (void)activator;
    (void)listenerName;
    return @NO;
}

- (NSArray *)activator:(id)activator
requiresCompatibleEventModesForListenerWithName:(NSString *)listenerName
{
    (void)activator;
    /* IDA 0x1D550 shows the listener-name argument left in the vararg list
     * between "springboard" and "lockscreen"; preserve that recovered call
     * rather than silently normalizing it. */
    return [NSArray arrayWithObjects:@"springboard", listenerName,
            @"lockscreen", @"application", nil];
}

- (NSNumber *)activator:(id)activator
requiresIsCompatibleWithEventName:(NSString *)eventName
           listenerName:(NSString *)listenerName
{
    (void)activator;
    (void)eventName;
    (void)listenerName;
    return @YES;
}

- (NSArray *)activator:(id)activator
requiresExclusiveAssignmentGroupsForListenerName:(NSString *)listenerName
{
    (void)activator;
    (void)listenerName;
    return @[];
}

- (id)activator:(id)activator
requiresInfoDictionaryValueOfKey:(NSString *)key
 forListenerWithName:(NSString *)listenerName
{
    (void)activator;
    (void)key;
    (void)listenerName;
    return nil;
}

- (BOOL)activator:(id)activator requiresNeedsPoweredDisplayForListenerName:(NSString *)listenerName
{
    (void)activator;
    (void)listenerName;
    return NO;
}

/* The original uses SBIcon.generateIconImageWithInfo: with a private struct
 * containing {29,29,scale,5}. The selector is recovered, but its struct ABI is
 * not available in the export. Keep the selector surface without fabricating
 * an ABI; Activator treats a nil icon as optional. */
- (UIImage *)imageForApplicationWithIdentifier:(NSString *)applicationIdentifier
                                         scale:(double)scale
{
    (void)applicationIdentifier;
    (void)scale;
    return nil;
}

- (UIImage *)activator:(id)activator
requiresIconForListenerName:(NSString *)listenerName
                 scale:(double)scale
{
    (void)activator;
    if (![self listenerNameIsSetActiveContainerListener:listenerName])
        return nil;
    return [self imageForApplicationWithIdentifier:
                 [self applicationIdentifierForSetActiveContainerListenerName:listenerName]
                                             scale:scale];
}

- (UIImage *)activator:(id)activator
requiresSmallIconForListenerName:(NSString *)listenerName
                      scale:(double)scale
{
    return [self activator:activator
 requiresIconForListenerName:listenerName
                       scale:scale];
}

- (BOOL)activator:(id)activator requiresSupportsRemovalForListenerWithName:(NSString *)listenerName
{
    (void)activator;
    (void)listenerName;
    return NO;
}

- (void)activator:(id)activator requestsRemovalForListenerWithName:(NSString *)listenerName
{
    (void)activator;
    (void)listenerName;
}

/* ---- changed-container events ------------------------------------------ */

- (NSString *)changedToContainerEventNameForContainerIdentifier:(NSString *)containerIdentifier
                                    ofApplicationWithIdentifier:(NSString *)applicationIdentifier
{
    return [NSString stringWithFormat:CR_ACTIVATOR_EVENT_FMT,
                                      CR_ACTIVATOR_EVENT_PREFIX,
                                      containerIdentifier,
                                      applicationIdentifier];
}

- (BOOL)eventNameIsChangedToContainerEvent:(NSString *)eventName
{
    NSString *prefix =
        [NSString stringWithFormat:@"%@.ChangedToContainer", CR_ACTIVATOR_EVENT_PREFIX];
    return [eventName hasPrefix:prefix];
}

- (NSString *)containerIDForChangedToContainerEventName:(NSString *)eventName
{
    if (![self eventNameIsChangedToContainerEvent:eventName])
        return nil;
    NSArray<NSString *> *parts = [eventName componentsSeparatedByString:@"|"];
    return parts.count >= 3 ? parts[1] : nil;
}

- (NSString *)applicationIDForChangedToContainerEventName:(NSString *)eventName
{
    if (![self eventNameIsChangedToContainerEvent:eventName])
        return nil;
    NSArray<NSString *> *parts = [eventName componentsSeparatedByString:@"|"];
    return parts.count >= 3 ? parts[2] : nil;
}

- (void)updateProvidedEvents
{
    CraneManager *manager = [CraneManager sharedManager];

    for (NSString *eventName in [self.changedToContainerEventCache copy]) {
        NSString *applicationIdentifier =
            [self applicationIDForChangedToContainerEventName:eventName];
        NSString *containerIdentifier =
            [self containerIDForChangedToContainerEventName:eventName];
        NSArray *containers =
            [manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier];

        if (![containers containsObject:containerIdentifier] ||
            !CRActivatorApplicationIsInstalled(applicationIdentifier)) {
            [self.changedToContainerEventCache removeObject:eventName];
            [gCRActivator unregisterEventDataSourceWithEventName:eventName];
        }
    }

    for (NSString *applicationIdentifier in
         [manager identfiersOfApplicationsThatHaveNonDefaultContainers]) {
        if (!CRActivatorApplicationIsInstalled(applicationIdentifier))
            continue;

        for (NSString *containerIdentifier in
             [manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier]) {
            NSString *eventName =
                [self changedToContainerEventNameForContainerIdentifier:containerIdentifier
                                            ofApplicationWithIdentifier:applicationIdentifier];
            if (![self.changedToContainerEventCache containsObject:eventName]) {
                [self.changedToContainerEventCache addObject:eventName];
                [gCRActivator registerEventDataSource:self forEventName:eventName];
            }
        }
    }
}

- (void)unregisterAllEvents
{
    for (NSString *eventName in [self.changedToContainerEventCache copy])
        [gCRActivator unregisterEventDataSourceWithEventName:eventName];
    [self.changedToContainerEventCache removeAllObjects];
}

- (NSString *)localizedGroupForEventName:(NSString *)eventName
{
    (void)eventName;
    return @"Crane";
}

- (NSString *)localizedTitleForEventName:(NSString *)eventName
{
    if (![self eventNameIsChangedToContainerEvent:eventName])
        return @"";

    NSString *applicationIdentifier =
        [self applicationIDForChangedToContainerEventName:eventName];
    NSString *containerIdentifier =
        [self containerIDForChangedToContainerEventName:eventName];
    CraneManager *manager = [CraneManager sharedManager];
    NSString *applicationName =
        [manager displayNameForApplicationWithIdentifier:applicationIdentifier];
    NSString *containerName =
        [manager displayNameForContainerWithIdentifier:containerIdentifier
                           ofApplicationWithIdentifier:applicationIdentifier
                                shouldUseShortVersion:YES];
    return [NSString stringWithFormat:@"%@ -> %@", applicationName, containerName];
}

- (NSString *)localizedDescriptionForEventName:(NSString *)eventName
{
    if (![self eventNameIsChangedToContainerEvent:eventName])
        return @"";

    NSString *applicationIdentifier =
        [self applicationIDForChangedToContainerEventName:eventName];
    NSString *containerIdentifier =
        [self containerIDForChangedToContainerEventName:eventName];
    CraneManager *manager = [CraneManager sharedManager];
    NSString *applicationName =
        [manager displayNameForApplicationWithIdentifier:applicationIdentifier];
    NSString *containerName =
        [manager displayNameForContainerWithIdentifier:containerIdentifier
                           ofApplicationWithIdentifier:applicationIdentifier
                                shouldUseShortVersion:YES];
    return [NSString stringWithFormat:CRLocalize(@"CHANGED_TO_CONTAINER"),
                                      applicationName, containerName];
}

- (BOOL)eventWithName:(NSString *)eventName isCompatibleWithMode:(NSString *)mode
{
    (void)eventName;
    (void)mode;
    return YES;
}

@end
