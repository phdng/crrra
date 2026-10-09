# Specification

Source-independent behavioural specification of the original tweak, recovered
from the package tree and the IDA exports. Every clause carries an evidence
class. This document describes the **original**, not the reconstruction —
what was built, and how close it got, is in `reconstruction/IMPLEMENTATION_STATUS.md`
and `final/KNOWN_DIFFERENCES.md`.

Evidence classes: **CONFIRMED_STATIC** (binary metadata, decompilation, valid
IDA export, package contents), **CORROBORATED** (two or more independent
sources), **INFERRED** (plausible, not verified), **UNKNOWN**.

**No clause in this document is CONFIRMED_RUNTIME.** No device, no logs, no
screenshots exist in this environment. That caps the entire project at
PARTIAL — BUILD ONLY.

---

## 1. Identity

| Property | Value | Class |
|---|---|---|
| Product | Crane | CONFIRMED_STATIC |
| Version | 6.0 (build 1) | CONFIRMED_STATIC |
| Bundle | `com.opa334.CraneApplication` | CONFIRMED_STATIC |
| Author | Lars Fröder (opa334) | CONFIRMED_STATIC |
| Preference domain | `com.opa334.craneprefs` | CONFIRMED_STATIC |
| Helper daemon | `com.opa334.cranehelperd` (label), `….xpc`, `….preferences.xpc` | CONFIRMED_STATIC |
| Shortcuts extension | `com.opa334.CraneApplication.CraneShortcuts` | CONFIRMED_STATIC |
| Deployment target, all 7 non-app binaries | iOS 11.0, SDK 14.5.0 | CONFIRMED_STATIC |
| Deployment target, apps | iOS 14.0/SDK 18.0 and iOS 12.0/SDK 17.4 | CONFIRMED_STATIC |
| Binary layout | dylibs fat `arm64+arm64e`; executables thin `arm64` | CONFIRMED_STATIC |
| Provenance of this copy | third-party redistribution — `Root.plist` says "Crack by Repo BVN" | CONFIRMED_STATIC |

## 2. Purpose

Run multiple independent copies of one app's data ("containers") on one device,
and make each copy indistinguishable both to the app and to the app's vendor.
CONFIRMED_STATIC (product model corroborated by the filter plists, the libSandy
profiles, the launchd job, and the 5 declared App Intents).

## 3. Architecture

| Component | Path | Injected into | Filter |
|---|---|---|---|
| Main dylib | `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` | every app | `Bundles=[com.apple.Foundation]`, `Flags=0` |
| SpringBoard dylib | `…/CraneSB.dylib` | SpringBoard, runningboardd | `Bundles=[com.apple.springboard]`, `Executables=[runningboardd]` |
| Daemon-support dylib | `…/CraneSupport.dylib` | cfprefsd, containermanagerd, securityd, pkd, lsd, accountsd, apsd | `Executables=[…7…]`, `Flags=1` |
| Settings bundle | `Library/PreferenceBundles/CranePrefs.bundle/CranePrefs` | Settings | — |
| Client library | `usr/lib/libcrane.dylib` | linked by CraneSB/Support/Prefs/legacy-CraneShortcuts | — |
| Daemon | `usr/local/libexec/cranehelperd` | root launchd job | `RunAtLoad`, `KeepAlive`, `_MSSafeMode=1`, `_SafeMode=1` |
| Daemon restarter | `usr/local/bin/cranehelperd_start` | — | — |
| UI bundle | `Library/Application Support/Crane.bundle` | — | 8 icons, 10 localizations |
| App + Shortcuts | `Applications/CraneApplication.app`, `…_Legacy.app` | — | SDK 18 / SDK 17.4 |

**Filename note (CONFIRMED_STATIC):** the main dylib and its filter plist carry
a **leading space** in their filenames. Four references to the spaced name exist
inside the binaries, and `CHOICYLOADER_SUGGESTION_MESSAGE` names the library as
`" Crane.dylib"`. It is load-bearing.

Class duplication: `ClientContainerCache` is compiled twice (CraneSB and
CraneSupport, same 7 selectors) because the two dylibs never load into the same
process. `CraneManager` lives once in `libcrane.dylib`.

## 4. Configuration

### 4.1 Global switches — domain `com.opa334.craneprefs`

