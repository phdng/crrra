# Binary Inventory

Generated from `tools/macho_inspect.py` + `tools/binary_inventory.py` against the
package tree. All values CONFIRMED_STATIC.

## 1. Executable binaries

| Path | Bytes | Type | Slices | UUID (slice 0) | Min OS | SDK | PIE |
|---|---:|---|---|---|---|---|---|
| `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` | 136752 | MH_DYLIB | arm64 + arm64e | `a222ac90-27f6-3fca-b8be-7fd4561df577` | 11.0 | 14.5.0 | no |
| `Library/MobileSubstrate/DynamicLibraries/CraneSB.dylib` | 479088 | MH_DYLIB | arm64 + arm64e | `6e732c16-8065-3ba0-aa73-0454d9fe1ce7` | 11.0 | 14.5.0 | no |
| `Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib` | 395136 | MH_DYLIB | arm64 + arm64e | `a1f4f544-d5f2-3f58-952c-9fe38883915e` | 11.0 | 14.5.0 | no |
| `Library/PreferenceBundles/CranePrefs.bundle/CranePrefs` | 896896 | MH_DYLIB | arm64 + arm64e | `a265f862-7754-3217-9868-6b51073fc662` | 11.0 | 14.5.0 | no |
| `usr/lib/libcrane.dylib` | 339216 | MH_DYLIB | arm64 + arm64e | `2d0e6b2f-7cc4-33b7-aa63-54d9caf75f7f` | 11.0 | 14.5.0 | no |
| `usr/local/libexec/cranehelperd` | 117616 | MH_EXECUTE | arm64 | `79bf292a-4eab-31c9-b9ee-3c38ac0e7482` | 11.0 | 14.5.0 | yes |
| `usr/local/bin/cranehelperd_start` | 69616 | MH_EXECUTE | arm64 | `573d6351-1e41-310f-9041-85d25bedf83c` | 11.0 | 14.5.0 | yes |
| `Applications/CraneApplication.app/CraneApplication` | 70160 | MH_EXECUTE | arm64 | `6abe3d9b-4dfc-3d32-8cf7-452320484259` | 14.0 | 18.0 | yes |
| `Applications/CraneApplication.app/PlugIns/CraneShortcuts.appex/CraneShortcuts` | 91584 | MH_EXECUTE | arm64 | `596f10f0-008b-3912-b613-24960cfe8c96` | 14.0 | 18.0 | yes |
| `Applications/CraneApplication_Legacy.app/CraneApplication` | 52976 | MH_EXECUTE | arm64 | `6757e554-8567-334a-8558-dfd343cad30a` | 12.0 | 17.4 | yes |
| `Applications/CraneApplication_Legacy.app/PlugIns/CraneShortcuts.appex/CraneShortcuts` | 54864 | MH_EXECUTE | arm64 | `84d43b4f-1aef-3163-b59c-76c093f2750c` | 12.0 | 17.4 | yes |

**Note on min-OS/sdk:** the five dylibs and the two daemon binaries carry
`LC_VERSION_MIN_IPHONEOS` (not `LC_BUILD_VERSION`), which is why a naive parser
reports `None`. Reading that load command gives **11.0 / SDK 14.5.0** for all
seven — they were built against an older SDK than the apps, which ship 18.0 and
17.4 respectively. Xcode builds: `16A242d` (iOS 18) and `15E204a` (legacy).

**Note on slices:** every *dylib* is fat `arm64 + arm64e`. Every *executable* is
thin `arm64`. `reconstruction/tools/verify_architectures.py` encodes exactly this
rule and CI runs it against the built package.

## 2. Install names

| Binary | `LC_ID_DYLIB` |
|---|---|
| ` Crane.dylib` | `/Library/MobileSubstrate/DynamicLibraries/Crane.dylib` |
| `CraneSB.dylib` | `/Library/MobileSubstrate/DynamicLibraries/CraneSB.dylib` |
| `CraneSupport.dylib` | `/Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib` |
| `CranePrefs` | `/Library/PreferenceBundles/CranePrefs.bundle/CranePrefs` |
| `libcrane.dylib` | `/usr/lib/libcrane.dylib` |

**No `@rpath`, no `LC_RPATH`, no `-install_name` rewriting** on any binary. Every
non-system dependency is referenced by absolute path, which is why the package
depends on `libsandy` and `firmware` (for `AltList.framework`).

**The leading-space anomaly:** ` Crane.dylib`'s *install name* has no space, but
the *installed filename* and the filter plist name both begin with U+0020. Four
independent references to the spaced name exist inside the binaries
(`CraneSB` 0x1FD74, `CraneSupport` 0x65EC, `CranePrefs` 0x3E364, plus the
`CHOICYLOADER_SUGGESTION_MESSAGE` localization text). This is intentional
upstream and is reproduced by the reconstruction's build.

## 3. Linked libraries

### ` Crane.dylib`
`libobjc.A.dylib`, `Foundation`, `CoreFoundation`, `CydiaSubstrate`,
`libc++.1.dylib`, `libSystem.B.dylib`, `LocalAuthentication`

### `CraneSB.dylib`
`libobjc.A.dylib`, `Foundation`, `CoreFoundation`, **`libsandy.dylib`**,
**`libcrane.dylib`**, `BackBoardServices`, `AppSupport`, `MobileCoreServices`,
`libc++.1.dylib`, `libSystem.B.dylib`, `CydiaSubstrate`, `LocalAuthentication`,
`UIKit`

