/*
 * CRPreferences.m — CranePrefs.bundle/CranePrefs, the Settings UI.
 *
 * The Settings UI is driven almost entirely by the plist specifiers in
 * Root.plist / Credits.plist, which are reproduced byte-for-byte in
 * reconstruction/layout/. This file therefore supplies:
 *
 *   * CRPRootListController   - NSPrincipalClass of the bundle
 *                              (CranePrefs.bundle/Info.plist)
 *   * CRPApplicationConfigurationListController - the per-application pane
 *   * CRPActiveContainerListItemsController     - the Active Container sheet
 *
 * all three of which are named in Root.plist and confirmed by the recovered
 * __objc_classlist.
 *
 * The class *names*, the preference *keys*, their *defaults*, the specifier
 * *order* and the section predicate are all CONFIRMED_STATIC. The custom
 * table cells and backup/restore flows remain incomplete. The optional Choicy
 * editor is recovered separately in CRChoicyEditor.m; its native behavior
 * remains unverified - see final/KNOWN_DIFFERENCES.md.
 */

#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <limits.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"
#import "CRChoicyEditor.h"

/* AltList and the Preferences framework are linked by the original. They are
 * declared minimally here so the file can be read without their headers; the
 * build genuinely requires both frameworks (see the Makefile). */
@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController
- (id)specifiers;
- (void)setSpecifier:(id)specifier;
- (id)specifier;
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (id)specifierAtIndex:(NSUInteger)index;
- (NSInteger)indexForIndexPath:(NSIndexPath *)indexPath;
- (void)reloadSpecifier:(id)specifier;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(id)specifier;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (void)reloadSpecifierAtIndex:(NSUInteger)index;
- (void)replaceContiguousSpecifiers:(NSArray *)oldSpecifiers withSpecifiers:(NSArray *)newSpecifiers animated:(BOOL)animated;
- (void)insertSpecifier:(id)specifier atIndex:(NSUInteger)index animated:(BOOL)animated;
- (void)insertSpecifier:(id)specifier afterSpecifier:(id)after animated:(BOOL)animated;
- (void)removeSpecifier:(id)specifier animated:(BOOL)animated;
@end

@interface PSSpecifier : NSObject
+ (id)preferenceSpecifierNamed:(NSString *)name target:(id)target set:(SEL)set
                          get:(SEL)get detail:(Class)detail cell:(NSInteger)cell
                          edit:(NSInteger)edit;
+ (id)emptyGroupSpecifier;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setDetailControllerClass:(Class)cls;
- (NSString *)name;
- (void)setName:(NSString *)name;
- (void)setButtonAction:(SEL)action;
- (void)setTitleDictionary:(id)value;
- (void)setShortTitleDictionary:(id)value;
- (void)setValues:(id)value;
- (void)loadValuesAndTitlesFromDataSource;
- (NSArray *)values;
@end

/* ------------------------------------------------------------------------- */
/* CRPRootListController                                                       */
/* ------------------------------------------------------------------------- */

@interface CRPRootListController : PSListController
@property (nonatomic, strong) NSArray *craneRootSpecifiers;
@end

@implementation CRPRootListController

- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated
{
    /* PSListController needs its backing before superclass layout runs. */
    [self specifiers];
    [super viewWillAppear:animated];
}

- (id)specifiers
{
    /* Explicit loading is required: NSPrincipalClass alone does not load
     * Root.plist and Settings otherwise displays an empty pane. */
    if (!self.craneRootSpecifiers) {
        NSBundle *bundle = [NSBundle bundleForClass:[self class]];
        NSLog(@"CranePrefs: root controller loaded; bundle=%@; Root.plist=%@",
              bundle.bundlePath, [bundle pathForResource:@"Root" ofType:@"plist"]);
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
        NSMutableArray *rootRows = [loaded mutableCopy] ?: [NSMutableArray new];
        /* Root.plist's first entry is a PSLinkListCell, handled by AltList
         * in the original. The current loader may produce a deferred/blank
         * cell until Settings relayout. Replace it with an immediately
         * usable link, preserving every later Root.plist preference. */
        NSUInteger appsIndex = NSNotFound;
        for (NSUInteger i = 0; i < rootRows.count; ++i) {
            PSSpecifier *row = rootRows[i];
            if ([[row propertyForKey:@"label"] isEqual:@"APPLICATIONS"] ||
                [row.name isEqualToString:CRLocalize(@"APPLICATIONS")]) {
                appsIndex = i;
                break;
            }
        }
        Class appListClass = NSClassFromString(@"CRPApplicationListSubcontrollerController");
        PSSpecifier *apps = [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"APPLICATIONS")
            target:self set:NULL get:NULL detail:appListClass cell:2 edit:0];
        [apps setDetailControllerClass:appListClass];
        [apps setProperty:@"CRPApplicationListSubcontrollerController" forKey:@"subcontrollerClass"];
        if (appsIndex != NSNotFound)
            [rootRows removeObjectAtIndex:appsIndex];
        /* Unlike the original CRPListController, our PSListController base
         * does not own the original root-group normalization. A link placed
         * before the first PSGroupCell is not reliably rendered during the
         * initial table construction. Put the link in its own explicit group. */
        PSSpecifier *applicationsGroup = [PSSpecifier emptyGroupSpecifier];
        [rootRows insertObject:applicationsGroup atIndex:0];
        [rootRows insertObject:apps atIndex:1];
        NSLog(@"CranePrefs: APPLICATIONS group and link installed at root start; rows=%lu",
              (unsigned long)rootRows.count);
        self.craneRootSpecifiers = rootRows;
        /* Avoid a direct _specifiers ivar reference: the private framework's
         * ivar-offset symbol is not exported by the SDK linker stub. KVC
         * resolves the ivar in the installed Preferences.framework at runtime. */
        @try {
            [self setValue:self.craneRootSpecifiers forKey:@"_specifiers"];
        } @catch (NSException *exception) {
            NSLog(@"CranePrefs: unable to install table specifiers: %@", exception);
        }
        NSLog(@"CranePrefs: root specifier count=%lu",
              (unsigned long)self.craneRootSpecifiers.count);
    }
    @try { [self setValue:self.craneRootSpecifiers forKey:@"_specifiers"]; }
    @catch (NSException *exception) { NSLog(@"CranePrefs: root backing refresh failed: %@", exception); }
    return self.craneRootSpecifiers;
}

@end

/* The original CRPActiveContainerListItemsController inherits the built-in
 * PSListItemsController; Preferences handles the selected value and calls
 * the parent specifier's setActiveContainer:specifier: action (0x74D8/77CC).
 * Recreating the selection in PSListController bypassed that contract. */
@interface PSListItemsController : PSListController
@end

@interface CRPActiveContainerListItemsController : PSListItemsController
- (NSString *)applicationIdentifier;
@end

