# Behaviour Specification

Source-independent. Every clause carries an evidence class and an evidence
reference. Nothing here is derived from reconstruction source.

Evidence classes used throughout: **CONFIRMED_STATIC** (binary metadata,
disassembly, valid IDA export, package contents), **CORROBORATED** (two or more
independent sources), **INFERRED** (plausible, not verified), **UNKNOWN**
(insufficient evidence), **NOT_TESTED** (behaviour well defined statically but
no runtime observation exists).

Runtime evidence for *any* clause is **absent** in this environment: there is no
device access, no logs, no screenshots. Consequently no clause in this document
is CONFIRMED_RUNTIME, and the overall verification status is capped accordingly.

## 1. Product model

Crane lets a jailbroken device run **multiple independent copies of one app's
data** ("containers"), and redirects system services so each copy is
indistinguishable to the app and to the vendor.

The pieces that make this work:

1. A **library injected into every app** (` Crane.dylib`) that rewrites the app's
   container path and its environment so all file access lands in the selected
   container.
2. **System daemons redirected** (`CraneSupport.dylib` inside cfprefsd,
   containermanagerd, securityd, pkd, lsd, accountsd, apsd) so that
   preferences, keychain items, notification tokens, plug-in enumeration,
   device identifiers and system accounts are also per-container.
3. **SpringBoard UI** (`CraneSB.dylib`) that exposes container selection on
   long-press, injects the right environment at launch, and integrates with
   notifications and Choicy.
4. **A privileged daemon** (`cranehelperd`) that performs operations a sandboxed
   process may not: keychain dump/restore, cross-app account switching,
   application reload, verification of whether Crane is actually loaded.
5. **A settings bundle** (`CranePrefs`) and an **app + Shortcuts extension**
   for management and automation.

This model is CORROBORATED by: the 4 Substrate filter plists, the 5 libSandy
profiles, the launchd job, the localized footer `© 2020-2024 Lars Fröder
(opa334)`, and the 5 App Intents declared in `Info.plist`.

## 2. Actors and identifiers

| Identifier | Value | Source |
|---|---|---|
| Default container sentinel | the string `DEFAULT` | `CFSTR("DEFAULT")` compared in `normalizedContainerID`, `containerPathForContainer`, `crane_containerToRedirectTo`, `setSeparateNotificationRegistrationsValue:` |
| Container root suffix | `Library/___Crane_Containers/<identifier>` | `"%@/Library/___Crane_Containers/%@"` |
| Rootless container root | `/var/jb/var/mobile/...` | `libCrane.plist` |
| Trailer sentinel | `___Crane_Containers` | `new_unlink`, `new_readdir`, `new_readdir_r`, `new_URLEnumeratorGetNextURL`, `stripCraneContainerFromPath` |
| Per-container notification plist | `<topic>.c_r_a_n_e.<identifier>.plist` | `"%@.c_r_a_n_e.%@.plist"` |
| Prefs domain | `com.opa334.craneprefs` | `Root.plist` `defaults`, `libCrane.plist` |
| Mach service | `com.opa334.cranehelperd.xpc` | launchd plist, libSandy profiles |
| Prefs Mach service | `com.opa334.cranehelperd.preferences.xpc` | launchd plist |
| Bundle | `com.opa334.CraneApplication` | app `Info.plist` |

## 3. Feature contracts

### F-01 Per-container launch redirection

**Purpose.** When a user picks a non-default container for an app, launching
that app must present that container's data.

**Trigger.** SpringBoard launches an application process.

**Preconditions.** `CraneSB.dylib` loaded in SpringBoard; `libcrane.dylib`
loaded (it is a hard `LC_LOAD_DYLIB` of CraneSB); `libsandy.dylib` present.

**Processing order** (CONFIRMED_STATIC, `crane_initSpringBoard` →
`crane_applyEnvironmentChanges` 0x1B45C → `sub_180F0`):

1. `[CraneManager isApplicationSupportedByCrane:appID]`. If **NO**, the
   environment is returned unchanged and none of the rest runs.
2. Read `applicationSettingsForApplicationWithIdentifier:`,
   `activeContainerIdentifierForApplicationWithIdentifier:`,
   `containerSettingsForContainerWithIdentifier:ofApplicationWithIdentifier:`.
3. If `gameCenterSupportEnabled` → `[CraneManager gameCenter_setActiveAccount:associatedGameCenterAccount andDontKillApplication:appID]`.
4. If active container **is** `DEFAULT`:
   - if `containerProtectionEnabled` → set `CRANE_PROTECT_CONTAINERS = "1"`
   - else → environment unchanged
5. Else (non-default container):
   - `[CraneManager resetLastError]`
   - if `libSandy_works()` is false → `crane_presentLibSandyNotWorkingError()`,
     **environment returned unchanged** (fail-open)
   - else call `[cranehelperdGlobalSyncRemoteObjectProxy verifyCraneInsuranceAndReply:…]`
     synchronously
   - if the reply reports broken daemons → `crane_presentDaemonError(...)`,
     **environment returned unchanged**
   - else insert `CRANE_CONTAINER_IDENTIFIER = <containerID>`, and insert
     `CRANE_SPOOF_SANDBOX_LOOKUPS = "1"` when `spoofSandboxLookupsEnabled`

**Output.** A mutated launch environment. The *original* launch behaviour is
always preserved — Crane only adds environment entries, never removes the
system's. `crane_containerToRedirectTo` (0x1B360) is the query used to decide
whether a redirect is needed at all: it returns `nil` for `DEFAULT` and for
unsupported apps.

**Side effects.** `crane_registerInjectionCheckForProcess:toBeLaunchedIntoContainer:`
is registered so SpringBoard can verify after launch that the dylib actually
loaded.

**Failure behaviour.** Fail-open with a user-visible SpringBoard alert; the app
still launches into its normal container.

**Acceptance tests.**
`T-F01-1` launch into DEFAULT with protection off → env identical to stock.
`T-F01-2` launch into DEFAULT with protection on → `CRANE_PROTECT_CONTAINERS=1`.
`T-F01-3` launch into a named container → `CRANE_CONTAINER_IDENTIFIER` set.
`T-F01-4` same + `spoofSandboxLookupsEnabled` → both variables set.
`T-F01-5` cranehelperd unreachable → alert shown, no variables injected.
`T-F01-6` libSandy not working → `LIBSANDY_NOT_WORKING_ERROR_MESSAGE` alert,
no variables injected.
**Status: NOT_TESTED** (no device).

### F-02 In-app environment and directory preparation

