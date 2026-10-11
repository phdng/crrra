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
 * table cells, the backup/restore flows and the Choicy pane are NOT reproduced
 * - see final/KNOWN_DIFFERENCES.md.
 */

#import <UIKit/UIKit.h>
#import <objc/message.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"

/* AltList and the Preferences framework are linked by the original. They are
 * declared minimally here so the file can be read without their headers; the
 * build genuinely requires both frameworks (see the Makefile). */
@interface PSViewController : UIViewController
@end

@interface PSListController : PSViewController
- (id)specifiers;
- (void)setSpecifier:(id)specifier;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (id)specifierAtIndex:(NSUInteger)index;
- (id)indexForIndexPath:(NSIndexPath *)indexPath;
- (void)reloadSpecifier:(id)specifier;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(id)specifier;
- (void)setPreferenceValue:(id)value specifier:(id)specifier;
- (void)reloadSpecifierAtIndex:(NSUInteger)index;
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
        self.craneRootSpecifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
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

/* The Preferences navigation stack expects a PSListController detail, not
 * an unrelated UITableViewController. */
@interface CRPActiveContainerListItemsController : PSListController
@property (nonatomic, copy) NSString *applicationIdentifier;
@property (nonatomic, strong) NSArray *craneActiveSpecifiers;
@end

@implementation CRPActiveContainerListItemsController

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

- (void)setSpecifier:(PSSpecifier *)specifier
{
    NSString *identifier = [specifier propertyForKey:@"crane_applicationIdentifier"];
    if (!identifier.length)
        identifier = [specifier propertyForKey:@"applicationIdentifier"];
    if (identifier.length && ![identifier isEqualToString:self.applicationIdentifier]) {
        self.applicationIdentifier = identifier;
        self.craneActiveSpecifiers = nil;
        @try { [self setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
    }
    [super setSpecifier:specifier];
}

- (id)specifiers
{
    if (!self.craneActiveSpecifiers) {
        CraneManager *manager = CraneManager.sharedManager;
        NSMutableArray *rows = [NSMutableArray new];
        NSMutableArray *identifiers = [[manager containerIdentifiersOfApplicationWithIdentifier:
                                        self.applicationIdentifier] mutableCopy] ?: [NSMutableArray new];
        if (![identifiers containsObject:CR_DEFAULT_CONTAINER_IDENTIFIER])
            [identifiers insertObject:CR_DEFAULT_CONTAINER_IDENTIFIER atIndex:0];
        NSString *active = [manager activeContainerIdentifierForApplicationWithIdentifier:
                             self.applicationIdentifier];
        for (NSString *identifier in identifiers) {
            NSString *name = [identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER]
                ? @"Default" : [manager displayNameForContainerWithIdentifier:identifier
                               ofApplicationWithIdentifier:self.applicationIdentifier
                                    shouldUseShortVersion:NO];
            PSSpecifier *row = [PSSpecifier preferenceSpecifierNamed:
                (name.length ? name : identifier) target:self set:NULL get:NULL
                detail:NULL cell:2 edit:0];
            [row setProperty:identifier forKey:@"crane_containerIdentifier"];
            [row setName:[NSString stringWithFormat:@"%@%@",
                [active isEqualToString:identifier] ? @"✓ " : @"", name ?: identifier]];
            [rows addObject:row];
        }
        self.craneActiveSpecifiers = rows;
        @try {
            [self setValue:rows forKey:@"_specifiers"];
        } @catch (NSException *exception) {
            NSLog(@"CranePrefs: Active Container backing failed: %@", exception);
        }
        NSLog(@"CranePrefs: Active Container app=%@ rows=%lu",
              self.applicationIdentifier, (unsigned long)rows.count);
    }
    @try { [self setValue:self.craneActiveSpecifiers forKey:@"_specifiers"]; }
    @catch (NSException *exception) { NSLog(@"CranePrefs: active backing refresh failed: %@", exception); }
    return self.craneActiveSpecifiers;
}

/* CranePrefs 0x74D8 selects by table row and checks biometric protection. */
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < 0 || (NSUInteger)indexPath.row >= self.craneActiveSpecifiers.count)
        return;
    PSSpecifier *specifier = self.craneActiveSpecifiers[(NSUInteger)indexPath.row];
    NSString *identifier = [specifier propertyForKey:@"crane_containerIdentifier"];
    if (!identifier.length || !self.applicationIdentifier.length)
        return;
    CraneManager *manager = CraneManager.sharedManager;
    NSDictionary *settings = [manager containerSettingsForContainerWithIdentifier:identifier
        ofApplicationWithIdentifier:self.applicationIdentifier];
    __weak typeof(self) weakSelf = self;
    void (^selectContainer)(void) = ^{
        [manager setActiveContainerIdentifier:identifier
            forApplicationWithIdentifier:weakSelf.applicationIdentifier];
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.craneActiveSpecifiers = nil;
            @try { [strongSelf setValue:nil forKey:@"_specifiers"]; }
            @catch (__unused NSException *exception) {}
            [strongSelf specifiers];
            [strongSelf reloadSpecifiers];
        });
    };
    NSLog(@"CranePrefs: select active container app=%@ id=%@ biometric=%@",
          self.applicationIdentifier, identifier,
          [settings[@"requireBiometricAuthentication"] boolValue] ? @"YES" : @"NO");
    if ([settings[@"requireBiometricAuthentication"] boolValue]) {
        NSString *reason = [NSString stringWithFormat:CRLocalize(@"SET_ACTIVE_CONTAINER_DESCRIPTION"),
            specifier.name ?: identifier];
        CRRequestAuthentication(reason, selectContainer);
    } else {
        selectContainer();
    }
}
@end