@implementation CRPActiveContainerListItemsController
- (NSString *)applicationIdentifier
{
    return [[self specifier] propertyForKey:@"applicationIdentifier"];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    PSSpecifier *parent = [self specifier];
    NSArray *values = [parent values];
    NSUInteger row = (NSUInteger)indexPath.row;
    if (row >= values.count) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    NSString *containerID = values[row];
    NSString *appID = [self applicationIdentifier];
    if (!appID.length || ![containerID isKindOfClass:NSString.class]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        return;
    }
    NSDictionary *settings = [CraneManager.sharedManager
        containerSettingsForContainerWithIdentifier:containerID
        ofApplicationWithIdentifier:appID];
    if ([settings[@"requireBiometricAuthentication"] boolValue]) {
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        NSInteger index = [self indexForIndexPath:indexPath];
        PSSpecifier *rowSpecifier = index >= 0 && (NSUInteger)index != NSNotFound
            ? [self specifierAtIndex:(NSUInteger)index] : nil;
        NSString *reason = [NSString stringWithFormat:CRLocalize(@"SET_ACTIVE_CONTAINER_DESCRIPTION"),
            rowSpecifier.name ?: containerID];
        CRRequestAuthentication(reason, ^{
            [super tableView:tableView didSelectRowAtIndexPath:indexPath];
        });
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}
@end

/* CranePrefs 0xDFD4/0xE030/0xE08C/0xE1E0/0xE31C: Filza browsing.
 * Only application paths are exposed in this reconstruction. The original
 * manager enumerates group/plug-in paths as well; those mappings are not
 * available and must not be guessed or synthesized from identifiers. */
@interface CRPBrowseContainerListController : PSListController
@property (nonatomic, strong) NSArray *craneBrowseSpecifiers;
- (NSString *)applicationIdentifier;
- (NSString *)containerIdentifier;
- (void)openPathForSpecifier:(PSSpecifier *)specifier;
@end

@implementation CRPBrowseContainerListController

- (NSString *)applicationIdentifier
{
    return [[self specifier] propertyForKey:@"applicationIdentifier"];
}

- (NSString *)containerIdentifier
{
    return [[self specifier] propertyForKey:@"containerIdentifier"];
}

- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (void)setSpecifier:(PSSpecifier *)specifier
{
    self.craneBrowseSpecifiers = nil;
    @try { [self setValue:nil forKey:@"_specifiers"]; }
    @catch (__unused NSException *exception) {}
    [super setSpecifier:specifier];
}

- (PSSpecifier *)specifierForIdentifier:(NSString *)identifier
                                   path:(NSString *)path
{
    PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:
        CRLocalize(identifier) target:self set:NULL get:NULL
        detail:NULL cell:13 edit:0];
    [row setProperty:@YES forKey:@"enabled"];
    [row setProperty:path forKey:@"pathToOpen"];
    [row setButtonAction:@selector(openPathForSpecifier:)];
    return row;
}

- (id)specifiers
{
    if (!self.craneBrowseSpecifiers) {
        NSMutableArray *rows = [NSMutableArray new];
        NSString *appID = self.applicationIdentifier;
        NSString *containerID = self.containerIdentifier;
        if (appID.length && containerID.length) {
            NSArray<NSString *> *paths = [CraneManager.sharedManager
                pathsAssociatedToContainerWithIdentifier:containerID
                              ofApplicationWithIdentifier:appID];
            NSFileManager *fm = NSFileManager.defaultManager;
            NSMutableSet<NSString *> *seen = [NSMutableSet new];
            for (NSString *path in paths) {
                if (![path isKindOfClass:NSString.class] || !path.length ||
                    [seen containsObject:path])
                    continue;
                BOOL directory = NO;
                if (![fm fileExistsAtPath:path isDirectory:&directory] ||
                    !directory ||
                    [fm destinationOfSymbolicLinkAtPath:path error:NULL])
                    continue;
                if (!rows.count) {
                    PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
                    [group setName:CRLocalize(@"APPLICATION")];
                    [rows addObject:group];
                }
                [seen addObject:path];
                [rows addObject:[self specifierForIdentifier:@"APPLICATION"
                                                      path:path]];
            }
        }
        self.craneBrowseSpecifiers = [rows copy];
    }
    @try { [self setValue:self.craneBrowseSpecifiers forKey:@"_specifiers"]; }
    @catch (NSException *exception) {
        NSLog(@"CranePrefs: browse specifier backing failed: %@", exception);
    }
    return self.craneBrowseSpecifiers;
}

- (void)openPathForSpecifier:(PSSpecifier *)specifier
{
    NSString *appID = self.applicationIdentifier;
    NSString *containerID = self.containerIdentifier;
    NSString *path = [specifier propertyForKey:@"pathToOpen"];
    if (!appID.length || !containerID.length ||
        ![path isKindOfClass:NSString.class] || !path.length)
        return;
    /* The displayed specifier may be stale after reinstall/switch.
     * Revalidate against the current verified manager paths at click time. */
    NSArray<NSString *> *paths = [CraneManager.sharedManager
        pathsAssociatedToContainerWithIdentifier:containerID
                          ofApplicationWithIdentifier:appID];
    BOOL directory = NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![paths containsObject:path] ||
        ![fm fileExistsAtPath:path isDirectory:&directory] || !directory ||
        [fm destinationOfSymbolicLinkAtPath:path error:NULL])
        return;

    /* Native 0xE08C: filza://view + URLPath-escaped path + /./ */
    NSString *encoded = [path stringByAddingPercentEncodingWithAllowedCharacters:
        NSCharacterSet.URLPathAllowedCharacterSet];
    if (!encoded.length)
        return;
    NSURL *url = [NSURL URLWithString:
        [NSString stringWithFormat:@"filza://view%@/./", encoded]];
    UIApplication *application = UIApplication.sharedApplication;
    if (url && [application canOpenURL:url])
        [application openURL:url options:@{} completionHandler:nil];
}
@end

/* Initial container detail controller reconstructed from CranePrefs 0x8920,
 * 0xEF38, 0xF0EC and 0xF268. Advanced groups remain unsupported. */
@interface CRPContainerConfigurationListController : PSListController
@property (nonatomic, copy) NSString *applicationIdentifier;
@property (nonatomic, copy) NSString *containerIdentifier;
@property (nonatomic, strong) NSArray *craneContainerSpecifiers;
@property (nonatomic, strong) PSSpecifier *choicyOverwriteToggleSpecifier;
@property (nonatomic, strong) PSSpecifier *choicyConfigurationPreviewSpecifier;
@property (nonatomic, strong) PSSpecifier *sizeGroupSpecifier;
@property (nonatomic, assign) unsigned long long cachedSize;
@property (nonatomic, assign) BOOL sizeCached;
@property (nonatomic, assign) NSUInteger sizeFetchGeneration;
@property (nonatomic, assign) BOOL craneReloadScheduled;
- (void)scheduleContainerConfigurationReload;
- (void)updateContainerSize;
- (void)updateSizeGroupSpecifierAndReload:(BOOL)reload;
@end

@implementation CRPContainerConfigurationListController

- (instancetype)init
{
    if ((self = [super init]))
        [CraneManager.sharedManager addObserver:self];
    return self;
}

- (void)dealloc
{
    [CraneManager.sharedManager removeObserver:self];
}

/* Coalesce observer and action refreshes after the current table selection
 * completes. Rebuilding private _specifiers inside didSelect/action dispatch
 * can leave Preferences' section map pointing at the old rows. */
- (void)scheduleContainerConfigurationReload
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scheduleContainerConfigurationReload];
        });
        return;
    }
    if (self.craneReloadScheduled)
        return;
    self.craneReloadScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.craneReloadScheduled = NO;
        self.sizeCached = NO;
        self.sizeFetchGeneration++;
        self.craneContainerSpecifiers = nil;
        self.sizeGroupSpecifier = nil;
        @try { [self setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
        [self reloadSpecifiers];
    });
}

- (void)didChangeContainerSettingsForContainerWithIdentifier:(NSString *)containerID
                            onApplicationWithIdentifier:(NSString *)appID
{
    if ([containerID isEqualToString:self.containerIdentifier] &&
        [appID isEqualToString:self.applicationIdentifier])
        [self scheduleContainerConfigurationReload];
}

- (void)didChangeSettingsForApplicationWithIdentifier:(NSString *)appID
{
    if ([appID isEqualToString:self.applicationIdentifier])
        [self scheduleContainerConfigurationReload];
}

- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated
{
    BOOL alreadyLoaded = self.craneContainerSpecifiers != nil;
    [self specifiers];
    [super viewWillAppear:animated];
    /* Refresh on return from another pane, but do not request twice
     * during the initial specifier build. */
    if (alreadyLoaded)
        [self updateContainerSize];
}

- (void)setSpecifier:(PSSpecifier *)specifier
{
    NSString *appID = [specifier propertyForKey:@"applicationIdentifier"];
    NSString *containerID = [specifier propertyForKey:@"containerIdentifier"];
    if (![appID isEqualToString:self.applicationIdentifier] ||
        ![containerID isEqualToString:self.containerIdentifier]) {
        self.applicationIdentifier = appID;
        self.containerIdentifier = containerID;
        self.sizeCached = NO;
        self.sizeFetchGeneration++;
        self.craneContainerSpecifiers = nil;
        @try { [self setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
    }
    [super setSpecifier:specifier];
}

- (id)specifiers
{
    BOOL shouldUpdateSize = !self.craneContainerSpecifiers;
    if (!self.craneContainerSpecifiers) {
        CraneManager *manager = CraneManager.sharedManager;
        NSDictionary *settings = [manager containerSettingsForContainerWithIdentifier:
            self.containerIdentifier ofApplicationWithIdentifier:self.applicationIdentifier];
        NSString *name = settings[CRCContainer_Name] ?: self.containerIdentifier ?: @"Container";
        BOOL isActive = [[manager activeContainerIdentifierForApplicationWithIdentifier:
            self.applicationIdentifier] isEqualToString:self.containerIdentifier];
        self.title = name;
        NSMutableArray *rows = [NSMutableArray new];
        PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
        [group setName:name];
        [rows addObject:group];
        PSSpecifier *active = [PSSpecifier preferenceSpecifierNamed:
            (isActive ? [NSString stringWithFormat:@"✓ %@", CRLocalize(@"ACTIVE")]
                      : CRLocalize(@"SET_AS_THE_ACTIVE_CRANE_CONTAINER"))
            target:self set:NULL get:NULL detail:NULL cell:13 edit:0];
        [active setButtonAction:@selector(makeActiveContainer)];
        [rows addObject:active];
        PSSpecifier *rename = [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"RENAME")
            target:self set:NULL get:NULL detail:NULL cell:13 edit:0];
        [rename setButtonAction:@selector(renameContainer)];
        [rows addObject:rename];

        /* CranePrefs 0x12EE8/0x10608/0xF8F0/0x12F74 displays vendor
         * ID only for supported applications. Our helper cannot yet
         * generate the real system ID, so restrict this to a verified,
         * non-default UUID and don't expose Generate/Set Custom actions. */
        if (![self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
            [manager applicationHasDeviceIdentifier:self.applicationIdentifier]) {
            NSString *selected = [manager
                deviceIdentifierToUseForContainerWithIdentifier:self.containerIdentifier
                                    ofApplicationWithIdentifier:self.applicationIdentifier];
            if (selected.length && [[NSUUID alloc] initWithUUIDString:selected]) {
                PSSpecifier *deviceGroup = [PSSpecifier emptyGroupSpecifier];
                [deviceGroup setName:CRLocalize(@"DEVICE_IDENTIFIER_FOR_VENDOR")];
                [rows addObject:deviceGroup];
                PSSpecifier *display = [PSSpecifier preferenceSpecifierNamed:selected
                    target:self set:NULL get:NULL detail:NULL cell:4 edit:0];
                [rows addObject:display];

                /* Disabling "use container identifier" is meaningful
                 * only if a valid stored custom UUID already exists.
                 * Otherwise CraneSupport falls back to the container ID,
                 * so don't offer a switch that silently does nothing. */
                NSString *custom = settings[@"customDeviceIdentifier"];
                if ([custom isKindOfClass:NSString.class] &&
                    [[NSUUID alloc] initWithUUIDString:custom]) {
                    PSSpecifier *useContainer = [PSSpecifier preferenceSpecifierNamed:
                        CRLocalize(@"USE_CONTAINER_IDENTIFIER")
                        target:self set:@selector(setUseContainerIdentifierAsDeviceIdentifier:specifier:)
                        get:@selector(readUseContainerIdentifierAsDeviceIdentifier:)
                        detail:NULL cell:6 edit:0];
                    [useContainer setProperty:@YES forKey:@"enabled"];
                    [useContainer setProperty:@YES forKey:@"default"];
                    [useContainer setProperty:CRPref_UseContainerIdentifierAsDeviceID
                                     forKey:@"key"];
                    [rows addObject:useContainer];
                }
            }
        }

        /* Native CranePrefs 0x11734: expose container notification
         * permission when global notifications are not disabled and the
         * application's separate registration switch is not disabled.
         * Both unset switches default to enabled. */
        id globalNotifications =
            [manager preferenceValueForKey:CRPref_NotificationsSupportEnabled];
        NSDictionary *appSettings =
            [manager applicationSettingsForApplicationWithIdentifier:
                self.applicationIdentifier];
        id separateRegistrations =
            appSettings[CRAppSetting_SeparateNotificationRegistrationsEnabled];
        if ((!globalNotifications || [globalNotifications boolValue]) &&
            (!separateRegistrations || [separateRegistrations boolValue])) {
            PSSpecifier *notificationsGroup = [PSSpecifier emptyGroupSpecifier];
            [notificationsGroup setName:CRLocalize(@"NOTIFICATIONS")];
            [notificationsGroup setProperty:CRLocalize(@"NOTIFICATIONS_FOOTER")
                                    forKey:@"footerText"];
            [rows addObject:notificationsGroup];

            PSSpecifier *allow = [PSSpecifier preferenceSpecifierNamed:
                CRLocalize(@"ALLOW_NOTIFICATIONS")
                target:self set:@selector(setContainerNotificationsAllowed:specifier:)
                get:@selector(readContainerNotificationsAllowed:)
                detail:NULL cell:6 edit:0];
            [allow setProperty:@YES forKey:@"enabled"];
            [allow setProperty:@YES forKey:@"default"];
            [allow setProperty:CRCContainer_NotificationsAllowed forKey:@"key"];
            [rows addObject:allow];
            /* The original also has Reset Notification Registration.
             * CraneManager's backend selector is still a no-op in this
             * reconstruction; do not expose an action that cannot work. */
        }

        /* CranePrefs 0x10BD4/0x10E68/0x11734: optional container editor (0x3F108).
         * Keep the read-only preview if the installed Choicy private ABI
         * cannot support the recovered callbacks. */
        if (![self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
            [self craneChoicyIntegrationAvailable]) {
            PSSpecifier *choicyGroup = [PSSpecifier emptyGroupSpecifier];
            [choicyGroup setName:CRLocalize(@"CHOICY_INTEGRATION")];
            [rows addObject:choicyGroup];

            PSSpecifier *toggle = [PSSpecifier preferenceSpecifierNamed:
                CRLocalize(@"OVERWRITE_CHOICY_CONFIGURATION")
                target:self set:@selector(setChoicyOverwriteEnabled:specifier:)
                get:@selector(readPreferenceValue:) detail:NULL cell:6 edit:0];
            [toggle setProperty:@YES forKey:@"enabled"];
            [toggle setProperty:CRCContainer_ChoicyConfigurationOverwriteEnabled
                        forKey:@"key"];
            self.choicyOverwriteToggleSpecifier = toggle;
            [rows addObject:toggle];

            Class editorClass = CRChoicyContainerEditorClass();
            PSSpecifier *preview = [PSSpecifier preferenceSpecifierNamed:
                CRLocalize(@"CHOICY_CONFIGURATION") target:self set:NULL
                get:@selector(previewStringForChoicyConfiguration:)
                detail:editorClass cell:(editorClass ? 2 : 4) edit:0];
            [preview setProperty:@YES forKey:@"enabled"];
            if (editorClass)
                [preview setDetailControllerClass:editorClass];
            [preview setProperty:CRCContainer_ChoicyConfigurationOverwrite
                         forKey:@"key"];
            [preview setProperty:self.applicationIdentifier
                         forKey:@"applicationIdentifier"];
            [preview setProperty:self.containerIdentifier
                         forKey:@"containerIdentifier"];
            self.choicyConfigurationPreviewSpecifier = preview;
            if ([settings[CRCContainer_ChoicyConfigurationOverwriteEnabled] boolValue])
                [rows addObject:preview];
        } else {
            self.choicyOverwriteToggleSpecifier = nil;
            self.choicyConfigurationPreviewSpecifier = nil;
        }
        /* Native CranePrefs 0x11520 displays size in a footer, initially
         * '(...)' and then NSByteCountFormatter once the async callback fires. */
        PSSpecifier *sizeGroup = [PSSpecifier emptyGroupSpecifier];
        self.sizeGroupSpecifier = sizeGroup;
        [rows addObject:sizeGroup];
        [self updateSizeGroupSpecifierAndReload:NO];

        /* Native CranePrefs 0x11734 only adds Browse Data if Filza's
         * URL scheme is available. The detail page resolves fresh
         * application-scoped container paths through CraneManager. */
        NSURL *filzaURL = [NSURL URLWithString:@"filza://"];
        if (filzaURL && [UIApplication.sharedApplication canOpenURL:filzaURL]) {
            PSSpecifier *browse = [PSSpecifier preferenceSpecifierNamed:
                CRLocalize(@"BROWSE_DATA") target:self set:NULL get:NULL
                detail:[CRPBrowseContainerListController class] cell:2 edit:0];
            [browse setProperty:@YES forKey:@"enabled"];
            [browse setDetailControllerClass:[CRPBrowseContainerListController class]];
            [browse setProperty:self.applicationIdentifier
                         forKey:@"applicationIdentifier"];
            [browse setProperty:self.containerIdentifier
                         forKey:@"containerIdentifier"];
            [rows addObject:browse];
        }
        self.craneContainerSpecifiers = rows;
    }
    @try { [self setValue:self.craneContainerSpecifiers forKey:@"_specifiers"]; }
    @catch (NSException *exception) {
        NSLog(@"CranePrefs: container detail backing failed: %@", exception);
    }
    if (shouldUpdateSize)
        [self updateContainerSize];
    return self.craneContainerSpecifiers;
}

/* Native CranePrefs 0x113A4/0x1148C/0x11520: calculate container size
 * asynchronously and update the existing footer on the main queue. */
- (void)updateSizeGroupSpecifierAndReload:(BOOL)reload
{
    PSSpecifier *group = self.sizeGroupSpecifier;
    if (!group)
        return;
    NSString *label = CRLocalize(@"SIZE_OF_CONTAINER");
    long long count = self.cachedSize > LLONG_MAX
        ? LLONG_MAX : (long long)self.cachedSize;
    NSString *value = self.sizeCached
        ? [NSByteCountFormatter stringFromByteCount:count countStyle:0]
        : @"(...)";
    [group setProperty:[NSString stringWithFormat:@"%@: %@", label, value]
               forKey:@"footerText"];
    if (reload)
        [self reloadSpecifier:group];
}

- (void)updateContainerSize
{
    NSString *appID = [self.applicationIdentifier copy];
    NSString *containerID = [self.containerIdentifier copy];
    if (!appID.length || !containerID.length)
        return;
    CraneManager *manager = CraneManager.sharedManager;
    /* No guessed/shared fallback if the app container cannot be resolved. */
    NSArray<NSString *> *paths = [manager pathsAssociatedToContainerWithIdentifier:containerID
                                                        ofApplicationWithIdentifier:appID];
    if (!paths.count)
        return;
    NSUInteger generation = ++self.sizeFetchGeneration;
    __weak typeof(self) weakSelf = self;
    [manager sizeOccupiedByContainerWithIdentifier:containerID
                     forApplicationWithIdentifier:appID
                              completionHandler:^(unsigned long long bytes) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf ||
                generation != strongSelf.sizeFetchGeneration ||
                ![appID isEqualToString:strongSelf.applicationIdentifier] ||
                ![containerID isEqualToString:strongSelf.containerIdentifier])
                return;
            strongSelf.cachedSize = bytes;
            strongSelf.sizeCached = YES;
            [strongSelf updateSizeGroupSpecifierAndReload:YES];
        });
    }];
}

