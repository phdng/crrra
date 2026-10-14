# CraneSupport original-binary parity audit — 2026-10-13

## Scope and evidence

This audit compares the installed iOS 15.8.8 Dopamine 2 + roothide
reconstruction against **the original recovered binary**, not hypothetical
upstream source. Original evidence is in:

- `Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib_export_for_ai/decompile/6C5C.c` (original constructor)
- `Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib_export_for_ai/decompile/6E44.c` (original sandbox-profile callback)
- `Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib_export_for_ai/imports.txt`
- `Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib` (both Mach-O slices)
- `Library/MobileSubstrate/DynamicLibraries/CraneSupport.plist`
- `Library/libSandy/CraneSupport.plist`

Reconstruction counterparts are in `reconstruction/sources/support/CRSupport.m`,
`reconstruction/sources/support/Makefile`,
`reconstruction/sources/common/CRCommon.m`,
`reconstruction/sources/cranehelperd/CRHelperd.m`, and
`reconstruction/layout/Library/`.

## Results

| Aspect | Original confirmed | Reconstruction | Conclusion |
| --- | --- | --- | --- |
| Inject filter | `Executables` = cfprefsd, containermanagerd, securityd, pkd, lsd, accountsd, apsd; `Flags=1` | Same parsed plist dictionary | **Exact semantic parity.** Do not remove/change `Flags=1` without device evidence. |
| `CraneSupport` libSandy profile | Seven signing IDs; two Mach grants for `com.opa334.cranehelperd.xpc` | Same parsed plist dictionary | **Exact semantic parity.** No reason to broaden sandbox exceptions. |
| Constructor order | `0x6C5C`: obtain process, register `_setXPCUnsandboxHandler:`, dispatch one of seven hook initializers | Previously applied libSandy and sent `runtime_report` **before** hooks | **Corrected:** register callback, dispatch hooks, then reconstruction-only profile/report. |
| Profile invocation | `0x6E44`: callback calls `libSandy_applyProfile("CraneSupport")`, caches **success only** | Same caching policy; explicit profile call also required for raw XPC | Functional departure still required by reconstruction-specific transport. |
| libSandy Mach-O dependency | Both original arm64/arm64e slices have `LC_LOAD_DYLIB /usr/lib/libsandy.dylib` and direct `_libSandy_applyProfile` import | Calls `dlsym` after `dlopen` on jbroot path; no explicit `libsandy` linker dependency in Support Makefile | **Unresolved loader/transport parity gap.** Need native roothide `otool -L` and a confirmed linkable libSandy SDK stub before changing this. |
| Other original dependencies | `/usr/lib/libcrane.dylib`, `/usr/lib/libbsm.0.dylib`, `/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate`, Foundation/CoreFoundation/Security/AppSupport/CoreData/LocalAuthentication, etc. | Explicit `crane bsm.0 substrate` and public framework use; AppSupport unused in current reconstructed code | Original Mach-O load names verified; do not remove `bsm.0` speculatively. |
| Runtime insurance | Original CraneSB `0x1B45C` + callback `0x1BAA4` asks original helper and fails to change non-default app environment when insurance fails | Reconstruction uses a new authenticated raw-XPC runtime registry | **Not original parity.** A missing registry claim does not itself prove a dylib was never mapped. |
| Reboot evidence | N/A | Support/probe files installed Oct 13 at 17:55; six observed target daemons restarted at 19:45; insurance 20:36 `works=0 connection=1` with seven broken names | Fresh processes and installed files verified; no valid runtime report. Constructor messages absent in a log stream which also omits helper-side insurance messages. |

## Scoped correction made

Moved the reconstruction-only `CRPrepareSupportXPCUnsandbox()` and
`CRReportRuntimeInjection(@"CraneSupport", nil)` to **after** the original
per-process hook dispatch in `CRInitFunc`. Registered the original
`CraneManager` sandbox callback **before** hook dispatch, preserving
`0x6C5C` ordering. The profile still runs before raw-XPC registration.
This prevents a pre-hook registration being mistaken for initialized daemon
support. Insurance still blocks any non-default launch without accepted
per-daemon evidence. No actual user data/container migration or deletion.

Added source contract assertions for the original IDA `6C5C.c` and
`6E44.c` exports to prevent future order regressions. The full IDA files
live in `Library/`, which is intentionally Git-ignored; CI instead uses
the tracked `reconstruction/tools/fixtures/cranesupport_constructor_evidence.json`
fixture (source markers, addresses and SHA-256 for both files). Local runs
with the original files present verify both hashes and the exact exported
call ordering. CI sets `CRANE_SUPPORT_SKIP_NATIVE_EXPORT=1` to verify the
fixture plus reconstruction source without assuming ignored original files
exist in the GitHub checkout. This avoids the earlier CI FileNotFoundError
while retaining a real native evidence cross-check.