/* Initial container detail controller reconstructed from CranePrefs 0x8920,
 * 0xEF38, 0xF0EC and 0xF268. Advanced groups remain unsupported. */
@interface CRPContainerConfigurationListController : PSListController
@property (nonatomic, copy) NSString *applicationIdentifier;
@property (nonatomic, copy) NSString *containerIdentifier;
@property (nonatomic, strong) NSArray *craneContainerSpecifiers;
@end

@implementation CRPContainerConfigurationListController
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

- (void)setSpecifier:(PSSpecifier *)specifier
{
    NSString *appID = [specifier propertyForKey:@"applicationIdentifier"];
    NSString *containerID = [specifier propertyForKey:@"containerIdentifier"];
    if (![appID isEqualToString:self.applicationIdentifier] ||
        ![containerID isEqualToString:self.containerIdentifier]) {
        self.applicationIdentifier = appID;
        self.containerIdentifier = containerID;
        self.craneContainerSpecifiers = nil;
        @try { [self setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
    }
    [super setSpecifier:specifier];
}

- (id)specifiers
{
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
            (isActive ? @"✓ Active Container" : @"Set as Active Container")
            target:self set:NULL get:NULL detail:NULL cell:13 edit:0];
        [active setButtonAction:@selector(makeActiveContainer)];
        [rows addObject:active];
        PSSpecifier *rename = [PSSpecifier preferenceSpecifierNamed:@"Rename Container"
            target:self set:NULL get:NULL detail:NULL cell:13 edit:0];
        [rename setButtonAction:@selector(renameContainer)];
        [rows addObject:rename];
        self.craneContainerSpecifiers = rows;
    }
    @try { [self setValue:self.craneContainerSpecifiers forKey:@"_specifiers"]; }
    @catch (NSException *exception) {
        NSLog(@"CranePrefs: container detail backing failed: %@", exception);
    }
    return self.craneContainerSpecifiers;
}

- (void)makeActiveContainer
{
    if (!self.applicationIdentifier.length || !self.containerIdentifier.length) return;
    [CraneManager.sharedManager setActiveContainerIdentifier:self.containerIdentifier
        forApplicationWithIdentifier:self.applicationIdentifier];
    NSLog(@"CranePrefs: container detail active app=%@ id=%@",
          self.applicationIdentifier, self.containerIdentifier);
    self.craneContainerSpecifiers = nil;
    @try { [self setValue:nil forKey:@"_specifiers"]; }
    @catch (__unused NSException *exception) {}
    [self specifiers];
    [self reloadSpecifiers];
}

- (void)renameContainer
{
    if (!self.applicationIdentifier.length || !self.containerIdentifier.length) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Rename Container"
        message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        NSDictionary *settings = [CraneManager.sharedManager containerSettingsForContainerWithIdentifier:
            self.containerIdentifier ofApplicationWithIdentifier:self.applicationIdentifier];
        field.text = settings[CRCContainer_Name];
    }];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"CANCEL")
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:CRLocalize(@"SAVE")
        style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *name = [alert.textFields.firstObject.text stringByTrimmingCharactersInSet:
            NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!name.length) return;
        CraneManager *manager = CraneManager.sharedManager;
        NSMutableDictionary *settings = [[manager containerSettingsForContainerWithIdentifier:
            strongSelf.containerIdentifier ofApplicationWithIdentifier:strongSelf.applicationIdentifier] mutableCopy];
        settings[CRCContainer_Name] = name;
        [manager setContainerSettings:settings forContainerWithIdentifier:strongSelf.containerIdentifier
            ofApplicationWithIdentifier:strongSelf.applicationIdentifier];
        strongSelf.craneContainerSpecifiers = nil;
        @try { [strongSelf setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
        [strongSelf specifiers];
        [strongSelf reloadSpecifiers];
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
@end

@implementation CRPApplicationConfigurationListController

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
- (void)setSpecifier:(PSSpecifier *)specifier
{
    NSString *identifier = [specifier propertyForKey:@"crane_applicationIdentifier"];
    if (identifier.length && ![identifier isEqualToString:self.applicationIdentifier]) {
        self.applicationIdentifier = identifier;
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
    NSLog(@"CranePrefs: app configuration %@ specifier count=%lu firstLabel=%@",
          self.applicationIdentifier, (unsigned long)specifiers.count,
          specifiers.count ? ((PSSpecifier *)specifiers.firstObject).name : @"(none)");
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
    [self setPreferenceValue:value specifier:specifier];
    /* Enabling system accounts invalidates the Game Center specifier, which is
     * why the original caches it in an ivar. */
    if (self.gameCenterSupportEnabledSpecifier &&
        [self.craneConfigurationSpecifiers containsObject:self.gameCenterSupportEnabledSpecifier])
        [self reloadSpecifier:self.gameCenterSupportEnabledSpecifier];
}

- (void)setGameCenterSupportValue:(id)value specifier:(id)specifier
{
    [self setPreferenceValue:value specifier:specifier];
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:CRLocalize(@"ADD_CONTAINER")
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
        strongSelf.craneConfigurationSpecifiers = nil;
        @try { [strongSelf setValue:nil forKey:@"_specifiers"]; }
        @catch (__unused NSException *exception) {}
        [strongSelf specifiers];
        [strongSelf reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end