/* Device-ID editor subset from CranePrefs 0xF8F0/0x129F0.
 * No generation of new UUIDs and no calls to the unavailable original
 * NSXPC device-ID setter. LSD consumes this exact per-container switch
 * on the next app request; it is NOT a promise of immediate app reload. */
- (id)readUseContainerIdentifierAsDeviceIdentifier:(PSSpecifier *)specifier
{
    if (![[specifier propertyForKey:@"key"]
          isEqualToString:CRPref_UseContainerIdentifierAsDeviceID])
        return @YES;
    NSDictionary *settings = [CraneManager.sharedManager
        containerSettingsForContainerWithIdentifier:self.containerIdentifier
                          ofApplicationWithIdentifier:self.applicationIdentifier];
    id use = settings[CRPref_UseContainerIdentifierAsDeviceID];
    return use ? @([use boolValue]) : @YES;
}

- (void)setUseContainerIdentifierAsDeviceIdentifier:(id)value
                                           specifier:(PSSpecifier *)specifier
{
    if (![[specifier propertyForKey:@"key"]
          isEqualToString:CRPref_UseContainerIdentifierAsDeviceID] ||
        ![value respondsToSelector:@selector(boolValue)] ||
        !self.applicationIdentifier.length || !self.containerIdentifier.length ||
        [self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return;
    CraneManager *manager = CraneManager.sharedManager;
    if (![manager applicationHasDeviceIdentifier:self.applicationIdentifier])
        return;
    NSMutableDictionary *settings = [[manager
        containerSettingsForContainerWithIdentifier:self.containerIdentifier
                          ofApplicationWithIdentifier:self.applicationIdentifier]
        mutableCopy];
    if (!settings)
        return;
    NSString *custom = settings[@"customDeviceIdentifier"];
    if (![custom isKindOfClass:NSString.class] ||
        ![[NSUUID alloc] initWithUUIDString:custom])
        return;
    id old = settings[CRPref_UseContainerIdentifierAsDeviceID];
    BOOL previous = !old || [old boolValue];
    BOOL requested = [value boolValue];
    if (previous == requested)
        return;
    settings[CRPref_UseContainerIdentifierAsDeviceID] = @(requested);
    [manager setContainerSettings:settings
        forContainerWithIdentifier:self.containerIdentifier
         ofApplicationWithIdentifier:self.applicationIdentifier];
}

/* Native 0x11734 sets default=1 on the notification permission switch.
 * The CraneSB routing hook checks the same "notificationsAllowed" key;
 * absent per-container value must therefore read as enabled. */
- (id)readContainerNotificationsAllowed:(PSSpecifier *)specifier
{
    if (![[specifier propertyForKey:@"key"]
          isEqualToString:CRCContainer_NotificationsAllowed] ||
        !self.applicationIdentifier.length || !self.containerIdentifier.length)
        return @YES;
    NSDictionary *settings = [CraneManager.sharedManager
        containerSettingsForContainerWithIdentifier:self.containerIdentifier
                          ofApplicationWithIdentifier:self.applicationIdentifier];
    id allowed = settings[CRCContainer_NotificationsAllowed];
    return allowed ? @([allowed boolValue]) : @YES;
}

- (void)setContainerNotificationsAllowed:(id)value
                               specifier:(PSSpecifier *)specifier
{
    if (![[specifier propertyForKey:@"key"]
          isEqualToString:CRCContainer_NotificationsAllowed] ||
        ![value respondsToSelector:@selector(boolValue)] ||
        !self.applicationIdentifier.length || !self.containerIdentifier.length)
        return;
    CraneManager *manager = CraneManager.sharedManager;
    NSMutableDictionary *settings = [[manager
        containerSettingsForContainerWithIdentifier:self.containerIdentifier
                          ofApplicationWithIdentifier:self.applicationIdentifier]
        mutableCopy];
    if (!settings)
        settings = [NSMutableDictionary new];
    NSNumber *allowed = @([value boolValue]);
    if ([settings[CRCContainer_NotificationsAllowed] isEqual:allowed])
        return;
    settings[CRCContainer_NotificationsAllowed] = allowed;
    [manager setContainerSettings:settings
        forContainerWithIdentifier:self.containerIdentifier
         ofApplicationWithIdentifier:self.applicationIdentifier];
}

/* ChoicyPrefs is optional; original 0x10BD4 loads its bundle before
 * testing for CHPProcessConfigurationListController. */
- (BOOL)craneChoicyIntegrationAvailable
{
    Class cls = NSClassFromString(@"CHPProcessConfigurationListController");
    if (cls)
        return YES;
    NSString *path = CRJailbreakRootPath(CR_CHOICY_PREFS_BUNDLE);
    if (![NSFileManager.defaultManager fileExistsAtPath:path])
        return NO;
    @try {
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (bundle)
            [bundle load];
    } @catch (NSException *exception) {
        NSLog(@"CranePrefs: optional Choicy bundle failed: %@", exception);
        return NO;
    }
    return NSClassFromString(@"CHPProcessConfigurationListController") != Nil;
}

- (id)readPreferenceValue:(PSSpecifier *)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key || !self.applicationIdentifier || !self.containerIdentifier)
        return nil;
    NSDictionary *settings = [CraneManager.sharedManager
        containerSettingsForContainerWithIdentifier:self.containerIdentifier
                          ofApplicationWithIdentifier:self.applicationIdentifier];
    return settings[key];
}

