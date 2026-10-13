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
 * Legacy (CF < 1665.15 / iOS 11-12 force-touch) path recovered from:
 *   early shortcut hook setup                 0x14D18
 *   late data-provider hook setup             0x169F0
 *   craneContainersApplicationShortcutItems  0x16A90
 *   applicationShortcutItems                 0x170A4
 *   _actionFromApplicationShortcutItem:      0x1555C
 *   force-touch action handlers              0x18A3C..0x19068
 *
 * F-14 recovers modern CRBadgeAction plus native badge-view presentation
 * when SpringBoard private APIs are present, and legacy RTL badge subtitles.
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
static NSString *const kLegacyContainersType =
    @"com.opa334.crane.containers";
static NSString *const kLegacyContainerTypePrefix =
    @"com.opa334.crane-container.";
static NSString *const kLegacySeparatorType =
    @"com.opa334.crane.separator";
static NSString *const kLegacyNewContainerType =
    @"com.opa334.crane.new-container-action";
static NSString *const kLegacyPreferencesType =
    @"com.opa334.crane.open-preferences";

extern void CRPresentNewContainerAlert(NSString *appID);
extern NSInteger CRBadgeStoreContainerCount(NSString *appID,
                                           NSString *containerID,
                                           BOOL validateContainer);

static id CRDynamicObjectGetter(id object, SEL selector)
{
    if (!object || ![object respondsToSelector:selector])
        return nil;
    return ((id (*)(id, SEL))objc_msgSend)(object, selector);
}

static BOOL CRDynamicBoolGetter(id object, SEL selector)
{
    if (!object || ![object respondsToSelector:selector])
        return NO;
    return ((BOOL (*)(id, SEL))objc_msgSend)(object, selector);
}

static void CRDynamicObjectSetter(id object, SEL selector, id value)
{
    if (!object || ![object respondsToSelector:selector])
        return;
    ((void (*)(id, SEL, id))objc_msgSend)(object, selector, value);
}

static void CRDynamicBoolSetter(id object, SEL selector, BOOL value)
{
    if (!object || ![object respondsToSelector:selector])
        return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(object, selector, value);
}

static id CRDynamicValueForKey(id object, NSString *key)
{
    if (!object || !key.length)
        return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void CRDynamicSetValueForKey(id object, NSString *key, id value)
{
    if (!object || !key.length)
        return;
    @try {
        [object setValue:value forKey:key];
    } @catch (__unused NSException *exception) {
    }
}

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
    [(CRSubtitleMenu *)copy setSubtitle:self.subtitle];
    return copy;
}

- (id)_copyWithOverrideChildren:(NSArray *)children
{
    id copy = [super _copyWithOverrideChildren:children];
    [(CRSubtitleMenu *)copy setSubtitle:self.subtitle];
    return copy;
}

- (id)_immutableCopy
{
    id copy = [super _immutableCopy];
    [(CRSubtitleMenu *)copy setSubtitle:self.subtitle];
    return copy;
}

- (id)_mutableCopy
{
    id copy = [super _mutableCopy];
    [(CRSubtitleMenu *)copy setSubtitle:self.subtitle];
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
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(
            service,
            selector,
            appID,
            nil,
            nil);
    }
}

/* Native CraneSB 0x143CC: after a biometric-protected switch, older
 * CF/UIKit needs 1 second before launch. A normal switch launches now. */
static void CRLaunchAfterContainerSwitch(dispatch_block_t launch,
                                         BOOL authenticated)
{
    if (!launch)
        return;
    if (authenticated && kCFCoreFoundationVersionNumber < 1740.0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                       dispatch_get_main_queue(), launch);
    } else {
        launch();
    }
}

static void CROpenCraneSettings(NSString *appID)
{
    /* Native 0x12720 distinguishes a nil appID (empty path) from a
     * non-nil, even empty, appID (APPLICATIONS/). Both remain non-nil. */
    NSString *path = appID
        ? [NSString stringWithFormat:@"APPLICATIONS/%@", appID]
        : @"";

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
            if (!group)
                group = @"Tweaks";
            /* Original 0x12720 uses the legacy percent-escaping selector
             * rather than URLQueryAllowedCharacterSet, which can leave
             * URL separators unescaped in the Shuffle group name. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            root = [group stringByAddingPercentEscapesUsingEncoding:
                              NSUTF8StringEncoding];
#pragma clang diagnostic pop
            settingsPath = [NSString stringWithFormat:@"Crane/%@", path];
        }
    }

    /* The native shared menu handler always appends &path=, including
     * the nil-app variant where that path is intentionally empty. */
    NSString *urlString = [NSString stringWithFormat:
        @"prefs:root=%@&path=%@", root, settingsPath];
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

/* F-14: read the persisted per-container badge snapshot (0xA860/0xAE20).
 * F-08 is responsible for producing/updating this file at runtime. */
static NSInteger CRStoredContainerBadgeCount(NSString *appID,
                                             NSString *containerID,
                                             CraneManager *manager)
{
    if (!appID.length || !containerID.length)
        return 0;
    (void)manager;
    NSInteger count = CRBadgeStoreContainerCount(appID, containerID, YES);
    return count > 0 ? count : 0;
}

static BOOL CRShouldShowContainerBadges(NSString *appID,
                                       NSDictionary *appSettings,
                                       CraneManager *manager)
{
    id enabled = [manager preferenceValueForKey:
        CRPref_NotificationsSupportEnabled];
    if (enabled && ![enabled boolValue])
        return NO;
    enabled = [manager preferenceValueForKey:
        CRPref_ShowContainerNotificationBadges];
    if (enabled && ![enabled boolValue])
        return NO;
    id separate = appSettings[CRAppSetting_SeparateNotificationRegistrationsEnabled];
    return !separate || [separate boolValue];
}

static UIMenu *CRBuildReplacementMenu(void) API_AVAILABLE(ios(13.0));

static UIMenu *CRBuildReplacementMenu(void)
{
    NSString *appID = gCRSelectedApplicationIdentifier;
    gCRSelectedApplicationIdentifier = nil;
    if (!appID.length) {
        NSLog(@"CraneSB: menu replacement skipped: missing selected application");
        return nil;
    }

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
    NSLog(@"CraneSB: replacement menu app=%@ containers=%lu active=%@",
          appID, (unsigned long)containers.count, active);
    NSMutableArray<UIMenuElement *> *children = [NSMutableArray new];
    BOOL showBadges = CRShouldShowContainerBadges(appID, appSettings, manager);

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
        UIActionHandler handler = ^(UIAction *selectedAction) {
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
                usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {
                    CRLaunchAfterContainerSwitch(launch, authenticated);
                }];
        };
        UIAction *action = nil;
        if (showBadges) {
            NSInteger count = CRStoredContainerBadgeCount(appID, containerID,
                                                         manager);
            Class badgeClass = NSClassFromString(@"CRBadgeAction");
            SEL factorySEL = NSSelectorFromString(
                @"actionWithTitle:badgeText:image:identifier:associatedApplicationIdentifier:handler:");
            if (count > 0 && [badgeClass respondsToSelector:factorySEL]) {
                /* Native 0x137FC creates a CRBadgeAction directly and
                 * formats its 32-bit badge count using %d. */
                NSString *badgeText = [NSString stringWithFormat:@"%d", (int)count];
                action = ((id (*)(id, SEL, id, id, id, id, id, id))objc_msgSend)(
                    badgeClass, factorySEL, title ?: containerID, badgeText,
                    image, (UIActionIdentifier)containerID, appID, handler);
            }
        }
        if (!action)
            action = [UIAction actionWithTitle:title ?: containerID
                                        image:image
                                   identifier:(UIActionIdentifier)containerID
                                      handler:handler];
        if (action)
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
            CRDynamicObjectGetter(child, NSSelectorFromString(@"title"));
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
    /* Native 0x145B8 replaces a child placeholder before checking the
     * enclosing menu's title. Only consume the selected application once. */
    NSArray *replaced = CRChildrenByReplacingPlaceholder(children);
    if (replaced == children && [title isEqualToString:kMenuPlaceholder]) {
        UIMenu *replacement = CRBuildReplacementMenu();
        if (replacement)
            return replacement;
    }

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
    /* Native 0x145B8 replaces a child placeholder before checking the
     * enclosing menu's title. Only consume the selected application once. */
    NSArray *replaced = CRChildrenByReplacingPlaceholder(children);
    if (replaced == children && [title isEqualToString:kMenuPlaceholder]) {
        UIMenu *replacement = CRBuildReplacementMenu();
        if (replacement)
            return replacement;
    }

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
        NSLog(@"CraneSB: UIMenu placeholder hook selector=%@", NSStringFromSelector(modern));
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
        NSLog(@"CraneSB: UIMenu placeholder hook selector=%@", NSStringFromSelector(legacy));
        MSHookMessageEx(menuClass,
                        legacy,
                        (IMP)CRUIMenuInitLegacy,
                        &gOrigUIMenuInitLegacy);
    }
}

