# Reconstruction Implementation Status

Statuses use the required vocabulary. Note the distinction the prompt draws:
`SOURCE_IMPLEMENTED` says source exists, nothing more.

| Status | Meaning | Applies here? |
|---|---|---|
| SOURCE_IMPLEMENTED | Source changes exist | Yes, for the components listed below |
| CI_BUILD_PASSED | An actual GitHub Actions run succeeded | **No** — no run exists |
| ARTIFACT_INSPECTED | The generated package was inspected | **No** — no artifact exists |
| DEVICE_INSTALL_PASSED | Device installation observed | **No** — no device access |
| INJECTION_VERIFIED | Library loading observed | **No** |
| RUNTIME_TEST_PASSED | Device-side feature test passed | **No** |
| DIFFERENTIAL_TEST_PASSED | Compared against the original at runtime | **No** |

## 1. Component status

| Component | Source | Fidelity | Status |
|---|---|---|---|
| Build system, `control`, install layout, CI workflow | complete | Install paths, filter plists, launchd job, libSandy profiles and settings plists reproduced and **verified byte-semantically identical** to the original | SOURCE_IMPLEMENTED (layout verified; build NOT_TESTED) |
| ` Crane.dylib` (main dylib) | `sources/maindylib/CRMainDylib.m` | **Transcription.** Every function corresponds 1:1 to a recovered export; control flow matches, including the fail-open and unsafe forms | SOURCE_IMPLEMENTED |
| `CRPaths.h` | complete | Every literal is a recovered string constant | SOURCE_IMPLEMENTED |
| `CRPreferences.h` | complete | Key names and defaults from `Root.plist` + the recovered specifier code | SOURCE_IMPLEMENTED |
| `CRCommon.m` | complete | Recovered common helpers plus reconstruction-only persistent runtime attestation (`runtime_report`), with generation-guarded XPC reconnect and report replay after helperd interruption | SOURCE_IMPLEMENTED |
| `libcrane.dylib` / `CraneManager` | partial | **Selector surface CONFIRMED_STATIC; implementation INFERRED**; the reconstruction keeps its own raw-XPC transport because the original helper protocol is still U-01. The low-level proxy now supports versioned `ping`, caller-authenticated `insurance`, `lookup_pid`, and `component_loaded`; PID lookup requires a live main-dylib runtime report and preserves the recovered 0x19608 `(containerID, connectionWorks)` reply ABI. `verifyCraneSBLoadedAndReply:` is wired for the recovered apsd 0x9B68 path. Recovered `runSafeXPCBlock:` and `verifyCraneSupportLoadedIntoDaemon:reply:` selectors now have a **bounded synchronous, authenticated `CraneSupport`/`pkd` runtime-health adapter** used by notification mutation (native 0x11CA4; reconstruction-specific transport, untested on-device). `cranehelperdConnectionWorks` remains a bounded low-level health probe; the original privileged NSXPC selector surface is still not reconstructed | SOURCE_IMPLEMENTED (reconstruction transport; runtime NOT_TESTED) |
| `cranehelperd` | partial | Registration and class names CONFIRMED_STATIC; **XPC protocol is this project's own** | SOURCE_IMPLEMENTED |
| `cranehelperd_start` | partial | Only the path is recovered | SOURCE_IMPLEMENTED |
| `CraneSB.dylib` | partial | Entry dispatch + F-01 environment contract and the core `CraneActivatorManager` listener/event integration are transcribed; menus/notification hooks remain incomplete | SOURCE_IMPLEMENTED (F-01, F-23 core) |
| `CraneSupport.dylib` | partial | Per-daemon dispatch plus recovered cfprefsd, containermanagerd, accountsd, lsd/device-ID and pkd/PlugInKit hook chains are transcribed; APNs/keychain hooks remain incomplete | SOURCE_IMPLEMENTED (dispatch, F-05/F-06/F-09/F-11 hook cores, F-12 server-side core) |
| `CranePrefs` | partial | Root controller + two panes; specifier construction mirrors recovered `0x8D00` | SOURCE_IMPLEMENTED (structure) |