- (NSString *)previewStringForChoicyConfiguration:(PSSpecifier *)specifier
{
    (void)specifier;
    NSDictionary *settings = [CraneManager.sharedManager
        containerSettingsForContainerWithIdentifier:self.containerIdentifier
                          ofApplicationWithIdentifier:self.applicationIdentifier];
    id config = settings[CRCContainer_ChoicyConfigurationOverwrite];
    if (!config)
        return @"";
    SEL method = NSSelectorFromString(@"previewStringForProcessPreferences:");
    for (NSString *name in @[@"CHPListController", @"CHPApplication"]) {
        Class cls = NSClassFromString(name);
        if (cls && [cls respondsToSelector:method]) {
            @try {
                id preview = ((id (*)(id, SEL, id))objc_msgSend)(cls, method, config);
                if ([preview isKindOfClass:[NSString class]])
                    return preview;
            } @catch (NSException *exception) {
                NSLog(@"CranePrefs: Choicy preview rejected: %@", exception);
            }
        }
    }
    return @"";
}

/* Native 0x10CD0: toggle row persistence and immediate preview visibility. */
- (void)setChoicyOverwriteEnabled:(id)value specifier:(PSSpecifier *)specifier
{
    if (![value respondsToSelector:@selector(boolValue)] ||
        ![[specifier propertyForKey:@"key"]
            isEqualToString:CRCContainer_ChoicyConfigurationOverwriteEnabled] ||
        !self.applicationIdentifier.length || !self.containerIdentifier.length ||
        [self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] ||
        ![[CraneManager.sharedManager
            containerIdentifiersOfApplicationWithIdentifier:self.applicationIdentifier]
            containsObject:self.containerIdentifier])
        return;
    CraneManager *manager = CraneManager.sharedManager;
    NSMutableDictionary *settings = [[manager
        containerSettingsForContainerWithIdentifier:self.containerIdentifier
                          ofApplicationWithIdentifier:self.applicationIdentifier]
        mutableCopy];
    if (!settings)
        return;
    settings[CRCContainer_ChoicyConfigurationOverwriteEnabled] = @([value boolValue]);
    [manager setContainerSettings:settings
        forContainerWithIdentifier:self.containerIdentifier
         ofApplicationWithIdentifier:self.applicationIdentifier];

    PSSpecifier *preview = self.choicyConfigurationPreviewSpecifier;
    NSArray *current = self.craneContainerSpecifiers;
    if (!preview || !current.count)
        return;
    BOOL visible = [current containsObject:preview];
    NSMutableArray *updated = [current mutableCopy];
    if ([value boolValue] && !visible &&
        [self respondsToSelector:@selector(insertSpecifier:afterSpecifier:animated:)]) {
        [self insertSpecifier:preview afterSpecifier:specifier animated:YES];
        NSUInteger index = [updated indexOfObject:specifier];
        if (index != NSNotFound)
            [updated insertObject:preview atIndex:index + 1];
    } else if (![value boolValue] && visible &&
               [self respondsToSelector:@selector(removeSpecifier:animated:)]) {
        [self removeSpecifier:preview animated:YES];
        [updated removeObject:preview];
    }
    self.craneContainerSpecifiers = [updated copy];
}

- (void)makeActiveContainer
{
    if (!self.applicationIdentifier.length || !self.containerIdentifier.length)
        return;
    CraneManager *manager = CraneManager.sharedManager;
    if (![self.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER] &&
        ![[manager containerIdentifiersOfApplicationWithIdentifier:self.applicationIdentifier]
            containsObject:self.containerIdentifier])
        return;
    [manager setActiveContainerIdentifier:self.containerIdentifier
        forApplicationWithIdentifier:self.applicationIdentifier];
    NSLog(@"CranePrefs: container detail active app=%@ id=%@",
          self.applicationIdentifier, self.containerIdentifier);
    [self scheduleContainerConfigurationReload];
}

