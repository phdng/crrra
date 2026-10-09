# Runtime Observations

**There are none.**

## 1. Statement

No runtime observation of the original tweak, and none of the reconstruction,
exists anywhere in this repository or was produced by this project.

| Question | Answer |
|---|---|
| Was any device connected? | No |
| Was any package installed? | No |
| Was any binary observed loaded into a process? | No |
| Were any logs, crash reports, screenshots or recordings available? | No — none are present in the repository |
| Was any debugger or LLDB session run? | No — no toolchain for it exists in this environment |
| Was the original or the reconstruction executed? | Neither |

Therefore **no claim in this project is `CONFIRMED_RUNTIME`**, and no feature is
`RUNTIME_TEST_PASSED`. This is stated at the top of
`analysis/behavior_specification.md`, in `tests/device_test_results.md`, in
`tests/ui_comparison.md`, and in the overall status of
`final/ACCEPTANCE_MATRIX.md`.

## 2. What a runtime observation would require

| Requirement | Availability here |
|---|---|
| An authorised jailbroken iOS test device | Not available |
| A route to it (SSH / `iproxy` / a CI self-hosted runner with a device) | Not available |
| A built `.deb` of the reconstruction | Not available — no build has run |
| The original `.deb` for differential comparison | Not available — only the extracted payload tree |
| A record of the user's existing install/test workflow | Not present in the repository |

## 3. What static evidence is *not*

For the avoidance of doubt, the following are static and must not be read as
runtime facts:

| Static fact | Why it is not runtime evidence |
|---|---|
| ` Crane.dylib` creates 8 directories and sets `HOME` | The pseudocode says what it would do; nothing observed it |
| `unlink` of a `___Crane_Containers` path returns 0 | A transcription of a hook body, not an observed return value |
| Settings switches have the defaults in `Root.plist` | Declared defaults, not observed switch positions |
| Four `___Crane_Containers` hooks are registered | A call-graph fact, not evidence that any fired |
| A springboard alert is shown when libSandy is down | An alert class exists with the right properties; no alert was seen |
| `kCFCoreFoundationVersionNumber >= 1665.15` selects a branch | A compile-time-comparison fact, not an observation of which branch a device took |

## 4. The observation template

When device access becomes available, each observation is recorded with this
schema so it can be audited later. The table is intentionally empty.

| Observation ID | Test ID | Environment (device / iOS / jailbreak / Substrate impl) | Exact steps | Expected behaviour | Actual behaviour | Evidence path | Classification | Remaining uncertainty |
|---|---|---|---|---|---|---|---|---|
| — | — | — | — | — | — | — | — | — |

## 5. Ordering the first device session

If device access is granted, this is the order that yields the most
information per step, because each step either establishes that the basics work
or rules out a whole class of failure.

| Step | Question | Why first |
|---|---|---|
| 1 | Does `launchctl print system/com.opa334.cranehelperd` show the job? | The daemon is a prerequisite for 4 features; if it is not up, F-01 fails open and F-19 is dead |
| 2 | Is the package installed with the expected file set? | Establishes the packaging baseline; `dpkg -L` output is cheap and definitive |
| 3 | Does ` Crane.dylib` appear in an app's loaded images? | Distinguishes "installed" from "injected" — the distinction the project must never collapse |
| 4 | Does `HOME` inside a launched app equal the container? | The single highest-value observation: it exercises F-01 → F-02 end to end, and on this build it is **expected to fail** (D-04) |
| 5 | Is a Crane error alert visible when a daemon is unloaded? | F-20; also confirms the alert plumbing exists |
| 6 | Does the Settings pane render the recovered tree? | F-15; expected to partially fail (D-18) |
| 7 | Long-press a supported app icon | F-13; expected to fail entirely (D-08) |
| 8 | Create two containers, write distinct data, relaunch each | F-16/F-01 together; the closest available substitute for the differential test |

Steps 4, 6 and 7 are **expected to fail** on the current reconstruction. Running
them first is what converts the predictions in `final/KNOWN_DIFFERENCES.md` into
demonstrations.

## 6. Differential testing against the original

For a differential comparison to be meaningful, both builds must be installable
on the same device and driven through the same steps. That requires:

1. the **original `.deb`** — only its extracted payload tree exists here, and
   without `DEBIAN/control` and `postinst` (U-19) it cannot be rebuilt;
2. the **reconstruction's `.deb`** — no build has run;
3. a device both can be installed on, in sequence, with the container data from
   one removed before the other is measured.

Until all three exist, `DIFFERENTIAL_TEST_PASSED` cannot be assigned to any
requirement, and the acceptance matrix reflects that.