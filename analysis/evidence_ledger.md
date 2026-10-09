# Evidence Ledger

Every important claim, its evidence type, its location, and how to reproduce it.
Confidence uses the project's vocabulary. **No row is CONFIRMED_RUNTIME** —
see `analysis/runtime_observations.md`.

## 1. Package and layout

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-PKG-01 | The tree contains 77 non-export files, all with an assigned role | Static metadata | `analysis/package_inventory.md` | `python tools/make_manifest.py` | CONFIRMED_STATIC |
| E-PKG-02 | Every file's SHA-256 is recorded | Static metadata | `analysis/package_inventory.md` | `python tools/make_manifest.py` | CONFIRMED_STATIC |
| E-PKG-03 | Product = Crane 6.0 (build 1), `com.opa334.CraneApplication` | Package metadata | both app `Info.plist`, `CranePrefs.bundle/Info.plist` | `plistlib.load` | CONFIRMED_STATIC |
| E-PKG-04 | Author Lars Fröder (opa334), © 2020-2024 | Package metadata | `Root.plist` OTHER group footer | `plistlib.load` | CONFIRMED_STATIC |
| E-PKG-05 | This copy is a third-party redistribution ("Crack by Repo BVN") | Package metadata | `Root.plist` OTHER group | `plistlib.load`; `FOLLOW_ME_ON_TWITTER` still in the localization table | CONFIRMED_STATIC |
| E-PKG-06 | No `DEBIAN/control`, maintainer script, `.deb`, Makefile, Logos source, workflow, test, screenshot, or log exists | Direct inspection | whole tree | `tools/classify_files.py` | CONFIRMED_STATIC |
| E-PKG-07 | The main dylib and filter plist carry a leading space (U+0020) | Static metadata | character codes of the directory listing | `Get-ChildItem … NameHex` | CONFIRMED_STATIC |
| E-PKG-08 | The space is intentional: 4 references to the spaced name exist inside the binaries | IDA export | CraneSB 0x1FD74, CraneSupport 0x65EC, CranePrefs 0x3E364, `CHOICYLOADER_SUGGESTION_MESSAGE` | `grep` over `strings.txt` | CONFIRMED_STATIC |

## 2. Injection topology

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-INJ-01 | ` Crane.dylib` loads into every app (`Bundles=[com.apple.Foundation]`, `Flags=0`) | Package metadata | `Library/MobileSubstrate/DynamicLibraries/ Crane.plist` | `plistlib.load` | CONFIRMED_STATIC |
| E-INJ-02 | `CraneSB.dylib` loads into SpringBoard and runningboardd | Package metadata | `CraneSB.plist` | `plistlib.load` | CONFIRMED_STATIC |
| E-INJ-03 | `CraneSupport.dylib` loads into 7 daemons, `Flags=1` | Package metadata | `CraneSupport.plist` | `plistlib.load` | CONFIRMED_STATIC |
| E-INJ-04 | cranehelperd runs as root, `RunAtLoad`, `KeepAlive`, both safe-mode env vars, 2 Mach services | Package metadata | `Library/LaunchDaemons/com.opa334.cranehelperd.plist` | `plistlib.load` | CONFIRMED_STATIC |
| E-INJ-05 | Every sandboxed process is granted the cranehelperd Mach service; `libCrane.plist` also grants both prefs paths | Package metadata | `Library/libSandy/*.plist` | `plistlib.load` | CONFIRMED_STATIC |
| E-INJ-06 | `libSandy_works()` gates F-01: failure presents an alert and leaves the environment unchanged | Decompiled pseudocode | `CraneSupport…/decompile/1B45C.c` | read the file | CONFIRMED_STATIC |
| E-INJ-07 | `ignoredProcesses = @[@"watchdogd", @"com.apple.springboard"]` | Decompiled pseudocode | `CraneSupport…/decompile/6C5C.c` | read the file | CONFIRMED_STATIC |
| E-INJ-08 | Rootless support is explicit via libroot (`libroot_get_jbroot_prefix`, `libroot_jbrootpath`, `/var/jb`) | Decompiled pseudocode + strings | `CraneSB…/decompile/7A74.c`, `strings.txt` 0x21A3C | read the file; grep | CONFIRMED_STATIC |
| E-INJ-09 | The per-daemon dispatch table and its version gate (CF ≥ 1932.101) | Decompiled pseudocode | `CraneSupport…/decompile/6C5C.c` | read the file | CONFIRMED_STATIC |

