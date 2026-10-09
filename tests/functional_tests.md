# Functional Tests

Test plan derived from `analysis/behavior_specification.md`. Every test is
`NOT_TESTED` — no device and no artifact exists. The value of this file is that
each test is specified precisely enough to execute without re-deriving intent.

## Static tests (executed during analysis)

These required no device and were run. Their results are real.

| Test ID | What it checks | Method | Result |
|---|---|---|---|
| S-01 | Each IDA export came from the binary it sits next to, same version, arm64 slice | `tools/prove_export_identity.py` — byte-compare `memory/*.txt` against each fat slice's segment map | **PASS** — 5/5 exports, `__text` 100.000% on arm64, 9–12% on arm64e |
| S-02 | IDA export completeness | `.export_progress` statuses vs `# Total exported:` vs `decompile/*.c` count | **PASS** — 2651 declared = 2651 files, all `done`, 0 `fallback`/`failed`/`skipped` |
| S-03 | Original package inventory is complete and hashed | `tools/make_manifest.py` | **PASS** — 77 non-export files, every one with a role |
| S-04 | Every layout plist in the reconstruction is semantically identical to the original | `plistlib` round-trip comparison, 12 files | **PASS** — 12/12 |
| S-05 | Layout assets are byte-identical to the original artwork | `shutil.copy2`, then hash comparison | **PASS** — 10 PNGs |
| S-06 | Every binary's slice layout matches the original rule | `reconstruction/tools/verify_architectures.py` | **PASS** — 11/11 (5 dylibs `arm64+arm64e`, 6 executables thin `arm64`) |
| S-07 | Hook inventory is complete | `tools/extract_hooks.py` over 2651 decompiled functions | **PASS** — 162 registrations catalogued |
| S-08 | Preference keys are consistent across plists and binaries | `tools/pref_schema.py`, `tools/pref_access.py` | **PASS** — 31 plist cells + 14 accessor sites cross-checked |

## Runtime tests (specification only)

Grouped by feature. `T-Fxx-n` matches `analysis/behavior_specification.md`.

### F-01 Launch redirection

| ID | Precondition | Steps | Expected | Status |
|---|---|---|---|---|
| T-F01-1 | app supported, protection off, container = DEFAULT | launch from SpringBoard; inspect the app's environment | no `CRANE_*` variable present | NOT_TESTED |
| T-F01-2 | protection on, container = DEFAULT | same | `CRANE_PROTECT_CONTAINERS=1`, no `CRANE_CONTAINER_IDENTIFIER` | NOT_TESTED |
| T-F01-3 | container = X, spoofing off | same | `CRANE_CONTAINER_IDENTIFIER=X`, no `CRANE_SPOOF_SANDBOX_LOOKUPS` | NOT_TESTED |
| T-F01-4 | container = X, spoofing on | same | both variables present | NOT_TESTED |
| T-F01-5 | cranehelperd unreachable | same | alert shown; environment unchanged; app runs normally | NOT_TESTED |
| T-F01-6 | libSandy not running | same | `LIBSANDY_NOT_WORKING_ERROR_MESSAGE`; environment unchanged | NOT_TESTED |
| T-F01-7 | app not supported by Crane | same | environment byte-identical to stock | NOT_TESTED |

### F-02 In-app environment and directory preparation

| ID | Steps | Expected | Status |
|---|---|---|---|
| T-F02-1 | launch with `CRANE_CONTAINER_IDENTIFIER=X` | `<base>/Library/___Crane_Containers/X` plus `tmp`, `Library`, `Library/Caches`, `Library/Preferences`, `Library/SplashBoard`, `Documents`, `SystemData` all exist | NOT_TESTED |
| T-F02-2 | inspect `environ` from inside the app | no variable starting with `CRANE_` remains | NOT_TESTED |
| T-F02-3 | `HOME` / `CFFIXED_USER_HOME` / `TMPDIR` | equal to the container, container, and `<container>/tmp` respectively | NOT_TESTED |
| T-F02-4 | launch with none of the three variables | no directories created, no hooks installed | NOT_TESTED |

### F-03 Container isolation

| ID | Steps | Expected | Status |
|---|---|---|---|
| T-F03-1 | from a default-container app, `unlink("/…/Library/___Crane_Containers/A")` | returns 0, directory still present | NOT_TESTED |
| T-F03-2 | `unlink` of an unrelated path | succeeds normally | NOT_TESTED |
| T-F03-3 | `readdir` over the container root | never yields an entry containing `___Crane_Containers` | NOT_TESTED |
| T-F03-4 | `readdir_r` | same | NOT_TESTED |
| T-F03-5 | enumerate URLs via `NSFileManager`/`NSURL` | Crane containers not enumerated | NOT_TESTED |
| T-F03-6 | protection off | all four hooks absent; `unlink` of a container path succeeds | NOT_TESTED |

### F-04 Sandbox-lookup spoofing

| ID | Steps | Expected | Status |
|---|---|---|---|
| T-F04-1 | from a non-default container, self `sandbox_container_path_for_pid` | returns the container path | NOT_TESTED |
| T-F04-2 | same, for another pid | unchanged from stock | NOT_TESTED |
| T-F04-3 | return value of both cases | forwarded unchanged | NOT_TESTED |
| T-F04-4 | spoofing off | hook absent | NOT_TESTED |

### F-05 to F-12 System redirection

All `NOT_TESTED`, and per `final/KNOWN_DIFFERENCES.md` D-05/D-06/D-07, T-F05-1,
T-F07-1, T-F08-2, T-F09-1, T-F11-1, T-F12-1 are expected to FAIL on this
reconstruction. They are retained so a future implementation can be held to them.