/* ------------------------------------------------------------------------- */
/* iOS 11/12 force-touch shortcut integration                                */
/* ------------------------------------------------------------------------- */

static NSString *CRShortcutApplicationIdentifier(id self);

static char kCRLegacyProvideOptionsKey;
static char kCRLegacySeparatorKey;
static BOOL gCRPreventDismissingForceTouchMenu;

static IMP gOrigLegacyForceTouchDismiss;
static IMP gOrigLegacyForceTouchControllerInit;
static IMP gOrigLegacyActionViewSetHighlighted;
static IMP gOrigLegacyActionViewSetupSubviews;
static IMP gOrigLegacyActionViewSetBackgroundColor;
static IMP gOrigLegacyActionFromShortcutItem;
static IMP gOrigLegacyApplicationShortcutItems;

static BOOL CRLegacyProvidesContainerOptions(id self, SEL _cmd)
{
    (void)_cmd;
    NSNumber *value =
        objc_getAssociatedObject(self, &kCRLegacyProvideOptionsKey);
    return value.boolValue;
}

static void CRLegacySetProvidesContainerOptions(id self, SEL _cmd, BOOL value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             &kCRLegacyProvideOptionsKey,
                             @(value),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL CRLegacyActionIsSeparator(id self, SEL _cmd)
{
    (void)_cmd;
    NSNumber *value = objc_getAssociatedObject(self, &kCRLegacySeparatorKey);
    return value.boolValue;
}

static void CRLegacySetActionIsSeparator(id self, SEL _cmd, BOOL value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             &kCRLegacySeparatorKey,
                             @(value),
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL CRLegacyIsSeparatorAction(id action)
{
    return CRDynamicBoolGetter(action,
        NSSelectorFromString(@"crane_isSeparator"));
}

static UIImage *CRLegacyTemplateIcon(NSString *name)
{
    UIImage *image = CRIcon(name);
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

static UIImage *CRLegacyBlankIcon(void)
{
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(30.0, 30.0), NO, 0.0);
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image;
}

static id CRLegacyForceTouchDelegate(id shortcutController)
{
    return CRDynamicObjectGetter(shortcutController,
                                 NSSelectorFromString(@"delegate"));
}

static void CRLegacyDismissShortcutController(id shortcutController,
                                              dispatch_block_t completion)
{
    id delegate = CRLegacyForceTouchDelegate(shortcutController);
    SEL selector =
        NSSelectorFromString(@"_dismissAnimated:withCompletionHandler:");
    if (delegate && [delegate respondsToSelector:selector]) {
        ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
            delegate, selector, YES, completion);
    } else if (completion) {
        completion();
    }
}

static void CRLegacyActivateShortcutItem(id shortcutController, id item)
{
    id delegate = CRLegacyForceTouchDelegate(shortcutController);
    SEL selector = NSSelectorFromString(
        @"appIconForceTouchShortcutViewController:activateApplicationShortcutItem:");
    if (delegate && [delegate respondsToSelector:selector]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            delegate, selector, shortcutController, item);
    }
}

static void CRLegacyExpandContainerOptions(id shortcutController)
{
    id delegate = CRLegacyForceTouchDelegate(shortcutController);
    id dataProvider = CRDynamicValueForKey(delegate, @"_dataProvider");
    CRLegacyDismissShortcutController(shortcutController, ^{
        id controller = CRLegacyForceTouchDelegate(shortcutController);
        CRDynamicBoolSetter(controller,
                            NSSelectorFromString(
                                @"setCrane_provideContainerOptions:"),
                            YES);

        id gestureRecognizer =
            CRDynamicObjectGetter(dataProvider,
                                  NSSelectorFromString(@"gestureRecognizer"));
        SEL setupSelector =
            NSSelectorFromString(@"_setupWithGestureRecognizer:");
        if (controller && [controller respondsToSelector:setupSelector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                controller, setupSelector, gestureRecognizer);
        }

        gCRPreventDismissingForceTouchMenu = YES;

        Class iconControllerClass = NSClassFromString(@"SBIconController");
        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        id iconController =
            (iconControllerClass &&
             [iconControllerClass respondsToSelector:sharedSelector])
                ? ((id (*)(id, SEL))objc_msgSend)(
                      iconControllerClass, sharedSelector)
                : nil;
        CRDynamicSetValueForKey(iconController,
                                @"_appIconForceTouchController",
                                controller);

        SEL peekSelector =
            NSSelectorFromString(
                @"_peekAnimated:withRelativeTouchForce:allowSmoothing:");
        if (controller && [controller respondsToSelector:peekSelector]) {
            ((void (*)(id, SEL, BOOL, double, BOOL))objc_msgSend)(
                controller, peekSelector, NO, 0.0, NO);
        }

        SEL presentSelector =
            NSSelectorFromString(@"_presentAnimated:withCompletionHandler:");
        if (controller && [controller respondsToSelector:presentSelector]) {
            ((void (*)(id, SEL, BOOL, id))objc_msgSend)(
                controller,
                presentSelector,
                YES,
                ^{
                    gCRPreventDismissingForceTouchMenu = NO;
                });
        } else {
            gCRPreventDismissingForceTouchMenu = NO;
        }
    });
}

