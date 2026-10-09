# Symbols and Selectors

Machine-readable indexes produced by `tools/build_export_index.py`:

| File | Rows | Contents |
|---|---:|---|
| `analysis/symbols_index.csv` | 2651 | every IDA-exported function: address, name, file, caller/callee lists |
| `analysis/callers_index.csv` | 6485 | directed call edges `callee ← caller` |
| `analysis/strings_index.csv` | 3667 | every exported string: address, length, type, text |
| `analysis/objc_classes.json` | — | classes/methods parsed straight from each Mach-O |
| `analysis/hooks_index.csv` | 159 | hook registrations with target class+selector |
| `analysis/crane_api_symbols.csv` | 22 | Crane-prefixed selectors/classes in the 6 unexported binaries |
| `analysis/preference_access.csv` | 14 | preference reads/writes per function |

## 1. Exported symbol surface (`exports.txt`)

Stripped binaries export only what Theos/Substrate needs. The real API is:

| Binary | Exported symbols |
|---|---|
| ` Crane.dylib` | 22: the 4 `sandbox_container_path_for_pid*`/`localize`/`containerPathForContainer`/`createDirectoryIfNotExists`/`normalizedContainerID`/`requestAuthentication`/`initUNProtocol`/`initProtection`/`HCHookFunctions`/… helpers, the `new_*` protection hooks, their `_org_*` storage, and `InitFunc_0` |
| `CraneSB.dylib` | 105: `init*` hook-group entry points, `crane_*` helpers, all 7 preference predicates, `ClientContainerCache`-related entry points, the 5 `OBJC_CLASS_$`/`OBJC_METACLASS_$` symbols it needs externally (`CRBadgeAction`, `CRSubtitleMenu`, `CraneActivatorManager`, `CraneChoicyOverwriteProvider`, `ClientContainerCache`) and 2 `OBJC_IVAR_$_CraneActivatorManager._*` symbols |
| `CraneSupport.dylib` | 293: every `init*`, the `csd_*`/`macho_*`/`fat_*`/`memory_stream_*`/`pfsec_*`/`arm64_*` helpers, `SecItem*_hook`/`_orig` pairs, `ClientContainerCache` symbols, `OBJC_IVAR_$_ClientContainerCache._*`, and `InitFunc_0` |
| `CranePrefs` | (see its own `exports.txt`; 561 entries) UI entry points and the embedded ZipArchive/MiniZip symbols |
| `CraneApplication` | 2: `__mh_execute_header`, `start` |

The `OBJC_IVAR_$_ClientContainerCache._*` exports
(`_daemonCenter`, `_activeContainerCache`, `_activeContainerCacheQueue`) and the
matching `CraneActivatorManager._setActiveContainerListenersCache` /
`._changedToContainerEventCache` confirm the ivar layout a reconstruction must
match if it wants the same cross-library access.

## 2. Objective-C classes recovered from the binaries

See `class_and_method_map.md` for the full per-binary table and
`analysis/objc_classes.json` for every method with its IMP address. Summary of
what is NOT in `__objc_classlist` but IS in the binary:

- Categories (all of `CranePrefs`' `CRPPreferenceMigrator` and
  `CRPKeychainManager` methods, plus all `CRPApplicationConfigurationListController`
  methods, which live in a category on a different base class)
- `CraneManager` (in `libcrane.dylib`)
- The alert classes CraneSB builds at runtime
- Everything in the iOS 16+ `CraneApplication` (Swift/App-Intents generated code)

## 3. Selector reference (all binaries, from `__TEXT,__objc_methname`)

### 3a. `CraneManager` public API (the cross-library contract)

Recovered from `objc_msgSend` selector literals in CraneSB / CraneSupport /
CranePrefs. This list is the **interface a reconstruction must provide** or the
linking binaries cannot work.

Container registry:

```
isApplicationSupportedByCrane:
identifiersOfAllSupportedApplications
identfiersOfApplicationsThatHaveNonDefaultContainers
applicationSettingsForApplicationWithIdentifier:
setApplicationSettings:forApplicationWithIdentifier:
containerSettingsForContainerWithIdentifier:ofApplicationWithIdentifier:
setContainerSettings:forContainerWithIdentifier:ofApplicationWithIdentifier:
containerIdentifiersOfApplicationWithIdentifier:
activeContainerIdentifierForApplicationWithIdentifier:
setActiveContainerIdentifier:forApplicationWithIdentifier:
setActiveContainerIdentifier:forApplicationWithIdentifier:reloadApplication:usingBiometricsIfNeededWithSuccessHandler:
setActiveContainerIdentifier:forApplicationWithIdentifier:usingBiometricsIfNeededWithSuccessHandler:
createNewContainerWithName:forApplicationWithIdentifier:
createNewContainerWithName:andIdentifier:forApplicationWithIdentifier:
deleteContentOfContainerWithIdentifier:forApplicationWithIdentifier:
wipeContainerWithIdentifier:forApplicationWithIdentifier:shouldRepopulate:
makeDefaultForContainerWithIdentifier:forApplicationWithIdentifier:
moveOrCopyContainerFromPath:toPath:move:
pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:
enumerate:pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:
sizeOccupiedByContainerWithIdentifier:ofApplicationWithIdentifier:completionHandler:
unknownContainersInsideApplicationWithIdentifier:knownContainers:
displayNameForApplicationWithIdentifier:
displayNameForContainerWithIdentifier:ofApplicationWithIdentifier:shouldUseShortVersion:
displayNameForContainerWithName:isDefaultContainer:shouldUseShortVersion:
deviceIdentifierToUseForContainerWithIdentifier:ofApplicationWithIdentifier:
setDeviceIdentifier:ofContainerWithIdentifier:andApplicationWithIdentifier:
applicationHasDeviceIdentifier:
isKeychainVersionUpToDate
updateKeychainVersion
migrateApplication:withAppSettings:
```

Keychain / backup:

```
dumpKeychainItemsFromContainerWithIdentifier:forApplicationIdentifier:reply:
restoreKeychainItemsToContainerWithIdentifier:forApplicationIdentifier:fromDictionary:
containersToBackup
```

Process control:

```
reloadApplicationWithIdentifier:
reloadApplicationWithIdentifier:ifContainerIsActive:
reloadApplicationIfContainerActive
reloadApplicationIfThisContainerIsActive
reloadDaemons:
isDylibLoaded
verifyCraneInsuranceAndReply:
verifyCraneSupportLoadedIntoDaemon:reply:
verifyCraneSBLoadedAndReply:
fetchActiveContainerIDForProcessWithPid:reply:
cranehelperdConnectionWorks
cranehelperdGlobalSyncRemoteObjectProxy
cranehelperdGlobalAsyncRemoteObjectProxy
```

Game Center:

```
gameCenter_setActiveAccount:
gameCenter_setActiveAccount:andDontKillApplication:
gameCenter_activeAccount
gameCenter_availableAccounts
gameCenter_setAvailableAccounts:
gameCenter_isAccountAvailable:
gameCenter_reloadExceptApplicationWithIdentifier:
```

Preferences and Choicy:

```
preferenceValueForKey:
_setXPCUnsandboxHandler:
resetLastError
getLastError
```

### 3b. Crane-injected selectors (added at runtime)

```
crane_containerIdentifier                                       FBProcess
crane_applyModificationsIfNeededToExecutionContext:withApplicationIdentifier:
crane_registerInjectionCheckForProcess:toBeLaunchedIntoContainer:
crane_provideContainerOptions / setCrane_provideContainerOptions:   SBUIActionView
crane_isSeparator / setCrane_isSeparator:
crane_trailingView / crane_rebuildConstraints / crane_updateConstraints
craneContainersApplicationShortcutItems                         SBUIAppIconForceTouchControllerDataProvider
crane_copyWithoutContainerID                                     UNS* record
crane_resetBadgeOfContainerWithIdentifier:ofApplicationWithIdentifier:
crane_switchBadgesOfContainerWithIdentifier:andContainerWithIdentifier:ofApplicationWithIdentifier:
crane_unregisterFromNotificationsIfNeededForContainerIdentifier:ofApplicationWithIdentifier:
crane_activeContainer / setCrane_activeContainer:               ACDDatabase
crane_databasesByContainerIdentifiers / set…:                    ACDDatabase
crane_storeCoordinatorsByContainerIdentifiers / set…:            ACDDatabase
crane_activeContainerID / setCrane_activeContainerID:             PKDServer
crane_topicStorage / setCrane_topicStorage:                       APSCourierConnection
crane_getIdentifier:ofType:forVendorName:andBundleIdentifier:    _LSDDeviceIdentifierClient
crane_setIdentifier:ofType:forVendorName:andBundleIdentifier:
crane_applyRedirectionForContainerWithIdentifier:                (CraneSupport)
crane_containerToRedirectToForClient:                            (CraneSupport)
crane_presentMainDylibNotLoadedErrorForAppName:                 UNSUserNotificationServerConnectionListener
crane_presentApsdRegistrationErrorForAppId:
crane_presentPkdRegistrationErrorForAppId:
crane_presentLibSandyNotWorkingError
crane_presentDaemonErrorWithBrokenDaemons:error:connectionWorks:
crane_reappearsAfterUnlock / setCrane_reappearsAfterUnlock:      CRErrorAlert (SBAlertItem subclass)
errorTitle / errorMessage / actions                              CRErrorAlert
applicationID / setApplicationID:                                CRNewContainerAlert (SBAlertItem subclass)
containerIdentifier                                              CHPProcessConfigurationListController
```