Read as `[[CraneManager sharedManager] preferenceValueForKey:key].boolValue`.
Every row posts `com.opa334.craneprefs/ReloadPrefs` on change.

| Key | Default | Class |
|---|---|---|
| `applicationShortcutEnabled` | YES | CONFIRMED_STATIC |
| `launchApplicationOnContainerSelectionEnabled` | NO | CONFIRMED_STATIC |
| `expandContainersShortcutEnabled` | NO | CONFIRMED_STATIC |
| `newContainerShortcutEnabled` | YES | CONFIRMED_STATIC |
| `onlyShowIfContainersExistEnabled` | YES | CONFIRMED_STATIC |
| `showContainerNotificationBadgesEnabled` | YES | CONFIRMED_STATIC |
| `notificationsSupportEnabled` | YES (bespoke setter) | CONFIRMED_STATIC |
| `showContainerInNotificationTitleEnabled` | YES | CONFIRMED_STATIC |
| `choicyConfigurationOverwriteEnabled` | unset → NO | CONFIRMED_STATIC |

### 4.2 Per-application settings — not a preference plist

Accessed via `CraneManager`; the settings UI caches an
`_applicationSettings` mutable dictionary and persists each change with a
remove-observer / write / add-observer sandwich (CONFIRMED_STATIC, CranePrefs
0xA7EC).

| Key | Default when unset | Class |
|---|---|---|
| `alwaysAskBeforeLaunchEnabled` | NO | CONFIRMED_STATIC |
| `containerProtectionEnabled` | NO | CONFIRMED_STATIC |
| `spoofSandboxLookupsEnabled` | NO | CONFIRMED_STATIC |
| `separateSystemAccountsEnabled` | NO | CONFIRMED_STATIC |
| `gameCenterSupportEnabled` | NO | CONFIRMED_STATIC |
| `separateNotificationRegistrationsEnabled` | **YES** (explicit `default=1`) | CONFIRMED_STATIC |

### 4.3 Per-container settings

`identifier`, `name`, `activeContainer`, `associatedGameCenterAccount`,
`useContainerIdentifierAsDeviceIdentifier`, `includeKeychain`,
`encryptBackupEnabled`. CONFIRMED_STATIC (CranePrefs 0x8D00, 0x8400, 0x86A8).

### 4.4 Notifications

| Name | Kind |
|---|---|
| `com.opa334.craneprefs/ReloadPrefs` | Darwin |
| `com.opa334.craneprefs/MigrationSucceeded` | Darwin |
| `com.opa334.cranesb/Loaded` | Darwin |
| `com.opa334.crane/ReloadApplication` | Darwin |
| `com.opa334.cranehelperd/Started` | Darwin |
| `com.opa334.craneliteprefs.newApp` | Darwin |
| `UIApplicationDidFinishLaunchingNotification` | local |

### 4.5 UIMenu identifiers (externally visible)

`com.opa334.crane.containers`, `.new-container-action`,
`.to-replace-with-container-selection`, `.separator`, `.open-preferences`,
`.application-container`, `com.opa334.crane-container[%@]`,
`com.opa334.crane-container.%@`. CONFIRMED_STATIC.

### 4.6 Launch-environment contract

| Variable | Written by | Read+unset by | Meaning |
|---|---|---|---|
| `CRANE_CONTAINER_IDENTIFIER` | CraneSB 0x1B45C | Crane 0x65D0 | active container ID |
| `CRANE_PROTECT_CONTAINERS=1` | CraneSB 0x1B45C | Crane 0x65D0 | hide containers (DEFAULT only) |
| `CRANE_SPOOF_SANDBOX_LOOKUPS=1` | CraneSB 0x1B45C | Crane 0x65D0 | hook the self-pid sandbox lookup |
| `CFFIXED_USER_HOME`, `HOME`, `TMPDIR` | Crane 0x65D0 | — | re-pointed at the container |

**Load order (CONFIRMED_STATIC):** SpringBoard reads the daemon's self-check,
then writes the `CRANE_*` variables; the app's dylib consumes and **unsets**
them, creates the container skeleton, sets `HOME`, then installs hooks.

## 5. Feature contracts

Full text with evidence references is in `analysis/behavior_specification.md`.
Summary:

