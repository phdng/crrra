# G-09: recovered 159-hook source coverage audit

**2026-10-16 · Source-only evidence, not runtime equivalence**

This is a reproducible audit of the already recovered registration index,
[hooks_index.csv](../analysis/hooks_index.csv), against currently compiled
CraneSB, CraneSupport and CranePrefs source files. It is **not** a list of
confirmed functioning hooks, ABI/class compatibility, or runtime device
verification.

## Reproduce

```sh
python3 reconstruction/tools/crane_hook_coverage_audit.py --check
python3 -m unittest discover -s reconstruction/tools -p test_crane_hook_coverage_audit.py -v
```

To intentionally regenerate after reviewed code changes:

```sh
python3 reconstruction/tools/crane_hook_coverage_audit.py --write
```

The tracked machine-readable output is
[`HOOK_COVERAGE_MATRIX.json`](HOOK_COVERAGE_MATRIX.json). Each of its 159
ordered rows keeps original dylib, registration function/address, hook API,
indexed target class/selector and hook implementation, then separately lists
candidate native source filename, line, installer API/target expression and
implementation expression. It separately lists Python contract/test files
that **mention the selector text**, not tests proven to exercise that
hook. It also records original duplicate-selector ambiguity, whether the
class field is reliable, and explicit `false` runtime/behavior
verification flags.

### CI-safe legacy Force Touch evidence (2026-10-16)

The recovered decompiles at
`Library/MobileSubstrate/DynamicLibraries/CraneSB.dylib_export_for_ai/decompile/14D18.c`
and `15204.c` are under the Git-ignored `Library/` tree and are **not**
present in a clean GitHub Actions checkout. The earlier version of
`test_crane_hook_coverage_audit.py` incorrectly required those files
and raised `FileNotFoundError` in two tests, although the native build
was unrelated.

The tests now require the small, tracked
`reconstruction/tools/fixtures/cranesb_legacy_force_touch_init_evidence.json`.
It stores literal registration, CoreFoundation version gate and original
initializer excerpts with precise decompile provenance. The tests still
check these excerpts against the current legacy Force Touch hook and
the tracked 159-row matrix. On a workstation where the full IDA exports
exist, an additional test cross-checks each excerpt against them; on CI
the fixture remains **mandatory** and the optional full-export comparison
does not access missing files. This is source-level evidence, not a
native runtime parity claim.

**Local fix verification:** all **18/18** hook-audit Python tests pass,
including an explicit simulated checkout where both ignored decompile
files raise `FileNotFoundError` if accessed. Full reconstruction Python
suite **296 tests, 295 pass, one Windows-specific skip, zero errors**.
`crane_hook_coverage_audit.py --check`, menu/badge contract,
`compileall` and `git diff --check` also pass. The tracked fixture
must be included in the next commit/push for GitHub Actions to use it;
the macOS runner has not yet been rerun on this fix.

## Findings, not parity claims

| Evidence state | Registration rows | Meaning |
| --- | ---: | --- |
| `textual_installer_candidate` | 137 | A matching hook API and selector can be resolved at a concrete source registration expression. **No guarantee** that the class, receiver kind (metaclass vs instance), signature, iOS version gate or implementation behavior matches the original. |
| `ambiguous_original_duplicate` | 10 | Multiple original registrations share a dylib/API/selector; textual evidence cannot prove which implementation/version-specific registration corresponds to which original row. |
| `no_installer_candidate` | 12 | This bounded lexical scanner found no matching source installer. This **does not automatically mean missing functionality**: private-class adaptation, alternate hook APIs, dynamic selectors, and unsupported original UI classes can legitimately differ. |
| **Total** | **159** | Original index: CraneSB 113, CraneSupport 45, CranePrefs 1. |

