# Class and Method Map

Recovered two ways and cross-checked:

1. `analysis/objc_classes.json` — parsed directly from each Mach-O slice
   (`__DATA,__objc_classlist` → `class_ro_t` → `method_list_t`), covering
   **all** binaries including the six with no IDA export.
2. `analysis/symbols_index.csv` — IDA-named functions, which includes
   `-[Class selector]` / `+[Class selector]` symbols recovered by IDA for
   classes declared in `__objc_const` (categories and classes whose method
   lists IDA symbolised).

Where both exist they agree on class names. Categories are only visible in
the IDA symbols (e.g. `-[CRPApplicationConfigurationListController …]` for a
class that is not in `__objc_classlist`), so **the union** is used.

## 1. Classes per binary

### `CraneSB.dylib` — 5 classes in `__objc_classlist`

| Class | Inst. methods | Notes |
|---|---:|---|
| `CRBadgeAction` | 4 | UIAction subclass for the per-container badge action |
| `CRSubtitleMenu` | 6 | `UIMenu` subclass carrying a `subtitle` |
| `ClientContainerCache` | 7 | pid → active container cache, XPC-backed |
| `CraneActivatorManager` | 41 | Activator integration (listeners + events) |
| `CraneChoicyOverwriteProvider` | 6 | Forces Choicy to keep Crane loaded first |

Plus dynamically created at runtime: `CRErrorAlert`, `CRNewContainerAlert`
(both subclasses of `SBAlertItem`, created in `InitFunc_0`/`InitFunc_1`).

### `CraneSupport.dylib` — 1 class

`ClientContainerCache` (7 instance methods) — same role as in CraneSB but a
separate copy, since each dylib is loaded into disjoint processes.

### `CranePrefs` — 34 classes

| Group | Classes |
|---|---|
| Entry points | `CRPRootListController` (15) |
| Application config | `CRPApplicationConfigurationListController` (43), `CRPContainerConfigurationListController` (60), `CRPActiveContainerListItemsController` (2), `CRPApplicationListSubcontrollerController` (3), `CRPBrowseContainerListController` (5), `CRPListController` (2), `CRPCellRefreshingListItemsController` (1), `CRPRootPageSuggestionProvider` |
| Container actions | `CRPDestructiveTableCell`, `CRPRightAlignedEditableTableCell`, `CRPNonBlueButtonTableCell`, `CRPInfoTableCell`, `CRPPresetSelectionCell`, `CRPMultiBackupContainerSelectionCell` |
| Backup / restore | `CRPNewBackupListController` (42), `CRPBackupOperation` (41), `CRPBackupContainer` (23), `CRPBackupRestoreController` (19), `CRPRestoreOperation` (43), `CRPBridgeContainer`→`CRPRestoreContainerMatchController` (25), `CRPMultiBackupPresetListController` (21), `CRPMultiBackupSelectionListController` (15), `CRPBackupRestoreProgressAlertController` (30), `CRPAlertWithLoadingBarController` (6) |
| Game Center | `CRPGameCenterAccountsController` (20) |
| Migration / keychain | `CRPPreferenceMigrator` (0 impl; all methods via categories), `CRPKeychainManager` (0 impl) |
| Credits | `CRPCreditsController` (16), `CRPCreditsMiniZipController`, `CRPCreditsZipArchiveController` |
| Vendored | `SSZipArchive` (13) — MiniZip/ZipArchive embedded |
| Cache | `ClientContainerCache` (7) |

`CRPPreferenceMigrator` and `CRPKeychainManager` have zero methods in the
base `class_ro_t`; their methods live in **categories** on those classes, which
IDA symbolised as `-[CRPPreferenceMigrator …]` / `-[CRPKeychainManager …]`.
The category list is therefore the authoritative source for them.

### `cranehelperd` — 6 classes

| Class | Inst. | Role (evidence) |
|---|---:|---|
| `CRHServiceShared` | 19 | base service object |
| `CRHGlobalService` | 15 | implements `CRHGlobalServiceProtocol` |
| `CRHGlobalServiceDelegate` | 1 | delegate |
| `CRHPreferencesService` | 3 | implements `CRHPreferencesServiceProtocol` |
| `CRHPreferencesServiceDelegate` | 1 | delegate |
| `CRHKeychain` | 0 | base; methods via categories |

Protocols: `CRHGlobalServiceProtocol`, `CRHPreferencesServiceProtocol`.

### `CraneShortcuts.appex` (legacy build, the one with a class list)

`IntentHandler`, `SetActiveCraneContainerIntent`, `SetActiveCraneContainerIntentHandler`
(9 inst / 4 class), `SetActiveCraneContainerIntentResponse`.

### `CraneApplication.app` (iOS 16+ build)

**No `__objc_classlist`** — the binary is almost entirely Swift/App-Intents
code plus thin `INIntentResponse` subclasses. IDA recovered 53 functions:
`ViewController`, `AppDelegate`, `SceneDelegate`, and five
`*IntentResponse` classes (`SetActiveCraneContainerIntentResponse`,
`NextCraneContainerIntentResponse`, `WipeCraneContainerIntentResponse`,
`CreateCraneContainerIntentResponse`, `SetDefaultCraneContainerIntentResponse`),
each with only `initWithCode:userActivity:`, `code`, `setCode:` — i.e. they
carry no Crane logic of their own.

### `CraneShortcuts.appex` (iOS 16+ build)

27 class names in `__TEXT,__objc_classname`, one Crane-prefixed:
`CraneIntentHandlerShared`.

### Binaries with no Objective-C classes at all