### `CraneSupport.dylib`
`libobjc.A.dylib`, `Foundation`, `CoreFoundation`, `Security`, **`libsandy.dylib`**,
**`libbsm.0.dylib`**, **`libcrane.dylib`**, `AppSupport`, `libc++.1.dylib`,
`libSystem.B.dylib`, `CydiaSubstrate`, `CoreData`, `LocalAuthentication`

### `CranePrefs`
`libobjc.A.dylib`, `Foundation`, `CoreFoundation`, `UIKit`, `Security`,
`MobileCoreServices`, `libz.1.dylib`, `libiconv.2.dylib`, **`libcrane.dylib`**,
`Preferences`, `AppSupport`, **`AltList`**, `libc++.1.dylib`, `libSystem.B.dylib`,
`CoreGraphics`, `LocalAuthentication`

### `libcrane.dylib`
`libobjc.A.dylib`, `Foundation`, `CoreFoundation`, **`libsandy.dylib`**,
`CydiaSubstrate`, `libc++.1.dylib`, `libSystem.B.dylib`, `LocalAuthentication`

### `cranehelperd`
`libobjc.A.dylib`, `Foundation`, `CoreFoundation`, `BackBoardServices`,
`MobileCoreServices`, `CydiaSubstrate`, `libc++.1.dylib`, `libSystem.B.dylib`,
`Security`

### `cranehelperd_start`
`libobjc.A.dylib`, `Foundation`, `CoreFoundation`, `libc++.1.dylib`,
`libSystem.B.dylib`

### `CraneApplication` (iOS 16+ build)
`Foundation`, `libobjc.A.dylib`, `libSystem.B.dylib`, `CoreFoundation`,
`Intents`, `UIKit` — **no Crane libraries**

### `CraneShortcuts.appex`
- iOS 16+ build: `Intents`, `Foundation`, `libobjc.A.dylib`, `libSystem.B.dylib`,
  `CoreFoundation` — no Crane libraries
- legacy build: adds **`libcrane.dylib`** and **`libsandy.dylib`**

The asymmetry between the two extension builds is real and is preserved in the
reconstruction's design (the legacy path goes through `CraneManager`, the modern
path through its own `CraneIntentHandlerShared`).

## 4. Hard build requirements for a reconstruction

Anything linked above that is not an iOS system framework must be provided by
another package:

| Dependency | Provided by | Needed by |
|---|---|---|
| `CydiaSubstrate` | `mobilesubstrate` | all 5 dylibs + `cranehelperd` |
| `libsandy.dylib` | `libhooker`/`libsandy` (libSandy) | `CraneSB`, `CraneSupport`, `libcrane`, legacy `CraneShortcuts` |
| `libcrane.dylib` | this package | `CraneSB`, `CraneSupport`, `CranePrefs`, legacy `CraneShortcuts` |
| `libbsm.0.dylib` | `firmware` | `CraneSupport` (keychain access-group rewriting) |
| `AltList.framework` | `firmware` | `CranePrefs` |
| `Preferences.framework` | system | `CranePrefs` |
| `libactivator.dylib` | `activator` | optional, probed at runtime by `CraneSB` |
| `ChoicyLoader.dylib` / `ChoicySB.dylib` | `choicy` | optional, probed at runtime |

The reconstructed `control` file lists `mobilesubstrate, ellekit, libhooker,
firmware, altlist, activator, choicy`.

## 5. Code signing and entitlements

All 11 binaries carry an `LC_CODE_SIGNATURE` superblob. Entitlements blobs
(`0xFADE7171`) were searched for and **none were found** — consistent with
jailbreak re-signing rather than a developer-signed build. Signature sizes:

| Binary | Signature offset | Size |
|---|---:|---:|
| ` Crane.dylib` | 0xD470 / 0xD300 | 0x330 |
| `CraneSB.dylib` | 0x34CC0 / 0x34AE0 | 0x810 |
| `CraneSupport.dylib` | 0x2C530 / 0x2C440 | 0x720 |
| `CranePrefs` | 0x6AB00 / 0x6A940 | 0xED0 |
| `libcrane.dylib` | 0x26B20 / 0x26A90 | 0x650 |
| `cranehelperd` | 0x18140 | 0xAA0 |
| `cranehelperd_start` | 0xCB60 | 0x550 |
| both apps, both appexes | — | 0x400–0x9E0 |

**Consequence:** a rebuild produces different signature bytes. This is expected
and is recorded as U-20; it does not affect behaviour but it does mean the
`SHA-256` of a reconstructed binary will never match the original.

## 6. Stripping

All binaries are stripped. `exports.txt` contains only what Theos/Substrate
needs to resolve: the exported entry points, `OBJC_CLASS_$` / `OBJC_METACLASS_$`
symbols another binary must link against, and the `__mod_init_func`
constructors named `InitFunc_0` … `InitFunc_2`. Function *names* for the other
2651 IDA-exported functions come from the decompiler, not from the binary.

## 7. Binaries with no IDA export

| Binary | What is missing as a result |
|---|---|
| `usr/lib/libcrane.dylib` | Container registry implementation, container-identifier generation, on-disk metadata format, XPC client |
| `usr/local/libexec/cranehelperd` | The XPC interface, service implementations, keychain operations |
| `usr/local/bin/cranehelperd_start` | Everything (only the path is recovered) |
| `Applications/CraneApplication_Legacy.app/CraneApplication` | The legacy app's intent handling |
| both `CraneShortcuts.appex/CraneShortcuts` | `CraneIntentHandlerShared`, intent handlers |
| both `Assets.car` | Compiled image assets (the standalone `Icons/*.png` are present as loose files) |
| both `Intents.intentdefinition` | Present as XML and readable |

This is the dominant analysis limitation and is quantified in
`analysis/environment_report.md` §5 and tracked as U-01/U-04/U-06/U-08.