| ID | Feature | Key rule | Class |
|---|---|---|---|
| F-01 | Launch redirection | supported app → mutate the launch environment; unsupported → return unchanged; libSandy down or self-check failed → **fail open** with an alert | CONFIRMED_STATIC |
| F-02 | In-app env + dirs | consume+unset 3 vars; create 8 directories; `setenv(overwrite=1)` | CONFIRMED_STATIC |
| F-03 | Container isolation | `unlink` returns 0 on a match **without calling the original**; `readdir`/`readdir_r`/`URLEnumeratorGetNextURL` loop past matches | CONFIRMED_STATIC |
| F-04 | Sandbox spoofing | original runs first, then overwrite the buffer for `getpid()` only; return value unchanged | CONFIRMED_STATIC |
| F-05 | Per-container prefs | `CFPrefsGetPathForTriplet` is hooked with `_orig` and its result rewritten | CORROBORATED |
| F-06 | Container resolution | `MCMContainerFactory` V2/V3 identity variants hooked with `_orig` | CORROBORATED |
| F-07 | Per-container keychain | 4 `SecItem*` hooks with `_orig` + a securityd code-signature patch | CORROBORATED |
| F-08 | Per-container APNs | 8 `APSCourierConnection` + 40 CraneSB hooks; topic rewrite to `<topic>.c_r_a_n_e.<id>.plist` | CORROBORATED |
| F-09 | System accounts | 3 `ACDDatabase` hooks + per-container Core Data map | CONFIRMED_STATIC |
| F-10 | Game Center | per-container `associatedGameCenterAccount`; the switch is appended only when F-09 is on | CONFIRMED_STATIC |
| F-11 | Device identifier | non-default containers spoof to the container ID by default; the default container's change persists system-wide | CORROBORATED |
| F-12 | Plug-in enumeration | 10 `PKDServer` hooks + `crane_activeContainerID` | CONFIRMED_STATIC |
| F-13 | Selection UI | 4 global switches gate the menu; 2 `UIMenu` initialiser variants chosen at runtime | CORROBORATED (layout INFERRED) |
| F-14 | Badges | per container, persisted to `BadgeStore.plist` | CONFIRMED_STATIC |
| F-15 | Settings UI | 8 groups; exact specifier order in `Root.plist` | CONFIRMED_STATIC |
| F-16 | Container lifecycle | create/rename/delete/wipe/default/move/copy/size/unknown-reconcile | API CONFIRMED_STATIC, layout UNKNOWN |
| F-17 | Backup/restore | ZIP via embedded `SSZipArchive`; optional encryption and keychain | UI CONFIRMED_STATIC, format UNKNOWN |
| F-18 | Biometric gate | `LAContext`; **handler runs even when biometrics are unavailable** | CONFIRMED_STATIC |
| F-19 | cranehelperd XPC | 2 Mach services; ~30 client selectors | registration CONFIRMED_STATIC, protocol UNKNOWN |
| F-20 | Self-verification | 5 runtime `SBAlertItem` subclasses | CONFIRMED_STATIC |
| F-21 | Choicy integration | `CraneChoicyOverwriteProvider`, 6 overrides | CONFIRMED_STATIC |
| F-22 | Shortcuts | 5 intents (modern) / 1 (legacy) | declaration CONFIRMED_STATIC, bodies UNKNOWN |
| F-23 | Activator | listener `%@.SetActiveContainer\|%@\|%@\|`, event `%@.ChangedToContainer\|%@\|%@\|` | CONFIRMED_STATIC |

## 6. Hook inventory

162 registrations: 109 `MSHookMessageEx`, 2 `MSHookFunction` (plus 4 `SecItem*`
and `_CFPrefsGetPathForTriplet` symbol pairs), 51 `class_addMethod`, and
`HCHookFunctions` tables in ` Crane.dylib` (1 mandatory + up to 4 protection).
Full table: `analysis/hook_reconstruction.md`; machine-readable:
`analysis/hooks_index.csv`.

Per binary: CraneSB 113, CraneSupport 48, CranePrefs 1, main dylib 0 direct
(table-driven), app 0.

## 7. UI states

