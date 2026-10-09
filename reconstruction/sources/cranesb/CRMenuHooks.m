/*
 * CRMenuHooks.m — CraneSB application-shortcut / container menu integration.
 *
 * Modern (CF >= 1665.15 / iOS 13-era UIMenu) path recovered from:
 *   crane_replacementMenu                    0x137FC
 *   initWithTitleHook                        0x145B8
 *   initUIMenuHooks                          0x1497C
 *   applicationShortcut hook setup           0x14D18
 *   SBIconView applicationShortcutItems      0x15E20
 *   context-menu configuration capture       0x1611C
 *   _configureCell variants                  0x1621C/0x16398/0x164A8
 *   _interfaceActionGroupForActions          0x16598
 *   UIMenu initWithMenu:overrideChildren:    0x166B0
 *
 * The pre-UIMenu force-touch path remains separate and is not transcribed here.
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"

static NSString *const kMenuPlaceholder =
    @"com.opa334.crane.to-replace-with-container-selection";
static NSString *const kApplicationContainerType =
    @"com.opa334.crane.application-container";

extern void CRPresentNewContainerAlert(NSString *appID);

@interface NSObject (CraneMenuRuntime)
- (NSString *)type;
- (void)setType:(NSString *)type;
- (void)setLocalizedTitle:(NSString *)title;
- (void)setBundleIdentifierToLaunch:(NSString *)bundleIdentifier;
- (NSString *)applicationBundleIdentifier;
- (NSString *)applicationBundleIdentifierForShortcuts;
- (id)actionView;
- (void)setSubtitle:(NSString *)subtitle;
- (BOOL)reversesActionOrder;
- (NSArray *)actions;
- (id)customContentView;
- (id)titleLabel;
- (id)imageView;
- (NSString *)text;
- (UIImage *)image;
- (void)setValue:(id)value forKey:(NSString *)key;
- (void)openApplication:(NSString *)appID
            withOptions:(id)options
             completion:(id)completion;
@end

@interface UIMenu (CraneMenuPrivateCopy)
- (id)_copyWithOverrideChildren:(NSArray *)children;
- (id)_immutableCopy;
- (id)_mutableCopy;
@end

API_AVAILABLE(ios(13.0))
@interface CRSubtitleMenu : UIMenu
@property (nonatomic, strong) NSString *subtitle;
+ (instancetype)menuWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                        image:(UIImage *)image
                   identifier:(UIMenuIdentifier)identifier
                      options:(UIMenuOptions)options
                     children:(NSArray<UIMenuElement *> *)children;
@end

@implementation CRSubtitleMenu

static char kCRSubtitleKey;

- (NSString *)subtitle
{
    return objc_getAssociatedObject(self, &kCRSubtitleKey);
}

- (void)setSubtitle:(NSString *)subtitle
{
    objc_setAssociatedObject(self,
                             &kCRSubtitleKey,
                             subtitle,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (instancetype)menuWithTitle:(NSString *)title
                     subtitle:(NSString *)subtitle
                        image:(UIImage *)image
                   identifier:(UIMenuIdentifier)identifier
                      options:(UIMenuOptions)options
                     children:(NSArray<UIMenuElement *> *)children
{
    UIMenu *menu = [UIMenu menuWithTitle:title
                                   image:image
                              identifier:identifier
                                 options:options
                                children:children];
    object_setClass(menu, self);
    ((CRSubtitleMenu *)menu).subtitle = subtitle;
    return (CRSubtitleMenu *)menu;
}

- (id)copyWithZone:(NSZone *)zone
{
    id copy = [super copyWithZone:zone];
    [copy setSubtitle:self.subtitle];
    return copy;
}

- (id)_copyWithOverrideChildren:(NSArray *)children
{
    id copy = [super _copyWithOverrideChildren:children];
    [copy setSubtitle:self.subtitle];
    return copy;
}

- (id)_immutableCopy
{
    id copy = [super _immutableCopy];
    [copy setSubtitle:self.subtitle];
    return copy;
}

- (id)_mutableCopy
{
    id copy = [super _mutableCopy];
    [copy setSubtitle:self.subtitle];
    return copy;
}

@end

static NSString *gCRSelectedApplicationIdentifier;

/* ------------------------------------------------------------------------- */
/* Shared actions                                                            */
/* ------------------------------------------------------------------------- */