static void CRLegacyHandleContainerSelection(id shortcutController,
                                             id shortcutItem,
                                             NSString *containerID,
                                             NSString *activeContainerID,
                                             NSString *appID)
{
    if ([containerID isEqualToString:activeContainerID]) {
        if (CRPrefBool(CRPref_LaunchAppOnContainerSelection))
            CRLegacyActivateShortcutItem(shortcutController, shortcutItem);
        else
            CRLegacyDismissShortcutController(shortcutController, nil);
        return;
    }

    CRLegacyDismissShortcutController(shortcutController, nil);
    [CraneManager.sharedManager
        setActiveContainerIdentifier:containerID
         forApplicationWithIdentifier:appID
        usingBiometricsIfNeededWithSuccessHandler:^(BOOL authenticated) {
            (void)authenticated;
            if (CRPrefBool(CRPref_LaunchAppOnContainerSelection))
                CRLegacyActivateShortcutItem(shortcutController, shortcutItem);
            else
                CRLegacyDismissShortcutController(shortcutController, nil);
        }];
}

static void CRLegacyDismissHook(id self,
                                SEL _cmd,
                                BOOL animated,
                                id completion)
{
    if (gCRPreventDismissingForceTouchMenu)
        return;

    void (*original)(id, SEL, BOOL, id) =
        (void (*)(id, SEL, BOOL, id))gOrigLegacyForceTouchDismiss;
    if (original)
        original(self, _cmd, animated, completion);
}

static id CRLegacyForceTouchControllerInit(id self, SEL _cmd)
{
    id (*original)(id, SEL) =
        (id (*)(id, SEL))gOrigLegacyForceTouchControllerInit;
    id result = original ? original(self, _cmd) : self;
    CRDynamicBoolSetter(result,
                        NSSelectorFromString(
                            @"setCrane_provideContainerOptions:"),
                        NO);
    return result;
}

static void CRLegacyActionViewSetHighlighted(id self,
                                             SEL _cmd,
                                             BOOL highlighted)
{
    id action =
        CRDynamicObjectGetter(self, NSSelectorFromString(@"action"));
    BOOL effective = highlighted && !CRLegacyIsSeparatorAction(action);

    void (*original)(id, SEL, BOOL) =
        (void (*)(id, SEL, BOOL))gOrigLegacyActionViewSetHighlighted;
    if (original)
        original(self, _cmd, effective);
}

static void CRLegacyActionViewSetupSubviews(id self, SEL _cmd)
{
    id action =
        CRDynamicObjectGetter(self, NSSelectorFromString(@"action"));
    if (!CRLegacyIsSeparatorAction(action)) {
        void (*original)(id, SEL) =
            (void (*)(id, SEL))gOrigLegacyActionViewSetupSubviews;
        if (original)
            original(self, _cmd);
        return;
    }

    if ([self isKindOfClass:UIView.class]) {
        NSLayoutConstraint *height =
            [[(UIView *)self heightAnchor] constraintEqualToConstant:2.0];
        height.active = YES;
    }
    [(UIView *)self setBackgroundColor:UIColor.blackColor];

    Class labelClass = NSClassFromString(@"SBUIActionViewLabel");
    if (!labelClass)
        return;

    id titleLabel =
        ((id (*)(id, SEL, CGRect))objc_msgSend)(
            [labelClass alloc], @selector(initWithFrame:), CGRectZero);
    id subtitleLabel =
        ((id (*)(id, SEL, CGRect))objc_msgSend)(
            [labelClass alloc], @selector(initWithFrame:), CGRectZero);
    CRDynamicSetValueForKey(self, @"_titleLabel", titleLabel);
    CRDynamicSetValueForKey(self, @"_subtitleLabel", subtitleLabel);
}

static void CRLegacyActionViewSetBackgroundColor(id self,
                                                 SEL _cmd,
                                                 UIColor *color)
{
    id action =
        CRDynamicObjectGetter(self, NSSelectorFromString(@"action"));
    UIColor *effective =
        CRLegacyIsSeparatorAction(action) ? UIColor.blackColor : color;

    void (*original)(id, SEL, id) =
        (void (*)(id, SEL, id))gOrigLegacyActionViewSetBackgroundColor;
    if (original)
        original(self, _cmd, effective);
}

static id CRLegacyActionFromShortcutItem(id self,
                                         SEL _cmd,
                                         id shortcutItem)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gOrigLegacyActionFromShortcutItem;
    id action = original ? original(self, _cmd, shortcutItem) : nil;
    if (!action)
        return nil;

    CRDynamicBoolSetter(action,
                        NSSelectorFromString(@"setCrane_isSeparator:"),
                        NO);

    NSString *type =
        CRDynamicObjectGetter(shortcutItem, NSSelectorFromString(@"type"));
    if ([type isEqualToString:kLegacyContainersType]) {
        CRDynamicSetValueForKey(action,
                                @"_image",
                                CRLegacyTemplateIcon(@"ContainersIcon"));
        CRDynamicSetValueForKey(action,
                                @"_handler",
                                [^{
            CRLegacyExpandContainerOptions(self);
        } copy]);
        return action;
    }

    if ([type hasPrefix:kLegacyContainerTypePrefix]) {
        NSString *containerID =
            [type stringByReplacingOccurrencesOfString:
                      kLegacyContainerTypePrefix
                                        withString:@""];
        id dataProvider =
            CRDynamicObjectGetter(self, NSSelectorFromString(@"dataProvider"));
        NSString *appID = CRShortcutApplicationIdentifier(dataProvider);
        NSString *active =
            [CraneManager.sharedManager
                activeContainerIdentifierForApplicationWithIdentifier:appID];

        UIImage *image = [containerID isEqualToString:active]
            ? CRLegacyTemplateIcon(@"SelectedContainerCheckmark")
            : CRLegacyBlankIcon();
        CRDynamicSetValueForKey(action, @"_image", image);

        CRDynamicSetValueForKey(action,
                                @"_handler",
                                [^{
            CRLegacyHandleContainerSelection(
                self, shortcutItem, containerID, active, appID);
        } copy]);
        return action;
    }

    if ([type isEqualToString:kLegacyNewContainerType]) {
        CRDynamicSetValueForKey(action,
                                @"_image",
                                CRLegacyTemplateIcon(@"AddIcon"));
        id dataProvider =
            CRDynamicObjectGetter(self, NSSelectorFromString(@"dataProvider"));
        NSString *appID = CRShortcutApplicationIdentifier(dataProvider);
        CRDynamicSetValueForKey(action,
                                @"_handler",
                                [^{
            /* Native 0x18F04 queues presentation exactly once after
             * dismissing. CRPresentNewContainerAlert already dispatches
             * SBAlertItemsController activation to the main queue. */
            CRLegacyDismissShortcutController(self, nil);
            CRPresentNewContainerAlert(appID);
        } copy]);
        return action;
    }

    if ([type isEqualToString:kLegacyPreferencesType]) {
        CRDynamicSetValueForKey(action,
                                @"_image",
                                CRLegacyTemplateIcon(@"SettingsIcon"));
        id dataProvider =
            CRDynamicObjectGetter(self, NSSelectorFromString(@"dataProvider"));
        NSString *appID = CRShortcutApplicationIdentifier(dataProvider);
        CRDynamicSetValueForKey(action,
                                @"_handler",
                                [^{
            CROpenCraneSettings(appID);
        } copy]);
        return action;
    }

    if ([type isEqualToString:kLegacySeparatorType]) {
        CRDynamicBoolSetter(action,
                            NSSelectorFromString(@"setCrane_isSeparator:"),
                            YES);
        CRDynamicSetValueForKey(action, @"_handler", [^{} copy]);
    }

    return action;
}

