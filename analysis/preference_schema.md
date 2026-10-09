# Preference Schema

Machine-readable: `analysis/preference_schema.csv` (declared UI cells) and
`analysis/preference_access.csv` (reads/writes recovered from pseudocode).

## 1. Storage domain (CONFIRMED_STATIC)

Two different stores are in play, and conflating them is the most likely
source of a behavioural difference in a reconstruction.

### 1a. Global switches — `com.opa334.craneprefs`

Declared in `Library/PreferenceBundles/CranePrefs.bundle/Root.plist`, every
`PSSwitchCell` carries `defaults = "com.opa334.craneprefs"`.
Read path, from `launchApplicationOnContainerSelectionEnabled` (0x1ED64,
CraneSB) and the seven sibling predicates:

```objc
[[CraneManager sharedManager] preferenceValueForKey:@"<key>"].boolValue
```

`CraneManager` is in `libcrane.dylib`, so the domain name itself lives in
code that has **no export directory**. `com.opa334.craneprefs` is therefore
CONFIRMED_STATIC from `Root.plist` + `libCrane.plist`'s sandbox grant of
`/var/mobile/Library/Preferences/com.opa334.craneprefs.plist`, and the
accessor name `preferenceValueForKey:` is CONFIRMED_STATIC from the call sites
in the exported binaries. The exact `CFPreferences` vs `NSUserDefaults` call
inside `CraneManager` is **UNKNOWN**.

| Key | Label | Default | PostNotification |
|---|---|---|---|
| `applicationShortcutEnabled` | `APP_SHORTCUT_ENABLED` | `YES` | `com.opa334.craneprefs/ReloadPrefs` |
| `launchApplicationOnContainerSelectionEnabled` | `LAUNCH_APPLICATION_ON_CONTAINER_SELECTION` | `NO` | `com.opa334.craneprefs/ReloadPrefs` |
| `expandContainersShortcutEnabled` | `EXPAND_CONTAINERS_SHORTCUT` | `NO` | `com.opa334.craneprefs/ReloadPrefs` |
| `newContainerShortcutEnabled` | `SHOW_NEW_CONTAINER_OPTION` | `YES` | `com.opa334.craneprefs/ReloadPrefs` |
| `onlyShowIfContainersExistEnabled` | `ONLY_SHOW_IF_CONTAINERS_EXIST` | `YES` | `com.opa334.craneprefs/ReloadPrefs` |
| `showContainerNotificationBadgesEnabled` | `SHOW_CONTAINER_NOTIFICATION_BADGES` | `YES` | `com.opa334.craneprefs/ReloadPrefs` |
| `notificationsSupportEnabled` | `NOTIFICATIONS_SUPPORT_ENABLED` | `YES` | `com.opa334.craneprefs/ReloadPrefs` |
| `showContainerInNotificationTitleEnabled` | `SHOW_CONTAINER_IN_TITLE` | `YES` | `com.opa334.craneprefs/ReloadPrefs` |

`notificationsSupportEnabled` additionally carries
`set = "setNotificationsSupportEnabled:specifier:"` in `Root.plist`, i.e. it
has a bespoke setter (`nestedEntryCount = 1`).

Two more switches are consumed by `CraneSB`/`CraneSupport` but are **not**
declared in `Root.plist`; they are per-application settings (see 1b) or set
elsewhere. Recorded from `objc_msgSend` selector literals and `CFSTR` uses:

| Key | Where read |
|---|---|
| `alwaysAskBeforeLaunchEnabled` | CraneSB 0x1F008; CranePrefs 0x8D00 |
| `containerProtectionEnabled` | CraneSB 0x1B45C (launch env); CranePrefs 0x8D00 |
| `spoofSandboxLookupsEnabled` | CraneSB 0x1B45C (launch env); CranePrefs 0x8D00 |
| `gameCenterSupportEnabled` | CraneSB 0x1B45C; CranePrefs 0x8D00 |
| `separateNotificationRegistrationsEnabled` | CraneSB 0x1EB9C; CranePrefs 0x8D00 |
| `separateSystemAccountsEnabled` | CraneSupport 0x6E88; CranePrefs 0x8D00 |
| `choicyConfigurationOverwriteEnabled` | CraneSB 0x1E3A4; CranePrefs 0x10E68 |
| `customTweakConfigurationEnabled` | CraneSB 0x1E4E0 |

`containerProtectionEnabled`, `spoofSandboxLookupsEnabled`,
`alwaysAskBeforeLaunchEnabled`, `gameCenterSupportEnabled`,
`separateNotificationRegistrationsEnabled` and `separateSystemAccountsEnabled`
are read from `applicationSettingsForApplicationWithIdentifier:` — i.e. they
are **per-app** values, while their siblings in `Root.plist` are global. Both
sets use the same key names in the same process; which store wins is decided by
the accessor, not by the key.

### 1b. Per-application settings — `CraneManager` API

Not a preference plist at all. Read/written through `CraneManager`:

```objc
-[CraneManager applicationSettingsForApplicationWithIdentifier:]        // read
-[CraneManager setApplicationSettings:forApplicationWithIdentifier:]   // write
-[CraneManager containerSettingsForContainerWithIdentifier:ofApplicationWithIdentifier:]
-[CraneManager setContainerSettings:forContainerWithIdentifier:ofApplicationWithIdentifier:]
```

The settings UI caches the application dict in `_applicationSettings` and
mutates it in place, persisting on every change with the
remove-observer / write / add-observer sandwich shown in
`class_and_method_map.md`.

Structure recovered from the settings UI (CONFIRMED_STATIC):

