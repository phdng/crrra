# Original Crane vs Reconstruction — Functional Gap & Implementation Plan

**Audit date:** 2026-10-14  
**Baseline:** original package/binary evidence under `Library/`, `Applications/`, `usr/`, and generated indexes under `analysis/`.  
**Current implementation:** `reconstruction/` on branch `chore/reconstruction-build-ci`, HEAD `f4ccd98` plus the current uncommitted post-debug cleanup.

## 1. How to read this audit

This audit deliberately separates four states:

| State | Meaning |
|---|---|
| **MISSING** | Original behavior/API exists, but there is no functional backend in the reconstruction. |
| **PARTIAL** | A meaningful portion exists, but one or more original behaviors are absent. |
| **ADAPTER** | The reconstruction works through a project-specific mechanism because the original implementation/protocol is unavailable. It is not binary/behavioral parity. |
| **VERIFY** | Source coverage is already substantial; the remaining gap is primarily native/device differential verification. |

The global CraneSupport injection problem is **closed**: the 2026-10-14 10:20 device pass ended helper fix-up with `success=1/errorCode=0` and insurance with `works=1`, empty `broken`. It is no longer listed as an implementation blocker.

## 2. Executive result

The reconstruction has the central container launch path, app-side redirection, cfprefsd/MCM/accountsd/apsd/pkd/lsd hook cores, container menu, biometric gate, Choicy provider, Activator core and most self-verification plumbing.

The largest remaining gaps are not in basic injection. They are:

1. **privileged cranehelperd operations and original service semantics;**
2. **the original CraneManager registry/storage model and exact lifecycle semantics;**
3. **keychain service/migration and full device-identifier write-through;**
4. **Game Center;**
5. **backup/restore;**
6. **the missing CraneApplication + Shortcuts extension;**
7. **remaining notification/badge fidelity and Settings controllers.**

### Registry safety follow-up (2026-10-14)

- Collision checks now enumerate persisted `appSettings_*` keys directly, in addition to supported-app and legacy candidates. They no longer depend on helper discovery for an app whose settings outlive installation.
- The collision probe reads native/legacy settings without invoking copy-forward migration for unrelated applications. Corrupt preference records fail closed before destructive container operations.
- Source contract tests for lifecycle and daemon responsibilities were aligned with recovered original selectors. These are **static invariants**, not proof of an iOS build or on-device behavior.

### Game Center account schema follow-up (2026-10-14)

- Original CranePrefs 0x15448 constructs `{name, identifier}` dictionaries; 0x14D00/0x14D8C loads/saves their array through `gameCenter_availableAccounts` / `gameCenter_setAvailableAccounts:`. The per-container picker at 0x1312C/0x13310 reads the two fields separately and adds `DEFAULT` as a UI-only choice.
- Previous manager code stored `NSArray<NSString *>` and tested `containsObject:account`, which rejected valid original-format identifiers. It now reads validated dictionaries without mutating malformed persisted settings, rejects malformed/duplicate entries on writes, and checks account membership by `identifier` (including `DEFAULT`).
- The shared pure-Foundation header is exercised by the existing macOS container smoke test; CI enforces original fixture/schema contracts. **This does not implement gamed switching or account database deletion.**

## 3. Gap list and implementation plan

