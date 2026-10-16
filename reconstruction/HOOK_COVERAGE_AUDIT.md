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

## Findings, not parity claims

| Evidence state | Registration rows | Meaning |
| --- | ---: | --- |
| `textual_installer_candidate` | 133 | A matching hook API and selector can be resolved at a concrete source registration expression. **No guarantee** that the class, receiver kind (metaclass vs instance), signature, iOS version gate or implementation behavior matches the original. |
| `ambiguous_original_duplicate` | 10 | Multiple original registrations share a dylib/API/selector; textual evidence cannot prove which implementation/version-specific registration corresponds to which original row. |
| `no_installer_candidate` | 16 | This bounded lexical scanner found no matching source installer. This **does not automatically mean missing functionality**: private-class adaptation, alternate hook APIs, dynamic selectors, and unsupported original UI classes can legitimately differ. |
| **Total** | **159** | Original index: CraneSB 113, CraneSupport 45, CranePrefs 1. |

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
3. **Support daemon functions:** unmatched `_handleMessageMessage:...`,
   `sendTokenGenerateMessageWithTopicHash:...` and some C-level functions
   need targeted review, not blind MSHookMessageEx additions. The existing
   `CRApsd.m` implementation may use reconstructed adapters.
4. **Repeated original registrations:** preserve each registration in the
   table; never assign identical class/implementation based only on selector
   equality.

**Unresolved:** No binary/runtime method-type comparison, hook return/value
semantics, callback lifecycle, filter selection, process launch test,
production notification delivery test, or on-device class identity
verification has been performed by this audit.

**Local verification (2026-10-16):** nine hook-audit Python tests PASS; full
reconstruction Python suite: 287 tests, 286 PASS, one platform SKIP, zero FAIL;
matrix --check, menu/badge source contract, Python compileall and
`git diff --check` PASS (only Windows line-ending warnings). CI's new
matrix freshness/test steps and native Theos builds are not independently
verified for this slice.

This work changes **no runtime hooks or daemon behavior**. Future patches
should begin with a single proven discrepancy and an isolated device test,
not with the numerical counts above.