## Recovered original live injection fix-up — no Userspace Reboot requirement

Later direct analysis of the recovered original binaries resolves an important
lifecycle gap that the earlier audit did not cover.

`CraneSB.dylib` decompile `0x1782C` (`didFinishLaunching`) first ensures
`cranehelperd` is reachable, then obtains the helper's async proxy and calls:

```text
runInjectionFixUpIfNeededAndReply:
```

The reply callback at `0x179C4` stores `injectionFixupError` only when the
helper reports failure. This happens during SpringBoard launch, so original
Crane does **not** depend on waiting for all CraneSupport target daemons to
restart after package installation.

The recovered original `cranehelperd` binary has no matched IDA pseudocode
export, but its Objective-C metadata/imports/strings now establish the
privileged operation surface directly:

- `_verifyCraneSupportLoadedIntoDaemon:error:`
- `_crucialCraneSupportDaemons`
- `_daemonsForCraneSupportInjection`
- `_fixupInjectionIfNeededForDaemon:error:`
- `_isDylib:loadedIntoProcessWithPid:`
- `_isDylib:loadedIntoProcessWithName:`
- `_injectDylib:intoProcessWithPid:error:`
- `_injectDylib:intoProcessWithName:error:`
- `_waitUntilDylib:isLoadedIntoProcessWithPid:timeoutInSeconds:`
- `_waitUntilDylib:isLoadedIntoProcessWithName:timeoutInSeconds:`
- `/Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib`
- injection backends `/usr/libexec/libhooker/libsyringe`,
  `/usr/bin/cynject`, and `/usr/bin/cynject.old`
- imports `task_for_pid`, `vm_read_overwrite`, `vm_write`, `kill`
- original helper entitlement `task_for_pid-allow = true`.

The helper also exposes `reloadDaemons:`, but the evidence above is enough to
show that the **normal recovered startup path is verify/fix-up/inject**, not a
mandatory Userspace Reboot. The reconstruction already preserved the
`runInjectionFixUpIfNeededAndReply:` selector ABI, but its implementation
now carries a bounded fixed-purpose helper operation. The prior Userspace Reboot requirement was only a diagnostic workaround and is not part of the reconstructed product behavior.

Separately, opa334's public SliceFixup project explicitly names
`CraneSupport.dylib` as a dylib that had arm64e ABI loading problems on
iOS 15 and says SliceFixup is intended to run from package `postinst`.
Native package/linkage/arm64e verification remains required while validating the newly implemented helper fix-up on iOS 15.

## 2026-10-14 device-debug closure: problem, causes, fixes, proof

The apparent "CraneSupport never loads into daemons" failure was not one bug.
The debugging sequence exposed several reconstruction-specific differences
around the recovered helper fix-up path:

1. **Cold-helper startup race (06:29).** SpringBoard called
   `cranehelperdConnectionWorks` twice on its main thread around helper
   startup. The reconstructed main-thread check is cache-only, so the second
   call could observe the first probe still in flight and skip the recovered
   `runInjectionFixUpIfNeededAndReply:` request entirely. The fix keeps the
   original startup intent but performs bounded readiness checks on a worker
   before sending the async fix-up request.
2. **PID transition treated too strictly (07:07).** Live injection succeeded
   for `cfprefsd`, then a launchd-managed target changed/disappeared. The
   reconstruction originally converted that into fatal error 1107. Direct
   original-helper analysis showed injector exit 0 is accepted and the outer
   pass stops on `NSError`, not on an added post-injection PID-stability
   requirement. The reconstruction now records a transition and defers later
   verification instead of aborting the seven-daemon pass.
3. **Post-inject polling was not original behavior (08:23).** A two-second
   mapped-image wait stretched the sequential pass and made an active pass look
   failed in a concurrent insurance snapshot. It was removed. A diagnostic
   immediate sample remains, while real health is decided later by insurance.
   The diagnostic state gained explicit `inProgress` so
   `success=0/error=null` cannot be mistaken for a completed failure.
4. **`opainject` timeout false-negative (08:55).** Insurance already reported
   `works=1 connection=1 broken=`, proving every required CraneSupport runtime
   attestation was healthy, while the wrapper still reported error 1104 for
   `pkd`. The Roothide injector had completed the useful load/report work but
   did not exit before the reconstruction's bounded child timeout. Timeout
   handling now first verifies that the PID still belongs to the same daemon;
   it then accepts an already-mapped `CraneSupport.dylib` or exact-PID runtime
   proof. A disappeared/reused PID is recorded as a deferred transition, never
   salvaged as the old target.