` Crane.dylib` (pure C, `libSandy` + Substrate), `libcrane.dylib`
(its class `CraneManager` is exported as a symbol but has no `classlist`
entry — it is likely constructed/registered differently), `cranehelperd_start`.
`cranehelperd`'s `CRHKeychain` and `CranePrefs`' `CRPKeychainManager` /
`CRPPreferenceMigrator` are category-only, as noted.

## 2. High-value method detail

### `CraneSB` — launch path (this is the core of the tweak)

| Function | Address | Contract |
|---|---:|---|
| `crane_initSpringBoard` | 0x17A14 | SpringBoard entry point (see `hook_reconstruction.md`) |
| `crane_initRunningBoardd` | 0x1BF10 | runningboardd entry point |
| `crane_applyEnvironmentChanges(ctx, appID)` | 0x1B45C | injects `CRANE_CONTAINER_IDENTIFIER`, `CRANE_PROTECT_CONTAINERS`, `CRANE_SPOOF_SANDBOX_LOOKUPS` into the launch environment |
| `crane_containerToRedirectTo(appID)` | 0x1B360 | returns the active container ID, or `nil` for DEFAULT / unsupported apps |
| `ClientContainerCache.activeContainerIdentifierForPid:` | 0x205CC | pid → active container, via cranehelperd XPC |

### `CraneSB` — preference predicates (all read through `CraneManager`)

| Function | Address | Preference key |
|---|---:|---|
| `applicationShortcutsEnabled` | 0x1ECD8 | `applicationShortcutEnabled` |
| `expandContainersShortcutEnabled` | 0x1EDE4 | `expandContainersShortcutEnabled` |
| `launchApplicationOnContainerSelectionEnabled` | 0x1ED64 | `launchApplicationOnContainerSelectionEnabled` |
| `newContainerShortcutEnabled` | 0x1EEF0 | `newContainerShortcutEnabled` |
| `onlyShowIfContainersExistEnabled` | 0x1EE64 | `onlyShowIfContainersExistEnabled` |
| `showContainerNotificationBadgesEnabled` | 0x1EF7C | `showContainerNotificationBadgesEnabled` |
| `notificationRedirectionEnabledForApp` | 0x1EB9C | `notificationsSupportEnabled` **and** per-app `separateNotificationRegistrationsEnabled` |
| `alwaysAskBeforeLaunchEnabled` | 0x1F008 | `alwaysAskBeforeLaunchEnabled` |

### `CranePrefs` — container settings model

`CRPApplicationConfigurationListController` keeps an in-memory
`_applicationSettings` `NSMutableDictionary`; reads go through
`readPreferenceValueForKey:` (`objectForKey:`), writes through
`setPreferenceValue:key:` which **re-registers as observer around the write**:

```
setPreferenceValue:key:(value, key)
    [[CraneManager sharedManager] removeObserver:self]
    _applicationSettings[key] = value
    [[CraneManager sharedManager] setApplicationSettings:[_applicationSettings copy]
                                    forApplicationWithIdentifier:appID]
    [[CraneManager sharedManager] addObserver:self]
```

Container entries live under the `Containers` key as an array of dicts with at
least `identifier` and `name` (seen in `renameContainerWithIdentifier:toName:`
and `removeContainerWithIdentifier:`).

Per-container settings keys read by the settings UI
(`CRPContainerConfigurationListController specifiers`, address 0x8D00):

| Key | Source |
|---|---|
| `activeContainer` | property on the "Active Container" specifier |
| `alwaysAskBeforeLaunchEnabled` | switch, value=YES |
| `separateNotificationRegistrationsEnabled` | switch, default=YES, only added when `notificationsSupportEnabled` is unset-or-true |
| `separateSystemAccountsEnabled` | switch, enabled=YES (not user-toggleable at specifier level) |
| `gameCenterSupportEnabled` | switch, enabled=YES; specifier retained in `self.gameCenterSupportEnabledSpecifier` and **only appended when `separateSystemAccountsEnabled` is true** |
| `containerProtectionEnabled` | switch, enabled=YES |
| `spoofSandboxLookupsEnabled` | switch, enabled=YES |
| `useContainerIdentifierAsDeviceIdentifier` | referenced from `crane_setIdentifier:` path |
| `deviceIdentifier` / custom identifier | via `deviceIdentifierToUseForContainerWithIdentifier:ofApplicationWithIdentifier:`, `setDeviceIdentifier:ofContainerWithIdentifier:andApplicationWithIdentifier:` |

### `cranehelperd` API surface (from `__objc_methname`)

`CRHGlobalService` exposes `crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:`,
`crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:`, plus
`verifyCraneInsurance`, `verifyCraneSupportLoaded`, `verifyCraneSBLoaded`,
`fetchActiveContainerIDForProcessWithPid`, `reloadApplication`, `resetBadge`,
`switchBadges`, `unregisterFromNotifications`, `presentDaemonError`,
`presentMainDylibNotLoadedError`, `presentApsdRegistrationError`,
`presentPkdRegistrationError`, `presentLibSandyNotWorkingError`.

## 3. Cross-binary class duplication

`ClientContainerCache` exists **twice** with the same 7 method selectors —
once in `CraneSB.dylib`, once in `CraneSupport.dylib`. They are separate
compilations of the same source into two dylibs that are never loaded into the
same process. A reconstruction should do the same (it avoids adding a new
shared dependency) rather than "fixing" the duplication.

`CraneManager` is defined once in `libcrane.dylib` and used by
`CraneSB.dylib`, `CraneSupport.dylib`, `CranePrefs`, and the legacy
`CraneShortcuts`. It is **not** linked by the iOS 16+ `CraneShortcuts`, which
has its own `CraneIntentHandlerShared`.