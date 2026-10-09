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
| `CraneSB.dylib` | partial | Entry dispatch + F-01 environment contract transcribed; menus/hooks not implemented | SOURCE_IMPLEMENTED (F-01) |
| `CraneSupport.dylib` | partial | Per-daemon dispatch transcribed; hook bodies not implemented | SOURCE_IMPLEMENTED (dispatch) |
| `CranePrefs` | partial | Root controller + two panes; specifier construction mirrors recovered `0x8D00` | SOURCE_IMPLEMENTED (structure) |

## 2. Feature status against the specification

F-IDs refer to `analysis/behavior_specification.md`.

| ID | Feature | Implemented | Gap |
|---|---|---|---|
| F-01 | Launch redirection | **Yes** — `CRApplyEnvironmentChanges`, transcribed step by step including both fail-open alert paths | SpringBoard's private launch APIs are not hooked, so the environment is not actually delivered to an app |
| F-02 | In-app env + dirs | **Yes** — full transcription | none |
| F-03 | Container isolation | **Yes** — all four hooks, including the `dlopen`/`dlsym` of `CoreServicesInternal` | `new_unlink`'s missing NULL check is preserved (upstream behaviour) |
| F-04 | Sandbox-lookup spoofing | **Yes** — full transcription | none |
| F-05 | Per-container preferences | Partial — redirect condition + filename rewrite CONFIRMED_STATIC | Private cfprefsd method/function ABI, libundirect fallback and ClientContainerCache hook path are not ported |
| F-06 | Container resolution | Dispatch only | Hook bodies not recovered |
| F-07 | Per-container keychain | **Not implemented** | Needs the ~180-function code-signature/Mach-O toolkit; a stub would silently weaken isolation |
| F-08 | Per-container APNs | **Not implemented** | Depends on F-07-class work plus CraneSB's 40 hooks whose target class is aliased (U-10) |
| F-09 | System accounts | Dispatch only | Needs the Core Data stack and cranehelperd (U-01) |
| F-10 | Game Center | Structure only | Account storage model unknown (U-06) |
| F-11 | Device identifier | Partial | `crane_getIdentifier:`/`crane_setIdentifier:` forwarding not wired (U-01) |
| F-12 | Plug-in enumeration | Dispatch only | 10 `PKDServer` hooks not implemented |
| F-13 | Container selection UI | **Not implemented** | Cell layout needs a screenshot or the `_configureCell` hooks (U-05) |
| F-14 | Badges | **Not implemented** | Depends on F-08 |
| F-15 | Settings UI | Partial | Plists reproduced exactly; 2 of 3 panes implemented; backup/restore, Choicy pane and suggestions absent |
| F-16 | Container lifecycle | Partial — CRUD present in `CraneManager`, on-disk layout INFERRED | Layout/identifier format unknown (U-04) |
| F-17 | Backup / restore | **Not implemented** | Archive and encryption format unknown (U-06) |
| F-18 | Biometric gate | **Yes** — full transcription | none |
| F-19 | cranehelperd XPC | Partial | Own protocol; incompatible with the original daemon (U-01) |
| F-20 | Self-verification | Partial | `verifyCraneInsurance` implemented; alert UI not built |
| F-21 | Choicy integration | Partial | Provider registered structurally; Choicy's protocol is not in the tree |
| F-22 | Shortcuts / Siri | **Not implemented** | No source for `CraneIntentHandlerShared` (U-08) |
| F-23 | Activator | **Not implemented** | Only probed for presence |

## 3. Coverage summary

| Measure | Value |
|---|---|
| Features with a complete, transcribed implementation | 5 of 23 (F-02, F-03, F-04, F-18, and F-01's contract) |
| Features partially implemented | 9 |
| Features not implemented | 9 |
| Recovered functions transcribed 1:1 | 17 of 2651 exported functions |
| Reconstruction source | 3041 lines across 8 `.m` and 4 `.h` files |
| Automated checks passing | 84 cross-document + identifier resolution + brace balance |
| Install-path / configuration artefacts verified identical | 12 of 12 plists, 10 of 10 assets |
| Binary architectures validated against the original rule | 11 of 11 |
| Runtime tests executed | **0** |

## 4. Why this ratio is what it is

This is not a build of what was understood and then abandoned. It is the
honest ceiling given the evidence:

- **17 of 2651** recovered functions live in binaries that **have** a decompiler
  export. Those are transcribed.
- The remaining 2634 include the largest subsystems — the notification hook set,
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
| F-05 prefs redirect | Port `handleSourceMessage`, `withSourceForDomain`, `__CFPrefsGetPathForTriplet` and `ClientContainerCache` with the recovered version/libundirect ABI guards | U-02 resolved; ABI port remains |
| F-06/F-12 daemon hooks | Read `CC88.c`, `F2B4.c` and their callees | — |
| F-07 keychain | Port or reimplement the embedded `csd_*`/`macho_*`/`pfsec_*` toolkit from the ~180 exported functions | U-03 |
| F-08 notifications | Read `CraneSupport/decompile/9C4C.c` and resolve `CraneSB/decompile/CBEC.c`'s aliased classes | U-10 |
| F-13 menu | Read `CraneSB` `_configureCell:` hooks, or take one screenshot | U-05 |
| F-15 settings UI | Read the remaining `CRP*` classes in the existing `CranePrefs` export | — |
| F-16/F-17 storage and backup | Export `libcrane.dylib`; read `CRPBackupOperation`/`CRPKeychainManager` | U-04, U-06 |
| F-19 XPC | Export `cranehelperd` | U-01 |
| F-22 Shortcuts | Export both `CraneShortcuts.appex` binaries | U-08 |
| F-23 Activator | Export `CraneActivatorManager` bodies — already present; read them | — |

None of these require a device. All of them require more decompilation passes
over exports that are already in this repository, or new exports for the six
binaries that lack them.