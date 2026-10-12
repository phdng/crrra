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
typedef struct {
    double width;
    double height;
    double scale;
    double unknownFourthField;
} CRSBIconImageInfoABI;
_Static_assert(sizeof(CRSBIconImageInfoABI) == 32, "SBIcon image-info ABI must remain four doubles");

@interface NSObject (CraneActivatorRuntime)
+ (id)sharedInstance;
+ (id)applicationProxyForIdentifier:(NSString *)identifier;
+ (id)defaultWorkspace;
- (BOOL)isInstalled;
- (id)model;
- (id)expectedIconForDisplayIdentifier:(NSString *)identifier;
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

/* Native 0x1C924 used containsString:, but an externally supplied
 * Activator listener name must not be accepted because it contains a
 * substring of another tweak's name. Native 0x1C8B0 generates exactly
 * four pipe-separated components, ending in '|'. Defensive adaptation. */
static NSArray<NSString *> *CRActivatorParsedListenerName(NSString *name)
{
    if (![name isKindOfClass:NSString.class])
        return nil;
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"|"];
    if (parts.count != 4 || [parts[3] length] != 0 ||
        ![parts[1] length] || ![parts[2] length])
        return nil;
    NSString *expected = [NSString stringWithFormat:CR_ACTIVATOR_LISTENER_FMT,
                          CR_ACTIVATOR_LISTENER_PREFIX, parts[1], parts[2]];
    return [name isEqualToString:expected] ? parts : nil;
}

/* 0x1D82C emits a different field order for changed-container
 * events: container ID first, application ID second. Treat anything
 * except the exact generated name as an unrelated Activator event. */
static NSArray<NSString *> *CRActivatorParsedEventName(NSString *name)
{
    if (![name isKindOfClass:NSString.class])
        return nil;
    NSArray<NSString *> *parts = [name componentsSeparatedByString:@"|"];
    if (parts.count != 4 || [parts[3] length] != 0 ||
        ![parts[1] length] || ![parts[2] length])
        return nil;
    NSString *expected = [NSString stringWithFormat:CR_ACTIVATOR_EVENT_FMT,
                          CR_ACTIVATOR_EVENT_PREFIX, parts[1], parts[2]];
    return [name isEqualToString:expected] ? parts : nil;
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
    return CRActivatorParsedListenerName(listenerName) != nil;
}

- (NSString *)applicationIdentifierForSetActiveContainerListenerName:(NSString *)listenerName
{
    return CRActivatorParsedListenerName(listenerName)[1];
}

- (NSString *)containerIdentifierForSetActiveContainerListenerName:(NSString *)listenerName
{
    return CRActivatorParsedListenerName(listenerName)[2];
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

    /* Only honor registered listener names for an installed app and a
     * currently known target. Deleted containers must never be activated.
     * DEFAULT remains valid even when absent from the persisted ID list. */
    if (![self listenerNameIsSetActiveContainerListener:listenerName] ||
        ![self.setActiveContainerListenersCache containsObject:listenerName] ||
        !CRActivatorApplicationIsInstalled(applicationIdentifier))
        return;
    CraneManager *manager = [CraneManager sharedManager];
    NSArray<NSString *> *containers =
        [manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier];
    if (![containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
        ![containers containsObject:containerIdentifier])
        return;
    NSString *previousContainerIdentifier =
        [manager activeContainerIdentifierForApplicationWithIdentifier:applicationIdentifier];
    if (![previousContainerIdentifier isKindOfClass:NSString.class] ||
        !previousContainerIdentifier.length)
        return;
    if (![containerIdentifier isEqualToString:previousContainerIdentifier]) {
        [event setUserInfo:@{ @"previousContainerID": previousContainerIdentifier }];
        [manager setActiveContainerIdentifier:containerIdentifier
                 forApplicationWithIdentifier:applicationIdentifier
 usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {
            (void)authenticated;
        }];
    }
}

- (void)activator:(id)activator abortEvent:(id)event forListenerName:(NSString *)listenerName
{
    (void)activator;
    if (![self listenerNameIsSetActiveContainerListener:listenerName] ||
        ![self.setActiveContainerListenersCache containsObject:listenerName])
        return;
    NSString *previousContainerIdentifier = [event userInfo][@"previousContainerID"];
    if (![previousContainerIdentifier isKindOfClass:NSString.class] ||
        !previousContainerIdentifier.length)
        return;

    NSString *applicationIdentifier =
        [self applicationIdentifierForSetActiveContainerListenerName:listenerName];
    CraneManager *manager = [CraneManager sharedManager];
    NSArray<NSString *> *containers =
        [manager containerIdentifiersOfApplicationWithIdentifier:applicationIdentifier];
    if (!CRActivatorApplicationIsInstalled(applicationIdentifier) ||
        (![previousContainerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
         ![containers containsObject:previousContainerIdentifier]))
        return;
    [manager setActiveContainerIdentifier:previousContainerIdentifier
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

/* CONFIRMED_STATIC from both original arm64 slices: immediately before
 * generateIconImageWithInfo:, the compiler places 29, 29, scale and 5 in
 * d0..d3. On arm64 that is the homogeneous-aggregate ABI for four doubles.
 * Field names beyond width/height/scale are not recovered, so the fourth field
 * deliberately remains semantically unnamed while preserving the exact ABI. */
- (UIImage *)imageForApplicationWithIdentifier:(NSString *)applicationIdentifier
                                         scale:(double)scale
{
    Class controllerClass = NSClassFromString(@"SBIconController");
    if (!controllerClass)
        return nil;

    id controller = [(id)controllerClass sharedInstance];
    id model = [controller model];
    id icon = [model expectedIconForDisplayIdentifier:applicationIdentifier];
    SEL selector = NSSelectorFromString(@"generateIconImageWithInfo:");
    if (!icon || ![icon respondsToSelector:selector])
        return nil;

    CRSBIconImageInfoABI info = { 29.0, 29.0, scale, 5.0 };
    IMP implementation = [icon methodForSelector:selector];
    UIImage *(*generateImage)(id, SEL, CRSBIconImageInfoABI) =
        (UIImage *(*)(id, SEL, CRSBIconImageInfoABI))implementation;
    return generateImage(icon, selector, info);
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
    return CRActivatorParsedEventName(eventName) != nil;
}

- (NSString *)containerIDForChangedToContainerEventName:(NSString *)eventName
{
    return CRActivatorParsedEventName(eventName)[1];
}

- (NSString *)applicationIDForChangedToContainerEventName:(NSString *)eventName
{
    return CRActivatorParsedEventName(eventName)[2];
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