## 3. Binaries

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-BIN-01 | 11 Mach-O binaries: 5 dylibs (fat arm64+arm64e), 6 executables (thin arm64) | Static metadata | `analysis/binary_inventory.md` | `python reconstruction/tools/verify_architectures.py .` | CONFIRMED_STATIC |
| E-BIN-02 | All 7 non-app binaries declare iOS 11.0 / SDK 14.5.0 via `LC_VERSION_MIN_IPHONEOS` | Static metadata | same | `tools/macho_inspect.py` LC parsing | CONFIRMED_STATIC |
| E-BIN-03 | Apps declare iOS 14.0/SDK 18.0 and iOS 12.0/SDK 17.4 via `LC_BUILD_VERSION` | Static metadata | both app `Info.plist`, `tools/macho_inspect.py` | same | CONFIRMED_STATIC |
| E-BIN-04 | No `@rpath`, no `LC_RPATH`, absolute install names only | Static metadata | `analysis/binary_inventory.md` §2 | `tools/macho_inspect.py` | CONFIRMED_STATIC |
| E-BIN-05 | All binaries are code-signed; no entitlements blob anywhere | Static metadata | `analysis/binary_inventory.md` §5 | `tools/macho_inspect.py` CS walker | CONFIRMED_STATIC |
| E-BIN-06 | All binaries are stripped; `exports.txt` holds only Substrate entry points and `OBJC_*` symbols | Static metadata | `analysis/symbols_and_selectors.md` §1 | read `exports.txt` | CONFIRMED_STATIC |
| E-BIN-07 | Hard non-system link dependencies: CydiaSubstrate, libsandy, libcrane, libbsm, AltList, Preferences | Static metadata | `analysis/binary_inventory.md` §3 | `tools/macho_inspect.py` | CONFIRMED_STATIC |
| E-BIN-08 | The legacy `CraneShortcuts` links libcrane + libsandy; the iOS 16+ one does not | Static metadata | `analysis/binary_inventory.md` §3 | same | CONFIRMED_STATIC |

## 4. IDA exports

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-IDB-01 | Each of the 5 exports is byte-identical in `__text` to the arm64 slice of the adjacent binary (100.000%), and matches the arm64e slice only 9–12% | Automated test output | `analysis/ida_export_coverage.md` | `python tools/prove_export_identity.py` | CONFIRMED_STATIC |
| E-IDB-02 | Therefore the exports are from the same binary version, arm64 slice | Inference from E-IDB-01 | same | same | CONFIRMED_STATIC |
| E-IDB-03 | All 5 exports are complete: 2651 declared = 2651 `decompile/*.c` = 2651 parsed records, all statuses `done` | Automated test output | `analysis/ida_export_coverage.md` | `python tools/build_export_index.py` | CONFIRMED_STATIC |
| E-IDB-04 | All byte differences between the dumps and the file are confined to `__bss`, `__common`, `__got`, `__la_symbol_ptr`, `__objc_classrefs`, `__objc_data`, `__cfstring`, `__const` — i.e. relocated regions; all `__TEXT` sections match 100% | Automated test output | `analysis/ida_export_coverage.md` | `python tools/section_diff.py` | CONFIRMED_STATIC |
| E-IDB-05 | `disassembly/` exists in all 5 export dirs but is empty | Direct inspection | `analysis/ida_export_coverage.md` §2 | `Get-ChildItem` | CONFIRMED_STATIC |
| E-IDB-06 | 6 binaries have no export: libcrane, cranehelperd, cranehelperd_start, the legacy app, both CraneShortcuts | Direct inspection | `analysis/environment_report.md` §5 | `Get-ChildItem -Directory *export_for_ai*` | CONFIRMED_STATIC |