```
applicationSettings[applicationIdentifier] = {
    "Containers": [ { "identifier": …, "name": …, …per-container keys }, … ],
    "gameCenterSupportEnabled": <bool>,
    "containerProtectionEnabled": <bool>,
    "spoofSandboxLookupsEnabled": <bool>,
    "separateNotificationRegistrationsEnabled": <bool>,
    "separateSystemAccountsEnabled": <bool>,
    "alwaysAskBeforeLaunchEnabled": <bool>,
    "presets": …,
    …
}
```

Per-container keys observed: `identifier`, `name`, `activeContainer`,
`associatedGameCenterAccount`, `useContainerIdentifierAsDeviceIdentifier`,
device identifier, `includeKeychain`, `encryptBackupEnabled` (backup side),
`createButton`/`updateCreateButtonEnabled` (UI state).

## 2. Notifications and Darwin notifications (CONFIRMED_STATIC)

| Name | Kind | Observer / poster |
|---|---|---|
| `com.opa334.craneprefs/ReloadPrefs` | `DarwinNotificationCenter` | posted by every `Root.plist` switch |
| `com.opa334.craneprefs/MigrationSucceeded` | `DarwinNotificationCenter` | posted by `CRPPreferenceMigrator`; observed by CraneSB `keychainMigrationSuceeded` (CraneSB 0x17A14, CranePrefs 0x16920) |
| `com.opa334.cranesb/Loaded` | `DarwinNotificationCenter` | observed by `ClientContainerCache._registerForClearMessages` (CraneSB 0x1486C/0x1782C/0x20244; CraneSupport 0x12724; CranePrefs 0x3E834) |
| `com.opa334.crane/ReloadApplication` | `DarwinNotificationCenter` | CraneSupport 0xF2B4 |
| `com.opa334.cranehelperd/Started` | `DarwinNotificationCenter` | CranePrefs 0x22614 |
| `com.opa334.craneliteprefs.newApp` | `DarwinNotificationCenter` | CranePrefs 0x1D1A4 (Crane Lite import path) |
| `UIApplicationDidFinishLaunchingNotification` | `NSNotificationCenter` (local) | CraneSB `didFinishLaunching` |

## 3. Files and paths used as pseudo-preference stores

| Path | Role |
|---|---|
| `/var/mobile/Library/Preferences/com.opa334.craneprefs.plist` | global switches (rootful) |
| `/var/jb/var/mobile/Library/Preferences/com.opa334.craneprefs.plist` | same, rootless path granted in `libCrane.plist` |
| `/var/mobile/Library/Preferences/Slices/%@` and `/%@` | imported *slices* become containers (`checkForSlices`) |
| `/var/mobile/Library/Preferences/com.opa334.craneliteprefs.plist` | Crane Lite import source |
| `/var/mobile/Library/Crane` | Crane's own data dir (badge store at `/var/mobile/Library/Crane/BadgeStore.plist`, backup temp) |
| `%@/Library/___Crane_Containers/%@` | container root |
| `%@.c_r_a_n_e.%@.plist` | per-container notification-topic plist inside apsd's storage |
| `/Library/Application Support/Crane.bundle` | UI bundle + `Icons/` |
| `/Library/PreferenceBundles/ChoicyPrefs.bundle`, `/usr/lib/ChoicyLoader.dylib` | Choicy integration targets |
| `/usr/local/bin/cranehelperd_start`, `/usr/local/libexec/cranehelperd` | daemon and restarter |
| `/usr/lib/TweakInject.dylib`, `/usr/lib/substrate/SubstrateInserter.dylib`, `/usr/lib/substitute-inserter.dylib` | injection-inserter probing used by `getInjectionPlatform` and the dylib-loaded checks |

## 4. Launch-environment contract (CONFIRMED_STATIC, the key cross-process interface)

`crane_applyEnvironmentChanges` (CraneSB 0x1B45C) writes into the launch
environment dictionary that SpringBoard passes to the app:

| Variable | Condition | Value |
|---|---|---|
| `CRANE_CONTAINER_IDENTIFIER` | active container ≠ `DEFAULT` **and** Crane's self-check (`verifyCraneInsuranceAndReply:` on the cranehelperd XPC) reported broken daemons | the active container ID |
| `CRANE_PROTECT_CONTAINERS` | active container **is** `DEFAULT` **and** `applicationSettings["containerProtectionEnabled"]` is truthy | `"1"` |
| `CRANE_SPOOF_SANDBOX_LOOKUPS` | active container ≠ `DEFAULT`, self-check OK, **and** `spoofSandboxLookupsEnabled` truthy | `"1"` |
| `CFFIXED_USER_HOME`, `HOME`, `TMPDIR` | set **by ` Crane.dylib` itself** after consuming `CRANE_CONTAINER_IDENTIFIER` | container path / path / path+`/tmp` |

Also in that function, before the environment is built:
if `gameCenterSupportEnabled` then
`[CraneManager gameCenter_setActiveAccount:associatedGameCenterAccount andDontKillApplication:appID]`.

Error paths: `libSandy_works() == false` → `crane_presentLibSandyNotWorkingError()`
and the environment is returned **unmodified**; self-check failure →
`crane_presentDaemonError(…)` and the environment is returned **unmodified**.
Both are user-visible errors, so failing open here is deliberate.

`CraneApplication`'s localized strings show the other side of this contract:
`CRANE_DYLIB_NOT_LOADED_ERROR`, `CRANE_DISABLED_MESSAGE`,
`CRANEHELPERD_COMMUNICATION_WARNING`.

## 5. Localization keys used as UI labels

`localize(key)` in all four dylibs first resolves
`/Library/Application Support/Crane.bundle` through the shared libroot
`jbrootpath` shim, then falls back to that bundle's
`en.lproj/Localizable.strings`.
204 keys exist. The ones that are behaviour-bearing (i.e. their presence/absence
changes what the user can do) are listed in `ui_specification.md`.