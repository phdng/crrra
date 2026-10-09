# Known Differences

Every item below is a real, deliberate gap. Nothing here is presented as
equivalent. Each is labelled with the evidence status of the claim on the other
side, and the analysis files that establish it.

## 1. Scope-level differences

### D-01 — Six of eleven binaries had no IDA export, so they could not be transcribed

**Original:** `usr/lib/libcrane.dylib` (339 KB, the container registry and XPC
client), `usr/local/libexec/cranehelperd` (118 KB), `usr/local/bin/cranehelperd_start`,
`CraneApplication_Legacy.app`, both `CraneShortcuts.appex` binaries.

**Reconstruction:** `CraneManager` exists with every recovered selector, and
`cranehelperd` registers both Mach services with the recovered class names, but
their behaviour is reconstructed from call sites, not transcribed.

**Consequence:** the container registry's on-disk format, the identifier
generation scheme, the archive format and the XPC protocol differ from the
original. **Containers written by one build are not guaranteed to be readable by
the other.**

Evidence: `analysis/environment_report.md` §5; U-01, U-04, U-06, U-08.

### D-02 — The cranehelperd XPC protocol is this project's own

**Original:** the protocol vended by `CRHGlobalService` is unknown (U-01).
**Reconstruction:** `CRHelperServiceProtocol` in `sources/common/CRManager.h`.

Method names were chosen to match what the exported binaries actually call, so
call sites line up, but argument encodings and reply-block shapes were chosen by
this project. The original daemon will reject these messages.

**Test impact:** `T-F19-1`, `T-F19-2` cannot pass against the original daemon.

### D-03 — Read subsystems were indexed, not all read line by line

The initial pass transcribed 17 recovered functions. Subsequent fidelity passes
also transcribed the main-dylib hook-table details, libroot path shim behaviour
and the core `CraneActivatorManager` listener/event flow. Most of the 2651
exported functions still remain at selector/call-graph/string-constant coverage
rather than full control-flow transcription.

**Consequence:** F-08, F-11, F-14, F-15 (partially),
F-16 (partially), F-19, F-20, F-21 remain declarations/dispatch or incomplete
implementations. F-09 now has its recovered accountsd/Core Data hook chain
transcribed but still depends on U-01/U-06 runtime plumbing. F-05 now has its recovered cfprefsd hook/ABI chain transcribed
but still depends on U-01 PID transport. F-06 now has its recovered containermanagerd hook/cache/proxy
chain transcribed but still depends on missing libcrane/helperd transport. F-12
now has its recovered pkd/PlugInKit server-side hook chain
transcribed, but still depends on the SpringBoard notification-support query-tag
path for the container-specific notification-extension case. See
`reconstruction/IMPLEMENTATION_STATUS.md` §2.

## 2. Behavioural differences in what *is* implemented

### D-04 — SpringBoard's launch APIs are not hooked

**Original:** `CraneSB` hooks `FBProcessManager`
`_bootstrapProcessWithExecutionContext:synchronously:error:`,
`_createProcessWithExecutionContext:`,
`createApplicationProcessForBundleID:withExecutionContext:` and
`SBIconController` `_launchFromIconView:`(+ two variants), then injects the
environment through `crane_applyModificationsIfNeededToExecutionContext:`.

**Reconstruction:** those `MSHookMessageEx` calls are **not** present.
`CRApplyEnvironmentChanges` is implemented and its contract is transcribed, but
nothing calls it, because the shape of `FBProcessExecutionContext` is a private
SpringBoard API that could not be recovered.

**Consequence:** F-01 does not work end-to-end. The function that decides what
the environment should be is correct; the plumbing that delivers it is absent.
This is the single largest functional gap.

### D-05 — cfprefsd hook chain is reconstructed; PID transport remains incomplete

**Original:** `initCfprefsd` captures the client host bundle identifier and PID,
uses `ClientContainerCache` to resolve a non-default active container, and hooks
CoreFoundation's source/path resolution. Explicit-container paths are moved under
the Crane container. Path-less domains temporarily carry the active container in
the current thread dictionary so `__CFPrefsGetPathForTriplet` can rewrite the
plist basename to `<domain>.c_r_a_n_e.<container>.plist`. CoreFoundation 1740–1999
uses Objective-C hooks with a `libundirect` fallback; CoreFoundation 2000+ hooks
the recovered shared-cache symbols directly.