### 3c. Notification identifiers and constants

```
%@.ChangedToContainer                    listener/event name template (Activator)
%@.ChangedToContainer|%@|%@|             listener-name template
%@.SetActiveContainer|%@|%@|             listener-name template
saveNotification_containerID             ivar added to notification record
extension_containerIDToAppend            key in notification-request mutation
crane_containerID / crane_sourceContainerID / crane_requestOriginContainerID
previousContainerID
APPLICATIONS/%@                           Settings deep-link path component
prefs:root=%@&path=%@/%@                  Settings deep-link URL
com.opa334.crane.application-container
com.opa334.crane.containers
com.opa334.crane-container / com.opa334.crane-container. / com.opa334.crane-container.%@
com.opa334.crane.new-container-action
com.opa334.crane.open-preferences
com.opa334.crane.separator
com.opa334.crane.to-replace-with-container-selection
```

The `com.opa334.crane.*` family are **UIMenu identifiers** consumed by
`initUIMenuHooks` and `SBUIActionView`; they are externally observable
(Shortcut/`UIMenu` automation and Choicy configs reference them) and must be
preserved verbatim.

## 4. Imports worth calling out

| Binary | Import that shapes behaviour |
|---|---|
| ` Crane.dylib` | `CydiaSubstrate`, `LocalAuthentication` (biometrics), `libc++`, `Foundation`, `CoreFoundation` |
| `CraneSB.dylib` | `libsandy.dylib`, `libcrane.dylib`, `BackBoardServices`, `AppSupport`, `MobileCoreServices`, `UIKit`, `LocalAuthentication`, `CydiaSubstrate` |
| `CraneSupport.dylib` | `Security`, `libsandy.dylib`, `libbsm.0.dylib`, `libcrane.dylib`, `AppSupport`, `CoreData`, `CydiaSubstrate` |
| `CranePrefs` | `AltList`, `Preferences`, `AppSupport`, `libz`, `libiconv`, `libcrane.dylib`, `MobileCoreServices`, `CoreGraphics` |
| `CraneApplication` (iOS 18) | `Intents`, `UIKit`, `Foundation` — no Crane libs |
| `CraneShortcuts` (legacy) | `Intents` + `libcrane.dylib` + `libsandy.dylib` |
| `cranehelperd` | `BackBoardServices`, `MobileCoreServices`, `Security`, `CydiaSubstrate` |

`libbsm.0.dylib` (Basic Security Module) is only in `CraneSupport`: it backs
the `securityd_xpc_dictionary_handler` hook that rewrites keychain access
groups. A reconstruction omitting it cannot intercept keychain queries the same
way.

## 5. Symbols deliberately NOT invented

The following are referenced in code or localization text but could not be
resolved to a definition anywhere in this tree, and are recorded as UNKNOWN
rather than reconstructed:

| Symbol | Why it is unknown |
|---|---|
| `libSandy_works()`, `libSandy_works` | lives in `libsandy.dylib`, which is **not part of this package** (only its `Library/libSandy/*.plist` config is) |
| `CraneManager`'s internals | `libcrane.dylib` has no IDA export |
| `CRHGlobalServiceProtocol` / `CRHPreferencesServiceProtocol` method lists | protocols are in `cranehelperd`; `cranehelperd` has no IDA export |
| `CraneIntentHandlerShared` | iOS 16+ `CraneShortcuts`, no IDA export |
| `CRPPreferenceMigrator` / `CRPKeychainManager` method lists | category-only; recovered from IDA symbols, bodies present, but the *registration* is dynamic |
| Precise `target_class` for the 40 notification hooks | aliased variable in the decompilation (see `hook_reconstruction.md` §3) |