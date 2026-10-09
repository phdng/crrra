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
- (id)specifierAtIndex:(NSUInteger)index;
- (id)indexForIndexPath:(NSIndexPath *)indexPath;
- (void)reloadSpecifier:(id)specifier;
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
- (void)setName:(NSString *)name;
- (void)setButtonAction:(SEL)action;
@end

/* ------------------------------------------------------------------------- */
/* CRPRootListController                                                       */
/* ------------------------------------------------------------------------- */

@interface CRPRootListController : PSListController
@end

@implementation CRPRootListController

- (id)specifiers
{
    /* Root.plist already declares the entire tree; PreferenceLoader loads it.
     * The only thing the controller must do is keep the group footer in the
     * upstream form. NOTE: this build ships the "Crack by Repo BVN" label found
     * in the analysed package; upstream ships FOLLOW_ME_ON_TWITTER. Both are
     * recorded in analysis/preference_schema.md. */
    return [super specifiers];
}

@end

/* ------------------------------------------------------------------------- */
/* CRPActiveContainerListItemsController                                       */
/* ------------------------------------------------------------------------- */

/* Named by Root.plist as the detail controller of the "Active Container"
 * specifier, and confirmed by the recovered __objc_classlist at 0x59500. */
@interface CRPActiveContainerListItemsController : UITableViewController
@property (nonatomic, copy) NSString *applicationIdentifier;
@property (nonatomic, copy) NSArray<NSString *> *containerIdentifiers;
@property (nonatomic, copy) NSArray<NSString *> *containerNames;
@end

@implementation CRPActiveContainerListItemsController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self reloadFromManager];
}

- (void)reloadFromManager
{
    CraneManager *manager = CraneManager.sharedManager;
    NSArray *identifiers = [manager containerIdentifiersOfApplicationWithIdentifier:
                            self.applicationIdentifier];
    NSMutableArray *names = [NSMutableArray new];
    for (NSString *identifier in identifiers) {
        [names addObject:[manager displayNameForContainerWithIdentifier:identifier
                                          ofApplicationWithIdentifier:self.applicationIdentifier
                                               shouldUseShortVersion:NO]];
    }
    self.containerIdentifiers = identifiers;
    self.containerNames = names;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return (NSInteger)self.containerIdentifiers.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell"];
    if (!cell)
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:@"cell"];

    NSString *identifier = self.containerIdentifiers[(NSUInteger)indexPath.row];
    CraneManager *manager = CraneManager.sharedManager;
    NSString *name = [manager displayNameForContainerWithIdentifier:identifier
                                        ofApplicationWithIdentifier:self.applicationIdentifier
                                             shouldUseShortVersion:NO];

    /* The checkmark is SelectedContainerCheckmark from Crane.bundle/Icons. */
    BOOL isActive = [[manager activeContainerIdentifierForApplicationWithIdentifier:
                      self.applicationIdentifier] isEqualToString:identifier];
    cell.accessoryType = isActive ? UITableViewCellAccessoryCheckmark
                                 : UITableViewCellAccessoryNone;
    cell.textLabel.text = name;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    NSString *identifier = self.containerIdentifiers[(NSUInteger)indexPath.row];
    CraneManager *manager = CraneManager.sharedManager;
    [manager setActiveContainerIdentifier:identifier
              forApplicationWithIdentifier:self.applicationIdentifier
                     reloadApplication:YES
       usingBiometricsIfNeededWithSuccessHandler:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self reloadFromManager];
        });
    }];
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
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
@end

@implementation CRPApplicationConfigurationListController

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
    self.applicationSettings[key] = value;
    [manager setApplicationSettings:[self.applicationSettings copy]
        forApplicationWithIdentifier:self.applicationIdentifier];
    [manager addObserver:self];
}

- (id)containersForApplication
{
    return self.applicationSettings[CRAppSetting_Containers];
}

- (id)specifiers
{
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
    [active setProperty:CRCContainer_ActiveContainer forKey:@"detailControllerClass"];
    [active setProperty:@YES forKey:@"enabled"];
    [specifiers addObject:active];

    /* Always Ask on App-Launch */
    PSSpecifier *ask = [PSSpecifier preferenceSpecifierNamed:
                        CRLocalize(@"ALWAYS_ASK_ON_APP_LAUNCH")
                                                     target:self set:NULL get:NULL
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
                                                   set:@selector(setPreferenceValue:specifier:)
                                                   get:@selector(readPreferenceValue:)
                                                detail:CRPApplicationConfigurationListController.class
                                                  cell:6
                                                  edit:0];
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

    return specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(id)specifier
{
    [self setPreferenceValue:value key:[specifier propertyForKey:@"key"]];
}

- (id)readPreferenceValue:(id)specifier
{
    return [self readPreferenceValueForKey:[specifier propertyForKey:@"key"]];
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
    [self reloadSpecifier:self.gameCenterSupportEnabledSpecifier];
}

- (void)setGameCenterSupportValue:(id)value specifier:(id)specifier
{
    [self setPreferenceValue:value specifier:specifier];
}

- (void)setActiveContainer:(id)value specifier:(id)specifier
{
    [self setPreferenceValue:value key:CRCContainer_ActiveContainer];
}

- (id)readActiveContainer:(id)specifier
{
    return [self readPreferenceValueForKey:CRCContainer_ActiveContainer];
}

- (void)addButtonPressed
{
    [CraneManager.sharedManager createNewContainerWithName:CRLocalize(@"NEW_CONTAINER")
                                forApplicationWithIdentifier:self.applicationIdentifier];
    [self loadApplicationSettings];
    [self reloadSpecifierAtIndex:0];
}

@end