**Reconstruction:** `CRCfprefs.m` now transcribes that request capture, both
`withSourceForDomain` ABI families, the version/libundirect selection logic and
the 0x400-byte triplet-path rewrite. Private XPC PID lookup is runtime-resolved
to avoid Xcode's unavailable declaration.

**Remaining difference:** `ClientContainerCache` still receives `DEFAULT` from
the reconstructed helperd/libcrane PID→container transport (U-01), so the hooks
cannot yet be claimed behaviorally effective end-to-end. Runtime/device testing
has not been performed.

### D-06 — Keychain isolation is entirely absent

**Original:** `initSecurityd` hooks `SecItemAdd` / `SecItemCopyMatching` /
`SecItemDelete` / `SecItemUpdate` with `_orig` storage, rewrites keychain access
groups per container, and **patches securityd's own code signature** using an
embedded ~180-function toolkit (`csd_*`, `macho_*`, `fat_*`, `memory_stream_*`,
`pfsec_*` arm64 pattern scanner, `arm64_gen_*`/`arm64_dec_*`).

**Reconstruction:** `initSecurityd()` exists and does nothing.

**Consequence:** every container shares one keychain. This is a data-integrity
difference, not just a missing feature: an app that writes credentials in
container A will find them in container B.

**Why it was not stubbed differently:** a partial implementation that rewrites
some access groups would break credentials *without* isolating them, which is
strictly worse than not touching the keychain at all.

### D-07 — Notification redirection is absent

**Original:** 8 `APSCourierConnection` hooks in `CraneSupport` plus 40 in
`CraneSB`'s `initNotificationSupport`, gated by `notificationsSupportEnabled`
and `separateNotificationRegistrationsEnabled`, with per-container topic
rewriting to `<topic>.c_r_a_n_e.<identifier>.plist`.

**Reconstruction:** both `initApsd()` and `initNotificationSupport()` are absent
or no-ops.

**Consequence:** all containers share one APNs token, so a push notification
wakes the container the user is not currently in. `showContainerInNotificationTitleEnabled`
and `showContainerNotificationBadgesEnabled` have no effect.

**Compounding uncertainty:** even with the hook bodies read, the target class of
each of the 40 `CraneSB` hooks is aliased in the decompilation (U-10), so they
cannot be attributed to classes without inventing them.

### D-08 — No container-selection UI

**Original:** 16 `SBUIActionView` hooks, 1
`SBUIAppIconForceTouchControllerDataProvider` hook, 2 `UIMenu` initialiser
variants, the `com.opa334.crane.*` menu identifier family, and
`CRBadgeAction`/`CRSubtitleMenu`.

**Reconstruction:** none of it. The UIMenu identifier constants are defined in
`CRPaths.h` but nothing creates a menu.

**Consequence:** long-pressing an app icon shows no container list. Container
selection is only reachable through the settings UI's Active Container sheet.

**Why:** the row arrangement (order, subtitle text, checkmark placement,
separators) is U-05 — it is only knowable from the `_configureCell:forElement:`
hook bodies or from a screenshot, and neither was available. Guessing a layout
would have produced something that *looks* right and cannot be checked.

### D-09 — Choicy integration is structural only

`CraneChoicyOverwriteProvider` is declared and its six selector names are
correct, but Choicy's own provider protocol header is not in this tree, so the
conformance relationship cannot be established. The `libSandy`/Choicy
integration also runs only in the older-CF branch of `crane_initSpringBoard`,
reproducing the original's (unexplained) branch inversion (U-07).

### D-10 — The backup/restore engine is absent

**Original:** embedded `SSZipArchive` + MiniZip in `CranePrefs`, 41-method
`CRPBackupOperation`, 42-method `CRPNewBackupListController`, 43-method
`CRPRestoreOperation`, a `CRPKeychainManager` category, and daemon-side keychain
dump/restore.

**Reconstruction:** `CRPCreditsController` and the credits panes are referenced
but no backup engine exists.

