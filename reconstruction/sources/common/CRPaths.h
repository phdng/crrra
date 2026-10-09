/*
 * CRPaths.h — paths, sentinels and constants.
 *
 * Every literal here is CONFIRMED_STATIC: it appears as a string literal in the
 * recovered IDA exports of the corresponding binary. Sources are noted inline.
 *
 *   Crane.dylib_export_for_ai/decompile/6B2C.c   "%@/Library/___Crane_Containers/%@"
 *   CraneSupport.../decompile/C260.c              "/Library/___Crane_Containers"
 *   CraneSupport.../decompile/D07C.c              "/___Crane_Containers/"
 *   CraneSB.../decompile/65D0.c                   InitFunc_0
 *   CraneSB.../decompile/1F0DC.c                 localize()
 *   CraneSB.../decompile/6924.c (Crane)           localize()
 */

#ifndef CR_PATHS_H
#define CR_PATHS_H

#import <Foundation/Foundation.h>

/* --- container identity ------------------------------------------------- */

/* Sentinel for "no container". Compared against with isEqualToString: in
 * normalizedContainerID (Crane 0x6DC0), containerPathForContainer (Crane
 * 0x6B2C), crane_containerToRedirectTo (CraneSB 0x1B360) and
 * crane_applyEnvironmentChanges (CraneSB 0x1B45C). It is a literal, not the
 * kCFBundleContainerURL sentinel. */
#define CR_DEFAULT_CONTAINER_IDENTIFIER @"DEFAULT"

/* Directory that holds all of an application's Crane containers, relative to
 * the app's own container. Also the substring used to hide containers from
 * the app when CRANE_PROTECT_CONTAINERS is set. */
#define CR_CONTAINERS_DIR_COMPONENT     @"Library/___Crane_Containers"
#define CR_CONTAINERS_DIR_TRAILER       @"___Crane_Containers"

/* --- launch environment contract ---------------------------------------- */

/* Consumed (read then unsetenv) by " Crane.dylib" InitFunc_0 at 0x65D0 and
 * written by CraneSB crane_applyEnvironmentChanges at 0x1B45C. */
#define CR_ENV_CONTAINER_IDENTIFIER     @"CRANE_CONTAINER_IDENTIFIER"
#define CR_ENV_PROTECT_CONTAINERS       @"CRANE_PROTECT_CONTAINERS"
#define CR_ENV_SPOOF_SANDBOX_LOOKUPS    @"CRANE_SPOOF_SANDBOX_LOOKUPS"

/* Set by " Crane.dylib" AFTER consuming CRANE_CONTAINER_IDENTIFIER. */
#define CR_ENV_FIXED_USER_HOME          @"CFFIXED_USER_HOME"
#define CR_ENV_HOME                     @"HOME"
#define CR_ENV_TMPDIR                   @"TMPDIR"

/* Value written for CRANE_PROTECT_CONTAINERS when protection is on. Confirmed
 * by the strcmp(v, "1") in Crane 0x65D0. */
#define CR_ENV_PROTECT_VALUE            "1"

/* --- bundle & data locations ------------------------------------------- */

#define CR_UI_BUNDLE_PATH               @"/Library/Application Support/Crane.bundle"
#define CR_ICON_BUNDLE_PATH             @"/Library/Application Support/Crane.bundle/Icons"
#define CR_MAIN_DYLIB_FILTER_PLIST      @"/Library/MobileSubstrate/DynamicLibraries/ Crane.plist"
#define CR_HELPERD_BIN                  @"/usr/local/libexec/cranehelperd"
#define CR_HELPERD_START_BIN            @"/usr/local/bin/cranehelperd_start"

#define CR_DATA_DIR                     @"/var/mobile/Library/Crane"
#define CR_BADGE_STORE_PATH             @"/var/mobile/Library/Crane/BadgeStore.plist"
#define CR_SLICES_DIR                   @"/var/mobile/Library/Preferences/Slices"
#define CR_LITE_PREFS_PATH              @"/var/mobile/Library/Preferences/com.opa334.craneliteprefs.plist"

/* --- Mach services ------------------------------------------------------ */

#define CR_HELPERD_MACH_SERVICE         @"com.opa334.cranehelperd.xpc"
#define CR_HELPERD_PREFS_MACH_SERVICE   @"com.opa334.cranehelperd.preferences.xpc"