## 5. Symbols, classes, hooks

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-SYM-01 | 2651 functions indexed with addresses, callers and callees | IDA export | `analysis/symbols_index.csv` (2651 rows), `callers_index.csv` (6485 rows) | `python tools/build_export_index.py` | CONFIRMED_STATIC |
| E-SYM-02 | 3667 strings indexed | IDA export | `analysis/strings_index.csv` | same | CONFIRMED_STATIC |
| E-SYM-03 | Classes recovered directly from `__objc_classlist`: CraneSB 5, CraneSupport 1, CranePrefs 34, cranehelperd 6, legacy CraneShortcuts 4; ` Crane.dylib`, libcrane, cranehelperd_start and the iOS 18 app have none | Static metadata | `analysis/objc_classes.json` | `python tools/objc_classes.py` | CONFIRMED_STATIC |
| E-SYM-04 | `cranehelperd` exposes 6 classes and 2 protocols (`CRHGlobalServiceProtocol`, `CRHPreferencesServiceProtocol`) | Static metadata | `analysis/class_and_method_map.md` §1 | same | CONFIRMED_STATIC |
| E-SYM-05 | `ClientContainerCache` is compiled twice with identical selectors (CraneSB 0x2CE18, CraneSupport 0x22B80) | Static metadata + IDA export | same | same; `objc_classes.json` | CONFIRMED_STATIC |
| E-SYM-06 | The `CraneManager` selector surface (≈70 selectors) recovered from `objc_msgSend` literals | IDA export | `analysis/symbols_and_selectors.md` §3a | `tools/crane_api.py` + `objc_msgSend` scan | CONFIRMED_STATIC |
| E-HOOK-01 | 162 hook registrations: 109 `MSHookMessageEx`, 2 `MSHookFunction` (+4 `SecItem*` + `_CFPrefsGetPathForTriplet` symbol pairs), 51 `class_addMethod`, plus the `HCHookFunctions` tables | Decompiled pseudocode | `analysis/hooks_index.csv` (159 rows), `analysis/hook_reconstruction.md` §7 | `python tools/extract_hooks.py` | CONFIRMED_STATIC |
| E-HOOK-02 | Per binary: CraneSB 113, CraneSupport 48, CranePrefs 1, main dylib 0 direct, app 0 | Decompiled pseudocode | `analysis/hooks_index.csv` | group by `binary` | CONFIRMED_STATIC |
| E-HOOK-03 | `crane_initSpringBoard` (0x17A14) registers 3 FBProcessManager hooks, 3 SBIconController hooks, 2 class_addMethod, 2 notification observers, and 3 init sub-groups, gated by `kCFCoreFoundationVersionNumber >= 1665.15` with an inverted branch | Decompiled pseudocode | `analysis/hook_reconstruction.md` §3 | read `decompile/17A14.c` | CONFIRMED_STATIC |
| E-HOOK-04 | `InitFunc_0`/`InitFunc_1`/`InitFunc_2` exist as `__mod_init_func` constructors at 0x9684 / 0x9E08 / 0x1BC70 | Decompiled pseudocode + Static metadata | same | read the files; `__DATA,__mod_init_func` = 24 bytes = 3 entries | CONFIRMED_STATIC |
| E-HOOK-05 | `Crane.dylib` registers `sandbox_container_path_for_pid` only when `CRANE_SPOOF_SANDBOX_LOOKUPS` is set, and 3–4 protection hooks only when `CRANE_PROTECT_CONTAINERS=1` | Decompiled pseudocode | `Crane…/decompile/65D0.c`, `7268.c` | read the files | CONFIRMED_STATIC |
| E-HOOK-06 | The 40 notification hooks' target classes are aliased in the decompilation | Decompiled pseudocode | `analysis/hook_reconstruction.md` §3, U-10 | read `decompile/CBEC.c` | UNKNOWN |

