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
| `CRCommon.m` | complete | `localize`, `createDirectoryIfNotExists`, `requestAuthentication`, `safe_getBundleIdentifier`, `getInjectionPlatform` transcribed | SOURCE_IMPLEMENTED |
| `libcrane.dylib` / `CraneManager` | partial | **Selector surface CONFIRMED_STATIC; implementation INFERRED** | SOURCE_IMPLEMENTED (API) |
| `cranehelperd` | partial | Registration and class names CONFIRMED_STATIC; **XPC protocol is this project's own** | SOURCE_IMPLEMENTED |
| `cranehelperd_start` | partial | Only the path is recovered | SOURCE_IMPLEMENTED |
| `CraneSB.dylib` | partial | Entry dispatch + F-01 environment contract and the core `CraneActivatorManager` listener/event integration are transcribed; menus/notification hooks remain incomplete | SOURCE_IMPLEMENTED (F-01, F-23 core) |
| `CraneSupport.dylib` | partial | Per-daemon dispatch plus recovered cfprefsd, containermanagerd, accountsd, lsd/device-ID and pkd/PlugInKit hook chains are transcribed; APNs/keychain hooks remain incomplete | SOURCE_IMPLEMENTED (dispatch, F-05/F-06/F-09/F-11 hook cores, F-12 server-side core) |
| `CranePrefs` | partial | Root controller + two panes; specifier construction mirrors recovered `0x8D00` | SOURCE_IMPLEMENTED (structure) |

## 2. Feature status against the specification

F-IDs refer to `analysis/behavior_specification.md`.

| ID | Feature | Implemented | Gap |
|---|---|---|---|
| F-01 | Launch redirection | **Yes** — `CRApplyEnvironmentChanges`, transcribed step by step including both fail-open alert paths | SpringBoard's private launch APIs are not hooked, so the environment is not actually delivered to an app |
| F-02 | In-app env + dirs | **Yes** — full transcription | none |
| F-03 | Container isolation | **Yes** — all four hooks, including the `dlopen`/`dlsym` of `CoreServicesInternal` | `new_unlink`'s missing NULL check is preserved (upstream behaviour) |
| F-04 | Sandbox-lookup spoofing | **Yes** — full transcription | none |
| F-05 | Per-container preferences | Partial — `handleSourceMessage`, both `withSourceForDomain` ABI families, `__CFPrefsGetPathForTriplet`, version guards and libundirect fallback are transcribed in `CRCfprefs.m` | PID→container helper transport is still U-01, so runtime redirection cannot be claimed end-to-end; no device test |
| F-06 | Container resolution | Partial — `ClientContainerCache`, modern `MCMContainerFactory`, legacy `MCMClientConnection`, group-path rewrite, corrupt suppression, PID capture and guarded Crane proxy are transcribed | Reconstructed helperd/libcrane PID→container transport still returns `DEFAULT`; `_populateContainerDirectory:ofType:` body is unavailable; no runtime test |
| F-07 | Per-container keychain | **Not implemented** | Needs the ~180-function code-signature/Mach-O toolkit; a stub would silently weaken isolation |
| F-08 | Per-container APNs | Partial — apsd-side topic/hash translation, `crane_topicStorage`, ApplePushService helper fallbacks, keychain topic lookup, token response restoration and all 10 recovered method hooks are transcribed in `CRApsd.m` | SpringBoard's ~40 notification producer/routing/title/badge hooks remain U-10; incoming apsd message rewrite also depends on U-01 `verifyCraneSBLoadedAndReply:` health proxy; no runtime test |
| F-09 | System accounts | Partial — client routing, modern coordinator-per-container, legacy database-per-container, legacy shared-coordinator reset/cache and Start-Using-iCloud suppression are transcribed in `CRAccountsd.m` | PID→container transport remains U-01; `gamed` path remains limited by reconstructed Game Center model U-06; no runtime test |
| F-10 | Game Center | Structure only | Account storage model unknown (U-06) |
| F-11 | Device identifier | Partial — LSD protocol extension, type-0 per-container UUID spoofing, helperd-only cache getter/setter, vendor-key derivation and `_LSDeviceIdentifierCache`/persona fallback are transcribed in `CRLsd.m`; reconstructed manager now uses the confirmed `customDeviceIdentifier` key | App-side PID→container routing remains U-01; reconstructed helperd still stores identifiers in `NSUserDefaults` instead of invoking the recovered lsd extension; no runtime test |
| F-12 | Plug-in enumeration | Partial — `PKDPlugIn` active-container state, four enable hooks, Transaction rule consumption, PKDatabase query wrappers, plug-in termination and reload handling are transcribed | SpringBoard notification-support hooks that append `extension_containerIDToAppend` as `crane_containerID` are still part of unresolved F-08/U-10; no runtime test |
| F-13 | Container selection UI | **Not implemented** | Cell layout needs a screenshot or the `_configureCell` hooks (U-05) |
| F-14 | Badges | **Not implemented** | Depends on F-08 |
| F-15 | Settings UI | Partial | Plists reproduced exactly; 2 of 3 panes implemented; backup/restore, Choicy pane and suggestions absent |
| F-16 | Container lifecycle | Partial — CRUD present in `CraneManager`, on-disk layout INFERRED | Layout/identifier format unknown (U-04) |
| F-17 | Backup / restore | **Not implemented** | Archive and encryption format unknown (U-06) |
| F-18 | Biometric gate | **Yes** — full transcription | none |
| F-19 | cranehelperd XPC | Partial | Own protocol; incompatible with the original daemon (U-01) |
| F-20 | Self-verification | Partial | `verifyCraneInsurance` implemented; alert UI not built |
| F-21 | Choicy integration | Partial — rootless-aware Choicy load/registration plus all 6 `CraneChoicyOverwriteProvider` methods are transcribed with exact return ABI, per-container gate, nested override parsing, bitmask `7`, and `" Crane"` allow-list preservation | Reconstructed CranePrefs still lacks the per-container Choicy configuration editor (`CRPContainerChoicyOverwriteListController`); no runtime test |
| F-22 | Shortcuts / Siri | **Not implemented** | No source for `CraneIntentHandlerShared` (U-08) |
| F-23 | Activator | Partial — dynamic load, listener/event registration, name parsing, switch/abort callbacks, metadata and app-icon generation are transcribed | `generateIconImageWithInfo:` is now recovered as a four-double HFA from both arm64 slices; remaining gap is the reconstructed `CraneManager` observer-dispatch semantics plus runtime testing |