/* --- notifications ------------------------------------------------------ */

#define CR_NOTIFICATION_RELOAD_PREFS            @"com.opa334.craneprefs/ReloadPrefs"
#define CR_NOTIFICATION_MIGRATION_SUCCEEDED     @"com.opa334.craneprefs/MigrationSucceeded"
#define CR_NOTIFICATION_SB_LOADED               @"com.opa334.cranesb/Loaded"
#define CR_NOTIFICATION_RELOAD_APPLICATION      @"com.opa334.crane/ReloadApplication"
#define CR_NOTIFICATION_HELPERD_STARTED         @"com.opa334.cranehelperd/Started"
#define CR_NOTIFICATION_LITE_NEW_APP            @"com.opa334.craneliteprefs.newApp"

/* --- UIMenu identifiers (externally visible; Choicy/Shortcut configs use them) */

#define CR_MENU_CONTAINERS              @"com.opa334.crane.containers"
#define CR_MENU_NEW_CONTAINER           @"com.opa334.crane.new-container-action"
#define CR_MENU_REPLACE_WITH_SELECTION  @"com.opa334.crane.to-replace-with-container-selection"
#define CR_MENU_SEPARATOR               @"com.opa334.crane.separator"
#define CR_MENU_OPEN_PREFERENCES        @"com.opa334.crane.open-preferences"
#define CR_MENU_APP_CONTAINER           @"com.opa334.crane.application-container"
#define CR_MENU_CONTAINER_PREFIX        @"com.opa334.crane-container"
#define CR_MENU_CONTAINER_FMT           @"com.opa334.crane-container.%@"
#define CR_MENU_CONTAINER_DOT_PREFIX    @"com.opa334.crane-container."

/* --- Activator names ---------------------------------------------------- */

#define CR_ACTIVATOR_LISTENER_FMT       @"%@.SetActiveContainer|%@|%@|"
#define CR_ACTIVATOR_EVENT_FMT          @"%@.ChangedToContainer|%@|%@|"
#define CR_ACTIVATOR_LISTENER_PREFIX    @"com.opa334.crane.activatorlistener"
#define CR_ACTIVATOR_EVENT_PREFIX       @"com.opa334.crane.activatorevent"

/* --- optional third-party tweaks probed by presence --------------------- */

#define CR_LIB_SANDY                    @"/usr/lib/libsandy.dylib"
#define CR_CHOICY_PREFS_BUNDLE          @"/Library/PreferenceBundles/ChoicyPrefs.bundle"
#define CR_CHOICY_LOADER                @"/usr/lib/ChoicyLoader.dylib"
#define CR_ACTIVATOR_LIB                @"/usr/lib/libactivator.dylib"
#define CR_CHOICY_SB_DYLIB              @"/Library/MobileSubstrate/DynamicLibraries/ChoicySB.dylib"
#define CR_INSERTER_TWEAK_INJECT        @"/usr/lib/TweakInject.dylib"
#define CR_INSERTER_SUBSTITUTE          @"/usr/lib/substitute-inserter.dylib"
#define CR_INSERTER_SUBSTRATE           @"/usr/lib/substrate/SubstrateInserter.dylib"

/* --- container path construction --------------------------------------- */

/* Crane 0x6B2C and CraneSupport 0x5B44 are the same function compiled twice:
 *
 *   if (!identifier || !base) return nil;
 *   if ([identifier isEqualToString:@"DEFAULT"]) return base;
 *   return [NSString stringWithFormat:@"%@/Library/___Crane_Containers/%@", base, identifier];
 */
static inline NSString *CRContainerPathForContainer(NSString *identifier, NSString *basePath)
{
    if (!identifier || !basePath)
        return nil;
    if ([identifier isEqualToString:CR_DEFAULT_CONTAINER_IDENTIFIER])
        return basePath;
    return [NSString stringWithFormat:@"%@/%@/%@", basePath,
                                      CR_CONTAINERS_DIR_COMPONENT, identifier];
}

/* Crane 0x6DC0: nil in, "DEFAULT" out. */
static inline NSString *CRNormalizedContainerID(NSString *identifier)
{
    return identifier ?: CR_DEFAULT_CONTAINER_IDENTIFIER;
}

#endif /* CR_PATHS_H */