static void CRLaunchApplicationIfEnabled(NSString *appID)
{
    if (!CRPrefBool(CRPref_LaunchAppOnContainerSelection) || !appID)
        return;

    Class serviceClass = NSClassFromString(@"FBSOpenApplicationService");
    id service = [serviceClass new];
    SEL selector =
        NSSelectorFromString(@"openApplication:withOptions:completion:");
    if ([service respondsToSelector:selector]) {
        [service openApplication:appID withOptions:nil completion:nil];
    }
}

static void CROpenCraneSettings(NSString *appID)
{
    NSString *path = appID.length
        ? [NSString stringWithFormat:@"APPLICATIONS/%@", appID]
        : nil;

    NSString *shufflePath =
        CRJailbreakRootPath(
            @"/Library/MobileSubstrate/DynamicLibraries/shuffle.plist");
    BOOL shuffleExists =
        [NSFileManager.defaultManager fileExistsAtPath:shufflePath];

    NSString *root = @"Crane";
    NSString *settingsPath = path;

    if (shuffleExists) {
        NSUserDefaults *shuffle =
            [[NSUserDefaults alloc] initWithSuiteName:@"com.creaturecoding.shuffle"];
        id enabled = [shuffle objectForKey:@"kEnabled"];
        if (!enabled || [enabled boolValue]) {
            NSString *group = [shuffle stringForKey:@"kTweaksGroupName"];
            if (!group.length)
                group = @"Tweaks";
            root = [group stringByAddingPercentEncodingWithAllowedCharacters:
                              NSCharacterSet.URLQueryAllowedCharacterSet];
            settingsPath = path.length
                ? [NSString stringWithFormat:@"Crane/%@", path]
                : @"Crane";
        }
    }

    NSString *urlString = settingsPath.length
        ? [NSString stringWithFormat:@"prefs:root=%@&path=%@", root, settingsPath]
        : [NSString stringWithFormat:@"prefs:root=%@", root];
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url)
        return;

    UIApplication *application = UIApplication.sharedApplication;
    if ([application respondsToSelector:
            @selector(openURL:options:completionHandler:)]) {
        [application openURL:url options:@{} completionHandler:nil];
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [application openURL:url];
#pragma clang diagnostic pop
    }
}

static UIMenu *CRBuildReplacementMenu(void) API_AVAILABLE(ios(13.0));

static UIMenu *CRBuildReplacementMenu(void)
{
    NSString *appID = gCRSelectedApplicationIdentifier;
    gCRSelectedApplicationIdentifier = nil;
    if (!appID.length)
        return nil;

    CraneManager *manager = CraneManager.sharedManager;
    NSString *active =
        [manager activeContainerIdentifierForApplicationWithIdentifier:appID];
    NSString *activeName =
        [manager displayNameForContainerWithIdentifier:active
                           ofApplicationWithIdentifier:appID
                                shouldUseShortVersion:YES];

    NSDictionary *appSettings =
        [manager applicationSettingsForApplicationWithIdentifier:appID];
    NSArray *containers = appSettings[CRAppSetting_Containers] ?: @[];
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray new];

    for (NSDictionary *container in containers) {
        NSString *containerID = container[CRCContainer_Identifier];
        if (!containerID.length)
            continue;

        NSString *title =
            [manager displayNameForContainerWithIdentifier:containerID
                               ofApplicationWithIdentifier:appID
                                    shouldUseShortVersion:YES];
        UIImage *image = [containerID isEqualToString:active]
            ? [UIImage systemImageNamed:@"checkmark"]
            : nil;

        NSString *capturedActive = active;
        UIAction *action =
            [UIAction actionWithTitle:title ?: containerID
                                image:image
                           identifier:(UIActionIdentifier)containerID
                              handler:^(UIAction *selectedAction) {
            NSString *target = (NSString *)selectedAction.identifier;
            void (^launch)(void) = ^{
                CRLaunchApplicationIfEnabled(appID);
            };

            if ([target isEqualToString:capturedActive]) {
                launch();
                return;
            }

            [CraneManager.sharedManager
                setActiveContainerIdentifier:target
                 forApplicationWithIdentifier:appID
                usingBiometricsIfNeededWithSuccessHandler:launch];
        }];
        [children addObject:action];
    }

    if (CRPrefBool(CRPref_NewContainerShortcut)) {
        UIAction *newContainer =
            [UIAction actionWithTitle:CRLocalize(@"NEW_CONTAINER")
                                image:[UIImage systemImageNamed:@"plus"]
                           identifier:@"crane-new-container-action"
                              handler:^(__unused UIAction *action) {
            CRPresentNewContainerAlert(appID);
        }];
        [children addObject:newContainer];
    }

    UIAction *settings =
        [UIAction actionWithTitle:CRLocalize(@"SETTINGS")
                            image:[UIImage systemImageNamed:@"gear"]
                       identifier:@"crane-settings-action"
                          handler:^(__unused UIAction *action) {
        CROpenCraneSettings(appID);
    }];

    if (CRPrefBool(CRPref_ExpandContainersShortcut)) {
        [children addObject:settings];
        return [UIMenu menuWithTitle:CRLocalize(@"CONTAINER")
                               image:nil
                          identifier:nil
                             options:(UIMenuOptions)1
                            children:children];
    }

    UIMenu *settingsWrapper =
        [UIMenu menuWithTitle:@""
                        image:nil
                   identifier:@"crane-settings-wrapper"
                      options:(UIMenuOptions)1
                     children:@[settings]];
    [children addObject:settingsWrapper];

    NSArray<UIMenuElement *> *ordered = nil;
    if (kCFCoreFoundationVersionNumber >= 1854.0) {
        ordered = children.reverseObjectEnumerator.allObjects;
    } else {
        ordered = [children copy];
    }

    return [CRSubtitleMenu
        menuWithTitle:CRLocalize(@"CONTAINER")
             subtitle:activeName
                image:[UIImage systemImageNamed:@"square.grid.2x2"]
           identifier:nil
              options:0
             children:ordered];
}