## 6. Configuration

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-CFG-01 | Prefs domain `com.opa334.craneprefs`, declared as `defaults` on all 8 switches | Package metadata | `Root.plist` | `plistlib.load` | CONFIRMED_STATIC |
| E-CFG-02 | 8 global switches with their defaults and `com.opa334.craneprefs/ReloadPrefs` | Package metadata | `Root.plist` | same | CONFIRMED_STATIC |
| E-CFG-03 | The global read path is `[[CraneManager sharedManager] preferenceValueForKey:key].boolValue` | Decompiled pseudocode | `CraneSB…/decompile/1ED64.c` + 6 siblings | read the files | CONFIRMED_STATIC |
| E-CFG-04 | Per-app keys read via `applicationSettingsForApplicationWithIdentifier:` with `objectForKeyedSubscript:` | Decompiled pseudocode | `CraneSB…/decompile/1B45C.c` | read the file | CONFIRMED_STATIC |
| E-CFG-05 | Container entries live under `Containers` as an array of dicts with `identifier` and `name` | Decompiled pseudocode | `CranePrefs…/decompile/8400.c`, `86A8.c`, `7F98.c` | read the files | CONFIRMED_STATIC |
| E-CFG-06 | The settings write path removes and re-adds itself as a CraneManager observer around each write | Decompiled pseudocode | `CranePrefs…/decompile/A7EC.c` | read the file | CONFIRMED_STATIC |
| E-CFG-07 | Per-app setting mutation fans out to unregister-notifications + reload for the affected switches | Decompiled pseudocode | `CranePrefs…/decompile/A224.c` | read the file | CONFIRMED_STATIC |
| E-CFG-08 | `notificationsSupportEnabled` is unset-or-true-gated for the notification row; the Game Center row is appended only when `separateSystemAccountsEnabled` is true | Decompiled pseudocode | `CranePrefs…/decompile/8D00.c` | read the file | CONFIRMED_STATIC |
| E-CFG-09 | 7 Darwin/local notification names | IDA export strings + pseudocode | `analysis/preference_schema.md` §2 | grep `strings.txt`, read `17A14.c` | CONFIRMED_STATIC |
| E-CFG-10 | Preference keys consumed by binaries but not declared in `Root.plist` | IDA export strings | `analysis/preference_schema.md` §1 | grep `strings.txt` | CONFIRMED_STATIC |

## 7. Behaviour

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-BHV-01 | `crane_applyEnvironmentChanges` sets `CRANE_CONTAINER_IDENTIFIER` and, gated, `CRANE_SPOOF_SANDBOX_LOOKUPS`; sets `CRANE_PROTECT_CONTAINERS=1` only in the DEFAULT container; fails open on libSandy-down or self-check-failure | Decompiled pseudocode | `CraneSB…/decompile/1B45C.c` | read the file | CONFIRMED_STATIC |
| E-BHV-02 | `crane_containerToRedirectTo` returns nil for unsupported apps and for `DEFAULT` | Decompiled pseudocode | `CraneSB…/decompile/1B360.c` | read the file | CONFIRMED_STATIC |
| E-BHV-03 | `Crane.dylib` `InitFunc_0` unsets all three `CRANE_*` vars, creates 8 directories, `setenv`s 3 vars with overwrite=1, and installs hooks in one batch | Decompiled pseudocode | `Crane…/decompile/65D0.c` | read the file | CONFIRMED_STATIC |
| E-BHV-04 | `new_unlink` returns 0 without calling the original on a match; the 3 enumeration hooks loop past matches | Decompiled pseudocode | `Crane…/decompile/721C.c`, `71C0.c`, `7140.c`, `70B0.c` | read the files | CONFIRMED_STATIC |
| E-BHV-05 | The sandbox-lookup hook calls the original first, then overwrites the buffer only for `getpid()`, and forwards the return value | Decompiled pseudocode | `Crane…/decompile/6564.c` | read the file | CONFIRMED_STATIC |
| E-BHV-06 | `requestAuthentication` invokes the handler immediately when biometrics are unavailable, and dispatches to the main queue only when the call was made on the main thread | Decompiled pseudocode | `Crane…/decompile/6E08.c`, `6F40.c` | read the files | CONFIRMED_STATIC |
| E-BHV-07 | `localize` falls back to the raw `en.lproj` table when `localizedStringForKey:` returns the key | Decompiled pseudocode | `Crane…/decompile/6924.c` | read the file | CONFIRMED_STATIC |
| E-BHV-08 | `containerPathForContainer` returns the base path for `DEFAULT` and `"%@/Library/___Crane_Containers/%@"` otherwise; nil in → nil out | Decompiled pseudocode | `Crane…/decompile/6B2C.c` | read the file | CONFIRMED_STATIC |
| E-BHV-09 | 204 localization keys in `en.lproj`; 10 languages total | Package metadata | `Library/Application Support/Crane.bundle/*/Localizable.strings` | `python tools/dump_strings.py` | CONFIRMED_STATIC |
| E-BHV-10 | The backup archive is ZIP-based (embedded `SSZipArchive`, `libz`, `libiconv`, member names `Info.plist` / `Metadata.plist` / `Keychain.plist`) | Decompiled pseudocode + Static metadata | `CranePrefs…/strings.txt`, `LC_LOAD_DYLIB` list | grep; `tools/macho_inspect.py` | CORROBORATED |
| E-BHV-11 | `initNoStartUsingiCloudHooks` is reachable from `initAccountsd` via `sub_76B8`, hooking the iOS follow-up controllers | Decompiled pseudocode + cross-reference | `CraneSupport…/decompile/76B8.c`, `7024.c`; `callers_index.csv` | read the files; grep the index | CONFIRMED_STATIC |
| E-BHV-12 | The launchd job sets `_MSSafeMode=1` and `_SafeMode=1`, so cranehelperd runs in safe mode | Package metadata | `com.opa334.cranehelperd.plist` | `plistlib.load` | CONFIRMED_STATIC |

