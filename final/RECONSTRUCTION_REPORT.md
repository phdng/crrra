# Reconstruction Report

## Executive summary

The workspace contained an **extracted iOS package payload tree** — 77 files,
11 Mach-O binaries, 3 Substrate filters, 1 launchd job, 5 libSandy profiles —
plus **five IDA Pro export directories** (2651 decompiled functions). There was
no source, no build system, no CI workflow, no tests, no screenshots and no
device evidence.

This project established, from that evidence alone:

- that each IDA export provably came from the binary beside it, same version,
  arm64 slice (100.000% `__text` byte identity, versus 9–12% for arm64e);
- a complete inventory of all 11 binaries, 77 files, 162 hook registrations,
  44 Objective-C classes and the preference/notification/path contracts;
- a source-independent specification of **23 features** with 76 acceptance tests;
- a **Theos reconstruction** of seven build targets, a byte-verified package layout,
  and a GitHub Actions workflow.

Five features are transcribed from the recovered pseudocode, nine are partial,
**nine are absent**. No build has been run, no artifact exists, and no device has
been used.

**This is not a behavioural equivalent of Crane 6.0.** Every gap is named in
`final/KNOWN_DIFFERENCES.md` rather than filled with plausible code.

## 1. Original package

Crane 6.0 (build 1), bundle `com.opa334.CraneApplication`, by Lars Fröder
(opa334). A jailbreak tweak that runs multiple independent copies of one app's
data ("containers") and makes each copy indistinguishable to both the app and its
vendor.

The analysed copy is a **third-party redistribution** — `Root.plist` carries a
"Crack by Repo BVN" button where upstream ships "Follow me on Twitter", though the
action name (`openTwitter`) and the `FOLLOW_ME_ON_TWITTER` key are both still
present. No binary patching was detected: the exports byte-match the binaries, so
the payload is the upstream code.

## 2. Environment

`analysis/environment_report.md`. The decisive points:

| Finding | Consequence |
|---|---|
| No `.deb`, `DEBIAN/control`, or maintainer script | Package identity came from bundle metadata; the app-bundle selection mechanism is **BLOCKED** (U-19) |
| No Makefile / Logos / Theos config | The build system had to be written from scratch |
| No `.github/`, no `gh`, no remote | **No CI run can be claimed** |
| No `otool`/`llvm-objdump`/`strings`/`ar` | Wrote `tools/macho_inspect.py` and `tools/objc_classes.py` to read Mach-O and ObjC metadata directly |
| No Theos/Xcode/SDK | Build validation is CI-only and is `NOT_TESTED` |
| No device, logs, screenshots | Every runtime claim is `NOT_TESTED` |

## 3. IDA export coverage

`analysis/ida_export_coverage.md`. Five export directories, all mapped, all
complete:

| Export | Functions | Coverage | Identity proof |
|---|---:|---|---|
| ` Crane.dylib` | 68 | 68/68 `done` | 5020/5020 `__text` bytes |
| `CraneSB.dylib` | 538 | 538/538 | 104212/104212 |
| `CraneSupport.dylib` | 624 | 624/624 | 87048/87048 |
| `CranePrefs` | 1368 | 1368/1368 | 233000/233000 |
| `CraneApplication` | 53 | 53/53 | 1620/1620 |
| **Total** | **2651** | **100%** | **100.000% on the arm64 slice** |

**Six binaries have no export at all**, most importantly `libcrane.dylib` (the
container registry and XPC client) and `cranehelperd`. This is the single
biggest constraint on the whole project and is quantified in §8.

No decompilation was re-run. All new work was indexing, Mach-O parsing for the
unexported binaries, and the byte-level identity proof.

## 4. Recovered architecture

| Component | Path | Slices | Installs into |
|---|---|---|---|
| Main dylib | `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` | arm64+arm64e | every app |
| SpringBoard dylib | `…/CraneSB.dylib` | arm64+arm64e | SpringBoard, runningboardd |
| Daemon-support dylib | `…/CraneSupport.dylib` | arm64+arm64e | 7 system daemons |
| Settings bundle | `Library/PreferenceBundles/CranePrefs.bundle/CranePrefs` | arm64+arm64e | Settings |
| Client library | `usr/lib/libcrane.dylib` | arm64+arm64e | linked by 4 binaries |
| Daemon | `usr/local/libexec/cranehelperd` | arm64 | root launchd job |
| Daemon restarter | `usr/local/bin/cranehelperd_start` | arm64 | — |

