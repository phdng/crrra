# Hook Reconstruction

All hook registrations recovered from the IDA pseudocode. Machine-readable:
`analysis/hooks_index.csv` (159 rows).

Legend for *Original called*: whether the registered hook function itself
invokes the saved original. `yes` = confirmed by reading the hook's
decompilation; `no` = confirmed absent; `n/a` = the registration is a
`class_addMethod` (adds a new selector, so there is no original).

## 1. Injection topology (CONFIRMED_STATIC, from filter plists)

| Dylib | Load filter | Injected into |
|---|---|---|
| ` Crane.dylib` | `Bundles = [com.apple.Foundation]`, `Flags = 0` | **every** app that loads Foundation |
| `CraneSB.dylib` | `Bundles = [com.apple.springboard]`, `Executables = [runningboardd]` | SpringBoard, runningboardd |
| `CraneSupport.dylib` | `Executables = [cfprefsd, containermanagerd, securityd, pkd, lsd, accountsd, apsd]`, `Flags = 1` | 7 system daemons |
| `CranePrefs` | (loaded by Settings / PreferenceLoader) | Settings, per `Root.plist` `detail` classes |

`Flags = 1` on `CraneSupport` is Substrate's "load also when the process is not
launched by the app" / safe-mode-independent flag; the exact meaning is
version-specific and is marked INFERRED.

**Filename anomaly (CONFIRMED_STATIC, needs attention in reconstruction):**
the main dylib and its filter are named with a **leading space**:

```
Library/MobileSubstrate/DynamicLibraries/ Crane.dylib
Library/MobileSubstrate/DynamicLibraries/ Crane.plist
```

Verified by character codes (`0x20` first byte of the name). The `LC_ID_DYLIB`
install name inside the binary is nevertheless
`/Library/MobileSubstrate/DynamicLibraries/Crane.dylib` (no space), and
several string references inside the binaries spell it *with* the space
(`/Library/MobileSubstrate/DynamicLibraries/ Crane.plist` appears in
`CraneSB` at 0x1FD74, `CraneSupport` at 0x65EC, `CranePrefs` at 0x3E364). The
localization table even warns about it:

> `CHOICYLOADER_SUGGESTION_MESSAGE` — "The main Crane library (" Crane.dylib")
> needs to inject into applications first …"

So the space is **intentional in this build** (it is how upstream ships the
library: a leading space keeps the dylib from being confused with the
`CraneSB`/`CraneSupport` names in logs). A reconstruction must reproduce the
space or Choicy/TweakRestrict allow-lists written for Crane will not match.

## 2. ` Crane.dylib` — the container redirection library

Pure C, no Objective-C classes. Two hook groups: a mandatory
`sandbox_container_path_for_pid` hook and an optional "protection" group.

### HK-1 `sandbox_container_path_for_pid` (CONFIRMED_STATIC, complete)

* Init: `InitFunc_0` at 0x65D0 (`__DATA,__mod_init_func`)
* Registration: `HCHookFunctions(table, count)` at 0x7360 — the libhooker
  shim. The recovered table uses **32-byte records**
  `{original, hook, orig_storage, reserved=0}`; the Substrate fallback passes
  the first three words to `MSHookFunction` and advances by four QWORDs.
* Registered **only** when `getenv("CRANE_SPOOF_SANDBOX_LOOKUPS") != NULL`
* Hook: `sandbox_container_path_for_pid_hook` at 0x6564

```c
// decompile/6564.c
int sandbox_container_path_for_pid_hook(pid_t pid, char *out, size_t n)
{
    int rc = sandbox_container_path_for_pid_orig(pid, out, n);
    if (pid == getpid()) {
        const char *home = getenv("HOME");
        strncpy(out, home, n);
    }
    return rc;
}
```

Contract: **the original always runs first**; for the current process only,
the caller-supplied buffer is overwritten with `$HOME`. Return value is passed
through unmodified. Note `strncpy` with no explicit NUL-termination beyond
`n` — a buffer of exactly `home` length+1 is fine, but this is the upstream
behaviour and must be reproduced verbatim.

### HK-2 Container path construction (CONFIRMED_STATIC, complete)