## 8. Reconstruction-side verification

| Evidence ID | Claim | Type | Location | Reproduction | Confidence |
|---|---|---|---|---|---|
| E-REC-01 | 12 of 12 layout plists are semantically identical to the original | Automated test output | `reconstruction/layout/**` | `python tools/audit_consistency.py` | CONFIRMED_STATIC |
| E-REC-02 | 10 of 10 layout PNG assets are byte-identical | Automated test output | same | `Get-FileHash` comparison | CONFIRMED_STATIC |
| E-REC-03 | All 11 original binaries conform to the architecture rule the CI verifier enforces | Automated test output | `reconstruction/tools/verify_architectures.py` | `python reconstruction/tools/verify_architectures.py .` | CONFIRMED_STATIC |
| E-REC-04 | 17 of 2651 recovered functions are transcribed 1:1 into the reconstruction | Source inspection | `reconstruction/IMPLEMENTATION_STATUS.md` §3 | read the sources | CONFIRMED_STATIC |
| E-REC-05 | 5 of 23 features have a complete transcription; 9 partial; 9 absent | Source inspection | same §2 | same | CONFIRMED_STATIC |
| E-REC-06 | 84 cross-document consistency checks, all passing | Automated test output | `analysis/consistency_audit.txt` | `python tools/audit_consistency.py` | CONFIRMED_STATIC |
| E-REC-07 | Every `CR`-prefixed identifier in the reconstruction resolves; braces and parens balance in all 8 `.m` files | Automated test output | `reconstruction/sources/**` | `python tools/check_identifiers.py` | CONFIRMED_STATIC |

## 9. What has no evidence

| Item | Why | Where tracked |
|---|---|---|
| The cranehelperd XPC interface | no export for that binary | U-01 |
| The cfprefsd redirect condition | export exists, not read line by line | U-02 |
| The securityd patch's failure behaviour | export exists, not read line by line | U-03 |
| Container on-disk metadata format and identifier generation | no export for libcrane | U-04 |
| The selection-menu visual layout | needs a screenshot | U-05 |
| Backup archive/encryption/keychain formats | no export for libcrane/cranehelperd | U-06 |
| The app-bundle selection `postinst` | no `.deb` in the tree | U-19 (BLOCKED) |
| Every runtime behaviour | no device | `analysis/runtime_observations.md` |
| Every UI pixel | no screenshots | `tests/ui_comparison.md` |
| Every CI result | no run | `tests/ci_build_results.md` |