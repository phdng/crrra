# Build and Install

Everything below is written from what was actually verified. Where a step was
not executed, it says so.

## 1. Prerequisites

### For building (CI only)

| Requirement | Why | Where it comes from |
|---|---|---|
| GitHub Actions runner `macos-14` | Xcode + Theos toolchain | `.github/workflows/build.yml` |
| `waruhachi/theos-action@v2.6.3` | installs Theos, SDKs and AltList for the workflow | same |
| An iOS SDK with `arm64` and `arm64e` | the original dylibs are fat arm64+arm64e | `analysis/binary_inventory.md` §1 |
| An iOS SDK providing `AltList.framework`, `Preferences.framework`, `BackBoardServices`, `MobileCoreServices`, `CoreData` | linked by the originals | `analysis/binary_inventory.md` §3 |

There is no local build path in this environment: no macOS, no Xcode, no Theos,
no iOS SDK. `make package` has therefore **never been executed here.**

### For installing (device)

| Requirement | Source |
|---|---|
| A jailbreak with MobileSubstrate or ElleKit | `CydiaSubstrate` is linked by 5 of the 6 reconstructed components |
| `libhooker` / libSandy | `libsandy.dylib` is linked by 4 components and `libSandy_works()` gates F-01 |
| `firmware` (provides `AltList.framework` and `libbsm.0.dylib`) | hard link dependencies |
| `altlist` | `CranePrefs` links `AltList` |
| A rootful or rootless jailbreak | both handled; rootless via libroot's `$JBROOT` (U-12, CONFIRMED_STATIC) |

`activator` and `choicy` are **optional** in the original (probed with `dlopen`,
degrading gracefully). The reconstructed `control` lists them as dependencies
anyway — a deliberate simplification recorded as D-14.

## 2. Repository setup

```
.github/workflows/build.yml        authoritative GitHub Actions build
reconstruction/
  Makefile                     master: 7 subprojects + after-stage filename fix
  control                      Debian metadata
  sources/
    common/                    CRPaths.h CRPreferences.h CRManager.h CRCommon.{h,m}
    maindylib/                 " Crane.dylib"   (Makefile, CRMainDylib.m)
    libcrane/                  libcrane.dylib  (Makefile) + ../libcrane/CRManager.m
    cranehelperd/              cranehelperd    (Makefile, CRHelperd.m)
    cranehelperd_start/        cranehelperd_start (Makefile, cranehelperd_start.m)
    cranesb/                   CraneSB.dylib   (Makefile, CRSpringBoard.m)
    support/                   CraneSupport.dylib (Makefile, CRSupport.m)
    prefs/                     CranePrefs      (Makefile) + ../prefs/CRPreferences.m
  layout/                      12 plists + 10 assets, verified identical to the original
  tools/verify_architectures.py  Mach-O slice rule check (runs in CI)
  tools/verify_package_layout.py recovered layout + compiled-artifact check
```

## 3. Building

### In CI (the authoritative path)

1. Push the repository to a GitHub remote. **No push has been made from this
   environment and no remote exists**, so no run ID exists.
2. The `build` job runs: checkout → install/record the toolchain →
   `make clean package FINALPACKAGE=1` → unpack the `.deb` → verify all 23
   recovered layout files plus 7 compiled artifacts → verify architectures →
   upload artifacts.
3. Artifacts: `build-log` (always) and `crane-reconstruction-package` (`.deb` +
   `pkg.manifest.sha256` + `deb.sha256`).

Record the results in `tests/ci_build_results.md` §5, which has a blank form for
run ID, commit SHA, Xcode version, `.deb` SHA-256 and the verification counts.

### Locally (untested; requires macOS)

```sh
git clone <remote> crane
cd crane/reconstruction
export THEOS=/opt/theos
make package            # builds 7 targets and stages the recovered layout
make stage              # prints the staged file list
```

`make stage` prints exactly what will be installed, which is the quickest way to
confirm the layout without unpacking a `.deb`.

### Expected build risks

Stated in `tests/ci_build_results.md` §4. The three most likely first-run
failures, in order of likelihood:

1. **Private framework / SDK availability.** `CraneSB`, `CraneSupport` and
   `CranePrefs` use private Apple frameworks. The selected Theos SDK set must
   provide link stubs for the versions used by the source.
2. **Preference bundle declarations.** `sources/prefs/CRPreferences.m` declares
   `PSSpecifier` / `PSListController` / `PSViewController` minimally rather than
   importing complete private headers. A compiler/API mismatch may require
   replacing those stand-ins with the matching SDK headers.
3. **Cross-subproject library ordering.** `libcrane` is listed before its
   dependents in the aggregate build; `CraneSB`, `CraneSupport` and `CranePrefs`
   link `-lcrane` from `$(THEOS_OBJ_DIR)`. CI is the first real validation that
   this aggregate ordering matches the current Theos build rules.

## 4. Artifact inspection

After a real build, before installing:

```sh
dpkg-deb -x packages/*.deb /tmp/crane-pkg
python3 tools/verify_package_layout.py /tmp/crane-pkg
python3 tools/verify_architectures.py /tmp/crane-pkg
```

Then confirm against the original package (`analysis/package_inventory.md`):