/* ------------------------------------------------------------------------- */
/* UIMenu placeholder replacement                                            */
/* ------------------------------------------------------------------------- */

static NSArray *CRChildrenByReplacingPlaceholder(NSArray *children)
    API_AVAILABLE(ios(13.0));

static NSArray *CRChildrenByReplacingPlaceholder(NSArray *children)
{
    NSInteger found = NSNotFound;
    for (NSUInteger index = 0; index < children.count; index++) {
        id child = children[index];
        NSString *title =
            [child respondsToSelector:@selector(title)] ? [child title] : nil;
        if ([title isEqualToString:kMenuPlaceholder])
            found = (NSInteger)index;
    }

    if (found == NSNotFound)
        return children;

    UIMenu *replacement = CRBuildReplacementMenu();
    if (!replacement)
        return children;

    NSMutableArray *mutable = [children mutableCopy];
    mutable[(NSUInteger)found] = replacement;
    return [mutable copy];
}

static IMP gOrigUIMenuInitModern;
static IMP gOrigUIMenuInitLegacy;

static id CRUIMenuInitModern(id self,
                             SEL _cmd,
                             NSString *title,
                             UIImage *image,
                             NSString *imageName,
                             UIMenuIdentifier identifier,
                             UIMenuOptions options,
                             NSArray *children)
{
    if ([title isEqualToString:kMenuPlaceholder]) {
        UIMenu *replacement = CRBuildReplacementMenu();
        if (replacement)
            return replacement;
    }

    NSArray *replaced = CRChildrenByReplacingPlaceholder(children);
    id (*original)(id, SEL, id, id, id, id, UIMenuOptions, id) =
        (id (*)(id, SEL, id, id, id, id, UIMenuOptions, id))
            gOrigUIMenuInitModern;
    return original
        ? original(self, _cmd, title, image, imageName,
                   identifier, options, replaced)
        : self;
}

static id CRUIMenuInitLegacy(id self,
                             SEL _cmd,
                             NSString *title,
                             UIImage *image,
                             UIMenuIdentifier identifier,
                             UIMenuOptions options,
                             NSArray *children)
{
    if ([title isEqualToString:kMenuPlaceholder]) {
        UIMenu *replacement = CRBuildReplacementMenu();
        if (replacement)
            return replacement;
    }

    NSArray *replaced = CRChildrenByReplacingPlaceholder(children);
    id (*original)(id, SEL, id, id, id, UIMenuOptions, id) =
        (id (*)(id, SEL, id, id, id, UIMenuOptions, id))
            gOrigUIMenuInitLegacy;
    return original
        ? original(self, _cmd, title, image, identifier, options, replaced)
        : self;
}