static id CRLegacyNewShortcutItem(NSString *title,
                                  NSString *subtitle,
                                  NSString *type,
                                  NSString *bundleIdentifier)
{
    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    id item = [itemClass new];
    if (!item)
        return nil;

    CRDynamicObjectSetter(item,
                          NSSelectorFromString(@"setLocalizedTitle:"),
                          title);
    if (subtitle.length) {
        CRDynamicObjectSetter(item,
                              NSSelectorFromString(@"setLocalizedSubtitle:"),
                              subtitle);
    }
    CRDynamicObjectSetter(item, NSSelectorFromString(@"setType:"), type);
    if (bundleIdentifier.length) {
        CRDynamicObjectSetter(item,
                              NSSelectorFromString(
                                  @"setBundleIdentifierToLaunch:"),
                              bundleIdentifier);
    }
    return item;
}

static NSArray *CRLegacyContainerShortcutItems(id self)
{
    NSString *appID = CRShortcutApplicationIdentifier(self);
    if (!appID.length)
        return @[];

    CraneManager *manager = CraneManager.sharedManager;
    NSDictionary *settings =
        [manager applicationSettingsForApplicationWithIdentifier:appID];
    NSArray *containers = settings[CRAppSetting_Containers] ?: @[];
    NSMutableArray *items = [NSMutableArray new];
    BOOL showBadges = CRShouldShowContainerBadges(appID, settings, manager);
    BOOL rightToLeft = [UIApplication sharedApplication].userInterfaceLayoutDirection ==
        UIUserInterfaceLayoutDirectionRightToLeft;

    for (NSDictionary *container in containers) {
        NSString *containerID = container[CRCContainer_Identifier];
        if (!containerID.length)
            continue;

        NSString *title =
            [manager displayNameForContainerWithIdentifier:containerID
                               ofApplicationWithIdentifier:appID
                                    shouldUseShortVersion:YES];
        NSString *type =
            [kLegacyContainerTypePrefix
                stringByAppendingString:containerID];
        NSString *subtitle = nil;
        if (showBadges) {
            NSInteger count = CRStoredContainerBadgeCount(appID, containerID,
                                                         manager);
            if (count > 0) {
                subtitle = rightToLeft
                    ? [NSString stringWithFormat:@"⬤ %d", (int)count]
                    : [NSString stringWithFormat:@"%d ⬤", (int)count];
            }
        }
        id item = CRLegacyNewShortcutItem(
            title ?: containerID, subtitle, type, appID);
        if (item)
            [items addObject:item];
    }

    if (CRPrefBool(CRPref_NewContainerShortcut)) {
        id item = CRLegacyNewShortcutItem(
            CRLocalize(@"NEW_CONTAINER"),
            nil,
            kLegacyNewContainerType,
            nil);
        if (item)
            [items addObject:item];
    }

    if (!CRPrefBool(CRPref_ExpandContainersShortcut)) {
        id separator =
            CRLegacyNewShortcutItem(nil, nil, kLegacySeparatorType, nil);
        if (separator)
            [items addObject:separator];
    }

    id settingsItem = CRLegacyNewShortcutItem(
        CRLocalize(@"SETTINGS"), nil, kLegacyPreferencesType, nil);
    if (settingsItem)
        [items addObject:settingsItem];

    return items;
}

static NSArray *CRLegacyContainerShortcutItemsMethod(id self, SEL _cmd)
{
    (void)_cmd;
    return CRLegacyContainerShortcutItems(self);
}

static NSArray *CRLegacyApplicationShortcutItems(id self, SEL _cmd)
{
    NSArray *(*original)(id, SEL) =
        (NSArray *(*)(id, SEL))gOrigLegacyApplicationShortcutItems;

    NSString *appID = CRShortcutApplicationIdentifier(self);
    if (!appID.length ||
        !CRPrefBool(CRPref_AppShortcutEnabled) ||
        ![CraneManager.sharedManager isApplicationSupportedByCrane:appID]) {
        return original ? original(self, _cmd) : nil;
    }

    id controller =
        CRDynamicObjectGetter(self, NSSelectorFromString(@"controller"));
    if (CRDynamicBoolGetter(
            controller,
            NSSelectorFromString(@"crane_provideContainerOptions"))) {
        CRDynamicBoolSetter(
            controller,
            NSSelectorFromString(@"setCrane_provideContainerOptions:"),
            NO);
        return CRLegacyContainerShortcutItems(self);
    }

    NSDictionary *settings =
        [CraneManager.sharedManager
            applicationSettingsForApplicationWithIdentifier:appID];
    NSArray *containers = settings[CRAppSetting_Containers] ?: @[];
    NSArray *existing = original ? original(self, _cmd) : nil;

    if (containers.count <= 1 &&
        CRPrefBool(CRPref_OnlyShowIfContainersExist)) {
        return existing;
    }

    if (CRPrefBool(CRPref_ExpandContainersShortcut)) {
        NSArray *craneItems = CRLegacyContainerShortcutItems(self);
        /* Native 0x170A4 distinguishes a nil original shortcut list
         * from a real, but empty, NSArray. The latter still gets the
         * separator before Crane's expanded container actions. */
        if (!existing)
            return craneItems;

        id separator =
            CRLegacyNewShortcutItem(nil, nil, kLegacySeparatorType, nil);
        NSMutableArray *combined = [existing mutableCopy];
        if (separator)
            [combined addObject:separator];
        [combined addObjectsFromArray:craneItems];
        return combined;
    }

    NSString *active =
        [CraneManager.sharedManager
            activeContainerIdentifierForApplicationWithIdentifier:appID];
    NSString *activeName =
        [CraneManager.sharedManager
            displayNameForContainerWithIdentifier:active
                       ofApplicationWithIdentifier:appID
                            shouldUseShortVersion:YES];

    id parent = CRLegacyNewShortcutItem(
        CRLocalize(@"CONTAINER"),
        activeName,
        kLegacyContainersType,
        nil);
    if (!parent)
        return existing;

    return existing ? [existing arrayByAddingObject:parent] : @[parent];
}