The rebuilt device test at **10:20 on 2026-10-14** closed this issue:

```text
CraneManager: helper injection fixup authorized=1 success=1 error=(null)
CraneManager: helper injection fixup state attempted=1 inProgress=0 success=1 process=pkd backend=opainject transitions=(null) errorCode=0 error=(null)
CraneManager: helper insurance works=1 connection=1 broken= error=(null)
```

This proves the reconstructed live fix-up completed and the independent
insurance gate accepted all required CraneSupport proofs. The earlier
`success=0/errorCode=1104` state is therefore closed as a wrapper
false-negative, not a remaining daemon-injection failure.

## Post-debug cleanup and parity decisions

Temporary loader diagnostics are no longer production payload:

- `CraneSupportProbeFlags`, `CraneSupportProbePlain`, and
  `CraneSupportProbeBare` remain in source only as an archived manual
  diagnostic harness. Normal Roothide packages no longer build/stage them.
- SpringBoard no longer installs probe Darwin-notification observers or sends
  probe pings on redirected launches.
- `cranehelperd` no longer scans/reports `flags/plain/bare` probe images.
  The generic failure-only mapped-image summary remains diagnostic and is not
  part of the insurance success expression.
- The temporary seven-daemon `support health` matrix after every successful
  app launch was removed; insurance already owns that decision.
- The temporary app-side same-peer runtime-report `ping` acknowledgment was
  removed; the persistent authenticated `runtime_report` transport remains.
- Constructor-only diagnosis logs were removed from CraneSB/CraneSupport.
- Unused fix-up timestamp state, obsolete 1106/1107 enum values, and two unreferenced helper predicates (`CRIsCraneSBProcess` / `CRIsCraneSupportProcess`) were removed.
- Injector candidates now have one shared source of truth. Rootful selection is again exactly the recovered `libsyringe/cynject/cynject.old` set, while `opainject` is explicitly a **Roothide-only platform adaptation**; backend discovery and diagnostic inventory can no longer drift apart.

### Intentional reconstruction differences that remain

These are not accidental debug leftovers and must not be removed without
recovering the corresponding original implementation:

- The authenticated raw-XPC runtime registry and `runtime_report` are
  reconstruction-specific because the original helper protocol remains U-01.
- CraneSupport explicitly applies its libSandy profile before raw-XPC
  attestation. The original invokes the same profile from the manager's
  unsandbox handler, but the reconstructed transport needs the explicit gate.
- Roothide prefers `opainject`; the original binary only names
  `libsyringe/cynject/cynject.old`. This is required by the observed Roothide
  environment and is isolated from rootful builds.
- The injector child has a bounded timeout with same-PID recovery. This is a
  reconstruction safety wrapper around the recovered "exit 0 means success"
  behavior.
- SpringBoard uses an off-main bounded helper-readiness retry because the
  reconstructed connection check has cache semantics that the original proxy
  path did not expose.
- Insurance still uses reconstruction runtime attestations and fails closed
  when a crucial daemon is absent. The original helper appears able to activate
  an on-demand service before verification; that activation routine is not yet
  reconstructed.
- Fix-up state/backend inventory and the generic mapped-image summary are
  observability only. Contracts ensure none of them can make `works=1`.

## What is *not* proved

- Exact original `cranehelperd` insurance implementation: its selector/Mach-O
  evidence survives, but no matched helper pseudocode export is available.
- Exact original on-demand crucial-daemon activation semantics.
- Exact direct libSandy linkage behavior under Roothide; reconstruction still
  resolves the jbroot library dynamically for its raw-XPC path.
- Feature-level correctness inside securityd/pkd/accountsd/apsd. The global
  CraneSupport injection path is proven healthy, but each isolation feature
  still needs its own device behavior test.

## Safe next verification

1. Stop treating daemon injection as the active blocker unless insurance
   regresses from `works=1` or returns a non-empty broken list.
2. Continue with non-default app/container tests: active container lookup,
   preferences isolation/cache coherence, then securityd keychain behavior.
3. For F-07, inspect the now-reachable securityd hook/symbol path before
   deciding whether the original private-symbol fallback (`0x11C08`) is
   actually needed.
4. Keep fail-closed insurance enabled and preserve all existing
   `DEFAULT`/non-default container data during tests.