| ID | Feature | Expected |
|---|---|---|
| T-F05-1 | F-05 | prefs written in container A are invisible in B |
| T-F05-2 | F-05 | the default container's prefs path is unchanged |
| T-F05-3 | F-05 | unsupported apps are unaffected |
| T-F06-1 | F-06 | `NSHomeDirectory()` resolves to the active container |
| T-F06-2 | F-06 | two containers of one app have disjoint App Group paths |
| T-F07-1 | F-07 | a keychain item written in A is not visible in B |
| T-F07-2 | F-07 | ignore-listed access groups stay shared |
| T-F07-3 | F-07 | securityd keeps working after the patch (no crash) |
| T-F08-1 | F-08 | support off → tokens shared |
| T-F08-2 | F-08 | support on → one token per container |
| T-F08-3 | F-08 | tapping a notification for A launches the app into A |
| T-F08-4 | F-08 | per-container notification disable stops only that container |
| T-F09-1 | F-09 | toggling Separate System Accounts changes the visible account after restart |
| T-F09-2 | F-09 | the Game Center row appears only when it is enabled |
| T-F10-1 | F-10 | two containers can hold two different Game Center accounts |
| T-F10-2 | F-10 | the Game Center switch is hidden when Separate System Accounts is off |
| T-F11-1 | F-11 | two containers report different device identifiers |
| T-F11-2 | F-11 | a custom identifier survives container selection changes |
| T-F11-3 | F-11 | the default container's identifier persists with Crane unloaded |
| T-F12-1 | F-12 | a container's notification extension is visible only there |
| T-F12-2 | F-12 | the alert appears when pkd lacks CraneSupport |

### F-13 Container selection UI

| ID | Steps | Expected | Status |
|---|---|---|---|
| T-F13-1 | long-press a supported app icon | container submenu appears | NOT_TESTED — expected FAIL (D-08) |
| T-F13-2 | select a container, relaunch | the app shows that container's data | NOT_TESTED |
| T-F13-3 | toggle each of the 5 global switches | the menu changes accordingly | NOT_TESTED |
| T-F13-4 | run on OS versions exposing each recovered `UIMenu` initializer family | both initializer variants handled without crashing | NOT_TESTED |
| T-F13-5 | select "New Container" | a container is created and selected | NOT_TESTED |

### F-14 to F-19

| ID | Feature | Expected | Status |
|---|---|---|---|
| T-F14-1 | F-14 | badge counts tracked per container | NOT_TESTED |
| T-F14-2 | F-14 | switching container updates the icon badge | NOT_TESTED |
| T-F14-3 | F-14 | the badge row is hidden when the global switch is off | NOT_TESTED |
| T-F15-1 | F-15 | every row in the recovered tree appears with the same default state | NOT_TESTED |
| T-F15-2 | F-15 | Game Center row hidden unless Separate System Accounts | NOT_TESTED |
| T-F15-3 | F-15 | notification row hidden when `notificationsSupportEnabled` is explicitly false | NOT_TESTED |
| T-F15-4 | F-15 | rename / delete / reorder round-trips | NOT_TESTED |
| T-F16-1 | F-16 | create → rename → delete round-trips | NOT_TESTED |
| T-F16-2 | F-16 | delete asks for confirmation and is irreversible | NOT_TESTED |
| T-F16-3 | F-16 | App Group data is per container | NOT_TESTED |
| T-F17-1 | F-17 | backup → restore round-trips in-container | NOT_TESTED |
| T-F17-2 | F-17 | an encrypted backup refuses to restore without the password | NOT_TESTED |
| T-F17-3 | F-17 | a wrong password reports `PREVIOUS_PASSWORD_WRONG_MESSAGE` | NOT_TESTED |
| T-F17-4 | F-17 | a backup from another app is rejected with `APP_ID_MISMATCH_ERROR` | NOT_TESTED |
| T-F17-5 | F-17 | multi-container backup/restore succeeds for installed apps | NOT_TESTED |
| T-F18-1 | F-18 | the biometric success handler runs on the main thread | NOT_TESTED |
| T-F18-2 | F-18 | the handler still runs when biometrics are unavailable | NOT_TESTED |
| T-F19-1 | F-19 | the daemon runs and is reachable from SpringBoard | NOT_TESTED |
| T-F19-2 | F-19 | `cranehelperdConnectionWorks` is true | NOT_TESTED |
| T-F19-3 | F-19 | a keychain dump/restore round-trips | NOT_TESTED |
| T-F19-4 | F-19 | the daemon runs in safe mode | NOT_TESTED |

### F-20 to F-23

| ID | Feature | Expected | Status |
|---|---|---|---|
| T-F20-1 | F-20 | disabling Crane for one app shows `CRANE_DYLIB_NOT_LOADED_ERROR` | NOT_TESTED |
| T-F20-2 | F-20 | stopping the daemon shows `CRANEHELPERD_COMMUNICATION_WARNING` | NOT_TESTED |
| T-F21-1 | F-21 | with the overwrite enabled, Crane cannot be disabled for a supported app | NOT_TESTED |
| T-F21-2 | F-21 | with it disabled, Choicy can disable Crane and the alert appears | NOT_TESTED |
| T-F22-1 | F-22 | the Set-Active-Container shortcut sets the active container | NOT_TESTED |
| T-F22-2 | F-22 | the app appears under Apps → Crane in Shortcuts | NOT_TESTED |
| T-F23-1 | F-23 | an activator action sets the active container | NOT_TESTED |
| T-F23-2 | F-23 | without Activator installed, SpringBoard still starts normally | NOT_TESTED |

## Totals

| Category | Count | Passing |
|---|---:|---:|
| Static tests (executed) | 8 | **8** |
| Runtime tests (specified) | 76 | **0** |
| Runtime tests expected to fail on this build by static analysis | 9 | n/a |