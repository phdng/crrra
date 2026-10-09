/*
 * CRErrorAlerts.m — CraneSB self-verification / user-visible failure alerts.
 *
 * Recovered from:
 *   CRErrorAlert runtime class                 0x9684
 *   configure:/reappearsAfterUnlock hooks      0x9A60 / 0x9DA4
 *   daemon-name formatting                     0x197A4
 *   libSandy presenter                         0x19A2C
 *   daemon/insurance presenter                 0x19E70
 *   main-dylib presenter                       0x1A68C
 *   apsd registration presenter                0x1AA34
 *   pkd registration presenter                 0x1AEC0
 *   UNS listener bridge                        0x17620
 *
 * SpringBoard private classes are resolved dynamically; no private framework
 * headers or link-time dependencies are introduced.
 */

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

#import "CRManager.h"
#import "CRPaths.h"
#import "CRPreferences.h"
#import "CRCommon.h"

@interface NSObject (CraneErrorAlertRuntime)
+ (id)sharedInstance;
- (id)alertController;
- (void)setIgnoreIfAlreadyDisplaying:(BOOL)value;
- (void)deactivateForButton;
- (void)activateAlertItem:(id)item;
- (void)exitAndRelaunch:(BOOL)relaunch;
- (void)openApplication:(NSString *)appID
            withOptions:(id)options
             completion:(id)completion;
@end

@interface UIAlertAction (CraneErrorAlertPrivate)
- (id)handler;
- (void)setHandler:(void (^)(UIAlertAction *action))handler;
@end

@interface CraneManager (CraneErrorAlertProxy)
- (id)_userNotificationsSyncRemoteProxy;
@end

static BOOL CRAlertsRunningInSpringBoard(void)
{
    return [CRGetProcessName() isEqualToString:@"SpringBoard"];
}

/* ------------------------------------------------------------------------- */
/* CRErrorAlert associated properties                                        */
/* ------------------------------------------------------------------------- */

static id CRErrorAlertErrorTitle(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self,
                                    (const void *)&CRErrorAlertErrorTitle);
}

static void CRErrorAlertSetErrorTitle(id self, SEL _cmd, id value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             (const void *)&CRErrorAlertErrorTitle,
                             value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id CRErrorAlertErrorMessage(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self,
                                    (const void *)&CRErrorAlertErrorMessage);
}