| Gap | Priority | Original evidence | Current state | Missing behavior | Proposed implementation |
|---|---|---|---|---|---|
| **G-01 — cranehelperd privileged service parity** | **P0** | Original `CRHGlobalService` has 15 recovered methods; `CRHPreferencesService` has 3; `CRHServiceShared` contains process/ping/inject/wait/kill helpers. See `analysis/objc_classes.json`. | **PARTIAL / ADAPTER, materially advanced.** Authenticated raw-XPC now covers health/fix-up/PID verification, app/daemon reload, application queries, keychain move/delete and vendor-ID bridging. `CRHPreferencesService` now exposes the exact original 3-selector surface instead of the reconstruction-only generic preference writer; dump/restore/migrate remain fail-closed. | Preferences-service keychain dump/restore/migrate serialization; original on-demand daemon activation/compatibility details; device verification of the newly recovered fixed-purpose operations. | Keep peer-authenticated raw-XPC as the transport, but add **fixed-purpose operations matching each recovered original selector’s semantics**. Implement one operation at a time with peer allowlists and no caller-supplied arbitrary process/path privileges. Add ObjC proxy methods only as adapters over those operations. |
| **G-02 — original CraneManager registry/storage model** | **P0** | Per-app/per-container schema is recoverable from CranePrefs, but `libcrane.dylib` has no IDA export. Original callers use `applicationSettingsForApplicationWithIdentifier:` / `setApplicationSettings:...`. | **PARTIAL / NATIVE-SCHEMA ADAPTER.** Primary storage now uses recovered `appSettings_<bundleID>` keys in the Crane prefs domain with DEFAULT projection. The old `com.opa334.cranereconstruction.apps` map is read only as a copy-forward migration source; duplicate-container checks now consult native per-app settings. | Exact remaining metadata persistence and observer/cache semantics; device proof that copy-forward migration matches existing installs. | First recover every schema key/default from CranePrefs call sites. On device, inspect original preference/data files **read-only** if available. Introduce a versioned storage adapter that can read current reconstruction data and the recovered original format. Migrate by copy/transaction, never destructive in-place conversion. |
| **G-03 — actual application reload, daemon reload, on-demand daemon activation** | **P0** | Original helper: `reloadApplication:`, `reloadDaemons:`; `CRHServiceShared`: `_serviceNameForDaemon:`, `_pingDaemon:`, `_execute:whileDaemonWithNameIsRunning:`, `_killallProcessesWithName:`. CraneSB 0x1A53C calls `reloadDaemons:`. | **IMPLEMENTED ADAPTER / DEVICE-UNVERIFIED.** Fixed-purpose authenticated helper operations now perform recovered app reload and hard-coded daemon reload semantics, and manager reload groups route through them. | Exact original on-demand daemon activation/ping semantics and device differential verification. | Recover launchd service-name table from helper strings/metadata. Implement fixed app terminate/relaunch using the same platform service family used by original call sites where recoverable; implement daemon kickstart/kill only for a hard-coded recovered daemon set. Add the original activation ping before insurance verification. |
| **G-04 — keychain service, migration and backup plumbing** | **P0** | Original helper GlobalService exposes keychain move/delete; PreferencesService exposes dump/restore/migrate. CranePrefs exports `+[CRPKeychainManager migrateFromVersion1IfNeeded]` 0x16920 and `handleMigrationWithViewController:` 0x16B38. | **PARTIAL.** Normal-symbol securityd isolation hooks exist. Original `CRHKeychain` access-group derivation plus move/delete loops are transcribed and exposed through authenticated helper operations; original delete-content lifecycle now invokes keychain deletion and associated cleanup. Preferences dump/restore/migrate selectors are exact but fail-closed, and manager migration no longer fakes success by rewriting app settings. | Exact dump serialization, restore, v1 migration transaction/rollback and Preferences migration UX; device-test F-07 and move/delete. | **First device-test F-07 normal securityd hooks**. Then transcribe `CRPKeychainManager` migration functions and recover the exact helper request dictionaries from CranePrefs decompiles. Implement authenticated helper keychain operations through securityd APIs, explicitly excluding SEP/non-exportable items as original UI warns. Add transactional migration with rollback markers. |
| **G-05 — securityd patchfinder fallback (0x11C08)** | **P1 conditional** | Original resolves five private securityd functions normally, then falls back to `patchfindSecurityd` 0x11C08. | **MISSING**, but normal symbol-visible path is ported atomically. | Support for OS builds where one or more private symbols are hidden. | Do **not** port blindly. First collect device log `securityd keychain isolation hooks=5 status=0` vs `missing_private_symbols`. Only if needed, transcribe 0x11C08 and its Mach-O/code-signature helper chain, with per-build signatures and fail-closed behavior. |
| **G-06 — complete per-container device identifier** | **P0/P1** | CraneSupport `initLsd` 0xD7D8 and helper metadata show device-vendor-ID read/write operations. Original semantics include writing DEFAULT/system cache and preserving visible ID across container/default changes. | **PARTIAL / BACKEND IMPLEMENTED.** LSD protocol/hooks and authenticated helper read/write bridge are transcribed; manager device-ID contract is wired. | Device proof of system vendor-ID read/write; DEFAULT persistence after Crane unload; exact automatic adjustment when making/changing default container. | Add helper operations matching original `readDeviceVendorIdentifierFromApplicationWithIdentifier:reply:` and `writeDeviceVendorIdentifier:toApplicationWithIdentifier:`. Route them only to authenticated LSD-side methods. Then implement the make-default ID swap transaction and test DEFAULT/non-default round trips. |
| **G-07 — Game Center account separation** | **P1** | Original launch calls `gameCenter_setActiveAccount:andDontKillApplication:`. CranePrefs 0x15448, 0x14D00/0x14D8C and 0x1312C/0x13310 show an array of `{identifier,name}` dictionaries. Accounts-side hooks include the Game Center special case. | **PARTIAL: account schema corrected, runtime core missing.** Manager validates and persists native account dictionaries, exposes identifier-based availability checks and treats DEFAULT as the system account. The `gameCenter_setActiveAccount*`, `gameCenter_activeAccount`, and `gameCenter_reloadExceptApplicationWithIdentifier:` methods still have no runtime implementation; UI account controller is absent. | Original active account switching, gamed/accountsd reload behavior, account discovery/rename/delete UI, per-container associated account UI. | Continue transcribing the controller 0x14DF4..0x167D0 and original manager/global account preference semantics; only then add state transitions and service reload. Keep destructive account removal and database writes disabled until verified. |
| **G-08 — exact container lifecycle and import semantics** | **P0/P1** | F-16 selectors plus CranePrefs `CRPContainerManager`, unknown-container checks, Slices and Crane Lite migration functions. | **PARTIAL, DELETE PATH DIRECTLY RECOVERED.** Create/move/copy/size/unknown scan exist with safety guards. `deleteContentOfContainer...` now follows the original libcrane cleanup order (reload-if-active, all associated paths, keychain, accounts DB, notifications/badge, container prefs, daemon handling) and no longer mutates the registry itself. `wipe...` is still inferred and `makeDefault...` currently only sets active. | Exact wipe preservation semantics, make-default semantics, metadata/attribute handling, Slices import, Crane Lite import, exact unknown-container adoption behavior. | Transcribe CranePrefs lifecycle functions (`removeContainer...`, `checkForUnknownContainers`, `CRPContainerManager`, `CRPPreferenceMigrator`) before changing disk semantics. Add differential filesystem tests on disposable test apps. Never infer destructive behavior from selector names. |
| **G-09 — notification/APNs/badge exactness** | **P1** | CraneSB has 113 hook registrations / 108 unique selectors; CraneSupport has 45 registrations. `initNotificationSupport` 0xCBEC is large; original private badge view uses `updateConstraints`, `layoutSubviews`, `badgeView`, `setBadgeView:`. | **PARTIAL.** apsd server path is strongly transcribed; CRBadgeStore contains a large portion of notification routing, pending/removal, badge aggregation and pkd verification. Exact private badge view is replaced by a safer approximation; some asynchronous/live-refresh semantics remain uncertain. | Exhaustive CBEC selector/class parity, asynchronous foreground metadata propagation, exact badge view layout, runtime APNs/pkd notification behavior. | Generate a machine-readable **159-hook coverage matrix**: original registration → current registration → implementation → test. Resolve U-10 class attribution from 0xCBEC, then implement only rows genuinely absent. Device-test token registration, delivery, badge changes and removal across two containers. |
| **G-10 — Settings functional completeness** | **P1/P2** | Original CranePrefs contains **32 CRP classes**. Current source defines 6; **26 CRP classes are absent**. | **PARTIAL.** Main app list, container config, Active Container, browse data, size, device-ID subset, Choicy editor and several switches exist. | Backup/restore UI, Game Center account UI, keychain migration UI, Lite migration, root suggestions, Credits controllers, custom cells, full original list-controller behavior. Root.plist still references actions/classes such as `createMultiBackupTapped`, `restoreMultiBackupTapped`, `CRPCreditsController` that current source does not implement. | Implement by dependency, not class count: (1) migration/keychain controller, (2) Game Center controller, (3) backup controllers, (4) root suggestion provider/Credits/custom-cell fidelity. Add a contract that every Root.plist action/detail class resolves at runtime. |
| **G-11 — backup/restore subsystem** | **P1/P2, large** | Original CranePrefs includes `CRPBackupOperation`, `CRPRestoreOperation`, `CRPBackupRestoreController`, `CRPNewBackupListController`, multi-backup/preset/matching controllers, SSZipArchive/MiniZip. | **MISSING.** | Single and multi-container backup, encryption/password, keychain inclusion, metadata/path restoration, free-space checks, app/group-ID validation, progress UI. | Reverse-engineer format **before writing any archive**. Transcribe `CRPBackupOperation processBackupOfContainer:` and `CRPRestoreOperation restoreBackupContainer:intoContainer:`, derive exact member names/metadata/encryption parameters, then create read-only parser/validator. Only after round-trip fixtures match original should write/restore be enabled. Depends on G-04 and G-08. |
| **G-12 — CraneApplication + Shortcuts/Siri** | **P2** | Original package contains modern `CraneApplication.app` + `CraneShortcuts.appex` with five intents, and a legacy app/extension with Set Active intent. Legacy handler method surface is fully recoverable from ObjC metadata. | **MISSING.** There is no reconstruction app/appex target or `Applications/` payload. | Apps → Crane Shortcuts integration; Create/Next/Set Active/Set Default/Wipe intents; legacy handler; original app shell/assets/package selection. | Start with legacy `SetActiveCraneContainerIntentHandler` because its method surface is known. Build a minimal hidden app + extension using recovered intent definitions/assets. Then implement modern five intents over safe CraneManager methods. Solve modern-vs-legacy package selection explicitly instead of installing two identical bundle IDs. |
| **G-13 — exact original helper/client XPC protocol** | **P2 research** | Original helper class/method encodings are recovered from Mach-O metadata, but `libcrane.dylib` and helper bodies have no IDA export. | **ADAPTER.** Current project protocol is intentionally its own authenticated raw-XPC transport. | Binary compatibility with original helper/client and exact NSXPC interface construction/retry semantics. | If binary compatibility is a goal, separately disassemble original `cranehelperd` + `libcrane.dylib`, recover `NSXPCInterface` construction and allowed classes/reply signatures, then add a compatibility transport. Do not destabilize the working raw-XPC transport while researching this. |
| **G-14 — Choicy / Activator / legacy UI fidelity** | **P2/P3** | Original selectors/classes largely recovered. | **VERIFY / PARTIAL.** Core Choicy provider/editor and Activator listener/event system exist; modern/legacy container menu largely transcribed. | Private API runtime compatibility, remaining observer semantics, visual fidelity, iOS 11/12 runtime coverage. | Native-build + device differential tests first. Only patch code when a concrete selector/behavior mismatch is observed. |
| **G-15 — original packaging details** | **P2** | Original package carries modern and legacy app bundles with same bundle ID; selection mechanism is not in the recovered tree. | **MISSING/UNKNOWN.** | Exact postinst app variant selection and original resign/install behavior. | Recover original `.deb` if possible. Otherwise define an explicit reconstruction packaging policy by target OS and document it as a known difference. |