All seven non-app binaries: iOS 11.0 minimum, SDK 14.5.0. Apps: iOS 14.0/SDK 18.0
and iOS 12.0/SDK 17.4. No rpaths, absolute install names, no entitlements,
stripped.

**The main dylib's filename begins with a space.** Confirmed by character codes
and by four references to the spaced name inside the binaries. The package's own
`CHOICYLOADER_SUGGESTION_MESSAGE` names it `" Crane.dylib"`. Load-bearing, and
reproduced.

## 5. Feature inventory

23 features, specified in `final/SPECIFICATION.md` and
`analysis/behavior_specification.md`. The load-bearing cross-process contract:

```
SpringBoard (CraneSB)                     app process ( Crane.dylib)
──────────────────────────                ────────────────────────────
reads cranehelperd self-check   ──┐
writes CRANE_CONTAINER_IDENTIFIER ──►  InitFunc_0: read + unsetenv
writes CRANE_PROTECT_CONTAINERS   ──►  create 8 directories
writes CRANE_SPOOF_SANDBOX_LOOKUPS ──►  setenv HOME/CFFIXED_USER_HOME/TMPDIR
                                       install hooks
```

Fail-open at both failure points (libSandy down, self-check failed): the
environment is returned unmodified and an alert is shown, rather than the app
being pointed at a container Crane cannot honour.

## 6. Reconstruction

`reconstruction/IMPLEMENTATION_STATUS.md`. Six components, one shared contract
layer (`CRPaths.h`, `CRPreferences.h`, `CRManager.h`, `CRCommon.{h,m}`).

**Complete, transcribed 1:1 from recovered pseudocode (17 functions):**

| Function | Recovery |
|---|---|
| `Crane.dylib` `InitFunc_0` | Crane 0x65D0 |
| `sandbox_container_path_for_pid_hook` | 0x6564 |
| `initProtection` + `new_unlink` / `new_readdir` / `new_readdir_r` / `new_URLEnumeratorGetNextURL` | 0x7268 / 0x721C / 0x71C0 / 0x7140 / 0x70B0 |
| `HCHookFunctions` | 0x7360 |
| `localize` | 0x6924 |
| `createDirectoryIfNotExists` | 0x6BE0 |
| `requestAuthentication` + reply block | 0x6E08 / 0x6F40 |
| `safe_getBundleIdentifier` | 0x6544 |
| `containerPathForContainer`, `normalizedContainerID` | 0x6B2C, 0x6DC0 |
| `crane_applyEnvironmentChanges` | CraneSB 0x1B45C |
| `crane_containerToRedirectTo` | CraneSB 0x1B360 |
| the 8 preference predicates | CraneSB 0x1EB9C–0x1F008 |
| `crane_initSpringBoard` / `crane_initRunningBoardd` | 0x17A14 / 0x1BF10 |
| `CraneSupport` per-daemon dispatch | 0x6C5C |
| `specifiers` (2 of 3 settings controllers) | CranePrefs 0x8D00 |

**Verified identical to the original (12 plists, 10 assets):** the three Substrate
filters, the launchd job, the five libSandy profiles, the PreferenceLoader entry,
`Root.plist`, `Credits.plist`, the settings `Info.plist`, and every artwork asset.

**Enforced by the CI workflow:** all 23 recovered static layout files plus 7
compiled artifacts, and the architecture rule (dylibs/bundles `arm64+arm64e`,
executables thin `arm64`) — which 11 of 11 original
binaries already satisfy.

## 7. Build, package, device status

| Stage | Status |
|---|---|
| Source written | **YES** — 7 build targets; static consistency checks are re-run before claiming a pass |
| Layout verified against the original | **YES** — 12/12 plists, 10/10 assets |
| CI workflow authored | **YES** |
| CI build run | **NOT_TESTED** — no remote, no `gh`, no run ID |
| Artifact produced and inspected | **NOT_TESTED** |
| Device install | **NOT_TESTED** |
| Injection verified | **NOT_TESTED** |
| Runtime tests | **NOT_TESTED** — 0 of 76 |
| Differential tests | **NOT_TESTED** |
| UI comparison | **NOT_TESTED** — 0 of 3 screens, no screenshots exist |

## 8. Fidelity assessment