## 2. Feature status against the specification

F-IDs refer to `analysis/behavior_specification.md`.

| ID | Feature | Implemented | Gap |
|---|---|---|---|
| F-01 | Launch redirection | **Yes** — `CRApplyEnvironmentChanges` plus recovered SpringBoard/runningboardd launch hook selectors are transcribed, including both fail-open alert paths | Source path is wired, but no device run has verified that the private launch objects accept the reconstructed hook ABI end-to-end |
| F-02 | In-app env + dirs | **Yes** — full transcription | none |
| F-03 | Container isolation | **Yes** — all four hooks, including the `dlopen`/`dlsym` of `CoreServicesInternal` | `new_unlink`'s missing NULL check is preserved (upstream behaviour) |
| F-04 | Sandbox-lookup spoofing | **Yes** — full transcription | none |
| F-05 | Per-container preferences | Partial — `handleSourceMessage`, both `withSourceForDomain` ABI families, `__CFPrefsGetPathForTriplet`, version guards and libundirect fallback are transcribed in `CRCfprefs.m`; reconstruction-specific authenticated PID→container lookup is now wired | The transport is not the unrecovered original U-01 protocol and has no device validation, so end-to-end runtime redirection is still NOT_TESTED |
| F-06 | Container resolution | Partial — `ClientContainerCache`, modern `MCMContainerFactory`, legacy `MCMClientConnection`, group-path rewrite, corrupt suppression, PID capture, guarded Crane proxy, and reconstruction-specific live PID→container lookup are wired | `_populateContainerDirectory:ofType:` body is unavailable; original helper protocol remains U-01; no runtime test |
| F-07 | Per-container keychain | **Not implemented** | Needs the ~180-function code-signature/Mach-O toolkit; a stub would silently weaken isolation |
| F-08 | Per-container APNs | Partial — apsd-side topic/hash translation, `crane_topicStorage`, ApplePushService helper fallbacks, keychain topic lookup, token response restoration and all 10 recovered method hooks are transcribed in `CRApsd.m`; reconstructed `verifyCraneSBLoadedAndReply:` now queries an authenticated live CraneSB runtime report | SpringBoard notification hooks are **partially** reconstructed in `CRBadgeStore.m`, including producer, topic, record and badge paths; a selector-by-selector audit against `CBEC.c` is still needed to isolate the missing asynchronous/live-refresh paths (U-10); the health transport is reconstruction-specific rather than original U-01; no runtime test |
| F-09 | System accounts | Partial — client routing, modern coordinator-per-container, legacy database-per-container, legacy shared-coordinator reset/cache and Start-Using-iCloud suppression are transcribed; reconstruction-specific PID→container lookup is wired | Original helper transport remains U-01; `gamed` path remains limited by unrecovered Game Center account storage (distinct from U-06 backup-format uncertainty); no runtime test |
| F-10 | Game Center | Structure only | Account storage model still unrecovered; do not conflate with U-06 (backup format) |
| F-11 | Device identifier | Partial — LSD protocol extension, type-0 per-container UUID spoofing, helperd-only cache getter/setter, vendor-key derivation and `_LSDeviceIdentifierCache`/persona fallback are transcribed in `CRLsd.m`; reconstructed manager uses the confirmed `customDeviceIdentifier` key and now has a reconstruction-specific live PID→container route | Original PID transport remains U-01; reconstructed helperd still stores identifiers in `NSUserDefaults` instead of invoking the recovered lsd extension; no runtime test |
| F-12 | Plug-in enumeration | Partial — `PKDPlugIn` active-container state, four enable hooks, Transaction rule consumption, PKDatabase query wrappers, plug-in termination and reload handling are transcribed | SpringBoard notification-support hooks that append `extension_containerIDToAppend` as `crane_containerID` are still part of unresolved F-08/U-10; no runtime test |
| F-13 | Container selection UI | Partial — both OS families are transcribed in `CRMenuHooks.m`: the modern UIMenu-era placeholder/replacement path and the CF <1665.15 `SBUIAppIconForceTouch*` / `SBUIActionView` path, including early/late hook phases, parent/expanded container menus, active checkmark/subtitle, Settings/New Container actions, separator rendering, biometric switching and launch-on-selection | F-14 `CRBadgeAction` / per-container notification-badge decoration is deferred; reconstructed manager does not expose the original success-handler BOOL/delay nuance; no runtime/visual test |
| F-14 | Badges | Partial — `CRBadgeAction` metadata/copy-compatible factory from 0x1C064/0x1C188..0x1C1B0, wired into CraneSB and UIKit `initWithAction:` cloning from 0x16820 | Badge label presentation on all three modern cell configuration variants is now implemented without private-class swizzling; this is a visual approximation, not the original `CRBadgeContextMenuActionView` / `SBIconBadgeView` layout. Modern container menu now reads positive counts from the original BadgeStore.plist schema and applies the original global/per-app notification gates; legacy force-touch container items also display the original RTL-aware badge-count subtitle; the recovered persisted store now has a shared in-memory loader, validated getter and atomic count setter (`CRBadgeStore.m`), but listener-side container badge swap/reset selectors from 0x10BEC/0x10CB0 are registered; private repository badge setters 0xFBB4/0xFCA8 and public setter 0xFD9C (XPC PID→container lookup where available, DEFAULT otherwise for a valid caller) now preserve `saveNotification_containerID` routing, persist the per-container count, and forward the aggregated count with the original 0xAA00 positive-sum / negative-only fallback; private setters now remove only the matching container's notification records when a badge is explicitly set to zero (0xBB04/0xBD98/0xBE80), where the repository exposes the recovered removal selector; notification producers, swap/reset now project the aggregate to UISApplicationState or FBSSystemService using original 0xA774 class names, with 0xAA00 app-count aggregation iterating persisted container keys and respecting the validation flag; the 0x10138 `_queue_saveNotificationRecord:withOptions:forBundleIdentifier:` hook now scopes `saveNotification_containerID` from record metadata around the original synchronous save call; additional queue-save variants 0xFF30/0x10050 now also scope the per-container thread context with their original selector signatures; the outer save entrypoint 0xF254 now scopes `saveNotification_containerID` around its synchronous original call; original asynchronous foreground-check propagation and other metadata paths remain pending; remote notification mutation hooks now scope explicit `crane_sourceContainerID` into `extension_containerIDToAppend` around synchronous originals for both selector variants (partial 0xEF84/0xF094/0xB7B8; pkd validation remains device-unverified over the reconstructed authenticated runtime proxy; untagged requests now use DEFAULT only for redirection-enabled apps per 0xBA6C); incoming remote messages now honor explicit per-container `notificationsAllowed = false` and fall back to `DEFAULT` for untagged userInfo (0xEDF4/0xBE18); resolving-set `containsObject:` method now preserves the system runtime type encoding rather than hardcoding BOOL encoding; resolving-set `containsObject:` now copies the original runtime method type encoding rather than hardcoding BOOL encoding; installed-bundle membership is now normalized through a dedicated `CRCraneResolvingSet` subclass installed after `_queue_didCompleteInitialization` where the exact `__NSSetM` runtime class is present (partial 0xDEEC/0xE94C); eligibility queries for user notification enablement and foreground state now normalize Crane topics to original bundle IDs (0xE570/0xE604); eligibility queries for content-available remote notifications and background app refresh now normalize encoded Crane topics to original app bundle IDs (0xE448/0xE4DC); `_queue_allTopicsForApplication:` now appends encoded APNS topics for non-default containers after the original topic collection (0xEBA0); legacy `_queue_appDescriptionForBundleIdentifier:` now decodes encoded Crane APNS topic before original app lookup (0xE698), while 0xDEEC resolving-set class substitution remains pending; notification source-description class method now decodes Crane APNS topics to original bundle IDs before lookup (0xDE54); token request now encodes originating XPC container, scopes `crane_requestOriginContainerID`, and temporarily aliases `_bundleIdentifierToSourceDescription` for the encoded topic where present (0xDA30/0xDF68); token invalidation now encodes the originating XPC container with the exact 0x1FEF0 topic format via guarded listener selector (0xDC5C/0xE194); remote-notification server token callback `_queue_connection:didReceiveToken:forTopic:identifier:` now strips encoded topic and remaps `_bundleIdentifiersNeedingToken` where available (0xE2C4); APSConnection `_deliverMessage:` now decodes the recovered `.c_r_a_n_e.` topic separator using first/last components for repeated separators, tags non-default sources and removes source tagging for DEFAULT (0x10350/0x1FF68/0x1FF7C); `_addNotificationRequests:forBundleIdentifier:withCompletionHandler:`, `_saveNotificationRequest:shouldRepost:forBundleIdentifier:withCompletionHandler:`, and the recovered 0x108F4 `deliveredDate:` save variant now tag request content for a resolved non-default XPC container (0x104AC/0x1072C/0x1235C), startup BadgeStore now prunes stale container keys and removes entries for apps confirmed uninstalled by LSApplicationProxy (partial 0xB00C/0xB688), while preserving data if install state is unavailable; startup now also reads existing icon badge via guarded UISApplicationState/FBSSystemService selectors and reconciles DEFAULT against the saved positive count where the container registry is available (partial 0xA658/0xB00C); startup icon reconciliation now sums filtered valid-container entries and removes DEFAULT for a reconciled zero icon badge; startup additionally drops persisted per-app badge entries when notification redirection is disabled and the container registry is available (partial 0xB00C); live refresh and device verification remain unported F-08 SpringBoard work; no device test |
| F-15 | Settings UI | Partial | Plists reproduced exactly; 2 of 3 panes implemented; backup/restore, Choicy pane and suggestions absent |
| F-16 | Container lifecycle | Partial — CRUD present in `CraneManager`, on-disk layout INFERRED | Layout/identifier format unknown (U-04) |
| F-17 | Backup / restore | **Not implemented** | Archive and encryption format unknown (U-06) |
| F-18 | Biometric gate | **Yes** — full transcription | none |
| F-19 | cranehelperd XPC | Partial — reconstruction-specific raw XPC provides health, audit-token/SecTask-authenticated insurance/component checks, live runtime reports with per-component, peer-token-guarded cleanup (multiple components sharing one PID), and authorized PID→container lookup | Own protocol remains incompatible with the original daemon; privileged original NSXPC operations remain U-01; no device test |
| F-20 | Self-verification | Partial — `CRErrorAlert`/`CRNewContainerAlert`, launch insurance, and the 0x18238/0x194EC/0x19608 post-launch check are wired. The recovered two-argument reply distinguishes missing main dylib from runningboardd/helper failure, and live app reports carry the consumed container ID | Transport is reconstruction-specific rather than the unrecovered original U-01 interface; the original injection-fixup error producer remains unported; no runtime test |
| F-21 | Choicy integration | Partial — rootless-aware load/registration and all 6 provider methods, plus the optional dynamic per-container editor (CranePrefs 0x3F108-0x3F774), scoped read/write, Crane tweak filtering and active-only reload are transcribed; incompatible private APIs retain a read-only preview | Python source/evidence contracts pass; actual-source Objective-C smoke added to CI but not run locally; no native build or real Choicy/device test |
| F-22 | Shortcuts / Siri | **Not implemented** | No source for `CraneIntentHandlerShared` (U-08) |
| F-23 | Activator | Partial — dynamic load, listener/event registration, name parsing, switch/abort callbacks, metadata and app-icon generation are transcribed | `generateIconImageWithInfo:` is now recovered as a four-double HFA from both arm64 slices; remaining gap is the reconstructed `CraneManager` observer-dispatch semantics plus runtime testing |