## 3. Coverage summary

| Measure | Value |
|---|---|
| Features with a complete, transcribed implementation | 5 of 23 (F-02, F-03, F-04, F-18, and F-01's contract) |
| Features partially implemented | 13 |
| Features not implemented | 5 |
| Recovered functions transcribed | Initial 17-function core plus later main-dylib/libroot work, the 42-method `CraneActivatorManager` surface, cfprefsd preferences, accountsd/Core Data isolation, lsd/device-ID isolation, apsd token/topic isolation, Choicy override provider, containermanagerd/cache/proxy, and pkd/PlugInKit chains; no inflated aggregate 1:1 count is claimed |
| Reconstruction source | 7461 lines across 15 `.m` and 4 `.h` files |
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
| F-05 prefs redirect | Recover/replace the missing helperd/libcrane PID→container transport and perform device validation; cfprefsd hook/ABI layer is now transcribed | U-01 runtime transport |
| F-06 containermanagerd | Recover/replace the missing libcrane/helperd PID→container transport and `_populateContainerDirectory:ofType:` semantics; hook/control-flow transcription is now present | U-01 / missing libcrane body |
| F-12 PlugInKit | Complete the SpringBoard-side `extension_containerIDToAppend` query-tagging path together with notification support | U-10 / F-08 coupling |
| F-07 keychain | Port or reimplement the embedded `csd_*`/`macho_*`/`pfsec_*` toolkit from the ~180 exported functions | U-03 |
| F-08 notifications | Resolve/port CraneSB `initNotificationSupport` producer/routing/title/badge hooks; CraneSupport/apsd side is now transcribed | U-10, plus U-01 for the apsd CraneSB-loaded health gate |
| F-13 menu | Read `CraneSB` `_configureCell:` hooks, or take one screenshot | U-05 |
| F-15 settings UI | Read the remaining `CRP*` classes in the existing `CranePrefs` export | — |
| F-16/F-17 storage and backup | Export `libcrane.dylib`; read `CRPBackupOperation`/`CRPKeychainManager` | U-04, U-06 |
| F-19 XPC | Export `cranehelperd` | U-01 |
| F-22 Shortcuts | Export both `CraneShortcuts.appex` binaries | U-08 |
| F-23 Activator | Recover the original `CraneManager` observer-dispatch body from a `libcrane.dylib` export; icon ABI is now statically recovered | U-01-class missing-binary evidence |

None of these require a device. All of them require more decompilation passes
over exports that are already in this repository, or new exports for the six
binaries that lack them.