## 4. Exact cranehelperd surface comparison

### Original `CRHGlobalService`

Recovered methods:

```text
testCallAndReply:
fetchActiveContainerIDForProcessWithPid:reply:
verifyCraneSBLoadedAndReply:
verifyCraneSupportLoadedIntoDaemon:reply:
verifyCraneInsuranceAndReply:
runInjectionFixUpIfNeededAndReply:
reloadDaemons:
reloadApplication:
getDisplayNameOfApplicationWithIdentifier:reply:
getIdentifiersOfAllSupportedApplicationsAndReply:
checkIsApplicationWithIdentifier:supportedByCraneAndReply:
moveKeychainItemsFromContainerWithIdentifier:toContainerWithIdentifier:forApplicationWithIdentifier:reply:
deleteKeychainItemsForContainerWithIdentifier:forApplicationIdentifier:
readDeviceVendorIdentifierFromApplicationWithIdentifier:reply:
writeDeviceVendorIdentifier:toApplicationWithIdentifier:
```

The current reconstruction now has authenticated raw-XPC equivalents for health/insurance/fix-up/PID/component verification, privileged app/daemon reload, application queries, keychain move/delete, and the recovered vendor-ID bridge. Remaining helper work is concentrated in Preferences-service keychain dump/restore/migrate, original on-demand daemon activation details, and native/device verification.