void CRInitUIMenuHooks(void)
{
    Class menuClass = NSClassFromString(@"UIMenu");
    if (!menuClass)
        return;

    SEL modern =
        NSSelectorFromString(
            @"initWithTitle:image:imageName:identifier:options:children:");
    if ([menuClass instancesRespondToSelector:modern]) {
        MSHookMessageEx(menuClass,
                        modern,
                        (IMP)CRUIMenuInitModern,
                        &gOrigUIMenuInitModern);
        return;
    }

    SEL legacy =
        NSSelectorFromString(
            @"initWithTitle:image:identifier:options:children:");
    if ([menuClass instancesRespondToSelector:legacy]) {
        MSHookMessageEx(menuClass,
                        legacy,
                        (IMP)CRUIMenuInitLegacy,
                        &gOrigUIMenuInitLegacy);
    }
}

/* ------------------------------------------------------------------------- */
/* iOS 13+ shortcut integration                                              */
/* ------------------------------------------------------------------------- */

static IMP gOrigShortcutIsSystem;
static IMP gOrigShortcutSection;
static IMP gOrigApplicationShortcutItems;
static IMP gOrigContextMenuConfiguration;
static IMP gOrigMenuInitWithOverrideChildren;
static IMP gOrigConfigureCellLong;
static IMP gOrigConfigureCellSize;
static IMP gOrigConfigureCellSimple;
static IMP gOrigInterfaceActionGroup;

static BOOL CRShortcutIsSystem(id self, SEL _cmd)
{
    if ([[self type] isEqualToString:kApplicationContainerType])
        return !CRPrefBool(CRPref_ExpandContainersShortcut);

    BOOL (*original)(id, SEL) =
        (BOOL (*)(id, SEL))gOrigShortcutIsSystem;
    return original ? original(self, _cmd) : NO;
}

static NSInteger CRShortcutSection(id self, SEL _cmd)
{
    if ([[self type] isEqualToString:kApplicationContainerType])
        return CRPrefBool(CRPref_ExpandContainersShortcut) ? 1 : 2;

    NSInteger (*original)(id, SEL) =
        (NSInteger (*)(id, SEL))gOrigShortcutSection;
    return original ? original(self, _cmd) : 0;
}

static NSString *CRShortcutApplicationIdentifier(id self)
{
    if ([self respondsToSelector:@selector(applicationBundleIdentifier)])
        return [self applicationBundleIdentifier];
    if ([self respondsToSelector:
            @selector(applicationBundleIdentifierForShortcuts)]) {
        return [self applicationBundleIdentifierForShortcuts];
    }
    return nil;
}

static NSArray *CRApplicationShortcutItems(id self, SEL _cmd)
{
    NSArray *(*original)(id, SEL) =
        (NSArray *(*)(id, SEL))gOrigApplicationShortcutItems;
    NSArray *existing = original ? original(self, _cmd) : nil;

    if (!CRPrefBool(CRPref_AppShortcutEnabled))
        return existing;

    NSString *appID = CRShortcutApplicationIdentifier(self);
    if (!appID.length ||
        ![CraneManager.sharedManager isApplicationSupportedByCrane:appID]) {
        return existing;
    }

    NSDictionary *settings =
        [CraneManager.sharedManager
            applicationSettingsForApplicationWithIdentifier:appID];
    NSArray *containers = settings[CRAppSetting_Containers] ?: @[];
    if (containers.count <= 1 &&
        CRPrefBool(CRPref_OnlyShowIfContainersExist)) {
        return existing;
    }

    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    id placeholder = [itemClass new];
    if (!placeholder)
        return existing;

    [placeholder setLocalizedTitle:kMenuPlaceholder];
    [placeholder setBundleIdentifierToLaunch:nil];
    [placeholder setType:kApplicationContainerType];

    if (CRPrefBool(CRPref_ExpandContainersShortcut)) {
        return existing ? [existing arrayByAddingObject:placeholder]
                        : @[placeholder];
    }

    return existing ? [@[placeholder] arrayByAddingObjectsFromArray:existing]
                    : @[placeholder];
}