- (void)renameContainer
{
    if (!self.applicationIdentifier.length || !self.containerIdentifier.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CRLocalize(@"RENAME")
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        NSDictionary *settings = [CraneManager.sharedManager containerSettingsForContainerWithIdentifier:
            self.containerIdentifier ofApplicationWithIdentifier:self.applicationIdentifier];
        field.text = settings[CRCContainer_Name];
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"CANCEL")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"RENAME")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        CraneManager *manager = CraneManager.sharedManager;
        NSMutableDictionary *settings = [[manager containerSettingsForContainerWithIdentifier:
            strongSelf.containerIdentifier ofApplicationWithIdentifier:strongSelf.applicationIdentifier] mutableCopy];
        if (![[manager containerIdentifiersOfApplicationWithIdentifier:strongSelf.applicationIdentifier]
            containsObject:strongSelf.containerIdentifier] &&
            ![strongSelf.containerIdentifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
            return;
        settings[CRCContainer_Name] = name;
        [manager setContainerSettings:settings forContainerWithIdentifier:strongSelf.containerIdentifier
            ofApplicationWithIdentifier:strongSelf.applicationIdentifier];
        [strongSelf scheduleContainerConfigurationReload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end

/* Minimal APPLICATIONS list for the recovered PSLinkListCell entry. The
 * original uses a custom app-list class; enumerate installed proxies at
 * runtime instead of linking unavailable private SDK symbols. */
@class CRPApplicationConfigurationListController;
@interface CRPApplicationListSubcontrollerController : PSListController
@property (nonatomic, strong) NSArray *craneAppSpecifiers;
@end

@implementation CRPApplicationListSubcontrollerController

- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated
{
    /* PSListController needs its backing before superclass layout runs. */
    [self specifiers];
    [super viewWillAppear:animated];
}

- (id)specifiers
{
    if (!self.craneAppSpecifiers) {
        NSMutableArray *rows = [NSMutableArray new];
        Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
        SEL defaultSelector = NSSelectorFromString(@"defaultWorkspace");
        id workspace = workspaceClass &&
            [workspaceClass respondsToSelector:defaultSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(workspaceClass, defaultSelector) : nil;
        SEL applicationsSelector = NSSelectorFromString(@"allApplications");
        NSArray *applications = workspace &&
            [workspace respondsToSelector:applicationsSelector]
            ? ((id (*)(id, SEL))objc_msgSend)(workspace, applicationsSelector) : nil;
        for (id app in applications) {
            NSString *identifier = nil;
            NSString *name = nil;
            @try {
                identifier = [app valueForKey:@"bundleIdentifier"];
                name = [app valueForKey:@"localizedName"];
            } @catch (__unused NSException *exception) {
                continue;
            }
            if (![identifier isKindOfClass:NSString.class] || !identifier.length)
                continue;
            if (![name isKindOfClass:NSString.class] || !name.length)
                name = identifier;
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:name
                target:self set:NULL get:NULL
                detail:NSClassFromString(@"CRPApplicationConfigurationListController")
                cell:2 edit:0];
            [row setProperty:identifier forKey:@"crane_applicationIdentifier"];
            [rows addObject:row];
        }
        [rows sortUsingComparator:^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) {
            return [a.name localizedCaseInsensitiveCompare:b.name];
        }];
        /* PSListController needs a group before its first visible row. */
        [rows insertObject:[PSSpecifier emptyGroupSpecifier] atIndex:0];
        self.craneAppSpecifiers = rows;
        @try {
            [self setValue:rows forKey:@"_specifiers"];
        } @catch (NSException *exception) {
            NSLog(@"CranePrefs: application list backing failed: %@", exception);
        }
        NSLog(@"CranePrefs: APPLICATIONS list count=%lu",
              (unsigned long)rows.count);
    }
    @try { [self setValue:self.craneAppSpecifiers forKey:@"_specifiers"]; }
    @catch (NSException *exception) { NSLog(@"CranePrefs: list backing refresh failed: %@", exception); }
    return self.craneAppSpecifiers;
}
@end

/* ------------------------------------------------------------------------- */
/* CRPApplicationConfigurationListController                                  */
/* ------------------------------------------------------------------------- */

/* Named by Root.plist (`detail` on the APPLICATIONS row and
 * `subcontrollerClass`) and confirmed by __objc_classlist at 0x595A0 with 43
 * instance methods. The specifier construction below mirrors the recovered
 * 0x8D00 (specifiers) exactly, including which rows are conditional on
 * which preference values. */
@interface CRPApplicationConfigurationListController : PSListController
@property (nonatomic, copy) NSString *applicationIdentifier;
@property (nonatomic, strong) NSMutableDictionary *applicationSettings;
@property (nonatomic, strong) PSSpecifier *gameCenterSupportEnabledSpecifier;
@property (nonatomic, strong) NSArray *craneConfigurationSpecifiers;
@property (nonatomic, assign) BOOL craneDidCompleteFirstLayout;
@property (nonatomic, assign) BOOL craneReloadScheduled;
- (void)scheduleConfigurationReload;
@end

@implementation CRPApplicationConfigurationListController

- (void)dealloc
{
    [CraneManager.sharedManager removeObserver:self];
}

- (void)scheduleConfigurationReload
{
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self scheduleConfigurationReload];
        });
        return;
    }
    if (self.craneReloadScheduled)
        return;
    self.craneReloadScheduled = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.craneReloadScheduled = NO;
        [self loadApplicationSettings];
        self.craneConfigurationSpecifiers = nil;
        @try { [self setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
        [self reloadSpecifiers];
    });
}

- (void)didChangeSettingsForApplicationWithIdentifier:(NSString *)appID
{
    if ([appID isEqualToString:self.applicationIdentifier])
        [self scheduleConfigurationReload];
}

- (void)didChangeContainersOfApplicationWithIdentifier:(NSString *)appID
{
    if ([appID isEqualToString:self.applicationIdentifier])
        [self scheduleConfigurationReload];
}

/* Rebuild from the current registry after selection/action dispatch finishes.
 * Avoid animating replacement rows against our independently rebuilt cache. */
- (void)reloadContainerSpecifiers
{
    [self scheduleConfigurationReload];
}

/* CranePrefs 0x9D3C: refresh the Active Container specifier's data source. */
- (void)reloadActiveContainer
{
    PSSpecifier *active = nil;
    for (PSSpecifier *row in self.craneConfigurationSpecifiers) {
        if ([[row propertyForKey:@"key"] isEqualToString:CRCContainer_ActiveContainer]) {
            active = row;
            break;
        }
    }
    if (!active) return;
    [active setTitleDictionary:nil];
    [active setShortTitleDictionary:nil];
    [active setValues:nil];
    [active loadValuesAndTitlesFromDataSource];
    [self reloadSpecifier:active];
}