### Original `CRHPreferencesService`

```text
dumpKeychainItemsFromContainerWithIdentifier:forApplicationIdentifier:reply:
restoreKeychainItemsToContainerWithIdentifier:forApplicationIdentifier:fromDictionary:
migrateApplication:withAppSettings:
```

The service surface is now selector-compatible with the original and the reconstruction-only generic preference get/set adapter has been removed. `dump`/`restore`/`migrate` intentionally remain fail-closed until the original keychain serialization and migration transaction are fully transcribed.

## 5. CranePrefs completeness snapshot

Original Mach-O metadata contains **32 classes whose names begin with `CRP`**. The current Preferences source defines 6. The 26 absent CRP classes are:

```text
CRPAlertWithLoadingBarController
CRPBackupContainer
CRPBackupOperation
CRPBackupRestoreController
CRPBackupRestoreProgressAlertController
CRPCellRefreshingListItemsController
CRPContainerManager
CRPCreditsController
CRPCreditsMiniZipController
CRPCreditsZipArchiveController
CRPDestructiveTableCell
CRPGameCenterAccountsController
CRPInfoTableCell
CRPKeychainManager
CRPListController
CRPMultiBackupContainerSelectionCell
CRPMultiBackupContainerSelectionListController
CRPMultiBackupPresetListController
CRPNewBackupListController
CRPNonBlueButtonTableCell
CRPPreferenceMigrator
CRPPresetSelectionCell
CRPRestoreContainerMatchController
CRPRestoreOperation
CRPRightAlignedEditableTableCell
CRPRootPageSuggestionProvider
```

