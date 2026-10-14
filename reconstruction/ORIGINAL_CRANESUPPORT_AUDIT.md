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

Added source contract assertions using actual original IDA `6C5C.c` and
`6E44.c` exports to prevent future order regressions.

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