- (void)viewDidLoad
{
    [self specifiers];
    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated
{
    [self specifiers];
    [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    /* A freshly pushed Preferences detail controller can complete its initial
     * table layout before the incoming app-specific specifiers are attached. */
    if (!self.craneDidCompleteFirstLayout && self.applicationIdentifier.length) {
        self.craneDidCompleteFirstLayout = YES;
        [self specifiers];
        [self reloadSpecifiers];
        NSLog(@"CranePrefs: first layout refreshed app=%@ rows=%lu",
              self.applicationIdentifier, (unsigned long)self.craneConfigurationSpecifiers.count);
    }
}

- (void)setSpecifier:(PSSpecifier *)specifier
{
    NSString *identifier = [specifier propertyForKey:@"crane_applicationIdentifier"];
    if (identifier.length && ![identifier isEqualToString:self.applicationIdentifier]) {
        self.applicationIdentifier = identifier;
        self.craneDidCompleteFirstLayout = NO;
        self.craneConfigurationSpecifiers = nil;
        @try { [self setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
        [self loadApplicationSettings];
    }
    [super setSpecifier:specifier];
}

- (id)init
{
    if ((self = [super init])) {
        [CraneManager.sharedManager addObserver:self];
        _applicationSettings = [NSMutableDictionary new];
        [self loadApplicationSettings];
    }
    return self;
}

- (void)loadApplicationSettings
{
    NSDictionary *settings =
        [CraneManager.sharedManager applicationSettingsForApplicationWithIdentifier:
            self.applicationIdentifier];
    self.applicationSettings = [settings mutableCopy] ?: [NSMutableDictionary new];
}

- (id)readPreferenceValueForKey:(NSString *)key
{
    return self.applicationSettings[key];
}

- (void)setPreferenceValue:(id)value key:(NSString *)key
{
    /* CONFIRMED_STATIC: the original removes and re-adds itself as a
     * CraneManager observer around the write (CranePrefs 0xA7EC). */
    CraneManager *manager = CraneManager.sharedManager;
    [manager removeObserver:self];
    if (!key.length || !self.applicationIdentifier.length) {
        NSLog(@"CranePrefs: refusing preference write without key/app ID (key=%@ app=%@)",
              key, self.applicationIdentifier);
        [manager addObserver:self];
        return;
    }
    NSLog(@"CranePrefs: write preference app=%@ key=%@ value=%@",
          self.applicationIdentifier, key, value);
    if (value)
        self.applicationSettings[key] = value;
    else
        [self.applicationSettings removeObjectForKey:key];
    [manager setApplicationSettings:[self.applicationSettings copy]
        forApplicationWithIdentifier:self.applicationIdentifier];
    [manager addObserver:self];
}

- (id)containersForApplication
{
    return self.applicationSettings[CRAppSetting_Containers];
}

/* CranePrefs 0x8D00 values/titles data sources for Active Container. */
- (NSArray *)containerIdentifersForApplication
{
    NSMutableArray *identifiers = [NSMutableArray arrayWithObject:CR_DEFAULT_CONTAINER_IDENTIFIER];
    for (NSString *identifier in [CraneManager.sharedManager containerIdentifiersOfApplicationWithIdentifier:self.applicationIdentifier]) {
        if (![identifiers containsObject:identifier])
            [identifiers addObject:identifier];
    }
    return identifiers;
}

- (NSArray *)containerNamesForApplication
{
    NSMutableArray *names = [NSMutableArray arrayWithObject:@"Default"];
    CraneManager *manager = CraneManager.sharedManager;
    for (NSString *identifier in [manager containerIdentifiersOfApplicationWithIdentifier:self.applicationIdentifier]) {
        if ([identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
            continue;
        NSString *name = [manager displayNameForContainerWithIdentifier:identifier
            ofApplicationWithIdentifier:self.applicationIdentifier shouldUseShortVersion:NO];
        [names addObject:name.length ? name : identifier];
    }
    return names;
}

- (id)specifiers
{
    if (self.craneConfigurationSpecifiers) {
        @try { [self setValue:self.craneConfigurationSpecifiers forKey:@"_specifiers"]; }
        @catch (NSException *exception) { NSLog(@"CranePrefs: detail backing refresh failed: %@", exception); }
        return self.craneConfigurationSpecifiers;
    }
    NSMutableArray *specifiers = [NSMutableArray new];

    /* Our PSListController base needs an explicit initial section. */
    [specifiers addObject:[PSSpecifier emptyGroupSpecifier]];

    /* Active Container */
    PSSpecifier *active = [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"ACTIVE_CONTAINER")
                                                           target:self
                                                             set:@selector(setActiveContainer:specifier:)
                                                             get:@selector(readActiveContainer:)
                                                          detail:CRPActiveContainerListItemsController.class
                                                            cell:2
                                                            edit:0];
    [active setProperty:CRCContainer_ActiveContainer forKey:@"key"];
    [active setProperty:self.applicationIdentifier forKey:@"crane_applicationIdentifier"];
    [active setDetailControllerClass:CRPActiveContainerListItemsController.class];
    /* Original CranePrefs 0x8D00 provides data sources to the detail pane. */
    [active setProperty:@"containerIdentifersForApplication" forKey:@"valuesDataSource"];
    [active setProperty:@"containerNamesForApplication" forKey:@"titlesDataSource"];
    [active setProperty:self.applicationIdentifier forKey:@"applicationIdentifier"];
    [active setProperty:@YES forKey:@"enabled"];
    [specifiers addObject:active];

    /* Always Ask on App-Launch */
    PSSpecifier *ask = [PSSpecifier preferenceSpecifierNamed:
                        CRLocalize(@"ALWAYS_ASK_ON_APP_LAUNCH")
                                                     target:self
                                                      set:@selector(setPreferenceValue:specifier:)
                                                      get:@selector(readPreferenceValue:)
                                                   detail:NULL cell:6 edit:0];
    [ask setProperty:@YES forKey:@"enabled"];
    [ask setProperty:CRAppSetting_AlwaysAskBeforeLaunchEnabled forKey:@"key"];
    [ask setProperty:@YES forKey:@"default"];
    [specifiers addObject:ask];

    /* CONTAINERS group + per-container rows + Add button */
    PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
    [group setName:CRLocalize(@"CONTAINERS")];
    [specifiers addObject:group];

    CraneManager *manager = CraneManager.sharedManager;
    for (NSString *identifier in
         [manager containerIdentifiersOfApplicationWithIdentifier:self.applicationIdentifier]) {
        PSSpecifier *row =
            [PSSpecifier preferenceSpecifierNamed:
                [manager displayNameForContainerWithIdentifier:identifier
                                  ofApplicationWithIdentifier:self.applicationIdentifier
                                       shouldUseShortVersion:NO]
                                                 target:self
                                                   set:NULL
                                                   get:NULL
                                                detail:NULL
                                                  cell:2
                                                  edit:0];
        [row setDetailControllerClass:CRPContainerConfigurationListController.class];
        [row setProperty:self.applicationIdentifier forKey:@"applicationIdentifier"];
        [row setProperty:identifier forKey:@"containerIdentifier"];
        [row setProperty:identifier forKey:@"crane_containerIdentifier"];
        [specifiers addObject:row];
    }

    PSSpecifier *add = [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"ADD")
                                                       target:self set:NULL get:NULL
                                                    detail:NULL cell:13 edit:0];
    [add setProperty:@YES forKey:@"enabled"];
    [add setProperty:@YES forKey:@"crane_addContainer"];
    [add setButtonAction:@selector(addButtonPressed)];
    [specifiers addObject:add];

    /* Separate Notification Registrations - only when notificationsSupportEnabled
     * is unset OR true. This exact condition is in CranePrefs 0x8D00. */
    id notificationsSupport = [CraneManager.sharedManager
                               preferenceValueForKey:CRPref_NotificationsSupportEnabled];
    if (!notificationsSupport || [notificationsSupport boolValue]) {
        PSSpecifier *footer = [PSSpecifier emptyGroupSpecifier];
        [footer setProperty:CRLocalize(@"SEPARATE_NOTIFICATION_REGISTRATIONS_FOOTER")
                     forKey:@"footerText"];
        [specifiers addObject:footer];

        PSSpecifier *sep = [PSSpecifier preferenceSpecifierNamed:
                             CRLocalize(@"SEPARATE_NOTIFICATION_REGISTRATIONS")
                                                     target:self
                                                       set:@selector(setSeparateNotificationRegistrationsValue:specifier:)
                                                       get:@selector(readPreferenceValue:)
                                                    detail:NULL cell:6 edit:0];
        [sep setProperty:@YES forKey:@"enabled"];
        [sep setProperty:@YES forKey:@"default"];
        [sep setProperty:CRAppSetting_SeparateNotificationRegistrationsEnabled forKey:@"key"];
        [specifiers addObject:sep];
    }

    /* Separate System Accounts */
    PSSpecifier *accountsFooter = [PSSpecifier emptyGroupSpecifier];
    [accountsFooter setProperty:CRLocalize(@"SEPARATE_SYSTEM_ACCOUNTS_FOOTER")
                        forKey:@"footerText"];
    [specifiers addObject:accountsFooter];

    PSSpecifier *accounts =
        [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"SEPARATE_SYSTEM_ACCOUNTS")
                                         target:self
                                           set:@selector(setSeparateSystemAccountsValue:specifier:)
                                           get:@selector(readPreferenceValue:)
                                        detail:NULL cell:6 edit:0];
    [accounts setProperty:@YES forKey:@"enabled"];
    [accounts setProperty:CRAppSetting_SeparateSystemAccountsEnabled forKey:@"key"];
    [specifiers addObject:accounts];

    /* Game Center Support - the specifier is built unconditionally but only
     * appended when Separate System Accounts is on. That asymmetry is in the
     * original (0x8D00) and is reproduced here. */
    PSSpecifier *gameCenter =
        [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"GAME_CENTER_SUPPORT")
                                         target:self
                                           set:@selector(setGameCenterSupportValue:specifier:)
                                           get:@selector(readPreferenceValue:)
                                        detail:NULL cell:6 edit:0];
    [gameCenter setProperty:@YES forKey:@"enabled"];
    [gameCenter setProperty:CRAppSetting_GameCenterSupportEnabled forKey:@"key"];
    self.gameCenterSupportEnabledSpecifier = gameCenter;
    if ([self.applicationSettings[CRAppSetting_SeparateSystemAccountsEnabled] boolValue])
        [specifiers addObject:gameCenter];

    /* Container Protection */
    PSSpecifier *protectionFooter = [PSSpecifier emptyGroupSpecifier];
    [protectionFooter setProperty:CRLocalize(@"CONTAINER_PROTECTION_FOOTER")
                           forKey:@"footerText"];
    [specifiers addObject:protectionFooter];

    PSSpecifier *protection =
        [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"CONTAINER_PROTECTION")
                                         target:self
                                           set:@selector(setPreferenceValue:specifier:)
                                           get:@selector(readPreferenceValue:)
                                        detail:NULL cell:6 edit:0];
    [protection setProperty:@YES forKey:@"enabled"];
    [protection setProperty:CRAppSetting_ContainerProtectionEnabled forKey:@"key"];
    [specifiers addObject:protection];

    /* Prevent Sandbox Lookups */
    PSSpecifier *spoofFooter = [PSSpecifier emptyGroupSpecifier];
    [spoofFooter setProperty:CRLocalize(@"PREVENT_SANDBOX_LOOKUPS_FOOTER")
                      forKey:@"footerText"];
    [specifiers addObject:spoofFooter];

    PSSpecifier *spoof =
        [PSSpecifier preferenceSpecifierNamed:CRLocalize(@"PREVENT_SANDBOX_LOOKUPS")
                                         target:self
                                           set:@selector(setPreferenceValue:specifier:)
                                           get:@selector(readPreferenceValue:)
                                        detail:NULL cell:6 edit:0];
    [spoof setProperty:@YES forKey:@"enabled"];
    [spoof setProperty:CRAppSetting_SpoofSandboxLookupsEnabled forKey:@"key"];
    [specifiers addObject:spoof];

    self.craneConfigurationSpecifiers = specifiers;
    @try {
        [self setValue:specifiers forKey:@"_specifiers"];
    } @catch (NSException *exception) {
        NSLog(@"CranePrefs: app configuration backing failed: %@", exception);
    }
    NSString *firstLabel = nil;
    for (PSSpecifier *row in specifiers) {
        if (row.name.length) {
            firstLabel = row.name;
            break;
        }
    }
    NSLog(@"CranePrefs: app configuration %@ specifier count=%lu firstLabel=%@",
          self.applicationIdentifier, (unsigned long)specifiers.count,
          firstLabel ?: @"(none)");
    return self.craneConfigurationSpecifiers;
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier
{
    [self setPreferenceValue:value key:[specifier propertyForKey:@"key"]];
}

- (id)readPreferenceValue:(id)specifier
{
    NSString *key = [specifier propertyForKey:@"key"];
    id value = [self readPreferenceValueForKey:key];
    if (!value)
        value = [specifier propertyForKey:@"default"];
    NSLog(@"CranePrefs: read app=%@ key=%@ value=%@", self.applicationIdentifier, key, value);
    return value;
}

- (void)setSeparateNotificationRegistrationsValue:(id)value specifier:(id)specifier
{
    /* CONFIRMED_STATIC: turning the switch OFF unregisters notifications for
     * every non-DEFAULT container and then reloads the app
     * (CranePrefs 0xA224). */
    if (![value boolValue]) {
        CraneManager *manager = CraneManager.sharedManager;
        for (NSDictionary *container in [self containersForApplication]) {
            NSString *identifier = container[CRCContainer_Identifier];
            if ([identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
                continue;
            [manager unregisterFromNotificationsIfNeededForContainerIdentifier:identifier
                                                 ofApplicationWithIdentifier:
                                                     self.applicationIdentifier];
        }
        [manager reloadApplicationWithIdentifier:self.applicationIdentifier];
    }
    [self setPreferenceValue:value specifier:specifier];
}

- (void)setSeparateSystemAccountsValue:(id)value specifier:(id)specifier
{
    /* Native CranePrefs 0xA4B8 inserts/removes the Game Center row
     * after the System Accounts switch, then reloads the app when a
     * non-DEFAULT container is active. Keep our cached rows consistent. */
    [self setPreferenceValue:value specifier:specifier];
    PSSpecifier *gameCenter = self.gameCenterSupportEnabledSpecifier;
    if (gameCenter) {
        NSArray *current = self.craneConfigurationSpecifiers;
        BOOL visible = [current containsObject:gameCenter];
        BOOL shouldShow = [value boolValue];
        if (shouldShow && !visible &&
            [self respondsToSelector:@selector(insertSpecifier:afterSpecifier:animated:)]) {
            [self insertSpecifier:gameCenter afterSpecifier:specifier animated:YES];
            NSMutableArray *updated = [current mutableCopy];
            NSUInteger index = [updated indexOfObject:specifier];
            if (index != NSNotFound)
                [updated insertObject:gameCenter atIndex:index + 1];
            self.craneConfigurationSpecifiers = [updated copy];
        } else if (!shouldShow && visible &&
                   [self respondsToSelector:@selector(removeSpecifier:animated:)]) {
            [self removeSpecifier:gameCenter animated:YES];
            NSMutableArray *updated = [current mutableCopy];
            [updated removeObject:gameCenter];
            self.craneConfigurationSpecifiers = [updated copy];
        }
    }
    CraneManager *manager = CraneManager.sharedManager;
    NSString *active = [manager activeContainerIdentifierForApplicationWithIdentifier:
        self.applicationIdentifier];
    if (![active isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        [manager reloadApplicationWithIdentifier:self.applicationIdentifier];
}

- (void)setGameCenterSupportValue:(id)value specifier:(id)specifier
{
    /* Native CranePrefs 0xA670 triggers Game Center state refresh after
     * saving, and reloads the app when support is switched off. The
     * manager's global Game Center refresh remains a reconstruction stub. */
    [self setPreferenceValue:value specifier:specifier];
    CraneManager *manager = CraneManager.sharedManager;
    [manager gameCenter_reloadExceptApplicationWithIdentifier:nil];
    if (![value boolValue])
        [manager reloadApplicationWithIdentifier:self.applicationIdentifier];
}

- (void)setActiveContainer:(id)value specifier:(id)specifier
{
    if ([value isKindOfClass:NSString.class]) {
        [CraneManager.sharedManager setActiveContainerIdentifier:value
            forApplicationWithIdentifier:self.applicationIdentifier];
        [self loadApplicationSettings];
    }
}

- (id)readActiveContainer:(id)specifier
{
    return [CraneManager.sharedManager activeContainerIdentifierForApplicationWithIdentifier:
        self.applicationIdentifier];
}

- (void)addButtonPressed
{
    if (!self.applicationIdentifier.length)
        return;
    /* CranePrefs 0x9848/0x9A80: ask for a name before creating. */
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CRLocalize(@"NEW_CONTAINER")
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = CRLocalize(@"NEW_CONTAINER_NAME");
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"CANCEL")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"ADD")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf.applicationIdentifier.length)
            return;
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length)
            name = CRLocalize(@"NEW_CONTAINER");
        CraneManager *manager = CraneManager.sharedManager;
        [manager removeObserver:strongSelf];
        NSString *identifier = [manager createNewContainerWithName:name
            forApplicationWithIdentifier:strongSelf.applicationIdentifier];
        [strongSelf loadApplicationSettings];
        [manager addObserver:strongSelf];
        NSLog(@"CranePrefs: created container app=%@ id=%@", strongSelf.applicationIdentifier, identifier);
        [strongSelf scheduleConfigurationReload];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end