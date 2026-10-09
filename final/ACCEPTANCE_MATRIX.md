# Acceptance Matrix

Every requirement, mapped to evidence, implementation, test and final status.
F-IDs are defined in `analysis/behavior_specification.md`.
D-IDs are gaps declared in `final/KNOWN_DIFFERENCES.md`.

## Status vocabulary

| Column | Values |
|---|---|
| Evidence | CONFIRMED_STATIC / CORROBORATED / INFERRED / UNKNOWN |
| SRC | SOURCE_IMPLEMENTED / PARTIAL / NOT_IMPLEMENTED |
| CI | CI_BUILD_PASSED / NOT_TESTED |
| ART | ARTIFACT_INSPECTED / NOT_TESTED |
| DEV | DEVICE_INSTALL_PASSED / INJECTION_VERIFIED / RUNTIME_TEST_PASSED / NOT_TESTED |
| DIFF | DIFFERENTIAL_TEST_PASSED / NOT_TESTED |
| Acceptance | PASS — VERIFIED / PARTIAL — FUNCTIONAL / PARTIAL — BUILD ONLY / BLOCKED / FAIL |

No row can be anything above PARTIAL — BUILD ONLY, because no CI run exists.

## 1. Artifact completeness (Phase 12 A)

| Req | Requirement | Evidence | Result |
|---|---|---|---|
| A-1 | All original package files inventoried | `tools/classify_files.py`, `tools/make_manifest.py` — 77 non-export files, 0 without a role | PASS (CONFIRMED_STATIC) |
| A-2 | Every relevant binary examined | `tools/macho_inspect.py` + `tools/objc_classes.py` over all 11 | PASS (CONFIRMED_STATIC) |
| A-3 | Every `export_for_ai` directory inventoried | `tools/build_export_index.py` → `analysis/ida_export_inventory.md` | PASS (CONFIRMED_STATIC) |
| A-4 | Export→binary mappings established | `tools/prove_export_identity.py` — 5/5 at 100% `__text` match on the arm64 slice | PASS (CONFIRMED_STATIC) |
| A-5 | Dependencies and injection targets identified | `analysis/binary_inventory.md` §3–4, all 11 `LC_LOAD_DYLIB` sets; 3 filter plists | PASS (CONFIRMED_STATIC) |
| A-6 | UI resources catalogued | `analysis/ui_specification.md`, 8 Crane icons + 2 settings icons, 10 localizations, 204 keys | PASS (CONFIRMED_STATIC) |
| A-7 | Analysis blind spots documented | `analysis/environment_report.md` §5, `analysis/binary_inventory.md` §7, U-01/U-04/U-06/U-08 | PASS |
| A-8 | Version mismatch risk between export and binary | Eliminated: 100% `__text` byte identity proves same version | PASS (CONFIRMED_STATIC) |

## 2. Behavioural completeness (Phase 12 B)

| Req | Requirement | Evidence | Result |
|---|---|---|---|
| B-1 | Every discovered feature has a requirement ID | 23 features, F-01…F-23 | PASS |
| B-2 | Every known hook has a documented contract | `analysis/hook_reconstruction.md`, `analysis/hooks_index.csv` — 162 registrations | PASS (CONFIRMED_STATIC) |
| B-3 | Configuration keys and state transitions documented | `analysis/preference_schema.md` — 8 global + 7 per-app keys, 6 notifications, 10 file paths | PASS |
| B-4 | Initialization and lifecycle sufficiently understood | `analysis/hook_reconstruction.md` §2–4; 3 module constructors + per-process entry points | PASS for ` Crane.dylib`, `CraneSupport`; PARTIAL for `CraneSB` (U-07, U-10) |
| B-5 | Feature interactions tested or marked unresolved | 11 interaction edges documented in `behavior_specification.md` §5; all NOT_TESTED | PARTIAL — documented, not tested |
| B-6 | No inferred behaviour presented as confirmed | Every clause carries a class; 3 inferences promoted to CONFIRMED_STATIC during analysis (U-12, U-14, U-16) with the resolving evidence attached | PASS |

## 3. Visual completeness (Phase 12 C)

