# Device Test Results

**Status: BLOCKED — no device access exists in this environment.**

## 1. Boundary

This project has no connection to the user's device-testing workflow:

- no device, no SSH, no `ideviceinstaller`, no `iproxy`;
- no screenshot, screen recording, device log or crash report in the repository;
- no record of how the user installs and tests the package.

Consequently **no statement in this repository asserts that the reconstructed
package was installed, injected, launched, or exercised on any device.** The
verification checklist below is pre-filled with the *result* that is actually
known, which for every device row is `NOT_TESTED` or `BLOCKED`.

## 2. Verification checklist

Result vocabulary: `PASS` / `FAIL` / `INCONCLUSIVE` / `NOT_TESTED` / `BLOCKED` /
`NOT_APPLICABLE`.

| # | Check | Result | Evidence |
|---|---|---|---|
| 1 | Package installation succeeds | NOT_TESTED | no artifact exists |
| 2 | Expected files installed at the recovered paths | NOT_TESTED | paths verified against the original package at analysis time (`analysis/package_inventory.md`); not verified on device |
| 3 | Injection filters match the intended processes | NOT_TESTED | filter plists reproduced and verified semantically identical (12/12) |
| 4 | The library loads into the target process | NOT_TESTED | — |
| 5 | Initialisation completes without a relevant crash | NOT_TESTED | — |
| 6 | Preferences and resources are found | NOT_TESTED | `com.opa334.craneprefs` and `/Library/Application Support/Crane.bundle` reproduced |
| 7 | Core hooks execute under expected conditions | NOT_TESTED | — |
| 8 | Core features match the behavioural specification | NOT_TESTED | — |
| 9 | UI changes and user interactions behave correctly | NOT_TESTED | — |
| 10 | Preferences and state persist across restarts | **FAIL (expected)** | `CraneManager` keeps application settings in memory (`reconstruction/IMPLEMENTATION_STATUS.md` §1); persistence is a known gap (D-16) |
| 11 | Process restarts and lifecycle transitions behave correctly | NOT_TESTED | — |
| 12 | No relevant regression or new crash | NOT_TESTED | — |
| 13 | Uninstallation and cleanup work | NOT_TESTED | — |
| 14 | `cranehelperd` launches and serves both Mach services | NOT_TESTED | — |
| 15 | libSandy integration succeeds | NOT_TESTED | requires the `libhooker` package on device |

Row 10 is recorded as FAIL on the strength of a static, code-level fact (no
persistence call exists), not on the strength of an observed failure. It is the
one row that can be predicted rather than measured.

## 3. What the user-managed workflow would need to produce

To convert the checklist above, the minimum evidence set is:

| Evidence | Unblocks |
|---|---|
| `dpkg -l com.opa334.cranereconstruction` output | row 1 |
| `dpkg -L` output | row 2 |
| `log stream --predicate 'senderImagePath CONTAINS "Crane"'` during a launch | rows 4, 5, 7 |
| `ps aux` / `vmmap` on an app process showing ` Crane.dylib` mapped | row 4 |
| `launchctl print system/com.opa334.cranehelperd` | row 14 |
| `sfltool dumpbtm` or the app-switcher screenshot after long-pressing an icon | rows 8, 9 |
| Settings → Crane screenshot | rows 9, 11 |
| A container created, then the app relaunched and its data compared | rows 7, 8, 11 |
| Any `*.ips` crash report from a Crane-injected process | row 12 |

## 4. Test-by-test status

The `T-*` identifiers come from `analysis/behavior_specification.md` §3
(acceptance tests per feature). Every one is `NOT_TESTED` — there are 76 of them
across the 23 features. They are enumerated with their preconditions so they can
be executed directly when a device becomes available; none has been run, so none
is reported as passing or failing.

Representative rows:

| Test ID | Feature | What it would establish | Status |
|---|---|---|---|
| T-F01-3 | F-01 | `CRANE_CONTAINER_IDENTIFIER` is present in a launched app's environment | NOT_TESTED |
| T-F02-1 | F-02 | the container directory tree is created and `$HOME` points at it | NOT_TESTED |
| T-F03-1 | F-03 | `unlink` of a `___Crane_Containers` path returns 0 and deletes nothing | NOT_TESTED |
| T-F04-1 | F-04 | self-pid `sandbox_container_path_for_pid` returns the container path | NOT_TESTED |
| T-F05-1 | F-05 | prefs written in container A are invisible in B | NOT_TESTED — **expected to fail**, see D-05 |
| T-F07-1 | F-07 | keychain items are isolated per container | NOT_TESTED — **expected to fail**, see D-06 |
| T-F13-1 | F-13 | long-pressing a supported app icon shows the container submenu | NOT_TESTED — **expected to fail**, see D-08 |
| T-F15-1 | F-15 | every row in the recovered settings tree appears with the same default state | NOT_TESTED — **expected to partially fail**, see D-18 |
| T-F18-1 | F-18 | the biometric success handler runs on the main thread | NOT_TESTED |
| T-F18-2 | F-18 | the handler still runs when biometrics are unavailable (fail-open) | NOT_TESTED |
| T-F19-2 | F-19 | `cranehelperdConnectionWorks` is true | NOT_TESTED — **expected to fail** with the original daemon, see D-02 |

Rows marked "expected to fail" are predictions derived from the static
implementation status, not observations. They are stated as expectations so that
a first device run can be read against a prior rather than interpreted from
scratch.

## 5. Environment details

Unknown and required before any device test is meaningful:

| Field | Value |
|---|---|
| Device model | UNKNOWN |
| iOS version | UNKNOWN |
| Jailbreak type (rootful / rootless / Bootstrap) | UNKNOWN |
| Substrate implementation (Substrate / ElleKit / libhooker) | UNKNOWN |
| Installed `libhooker`, `firmware`, `altlist`, `activator`, `choicy` | UNKNOWN |
| Free disk space (required by the backup flow's free-space checks) | UNKNOWN |

The behavioural specification defines compatibility in terms of
`kCFCoreFoundationVersionNumber` thresholds (1665.15 and 1932.101) and the
`CraneSupport.plist` `Flags` value, so an iOS version alone is not sufficient to
predict which code paths a device will take — the environment above must be
recorded alongside any test result.