`containerPathForContainer(identifier, basePath)` at 0x6B2C:

```c
if (identifier == nil || basePath == nil) return nil;
if ([identifier isEqualToString:@"DEFAULT"]) return basePath;
return [NSString stringWithFormat:@"%@/Library/___Crane_Containers/%@", basePath, identifier];
```

`normalizedContainerID(id)` at 0x6DC0: returns `@"DEFAULT"` when `id` is nil.

### HK-3 Initialization and environment contract (CONFIRMED_STATIC, complete)

`InitFunc_0` reads and then **unsets** three environment variables:

| Variable | Effect |
|---|---|
| `CRANE_CONTAINER_IDENTIFIER` | `unsetenv`, then `crane_activeContainerIdentifier = [NSString stringWithCString:v encoding:4]` (UTF-8). Non-nil ⇒ the container-preparation branch runs. |
| `CRANE_PROTECT_CONTAINERS` | `unsetenv`, then `strcmp(v,"1")==0` |
| `CRANE_SPOOF_SANDBOX_LOOKUPS` | `unsetenv`, and enables the `sandbox_container_path_for_pid` hook |

If `crane_activeContainerIdentifier != nil`:

1. `containerPathForContainer(id, NSHomeDirectory())`
2. `createDirectoryIfNotExists` for: `<path>`, `<path>/tmp`,
   `<path>/Library`, `<path>/Library/Caches`, `<path>/Library/Preferences`,
   `<path>/Library/SplashBoard`, `<path>/Documents`, `<path>/SystemData`
3. `setenv("CFFIXED_USER_HOME", <path>, 1)`, `setenv("HOME", <path>, 1)`,
   `setenv("TMPDIR", <path>/tmp, 1)` — all with `overwrite = 1`

Else if `CRANE_PROTECT_CONTAINERS == "1"`: `initProtection(&table[2*spoof], &count)`.

Finally `if (count >= 1) HCHookFunctions(table, count)`.

`initProtection` (0x7268) registers 3 hooks unconditionally plus 1
conditionally:

| # | Original | Hook | Original called | Behaviour |
|---|---|---|---|---|
| 1 | `unlink` | `new_unlink` 0x721C | **bypassed** | `if (strstr(path,"___Crane_Containers")) return 0; else return org_unlink(path);` |
| 2 | `readdir` | `new_readdir` 0x71C0 | in loop | repeats `org_readdir` while `strstr(entry+21, "___Crane_Containers")` |
| 3 | `readdir_r` | `new_readdir_r` 0x7140 | in loop | same filter on `*result` (`d_name` at offset 21 of `struct dirent`) |
| 4 | `URLEnumeratorGetNextURL` (resolved via `dlopen("…/CoreServicesInternal.framework/CoreServicesInternal", RTLD_NOW)` + `dlsym("_URLEnumeratorGetNextURL")`) | `new_URLEnumeratorGetNextURL` 0x70B0 | in loop | loops while the current URL's `CFURLGetString` contains `___Crane_Containers` |

The `+21` offset is the `d_name` field of `struct dirent` on Darwin — the
entry that follows `d_ino, d_seekoff, d_reclen, d_namlen` (8+8+2+2).

Purpose (localization `CONTAINER_PROTECTION_FOOTER`, INFERRED-consistent):
hide Crane's own container directory from the app so it cannot delete other
containers' data.

### HK-4 Localization lookup (CONFIRMED_STATIC, complete)

