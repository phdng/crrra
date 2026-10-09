# CI Build Results

**Status: NOT_TESTED — no GitHub Actions run exists.**

## 1. Why this file is empty of results

The analysis environment has:

- no `gh` CLI,
- no `.github/` directory in the original tree,
- no git remote,
- no macOS / Xcode / Theos toolchain.

A workflow has been authored at the repository root: `.github/workflows/build.yml`.
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
| `waruhachi/theos-action@v2.6.3` | install Theos, SDKs and AltList | setup error |
| Record toolchain | writes macOS/Xcode/clang/make/Theos details to `$GITHUB_STEP_SUMMARY` | toolchain command error |
| `make clean package FINALPACKAGE=1` | build all seven reconstruction targets and lay out the package | any build or packaging error (`set -o pipefail` + `tee` keeps errors visible) |
| Inspect the produced package | `dpkg-deb -x`, emit `pkg.manifest.sha256` and `deb.sha256` | missing/invalid `.deb` |
| **Verify package layout** | `python3 tools/verify_package_layout.py pkg` checks 23 recovered static files + 7 compiled artifacts, including `Library/MobileSubstrate/DynamicLibraries/ Crane.dylib` | any missing file |
| **Verify architectures** | `python3 tools/verify_architectures.py pkg` | any dylib/bundle that is not `arm64 + arm64e`, or any executable that is not thin `arm64` |
| Upload build log | `build-log` artifact (`if: always()`) | — |
| Upload package + manifest | `crane-reconstruction-package` artifact | upload error |

The two verification steps are the CI equivalent of an artifact inspection: a
green build alone would not prove the package is installable where the tweak
expects.

## 3. What a passing run would and would not prove

| It would prove | It would **not** prove |
|---|---|
| The seven reconstruction targets compile and link | That any hook behaves correctly |
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
| Private framework / SDK availability | `CraneSB`, `CraneSupport`, `CranePrefs` link | the selected Theos SDK must provide stubs for the private Apple frameworks referenced by the source |
| Preferences declarations | `CranePrefs` compile | the source uses minimal `PS*` declarations; a compiler/API mismatch may require matching private headers |
| `libcrane` aggregate order | `CraneSB`, `CraneSupport`, `CranePrefs` link | dependent subprojects link `-lcrane` from `$(THEOS_OBJ_DIR)` after `sources/libcrane`; CI is the first real validation of that aggregate ordering |
| `bsm.0` availability | `CraneSupport` link | the SDK/toolchain must provide the expected libbsm stub |
| Private cfprefsd ABI | runtime only, not build | U-02 control flow is resolved, but the three version-specific private hook entry points are intentionally not installed yet |

## 5. Record to add on the first real run

```
Run ID / URL:      <fill in>
Commit SHA:        <fill in>
Trigger:           <push | pull_request | workflow_dispatch>
Runner:            <macos-14 image version>
Xcode:             <xcodebuild -version output>
Theos action:      waruhachi/theos-action@v2.6.3
Build command:     make clean package FINALPACKAGE=1  (reconstruction/)
Result:            <success | failure>
Warnings:          <count and text>
.deb name:         reconstruction/packages/<name>.deb
.deb SHA-256:      <from deb.sha256>
Artifact names:    build-log, crane-reconstruction-package
pkg.manifest sha:  <from pkg.manifest.sha256>
Verified files:    <30/30 required package files present>
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
| Package layout set | `reconstruction/tools/verify_package_layout.py` | NOT_TESTED in CI; verifier is authored for 30 required files |

The architecture verifier and the layout comparison are the two checks that can
be, and have been, run without a device or a macOS toolchain; their results are
recorded as CONFIRMED (analysis-time), not as CI results.