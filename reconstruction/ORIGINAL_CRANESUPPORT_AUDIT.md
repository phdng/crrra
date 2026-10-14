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

## What is *not* proved

- Whether the three diagnostic dylibs are mapped into post-reboot system daemons.
- Whether an injected CraneSupport constructor ran and failed to apply
  libSandy or its runtime-report XPC was rejected.
- Whether roothide rewrites the original direct libSandy load command to
  an accessible jbroot path; local host lacks native Theos/otool and the
  original input tree does not include a `libsandy.dylib` linker stub.
- Exact original `cranehelperd` insurance implementation: only its Mach-O
  and selector evidence survives, not a matched IDA pseudocode export.

## Safe next verification

1. Run native Theos roothide CI, inspect `linkage.txt` especially
   `CraneSupport.dylib`, `libcrane.dylib`, and libSandy linkage. Do not
   declare a native build passed merely from Python static checks.
2. For device diagnosis use a genuinely independent *passive* way to
   determine if Support/probe images are mapped or collect persistent
   constructor status, rather than repeating post-reboot live
   `oslog | grep` and treating missing messages as proof of no injection.
3. Keep fail-closed insurance enabled; do not port `patchfindSecurityd`
   while `CraneSupport` runtime proof is absent. Preserve every
   `DEFAULT`/non-default Chrome container and its on-disk contents.