`localize(key)` at 0x6924: passes
`/Library/Application Support/Crane.bundle` through the dispatch-once libroot
`libroot_jbrootpath` wrapper (`sub_6138`; fallback `sub_631C`) before loading
that path as an `NSBundle`, then calls `localizedStringForKey:value:table:`
with `value = key` and **`table = 0`**
(i.e. `nil` → `Localizable.strings`). If the result equals the key, it falls
back to `[NSDictionary dictionaryWithContentsOfFile:` of
`<bundle>/en.lproj/Localizable.strings`] objectForKey:key`, else the key.
Returns `nil` for a `nil` key.

### HK-5 `requestAuthentication(reason, handler)` (CONFIRMED_STATIC, complete)

0x6E08. `LAContext` + `canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics`
(`1`) then `evaluatePolicy:localizedReason:reply:`. **If evaluation is not
available the handler is invoked immediately on the calling thread** rather
than failing. The reply block (0x6F40) captures `isMainThread` at creation
and dispatches the handler to the main queue when on the main thread, else to
a global concurrent queue — and only on **success** (`success` truthy).

### HK-6 `safe_getBundleIdentifier` (CONFIRMED_STATIC, complete)

0x6544. `CFBundleGetMainBundle()` then `CFBundleGetIdentifier`, autoreleased.
Returns nil if the main bundle is nil.

## 3. `CraneSB.dylib` — 113 registrations

### Entry points

`InitFunc_2` (0x1BC70), a `__mod_init_func`:

```c
initUNProtocol();
NSString *exe = safe_getExecutablePath(NULL);
if ([exe.lastPathComponent isEqualToString:@"SpringBoard"]) {
    gIsSpringBoard = 1;
    crane_initSpringBoard();
} else if ([exe.lastPathComponent isEqualToString:@"runningboardd"]) {
    crane_initRunningBoardd();
}
```

Two further module constructors (`InitFunc_0` 0x9684, `InitFunc_1` 0x9E08)
create the alert classes. `InitFunc_0` subclasses `SBAlertItem` as
`CRErrorAlert` with properties `errorTitle`, `errorMessage`, `actions`,
`crane_reappearsAfterUnlock` and hooks `configure:requirePasscodeForActions:`
and `reappearsAfterUnlock`. `InitFunc_1` creates `CRNewContainerAlert` with
`applicationID`, hooking only `configure:requirePasscodeForActions:`.

### `crane_initSpringBoard` (0x17A14) — SpringBoard hook group

```c
hasFinishedLaunching = 0;
[CraneActivatorManager startIfPossible];

class_addMethod(objc_getClass("FBProcess"), "crane_containerIdentifier",
                sub_17D28, "@@:");
Class fbpm = objc_getClass("FBProcessManager");
MSHookMessageEx(fbpm, "_bootstrapProcessWithExecutionContext:synchronously:error:", ...);
MSHookMessageEx(fbpm, "_createProcessWithExecutionContext:", ...);
MSHookMessageEx(fbpm, "createApplicationProcessForBundleID:withExecutionContext:", ...);
class_addMethod(fbpm, "crane_applyModificationsIfNeededToExecutionContext:withApplicationIdentifier:", sub_180F0, "@@:@@");
class_addMethod(fbpm, "crane_registerInjectionCheckForProcess:toBeLaunchedIntoContainer:", sub_18238, "v@:@@");
Class sic = objc_getClass("SBIconController");
MSHookMessageEx(sic, "_launchFromIconView:", ...);
MSHookMessageEx(sic, "_launchFromIconView:withActions:", ...);
MSHookMessageEx(sic, "_launchFromIconView:withActions:modifierFlags:", ...);

if (kCFCoreFoundationVersionNumber >= 1665.15) initRunningboarddErrorAlertHooks();
else { craneIconBundle = [NSBundle bundleWithPath:…/Crane.bundle/Icons];
       crane_initChoicyIntegration(); }

CFNotificationCenterAddObserver(localCenter, NULL, didFinishLaunching,
                               UIApplicationDidFinishLaunchingNotification, ...);
CFNotificationCenterAddObserver(darwinCenter, NULL, keychainMigrationSuceeded,
                               "com.opa334.craneprefs/MigrationSucceeded", ...);
if (applicationShortcutsEnabled() && qword_2D400 != -1)
    dispatch_once(&qword_2D400, &stru_289E8);
