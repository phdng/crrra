# Environment Report

Status: CONFIRMED_STATIC unless stated otherwise.

## 1. Repository contents

The working directory contains **only an extracted iOS package payload tree**
plus the analysis artefacts created by this project. It is **not** a git
repository in its original state (`git init` was run by this analysis to allow
diffing; the tree had no `.git` before).

Present in the tree:

| Top-level | Contents |
|---|---|
| `Applications/` | `CraneApplication.app` (SDK 18 build) and `CraneApplication_Legacy.app` (SDK 17.4 build), each with a `CraneShortcuts.appex` |
| `Library/` | `MobileSubstrate/DynamicLibraries` (3 tweak dylibs + 3 filter plists), `PreferenceBundles/CranePrefs.bundle`, `PreferenceLoader/Preferences`, `Application Support/Crane.bundle` (UI assets + 10 localizations), `LaunchDaemons`, `libSandy` |
| `usr/` | `lib/libcrane.dylib`, `local/libexec/cranehelperd`, `local/bin/cranehelperd_start` |
| `*/<name>_export_for_ai/` | 5 IDA Pro export directories (inside the app bundle and the tweak directories) |
| `tools/` | Analysis scripts written by this project |
| `analysis/` | Reports and machine-readable indexes written by this project |

Absent — and therefore **UNKNOWN**, not merely unlisted:

- No `.deb` archive, no `DEBIAN/control`, no `preinst`/`postinst`/`prerm`
- No `Makefile`, `control`, `*.xm`, `.theos`, or any Logos/Objective-C source
- No `.github/` and **no GitHub Actions workflow**
- No test suite, no screenshots, no device logs, no crash reports
- No `original/` working copy, hash manifest, or extracted `.deb` tarball

**Consequence for Gate 0:** the project cannot be "build-ready" in the sense
the prompt assumes, because there is no existing build system to reuse and no
CI configuration to validate against. Both must be created from scratch, and
CI results cannot be claimed until an actual workflow run exists.

## 2. Package identity (from bundle metadata, not Debian control)

| Field | Value | Source |
|---|---|---|
| Product | Crane | `CranePrefs.bundle/Info.plist`, localization table |
| Bundle id | `com.opa334.CraneApplication` | `Applications/*/Info.plist` |
| Version | `CFBundleShortVersionString` 6.0, `CFBundleVersion` 1 | both app `Info.plist` |
| Author | Lars Fröder (opa334) — footer `© 2020-2024 Lars Fröder (opa334)` | `Root.plist` group footer |
| Shortcuts extension id | `com.opa334.CraneApplication.CraneShortcuts` | appex `Info.plist` |
| Helper daemon label | `com.opa334.cranehelperd` | `LaunchDaemons` plist |
| Prefs domain | `com.opa334.craneprefs` | `Root.plist` `defaults` key |
| Mach services | `com.opa334.cranehelperd.xpc`, `com.opa334.cranehelperd.preferences.xpc` | `LaunchDaemons` plist |

This copy is a **third-party redistribution**, not the upstream release:
`Root.plist` contains a `PSButtonCell` with label **"Crack by Repo BVN"** where
upstream ships "Follow me on Twitter" (`FOLLOW_ME_ON_TWITTER` is still present
in the localization table, and `openTwitter` is still the action name). No DRM
stripping or binary patching was detected: the core dylibs are
`CONFIRMED_STATIC`-consistent with their exports, and nothing in the export
byte-comparison indicates binary modification.

## 3. Build-relevant target configuration recovered from binaries

| Property | ` Crane.dylib` | `CraneSB.dylib` | `CraneSupport.dylib` | `CranePrefs` | `libcrane.dylib` | `cranehelperd` | `cranehelperd_start` | App (18) | App (legacy) |
|---|---|---|---|---|---|---|---|---|---|
| Type | MH_DYLIB | MH_DYLIB | MH_DYLIB | MH_DYLIB | MH_DYLIB | MH_EXECUTE | MH_EXECUTE | MH_EXECUTE | MH_EXECUTE |
| Slices | arm64 + arm64e | arm64 + arm64e | arm64 + arm64e | arm64 + arm64e | arm64 + arm64e | arm64 + arm64e | arm64 + arm64e | arm64 | arm64 |
| `LC_BUILD_VERSION` | **absent** | **absent** | **absent** | **absent** | **absent** | **absent** | **absent** | iOS 14.0 / SDK 18.0 | iOS 12.0 / SDK 17.4 |
| Install name | `/Library/MobileSubstrate/DynamicLibraries/Crane.dylib` | `.../CraneSB.dylib` | `.../CraneSupport.dylib` | `/Library/PreferenceBundles/CranePrefs.bundle/CranePrefs` | `/usr/lib/libcrane.dylib` | — | — | — | — |
| PIE flag | no | no | no | no | no | yes | yes | yes | yes |
| Code signature | yes (superblob) | yes | yes | yes | yes | yes | yes | yes | yes |