**Consequence:** `CREATE_MULTI_CONTAINER_BACKUP` and
`RESTORE_MULTI_CONTAINER_BACKUP` in `Root.plist` reference actions that do
nothing. The specifier cells themselves are present and correctly labelled.

### D-11 — The two app bundles and the Shortcuts extensions are not reproduced

Both `CraneApplication` builds and both `CraneShortcuts.appex` binaries have no
source available (`CraneIntentHandlerShared` bodies are U-08), and the Swift/App-
Intents layer cannot be reconstructed from 53 exported functions. No app is
built by this project.

**Consequence:** F-22 is not implemented. The `NSUserActivityTypes` and
`SBAppTags` metadata is documented in `analysis/behavior_specification.md` §23
but no binary carries it.

**Related (U-19, BLOCKED):** the original ships *two* app bundles sharing the
identifier `com.opa334.CraneApplication` and must have a `postinst` selecting
between them by `MinimumOSVersion`. That script is not in the tree and no
`dpkg-deb`/`ar` is available here, so the mechanism is unknown. This
reconstruction ships no app, which sidesteps the collision entirely.

## 3. Configurations and dependencies

### D-12 — `prefer_opaque` / `LSRequiresIPhoneOS` and code signing are not reproduced

The original's binaries are re-signed by the packaging tool (no entitlements
blob anywhere). This project does not attempt to reproduce signature bytes; a
rebuild will produce different ones (U-20).

### D-13 — Substrate `Flags` semantics are carried over verbatim, not interpreted

`CraneSupport.plist` has `Flags = 1`. Whatever that means for a given Substrate
version is copied unchanged rather than re-derived (U-18).

### D-14 — Dependency list is this project's best reading, not a recovered `Depends` line

No `DEBIAN/control` exists in the tree. The reconstructed `control` lists
`mobilesubstrate, ellekit, libhooker, firmware, altlist, activator, choicy`,
derived from the `LC_LOAD_DYLIB` set plus the runtime-probed optional tweaks.
`activator` and `choicy` are probed with `dlopen` in the original, so making them
hard dependencies is a deliberate simplification — the original treats them as
optional and degrades gracefully.

## 4. Configuration semantics

### D-15 — Preference storage is `NSUserDefaults`, not the original's mechanism

`CraneManager.preferenceValueForKey:` is transcribed, but the original's backing
store is inside `libcrane.dylib` and unknown. This build uses
`NSUserDefaults.standardUserDefaults` for the `com.opa334.craneprefs` domain.
A `CFPreferences` daemon or a domain-specific suite would be observationally
equivalent for reads inside Crane's own processes but would differ if another
tweak read the same domain.

### D-16 — Per-application settings live in memory, not in a persisted registry

`setApplicationSettings:forApplicationWithIdentifier:` writes to an in-memory
dictionary. The original persists across process restarts through a store inside
`libcrane.dylib`. **Consequence:** container settings do not survive a reboot in
this build.

### D-17 — Defaults for unset per-app keys

`boolValue` on `nil` yields `NO`, matching the original's behaviour for the keys
with no explicit `default`. The one exception,
`separateNotificationRegistrationsEnabled`, carries `default = 1` on its
specifier (recovered from `CranePrefs` 0x8D00) and is reproduced. U-17 records
that this has not been confirmed against `readPreferenceValue:`.

## 5. UI

### D-18 — Settings pane implemented for 2 of 3 recovered controllers

`CRPRootListController`, `CRPApplicationConfigurationListController` (43 methods
in the original, ~15 reproduced) and `CRPActiveContainerListItemsController` are
implemented. `CRPContainerConfigurationListController` (60 methods — the largest
class in `CranePrefs`, holding per-container device-identifier, Game Center,
notification and keychain rows), the 12 backup/restore controllers, the 9
`CRPCredits*` classes and the 6 custom cells are not.

`Root.plist` still references them, so the settings UI will reference classes
that do not exist in the rebuilt bundle.

### D-19 — Alert UI is not built

`CRErrorAlert` and `CRNewContainerAlert` are `SBAlertItem` subclasses created at
runtime with `errorTitle` / `errorMessage` / `actions` /
`crane_reappearsAfterUnlock` / `applicationID`. Their property sets and hook
registrations are recovered; the presentation bodies are not implemented. The
error *paths* exist (F-01 logs rather than alerts) but nothing is shown to the
user.