## 3. Coverage summary

| Measure | Value |
|---|---|
| Features with a complete, transcribed implementation | 5 of 23 (F-02, F-03, F-04, F-18, and F-01's contract) |
| Features partially implemented | 14 |
| Features not implemented | 4 |
| Recovered functions transcribed | Initial 17-function core plus later main-dylib/libroot work, the 42-method `CraneActivatorManager` surface, cfprefsd preferences, accountsd/Core Data isolation, lsd/device-ID isolation, apsd token/topic isolation, Choicy override provider, self-verification/new-container alerts, modern container-selection menus, containermanagerd/cache/proxy, and pkd/PlugInKit chains; no inflated aggregate 1:1 count is claimed |
| Reconstruction source | 9051 lines across 17 `.m` and 4 `.h` files |
| Static consistency audit | 0 failed checks; identifier resolution and brace balance clean |
| Install-path / configuration artefacts verified identical | 12 of 12 plists, 10 of 10 assets |
| Binary architectures validated against the original rule | 11 of 11 |
| Runtime tests executed | **0** |

## 4. Why this ratio is what it is

This is not a build of what was understood and then abandoned. It is the
honest ceiling given the evidence:

- The initial pass transcribed a 17-function core. Incremental fidelity passes
  have since added the recovered main-dylib details, libroot path semantics and
  the 42-method `CraneActivatorManager` surface (with three icon callbacks
  explicitly partial rather than guessed).
- The remaining export set still includes the largest subsystems — the notification hook set,
  the 40 CraneSB hooks, the settings UI, the backup engine — whose *bodies* are
  available but which this pass indexed rather than read line by line.
- The remaining **whole binaries** with no export at all (`libcrane.dylib`,
  `cranehelperd`, both `CraneShortcuts`, the legacy app) account for the
  container registry, the keychain engine and the automation surface.

Writing the unread subsystems from the selector lists alone would produce code
that compiles, links and looks plausible while inventing the behaviour the
prompt explicitly forbids inventing. It would also be unverifiable: with no
device access there is no way to tell a correct reconstruction from a fluent
one. The line drawn here is: **transcribe what was read, declare what was not.**

## 5. What would move each unimplemented feature

| To implement | First step | Uncertainty |
|---|---|---|
| F-05 prefs redirect | Device-validate the reconstruction-specific PID→container transport with cfprefsd and compare against the original once U-01 is recovered | U-01 original protocol / runtime validation |
| F-06 containermanagerd | Device-validate live PID→container routing and recover `_populateContainerDirectory:ofType:` semantics | U-01 / missing libcrane body |
| F-12 PlugInKit | Complete the SpringBoard-side `extension_containerIDToAppend` query-tagging path together with notification support | U-10 / F-08 coupling |
| F-07 keychain | Port or reimplement the embedded `csd_*`/`macho_*`/`pfsec_*` toolkit from the ~180 exported functions | U-03 |
| F-08 notifications | Resolve/port CraneSB `initNotificationSupport` producer/routing/title/badge hooks and device-validate the reconstructed CraneSB-loaded health gate | U-10; U-01 only for original protocol equivalence |
| F-14 menu badges | The store/count display and `CRBadgeAction` are partially wired; port exact `CRBadgeContextMenuActionView` layout and verify live badge refresh rather than rebuilding existing F-08 hook work | F-08 asynchronous notification / F-14 UI coupling |
| F-15 settings UI | Read the remaining `CRP*` classes in the existing `CranePrefs` export | — |
| F-16/F-17 storage and backup | Export `libcrane.dylib`; read `CRPBackupOperation`/`CRPKeychainManager` | U-04, U-06 |
| F-19 XPC | Export `cranehelperd` | U-01 |
| F-22 Shortcuts | Export both `CraneShortcuts.appex` binaries | U-08 |
| F-23 Activator | Recover the original `CraneManager` observer-dispatch body from a `libcrane.dylib` export; icon ABI is now statically recovered | U-01-class missing-binary evidence |

None of these require a device. All of them require more decompilation passes
over exports that are already in this repository, or new exports for the six
binaries that lack them.