The three tweak dylibs, the settings bundle, and `libcrane.dylib` carry
`LC_VERSION_MIN_IPHONEOS` rather than `LC_BUILD_VERSION`, which is why the
`min_os`/`sdk` fields are `None` for them in the machine-readable inventory.
Reading that load command directly gives the real values:

| Binary | Load command | Minimum OS | SDK |
|---|---|---|---|
| ` Crane.dylib` | `LC_VERSION_MIN_IPHONEOS` | **11.0** | **14.5.0** |
| `CraneSB.dylib` | `LC_VERSION_MIN_IPHONEOS` | **11.0** | **14.5.0** |
| `CraneSupport.dylib` | `LC_VERSION_MIN_IPHONEOS` | **11.0** | **14.5.0** |
| `CranePrefs` | `LC_VERSION_MIN_IPHONEOS` | **11.0** | **14.5.0** |
| `libcrane.dylib` | `LC_VERSION_MIN_IPHONEOS` | **11.0** | **14.5.0** |
| `cranehelperd` | `LC_VERSION_MIN_IPHONEOS` | **11.0** | **14.5.0** |
| `cranehelperd_start` | `LC_VERSION_MIN_IPHONEOS` | **11.0** | **14.5.0** |
| `CraneApplication` (iOS 16+) | `LC_BUILD_VERSION` | 14.0 | 18.0 (16A242d) |
| `CraneApplication_Legacy` | `LC_BUILD_VERSION` | 12.0 | 17.4 (15E204a) |
| `CraneShortcuts` (iOS 16+) | `LC_BUILD_VERSION` | 14.0 | 18.0 |
| `CraneShortcuts` (legacy) | `LC_BUILD_VERSION` | 12.0 | 17.4 |

This resolves former uncertainty U-16. Note that all seven non-app binaries were
built against an **older SDK (14.5)** than either app build, which is consistent
with a single tweak source tree and two separately-built app targets.

No `@rpath`, `LC_LOAD_DYLIB` of a Rockbox-style prefix, or `-install_name`
rewrite was found; install names are absolute.

The `CranePrefs` binary links `/Library/Frameworks/AltList.framework/AltList`
and `/System/Library/PrivateFrameworks/Preferences.framework/Preferences`,
so a reconstruction **must** bundle AltList and depend on Preferences.

## 4. Local analysis toolchain actually available

| Tool | Status | Version / path |
|---|---|---|
| Python | available | 3.13.2, `C:\Python313\python.exe` |
| git | available | `C:\Program Files\Git\cmd\git.exe` |
| node | available | `C:\Program Files\nodejs\node.exe` |
| `gh` (GitHub CLI) | **not available** | — |
| `otool`, `llvm-objdump`, `nm`, `strings`, `ar`, `dpkg-deb`, `7z` | **not available** | — |
| Theos / Logos / iOS SDK | **not available** | — |
| IDA Pro, Ghidra, Hopper, radare2, LLDB | **not available** | — |

Because no Apple or LLVM binutils are present, the Mach-O reading in this
project is done by `tools/macho_inspect.py` (load commands, fat slices,
segments, sections, UUID, code signature, entitlements) and
`tools/objc_classes.py` (`__objc_classlist` → `class_ro_t` → method lists,
with relative and absolute IMP layouts). These parsers were validated against
every class in every inspected binary and against the IDA exports (see
`analysis/ida_export_coverage.md`).

**Practical consequences, recorded as limitations:**

- Objective-C **type encodings** are only recovered where they live in
  `__TEXT,__objc_methtype`; many entries have `types: null`.
- Local symbols are stripped (`exports.txt` lists only the few exported entry
  points plus `InitFunc_N` module constructors), so function *names* for most
  of the 2651 indexed functions come from IDA, not from the binary.
- No disassembly is generated locally; the exports' `decompile/*.c` files are
  the disassembly substitute and they cover 100% of IDA's declared functions.

## 5. IDA Pro exports: inventory and identity