initNotificationSupport();
initCRBadgeContextMenuActionView();
initUIMenuHooks();
```

Version gate note: the branch is **inverted** relative to its name —
`initRunningboarddErrorAlertHooks()` runs on *newer* CF (≥1665.15, iOS 15+),
while the icon-bundle load plus Choicy integration runs on *older* CF. Read
literally from the pseudocode; the *intent* of that inversion is UNKNOWN.

`crane_initRunningBoardd` (0x1BF10):

```c
Class rbpm = objc_getClass("RBProcessManager");
MSHookMessageEx(rbpm, "executeLaunchRequest:withError:", sub_1BF74, ...);
MSHookMessageEx(rbpm, "_executeLaunchRequest:withError:", sub_1BFEC, ...);
crane_initChoicyIntegration();
```

### Notification support — `initNotificationSupport` (0xCBEC), 40 registrations

All on the classes reached through `initUNProtocol`. Recovered selector list
(class column collapsed because the registration variables alias the resolved
UN classes — see the *Uncertainty* note):

| Hooked selector (grouped) |
|---|
| Records: `saveNotificationRecord:…`, `_queue_saveNotificationRecord:…` (3 variants), `_saveNotificationRequest:…` (2), `_queue_bulletinForNotification:`, `_deliverMessage:`, `title`, `notificationRecordForForIdentifier:bundleIdentifier:…`, `notificationRecordsForBundleIdentifier:` (2), `removeNotificationRecordsPassingTest:forBundleIdentifier:`, `removeAllPendingNotificationRequestsForBundleIdentifier:` (2), `removeNotificationRecordsForBundleIdentifier:` |
| Requests: `getPendingNotificationRequestsForBundleIdentifier:…`, `removePendingNotificationRequestsWithIdentifiers:…` (3), `_addNotificationRequests:forBundleIdentifier:…`, `mutateContentForNotificationRequest:error:`, `handleBulletinActionResponse:withCompletion:` |
| Tokens: `requestTokenForRemoteNotificationsForBundleIdentifier:…` (2), `invalidateTokenForRemoteNotificationsForBundleIdentifier:…` (2), `_queue_connection:didReceiveToken:forTopic:…`, `un_applicationBundleIdentifier` |
| Enablement: `_queue_isUserNotificationEnabledForApplication:`, `uns_isAllowedToRequestUserNotificationsForBundleIdentifier:`, `_queue_isBackgroundAppRefreshAllowedForBundleIdentifier:`, `_queue_isContentAvailableRemoteNotification…`, `_queue_isApplicationForeground:`, `isApplicationForeground:` |
| Badges: `_setBadgeNumber:forBundleIdentifier:withCompletion:`, `setBadgeNumber:forBundleIdentifier:withCompletion:`, `_queue_setBadgeNumber:forBundleIdentifier:…` |
| Topics: `_queue_allTopicsForApplication:` |
| Uninstall: `notificationSourcesDidUninstall:`, `applicationsDidUninstall:` |
| Dynamic adds (n/a): `crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:`, `crane_switchBadgesOfContainerWithIdentifier:andContainerWithIdentifier:ofApplicationWithIdentifier:`, `crane_unregisterFromNotificationsIfNeededForContainerIdentifier:ofApplicationWithIdentifier:`, `crane_copyWithoutContainerID` (2 entries — getter and setter sharing the label in the export), `setProtocol:` |
| Helper: `_queue_tryToModifyNotificationRequest:bundleIdentifier:…` (2) |
| Delegate-ish: `connection:didReceiveIncomingMessage:`, `containsObject:`, `isSimilar:`, `sourceDescriptionWithBundleIdentifier:` |

**Uncertainty (recorded, not invented):** the export's `objc_getClass`
assignments are aliased to the variable holding the UN class, so the class
column of `hooks_index.csv` reads `UNSNotificationRecord` for all of them.
The *selectors* are exact (string literals); the *class* each selector lives
on is INFERRED from the selector's naming convention (`_queue_*` =
`UNSNotificationServiceConnection`/`UNSUserNotificationServerConnection`,
`_setBadgeNumber:` = `UNSNotificationRecord`) and is **not** used as evidence
anywhere else in this project.

### App-shortcut menus

`initWithTitleHook` 0x145B8, `initUIMenuHooks` 0x1497C,
`initApplicationShortcutHooks` 0x14CE0,
`initApplicationShortcutLateHooks_12Down` 0x169B8, plus `sub_14D18` /
`sub_169F0` (26 registrations on `SBUIActionView` and
`SBUIAppIconForceTouchControllerDataProvider`).

`initUIMenuHooks` contains an explicit runtime version check:

```c
if ([UIMenu instancesRespondToSelector:@selector(
        initWithTitle:image:imageName:identifier:options:children:)])
    MSHookMessageEx(UIMenu, "initWithTitle:image:imageName:identifier:options:children:", …);