**Purpose.** The app process itself must be convinced it is running from its
container.

**Trigger.** `InitFunc_0` in ` Crane.dylib` at library load.

**Behaviour** (CONFIRMED_STATIC, complete pseudocode in
`hook_reconstruction.md` §2):

1. Read and `unsetenv` `CRANE_CONTAINER_IDENTIFIER`, `CRANE_PROTECT_CONTAINERS`,
   `CRANE_SPOOF_SANDBOX_LOOKUPS` (each exactly once, at load).
2. If `CRANE_CONTAINER_IDENTIFIER` was present: create
   `<container>`, `<container>/tmp`, `<container>/Library`,
   `<container>/Library/Caches`, `<container>/Library/Preferences`,
   `<container>/Library/SplashBoard`, `<container>/Documents`,
   `<container>/SystemData`; then `setenv` `CFFIXED_USER_HOME`, `HOME`
   (overwrite=1) and `TMPDIR = <container>/tmp`.
3. Else if `CRANE_PROTECT_CONTAINERS == "1"`: register the protection hooks.
4. If `CRANE_SPOOF_SANDBOX_LOOKUPS` was present: register the
   `sandbox_container_path_for_pid` hook.
5. Install all registered hooks in one `HCHookFunctions` batch.

**Why SplashBoard exists:** the localized strings never mention it, and the
directory name differs from iOS's own `SplashBoard`; it is almost certainly a
place Crane must pre-create so the system's splash-board daemon cannot fail or
so a per-container cache exists. Purpose is **UNKNOWN**; the behaviour
(create it if absent) is CONFIRMED_STATIC.

**Side effects.** Three environment variables are consumed and removed from the
app's environment — this is observable by the app via `environ` and is
intentional (an app must not be able to discover the container from the env).

**Acceptance tests.** `T-F02-1` app launched with
`CRANE_CONTAINER_IDENTIFIER=X` → container dir tree exists, `HOME` = container.
`T-F02-2` `environ` no longer contains any `CRANE_*` variable.
`T-F02-3` launched with neither variable → no directory creation, no hooks
beyond none. **Status: NOT_TESTED.**

### F-03 Container isolation (protection)

**Purpose.** An app running in the *default* container must not be able to
delete other containers' data.

**Trigger.** `CRANE_PROTECT_CONTAINERS=1` at app launch.

**Behaviour** (CONFIRMED_STATIC, complete):

| Hoisted function | Filter |
|---|---|
| `unlink` | returns `0` (success, no deletion) if the path contains `___Crane_Containers`; otherwise calls the original |
| `readdir` | loops the original until the returned entry's name (offset 21) does not contain `___Crane_Containers` |
| `readdir_r` | same, on the `struct dirent` |
| `URLEnumeratorGetNextURL` | loops the original while the current `CFURL`'s string contains `___Crane_Containers`; resolved dynamically from `CoreServicesInternal` via `dlopen`/`dlsym` |

**Original-method interaction.** For `unlink` the original is **bypassed** on a
match. For the three enumeration hooks the original runs first each iteration
and the hook only decides whether to expose the result. `URLEnumeratorGetNextURL`
is only hooked if `dlsym` succeeds — absence of the symbol degrades gracefully.

**Edge cases.** `strstr` on a `NULL` path would crash; the recovered code does
not null-check `new_unlink`'s argument. That is upstream behaviour; reproducing
it is the faithful choice, and it is flagged in `final/KNOWN_DIFFERENCES.md`
as a latent crash.

**Acceptance tests.** `T-F03-1` `unlink("/…/Library/___Crane_Containers/A")`
from a default-container app returns 0 and the directory still exists.
`T-F03-2` `unlink` of an unrelated path succeeds.
`T-F03-3` `readdir` over a directory listing other containers never yields
`___Crane_Containers`.
`T-F03-4` the same three hooks are **not** installed when protection is off.
**Status: NOT_TESTED.**

### F-04 Sandbox-lookup spoofing

**Purpose.** `sandbox_container_path_for_pid` can be called with the app's own
pid to discover its real, un-redirected container. That would let an app (or a
web browser) find the true paths and defeat redirection.

**Behaviour** (CONFIRMED_STATIC, complete): original runs first; if
`pid == getpid()`, overwrite the caller's buffer with `getenv("HOME")`.
Return value unchanged.

**Opt-in.** Only registered when `CRANE_SPOOF_SANDBOX_LOOKUPS` is set, which
requires both a non-default container and `spoofSandboxLookupsEnabled`.

**Acceptance tests.** `T-F04-1` self-lookup returns the container path.
`T-F04-2` lookup for another pid is unaffected.
`T-F04-3` hook absent when the variable is unset. **Status: NOT_TESTED.**

### F-05 Per-container preferences

**Purpose.** `cfprefsd` resolves a preference domain to a directory; without
redirecting, all containers share one prefs file.

**Behaviour.** `CraneSupport.dylib`, `initCfprefsd` (0xBBFC), hooks
`CFPrefsGetPathForTriplet` (via `new_CFPrefsGetPathForTriplet`, 0xB4D0) plus
`CFPrefsDaemon handleSourceMessage:replyHandler:` and the symbol resolved as
`gHandleSourceMessageSym`. The container's directory is
`%@/Library/Preferences`. Path rewriting uses
`redirectedContainerPathCopyForContainerPath` / `stripCraneContainerFromPath`.

**Original-method interaction.** The original **is** called — the hook rewrites
the path it produces, rather than fabricating one. Confirmed for the triplet
hook by the presence of `_orig_CFPrefsGetPathForTriplet` in `exports.txt`.

**Redirect condition (confirmed).** Reading `BBFC.c`, `ADF0.c`, `AB1C.c` and
`B4D0.c` line-by-line resolves U-02. `handleSourceMessage:replyHandler:` stores
the client host bundle identifier and PID in the current thread dictionary.
`withSourceForDomainHook` ignores the protected processes (`watchdogd` and
`com.apple.springboard`) and redirects only when `ClientContainerCache` returns
a non-default active container for that PID. `com.apple.Preferences` has a
special case that queries the active container for the preference domain's app
identifier directly. For the null-container path variant, the active container
ID is placed in thread-local state while the original source lookup runs; then
`new_CFPrefsGetPathForTriplet` rewrites the generated filename to
`<domain>.c_r_a_n_e.<container>.plist`. This behavior is CONFIRMED_STATIC.

**Acceptance tests.** `T-F05-1` prefs written in container A are invisible in
container B. `T-F05-2` the default container's prefs path is unchanged.
`T-F05-3` third-party apps without Crane support are unaffected.
**Status: NOT_TESTED.**