static id CRContextMenuConfiguration(id self,
                                     SEL _cmd,
                                     id interaction,
                                     CGPoint location)
{
    if (CRPrefBool(CRPref_AppShortcutEnabled))
        gCRSelectedApplicationIdentifier =
            [CRShortcutApplicationIdentifier(self) copy];

    id (*original)(id, SEL, id, CGPoint) =
        (id (*)(id, SEL, id, CGPoint))
            gOrigContextMenuConfiguration;
    return original ? original(self, _cmd, interaction, location) : nil;
}

static id CRMenuInitWithOverrideChildren(id self,
                                         SEL _cmd,
                                         id menu,
                                         NSArray *children)
{
    id (*original)(id, SEL, id, id) =
        (id (*)(id, SEL, id, id))
            gOrigMenuInitWithOverrideChildren;
    id result = original ? original(self, _cmd, menu, children) : self;

    if ([menu isKindOfClass:CRSubtitleMenu.class] && result) {
        object_setClass(result, CRSubtitleMenu.class);
        [(CRSubtitleMenu *)result
            setSubtitle:((CRSubtitleMenu *)menu).subtitle];
    }
    return result;
}

static void CRApplySubtitleToCell(id cell, id element)
{
    if (![element isKindOfClass:CRSubtitleMenu.class])
        return;

    id actionView =
        [cell respondsToSelector:@selector(actionView)] ? [cell actionView] : nil;
    if ([actionView respondsToSelector:@selector(setSubtitle:)])
        [actionView setSubtitle:((CRSubtitleMenu *)element).subtitle];
}

static void CRConfigureCellLong(id self,
                                SEL _cmd,
                                id cell,
                                id collectionView,
                                id indexPath,
                                id element,
                                id section,
                                uint64_t size)
{
    void (*original)(id, SEL, id, id, id, id, id, uint64_t) =
        (void (*)(id, SEL, id, id, id, id, id, uint64_t))
            gOrigConfigureCellLong;
    if (original)
        original(self, _cmd, cell, collectionView,
                 indexPath, element, section, size);
    CRApplySubtitleToCell(cell, element);
}

static void CRConfigureCellSize(id self,
                                SEL _cmd,
                                id cell,
                                id element,
                                id section,
                                uint64_t size)
{
    void (*original)(id, SEL, id, id, id, uint64_t) =
        (void (*)(id, SEL, id, id, id, uint64_t))
            gOrigConfigureCellSize;
    if (original)
        original(self, _cmd, cell, element, section, size);
    CRApplySubtitleToCell(cell, element);
}

static void CRConfigureCellSimple(id self,
                                  SEL _cmd,
                                  id cell,
                                  id element,
                                  id section)
{
    void (*original)(id, SEL, id, id, id) =
        (void (*)(id, SEL, id, id, id))
            gOrigConfigureCellSimple;
    if (original)
        original(self, _cmd, cell, element, section);
    CRApplySubtitleToCell(cell, element);
}

static id CRInterfaceActionGroup(id self, SEL _cmd, NSArray *elements)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gOrigInterfaceActionGroup;
    id group = original ? original(self, _cmd, elements) : nil;
    if (!group)
        return group;

    NSArray *actions =
        [group respondsToSelector:@selector(actions)] ? [group actions] : nil;
    BOOL reverse =
        [self respondsToSelector:@selector(reversesActionOrder)]
            ? [self reversesActionOrder]
            : NO;

    [elements enumerateObjectsUsingBlock:
        ^(id element, NSUInteger index, BOOL *stop) {
        (void)stop;
        if (![element isKindOfClass:CRSubtitleMenu.class])
            return;

        NSUInteger mapped =
            reverse ? (elements.count - 1 - index) : index;
        if (mapped >= actions.count)
            return;

        id interfaceAction = actions[mapped];
        id customView =
            [interfaceAction respondsToSelector:@selector(customContentView)]
                ? [interfaceAction customContentView]
                : nil;
        NSString *title = nil;
        UIImage *image = nil;
        if (customView) {
            id titleLabel =
                [customView respondsToSelector:@selector(titleLabel)]
                    ? [customView titleLabel]
                    : nil;
            title =
                [titleLabel respondsToSelector:@selector(text)]
                    ? [titleLabel text]
                    : nil;
            id imageView =
                [customView respondsToSelector:@selector(imageView)]
                    ? [customView imageView]
                    : nil;
            image =
                [imageView respondsToSelector:@selector(image)]
                    ? [imageView image]
                    : nil;
        }

        Class viewClass =
            NSClassFromString(@"_UIContextMenuActionView");
        SEL initSelector =
            NSSelectorFromString(@"initWithTitle:subtitle:image:");
        if (!viewClass ||
            ![viewClass instancesRespondToSelector:initSelector]) {
            return;
        }

        id view = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
            [viewClass alloc],
            initSelector,
            title,
            ((CRSubtitleMenu *)element).subtitle,
            image);
        [interfaceAction setValue:view forKey:@"_customContentView"];
    }];

    return group;
}

