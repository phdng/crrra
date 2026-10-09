/*
 * CRPreferences.h — the preference contract.
 *
 * Two distinct stores, which must not be conflated (see
 * analysis/preference_schema.md):
 *
 *  1. GLOBAL switches in the CFPreferences domain "com.opa334.craneprefs",
 *     declared in Root.plist with `defaults = com.opa334.craneprefs` and read
 *     through `[[CraneManager sharedManager] preferenceValueForKey:key].boolValue`
 *     (CraneSB 0x1ED64 etc.).
 *
 *  2. PER-APPLICATION settings, not a preference plist at all: they live in the
 *     CraneManager container registry and are read through
 *     `applicationSettingsForApplicationWithIdentifier:` /
 *     `containerSettingsForContainerWithIdentifier:ofApplicationWithIdentifier:`.
 *
 * Several key NAMES appear in both stores. `preference_schema.md` records which
 * accessor each site uses; the names below carry an explicit comment saying
 * which store is meant so a reader cannot mix them up.
 */

#ifndef CR_PREFERENCES_H
#define CR_PREFERENCES_H

#import <Foundation/Foundation.h>
#import "CRManager.h"

/* CFPreferences domain for the global switches.
 * Root.plist `defaults` keys + Library/libSandy/libCrane.plist grants. */
#define CR_PREFS_DOMAIN @"com.opa334.craneprefs"

/* ---- global switches, declared in CranePrefs.bundle/Root.plist ---------- */

/* All six of these are declared in Root.plist and post
 * com.opa334.craneprefs/ReloadPrefs on change. */
#define CRPref_AppShortcutEnabled                @"applicationShortcutEnabled"                 /* default YES */
#define CRPref_LaunchAppOnContainerSelection     @"launchApplicationOnContainerSelectionEnabled" /* default NO  */
#define CRPref_ExpandContainersShortcut          @"expandContainersShortcutEnabled"           /* default NO  */
#define CRPref_NewContainerShortcut              @"newContainerShortcutEnabled"               /* default YES */
#define CRPref_OnlyShowIfContainersExist         @"onlyShowIfContainersExistEnabled"          /* default YES */
#define CRPref_ShowContainerNotificationBadges   @"showContainerNotificationBadgesEnabled"    /* default YES */
#define CRPref_NotificationsSupportEnabled       @"notificationsSupportEnabled"              /* default YES */
#define CRPref_ShowContainerInTitle              @"showContainerInNotificationTitleEnabled"  /* default YES */

/* Read by CraneSB/CraneSupport but NOT declared in Root.plift; the ones marked
 * "per-app" are per-application settings, the rest are global. */
#define CRPref_AlwaysAskBeforeLaunch             @"alwaysAskBeforeLaunchEnabled"             /* per-app */
#define CRPref_ContainerProtection               @"containerProtectionEnabled"               /* per-app */
#define CRPref_SpoofSandboxLookups               @"spoofSandboxLookupsEnabled"               /* per-app */
#define CRPref_SeparateNotificationRegistrations @"separateNotificationRegistrationsEnabled" /* per-app */
#define CRPref_SeparateSystemAccounts            @"separateSystemAccountsEnabled"            /* per-app */
#define CRPref_GameCenterSupport                 @"gameCenterSupportEnabled"                 /* per-app */
#define CRPref_ChoicyConfigOverwrite             @"choicyConfigurationOverwriteEnabled"      /* global */
#define CRPref_CustomTweakConfiguration          @"customTweakConfigurationEnabled"          /* Choicy-side */
#define CRPref_UseContainerIdentifierAsDeviceID  @"useContainerIdentifierAsDeviceIdentifier" /* per-container */

/* ---- per-application settings dictionary keys -------------------------- */
/* CraneSB 0x1B45C reads these via
 * `objc_msgSend(applicationSettings, "objectForKeyedSubscript:", ...)`. */

#define CRAppSetting_Containers                              @"Containers"
#define CRAppSetting_GameCenterSupportEnabled                @"gameCenterSupportEnabled"
#define CRAppSetting_ContainerProtectionEnabled              @"containerProtectionEnabled"
#define CRAppSetting_SpoofSandboxLookupsEnabled              @"spoofSandboxLookupsEnabled"
#define CRAppSetting_SeparateNotificationRegistrationsEnabled @"separateNotificationRegistrationsEnabled"
#define CRAppSetting_SeparateSystemAccountsEnabled           @"separateSystemAccountsEnabled"
#define CRAppSetting_AlwaysAskBeforeLaunchEnabled            @"alwaysAskBeforeLaunchEnabled"
#define CRAppSetting_Presets                                 @"presets"

/* ---- per-container settings dictionary keys ---------------------------- */
/* `identifier` and `name` are read by
 * -[CRPApplicationConfigurationListController renameContainerWithIdentifier:toName:]
 * (0x8400) and removeContainerWithIdentifier: (0x86A8). */

#define CRCContainer_Identifier                    @"identifier"
#define CRCContainer_Name                          @"name"
#define CRCContainer_ActiveContainer               @"activeContainer"
#define CRCContainer_AssociatedGameCenterAccount   @"associatedGameCenterAccount"
#define CRCContainer_IncludeKeychain               @"includeKeychain"
#define CRCContainer_EncryptBackup                 @"encryptBackupEnabled"

/* ---- helpers ----------------------------------------------------------- */

static inline BOOL CRPrefBool(NSString *key)
{
    /* Mirrors CraneSB 0x1ED64 exactly: CraneManager may return nil for an unset
     * key, and [nil boolValue] is 0, i.e. every unset per-app switch reads NO.
     * The one exception is separateNotificationRegistrationsEnabled, which
     * carries an explicit `default = 1` on its specifier (CranePrefs 0x8D00). */
    return [[[CraneManager sharedManager] preferenceValueForKey:key] boolValue];
}

#endif /* CR_PREFERENCES_H */