### F-06 Per-container container enumeration

**Purpose.** `containermanagerd` decides which directory an app may use. If it
returns the default path, redirection fails.

**Behaviour.** `initContainermanagerd` (0xCC88) hooks
`MCMContainerFactory containerForContainerIdentity:createIfNecessary:…` (two
variants), `groupContainerPathsForUser:clientConnection:…`,
`containerForContainerIdentityHook` (0xC8E8, reads `_containerRootComponent` /
`_containerDataComponent`), and
`createOrLookupContainerWithContainerIdentityV2V3Hook` (0xC680) — the latter
two names indicate explicit **V2/V3 identity** handling.

**Original-method interaction.** Both hooked factory methods have `_orig`
storage in `exports.txt`, so the original is invoked and its result is
substituted or amended. CONFIRMED_STATIC.

**Version gate.** `initCraneProxy()` runs only when
`kCFCoreFoundationVersionNumber >= 1932.101`. It installs a
`xpc_connection_set_event_handler` hook (0x69DC / `__xpc_connection_set_event_handler`).

**Acceptance tests.** `T-F06-1` an app launched into container A resolves
`NSHomeDirectory()` to A's path. `T-F06-2` two containers of the same app have
disjoint group container paths. **Status: NOT_TESTED.**

### F-07 Per-container keychain

**Purpose.** Keychain items are stored in a shared keychain; without
redirection every container sees the same credentials.

**Behaviour.** `initSecurityd` (0x11E5C) hooks four `SecItem*` C functions
(`SecItemAdd`, `SecItemCopyMatching`, `SecItemDelete`, `SecItemUpdate`) via
`MSHookFunction` with `_orig` storage, *and* patches securityd itself:
`patchfindSecurityd` (0x11C08) uses the embedded Mach-O/code-signature toolkit
(`macho_replace_code_signature`, `csd_*`, `pfsec_*` arm64 scanner) to
`update_load_commands_for_coretrust_bypass`. Keychain access groups are
rewritten per container via `createUpdatedAccessGroup`, with
`getSecurityAccessGroupsToIgnore` listing groups to leave alone.
`securityd_xpc_dictionary_handler_hook` (0x112D8) rewrites the XPC dictionaries.

**Original-method interaction.** The `SecItem*` hooks store and call `_orig`
(exports confirm `__SecItemAdd_orig` etc.). CONFIRMED_STATIC. The
`securityd_xpc_dictionary_handler` pair (`_orig` present) likewise.

**Side effects.** A code-signature rewrite of securityd — a high-risk,
highly version-dependent operation. `libbsm.0.dylib` is required.

**Uncertainty.** Whether the signature patch is best-effort or mandatory, and
what happens when it fails, is **UNKNOWN** (`UNSAFE`, recorded as U-03).

**Acceptance tests.** `T-F07-1` a keychain item written in container A is not
visible in B. `T-F07-2` items in the ignore-list access groups are shared.
`T-F07-3` securityd still functions after the patch (no crash on keychain use).
**Status: NOT_TESTED.**

### F-08 Per-container notification tokens

**Purpose.** APNs tokens are registered per bundle id, not per container, so
pushes for one container wake the wrong one.

**Behaviour.** `initApsd` (0x9C4C) hooks eight `APSCourierConnection`
selectors around token generation and message handling, adds
`crane_topicStorage`/`setCrane_topicStorage:` (an
`apsd_notificationSupportEnabled`-gated store keyed by
`<topic>.c_r_a_n_e.<identifier>.plist` via `topicStorage_*`), and rewrites
topics with `craneContainerStringForString` /
`dotCraneStringForContainerIdentifier`.
`isCraneTopic`/`buildCraneTopic`/`decodeCraneTopic` identify Crane's own topics.
`getSecurityAccessGroupsToIgnore`, `fetchTopicHash` and
`handleAppTokenGenerateResponseHook` (0x96C8) complete the flow.

**Gate.** `notificationsSupportEnabled` (global) **and**
`separateNotificationRegistrationsEnabled` (per app) — read by
`apsd_notificationSupportEnabled` (0x8D90) and
`notificationRedirectionEnabledForApp` (0x1EB9C).

**Original-method interaction.** Hooks have `_orig` storage
(`withSourceForDomainHook`, `withSourceForDomainHook_v3`,
`handleSourceMessageHook_v2`). CONFIRMED_STATIC.

**Acceptance tests.** `T-F08-1` with support off, tokens are shared.
`T-F08-2` with support on, each container gets its own token.
`T-F08-3` tapping a notification for container A launches the app into A.
`T-F08-4` per-container notification disable stops only that container.
**Status: NOT_TESTED.**

### F-09 Per-container system accounts

**Purpose.** Apple ID / system accounts are per-system, not per-container.

**Behaviour.** `initAccountsd` (0x7200) hooks
`ACDDatabase _sharedPersistentCoordinatorForStoreAtPath:`, `initWithClient:`,
and `initWithClient:databaseConnection:`, and adds a per-container
`Crane_*` database map (`crane_databasesByContainerIdentifiers`,
`crane_storeCoordinatorsByContainerIdentifiers`, `crane_activeContainer`).

**Gate.** `separateSystemAccountsEnabled` (per app) — read by
`separateSystemAccountsEnabledForBundleID` (0x6E88) which is also the predicate
that decides whether the Game Center switch is even shown.

**Acceptance tests.** `T-F09-1` toggling the switch changes which account the
app sees after restart. `T-F09-2` the Game Center row appears only when the
switch is on. **Status: NOT_TESTED.**

### F-10 Per-container Game Center account

**Purpose.** Game Center login is per system.

**Behaviour.** Per-container key `associatedGameCenterAccount`; global list of
available accounts managed in `CRPGameCenterAccountsController`;
`gameCenter_setActiveAccount:andDontKillApplication:` is called from
`crane_applyEnvironmentChanges` at launch.
The switch `gameCenterSupportEnabled` is only added to the specifier list when
`separateSystemAccountsEnabled` is true (0x8D00). Setting the app's Game Center
switch off triggers per-container
`unregisterFromNotificationsIfNeededForContainerIdentifier:ofApplicationWithIdentifier:`
for every non-DEFAULT container followed by `reloadApplicationWithIdentifier:`
(`setSeparateNotificationRegistrationsValue:specifier:`, 0xA224 — the same
pattern is applied for the notifications switch).

**Acceptance tests.** `T-F10-1` assigning different accounts to two containers
produces two different Game Center identities. `T-F10-2` the switch is hidden
when `separateSystemAccountsEnabled` is off. **Status: NOT_TESTED.**