void CRInitApplicationShortcutHooks(void)
{
    if (kCFCoreFoundationVersionNumber < 1665.15)
        return;

    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    if (itemClass) {
        SEL systemSelector = NSSelectorFromString(@"sbh_isSystemShortcut");
        if ([itemClass instancesRespondToSelector:systemSelector]) {
            MSHookMessageEx(itemClass,
                            systemSelector,
                            (IMP)CRShortcutIsSystem,
                            &gOrigShortcutIsSystem);
        }

        SEL sectionSelector = NSSelectorFromString(@"sbh_shortcutSection");
        if ([itemClass instancesRespondToSelector:sectionSelector]) {
            MSHookMessageEx(itemClass,
                            sectionSelector,
                            (IMP)CRShortcutSection,
                            &gOrigShortcutSection);
        }
    }

    Class iconViewClass = NSClassFromString(@"SBIconView");
    if (iconViewClass) {
        SEL itemsSelector =
            NSSelectorFromString(@"applicationShortcutItems");
        if ([iconViewClass instancesRespondToSelector:itemsSelector]) {
            MSHookMessageEx(iconViewClass,
                            itemsSelector,
                            (IMP)CRApplicationShortcutItems,
                            &gOrigApplicationShortcutItems);
        }

        SEL contextSelector =
            NSSelectorFromString(
                @"contextMenuInteraction:configurationForMenuAtLocation:");
        if ([iconViewClass instancesRespondToSelector:contextSelector]) {
            MSHookMessageEx(iconViewClass,
                            contextSelector,
                            (IMP)CRContextMenuConfiguration,
                            &gOrigContextMenuConfiguration);
        }
    }

    Class listClass =
        NSClassFromString(@"_UIContextMenuActionsListView");
    if (!listClass)
        listClass = NSClassFromString(@"_UIContextMenuListView");
    if (listClass) {
        SEL longSelector =
            NSSelectorFromString(
                @"_configureCell:inCollectionView:atIndexPath:forElement:section:size:");
        if ([listClass instancesRespondToSelector:longSelector]) {
            MSHookMessageEx(listClass,
                            longSelector,
                            (IMP)CRConfigureCellLong,
                            &gOrigConfigureCellLong);
        }

        SEL sizeSelector =
            NSSelectorFromString(
                @"_configureCell:forElement:section:size:");
        if ([listClass instancesRespondToSelector:sizeSelector]) {
            MSHookMessageEx(listClass,
                            sizeSelector,
                            (IMP)CRConfigureCellSize,
                            &gOrigConfigureCellSize);
        }

        SEL simpleSelector =
            NSSelectorFromString(
                @"_configureCell:forElement:section:");
        if ([listClass instancesRespondToSelector:simpleSelector]) {
            MSHookMessageEx(listClass,
                            simpleSelector,
                            (IMP)CRConfigureCellSimple,
                            &gOrigConfigureCellSimple);
        }

        SEL groupSelector =
            NSSelectorFromString(@"_interfaceActionGroupForActions:");
        if ([listClass instancesRespondToSelector:groupSelector]) {
            MSHookMessageEx(listClass,
                            groupSelector,
                            (IMP)CRInterfaceActionGroup,
                            &gOrigInterfaceActionGroup);
        }
    }

    Class menuClass = NSClassFromString(@"UIMenu");
    SEL overrideSelector =
        NSSelectorFromString(@"initWithMenu:overrideChildren:");
    if (menuClass &&
        [menuClass instancesRespondToSelector:overrideSelector]) {
        MSHookMessageEx(menuClass,
                        overrideSelector,
                        (IMP)CRMenuInitWithOverrideChildren,
                        &gOrigMenuInitWithOverrideChildren);
    }
}