Five export directories exist. Format is identical in all of them:

```
<name>_export_for_ai/
  .export_progress        address|status per IDA function (all "done")
  exports.txt             exported symbol addresses (usually just 2-3)
  function_index.txt      declared total, then per-function:
                            Function / Address / File / Type
                            Called by (n): ... Calls (n): ...
  imports.txt             imported symbol addresses
  strings.txt             address | length | type | string
  pointers.txt            source | segment | target | name | type | detail
  memory/START--END.txt   hex + ASCII dump of the analyzed image
  decompile/ADDR.c        Hex-Rays pseudocode with a header comment
  disassembly/            present as an empty directory
```

| Export dir | Host binary | Functions exported | `.c` files | `__text` bytes matched |
|---|---|---:|---:|---|
| ` Crane.dylib_export_for_ai` | `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` | 68 | 68 | 5020/5020 (100.000%) |
| `CraneSB.dylib_export_for_ai` | `.../CraneSB.dylib` | 538 | 538 | 104212/104212 (100.000%) |
| `CraneSupport.dylib_export_for_ai` | `.../CraneSupport.dylib` | 624 | 624 | 87048/87048 (100.000%) |
| `CranePrefs_export_for_ai` | `Library/PreferenceBundles/CranePrefs.bundle/CranePrefs` | 1368 | 1368 | 233000/233000 (100.000%) |
| `CraneApplication_export_for_ai` | `Applications/CraneApplication.app/CraneApplication` | 53 | 53 | 1620/1620 (100.000%) |

The `__text` match column is the identity proof described in
`analysis/ida_export_coverage.md`. All five exports correspond to the **same
binary version** as the files in this tree and to the **arm64** slice
(`cpusubtype 0`); the arm64e slice matches only 9–12% and is rejected.

Binaries **without** any export directory:

| Binary | Size | Notes |
|---|---:|---|
| `usr/lib/libcrane.dylib` | 339216 | The shared `CraneManager` API; core behaviour lives here |
| `usr/local/libexec/cranehelperd` | 117616 | Daemon: `CRHGlobalService`, `CRHPreferencesService`, `CRHKeychain` |
| `usr/local/bin/cranehelperd_start` | 69616 | Daemon restarter |
| `Applications/CraneApplication_Legacy.app/CraneApplication` | 52976 | Legacy app build |
| both `CraneShortcuts.appex/CraneShortcuts` | 91584 / 54864 | Shortcuts extension |
| `Applications/*/Assets.car` | 173871 / 165576 | Compiled asset catalogs |
| `Applications/*/Base.lproj/Intents.intentdefinition` | 39382 / 5817 | App Intents definitions |

This is the single largest analysis blind spot: `libcrane.dylib` implements
the container registry, backup/restore, keychain handling, and the XPC client,
and it has **no decompiler output** in this repository. Its public selector
surface was recovered from `__objc_methname` (`analysis/crane_api_symbols.csv`)
and cross-referenced with `objc_msgSend` selector literals in the exported
binaries, which pins the API *shape* but not its implementation.

## 6. Build environment

- **GitHub Actions: NOT AVAILABLE.** `gh` is not installed, there is no
  `.github/` directory, and no repository remote exists. No CI run has been
  triggered, and none can be from this environment.
- A workflow **can** be authored (see `reconstruction/.github/`), but a green
  build is `NOT_TESTED` until the user pushes a remote and a run completes.

## 7. Device testing boundary

No device access, no logs, no screenshots, no crash reports, and no record of
the user's install/test workflow are present in this repository. Runtime
behaviour is therefore **UNKNOWN** for every feature except where this project
performed static analysis. All runtime status fields in
`final/ACCEPTANCE_MATRIX.md` are `NOT_TESTED` or `BLOCKED`.

## 8. Gate 0 assessment

| Requirement | Status | Note |
|---|---|---|
| Existing repository understood | PASS | It is a payload tree, not a source project |
| CI pipeline understood | FAIL | No pipeline exists |
| Packaging requirements understood | PARTIAL | Layout and filters recovered; Debian metadata absent |
| IDA export coverage understood | PASS | 5/5 exports mapped and byte-verified |
| Toolchain available for analysis | PASS | Custom parsers written and validated |
| Toolchain available for building | FAIL | No Theos/SDK locally; CI would be the only route |
| Device runtime evidence | BLOCKED | Not accessible from this environment |

Gate 0 is **not** passed for building. Static analysis is complete enough to
write a behavioural specification and to begin implementation.