### D-20 — No visual comparison was performed

No screenshots of the original exist in the repository and no device is
available, so `tests/ui_comparison.md` records metrics as NOT_TESTED. The only
UI facts recovered are the icon set (8 PNGs, byte-identical, and used verbatim),
the localization tables (204 keys), and the specifier order from `Root.plist`.

## 6. Lifecycle and timing

### D-21 — `dispatch_once` behaviour for the `Apps Shortcuts Enabled` block

`crane_initSpringBoard` guards `dispatch_once(&qword_2D400, &stru_289E8)` behind
`applicationShortcutsEnabled() && qword_2D400 != -1`. The initial value of
`qword_2D400` and the block body were not recovered. Not reproduced.

### D-22 — `InitFunc_0`/`InitFunc_1` module-constructor ordering

The three `__mod_init_func` constructors of `CraneSB` (0x9684, 0x9E08, 0x1BC70)
run in address order, i.e. `CRErrorAlert` and `CRNewContainerAlert` are created
before `crane_initSpringBoard`. The reconstruction has one constructor, so any
hook that depended on those alert classes already existing is not reproduced.

### D-23 — Activator core and icon ABI are reconstructed; observer refresh remains partial

**Original:** `CraneActivatorManager` dynamically loads Activator, registers one
set-active listener and one changed-container event per app/container pair,
handles receive/abort by switching/restoring the active container, and supplies
localized metadata plus app icons generated through the private SpringBoard
`generateIconImageWithInfo:` ABI.

**Reconstruction:** dynamic loading, listener/event registration, naming/parsing,
switch/abort behaviour, metadata and app-icon generation are transcribed from
the recovered methods. Machine-code inspection of both arm64 slices confirms
`generateIconImageWithInfo:` receives a four-double homogeneous aggregate
`{29, 29, scale, 5}` in `d0..d3`; that exact ABI is now used. `CraneManager`
observer membership is implemented, but the original manager's notification-
dispatch body is unavailable, so cache refresh after an in-process container-
list change is not claimed equivalent. Activator absence still degrades to a
no-op as in the original.

**Test impact:** F-23 is source-implemented only and remains runtime NOT_TESTED.

### D-24 — PlugInKit isolation is server-side complete but notification query tagging is still coupled to F-08

**Original:** `initPkd` stores `crane_activeContainerID` on each `PKDPlugIn`,
consumes a private `crane_containerID` rule from Transaction XPC requests,
propagates it through all `PKDatabase` query variants, terminates stale plug-ins
when their active container changes, and injects `CRANE_CONTAINER_IDENTIFIER`
into extension launch environments. SpringBoard's notification-support hooks
supply that private rule via thread-local `extension_containerIDToAppend`.

**Reconstruction:** the recovered pkd/PlugInKit server-side chain is transcribed
in `CRPkd.m`, including the four enable variants, query wrappers, termination,
reload notification and older-PKD server capture. The SpringBoard-side tagging
hooks live inside the still-unported notification-support group whose target
classes are U-10, so container-specific notification-service extension queries
are not yet end-to-end equivalent.

### D-25 — Container-manager hooks are transcribed; PID transport remains reconstruction-limited

**Original:** `CraneSupport` carries a shared `ClientContainerCache` keyed by PID,
cleared on `com.opa334.cranesb/Loaded`. `initContainermanagerd` selects among
modern `MCMContainerFactory`, legacy `MCMClientConnection`, and older group-path
APIs, rewriting root/data paths into the active Crane container. On newer Core
Foundation versions, `initCraneProxy` wraps containermanagerd XPC and accepts
`crane_isProxyMessage` requests only from six signing-identifier allowlisted
CraneSupport daemons.

**Reconstruction:** those hook bodies, cache queue semantics, PID-capture hook,
metadata/path copying, corrupt suppression, group rewrite and guarded modern
proxy are transcribed in `CRMCM.m` without private MobileContainerManager
headers. Audit-token/SecTask SPI is resolved dynamically and fails closed if it
is unavailable.