| Req | Requirement | Result |
|---|---|---|
| C-1 | Every discovered screen has a reference specification | 3 screens structurally specified (`tests/ui_comparison.md` §2) — PARTIAL |
| C-2 | Layout/typography/colour differences evaluated | **BLOCKED** — 0 values recoverable; not 1 value is recoverable (`tests/ui_comparison.md` §2.3) |
| C-3 | Interactive controls update the correct runtime state | NOT_TESTED — specification-level: F-15 rows mapped to keys with defaults |
| C-4 | Persistence and reopening match the reference | **FAIL (static)** — `CraneManager` holds application settings in memory (D-16) |
| C-5 | Remaining visual differences documented | `tests/ui_comparison.md` §2.3, §5, D-08, D-18, D-19 | PASS (as documentation) |

## 4. Build and packaging (Phase 12 D)

| Req | Requirement | Result | Evidence |
|---|---|---|---|
| D-1 | The replacement builds through GitHub Actions | NOT_TESTED | workflow authored at repo-root `.github/workflows/build.yml` |
| D-2 | The actual CI result is available | NOT_TESTED | no run exists; `tests/ci_build_results.md` records why |
| D-3 | Source revision and artifact identifiable | NOT_TESTED | — |
| D-4 | The generated package has been inspected | NOT_TESTED | — |
| D-5 | Correct architecture configuration | **PASS (analysis-time)** | `verify_architectures.py`: 11/11 binaries match the original's rule (dylibs `arm64+arm64e`, executables thin `arm64`) |
| D-6 | Correct packaging configuration | **PASS (analysis-time)** | 12/12 layout plists semantically identical; 10/10 assets byte-identical |
| D-7 | Installation and activation verified on device | NOT_TESTED | — |
| D-8 | Runtime logs and crash status checked | NOT_TESTED | — |
| D-9 | Uninstallation and cleanup validated | NOT_TESTED | — |
| D-10 | The build is reproducible from documented source | PARTIAL | `final/BUILD_AND_INSTALL.md` + a single `make package`; unverified because no run exists |

## 5. Test coverage (Phase 12 E)

| Req | Requirement | Result |
|---|---|---|
| E-1 | Every core feature has at least one positive test | PASS — 76 tests specified across 23 features (`tests/functional_tests.md`) |
| E-2 | Enable/disable states both tested | PASS at specification level (F-01 tests 1–4 cover the 2×2 of container × spoofing; F-03-6 and F-04-4 cover disabled) |
| E-3 | Persistence and lifecycle tests | SPECIFIED — T-F02-4, T-F15-4, T-F16-1 |
| E-4 | Critical edge cases tested or reasons recorded | PASS — reasons recorded for the untestable (D-01, U-01 and remaining runtime-only UI differences) |
| E-5 | No unresolved critical failure hidden by an overall pass | **PASS** — the overall status is PARTIAL — BUILD ONLY; the 9 expected-failure tests are named individually in `tests/functional_tests.md` |
| E-6 | Results associated with the correct revision | N/A — no results exist |

## 6. Evidence quality (Phase 12 F)

| Req | Requirement | Result |
|---|---|---|
| F-1 | Every critical requirement has evidence | PASS |
| F-2 | Every runtime claim has an actual runtime observation | **PASS vacuously** — no runtime claim is made anywhere |
| F-3 | Every CI claim has an actual CI result | **PASS** — no CI claim is made |
| F-4 | Every known difference has a record | PASS — 22 differences in `final/KNOWN_DIFFERENCES.md` |
| F-5 | Test outcomes can be reproduced | PASS for the 8 static tests (commands in `tests/functional_tests.md`); N/A for runtime |
| F-6 | Final claims match the available evidence | PASS |

## 7. Feature-level matrix