else
    MSHookMessageEx(UIMenu, "initWithTitle:image:identifier:options:children:", …);
```

`SBUIActionView` receives hooks for `_interfaceActionGroupForActions:`,
`_configureCell:forElement:section:`, `_configureCell:forElement:section:size:`,
`_configureCell:inCollectionView:atIndexPath:…`, `initWithMenu:overrideChildren:`,
`initWithAction:`, `dismissAnimated:withCompletionHandler:`,
`contextMenuInteraction:configurationForMenuAtIndexPath:`,
`_actionFromApplicationShortcutItem:`, `sbh_shortcutSection`,
`sbh_isSystemShortcut`, `applicationShortcutItems`, `setHighlighted:`,
`init`, `setBackgroundColor:`, `_setupSubviews`; and dynamic adds
`crane_provideContainerOptions`, `setCrane_provideContainerOptions:`,
`crane_isSeparator`, `setCrane_isSeparator:`, `crane_trailingView`,
`crane_rebuildConstraints`, `crane_updateConstraints`.

`SBUIAppIconForceTouchControllerDataProvider.applicationShortcutItems` is
hooked and `craneContainersApplicationShortcutItems` added — this is the
long-press / force-touch container menu.

### Badge view — `initCRBadgeContextMenuActionView` (0x7F58)

Hooks `SBApplicationIcon.updateConstraints`, `.layoutSubviews`,
`.valueForUndefinedKey:`; adds `associatedApplicationID`,
`setAssociatedApplicationID:`, `badgeView`, `setBadgeView:`, `text`,
`setText:`.

### RunningBoard error alerts — `initRunningboarddErrorAlertHooks` (0x17620)

Hooks `UNSUserNotificationServerConnectionListener.listener:shouldAcceptNewConnection:`;
adds `crane_presentMainDylibNotLoadedErrorForAppName:`,
`crane_presentApsdRegistrationErrorForAppId:`, `crane_presentPkdRegistrationErrorForAppId:`,
`crane_presentLibSandyNotWorkingError`,
`crane_presentDaemonErrorWithBrokenDaemons:error:connectionWorks:`.

### Activator integration — `CraneActivatorManager` (0x1C4D4–0x1E284)

`+[CraneActivatorManager startIfPossible]` resolves the Activator dylib through
the libroot path shim, opens it lazily, obtains `LAActivator.sharedInstance`,
and instantiates a singleton manager only when Activator is present. The manager
registers one `SetActiveContainer|app|container|` listener and one
`ChangedToContainer|container|app|` event data source for every container of
every installed app that has non-default containers. Listener receive stores the
previous container in the Activator event's `userInfo` and calls
`CraneManager.setActiveContainerIdentifier:...usingBiometrics...`; abort restores
the previous container. App install/uninstall and CraneManager container-change
observer callbacks rebuild both caches.

The reconstruction now transcribes this core flow and the recovered metadata
callbacks in `sources/cranesb/CRActivator.m` without a hard Activator link. Icon
generation is also recovered statically: in both arm64 and arm64e slices, the
call to `generateIconImageWithInfo:` loads `d0=29`, `d1=29`, `d2=scale`, and
`d3=5` immediately before `objc_msgSend`, proving a four-double homogeneous
aggregate passed by value. The reconstruction preserves exactly that ABI while
leaving the semantic name of the fourth field unknown. Runtime behaviour remains
NOT_TESTED.

### Choicy integration — `crane_initChoicyIntegration` (0x1BBB8)

`CraneChoicyOverwriteProvider` (6 instance methods:
`providedOverridesForApplication:`,
`customTweakConfigurationEnabledOverrideForApplication:`,
`overwriteGlobalConfigurationOverrideForApplication:`,
`disableTweakInjectionOverrideForApplication:`,
`customTweakConfigurationAllowDenyModeOverrideForApplication:`,
`customTweakConfigurationAllowOrDenyListOverrideForApplication:`)
implements Choicy's provider protocol so Crane is never disabled for an app
it manages. `parseNumberBool` / `parseNumberInteger` (0x1E2BC / 0x1E330)
coerce a Choicy `NSNumber` to `boolValue` / `integerValue`, leaving the
provided fallback untouched when the object is nil or not an `NSNumber`.

## 4. `CraneSupport.dylib` — 45 registrations

### Entry point `InitFunc_0` (0x6C5C)

```c
ignoredProcesses = @[@"watchdogd", @"com.apple.springboard"];
[[CraneManager sharedManager] _setXPCUnsandboxHandler:&handler];