### F-11 Per-container device identifier

**Purpose.** Apps (and vendors) key state on a device identifier; sharing it
across containers means shared logins.

**Behaviour.** `initLsd` (0xD7D8) hooks
`_LSDDeviceIdentifierClient setProtocol:` and
`getIdentifierOfType:completionHandler:` and adds
`crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:` /
`crane_setIdentifier:…`, forwarded to `cranehelperd` (which exposes the same
two selectors).

**Semantics** (from `DEVICE_IDENTIFIER_DESCRIPTION`, which is unusually
explicit and therefore good evidence):
- By default Crane **spoofs the identifier of non-default containers to the
  container identifier**.
- `useContainerIdentifierAsDeviceIdentifier` toggles that off in favour of a
  custom value.
- When the active/default container changes, the identifier is **automatically
  adjusted** so that the app's visible device identifier stays the same.
- Modifying the identifier of the *default* container writes the system cache
  and **persists even when Crane is unloaded**.
- `DEVICE_IDENTIFIER_CHANGE_WARNING` warns that some apps will sign the user out.

**Acceptance tests.** `T-F11-1` two containers of one app report different
identifiers. `T-F11-2` a custom identifier survives container selection changes.
`T-F11-3` the default container's identifier persists with Crane disabled.
**Status: NOT_TESTED.**

### F-12 Per-container plug-in enumeration

**Purpose.** Notification service extensions and other plug-ins are found by
bundle id; without redirection every container sees the default's.

**Behaviour.** `initPkd` (0xF2B4) hooks ten `PKDServer` selectors
(`findPlugIns…`, `pluginsMatchingQuery:applyFilter:`, `enableForClient:…`,
`matchPlugIns`, `terminatePlugIns`, `reloadApplication`,
`initWithConnection:queue:database:externalPro…`) and adds
`crane_activeContainerID`/`setCrane_activeContainerID:`.
`reloadApplication` posts `com.opa334.crane/ReloadApplication` (0xF2B4).