**Follow-up after the user confirmed the first G-09 build:** the scanner
now recognizes adjacent Objective-C string literals inside
`NSSelectorFromString`. This restores three already-present direct APSd
hook installer candidates: `sendTokenGenerateMessageWithTopicHash:...`
and two `_handleMessageMessage:...` variants in `CRApsd.m`.
No APSd runtime code was changed. A later inspection of the **original**
`CraneSB.dylib_export_for_ai/decompile/14D18.c` and `15204.c` resolved
one more scanner false negative: the original pre-iOS-13 branch hooks
`SBUIAppIconForceTouchController` selector `init`, calls the original
initializer, then resets `crane_provideContainerOptions` to false. That
same sequence already exists in `CRMenuHooks.m` through
`SEL initSelector = @selector(init)` and `CRLegacyForceTouchControllerInit`.
The audit now recognizes local `@selector(...)` definitions, with exact
original/source regression checks. **No duplicate runtime hook was added.**

Of the remaining 12 original entries with no same-API/same-selector
installer, all 12 carry reviewed `reviewed_alternative_not_parity`
file/line evidence:

- **Seven native badge/menu rows:** one `valueForUndefinedKey:` alternate
  class method and six visual-only safe-adapter references. Private badge
  getter/setter and layout hooks are **not** claimed equivalent.
- **One notification row:** `containsObject:` uses an alternate
  `CRCraneResolvingSet` subclass method in `CRBadgeStore.m`.
- **Four support rows:** the C-level
  `xpc_connection_set_event_handler` hook via `MSHookFunction`, the
  cfprefsd ObjC hook wrapper, and two separate C-symbol hooks in
  `CRCfprefs.m`. These are alternatives, not original ABI parity.

The reviewed alternatives have explicit `equivalence_verified:false` and
are kept in the JSON **without** altering the 12 `no_installer_candidate`
statuses. The duplicate-original-selector 10 rows remain ambiguous.

The indexed `_initNotificationSupport` group contains **52 rows**, not 40
as an older hand-written comment suggests. Its `target_class` is collapsed
by the original extractor to `UNSNotificationRecord` due to aliasing and
**cannot be trusted as class attribution**. All 52 are marked
`alias_collapsed_unverified` regardless of matching selector. Do not
hook `UNSNotificationRecord` based solely on this index.

## Triage targets

1. **Notification and async metadata:** the `containsObject:` original
   registration does not produce an installer candidate from a direct
   `MSHookMessageEx` expression. The reconstruction uses an alternate
   `CRCraneResolvingSet` class method strategy in `CRBadgeStore.m`; compare
   behavior and ABI on a disposable device before deciding there is a gap.
   Foreground response/completion propagation remains unverified.
2. **Original private badge class:** `updateConstraints`,
   `layoutSubviews`, `badgeView`, and `setBadgeView:` have no literal
   installer candidate. The current `CRMenuHooks.m` layout is a documented
   safe approximation; do not copy fragile class swizzling without
   runtime class/signature evidence.
3. **Support daemon functions:** three apparent APSd misses were only
   concatenated-literal scanner false negatives, now resolved to source
   installer candidates. The remaining function-level entries use
   `MSHookFunction` / cfprefsd wrapper mechanisms, with reviewed anchors.
   Do not blindly add `MSHookMessageEx` for them.
4. **Repeated original registrations:** preserve each registration in the
   table; never assign identical class/implementation based only on selector
   equality.

**Unresolved:** No binary/runtime method-type comparison, hook return/value
semantics, callback lifecycle, filter selection, process launch test,
production notification delivery test, or on-device class identity
verification has been performed by this audit.

**Earlier G-09 verification (2026-10-16):** the user reported the
G-09 build PASS before this follow-up. The previous nine hook-audit tests
and 287-test reconstruction Python suite passed (one platform skip).
This follow-up added selector-literal parser tests and reviewed evidence.
**Prior local verification:** 16/16 hook-audit tests PASS on a workstation
containing full original decompiles. The new CI-safe fixture preserves the
same legacy Force Touch `init` and CoreFoundation gate checks without
requiring the full ignored export. The prior full Python
suite **294 tests, 293 PASS, one Windows/POSIX SKIP, zero failures**;
regenerated matrix --check PASS, menu badge contract PASS, Python compileall
PASS and git diff --check PASS (only Windows LF/CRLF warnings).
CI native and on-device runtime checks remain necessary for any new hook.

This work changes **no runtime hooks or daemon behavior**. Future patches
should begin with a single proven discrepancy and an isolated device test,
not with the numerical counts above.