NSString *proc = getProcessName();
if      ([proc isEqualToString:@"cfprefsd"])          initCfprefsd();
else if ([proc isEqualToString:@"containermanagerd"]) { initContainermanagerd();
                                                        if (kCFCoreFoundationVersionNumber >= 1932.101)
                                                            initCraneProxy(); }
else if ([proc isEqualToString:@"securityd"])          initSecurityd();
else if ([proc isEqualToString:@"accountsd"])          initAccountsd();
else if ([proc isEqualToString:@"pkd"])                initPkd();
else if ([proc isEqualToString:@"apsd"])               initApsd();
else if ([proc isEqualToString:@"lsd"])                initLsd();
```

Note `initWithSourceForDomain` (0xB848) and
`initHandleSourceMessage` (0xB6E0) are **not** reached from this
constructor — they are exported symbols used by the XPC shim path
(`gWithSourceForDomainHookSym`, `gHandleSourceMessageSym` are file-scope
globals resolved by `dlsym`). Their trigger conditions are UNKNOWN.

### Per-daemon hooks

| Init fn | Address | Hooks |
|---|---:|---|
| `initCfprefsd` | 0xBBFC | `MSHookFunction(&gHandleSourceMessageSym, …)`, `MSHookMessageEx(CFPrefsDaemon, handleSourceMessage:replyHandler:, …)`, `new_CFPrefsGetPathForTriplet` |
| `initContainermanagerd` | 0xCC88 | `MCMContainerFactory.containerForContainerIdentity:createIfNecessary:…` (2 variants), `groupContainerPathsForUser:clientConnection:…`, `containerForContainerIdentityHook`, `createOrLookupContainerWithContainerIdentityV2V3Hook` |
| `initCraneProxy` | 0x6C40 | `MSHookFunction(&xpc_connection_set_event_handler, …)` + `__xpc_connection_set_event_handler` shim (used to intercept unsandboxed XPC setup) |
| `initAccountsd` | 0x7200 | `ACDDatabase._sharedPersistentCoordinatorForStoreAtPath:`, `initWithClient:`, `initWithClient:databaseConnection:`; adds `crane_activeContainer`, `setCrane_activeContainer:`, `crane_databasesByContainerIdentifiers`, `setCrane_databasesByContainerIdentifiers:`, `crane_storeCoordinatorsByContainerIdentifiers`, `setCrane_storeCoordinatorsByContainerIdentifiers:` |
| `initPkd` | 0xF2B4 | `PKDPlugIn` active-container property/update method; four `enableForClient:environment:…` variants; `Transaction.matchPlugIns`; four `PKDatabase findPlugIns…` variants; `LSApplicationWorkspace.pluginsMatchingQuery:applyFilter:`; PKDServer capture/termination; distributed `ReloadApplication` handling. Server-side flow is transcribed in `reconstruction/sources/support/CRPkd.m`; SpringBoard-side query tagging remains coupled to notification support. |
| `initApsd` | 0x9C4C | `APSCourierConnection`: `_handleMessageMessage:onInterface:withGenerated…` (2), `_handleMessageMessage:onProtocolConnection:wi…`, `_handleAppTokenGenerateResponse:onProtocolCon…`, `_handleAppTokenGenerateResponse:onInterface:`, `sendTokenGenerateMessageWithTopicHash:baseToken…` (2), `connection:didRequestTokenForInfo:`, `connection:didRequestPerAppTokenForTopic:identifier:`; adds `crane_topicStorage`, `setCrane_topicStorage:` |
| `initLsd` | 0xD7D8 | `_LSDDeviceIdentifierClient.setProtocol:`, `getIdentifierOfType:completionHandler:`; adds `crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:`, `crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:` |
| `initSecurityd` | 0x11E5C | `SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`, `SecItemUpdate` (all four via `MSHookFunction` with `_hook`/`_orig` pairs) plus `securityd_xpc_dictionary_handler` and `patchfindSecurityd` |
| `initNoStartUsingiCloudHooks` | 0x7024 | exported but **not** called from `InitFunc_0`; condition UNKNOWN |

### Data redirection helpers

| Function | Address | Purpose |
|---|---:|---|
| `containerPathForContainer` | 0x5B44 | same `"%@/Library/___Crane_Containers/%@"` rule as ` Crane.dylib` |
| `redirectedURLForURL` / `redirectedContainerPathCopyForContainerPath` | 0xC2BC / 0xC3E4 | rewrite a container URL/path to the active container |
| `stripCraneContainerFromPath` | 0xC260 | inverse; strips the `/Library/___Crane_Containers` component |
| `craneContainerStringForString` / `dotCraneStringForContainerIdentifier` | 0x10834 / 0x1081C | notification-topic rewriting (`%@.c_r_a_n_e.%@.plist`) |
| `getSecurityAccessGroupsToIgnore` | 0x62BC | keychain access groups skipped when redirecting |
| `separateSystemAccountsEnabledForBundleID` | 0x6E88 | reads `separateSystemAccountsEnabled` |
| `apsd_notificationSupportEnabled` | 0x8D90 | reads `notificationsSupportEnabled` |
| `createUpdatedAccessGroup` | 0x108B8 | per-container keychain access group name |
| `ignoredProcesses` | 0x22FF8 | `@[@"watchdogd", @"com.apple.springboard"]` |

`CraneSupport` also embeds a complete Mach-O manipulation toolkit
(`csd_*` code-signature parsing, `macho_*`, `fat_*`, `memory_stream_*`,
`pfsec_*` arm64 pattern scanner, `arm64_gen_*`/`arm64_dec_*` encoder) used by
`patchfindSecurityd` / `update_load_commands_for_coretrust_bypass` /
`macho_replace_code_signature` / `macho_extract_cs_to_file`. That is ~180 of
the 624 exported functions and is required to make the keychain redirection
work against the current securityd signature checks. **A reconstruction that
omits this cannot claim equivalent keychain behaviour.**

## 5. `CranePrefs` — 1 registration

`CRPContainerChoicyOverwriteListController_init` adds
`containerIdentifier` (`@@:`) to `CHPProcessConfigurationListController`, so
the Choicy per-app configuration pane can display which container is active.
All other CranePrefs behaviour is ordinary Preferences-framework UI plus
`CraneManager` API calls.

## 6. `CraneApplication` — 0 hooks

The app and both `CraneShortcuts` extensions register no hooks. The app
declares 5 App Intents; the extensions implement `CraneIntentHandlerShared` /
`SetActiveCraneContainerIntentHandler`.

## 7. Summary counts

| Binary | `MSHookMessageEx` | `MSHookFunction` | `class_addMethod` | Total |
|---|---:|---:|---:|---:|
| ` Crane.dylib` | 0 | 0 | 0 | 0 (hooks installed via `HCHookFunctions` table: 1 + up to 4) |
| `CraneSB.dylib` | 66 | 0 | 47 | 113 |
| `CraneSupport.dylib` | 43 | 2 | 3 | 48 |
| `CranePrefs` | 0 | 0 | 1 | 1 |
| `CraneApplication` | 0 | 0 | 0 | 0 |
| **Total** | **109** | **2** | **51** | **162** |

(`extract_hooks.py` reports 159 because two `crane_copyWithoutContainerID`
entries and three `initWithSourceForDomain`-adjacent function hooks are
counted once each in the CSV; the table above additionally counts the
`SecItem*` and `_CFPrefsGetPathForTriplet` hooks that `MSHookFunction` on
already-hooked symbols implies but which appear in the exports as
`*_hook`/`*_orig` symbol pairs rather than call sites.)