This count should **not** be used as a progress percentage: several are cosmetic/custom-cell classes. The functional priorities inside this list are `CRPKeychainManager`, `CRPPreferenceMigrator`, `CRPGameCenterAccountsController`, `CRPContainerManager`, and the backup/restore controller/operation family.

## 6. Features that are mostly implementation-complete and should be verified rather than rewritten

These areas should not receive speculative rewrites before device evidence shows a mismatch:

| Feature | Current assessment | Next action |
|---|---|---|
| F-01 launch redirection | Core launch/env path implemented; Chrome redirect/Always Ask has device evidence. | Smoke after each foundational change. |
| F-02 in-app environment/directories | Transcribed. | Two-container filesystem differential test. |
| F-03 container protection | Transcribed. | Test DEFAULT vs non-default protection. |
| F-04 sandbox lookup spoofing | Transcribed. | Device test with switch on/off. |
| F-05 cfprefsd isolation | Hook logic transcribed; transport/cache is reconstruction-specific. | Verify two containers receive independent prefs and no sticky DEFAULT cache. |
| F-06 MCM/container resolution | Substantial implementation with cache coherence guards. | Verify app/group paths across live PID proof timing. |
| F-08 apsd half | Substantial CraneSupport implementation. | Focus remaining work on SpringBoard notification matrix/device path. |
| F-09 system accounts | Core accountsd redirect transcribed. | Device-test account DB isolation; do not conflate with Game Center G-07. |
| F-12 PlugInKit | Server-side pkd flow transcribed and pkd verification adapter exists. | Device-test extension discovery/termination. |
| F-13 container menu | Modern/legacy source largely recovered; Always Ask is device-proven on iOS 15.8.8. | Visual/legacy differential testing. |
| F-18 biometrics | Full transcription. | Device test success/unavailable behavior. |
| F-20 injection self-check | Helper fix-up + insurance now device-proven; privileged reload adapter is implemented. | Keep regression smoke; finish Preferences keychain migration under G-04 and device-test reload behavior. |
| F-21 Choicy | Runtime provider + dynamic per-container editor implemented. | Native/device test. |
| F-23 Activator | Core listener/event path implemented. | Device test with and without Activator. |

## 7. Recommended implementation order

### Phase A — foundation and data safety

1. **G-01/G-03:** complete helper privileged fixed-purpose operations and true app/daemon reload.
2. **G-02:** resolve CraneManager registry/storage compatibility enough that later migrations/backups have a stable source of truth.
3. **G-04:** complete keychain service + original Preferences migration.
4. Run full regression: fix-up/insurance, active-container launch, cfprefsd and MCM.

**Exit condition:** no empty privileged backend remains on a path used by Settings or launch; no destructive migration runs without a transaction/rollback marker.

### Phase B — identity and lifecycle

1. **G-06:** full LSD/vendor-ID round trip.
2. **G-08:** exact lifecycle/make-default/delete/import semantics.
3. **G-05:** only if securityd device evidence requires the private-symbol fallback.

**Exit condition:** create/delete/wipe/make-default and device-ID transitions pass two-container device tests without losing DEFAULT data.

### Phase C — service features

1. **G-07:** Game Center core + account UI.
2. **G-09:** finish notification/badge matrix and exact async behavior.
3. Device-test accountsd, pkd, apsd and notification delivery.

### Phase D — Settings completeness and backup

1. **G-10:** functional missing controllers in dependency order.
2. **G-11:** backup format reverse engineering → read-only parser → writer → restore.
3. Add golden fixtures from an original backup before declaring compatibility.

### Phase E — app/automation and polish

1. **G-12:** hidden CraneApplication + legacy Set Active shortcut, then modern five intents.
2. **G-15:** packaging selection policy.
3. **G-14:** Choicy/Activator/legacy visual/runtime differential fixes.
4. Optional exact XPC compatibility research under **G-13**.

## 8. Immediate next coding target

The best next target is **not backup/restore and not patchfindSecurityd**. It is:

> **Recover and implement the missing original helper privileged operation surface, starting with reloadApplication/reloadDaemons and the keychain/device-ID service contracts.**

Reason: Game Center, migration, backup/restore, Settings toggles and device-ID parity all depend on these operations. Implementing higher UI first would create buttons that still terminate in empty/helper-unavailable backends.

After that, the first feature-level device test should be **F-07 securityd keychain isolation** on the already healthy CraneSupport injection path. If all five normal symbols hook successfully, the expensive 0x11C08 patchfinder can remain deferred.