| Measure | Result |
|---|---|
| Original files inventoried and hashed | 77 / 77 |
| Binaries examined | 11 / 11 |
| IDA exports mapped and byte-verified | 5 / 5 |
| Features with a complete transcription | **5 / 23** |
| Features partial | 9 / 23 |
| Features absent | 9 / 23 |
| Recovered functions transcribed 1:1 | 17 / 2651 |
| Hook registrations catalogued | 162 / 162 |
| Preference keys documented | 15 global/per-app + 10 per-container + 7 notifications |
| Uncertainties | 4 resolved, 15 open, 1 blocked |
| Runtime verification | **0%** |

## 9. Critical limitations

**A. Runtime verification is zero.** No device, no artifact, no CI run. Every
claim about how the original behaves is static; every claim about how the
reconstruction behaves is a statement about its source.

**B. Six binaries had no decompiler output.** `libcrane.dylib` holds the container
registry, the XPC client and the backup engine; `cranehelperd` holds the XPC
service. Their *API surfaces* were recovered from call sites, their
*implementations* were not. Consequently this build defines its own XPC protocol
and cannot speak to the original daemon, and containers written by one build are
not readable by the other.

**C. F-01 does not work end to end.** The function that decides the launch
environment is transcribed correctly; the SpringBoard private APIs that deliver
it are not hooked. This is the largest single functional gap.

**D. Seven subsystems are absent**, several of which affect data integrity rather
than convenience: per-container keychain (F-07), notifications (F-08), plug-in
enumeration (F-12), the selection UI (F-13), badges (F-14), backup/restore (F-17)
and Shortcuts (F-22). Keychain isolation in particular is a *correctness*
difference: containers share one keychain, so credentials written in one are
visible in another.

**E. Nothing visual was measured.** No screenshot exists of the original. Row
*structure* is known exactly; every pixel is UNKNOWN.

## 10. Final status

# PARTIAL — BUILD ONLY

with the caveat that **even the build has not been executed**: no CI run exists,
so the highest verified state is `SOURCE_IMPLEMENTED` for 5 of 23 features plus
analysis-time verification of the packaging layer.

- **PASS — VERIFIED** is not available: mandatory behavioural validation was not
  performed.
- **PARTIAL — FUNCTIONAL** is not available: no feature is shown to work at
  runtime, and 7 subsystems are absent.
- **FAIL** does not apply: no mandatory criterion has been *demonstrably*
  violated. One is predicted to fail (persistence, D-16) and 9 tests are
  predicted to fail; those are static predictions, not demonstrations.
- **BLOCKED** applies to the runtime-verification half specifically.

## 11. What would raise the status

The rows below are **required actions**, not results. None has been performed.

| To reach this status | Required action |
|---|---|
| `CI_BUILD_PASSED` | Push to a remote and complete a `make package` run; record the run ID and `.deb` hash in `tests/ci_build_results.md` |
| `ARTIFACT_INSPECTED` | Unpack that `.deb` and confirm all 30 required package files, the architectures and the plist equivalence |
| `RUNTIME_TEST_PASSED` (any feature) | Install on the user's authorised device and run that feature's tests in `tests/functional_tests.md` |
| `DIFFERENTIAL_TEST_PASSED` (any feature) | Also install the original `.deb` — which requires recovering the `.deb` first (U-19) |
| PARTIAL — FUNCTIONAL | Implement the 9 absent subsystems; the highest-value first steps are listed per-feature in `reconstruction/IMPLEMENTATION_STATUS.md` §5 |

Most of the implementation work does **not** need a device or a new export.
U-02 and U-05 are now resolved by reading the existing cfprefsd and CraneSB
decompilations. U-03 and most of U-06 can likewise be closed from exports already in this repository.
Only U-01 (the cranehelperd XPC interface) genuinely requires a new export.

## 12. Artifact index

| Area | Files |
|---|---|
| Analysis reports | `analysis/` — 12 reports |
| Machine-readable indexes | `analysis/symbols_index.csv` (2651), `callers_index.csv` (6485), `strings_index.csv` (3667), `hooks_index.csv` (159), `objc_classes.json`, `preference_schema.csv`, `preference_access.csv`, `crane_api_symbols.csv`, `consistency_audit.txt` |
| Analysis tools | `tools/` — 11 scripts, all reproducible |
| Reconstruction | `reconstruction/` — 7 build targets + shared contract layer + 12 plists + 10 assets; workflow at repo-root `.github/workflows/build.yml` |
| Tests | `tests/` — 5 files: functional, regression, CI, device, UI comparison |
| Final | `final/` — report, specification, build/install, known differences, acceptance matrix |
| Untouched | every original file and every IDA export directory |