static void CRErrorAlertSetErrorMessage(id self, SEL _cmd, id value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             (const void *)&CRErrorAlertErrorMessage,
                             value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id CRErrorAlertActions(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(self,
                                    (const void *)&CRErrorAlertActions);
}

static void CRErrorAlertSetActions(id self, SEL _cmd, id value)
{
    (void)_cmd;
    objc_setAssociatedObject(self,
                             (const void *)&CRErrorAlertActions,
                             value,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static BOOL CRErrorAlertReappears(id self, SEL _cmd)
{
    (void)_cmd;
    NSValue *value =
        objc_getAssociatedObject(self,
                                 (const void *)&CRErrorAlertReappears);
    BOOL result = NO;
    [value getValue:&result];
    return result;
}

static void CRErrorAlertSetReappears(id self, SEL _cmd, BOOL value)
{
    (void)_cmd;
    NSValue *boxed = [NSValue valueWithBytes:&value objCType:@encode(BOOL)];
    objc_setAssociatedObject(self,
                             (const void *)&CRErrorAlertReappears,
                             boxed,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void CRErrorAlertConfigure(id self,
                                  SEL _cmd,
                                  BOOL requirePasscode,
                                  BOOL requirePasscodeForActions)
{
    (void)_cmd;
    (void)requirePasscode;
    (void)requirePasscodeForActions;

    UIAlertController *controller = [self alertController];
    if (!controller)
        return;

    [controller setTitle:[self valueForKey:@"errorTitle"]];
    [controller setMessage:[self valueForKey:@"errorMessage"]];

    NSArray *actions = [self valueForKey:@"actions"];
    for (UIAlertAction *action in actions) {
        if (![action handler]) {
            __weak id weakAlert = self;
            [action setHandler:^(__unused UIAlertAction *selectedAction) {
                [weakAlert deactivateForButton];
            }];
        }
        [controller addAction:action];
    }
}

static BOOL CRErrorAlertReappearsAfterUnlock(id self, SEL _cmd)
{
    (void)_cmd;
    return ((BOOL (*)(id, SEL))objc_msgSend)(
        self,
        NSSelectorFromString(@"crane_reappearsAfterUnlock"));
}

static id CRNewContainerAlertApplicationID(id self, SEL _cmd)
{
    (void)_cmd;
    return objc_getAssociatedObject(
        self,
        (const void *)&CRNewContainerAlertApplicationID);
}

static void CRNewContainerAlertSetApplicationID(id self,
                                                 SEL _cmd,
                                                 id value)
{
    (void)_cmd;
    objc_setAssociatedObject(
        self,
        (const void *)&CRNewContainerAlertApplicationID,
        value,
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void CRNewContainerAlertConfigure(id self,
                                         SEL _cmd,
                                         BOOL requirePasscode,
                                         BOOL requirePasscodeForActions)
{
    (void)_cmd;
    (void)requirePasscode;
    (void)requirePasscodeForActions;

    UIAlertController *controller = [self alertController];
    if (!controller)
        return;

    controller.title = CRLocalize(@"NEW_CONTAINER");
    controller.message = @"";
    [controller addTextFieldWithConfigurationHandler:
        ^(__unused UITextField *textField) {}];

    NSString *primaryKey =
        CRPrefBool(CRPref_LaunchAppOnContainerSelection) ? @"LAUNCH" : @"CREATE";
    __weak id weakAlert = self;
    __weak UIAlertController *weakController = controller;
    UIAlertAction *primary =
        [UIAlertAction actionWithTitle:CRLocalize(primaryKey)
                                 style:UIAlertActionStyleDefault
                               handler:^(__unused UIAlertAction *action) {
        NSString *name = weakController.textFields.firstObject.text;
        if (!name.length)
            return;

        NSString *appID = [weakAlert valueForKey:@"applicationID"];
        CraneManager *manager = CraneManager.sharedManager;
        NSString *containerID =
            [manager createNewContainerWithName:name
                    forApplicationWithIdentifier:appID];
        [weakAlert deactivateForButton];

        if (!containerID)
            return;
        [manager setActiveContainerIdentifier:containerID
                     forApplicationWithIdentifier:appID];

        if (CRPrefBool(CRPref_LaunchAppOnContainerSelection)) {
            Class serviceClass = NSClassFromString(@"FBSOpenApplicationService");
            id service = [serviceClass new];
            if ([service respondsToSelector:
                    NSSelectorFromString(@"openApplication:withOptions:completion:")]) {
                [service openApplication:appID withOptions:nil completion:nil];
            }
        }
    }];
    [controller addAction:primary];

    UIAlertAction *cancel =
        [UIAlertAction actionWithTitle:CRLocalize(@"CANCEL")
                                 style:UIAlertActionStyleCancel
                               handler:^(__unused UIAlertAction *action) {
        [weakAlert deactivateForButton];
    }];
    [controller addAction:cancel];
}

static void CRInitNewContainerAlert(void)
{
    if (NSClassFromString(@"CRNewContainerAlert"))
        return;

    Class alertItemClass = NSClassFromString(@"SBAlertItem");
    if (!alertItemClass)
        return;

    Class cls = objc_allocateClassPair(alertItemClass,
                                       "CRNewContainerAlert",
                                       0);
    if (!cls)
        return;

    objc_property_attribute_t attributes[] = {
        { "T", "@\"NSString\"" },
        { "&", "" },
        { "N", "" },
    };
    class_addProperty(cls, "applicationID", attributes, 3);
    class_addMethod(cls,
                    NSSelectorFromString(@"applicationID"),
                    (IMP)CRNewContainerAlertApplicationID,
                    "@@:");
    class_addMethod(cls,
                    NSSelectorFromString(@"setApplicationID:"),
                    (IMP)CRNewContainerAlertSetApplicationID,
                    "v@:@");
    objc_registerClassPair(cls);

    MSHookMessageEx(cls,
                    NSSelectorFromString(
                        @"configure:requirePasscodeForActions:"),
                    (IMP)CRNewContainerAlertConfigure,
                    NULL);
}

void CRInitErrorAlerts(void)
{
    if (NSClassFromString(@"CRErrorAlert")) {
        CRInitNewContainerAlert();
        return;
    }

    Class alertItemClass = NSClassFromString(@"SBAlertItem");
    if (!alertItemClass)
        return;

    Class cls = objc_allocateClassPair(alertItemClass, "CRErrorAlert", 0);
    if (!cls)
        return;

    objc_property_attribute_t stringAttributes[] = {
        { "T", "@\"NSString\"" },
        { "&", "" },
        { "N", "" },
    };
    objc_property_attribute_t arrayAttributes[] = {
        { "T", "@\"NSArray\"" },
        { "&", "" },
        { "N", "" },
    };
    objc_property_attribute_t boolAttributes[] = {
        { "T", "B" },
        { "N", "" },
    };

    class_addProperty(cls, "errorTitle", stringAttributes, 3);
    class_addMethod(cls,
                    NSSelectorFromString(@"errorTitle"),
                    (IMP)CRErrorAlertErrorTitle,
                    "@@:");
    class_addMethod(cls,
                    NSSelectorFromString(@"setErrorTitle:"),
                    (IMP)CRErrorAlertSetErrorTitle,
                    "v@:@");

    class_addProperty(cls, "errorMessage", stringAttributes, 3);
    class_addMethod(cls,
                    NSSelectorFromString(@"errorMessage"),
                    (IMP)CRErrorAlertErrorMessage,
                    "@@:");
    class_addMethod(cls,
                    NSSelectorFromString(@"setErrorMessage:"),
                    (IMP)CRErrorAlertSetErrorMessage,
                    "v@:@");

    class_addProperty(cls, "actions", arrayAttributes, 3);
    class_addMethod(cls,
                    NSSelectorFromString(@"actions"),
                    (IMP)CRErrorAlertActions,
                    "@@:");
    class_addMethod(cls,
                    NSSelectorFromString(@"setActions:"),
                    (IMP)CRErrorAlertSetActions,
                    "v@:@");

    class_addProperty(cls,
                      "crane_reappearsAfterUnlock",
                      boolAttributes,
                      2);
    class_addMethod(cls,
                    NSSelectorFromString(@"crane_reappearsAfterUnlock"),
                    (IMP)CRErrorAlertReappears,
                    "B@:");
    class_addMethod(cls,
                    NSSelectorFromString(@"setCrane_reappearsAfterUnlock:"),
                    (IMP)CRErrorAlertSetReappears,
                    "v@:B");

    objc_registerClassPair(cls);

    MSHookMessageEx(cls,
                    NSSelectorFromString(
                        @"configure:requirePasscodeForActions:"),
                    (IMP)CRErrorAlertConfigure,
                    NULL);
    MSHookMessageEx(cls,
                    NSSelectorFromString(@"reappearsAfterUnlock"),
                    (IMP)CRErrorAlertReappearsAfterUnlock,
                    NULL);

    CRInitNewContainerAlert();
}

/* ------------------------------------------------------------------------- */
/* Shared helpers                                                            */
/* ------------------------------------------------------------------------- */

static id CRNewErrorAlert(void)
{
    Class cls = NSClassFromString(@"CRErrorAlert");
    if (!cls)
        return nil;

    id alert = [cls new];
    [alert setIgnoreIfAlreadyDisplaying:YES];
    return alert;
}

static void CRActivateErrorAlert(id alert)
{
    if (!alert)
        return;

    dispatch_async(dispatch_get_main_queue(), ^{
        Class controllerClass = NSClassFromString(@"SBAlertItemsController");
        id controller =
            [controllerClass respondsToSelector:@selector(sharedInstance)]
                ? [controllerClass sharedInstance]
                : nil;
        if ([controller respondsToSelector:
                NSSelectorFromString(@"activateAlertItem:")]) {
            [controller activateAlertItem:alert];
        }
    });
}

void CRPresentNewContainerAlert(NSString *appID)
{
    Class cls = NSClassFromString(@"CRNewContainerAlert");
    if (!cls || !appID.length)
        return;

    id alert = [cls new];
    [alert setValue:appID forKey:@"applicationID"];
    CRActivateErrorAlert(alert);
}

static UIAlertAction *CRCloseAction(id alert)
{
    return [UIAlertAction
        actionWithTitle:CRLocalize(@"CLOSE")
                  style:UIAlertActionStyleDefault
                handler:^(__unused UIAlertAction *action) {
                    [alert deactivateForButton];
                }];
}

static id CRUserNotificationsProxy(void)
{
    CraneManager *manager = CraneManager.sharedManager;
    SEL selector = NSSelectorFromString(@"_userNotificationsSyncRemoteProxy");
    if (![manager respondsToSelector:selector])
        return nil;
    return [manager _userNotificationsSyncRemoteProxy];
}

static NSString *CRStringifyDaemons(id daemonValue)
{
    if ([daemonValue isKindOfClass:NSString.class])
        return daemonValue;
    if (![daemonValue isKindOfClass:NSArray.class])
        return nil;

    NSArray *daemons = daemonValue;
    if (daemons.count == 0)
        return nil;
    if (daemons.count == 1)
        return daemons.firstObject;
    if (daemons.count == 2) {
        return [NSString stringWithFormat:@"%@ %@ %@",
                                          daemons[0],
                                          CRLocalize(@"AND"),
                                          daemons[1]];
    }

    NSMutableString *prefix = [NSMutableString new];
    for (NSUInteger index = 0; index + 1 < daemons.count; index++) {
        [prefix appendString:daemons[index]];
        if (index + 2 < daemons.count)
            [prefix appendString:@", "];
    }
    return [NSString stringWithFormat:@"%@ %@ %@",
                                      prefix,
                                      CRLocalize(@"AND"),
                                      daemons.lastObject];
}

static NSString *CRAppendChoicyNoticeIfNeeded(NSString *message)
{
    if (!CRIsDylibLoaded(CR_CHOICY_SB_DYLIB))
        return message;

    return [NSString stringWithFormat:@"%@\n\n%@",
                                      message ?: @"",
                                      CRLocalize(@"INJECTION_ERROR_MESSAGE_CHOICY")];
}

static NSString *CRAppendDisabledMessage(NSString *message)
{
    return [NSString stringWithFormat:@"%@\n\n%@",
                                      message ?: @"",
                                      CRLocalize(@"CRANE_DISABLED_MESSAGE")];
}

/* ------------------------------------------------------------------------- */
/* Presenters                                                                */
/* ------------------------------------------------------------------------- */

void CRPresentLibSandyNotWorkingError(void)
{
    if (!CRAlertsRunningInSpringBoard()) {
        id proxy = CRUserNotificationsProxy();
        SEL selector =
            NSSelectorFromString(@"crane_presentLibSandyNotWorkingError");
        if ([proxy respondsToSelector:selector])
            ((void (*)(id, SEL))objc_msgSend)(proxy, selector);
        return;
    }

    id alert = CRNewErrorAlert();
    if (!alert)
        return;

    [alert setValue:CRLocalize(@"CRANE_ERROR") forKey:@"errorTitle"];

    NSString *message = CRLocalize(@"LIBSANDY_NOT_WORKING_ERROR_MESSAGE");
    message = CRAppendChoicyNoticeIfNeeded(message);
    message = CRAppendDisabledMessage(message);
    [alert setValue:message forKey:@"errorMessage"];
    [alert setValue:@[CRCloseAction(alert)] forKey:@"actions"];

    CRActivateErrorAlert(alert);
}

void CRPresentDaemonError(id brokenDaemons,
                          NSError *error,
                          BOOL connectionWorks)
{
    if (!CRAlertsRunningInSpringBoard()) {
        id proxy = CRUserNotificationsProxy();
        SEL selector =
            NSSelectorFromString(
                @"crane_presentDaemonErrorWithBrokenDaemons:error:connectionWorks:");
        if ([proxy respondsToSelector:selector]) {
            ((void (*)(id, SEL, id, id, BOOL))objc_msgSend)(
                proxy,
                selector,
                brokenDaemons,
                error,
                connectionWorks);
        }
        return;
    }

    id alert = CRNewErrorAlert();
    if (!alert)
        return;

    [alert setValue:CRLocalize(@"CRANE_ERROR") forKey:@"errorTitle"];

    UIAlertAction *close = CRCloseAction(alert);
    NSMutableArray *actions = [NSMutableArray new];
    NSString *message = nil;

    if (!connectionWorks) {
        message =
            [NSString stringWithFormat:@"%@\n\n%@",
                                       CRLocalize(@"COMMUNICATION_ERROR_MESSAGE"),
                                       error.localizedDescription ?: @""];
        [actions addObject:close];
    } else if (error) {
        message =
            [NSString stringWithFormat:@"%@\n\n%@",
                                       CRLocalize(@"INSURANCE_FAILED_ERROR_MESSAGE"),
                                       error.localizedDescription ?: @""];
        [actions addObject:close];
    } else {
        NSString *daemonString = CRStringifyDaemons(brokenDaemons);
        NSString *format = CRLocalize(@"INJECTION_ERROR_MESSAGE");
        message = format
            ? [NSString stringWithFormat:format, daemonString ?: @""]
            : daemonString;
        message = CRAppendChoicyNoticeIfNeeded(message);

        __weak id weakAlert = alert;
        id capturedDaemons = brokenDaemons;
        UIAlertAction *restart =
            [UIAlertAction
                actionWithTitle:
                    CRLocalize(@"RESTART_AFFECTED_DAEMONS_AND_SPRINGBOARD")
                          style:UIAlertActionStyleDefault
                        handler:^(__unused UIAlertAction *action) {
                            id<CRHelperServiceProtocol> proxy =
                                (id<CRHelperServiceProtocol>)
                                    [CraneManager.sharedManager
                                        cranehelperdGlobalSyncRemoteObjectProxy];
                            if ([proxy respondsToSelector:
                                    @selector(reloadDaemons:)]) {
                                NSArray *daemonArray =
                                    [capturedDaemons isKindOfClass:NSArray.class]
                                        ? capturedDaemons
                                        : (capturedDaemons ? @[capturedDaemons]
                                                           : @[]);
                                [proxy reloadDaemons:daemonArray];
                            }

                            Class serviceClass =
                                NSClassFromString(@"FBSystemService");
                            id service =
                                [serviceClass respondsToSelector:
                                    @selector(sharedInstance)]
                                    ? [serviceClass sharedInstance]
                                    : nil;
                            if ([service respondsToSelector:
                                    NSSelectorFromString(@"exitAndRelaunch:")]) {
                                [service exitAndRelaunch:YES];
                            }
                            [weakAlert deactivateForButton];
                        }];
        [actions addObject:restart];
        [actions addObject:close];
    }

    message = CRAppendDisabledMessage(message);
    [alert setValue:message forKey:@"errorMessage"];
    [alert setValue:actions forKey:@"actions"];
    CRActivateErrorAlert(alert);
}

void CRPresentMainDylibNotLoadedError(NSString *appName)
{
    if (!CRAlertsRunningInSpringBoard()) {
        id proxy = CRUserNotificationsProxy();
        SEL selector =
            NSSelectorFromString(
                @"crane_presentMainDylibNotLoadedErrorForAppName:");
        if ([proxy respondsToSelector:selector]) {
            ((void (*)(id, SEL, id))objc_msgSend)(
                proxy,
                selector,
                appName);
        }
        return;
    }

    id alert = CRNewErrorAlert();
    if (!alert)
        return;

    [alert setValue:CRLocalize(@"CRANE_ERROR") forKey:@"errorTitle"];
    [alert setValue:@[CRCloseAction(alert)] forKey:@"actions"];

    NSString *format = CRLocalize(@"CRANE_DYLIB_NOT_LOADED_ERROR");
    NSString *message =
        format ? [NSString stringWithFormat:format, appName ?: @""] : appName;
    [alert setValue:message forKey:@"errorMessage"];
    CRActivateErrorAlert(alert);
}

static NSString *CRErrorTitleForApplication(NSString *appID)
{
    NSString *displayName =
        [CraneManager.sharedManager
            displayNameForApplicationWithIdentifier:appID];
    return [NSString stringWithFormat:@"%@ (%@)",
                                      CRLocalize(@"CRANE_ERROR"),
                                      displayName ?: appID ?: @""];
}

void CRPresentApsdRegistrationError(NSString *appID)
{
    if (!CRAlertsRunningInSpringBoard()) {
        id proxy = CRUserNotificationsProxy();
        SEL selector =
            NSSelectorFromString(
                @"crane_presentApsdRegistrationErrorForAppId:");
        if ([proxy respondsToSelector:selector])
            ((void (*)(id, SEL, id))objc_msgSend)(proxy, selector, appID);
        return;
    }

    id alert = CRNewErrorAlert();
    if (!alert)
        return;

    [alert setValue:CRErrorTitleForApplication(appID) forKey:@"errorTitle"];
    [alert setValue:@[CRCloseAction(alert)] forKey:@"actions"];
    [alert setValue:
        CRAppendChoicyNoticeIfNeeded(
            CRLocalize(@"REGISTRATION_FAILED_MESSAGE"))
             forKey:@"errorMessage"];
    CRActivateErrorAlert(alert);
}

void CRPresentPkdRegistrationError(NSString *appID)
{
    if (!CRAlertsRunningInSpringBoard()) {
        id proxy = CRUserNotificationsProxy();
        SEL selector =
            NSSelectorFromString(
                @"crane_presentPkdRegistrationErrorForAppId:");
        if ([proxy respondsToSelector:selector])
            ((void (*)(id, SEL, id))objc_msgSend)(proxy, selector, appID);
        return;
    }

    id alert = CRNewErrorAlert();
    if (!alert)
        return;

    [alert setValue:@YES forKey:@"crane_reappearsAfterUnlock"];
    [alert setValue:CRErrorTitleForApplication(appID) forKey:@"errorTitle"];
    [alert setValue:@[CRCloseAction(alert)] forKey:@"actions"];
    [alert setValue:
        CRAppendChoicyNoticeIfNeeded(
            CRLocalize(@"PLUGIN_REDIRECTION_FAILED_MESSAGE"))
             forKey:@"errorMessage"];
    CRActivateErrorAlert(alert);
}

/* ------------------------------------------------------------------------- */
/* CF >=1665.15 user-notification listener bridge                            */
/* ------------------------------------------------------------------------- */

static IMP gOrigListenerShouldAcceptConnection;

static BOOL CRListenerShouldAcceptConnection(id self,
                                             SEL _cmd,
                                             id listener,
                                             id connection)
{
    BOOL (*original)(id, SEL, id, id) =
        (BOOL (*)(id, SEL, id, id))
            gOrigListenerShouldAcceptConnection;
    return original ? original(self, _cmd, listener, connection) : YES;
}

static void CRListenerPresentLibSandy(id self, SEL _cmd)
{
    (void)self;
    (void)_cmd;
    CRPresentLibSandyNotWorkingError();
}

static void CRListenerPresentDaemon(id self,
                                    SEL _cmd,
                                    id brokenDaemons,
                                    NSError *error,
                                    BOOL connectionWorks)
{
    (void)self;
    (void)_cmd;
    CRPresentDaemonError(brokenDaemons, error, connectionWorks);
}

static void CRListenerPresentMainDylib(id self,
                                       SEL _cmd,
                                       NSString *appName)
{
    (void)self;
    (void)_cmd;
    CRPresentMainDylibNotLoadedError(appName);
}

static void CRListenerPresentApsd(id self, SEL _cmd, NSString *appID)
{
    (void)self;
    (void)_cmd;
    CRPresentApsdRegistrationError(appID);
}

static void CRListenerPresentPkd(id self, SEL _cmd, NSString *appID)
{
    (void)self;
    (void)_cmd;
    CRPresentPkdRegistrationError(appID);
}

void CRInitRunningboarddErrorAlertHooks(void)
{
    Class cls =
        NSClassFromString(@"UNSUserNotificationServerConnectionListener");
    if (!cls)
        return;

    MSHookMessageEx(
        cls,
        NSSelectorFromString(@"listener:shouldAcceptNewConnection:"),
        (IMP)CRListenerShouldAcceptConnection,
        &gOrigListenerShouldAcceptConnection);

    class_addMethod(
        cls,
        NSSelectorFromString(@"crane_presentLibSandyNotWorkingError"),
        (IMP)CRListenerPresentLibSandy,
        "v@:");
    class_addMethod(
        cls,
        NSSelectorFromString(
            @"crane_presentDaemonErrorWithBrokenDaemons:error:connectionWorks:"),
        (IMP)CRListenerPresentDaemon,
        "v@:@@B");
    class_addMethod(
        cls,
        NSSelectorFromString(
            @"crane_presentMainDylibNotLoadedErrorForAppName:"),
        (IMP)CRListenerPresentMainDylib,
        "v@:@");
    class_addMethod(
        cls,
        NSSelectorFromString(
            @"crane_presentApsdRegistrationErrorForAppId:"),
        (IMP)CRListenerPresentApsd,
        "v@:@");
    class_addMethod(
        cls,
        NSSelectorFromString(
            @"crane_presentPkdRegistrationErrorForAppId:"),
        (IMP)CRListenerPresentPkd,
        "v@:@");
}