| F-ID | Feature | Evidence | SRC | CI | ART | DEV | DIFF | Acceptance |
|---|---|---|---|---|---|---|---|---|
| F-01 | Launch redirection | CONFIRMED_STATIC (CraneSB 0x1B45C, 0x1B360) | PARTIAL — contract transcribed, SpringBoard APIs unhooked (D-04) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-02 | In-app env + dirs | CONFIRMED_STATIC (Crane 0x65D0) | SOURCE_IMPLEMENTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-03 | Container isolation | CONFIRMED_STATIC (Crane 0x7268/0x721C/0x71C0/0x7140/0x70B0) | SOURCE_IMPLEMENTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-04 | Sandbox spoofing | CONFIRMED_STATIC (Crane 0x6564) | SOURCE_IMPLEMENTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-05 | Per-container prefs | CONFIRMED_STATIC (Support 0xBBFC/0xAB1C/0xADF0/0xB4D0) | PARTIAL — control flow recovered, private ABI hooks pending (D-05) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-06 | Container resolution | CORROBORATED (Support 0xCC88) | PARTIAL — dispatch only | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-07 | Per-container keychain | CORROBORATED (Support 0x11E5C) | NOT_IMPLEMENTED (D-06) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-08 | Per-container APNs | CORROBORATED (Support 0x9C4C, SB 0x1EB9C) | NOT_IMPLEMENTED (D-07) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-09 | System accounts | CONFIRMED_STATIC (Support 0x7200) | PARTIAL — dispatch only | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-10 | Game Center | CONFIRMED_STATIC (SB 0x1B45C, Prefs 0x8D00) | PARTIAL | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-11 | Device identifier | CORROBORATED (Support 0xD7D8) | PARTIAL | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-12 | Plug-in enumeration | CONFIRMED_STATIC (Support 0xF2B4) | PARTIAL — dispatch only | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-13 | Container selection UI | CONFIRMED_STATIC / CORROBORATED (SB 0x137FC/0x13508/0x145B8/0x15E20) | PARTIAL — modern UIMenu path transcribed; legacy force-touch/badge decoration absent | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-14 | Badges | CONFIRMED_STATIC (SB 0x7F58) | NOT_IMPLEMENTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-15 | Settings UI | CONFIRMED_STATIC (Root.plist, Credits.plist, 34 classes) | PARTIAL — 2 of 3 controllers (D-18) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-16 | Container lifecycle | CONFIRMED_STATIC (API) / UNKNOWN (layout) | PARTIAL (U-04) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-17 | Backup/restore | CONFIRMED_STATIC (UI) / UNKNOWN (format) | NOT_IMPLEMENTED (D-10) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-18 | Biometric gate | CONFIRMED_STATIC (Crane 0x6E08) | SOURCE_IMPLEMENTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-19 | cranehelperd XPC | CONFIRMED_STATIC (registration) / UNKNOWN (protocol) | PARTIAL — own protocol (D-02) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-20 | Self-verification | CONFIRMED_STATIC (SB 0x17620) | PARTIAL — checks only, no alert UI (D-19) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-21 | Choicy integration | CONFIRMED_STATIC (SB 0x1BBB8) | PARTIAL — structural (D-09) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-22 | Shortcuts / Siri | CONFIRMED_STATIC (declaration) / UNKNOWN (bodies) | NOT_IMPLEMENTED (D-11, U-08) | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |
| F-23 | Activator | CONFIRMED_STATIC (CraneActivatorManager) | NOT_IMPLEMENTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | NOT_TESTED | PARTIAL — BUILD ONLY |

## 8. Overall status

# PARTIAL — BUILD ONLY

**It does not even reach that literally.** The honest status is a compound:

| Reading | Applies |
|---|---|
| PASS — VERIFIED | No. Mandatory behavioural validation was not performed. |
| PARTIAL — FUNCTIONAL | No. No feature has been shown to work at runtime, and 7 whole subsystems are unimplemented. |
| **PARTIAL — BUILD ONLY** | The closest available label, with the caveat that **even the build has not been executed**: the highest verified state is SOURCE_IMPLEMENTED for 5 of 23 features, with packaging verified at analysis time and the CI build `NOT_TESTED`. |
| BLOCKED | Applies to the runtime-verification half specifically: no device access, no artifact, no CI run. |
| FAIL | No mandatory criterion has been *demonstrably violated*. One is predicted to fail (persistence, D-16) and 9 tests are predicted to fail; those are predictions from static analysis, not demonstrations. |

### The one-line version

Of 23 recovered features, **5 are transcribed from the recovered pseudocode, 9
are partial, and 9 are absent**; the packaging and configuration layer is
byte-verified against the original; **no build has been run, no artifact exists,
and no device has been used** — so nothing about this reconstruction's runtime
behaviour has been demonstrated, and it is **not** a behavioural equivalent of
Crane 6.0. See `final/KNOWN_DIFFERENCES.md`.