**Gate.** `notificationsSupportEnabled` — the extension-redirection alert text
is `PLUGIN_REDIRECTION_FAILED_MESSAGE` ("…because CraneSupport.dylib is not
loaded into the pkd daemon").

**Acceptance tests.** `T-F12-1` a container with an extension installed sees it
only there. `T-F12-2` the alert appears when pkd lacks CraneSupport.
**Status: NOT_TESTED.**

### F-13 Container selection UI (long-press / 3D Touch)

**Purpose.** The user-facing entry point.

**Behaviour.** Gate chain (CONFIRMED_STATIC from the predicate functions and
`initWithTitleHook`):

```
applicationShortcutEnabled                                   (global, default YES)
  AND newContainerShortcutEnabled            (global, default YES)  -> "New Container" row
  AND expandContainersShortcutEnabled        (global, default NO )  -> expand submenu
  AND onlyShowIfContainersExistEnabled       (global, default YES)  -> hide apps with no containers
launchApplicationOnContainerSelectionEnabled  (global, default NO )  -> launch on selection
alwaysAskBeforeLaunchEnabled                 (per app)              -> confirm sheet
```

Menu identifiers are fixed: `com.opa334.crane.containers`,
`com.opa334.crane.new-container-action`,
`com.opa334.crane.to-replace-with-container-selection`,
`com.opa334.crane.separator`, `com.opa334.crane.open-preferences`,
`com.opa334.crane.application-container`,
`com.opa334.crane-container[%@]`.

Implementation hooks `SBUIActionView` (16 selectors) and
`SBUIAppIconForceTouchControllerDataProvider.applicationShortcutItems`, plus
`UIMenu`'s two initialiser variants selected by
`instancesRespondToSelector:` at runtime.

**Uncertainty.** The exact cell layout (row order, subtitle text, checkmark
placement) is **UNKNOWN** from static evidence; it would require reading the
`_configureCell:forElement:section:` hooks in detail and, ideally, a
screenshot. Recorded as U-05. The artwork in `Crane.bundle/Icons`
(`ContainersIcon`, `AddIcon`, `SelectedContainerCheckmark`, `SettingsIcon`)
constrains it: a containers row, an add row, a checkmark for the selected
container, and a settings row.

**Acceptance tests.** `T-F13-1` long-press shows the container submenu for a
supported app. `T-F13-2` selecting a container and relaunching shows that
container's data. `T-F13-3` the four global switches each change the menu.
`T-F13-4` no crash on both UIMenu initialiser variants (iOS 15+ and earlier).
**Status: NOT_TESTED.**

### F-14 Badge count per container

**Purpose.** Icon badges should reflect the container the user is in.

**Behaviour.** `initCRBadgeContextMenuActionView` (0x7F58) hooks
`SBApplicationIcon.updateConstraints` / `.layoutSubviews` /
`.valueForUndefinedKey:` and adds `badgeView`, `text`, `associatedApplicationID`.
Supporting functions: `existingBadgeCountForApplication` (0xA658),
`setExistingBadgeCountForApplication` (0xA774),
`badgeCountStore*` (`_init`, `GetContainerCount`, `GetAppCount`, `UpdateBadge`,
`SetAppDict`, `SetContainerCount`), persisting to
`/var/mobile/Library/Crane/BadgeStore.plist`.
`UNSNotificationRecord._setBadgeNumber:forBundleIdentifier:withCompletion:`
and `setBadgeNumber:…` are hooked to route the badge to the right container.

**Gate.** `showContainerNotificationBadgesEnabled` (global, default YES).
`showContainerInNotificationTitleEnabled` (global, default YES) controls
whether the container name is prefixed to the notification title via
`containerNameToDisplayInNotificationWithUserInfoOrContext:ofApplicationWithIdentifier:`.

**Acceptance tests.** `T-F14-1` badge counts are tracked per container.
`T-F14-2` switching container updates the icon badge.
`T-F14-3` the badge row is hidden when the global switch is off.
**Status: NOT_TESTED.**

### F-15 Settings UI

**Purpose.** All management.

**Structure** (CONFIRMED_STATIC from `Root.plist`, `Credits.plist`,
`PreferenceLoader` plist, and `CRP*` class list):

```
Settings -> Crane  (CRPRootListController)
  ├─ APPLICATIONS          -> CRPApplicationConfigurationListController
  │     search bar on, alphabetic indexing on,
  │     sectioned on `crane_isSupported == YES`
  │     custom subtitle provider (container info) and preview provider
  │  └─ per application (CRPContainerConfigurationListController):
  │       Active Container        (CRPActiveContainerListItemsController)
  │       Always Ask on App-Launch
  │       CONTAINERS [ ...rows..., Add ]
  │       (if notificationsSupportEnabled unset-or-true)
  │         SEPARATE_NOTIFICATION_REGISTRATIONS_FOOTER
  │         Separate Notification Registrations        default YES
  │       SEPARATE_SYSTEM_ACCOUNTS_FOOTER
  │       Separate System Accounts                    (enabled, not togglable here)
  │       Game Center Support                         (only if Separate System Accounts)
  │       CONTAINER_PROTECTION_FOOTER
  │       Container Protection                        (enabled)
  │       PREVENT_SANDBOX_LOOKUPS_FOOTER
  │       Prevent Sandbox Lookups                     (enabled)
  │       ... plus Game Center account, device identifier, notifications
  │          and keychain rows for supported containers
  ├─ APP_SHORTCUTS [footer APP_SHORTCUT_DESCRIPTION]
  │     App Shortcuts Enabled                default YES  (nestedEntryCount 5)
  │     Launch App on Container Selection    default NO
  │     Expand Shortcuts                     default NO
  │     Show 'New Container' Option          default YES
  │     Only Show if Containers Exist        default YES
  │     Show Container Notification Badges  default YES
  ├─ NOTIFICATIONS [footer NOTIFICATIONS_SUPPORT_FOOTER]
  │     Notifications Support Enabled       default YES  (bespoke setter)
  │     Show Container in Title              default YES
  ├─ REPLACE_WITH_SUGGESTIONS   (empty group: Choicy / libSandy / Shortcuts / Activator suggestions)
  ├─ BACKUP_RESTORE
  │     Create Multi-Container Backup
  │     Restore Multi-Container Backup
  ├─ OTHER  [footer © 2020-2024 Lars Fröder (opa334)]
  │     (this build: "Crack by Repo BVN" instead of "Follow me on Twitter")
  │     Credits & Licenses -> CRPCreditsController
  └─ CREDITS
        ZipArchive + LICENSE, MiniZip + LICENSE, then per-language credits
```

**Known layout details.** Row 1 of `Root.plist` uses `detail =
CRPApplicationListSubcontrollerController` with
`subcontrollerClass = CRPApplicationConfigurationListController` and
`sections = [{sectionName: APPLICATIONS, sectionPredicate:
"crane_isSupported == YES", sectionType: Custom}]`. `alphabeticIndexingEnabled`
and `useSearchBar` are both YES. This is AltList syntax — a reconstruction
**must** ship AltList or the pane cannot be reproduced.

**Acceptance tests.** `T-F15-1` every row in the tree above appears with the
same default state. `T-F15-2` the Game Center row is hidden unless
`separateSystemAccountsEnabled`. `T-F15-3` the notification row is hidden when
`notificationsSupportEnabled` is explicitly false. `T-F15-4` renaming,
deleting and reordering containers persists.
**Status: NOT_TESTED.**

### F-16 Container lifecycle operations

**Purpose.** The container CRUD surface exposed by `CraneManager` and driven
from the settings UI.

| Operation | Selector | Behaviour |
|---|---|---|
| Create | `createNewContainerWithName:forApplicationWithIdentifier:` | creates `<root>/Library/___Crane_Containers/<newID>` |
| Create (explicit id) | `createNewContainerWithName:andIdentifier:forApplicationWithIdentifier:` | as above |
| Delete | `deleteContentOfContainerWithIdentifier:forApplicationWithIdentifier:` | behind `CONTAINER_DELETE_CONFIRMATION_*` (irreversible warning) |
| Wipe | `wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:` | clears data, optionally repopulates |
| Make default | `makeDefaultForContainerWithIdentifier:forApplicationWithIdentifier:` | writes the system cache |
| Set active | `setActiveContainerIdentifier:forApplicationWithIdentifier:…` | 2- and 3-argument forms; the 3-arg form adds `reloadApplication:` |
| Biometrics | `…usingBiometricsIfNeededWithSuccessHandler:` | via `requestAuthentication` (F-18) |
| Move / copy | `moveOrCopyContainerFromPath:toPath:move:` | |
| Size | `sizeOccupiedByContainerWithIdentifier:ofApplicationWithIdentifier:completionHandler:` | drives `SIZE_OF_CONTAINER` |
| Unknown detection | `unknownContainersInsideApplicationWithIdentifier:knownContainers:` | drives `UNKNOWN_CONTAINERS_FOUND_MESSAGE` |
| Slice import | (prefs paths `Slices/%@`) | drives `SLICES_FOUND_MESSAGE`; "It is not possible to revert them back to Slices in the future." |
| Crane Lite import | `com.opa334.craneliteprefs.newApp` | `LITE_IMPORT_MESSAGE` |
| Group containers | `groupContainerURLs`, `enumerate:pathsAssociatedTo…` | App Groups also isolated |

**Uncertainty.** The bodies of these live in `libcrane.dylib` / `CranePrefs`
and were only partially read. On-disk layout, identifier generation, and the
"unknown container" reconciliation rules are **UNKNOWN** (U-04).

**Acceptance tests.** `T-F16-1` create/rename/delete round-trips.
`T-F16-2` delete asks for confirmation and is irreversible.
`T-F16-3` app-group data is per container. **Status: NOT_TESTED.**

### F-17 Backup and restore

**Purpose.** Move container data (and optionally keychain) between containers
and off-device.

**Assets.** Embedded `SSZipArchive` + MiniZip in `CranePrefs` (licenses
`ZipArchiveLicense.plist`, `MiniZipLicense.plist`); `libz` and `libiconv` are
`LC_LOAD_DYLIB`s of `CranePrefs`.

**UI.** `CRPCreditsController` links to
`https://github.com/ZipArchive/ZipArchive` and
`https://github.com/nmoinvaz/minizip`. The Credits pane also links
`https://opa334.github.io` (`OPEN_REPO`), `https://twitter.com/%@` and
`twitter://user?screen_name=%@`.

**States** (from the localization table, which enumerates the progress
alert's status vocabulary — `CRPBackupRestoreProgressAlertController` has
30 instance methods including `setStatus:`, `setTotalSuboperationsCount:`,
`setCurrentSuboperationIndex:`, `setProcessedFile:`, `setProcessedContainer:`,
`setProcessedIdentifier:`, `updateAlertContent`):
`PREPARING`, `BACKING_UP`, `UNARCHIVING`, `RESTORING`, `CHECKING`,
`BACKUP_ERROR`, `RESTORE_ERROR`, `SUCCESS`.

**Options.** `encryptBackupEnabled` (+ `ENABLE_ENCRYPTION`, `PASSWORD`,
`CONFIRM_PASSWORD`, `PROTECT_USING_BIOMETRICS`, `PREVIOUS_PASSWORD_WRONG_MESSAGE`),
`includeKeychainEnabled` (+ `INCLUDE_KEYCHAIN`, `SEP_ITEMS_OMMITED_WARNING_MESSAGE`
for secure-enclave items).

**Validation.** `APP_ID_MISMATCH_ERROR`, `GROUP_ID_MISMATCH_WARNING`,
`NOT_A_BACKUP_ERROR_MESSAGE`, `NOT_A_MULTI_CONTAINER_BACKUP_ERROR_MESSAGE`,
`NO_APPS_INSTALLED_ERROR`, `BACKUP_NOT_ENOUGH_FREE_SPACE_ERROR`,
`RESTORE_NOT_ENOUGH_FREE_SPACE_ERROR`, `NO_PASSWORD_ERROR`,
`RESTORE_WARNING_MESSAGE`.

**Multi-container.** `CRPMultiBackupPresetListController`,
`CRPMultiBackupContainerSelectionListController`,
`CRPMultiBackupSelectionCell`, `PRESETS`, `NEW_PRESET`, `NEW_PRESET_MESSAGE`,
`SAVE_SELECTION_INTO_PRESET`, `INCLUDED_CONTAINERS`,
`MULTI_RESTORE_SUCCESS_MESSAGE`.

**Uncertainty.** The archive layout, encryption algorithm, and keychain dump
format are **UNKNOWN** — the code is in `libcrane.dylib` (no export) and
`cranehelperd`. **A backup produced by this build cannot be assumed readable
by another build.** Recorded as U-06.

**Acceptance tests.** `T-F17-1` backup→restore round-trips in-container.
`T-F17-2` an encrypted backup refuses to restore without the password.
`T-F17-3` a wrong password reports `PREVIOUS_PASSWORD_WRONG_MESSAGE`.
`T-F17-4` a backup from another app is rejected with `APP_ID_MISMATCH_ERROR`.
`T-F17-5` multi-container backup/restore succeeds for installed apps.
**Status: NOT_TESTED.**

### F-18 Biometric / password gate

**Behaviour** (CONFIRMED_STATIC, `requestAuthentication` 0x6E08):
`LAContext.canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics`;
if true → `evaluatePolicy:localizedReason:reply:`; **if false the handler runs
immediately**. On success the handler is dispatched to the main queue when
`+[NSThread isMainThread]` was true at call time, otherwise to a global
concurrent queue. On failure nothing is invoked (no error surfaced).

Used by `setActiveContainerIdentifier:forApplicationWithIdentifier:
usingBiometricsIfNeededWithSuccessHandler:` and the 4-argument form.

**Acceptance tests.** `T-F18-1` with biometrics available and enrolled, the
success handler runs on the main thread. `T-F18-2` with biometrics unavailable
the handler still runs (degrade open). **Status: NOT_TESTED.**

### F-19 cranehelperd XPC service

**Purpose.** Privileged operations.

**Registration** (CONFIRMED_STATIC, launchd plist): Label
`com.opa334.cranehelperd`, `Program /usr/local/libexec/cranehelperd`,
`UserName root`, `RunAtLoad` true, `KeepAlive` true,
`ProcessType Interactive`, `EnvironmentVariables` sets `_MSSafeMode=1` and
`_SafeMode=1` (so it also runs in safe mode), and registers two Mach services:
`com.opa334.cranehelperd.xpc` and
`com.opa334.cranehelperd.preferences.xpc`.

**Clients** (CONFIRMED_STATIC from `CraneManager` selector literals):
`cranehelperdGlobalSyncRemoteObjectProxy`,
`cranehelperdGlobalAsyncRemoteObjectProxy`, `cranehelperdConnectionWorks`,
`verifyCraneInsuranceAndReply:`, `verifyCraneSupportLoadedIntoDaemon:reply:`,
`verifyCraneSBLoadedAndReply:`, `fetchActiveContainerIDForProcessWithPid:reply:`,
`reloadApplicationWithIdentifier:`, `reloadDaemons:`,
`resetBadgeOfContainer…`, `switchBadges…`,
`unregisterFromNotificationsIfNeededForContainer…`,
`dumpKeychainItemsFromContainerWithIdentifier:…`,
`restoreKeychainItemsToContainerWithIdentifier:…`,
`gameCenter_*`, `crane_getIdentifier:`/`crane_setIdentifier:`.

**Server classes** (CONFIRMED_STATIC from `cranehelperd`'s class list):
`CRHServiceShared` (19 methods, base), `CRHGlobalService` (15) implementing
`CRHGlobalServiceProtocol`, `CRHPreferencesService` (3) implementing
`CRHPreferencesServiceProtocol`, their two delegate classes, and `CRHKeychain`.

**libSandy requirement.** Every client process is granted
`com.apple.app-sandbox.mach` + `com.apple.security.exception.mach-lookup.global-name`
for `com.opa334.cranehelperd.xpc` by the profiles in `Library/libSandy/`
(`libCrane.plist` = `*`, i.e. all processes; `CraneSB.plist`,
`CraneSupport.plist`, `CraneShortcuts.plist` = specific ones).
Without libSandy running, `libSandy_works()` is false and F-01 fails open.

**Uncertainty.** The XPC protocol/interface (NSXPCInterface vended by
`cranehelperd`) is **UNKNOWN** — `cranehelperd` has no IDA export. A
reconstruction must define its own protocol, and cross-version compatibility
with this build's daemon is therefore **not achievable**. Recorded as U-01 and
flagged in `final/KNOWN_DIFFERENCES.md`.

**Acceptance tests.** `T-F19-1` the daemon is running and reachable from
SpringBoard. `T-F19-2` `cranehelperdConnectionWorks` is true.
`T-F19-3` a keychain dump/restore round-trips. `T-F19-4` the daemon survives
safe mode. **Status: NOT_TESTED.**

### F-20 Self-verification and error reporting

**Purpose.** Crane's data-integrity story is that it detects its own absence.

**Checks** (CONFIRMED_STATIC from selectors + localized strings):

| Check | Failure alert |
|---|---|
| ` Crane.dylib` present in the launched process | `CRANE_DYLIB_NOT_LOADED_ERROR` ("The application %@ started into the default container because the Crane dylib was not loaded into it…") |
| Crane "disabled" state | `CRANE_DISABLED_MESSAGE` ("Crane has been disabled to avoid data desyncs.") |
| `CraneSupport.dylib` in a daemon | `INJECTION_ERROR_MESSAGE`, `INJECTION_ERROR_MESSAGE_CHOICY` |
| cranehelperd reachable | `CRANEHELPERD_COMMUNICATION_WARNING`, `COMMUNICATION_ERROR_MESSAGE` |
| libSandy running | `LIBSANDY_NOT_WORKING_ERROR_MESSAGE` |
| injection binary present | `CRANEHELPERD_INJECTION_ERROR_INJECTION_BINARY_NOT_FOUND` |
| dylib found for pid | `CRANEHELPERD_INJECTION_ERROR_DYLIB_FILE_NOT_FOUND` |
| injection raised | `CRANEHELPERD_INJECTION_ERROR_EXCEPTION_OCCURED` |
| process not running for verify | `CRANEHELPERD_VERIFY_ERROR_PROCESS_NOT_RUNNING` |
| keychain migration incomplete | `KEYCHAIN_MIGRATION_MESSAGE` ("…this can only be done from the Preferences process… Crane has been disabled until this is done.") |
| migration completed | `MIGRATION_SUCCEEDED` / `MIGRATION_SUCCEEDED_MESSAGE` |
| serialisation errors | `INSURANCE_FAILED_ERROR_MESSAGE`, `FIXUP_ERROR_DESCRIPTION` |

Alert mechanism: `CRErrorAlert`/`CRNewContainerAlert`, runtime `SBAlertItem`
subclasses with `errorTitle`, `errorMessage`, `actions`, `applicationID`,
`crane_reappearsAfterUnlock`, hooked `configure:requirePasscodeForActions:`
and `reappearsAfterUnlock`. This is how a jailbreak alert stays dismissed
across lock/unlock if desired.

`crane_stringifyDaemons` (0x197A4) formats the broken-daemon list for
`crane_presentDaemonErrorWithBrokenDaemons:error:connectionWorks:`.

**Acceptance tests.** `T-F20-1` disabling Crane for one app via Choicy shows
`CRANE_DYLIB_NOT_LOADED_ERROR` on next launch. `T-F20-2` stopping cranehelperd
shows `CRANEHELPERD_COMMUNICATION_WARNING`. **Status: NOT_TESTED.**

### F-21 Choicy integration

**Purpose.** Choicy can disable tweaks per app; if it disables
` Crane.dylib`, Crane's data model breaks (the `CHOICYLOADER_SUGGESTION_MESSAGE`
string spells out exactly this failure mode).

**Behaviour.** `crane_initChoicyIntegration` (0x1BBB8) registers
`CraneChoicyOverwriteProvider` overriding Choicy's provider so that:
`customTweakConfigurationEnabledOverrideForApplication:`,
`overwriteGlobalConfigurationOverrideForApplication:`,
`disableTweakInjectionOverrideForApplication:`,
`customTweakConfigurationAllowDenyModeOverrideForApplication:`,
`customTweakConfigurationAllowOrDenyListOverrideForApplication:`,
`providedOverridesForApplication:`.
Gate: the global key `choicyConfigurationOverwriteEnabled`.
In `CranePrefs`, `CRPContainerChoicyOverwriteListController_init` adds
`containerIdentifier` to `CHPProcessConfigurationListController` so the Choicy
pane shows the active container. `OVERWRITE_CHOICY_CONFIGURATION` and
`CHOICY_CONFIGURATION` are UI labels.

**Version interaction.** `crane_initChoicyIntegration` runs only in the
`else` branch of `kCFCoreFoundationVersionNumber >= 1665.15` in
`crane_initSpringBoard`. Recorded as-is; the reason for the branch inversion is
**UNKNOWN** (U-07).

**Acceptance tests.** `T-F21-1` with `choicyConfigurationOverwriteEnabled`,
Crane cannot be disabled for a supported app. `T-F21-2` with it off, Choicy can
disable it and the error alert appears. **Status: NOT_TESTED.**

### F-22 App Shortcuts / Siri integration

**Behaviour.** Five intents in the modern app (`Info.plist`
`NSUserActivityTypes`): `CreateCraneContainerIntent`,
`NextCraneContainerIntent`, `SetActiveCraneContainerIntent`,
`SetDefaultCraneContainerIntent`, `WipeCraneContainerIntent`; the legacy app
declares only `SetActiveCraneContainerIntent`.
The modern app's `NSUserActivityTypes` are exactly those five names and
`SBAppTags` is `{hidden}`. `SHORTCUTS_INFO_SUGGESTION_MESSAGE` documents the
path: *Apps → Crane → Set Active Crane Container*.
The legacy extension links `libcrane.dylib` + `libsandy.dylib` and implements
`SetActiveCraneContainerIntentHandler` + `CraneIntentHandlerShared`.

**Uncertainty.** The modern extension's `CraneIntentHandlerShared` body and
the `*IntentResponse.code` values are **UNKNOWN** (no export). Recorded U-08.

**Acceptance tests.** `T-F22-1` the Set-Active-Container shortcut sets the
active container. `T-F22-2` the app appears in Shortcuts under Apps → Crane.
**Status: NOT_TESTED.**

### F-23 Activator integration

**Behaviour.** `CraneActivatorManager` (41 instance methods) provides
listeners named `%@.SetActiveContainer|%@|%@|` and events named
`%@.ChangedToContainer|%@|%@|`, with
`changedToContainerEventNameForContainerIdentifier:ofApplicationWithIdentifier:`,
`eventNameIsChangedToContainerEvent:`,
`containerIDForChangedToContainerEventName:`,
`applicationIDForChangedToContainerEventName:`, and the
`activator:requires*` / `activator:receiveEvent:forListenerName:` family.
`+[CraneActivatorManager startIfPossible]` is called first thing in
`crane_initSpringBoard`, so integration degrades silently when
`/usr/lib/libactivator.dylib` is absent (that path is probed in `CranePrefs`).

`ACTIVATOR_INFO_SUGGESTION_MESSAGE` documents that Crane offers both "set an
activator action to run when a container becomes active" and "set a container
as active", accessible under any event mode.

**Acceptance tests.** `T-F23-1` an activator action sets the active container.
`T-F23-2` without Activator installed, SpringBoard still starts normally.
**Status: NOT_TESTED.**

## 4. State machine: one container's lifecycle

```
        (no entry) --create--> [exists, inactive] --setActive--> [active]
                                  |    ^                             |
                            delete |    | makeDefault / reload        | app launch
                                  v    |                             v
                              [removed] [exists, inactive]      app runs in container
                                                                     |
                                                    wipe / app removes data
                                                                     v
                                                            [exists, empty]
```

Invariants observed statically:

- Exactly one container per app is "active" at a time; `DEFAULT` is the initial
  value.
- Setting a container active for an app that does not exist yet is impossible —
  all APIs are keyed by application identifier.
- `activeContainerIdentifierForApplicationWithIdentifier:` never returns `nil`
  in practice; `crane_containerToRedirectTo` translates `DEFAULT` to `nil`.
- Deleting the active container is not represented in the recovered selectors;
  whether it is blocked, or silently remaps to `DEFAULT`, is **UNKNOWN** (U-09).

## 5. Cross-feature interactions (all CONFIRMED_STATIC as *edges*, behaviour NOT_TESTED)

| A | B | Relationship |
|---|---|---|
| F-01 | F-02 | `CRANE_CONTAINER_IDENTIFIER` is the only channel from SpringBoard to the app |
| F-01 | F-19 | `verifyCraneInsuranceAndReply:` gates whether redirection happens at all |
| F-01 | F-21 | Choicy overrides exist so F-01 cannot be silently disabled |
| F-03 | F-01 | protection applies only in the `DEFAULT` container (`CRANE_PROTECT_CONTAINERS` only set there) |
| F-04 | F-01 | spoofing only for non-default containers |
| F-08 | F-09 | both gated on `notificationsSupportEnabled` / `separateSystemAccountsEnabled` |
| F-08 | F-12 | pkd extension redirection is part of notification support |
| F-10 | F-09 | Game Center switch only visible when separate system accounts is on |
| F-13 | F-01 | menu selection triggers `setActiveContainerIdentifier:…` then `reloadApplication:` |
| F-14 | F-08 | badges are per container, so notification support is a prerequisite |
| F-15 | F-16 | settings UI is the only writer of application settings |
| F-16 | F-19 | container mutations and reloads go through cranehelperd |
| F-17 | F-19 | keychain dump/restore is a daemon operation |
| F-20 | every | any broken dependency surfaces as an alert, not a crash |

## 6. Feature matrix

| ID | Feature | Trigger | Configuration | Observable result | Evidence | Confidence |
|---|---|---|---|---|---|---|
| F-01 | Launch redirection | SpringBoard launches app | per-app `containerProtectionEnabled`/`spoofSandboxLookupsEnabled` | container path chosen | CraneSB 0x1B45C, 0x1B360 | CONFIRMED_STATIC |
| F-02 | Env + dirs | dylib load | `CRANE_CONTAINER_IDENTIFIER` | `$HOME` = container | Crane 0x65D0 | CONFIRMED_STATIC |
| F-03 | Container isolation | default container | `containerProtectionEnabled` | `___Crane_Containers` invisible | Crane 0x7268/0x721C/0x71C0/0x7140/0x70B0 | CONFIRMED_STATIC |
| F-04 | Sandbox spoofing | self pid lookup | `spoofSandboxLookupsEnabled` | `$HOME` returned | Crane 0x6564 | CONFIRMED_STATIC |
| F-05 | Per-container prefs | `cfprefsd` resolves domain | — | prefs isolated | Support 0xBBFC | CORROBORATED |
| F-06 | Container resolution | `containermanagerd` | — | redirected path | Support 0xCC88 | CORROBORATED |
| F-07 | Per-container keychain | `SecItem*` + securityd patch | — | keychain isolated | Support 0x11E5C | CORROBORATED |
| F-08 | Per-container APNs | token generation | `notificationsSupportEnabled` + `separateNotificationRegistrationsEnabled` | tokens isolated | Support 0x9C4C, SB 0x1EB9C | CORROBORATED |
| F-09 | System accounts | `accountsd` | `separateSystemAccountsEnabled` | accounts isolated | Support 0x7200 | CONFIRMED_STATIC |
| F-10 | Game Center | launch | `gameCenterSupportEnabled` | per-container identity | SB 0x1B45C, Prefs 0x8D00 | CONFIRMED_STATIC |
| F-11 | Device identifier | `lsd` lookup | `useContainerIdentifierAsDeviceIdentifier` | identifier spoofed | Support 0xD7D8, `DEVICE_IDENTIFIER_DESCRIPTION` | CORROBORATED |
| F-12 | Plug-in enumeration | `pkd` query | `notificationsSupportEnabled` | extension isolated | Support 0xF2B4 | CONFIRMED_STATIC |
| F-13 | Container selection UI | long-press app icon | 5 global switches | menu with containers | SB 0x145B8/0x1497C/0x14CE0 | CORROBORATED (layout INFERRED) |
| F-14 | Badges | notification/app state | `showContainerNotificationBadgesEnabled`, `showContainerInNotificationTitleEnabled` | per-container badge | SB 0x7F58, `BadgeStore.plist` | CONFIRMED_STATIC |
| F-15 | Settings UI | open Settings → Crane | all switches | 8 groups of rows | `Root.plist`, `Credits.plist` | CONFIRMED_STATIC |
| F-16 | Container lifecycle | settings actions | — | create/rename/delete/wipe/default | `CraneManager` selectors | CONFIRMED_STATIC (API) / UNKNOWN (layout) |
| F-17 | Backup/restore | settings actions | `encryptBackupEnabled`, `includeKeychainEnabled` | archive round-trip | Prefs classes + strings | CONFIRMED_STATIC (UI) / UNKNOWN (format) |
| F-18 | Biometrics | set active container | — | LAContext gate | Crane 0x6E08 | CONFIRMED_STATIC |
| F-19 | cranehelperd | always | — | privileged ops work | launchd plist, class list | CONFIRMED_STATIC (registration) / UNKNOWN (protocol) |
| F-20 | Self-verification | every launch | — | alert on missing component | SB 0x17620 + strings | CONFIRMED_STATIC |
| F-21 | Choicy | Choicy installed | `choicyConfigurationOverwriteEnabled` | Crane cannot be disabled | SB 0x1BBB8 | CONFIRMED_STATIC |
| F-22 | Shortcuts | Siri/Shortcuts | — | 5 intents | app `Info.plist` | CONFIRMED_STATIC (declaration) / UNKNOWN (bodies) |
| F-23 | Activator | Activator installed | — | activator actions | SB `CraneActivatorManager` | CONFIRMED_STATIC |

## 7. Acceptance matrix summary

23 features. Static specification complete for all 23 at the level needed to
implement. Runtime verification: **0 of 23**. The reconstruction cannot exceed
"builds and is spec-consistent" until device tests exist.