static void CRInitLegacyApplicationShortcutHooks(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class forceTouchViewController =
            NSClassFromString(@"SBUIIconForceTouchViewController");
        SEL dismissSelector =
            NSSelectorFromString(@"dismissAnimated:withCompletionHandler:");
        if (forceTouchViewController &&
            [forceTouchViewController
                instancesRespondToSelector:dismissSelector]) {
            MSHookMessageEx(forceTouchViewController,
                            dismissSelector,
                            (IMP)CRLegacyDismissHook,
                            &gOrigLegacyForceTouchDismiss);
        }

        Class controllerClass =
            NSClassFromString(@"SBUIAppIconForceTouchController");
        if (controllerClass) {
            objc_property_attribute_t attributes[] = {
                {"T", "B"},
                {"N", ""}
            };
            class_addProperty(controllerClass,
                              "crane_provideContainerOptions",
                              attributes,
                              2);
            class_addMethod(controllerClass,
                            NSSelectorFromString(
                                @"crane_provideContainerOptions"),
                            (IMP)CRLegacyProvidesContainerOptions,
                            "B@:");
            class_addMethod(controllerClass,
                            NSSelectorFromString(
                                @"setCrane_provideContainerOptions:"),
                            (IMP)CRLegacySetProvidesContainerOptions,
                            "v@:B");

            SEL initSelector = @selector(init);
            if ([controllerClass
                    instancesRespondToSelector:initSelector]) {
                MSHookMessageEx(controllerClass,
                                initSelector,
                                (IMP)CRLegacyForceTouchControllerInit,
                                &gOrigLegacyForceTouchControllerInit);
            }
        }

        Class actionClass = NSClassFromString(@"SBUIAction");
        if (actionClass) {
            objc_property_attribute_t attributes[] = {
                {"T", "B"},
                {"N", ""}
            };
            class_addProperty(actionClass,
                              "crane_isSeparator",
                              attributes,
                              2);
            class_addMethod(actionClass,
                            NSSelectorFromString(@"crane_isSeparator"),
                            (IMP)CRLegacyActionIsSeparator,
                            "B@:");
            class_addMethod(actionClass,
                            NSSelectorFromString(@"setCrane_isSeparator:"),
                            (IMP)CRLegacySetActionIsSeparator,
                            "v@:B");
        }

        Class actionViewClass = NSClassFromString(@"SBUIActionView");
        if (actionViewClass) {
            SEL highlighted =
                NSSelectorFromString(@"setHighlighted:");
            if ([actionViewClass
                    instancesRespondToSelector:highlighted]) {
                MSHookMessageEx(actionViewClass,
                                highlighted,
                                (IMP)CRLegacyActionViewSetHighlighted,
                                &gOrigLegacyActionViewSetHighlighted);
            }

            SEL setup = NSSelectorFromString(@"_setupSubviews");
            if ([actionViewClass instancesRespondToSelector:setup]) {
                MSHookMessageEx(actionViewClass,
                                setup,
                                (IMP)CRLegacyActionViewSetupSubviews,
                                &gOrigLegacyActionViewSetupSubviews);
            }

            SEL background =
                NSSelectorFromString(@"setBackgroundColor:");
            if ([actionViewClass
                    instancesRespondToSelector:background]) {
                MSHookMessageEx(actionViewClass,
                                background,
                                (IMP)CRLegacyActionViewSetBackgroundColor,
                                &gOrigLegacyActionViewSetBackgroundColor);
            }
        }

        Class shortcutViewController =
            NSClassFromString(
                @"SBUIAppIconForceTouchShortcutViewController");
        SEL actionSelector =
            NSSelectorFromString(
                @"_actionFromApplicationShortcutItem:");
        if (shortcutViewController &&
            [shortcutViewController
                instancesRespondToSelector:actionSelector]) {
            MSHookMessageEx(shortcutViewController,
                            actionSelector,
                            (IMP)CRLegacyActionFromShortcutItem,
                            &gOrigLegacyActionFromShortcutItem);
        }
    });
}

void CRInitApplicationShortcutLateHooks(void)
{
    if (kCFCoreFoundationVersionNumber >= 1665.15)
        return;

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class dataProviderClass =
            NSClassFromString(
                @"SBUIAppIconForceTouchControllerDataProvider");
        if (!dataProviderClass)
            return;

        class_addMethod(dataProviderClass,
                        NSSelectorFromString(
                            @"craneContainersApplicationShortcutItems"),
                        (IMP)CRLegacyContainerShortcutItemsMethod,
                        "@@:");

        SEL itemsSelector =
            NSSelectorFromString(@"applicationShortcutItems");
        if ([dataProviderClass
                instancesRespondToSelector:itemsSelector]) {
            MSHookMessageEx(dataProviderClass,
                            itemsSelector,
                            (IMP)CRLegacyApplicationShortcutItems,
                            &gOrigLegacyApplicationShortcutItems);
        }
    });
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
static IMP gOrigBadgeActionCopyInit;

/* 0x16820: preserve badge metadata when UIKit clones a UIAction. */
static id CRBadgeActionCopyInit(id self, SEL _cmd, id source)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gOrigBadgeActionCopyInit;
    id result = original ? original(self, _cmd, source) : nil;
    Class badgeClass = NSClassFromString(@"CRBadgeAction");
    if (result && badgeClass && [source isKindOfClass:badgeClass]) {
        object_setClass(result, badgeClass);
        CRDynamicObjectSetter(result, NSSelectorFromString(@"setBadgeText:"),
            CRDynamicObjectGetter(source, NSSelectorFromString(@"badgeText")));
        CRDynamicObjectSetter(result,
            NSSelectorFromString(@"setAssociatedApplicationID:"),
            CRDynamicObjectGetter(source,
                NSSelectorFromString(@"associatedApplicationID")));
    }
    return result;
}

static BOOL CRShortcutIsSystem(id self, SEL _cmd)
{
    if ([CRDynamicObjectGetter(self, NSSelectorFromString(@"type"))
            isEqualToString:kApplicationContainerType])
        return !CRPrefBool(CRPref_ExpandContainersShortcut);

    BOOL (*original)(id, SEL) =
        (BOOL (*)(id, SEL))gOrigShortcutIsSystem;
    return original ? original(self, _cmd) : NO;
}

