# Regression Results

**Status: NOT_TESTED — no build and no device exist.**

## 1. What regression testing means here

A regression result requires: a source revision, a CI artifact from that exact
revision, and a device observation against that same artifact. This project has
none of the three. There is therefore no regression result to report, and none is
invented.

What *can* be reported are the analysis-time checks that guard the reconstruction
against regressing away from the original. Those are recorded below, and they
are the results a future commit must keep passing.

## 2. Guard tests (must not regress)

| Guard | What it protects | Result | Command |
|---|---|---|---|
| G-01 | Each IDA export stays identified with its binary and arm64 slice | PASS | `python tools/prove_export_identity.py` |
| G-02 | Export completeness stays 100% | PASS | `python tools/build_export_index.py` (parsed == declared for all 5) |
| G-03 | The layout plists stay semantically identical to the original | PASS | `plistlib` comparison of `reconstruction/layout/**` |
| G-04 | Layout assets stay byte-identical | PASS | hash comparison of the 10 PNGs |
| G-05 | The arm64/arm64e rule stays satisfied | PASS | `python reconstruction/tools/verify_architectures.py <unpacked .deb>` |
| G-06 | The package inventory stays complete and hashed | PASS | `python tools/make_manifest.py` (77 files, 0 without a role) |
| G-07 | The hook inventory stays catalogued | PASS | `python tools/extract_hooks.py` |
| G-08 | Preference keys stay consistent between plists and binaries | PASS | `python tools/pref_schema.py`, `python tools/pref_access.py` |
| G-09 | The leading space in ` Crane.dylib` / ` Crane.plist` is not "fixed" | PASS | covered by G-03 and by the CI layout check |
| G-10 | Every `CR`-prefixed identifier in the reconstruction resolves to a macro, function, class, import target, or runtime class lookup | PASS | `python tools/check_identifiers.py` |
| G-11 | Braces and parentheses balance in every reconstruction `.m` file | PASS | checked by `tools/audit_consistency.py` |
| G-12 | No report falsely claims a passed build/device/runtime status | PASS | `python tools/audit_consistency.py` (82 cross-document checks) |

G-09 deserves a note. A well-meaning cleanup that renames the file to
`Crane.dylib` would break Choicy/TweakRestrict allow-lists written for Crane and
contradict the package's own `CHOICYLOADER_SUGGESTION_MESSAGE`. The space is
load-bearing.

## 3. Analysis-time regression checks that were actually run

These were executed against the original package and are recorded because their
results are real and reproducible:

| Check | Method | Result |
|---|---|---|
| Universal-binary identity for all five exports | byte-compare IDA `memory/` dumps against each fat slice | `__text` 100.000% (arm64) vs 9–12% (arm64e) for all 5 |
| Section-level agreement | same method, per `__objc_*` section | 100% for all `__TEXT` sections and all non-pointer `__DATA` sections; only `__bss`, `__common`, `__got`, `__la_symbol_ptr`, `__objc_classrefs`, `__objc_data`, `__cfstring` differ, i.e. exactly the relocated regions |
| Architecture rule across the package | `verify_architectures.py` | 11/11 conform |
| Layout plist equivalence | `plistlib` | 12/12 identical |
| Asset byte-identity | SHA-256 | 10/10 identical |

## 4. Regressions a future implementation must specifically guard against

These are the traps in the recovered behaviour. A reconstruction that "cleans
them up" is *less* faithful even though it looks better:

| Trap | Correct behaviour | Evidence |
|---|---|---|
| Removing the leading space from the dylib filename | keep it | 4 references inside the binaries + the localization text |
| Making `requestAuthentication` fail when biometrics are unavailable | it invokes the handler anyway | Crane 0x6E08 |
| Making the `unlink` protection hook call the original on a match | it returns 0 without deleting | Crane 0x721C |
| Making the sandbox-lookup hook return early instead of calling the original first | the original runs first, then the buffer is overwritten for `getpid()` only | Crane 0x6564 |
| Treating an unset per-app switch as YES | it reads NO (`[nil boolValue] == 0`) | Crane 0x1ED64 and the recovered specifier code |
| Building the Game Center specifier unconditionally *and* appending it unconditionally | it is built always but appended only when Separate System Accounts is on | CranePrefs 0x8D00 |
| Reading `CRANE_CONTAINER_IDENTIFIER` without unsetting it | the variable is unset so the app cannot discover its container | Crane 0x65D0 |
| Using `setenv` with `overwrite = 0` | all three use `overwrite = 1` | Crane 0x65D0 |
| Sorting or de-duplicating `Root.plist` items | specifier order is observable | `Root.plist` |
| Treating `Flags = 1` on `CraneSupport.plist` as a bug | it is reproduced verbatim | `CraneSupport.plist` |
| Letting `libSandy_works() == false` abort the launch | it fails open and alerts | CraneSB 0x1B45C |

## 5. Regression suite status

| Category | Count | Result |
|---|---:|---|
| Guard tests defined and passing | 12 | 12 PASS |
| Static regression checks executed | 5 | 5 PASS |
| Cross-document consistency checks | 82 | 82 PASS |
| Reconstructed source lines | 3041 | balance + identifier checks PASS |
| Behavioural regressions tested on device | 0 | NOT_TESTED |
| Regression history entries | 0 | no prior build exists |

When the first CI run and first device test happen, each of the 76 runtime tests
in `tests/functional_tests.md` should be entered here with its CI run ID, commit
SHA and `.deb` hash, so that a later build can be compared against a real
baseline rather than against the original's undocumented behaviour.