| Must match | Reference |
|---|---|
| `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` (leading space) | yes |
| `Library/MobileSubstrate/DynamicLibraries/ Crane.plist` (leading space) | yes |
| `Library/MobileSubstrate/DynamicLibraries/CraneSB.{dylib,plist}` | yes |
| `Library/MobileSubstrate/DynamicLibraries/CraneSupport.{dylib,plist}` | yes |
| `Library/PreferenceBundles/CranePrefs.bundle/{CranePrefs,Root.plist,Credits.plist,Info.plist}` | yes |
| `Library/PreferenceLoader/Preferences/CranePrefs.plist` | yes |
| `Library/LaunchDaemons/com.opa334.cranehelperd.plist` | yes |
| `Library/libSandy/{libCrane,CraneSupport,CraneRB,CraneShortcuts}.plist` | yes |
| `Library/Application Support/Crane.bundle/{Icons/*.png,en.lproj/Localizable.strings}` | yes |
| `usr/lib/libcrane.dylib` | yes |
| `usr/local/libexec/cranehelperd`, `usr/local/bin/cranehelperd_start` | yes |
| Not present: `Applications/*.app` | the original ships two app bundles; this reconstruction ships none (D-11) |

The CI layout verifier asserts all 23 static layout files plus the 7 compiled
artifacts (30 required package files total).

## 5. Installation

**No installation command in this document has been executed or tested.** The
following is the expected procedure for a rootless/rootful jailbreak package
managed by the user's existing tooling. Use the user's established workflow; it
is not recorded anywhere in this repository.

```sh
# Typical, NOT TESTED HERE
sudo dpkg -i com.opa334.cranereconstruction_*.deb
sudo killall -9 SpringBoard        # or reboot
```

Expect a respring or reboot. `cranehelperd` is `RunAtLoad` + `KeepAlive`, so
launchd starts it without any further action.

To remove:

```sh
sudo dpkg -r com.opa334.cranereconstruction
sudo killall -9 SpringBoard
```

There is no maintainer script in this package, so uninstalling leaves two things
behind that a user should be aware of:

| Leftover | Path | Note |
|---|---|---|
| User container data | `/var/mobile/Library/Crane` | **containers written by this build remain**. They are not readable by Crane 6.0 and vice versa (D-01). |
| Daemon launchd job | `com.opa334.cranehelperd` | launchd removes it with the package; verify with `launchctl print system/com.opa334.cranehelperd` |

## 6. Device-side validation

The checklist is in `tests/device_test_results.md` §2 with the minimum evidence
set needed to fill each row in §3. The three checks worth doing first, because
they separate "the tweak loaded" from "the tweak works":

```sh
# 1. did the dylib actually load into an app?
log stream --predicate 'senderImagePath CONTAINS "Crane"' &
launch a Crane-supported app from SpringBoard

# 2. is the daemon up?
launchctl print system/com.opa334.cranehelperd

# 3. did the environment contract fire? (the core of F-01)
#    from a debugger attached to the app:
po [[[NSProcessInfo processInfo] environment] objectForKey:@"HOME"]
```

Note that check 3 will show the **container** path only after F-01 delivers the
environment — which requires the SpringBoard hooks that are absent (D-04). On
this build it will show the app's real container. That is expected, not a bug in
the check.

## 7. Troubleshooting

| Symptom | Likely cause | Reference |
|---|---|---|
| Nothing happens after install | Crane libraries not linked because `libhooker`/`firmware` are missing; the loader silently skips them | `analysis/binary_inventory.md` §4 |
| Container directory created but the app shows the wrong data | F-01 never fired — SpringBoard hooks are absent | D-04 |
| Settings shows no Crane row | `CranePrefs` failed to link AltList, or `PreferenceLoader` did not pick up the plist | `Library/PreferenceLoader/Preferences/CranePrefs.plist` |
| Settings crashes opening the pane | `Root.plist` references controllers this build does not implement (60-method `CRPContainerConfigurationListController`, the backup controllers, the 6 custom cells) | D-18 |
| Daemon not running | `launchctl print system/com.opa334.cranehelperd`; confirm `/usr/local/libexec/cranehelperd` exists and is executable | `final/KNOWN_DIFFERENCES.md` D-19 of the alert path |
| App launches but isolation is incomplete | Keychain isolation is still absent; prefs/APNs/PlugInKit server-side chains are transcribed but remain limited by the documented U-01/U-10 runtime gaps | D-05, D-06, D-07, D-24, D-25 |
| Choicy override does not apply | Provider/runtime core is reconstructed; verify the active container has `choicyConfigurationOverwriteEnabled` plus the nested Choicy payload. The rebuilt settings UI still lacks that per-container editor | D-09 |

## 8. What the documentation does *not* cover

| Missing | Why | Where to look instead |
|---|---|---|
| The original `.deb`'s `postinst` | Not in the tree; no `ar`/`dpkg-deb` here. It apparently selects between the two app bundles (U-19) | `analysis/uncertainty_register.md` U-19 |
| A verified installation procedure | No device, no artifact | §5 is marked NOT TESTED |
| Per-version compatibility | No iOS version has been tested on | `analysis/behavior_specification.md` mentions the `kCFCoreFoundationVersionNumber` thresholds 1665.15 and 1932.101 that matter |
| Backup compatibility | The archive format is unknown (U-06) | `final/KNOWN_DIFFERENCES.md` D-10 |