| Screen | Structure | Class |
|---|---|---|
| Settings → Crane | 8 groups; see `tests/ui_comparison.md` §2.1 | CONFIRMED_STATIC |
| Per-application pane | 14 conditional rows; see `tests/ui_comparison.md` §2.2 | CONFIRMED_STATIC |
| Credits | ZipArchive + MiniZip licenses, then 11 per-language credit groups | CONFIRMED_STATIC |
| Active Container sheet | one row per container + checkmark on the active one | INFERRED |
| App long-press menu | container rows, separator, New Container, Settings | INFERRED (U-05) |
| Error alert | `CRErrorAlert` with title/message/actions; can require a passcode and reappear after unlock | CONFIRMED_STATIC (mechanism) / UNKNOWN (appearance) |

Typography, colours, insets, control sizes and row heights: **UNKNOWN for every
screen.** None is recoverable from the extracted package.

Localization: 204 keys in `en.lproj`, 10 languages total.

## 8. Lifecycle

```
install ──► launchd starts cranehelperd (RunAtLoad)
          ──► per-process dylib load:
                 every app            → Crane InitFunc_0  (env → dirs → hooks)
                 SpringBoard          → CraneSB InitFunc_2 → crane_initSpringBoard
                 runningboardd        → CraneSB InitFunc_2 → crane_initRunningBoardd
                 7 system daemons     → CraneSupport InitFunc_0 → per-daemon init
                 Settings             → PreferenceLoader → CRPRootListController
user selects container
   ──► SpringBoard crane_applyEnvironmentChanges
   ──► [CraneManager setActiveContainerIdentifier:…]
   ──► reloadApplicationWithIdentifier:
   ──► next launch: Crane 0x65D0 consumes CRANE_CONTAINER_IDENTIFIER
```

CONFIRMED_STATIC. Two module-constructor details are preserved as observed: the
alert classes are created *before* `crane_initSpringBoard` (address order), and
`crane_initSpringBoard` guards its `dispatch_once` behind
`applicationShortcutsEnabled() && qword_2D400 != -1`.

## 9. Acceptance tests

76 tests, specified in `tests/functional_tests.md`, distributed as F-01: 7,
F-02: 4, F-03: 6, F-04: 4, F-05: 3, F-06: 2, F-07: 3, F-08: 4, F-09: 2,
F-10: 2, F-11: 3, F-12: 2, F-13: 5, F-14: 3, F-15: 4, F-16: 3, F-17: 5,
F-18: 2, F-19: 4, F-20: 2, F-21: 2, F-22: 2, F-23: 2.

**Executed: 0.** Each has a pre-specified expected result so it can be run
directly against a device.

## 10. Unresolved uncertainties

14 open, 1 blocked, 3 resolved. Full register:
`analysis/uncertainty_register.md`.

Highest impact:

| ID | Question | Blocks |
|---|---|---|
| U-01 | the cranehelperd XPC interface | F-19, and the honest interoperability of any rebuild |
| U-02 | the cfprefsd redirect condition | F-05 |
| U-04 | container on-disk layout and identifier generation | F-16, F-17 |
| U-05 | the selection-menu layout | F-13 |
| U-06 | backup archive, encryption and keychain dump formats | F-07, F-17 |
| U-19 | the `postinst` that picks between the two app bundles | packaging (BLOCKED — needs the original `.deb`) |

## 11. Evidence index

| Claim area | Primary evidence | Machine-readable |
|---|---|---|
| Install layout, hashes | `tools/classify_files.py`, `tools/make_manifest.py` | `analysis/package_inventory.md` |
| Binary metadata | `tools/macho_inspect.py` | `analysis/binary_inventory.md` |
| Export↔binary identity | `tools/prove_export_identity.py` | `analysis/ida_export_coverage.md` |
| Export inventory/coverage | `tools/build_export_index.py` | `analysis/ida_export_inventory.md`, `symbols_index.csv`, `strings_index.csv`, `callers_index.csv` |
| Classes and methods | `tools/objc_classes.py` | `analysis/objc_classes.json`, `analysis/class_and_method_map.md` |
| Hooks | `tools/extract_hooks.py` | `analysis/hooks_index.csv`, `analysis/hook_reconstruction.md` |
| Preferences | `tools/pref_schema.py`, `tools/pref_access.py` | `analysis/preference_schema.md`, `preference_schema.csv`, `preference_access.csv` |
| Behaviour | manual synthesis from all of the above | `analysis/behavior_specification.md` |
| Gaps | — | `analysis/uncertainty_register.md`, `final/KNOWN_DIFFERENCES.md` |