**Remaining difference:** the original cache obtains a PID's active container
through libcrane's synchronous cranehelperd proxy, with an error-specific direct
containermanagerd fallback. The reconstructed `CraneManager`/helperd transport
is still U-01 and currently answers `DEFAULT`, and libcrane's private
`_populateContainerDirectory:ofType:` body is unavailable. The hook chain is
therefore source-complete at the recovered CraneSupport layer but not claimed
end-to-end behaviourally equivalent.

### D-26 — System-account database redirection is transcribed; client/container plumbing remains partial

**Original:** `initAccountsd` adds active-container state to `ACDAccountStore` and
selects a target container from the AccountsDaemon client. App Store family
clients map to `com.apple.AppStore`, `itunescloudd` maps to `com.apple.Music`,
normal clients use `ClientContainerCache(pid)`, and `gamed` uses Crane's Game
Center state. On newer systems each normalized container gets its own Core Data
`NSPersistentStoreCoordinator` and `Crane/<container>.sqlite`; older systems
cache an `ACDDatabase` per container and reset AccountsDaemon's global shared-
coordinator once-token between store paths. The tweak also suppresses the Start
Using iCloud follow-up while a redirected account store is active.

**Reconstruction:** `CRAccountsd.m` transcribes those two OS generations, the
associated-object properties/cache maps, client routing, Core Data store setup,
legacy shared-coordinator reset/cache, and both iCloud follow-up suppression
variants without hard-linking AccountsDaemon private headers.

**Remaining difference:** ordinary PID-based routing still depends on U-01
because reconstructed `ClientContainerCache` receives `DEFAULT` from the missing
helperd/libcrane transport. The `gamed` branch additionally depends on the
original Game Center storage model (U-06); it therefore fails closed when the
reconstructed manager does not expose `gameCenter_enabledApplicationIdentifiers`.
No device/runtime account-switch test has been performed.

## 7. Untested edge cases

No runtime testing was possible, so these are untested rather than known-good:

- Rapid enable/disable of a container switch
- Process restart with an active non-default container
- Device lock/unlock with a `crane_reappearsAfterUnlock` alert
- Safe mode (`_MSSafeMode=1`/`_SafeMode=1` are set for the daemon, and the main
  dylib's `Flags = 0`)
- Rootless vs rootful path resolution in practice (U-12 resolved statically, not
  exercised)
- Hook conflicts with other container-manipulation tweaks
- Behaviour on iOS versions where `kCFCoreFoundationVersionNumber` crosses the
  1665.15 and 1932.101 thresholds
- Whether deleting the **active** container is blocked (U-09)

## 8. Unsupported environments

| Environment | Status |
|---|---|
| iOS 12–13 | No app bundle shipped (D-11); tweak dylibs declare iOS 11.0 and should load |
| iOS 14–17 | Same |
| iOS 18+ | Same |
| Non-jailbroken | Out of scope — the package is jailbreak-only (`SEROTONIN_ROOTHIDE_INCOMPATIBILITY_MESSAGE`) |
| Rootless jailbreaks | Path handling implemented via libroot (U-12, CONFIRMED_STATIC), never exercised |
| Rootful jailbreaks | Implemented; never exercised |
| Original `cranehelperd` (from the original package) | **Incompatible** with this build's XPC protocol (D-02) |
| Containers written by Crane 6.0 | **Not readable** (D-01) |

## 9. Summary

| Category | Count |
|---|---:|
| Whole subsystems absent (F-07, F-08, F-13, F-17, F-22, F-14) | 6 |
| Partially implemented | 12 |
| Fully implemented | 5 (F-02, F-03, F-04, F-18, and F-01's contract) |
| Whole binaries not reconstructed | 6 of 11 |
| Function coverage | Initial 17-function core plus later main-dylib/libroot/Activator, cfprefsd, accountsd/Core Data, containermanagerd/cache/proxy and pkd/PlugInKit transcriptions; no inflated single 1:1 count is claimed |
| Runtime tests executed | 0 |
| Visual comparisons performed | 0 |

**This reconstruction is not a behavioural equivalent of Crane 6.0.** It is a
transcription of the fully-recovered core plus a faithful packaging and
configuration layer, with every remaining gap named above rather than filled
with plausible-looking code.