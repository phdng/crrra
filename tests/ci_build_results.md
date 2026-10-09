# CI Build Results

**Status: NOT_TESTED — no GitHub Actions run exists.**

## 1. Why this file is empty of results

The analysis environment has:

- no `gh` CLI,
- no `.github/` directory in the original tree,
- no git remote,
- no macOS / Xcode / Theos toolchain.

A workflow has been authored at `reconstruction/.github/workflows/build.yml`.
Pushing this repository to a GitHub remote and letting the workflow run is the
only way to obtain a real result. Until a run ID exists, no build claim can be
made.

Fabricating a run ID, a log excerpt or an artifact hash here would violate the
project's own evidence rules, so this file records the *state of readiness*
instead, and `tests/ci_build_results.md` must be updated with the real values
when the first run completes.

## 2. What the workflow does when it runs

`.github/workflows/build.yml`, job `build`, runner `macos-14`:

| Step | Purpose | Fails the job on |
|---|---|---|
| `actions/checkout@v4` | get the source | checkout error |
| Record toolchain versions | writes runner OS, `xcodebuild -version`, `git --version` to `$GITHUB_STEP_SUMMARY` | — |
| `theos/theos-action@v1` | install Theos | install error |
| `make package` | build all six components and lay out the package | any build or packaging error (`set -o pipefail` + `tee` keeps errors visible) |
| Inspect the produced package | extract `data.tar.gz`, emit `pkg.manifest.sha256` and `deb.sha256` | missing `.deb` |
| **Verify staged layout** | assert 19 required install paths exist, including `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` **with its leading space** | any missing path |
| **Verify architectures** | `python3 tools/verify_architectures.py pkg` | any dylib that is not `arm64 + arm64e`, or any executable that is not thin `arm64` |
| Upload build log | `build-log` artifact (`if: always()`) | — |
| Upload package + manifest | `crane-package` artifact | upload error |

The two verification steps are the CI equivalent of an artifact inspection: a
green build alone would not prove the package is installable where the tweak
expects.

## 3. What a passing run would and would not prove

| It would prove | It would **not** prove |
|---|---|
| The six components compile and link | That any hook behaves correctly |
| The package installs to the recovered paths | That any dylib is injected |
| The fat-slice architectures match the original | That `cranehelperd` starts and serves its Mach services |
| The layout plists are present | That the preference domain is the original's store |
| Nothing about runtime | Nothing about the Settings UI |

That distinction is exactly why `final/ACCEPTANCE_MATRIX.md` keeps
`CI_BUILD_PASSED` and `RUNTIME_TEST_PASSED` as separate columns.

## 4. Known build risks that CI will surface

Stated up front so a first-run failure can be attributed correctly rather than
investigated from scratch:

| Risk | Where it would fail | Likely cause |
|---|---|---|
| AltList headers absent | `CranePrefs` compile | `AltList.framework` ships with the `firmware` package on the runner's Theos; `PSSpecifier`/`PSListController` declarations in `sources/prefs/CRPreferences.m` are minimal stand-ins that may not match the real headers |
| `libcrane.dylib` link order | `CraneSB`, `CraneSupport`, `CranePrefs` link | `LIBRARIES = objc libcrane.dylib` resolves to Theos' staged output; the master Makefile's `package-stage` rule is what places it at `/usr/lib` |
| Rootless staging prefix | layout verification | `THEOS_PACKAGE_SCHEME = rootless` puts files under `_jbroot` during staging; `package-stage` must copy to the un-prefixed names the verification step expects |
| `TWEAK_NAME =  Crane` | main dylib build | Theos may reject or mangle a name with a leading space; the `package-stage` rule exists precisely because of this |
| Private framework headers | `CraneSB` / `CraneSupport` | `BackBoardServices`, `AppSupport`, `Preferences`, `CoreData` are used only for constants and string literals in this implementation, so header availability should not matter |
| `libbsm.0.dylib` | `CraneSupport` link | provided by the `firmware` package |

## 5. Record to add on the first real run

```
Run ID / URL:      <fill in>
Commit SHA:        <fill in>
Trigger:           <push | pull_request | workflow_dispatch>
Runner:            <macos-14 image version>
Xcode:             <xcodebuild -version output>
Theos revision:    <theos/theos-action resolved revision>
Build command:     make package  (reconstruction/)
Result:            <success | failure>
Warnings:          <count and text>
.deb name:         reconstruction/packages/<name>.deb
.deb SHA-256:      <from deb.sha256>
Artifact names:    build-log, crane-package
pkg.manifest sha:  <from pkg.manifest.sha256>
Verified paths:    <count of the 19 expected paths present>
Architecture check: <output tail of verify_architectures.py>
Automated tests:   none defined yet
```

## 6. Test automation status

No automated functional tests exist. What CI does check mechanically today:

| Check | Tool | Status |
|---|---|---|
| Mach-O architectures | `reconstruction/tools/verify_architectures.py` | **PASS locally** — run against the original package tree, 11/11 binaries conform |
| Layout plist equivalence | `python3` + `plistlib` comparison of `reconstruction/layout/**` against the original files | **PASS locally** — 12/12 semantically identical |
| Export↔binary identity | `tools/prove_export_identity.py` | **PASS** — 5/5 exports, 100% `__text` match on the arm64 slice |
| Layout path set | CI step | NOT_TESTED |

The architecture verifier and the layout comparison are the two checks that can
be, and have been, run without a device or a macOS toolchain; their results are
recorded as CONFIRMED (analysis-time), not as CI results.