static NSInteger CRShortcutSection(id self, SEL _cmd)
{
    if ([CRDynamicObjectGetter(self, NSSelectorFromString(@"type"))
            isEqualToString:kApplicationContainerType])
        return CRPrefBool(CRPref_ExpandContainersShortcut) ? 1 : 2;

    NSInteger (*original)(id, SEL) =
        (NSInteger (*)(id, SEL))gOrigShortcutSection;
    return original ? original(self, _cmd) : 0;
}

static NSString *CRShortcutApplicationIdentifier(id self)
{
    SEL primary = NSSelectorFromString(@"applicationBundleIdentifier");
    if ([self respondsToSelector:primary])
        return CRDynamicObjectGetter(self, primary);

    SEL shortcuts =
        NSSelectorFromString(@"applicationBundleIdentifierForShortcuts");
    if ([self respondsToSelector:shortcuts])
        return CRDynamicObjectGetter(self, shortcuts);
    return nil;
}

static NSArray *CRApplicationShortcutItems(id self, SEL _cmd)
{
    NSArray *(*original)(id, SEL) =
        (NSArray *(*)(id, SEL))gOrigApplicationShortcutItems;
    NSArray *existing = original ? original(self, _cmd) : nil;

    if (!CRPrefBool(CRPref_AppShortcutEnabled)) {
        NSLog(@"CraneSB: shortcut query skipped: applicationShortcutEnabled=NO");
        return existing;
    }

    NSString *appID = CRShortcutApplicationIdentifier(self);
    if (!appID.length ||
        ![CraneManager.sharedManager isApplicationSupportedByCrane:appID]) {
        NSLog(@"CraneSB: shortcut query skipped: app=%@ unsupported or missing identifier", appID);
        return existing;
    }

    NSDictionary *settings =
        [CraneManager.sharedManager
            applicationSettingsForApplicationWithIdentifier:appID];
    NSArray *containers = settings[CRAppSetting_Containers] ?: @[];
    if (containers.count <= 1 &&
        CRPrefBool(CRPref_OnlyShowIfContainersExist)) {
        NSLog(@"CraneSB: shortcut query skipped: app=%@ containers=%lu onlyShow=YES",
              appID, (unsigned long)containers.count);
        return existing;
    }

    Class itemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    id placeholder = [itemClass new];
    if (!placeholder) {
        NSLog(@"CraneSB: shortcut query skipped: SBSApplicationShortcutItem unavailable");
        return existing;
    }
    NSLog(@"CraneSB: shortcut placeholder app=%@ containers=%lu",
          appID, (unsigned long)containers.count);

    CRDynamicObjectSetter(placeholder,
                          NSSelectorFromString(@"setLocalizedTitle:"),
                          kMenuPlaceholder);
    CRDynamicObjectSetter(placeholder,
                          NSSelectorFromString(@"setBundleIdentifierToLaunch:"),
                          nil);
    CRDynamicObjectSetter(placeholder,
                          NSSelectorFromString(@"setType:"),
                          kApplicationContainerType);

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
    if (CRPrefBool(CRPref_AppShortcutEnabled)) {
        gCRSelectedApplicationIdentifier =
            [CRShortcutApplicationIdentifier(self) copy];
        NSLog(@"CraneSB: context menu selected app=%@", gCRSelectedApplicationIdentifier);
    }

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

/* Native 0x7F58/0x8530/0x8ED4 uses SBIconBadgeView driven by a
 * CRFakeIcon (SBApplicationIcon subclass). Construct it only when the same
 * private classes/selectors exist; otherwise retain the UILabel fallback.
 * Never change a UIKit private action view's class at runtime. */
static char kCRMenuBadgeLabelKey;
static char kCRMenuNativeBadgeViewKey;
static char kCRMenuNativeBadgeTextKey;
static char kCRMenuNativeBadgeAppKey;
static char kCRMenuAdjustedConstraintKey;
static char kCRMenuOriginalConstraintConstantKey;
static char kCRFakeIconTextKey;

/* Native 0x8778 reserves intrinsic badge width + 5pt by shifting the
 * action view's existing label/trailing constraint. Unlike the original
 * one-time private-class constraint hook, record each baseline per view
 * so UIKit cell reuse and changing badge widths can restore it safely. */
static void CRMenuRestoreBadgeSpacing(UIView *view)
{
    NSLayoutConstraint *adjusted = objc_getAssociatedObject(
        view, &kCRMenuAdjustedConstraintKey);
    NSNumber *baseline = objc_getAssociatedObject(
        view, &kCRMenuOriginalConstraintConstantKey);
    if (adjusted && baseline && [view.constraints containsObject:adjusted])
        adjusted.constant = [baseline doubleValue];
    objc_setAssociatedObject(view, &kCRMenuAdjustedConstraintKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kCRMenuOriginalConstraintConstantKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void CRMenuReserveBadgeSpacing(UIView *view, CGFloat width)
{
    CRMenuRestoreBadgeSpacing(view);
    if (!(width > 0.0 && width < 300.0))
        return;
    /* Native 0x8778 prefers trailingView.centerX; older layouts instead
     * use labelStackView.trailing. Never modify an unknown constraint. */
    id trailing = CRDynamicObjectGetter(
        view, NSSelectorFromString(@"trailingView"));
    if (![trailing isKindOfClass:[UIView class]])
        trailing = CRDynamicObjectGetter(
            view, NSSelectorFromString(@"imageView"));
    if (![trailing isKindOfClass:[UIView class]])
        trailing = CRDynamicObjectGetter(
            view, NSSelectorFromString(@"iconImageView"));
    NSLayoutXAxisAnchor *firstAnchor = nil;
    if ([trailing isKindOfClass:[UIView class]])
        firstAnchor = [(UIView *)trailing centerXAnchor];
    else {
        id stack = CRDynamicObjectGetter(
            view, NSSelectorFromString(@"labelStackView"));
        if ([stack isKindOfClass:[UIView class]])
            firstAnchor = [(UIView *)stack trailingAnchor];
    }
    if (!firstAnchor)
        return;
    NSLayoutXAxisAnchor *lastAnchor = view.trailingAnchor;
    for (NSLayoutConstraint *constraint in view.constraints) {
        if (![constraint.firstAnchor isEqual:firstAnchor] ||
            ![constraint.secondAnchor isEqual:lastAnchor])
            continue;
        CGFloat baseline = constraint.constant;
        constraint.constant = baseline - (width + 5.0);
        objc_setAssociatedObject(view, &kCRMenuAdjustedConstraintKey,
            constraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kCRMenuOriginalConstraintConstantKey,
            @(baseline), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        break;
    }
}

static IMP gCRMenuFakeIconUndefinedKeyOriginal;

static id CRMenuFakeIconText(id self, SEL cmd)
{
    (void)cmd;
    return objc_getAssociatedObject(self, &kCRFakeIconTextKey);
}

static void CRMenuFakeIconSetText(id self, SEL cmd, id text)
{
    (void)cmd;
    objc_setAssociatedObject(self, &kCRFakeIconTextKey,
                             [text copy], OBJC_ASSOCIATION_COPY_NONATOMIC);
}

static id CRMenuFakeIconAccessoryText(id self, SEL cmd, id location)
{
    (void)cmd; (void)location;
    return CRMenuFakeIconText(self, @selector(text));
}

static id CRMenuFakeIconApplicationBundleID(id self, SEL cmd)
{
    (void)cmd;
    /* Native 0x8444 uses KVC _application, with 0x84A0 mapping an
     * undefined private key back to the normal application getter. */
    id application = CRDynamicValueForKey(self, @"_application");
    return CRDynamicObjectGetter(application, NSSelectorFromString(@"bundleIdentifier"));
}

/* Native 0x84A0 maps KVC _application to SBApplicationIcon.application.
 * Preserve the inherited undefined-key behavior for all other keys. */
static id CRMenuFakeIconUndefinedKey(id self, SEL cmd, id key)
{
    if ([key isEqualToString:@"_application"])
        return CRDynamicObjectGetter(self, NSSelectorFromString(@"application"));
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gCRMenuFakeIconUndefinedKeyOriginal;
    return original ? original(self, cmd, key) : nil;
}

static Class CRMenuFakeIconClass(void)
{
    static Class fakeClass;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Class baseClass = NSClassFromString(@"SBApplicationIcon");
        if (!baseClass)
            return;
        fakeClass = NSClassFromString(@"CRFakeIcon");
        if (fakeClass)
            return;
        Class created = objc_allocateClassPair(baseClass, "CRFakeIcon", 0);
        if (!created)
            return;
        class_addMethod(created, @selector(text),
                        (IMP)CRMenuFakeIconText, "@@:");
        class_addMethod(created, @selector(setText:),
                        (IMP)CRMenuFakeIconSetText, "v@:@");
        class_addMethod(created, @selector(accessoryTextForLocation:),
                        (IMP)CRMenuFakeIconAccessoryText, "@@:@");
        class_addMethod(created, @selector(applicationBundleID),
                        (IMP)CRMenuFakeIconApplicationBundleID, "@@:");
        SEL undefinedSEL = @selector(valueForUndefinedKey:);
        Method inherited = class_getInstanceMethod(baseClass, undefinedSEL);
        if (inherited) {
            gCRMenuFakeIconUndefinedKeyOriginal = method_getImplementation(inherited);
            class_addMethod(created, undefinedSEL,
                            (IMP)CRMenuFakeIconUndefinedKey, "@@:@");
        }
        objc_registerClassPair(created);
        fakeClass = created;
    });
    return fakeClass;
}

static UIView *CRMenuCreateNativeBadgeView(NSString *appID, NSString *badgeText)
{
    Class badgeClass = NSClassFromString(@"SBIconBadgeView");
    Class fakeClass = CRMenuFakeIconClass();
    Class controllerClass = NSClassFromString(@"SBApplicationController");
    SEL sharedSEL = NSSelectorFromString(@"sharedInstance");
    SEL applicationSEL = NSSelectorFromString(@"applicationWithBundleIdentifier:");
    SEL initSEL = NSSelectorFromString(@"initWithApplication:");
    SEL configureSEL = NSSelectorFromString(@"configureForIcon:infoProvider:");
    if (!badgeClass || !fakeClass || !appID.length || !badgeText.length ||
        ![controllerClass respondsToSelector:sharedSEL] ||
        ![fakeClass instancesRespondToSelector:initSEL] ||
        ![badgeClass instancesRespondToSelector:configureSEL])
        return nil;
    @try {
        id controller = CRDynamicObjectGetter(controllerClass, sharedSEL);
        id application = [controller respondsToSelector:applicationSEL]
            ? ((id (*)(id, SEL, id))objc_msgSend)(
                controller, applicationSEL, appID) : nil;
        if (!application)
            return nil;
        id fakeIcon = ((id (*)(id, SEL, id))objc_msgSend)(
            [fakeClass alloc], initSEL, application);
        if (!fakeIcon)
            return nil;
        CRMenuFakeIconSetText(fakeIcon, @selector(setText:), badgeText);
        id badge = [[badgeClass alloc] init];
        if (![badge isKindOfClass:[UIView class]])
            return nil;
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            badge, configureSEL, fakeIcon, nil);
        return (UIView *)badge;
    } @catch (NSException *exception) {
        (void)exception;
        return nil;
    }
}
static void CRApplyBadgeToActionView(id actionView, id element)
{
    if (![actionView isKindOfClass:[UIView class]])
        return;
    UIView *view = (UIView *)actionView;
    UILabel *label = objc_getAssociatedObject(view, &kCRMenuBadgeLabelKey);
    Class badgeClass = NSClassFromString(@"CRBadgeAction");
    BOOL isBadge = badgeClass && [element isKindOfClass:badgeClass];
    NSString *badgeText = isBadge
        ? CRDynamicObjectGetter(element, NSSelectorFromString(@"badgeText"))
        : nil;
    UIView *native = objc_getAssociatedObject(view, &kCRMenuNativeBadgeViewKey);
    if (![badgeText isKindOfClass:[NSString class]] || !badgeText.length) {
        /* UIKit reuses action views. Remove stale native badges when a
         * normal UIAction takes over the same cell (native 0x13508). */
        [native removeFromSuperview];
        CRMenuRestoreBadgeSpacing(view);
        objc_setAssociatedObject(view, &kCRMenuNativeBadgeViewKey,
                                 nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kCRMenuNativeBadgeTextKey,
                                 nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(view, &kCRMenuNativeBadgeAppKey,
                                 nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
        label.hidden = YES;
        return;
    }
    NSString *appID = CRDynamicObjectGetter(
        element, NSSelectorFromString(@"associatedApplicationID"));
    NSString *previousText = objc_getAssociatedObject(
        view, &kCRMenuNativeBadgeTextKey);
    NSString *previousApp = objc_getAssociatedObject(
        view, &kCRMenuNativeBadgeAppKey);
    if (native && native.superview == view &&
        [previousText isEqualToString:badgeText] &&
        [previousApp isEqualToString:appID]) {
        label.hidden = YES;
        return;
    }
    [native removeFromSuperview];
    CRMenuRestoreBadgeSpacing(view);
    objc_setAssociatedObject(view, &kCRMenuNativeBadgeViewKey,
                             nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *replacement = CRMenuCreateNativeBadgeView(appID, badgeText);
    CGFloat badgeWidth = replacement ? replacement.intrinsicContentSize.width : 0.0;
    /* 0x8778 constrains the native badge to intrinsic width. Invalid
     * measurements must fall back rather than leave an ambiguous view. */
    if (!(badgeWidth > 0.0 && badgeWidth < 300.0))
        replacement = nil;
    if (replacement) {
        replacement.translatesAutoresizingMaskIntoConstraints = NO;
        [view addSubview:replacement];
        [NSLayoutConstraint activateConstraints:@[
            [replacement.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
            [replacement.trailingAnchor constraintEqualToAnchor:view.trailingAnchor
                                                        constant:-16.0],
            [replacement.widthAnchor constraintEqualToConstant:badgeWidth]
        ]];
        CRMenuReserveBadgeSpacing(view, badgeWidth);
        objc_setAssociatedObject(view, &kCRMenuNativeBadgeViewKey,
                                 replacement, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kCRMenuNativeBadgeTextKey,
                                 badgeText, OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(view, &kCRMenuNativeBadgeAppKey,
                                 appID, OBJC_ASSOCIATION_COPY_NONATOMIC);
        label.hidden = YES;
        return;
    }
    /* Private SpringBoard badges are unavailable on some OS versions.
     * Keep the existing lightweight view instead of forcing an object ISA. */
    objc_setAssociatedObject(view, &kCRMenuNativeBadgeTextKey,
                             nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(view, &kCRMenuNativeBadgeAppKey,
                             nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
    if (!label) {
        label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [UIFont boldSystemFontOfSize:12.0];
        label.textAlignment = NSTextAlignmentCenter;
        label.textColor = [UIColor whiteColor];
        label.backgroundColor = [UIColor systemRedColor];
        label.layer.cornerRadius = 10.0;
        label.clipsToBounds = YES;
        [view addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
            [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor
                                                 constant:-16.0],
            [label.heightAnchor constraintGreaterThanOrEqualToConstant:20.0],
            [label.widthAnchor constraintGreaterThanOrEqualToConstant:20.0]
        ]];
        objc_setAssociatedObject(view, &kCRMenuBadgeLabelKey,
                                 label, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.text = badgeText;
    label.hidden = NO;
    [label sizeToFit];
    CRMenuReserveBadgeSpacing(view,
        MAX(20.0, label.intrinsicContentSize.width + 10.0));
}

static void CRApplyBadgeToCell(id cell, id element)
{
    id actionView = CRDynamicObjectGetter(cell, NSSelectorFromString(@"actionView"));
    CRApplyBadgeToActionView(actionView, element);
}

static void CRApplySubtitleToCell(id cell, id element)
{
    if (![element isKindOfClass:CRSubtitleMenu.class])
        return;

    id actionView =
        CRDynamicObjectGetter(cell, NSSelectorFromString(@"actionView"));
    CRDynamicObjectSetter(actionView,
                          NSSelectorFromString(@"setSubtitle:"),
                          ((CRSubtitleMenu *)element).subtitle);
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
    CRApplyBadgeToCell(cell, element);
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
    CRApplyBadgeToCell(cell, element);
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
    CRApplyBadgeToCell(cell, element);
}

static id CRInterfaceActionGroup(id self, SEL _cmd, NSArray *elements)
{
    id (*original)(id, SEL, id) =
        (id (*)(id, SEL, id))gOrigInterfaceActionGroup;
    id group = original ? original(self, _cmd, elements) : nil;
    if (!group)
        return group;

    NSArray *actions =
        CRDynamicObjectGetter(group, NSSelectorFromString(@"actions"));
    BOOL reverse =
        CRDynamicBoolGetter(self, NSSelectorFromString(@"reversesActionOrder"));

    [elements enumerateObjectsUsingBlock:
        ^(id element, NSUInteger index, BOOL *stop) {
        (void)stop;
        Class badgeClass = NSClassFromString(@"CRBadgeAction");
        BOOL isBadge = badgeClass && [element isKindOfClass:badgeClass];
        if (![element isKindOfClass:CRSubtitleMenu.class] && !isBadge)
            return;

        NSUInteger mapped =
            reverse ? (elements.count - 1 - index) : index;
        if (mapped >= actions.count)
            return;

        id interfaceAction = actions[mapped];
        id customView =
            CRDynamicObjectGetter(interfaceAction,
                                  NSSelectorFromString(@"customContentView"));
        NSString *title = nil;
        UIImage *image = nil;
        if (customView) {
            id titleLabel =
                CRDynamicObjectGetter(customView,
                                      NSSelectorFromString(@"titleLabel"));
            title = CRDynamicObjectGetter(titleLabel,
                                          NSSelectorFromString(@"text"));
            id imageView =
                CRDynamicObjectGetter(customView,
                                      NSSelectorFromString(@"imageView"));
            image = CRDynamicObjectGetter(imageView,
                                          NSSelectorFromString(@"image"));
        }

        /* Native 0x190D4 builds a badge-aware custom view in group
         * layouts. When UIKit did not expose its action view yet, create a
         * guarded normal action view and attach our badge without changing
         * the class/ivar layout of UIKit's private subclass. */
        if (isBadge) {
            if (![customView isKindOfClass:[UIView class]]) {
                Class viewClass = NSClassFromString(@"_UIContextMenuActionView");
                SEL initSEL = NSSelectorFromString(@"initWithTitle:subtitle:image:");
                if (viewClass && [viewClass instancesRespondToSelector:initSEL]) {
                    @try {
                        id actionTitle = title ?: CRDynamicObjectGetter(
                            element, NSSelectorFromString(@"title"));
                        id actionImage = image ?: CRDynamicObjectGetter(
                            element, NSSelectorFromString(@"image"));
                        id configured = ((id (*)(id, SEL, id, id, id))objc_msgSend)(
                            [viewClass alloc], initSEL, actionTitle, nil,
                            actionImage);
                        if ([configured isKindOfClass:[UIView class]]) {
                            [interfaceAction setValue:configured
                                              forKey:@"_customContentView"];
                            customView = CRDynamicObjectGetter(interfaceAction,
                                NSSelectorFromString(@"customContentView"));
                        }
                    } @catch (NSException *exception) {
                        (void)exception;
                    }
                }
            }
            CRApplyBadgeToActionView(customView, element);
            return;
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
    if (kCFCoreFoundationVersionNumber < 1665.15) {
        CRInitLegacyApplicationShortcutHooks();
        return;
    }

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

    NSLog(@"CraneSB: shortcut hooks SBIconView=%@ items=%@ context=%@",
          iconViewClass ? @"YES" : @"NO",
          gOrigApplicationShortcutItems ? @"YES" : @"NO",
          gOrigContextMenuConfiguration ? @"YES" : @"NO");

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

    Class actionClass = NSClassFromString(@"UIAction");
    SEL copySelector = NSSelectorFromString(@"initWithAction:");
    if (actionClass && [actionClass instancesRespondToSelector:copySelector]) {
        MSHookMessageEx(actionClass, copySelector,
                        (IMP)CRBadgeActionCopyInit,
                        &gOrigBadgeActionCopyInit);
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
