# Crane — Porting Gap Inventory & Implementation Backlog

Ngày kiểm kê: 2026-10-12. Nhánh quan sát: `chore/reconstruction-build-ci`.

## Helper communication follow-up — empty Crane Error suffix

The supplied Chrome alert identifies the helper communication branch, with no
underlying description. The raw-XPC adapter discarded errors and the original
post-launch nil/false branch forwarded nil. Added shared transport diagnostics,
reply-scoped getLastError handling, bounded insurance/PID lookup, and helper
startup/listener/peer logs. The original insurance/injection gates and caller
authentication remain intact. Clients select the privileged Mach bootstrap for
the recovered launchd service; no original NSXPC wire equivalence is claimed.

Recovered XML entitlement dictionaries directly from original helper-tool code
signature slot 5, wired them into Theos signing, and added documented Roothide
executable permissions separately. Fixed the starter's Roothide bootstrap
executable resolution. Source/evidence checks pass; CI compiles the production
diagnostic decoder and verifies actual packaged entitlement slots. Native build
and device results remain unverified.

P0 incident: SpringBoard repeatedly reports `runtime_report` Code=1003
Connection invalid. Package 6.0 / iphoneos-arm64e is installed, the recovered
plist fields match and the helper is executable, but no helper PID is visible.
The user's only shell is mobile; its job query cannot conclusively distinguish
missing system registration from restricted visibility. Missing installer
registration is the leading hypothesis, not a proven exclusion of signing,
dependency or resolved-path failures.

The user explicitly authorized the package install adapter. Added
`layout/DEBIAN/postinst`: during configure it requires the privileged package
installer, checks the helper/plist, queries only `com.opa334.cranehelperd`,
bootstraps it if absent and kickstarts the installed build. A bootstrap failure
is tolerated only when the job becomes queryable (concurrent registration);
otherwise package configuration fails visibly. User container data and peer
authentication are untouched. The standalone starter remains kickstart-only.

Theos stages postinst as 0755. CI extracts control.tar.* separately and verifies
the exact script contents/mode, while excluding DEBIAN metadata from installed
data. Eight production-script control-flow tests pass with mocked launchctl
(fresh, registered, registration race/failure, kickstart failure, non-root,
missing files and ignored actions). Rootful/Roothide native packages and real
device registration still require validation. Installing the newly rebuilt
package through the trusted package manager is the mobile-only repair path;
reinstalling an older package without this hook does not add registration.

The original package maintainer scripts and helper/libcrane bodies are absent,
so this install hook is explicitly reconstruction packaging work. Earlier
automatic-review refusal was resolved by the user's explicit approval.
The existing read-only diagnostic remains available for verification.

## Device incident — Chrome launched into DEFAULT after Helper XPC recovery

**F-19 follow-up Chrome PID 3756, installed app Mach profile but still Code=1003:**
The device confirms `/Library/libSandy/CraneAppRuntime.plist` is installed
(198-byte, root:wheel) and Chrome is using the same selected UUID
`F7555D97-7AE9-4D62-9BF2-9A9E42AE5BBB`, yet app `runtime_report`
and same-peer diagnostic ping still return Code=1003, while SpringBoard's
helper lookup succeeds. Follow-up Chrome PID 4261 now proves the diagnostic
path and libSandy call both execute: `APP_RUNTIME_MACH_DIAGNOSTIC_V2` is logged
and `Crane: app runtime Mach profile pid=4261 status=0`. Therefore profile
loading/application is no longer the leading failure; the remaining Code=1003
is after a successful libSandy apply. Comparing the app profile with the
recovered `CraneSupport.plist` / `CraneRB.plist` exposes a concrete mismatch:
those original profiles grant the same exact helper Mach name with BOTH
`com.apple.app-sandbox.mach` and
`com.apple.security.exception.mach-lookup.global-name`, while the new app
profile granted only the first class. The app profile now mirrors those two
service-specific classes for `com.opa334.cranehelperd.xpc` only. It still grants
no filesystem/keychain/wildcard service, keeps the privileged XPC bootstrap
flag, and does not weaken helper PID/signing authorization or touch Chrome data.

**F-19 app-sandbox Helper Mach lookup fix (Chrome PID 3411, 2026-10-13):**
Chrome log proves main ` Crane.dylib` loaded, selected nondefault
`F7555D97-7AE9-4D62-9BF2-9A9E42AE5BBB` is present, and app
`runtime_report` was queued, but the app's same-connection probe returns
`Code=1003 Connection invalid` repeatedly. In parallel SpringBoard
`lookup_pid` has `helper=1` and no Chrome proof. This isolates an
**app-to-helper XPC transport** fault; a sandbox Mach-lookup permission
gap is the leading hypothesis, not a proven denial. Profile diff: all
original/reconstructed libSandy profiles for runningboardd
(`CraneRB`), CraneSupport daemons and CraneShortcuts grant the helper
Mach service, but the original `libCrane` profile for arbitrary apps
only grants preferences-file access. The `libSandy` upstream API
supports granting an exact Mach service via
`com.apple.app-sandbox.mach` to sandboxed applications. To address this
reconstruction-only runtime attestation channel, added
`layout/Library/libSandy/CraneAppRuntime.plist` with
`AllowedProcesses=["*"]` (necessary for arbitrary managed bundle IDs)
and the two service-specific Mach extension classes already recovered in
`CraneSupport` / `CraneRB` (`com.apple.app-sandbox.mach` plus
`com.apple.security.exception.mach-lookup.global-name`) for the exact
`com.opa334.cranehelperd.xpc` name; no filesystem, keychain, wildcard Mach
or other RPC access. Main `CRMainDylib.m` only requests it for
nondefault container launch before the unchanged
`CRReportRuntimeInjection` call, through the jbroot-resolved libSandy
`libSandy_applyProfile("CraneAppRuntime")` function, and logs
success/failure without faking proof. Helper PID and signing-based
caller authorization remain unchanged. Added
`check_app_runtime_sandbox_contract.py` in both CI schemes and
strengthened the extracted-package verifier to reject an overbroad or
malformed installed profile. **Native build and on-device libSandy
profile application / app-to-helper XPC / live same-PID proof remain
unverified.** If libSandy fails, log its return code and inspect the
Roothide install; do not bypass XPC authorization.

**Data isolation caution:** Chrome container UUIDs
`007FADC7-01AC-4740-AD98-0099E98A32FC`,
`1947F19D-7E24-40BF-9E8F-2EA7C70B65B9` and
`F7555D97-7AE9-4D62-9BF2-9A9E42AE5BBB` are distinct profiles.
App init only creates missing skeleton directories; no delete of prior
profiles in this fix. Preserve these directories and DEFAULT; the new
Mach extension neither accesses nor migrates app data.

**New app-to-Helper attestation incident (Chrome PID 3100, 2026-10-13):**
After the Roothide SpringBoard launch fallback was deployed, Chrome logged
`Crane: app init ... container=1947F19D-7E24-40BF-9E8F-2EA7C70B65B9`
and `app environment ready ... hooks=0`. With `protection=0 spoof=0`,
`hooks=0` is **normal**; main dylib env consumption has progressed.
SpringBoard still failed three same-PID Helper lookup attempts despite
`helper=1`: client and server helper availability are **not equivalent**.
The app-to-Helper `CRReportRuntimeInjection` is one-way, so an app sandbox
Mach lookup failure or a disconnected runtime peer can yield no stored
proof while SpringBoard's own XPC requests succeed. Added an asynchronous
read-only `ping` after the initial `runtime_report` on the *same* client
XPC connection, along with sender logs for queued report, transport error
and compatible response. Helper logs distinguish accepted/rejected
reports, peer disconnect, no runtime peer, process-name mismatch, no Crane
report and empty container claim; the existing PID authentication and
protocol bytes remain unchanged. `check_app_runtime_probe_contract.py`
verifies ordering and fail-closed semantics in CI. This is diagnostic,
NOT proof that sandbox Mach lookup is fixed or that registration succeeded.

**Possible apparent Chrome data loss:** earlier selected container was
`007FADC7-01AC-4740-AD98-0099E98A32FC`, but PID3100 received
`1947F19D-7E24-40BF-9E8F-2EA7C70B65B9`. Different isolated paths
present as a fresh browser profile without implying deleted data.
`CRMainDylib` only creates missing skeleton directories and sets
environment home; it does not delete the old directory. The user must
preserve both directories, DEFAULT and Chrome app data while validating.
Do not automatically migrate/delete/revert storage paths to hide the alert.
Further edits require exact app-to-Helper IPC/sandbox evidence from the
mobile-only device log after rebuilt package deployment.

Latest Roothide iOS 15.8.8 Chrome evidence: PID 2767 logs
`Crane: app dylib loaded bundle=com.google.chrome.ios pid=2767
containerEnvPresent=0`, so main ` Crane.dylib` injection **works** but
the selected `CRANE_CONTAINER_IDENTIFIER` is absent. Helper replies
`helper=1` for attempts 1/2/3 but cannot attest an app container it never
received. Compared original CraneSB `0x180F0/0x1BF10/0x1BD44`: on modern
iOS SpringBoard returns a container ID, while a separate runningboardd
RBProcessManager hook injects it into `_additionalEnvironment`. Some Roothide
Bootstrap variants restrict daemon injection, so the missing runningboardd
path is plausible, not yet independently proven. Implemented a
**CRANE_ROOTHIDE-only, source-backed compatibility attempt** in
`CRApplyModificationsIfNeededToExecutionContext`: before the FBProcess
launch call, use the available `_additionalEnvironment` modern or
`environment` native legacy context accessor pair, run the unchanged
`CRApplyEnvironmentChanges` libSandy/helper insurance and validated ID
check, and write only when a new environment for the selected UUID was
returned. Rootful/native runningboardd path unchanged; post-launch
missing-proof alert remains. The fallback may fail when the context
lacks both selector pairs or fails to propagate values between SpringBoard
and runningboardd. `check_roothide_launch_environment_contract.py` tests
source guards, rootful compile gating and denial/validity cases in CI.
**Requires native build and Chrome proof after installation; do not claim fixed
based on an applied log alone.**

Follow-up Chrome device logs: PID 2339 produced duplicate post-launch checks
for each of attempts 1–3, all `helper=1 error=(null)`; user confirms Choicy
is **not installed**. The retry did not produce injection proof. The earlier
grep did not include the existing `CraneSB: constructor reached` log, and
` Crane.dylib` only logged app-init when the nondefault container environment
was already supplied. Added an explicit diagnostic in the main dylib
constructor for non-Apple apps when `CRANE_CONTAINER_IDENTIFIER` is absent,
to distinguish a loaded image with no environment from an image that never
loaded. Added a per-FBProcess/PID association to suppress duplicated
registration of the same post-launch verification from overlapping
FBProcessManager hooks (without persisting global PID state). Verified the
original binary main filter `Bundles: com.apple.Foundation, Flags: 0` and
CraneSB filter `Bundles: com.apple.springboard, Executables: runningboardd`;
the reconstruction filter plists match. CI source contracts verify package
rename to the **leading-space** ` Crane.dylib`, both filters and diagnostic
lifetime. No proof yet whether the roothide injector loads these dylibs into
Chrome/runningboardd. Do not blame absent Choicy, skip injection attestation
or increase retry count; collect the expanded constructor and main-dylib
diagnostics after deploying the rebuilt package.

The iOS 15.8.8 Roothide device now reaches the Chrome container Settings
page and opens its Filza container path, but SpringBoard alerts that the
application started into DEFAULT because ` Crane.dylib` was not loaded. Filza
only confirms LaunchServices/File Manager access to the container directory,
not app-side injection. The runningboardd path may fail to provide the
nondefault ID if `CraneRB` sandbox profile/selector/launch-context is missing;
or the main app-side constructor may be disabled by a tweak manager, fail to
run, or have its independent `runtime_report` arrive later than the immediate
helperd `lookup_pid` check.

A new **bounded post-launch proof retry** in `CRSpringBoard.m` retries only
the `connectionWorks=YES` + no live app proof branch two times (750ms apart),
rechecks running state and the exact launched PID and retains both missing
proof and transport error behavior. No helper protocol selectors, privileges
or injection failure classification are bypassed. Added runningboardd
selector/profile/environment logs and helperd accepted/rejected runtime
report and PID-proof status logs (no path changes or auth weakening).
`check_postlaunch_injection_contract.py` now runs with rootful/roothide CI.
`XPC_PING_DEVICE_TEST.md` describes the mobile-shell capture matrix and the
necessary distinction between a missing launch environment, a blocked tweak
injector/Choicy configuration and a delayed/rejected helper report. All
changes are source-tested only; a genuine missing injection or runningboardd
hook requires an evidence-backed fix after on-device logging. **Do not call
Chrome isolation fixed until a launched Chrome process emits app-init proof
and helperd confirms its nondefault container.**

## Quy ước

- **ABSENT**: chưa có triển khai chức năng tương ứng trong source.
- **PARTIAL**: có source/hook nhưng còn hành vi, tích hợp hoặc giao thức chưa tương đương.
- **SOURCE_PORTED**: triển khai mã nguồn được báo cáo hoàn chỉnh, **không có nghĩa runtime pass**.
- **VERIFY**: không kết luận thiếu mã chỉ từ tài liệu cũ; phải so lại source với export trước khi bổ sung.
- Ưu tiên **P0** cho các dependency trọng yếu/isolation, **P1** cho chức năng người dùng, **P2** cho tích hợp.
- Đây là **backlog triển khai**, không phải tuyên bố binary parity, CI xanh hay chạy ổn trên thiết bị.

## Device regression follow-up — blank Settings and container/Chrome crashes

User reported blank Applications/Active Container labels and crashes on create, rename, set-active and Chrome launch. Supplied log proves the registry active ID was saved but contains no exception/backtrace, so exact on-device crash attribution remains open.

- Roothide builds now select the SDK `jbroot` path resolver via exported `CRANE_ROOTHIDE=1`, preserving existing `/var/mobile` user-data paths. The previous native `/var/LIY` fallback could miss randomly rooted installed resources.
- Shared `CRLocalization.h` retains valid empty translations, but returns a key/English value rather than nil when the bundle or table cannot be read. Logs the resolved bundle path/availability. Renaming/creation now use existing English-table action keys.
- Corrected `PSListController indexForIndexPath:` from object to `NSInteger`; ARC must not retain a returned numeric index. Added explicit initial groups to the application list/configuration. Active-row refresh finds its key instead of assuming the first cached specifier.
- Detail and application observer/action refreshes coalesce onto the main queue after selection callbacks. Replaced reconstructed animated container-row replacement with a complete deferred refresh, avoiding two independent caches during private table animation.
- Verified native `HCHookFunctions` 0x7360-0x7380 preserves x0/w1 at the libhooker tail branch. Corrected the backend pointer/call to pass table/count, with the public symbol as fallback. Tracked native bytes in `fixtures/main_hook_tailcall.json` for Git-checkout evidence.
- App initialization now snapshots all `getenv` values before `unsetenv`. Sandbox-path rewriting checks HOME/buffer/size and leaves the original output intact when the full home cannot fit. Added init/home/environment-ready logs.
- Added `check_ui_runtime_contract.py` and an actual shared-localization Foundation smoke to both CI variants. Local contracts do not establish runtime crash resolution. **Need rootful/roothide native builds, the Preferences/Chrome crash reports and device re-test.**

## Device log follow-up — mkdir EEXIST and missing long-press menu

The 23:12:41/23:12:52 device logs identify a deterministic reconstruction
failure: `CRManagerCreateEmptyContainer` visits `Library` for each nested
subdirectory and called single-level mkdir again after it already existed.
The original Crane initializer `0x65D0` uses `0x6BE0`'s existence check.
`CRContainerScaffold.h` now uses a real-directory existence check before mkdir,
retains symlink/non-directory rejection, and includes the original
`Library/SplashBoard` directory. Fresh create, repopulation and wipe share the
same actual helper. Creation returns/stores a filesystem error and Settings
does not log a nil ID as a successful creation.

Long-press code was compared with CraneSB `0x1ECD8/0x1EE64/0x1EEF0/0x1EF7C`,
`0x15E20`, `0x1611C`, `0x145B8`, `0x1497C`, `0x14D18` and `0x137FC`.
The recovered predicates explicitly return YES for unset shortcut/new/only-show/
badge preferences, while reconstructed menu queries treated every nil as NO.
The shared boolean helper now restores those defaults, preserving explicit
false values and nil->NO for launch/expand switches. The original >1 count gate
is unchanged: it assumes `Containers` includes DEFAULT. A compatibility
projection in `CRContainerRegistry.h` supplies one DEFAULT for older custom-only
registries and preserves registered custom entries; saved settings use that
same representation. This is an explicit adapter because libcrane's native
storage body has no export, not a claimed recovery of its binary internals.

The supported-app gate now reads the shared synchronized registry before
checking membership. Modern/legacy menu initialization restores the original
children-before-title placeholder replacement precedence. Exact original
SpringBoard selectors and the context->placeholder->replacement chain remain.
Added diagnostics for installed selectors, query gate reason, selected app,
replacement count/active ID, and the Crane Error alert's actual message.
The supplied log proves corrected resource lookup and labels but does not
contain the alert text or a Chrome crash backtrace.

`check_shortcut_gate_contract.py` checks the original defaults/gates and optional
local export cross-check; `container_menu_smoke.m` executes the production
scaffold, registry projection and boolean defaults on macOS CI, including real
fresh/repeated directory creation and file/symlink collisions. All 24 local
Python contracts pass; **native CI and device menu/create verification remain
pending**. No commit/push.

## 1. Danh sách triển khai

| ID | Feature | Trạng thái | Đầu việc cụ thể | Bằng chứng / nơi kiểm tra | Priority | Điều kiện nghiệm thu |
|---|---|---|---|---|---|---|
| F-01 | Launch redirection | SOURCE_PORTED / untested | Kiểm tra ABI SpringBoard/runningboardd và launcher integration thực tế | `CRSpringBoard.m`, export 0x1BF10/0x1BD44 | P0 VERIFY | Build + test launch DEFAULT và non-default, injection insurance |
| F-02 | In-app env/dirs | SOURCE_PORTED / untested | Không tự port lại; regression environment/layout | Main dylib | P2 VERIFY | Directory/environment differential tests |
| F-03 | File/container isolation | SOURCE_PORTED / untested | Test unlink/path isolation, ghi nhận NULL edge case bản gốc | Main dylib | P0 VERIFY | Không rò hoặc xóa nhầm dữ liệu giữa containers |
| F-04 | Sandbox lookup | SOURCE_PORTED / untested | Test sandbox lookup theo app/container | Main dylib | P1 VERIFY | Differential test |
| F-05 | Preferences isolation | PARTIAL, bounded UTF-8 pathname rewrite + PID-cache invalidation | Avoid partial/unterminated cfprefsd `.plist` paths; authenticated runtime container proof now clears any earlier DEFAULT PID cache. Verify on-device ordering because the very first prefs query can still precede the asynchronous app proof | `CRCfprefs.m`, `CRMCM.m`, `CRHelperd.m`, `CRManager.m`, `0xADF0/0xB4D0`, original cache 0x12724/0x12A4C | P0 DEVICE VERIFY | Preferences độc lập giữa container; proof arrival repairs transient negative cache; no persistent DEFAULT leakage after proof |
| F-06 | Container resolution | PARTIAL, guarded app-home/population + live registry cache coherence | Optional `LSApplicationProxy.dataContainerURL` resolver + restricted `_populateContainerDirectory:ofType:` added. App sends its non-default live proof immediately after the launch claim is snapshotted/hidden and before directory/HOME setup to narrow the first-query race. Preserve original `CraneSB/Loaded` clear and add reconstruction-only `RuntimeRegistryChanged`: helper posts it on accepted non-default `Crane` proof and peer disconnect, clearing daemon `ClientContainerCache`; a monotonically increasing cache generation rejects any older in-flight reply whose async write would otherwise repopulate DEFAULT/positive state after the clear, so early misses and stale PID reuse do not persist | `CRMCM.m`, `CRHelperd.m`, `CRPaths.h`, `CRManager.m`, original 0x12724/0x12A4C, U-01/U-04 | P0 DEVICE VERIFY | Container data/group paths đúng; same PID resolves to non-default after proof; an in-flight pre-proof reply cannot overwrite the cleared cache; exited/reused PID cannot inherit stale container |
| F-07 | Keychain isolation | PARTIAL; normal securityd path transcribed, global CraneSupport injection/fix-up DEVICE-PROVEN | The historical 0/7 daemon failure is resolved. On iOS 15.8.8 at 2026-10-14 10:20 the helper completed `attempted=1 inProgress=0 success=1 errorCode=0`, and insurance returned `works=1 connection=1 broken=`. Debugging fixed the cold-helper readiness race, target-transition false failure, non-original post-inject polling, and the Roothide `opainject` timeout false-negative. Temporary flags/plain/bare loader probes are now archived source only and no longer ship; the per-launch seven-daemon health matrix and app transport ping were also removed. | `CRSecurityd.m`, `CRSupport.m`, `CRHelperd.m`, `CRManager.m`, `CRErrorAlerts.m`, `CraneSupport.plist`, `ORIGINAL_CRANESUPPORT_AUDIT.md`, CraneSB 0x1B45C/0x1BAA4/0x1782C, CraneSupport 0x6C5C/0x6E44/0x11E5C, U-01/U-03 | P0 DEVICE VERIFY | Global daemon injection is no longer the acceptance blocker. Verify actual per-container keychain add/copy/update/delete behavior in securityd, collect normal-symbol status, and only consider the unrecovered 0x11C08 private-symbol fallback if device evidence reports `missing_private_symbols`. No Userspace Reboot requirement. |
| F-08 | APNs/notification routing | PARTIAL, topic decoding guarded | 0x8C78/0x932C reject malformed hex/appId mapping keys; 0x8854/0x8E1C safely parse token keychain account; 0x96C8/0x989C preserve original payload on invalid type. Continue CBEC async metadata and real delivery tests | `CRApsd.m`, CraneSupport 0x8B24/0x8C78/0x8854/0x8E1C/0x932C/0x96C8/0x989C, U-10 | P1 | Valid tokens/topics route by container; invalid input leaves APNs unchanged |
| F-09 | System accounts | PARTIAL, guarded Core Data attachment | Modern 0x7CB8 only installs per-container coordinator after SQLite attach succeeds; modern/legacy 0x8324 validate container key, Crane store root and database/sidecar symlinks; gamed transport and actual accountsd device behavior still need verification | `CRAccountsd.m`, CraneSupport 0x7CB8/0x8324, U-01 | P1 | Isolated accounts stores load correctly; failure leaves previous account database intact |
| F-10 | Game Center | STRUCTURE ONLY | Khôi phục model Game Center/manager state từ binary còn thiếu; không phỏng đoán | U-06 trong hiện trạng feature (lưu ý U-06 trong uncertainty register là backup format) | P1 BLOCKED BY EVIDENCE | Đúng enable list và container/account behavior |
| F-11 | Device ID | PARTIAL, guarded settings subset | Manager UUID selection corrected to match LSD fallback; readonly ID and conditional non-DEFAULT use-container-ID switch (only with valid existing custom UUID) added; original setter/helped lsd storage and authentication remain unverified | `CRLsd.m`, `CRManager.m`, `CRPreferences.m`, CranePrefs 0x10608/0xF8F0/0x12F74 | P1 | UUID ổn định và cách ly theo container |
| F-12 | Plug-in enumeration | PARTIAL, scoped synchronous query + Shortcuts fallback | The 0xFD70/0xF174 container rule is now scoped to the synchronous match on the invoking thread, with nested restoration and one-shot consumption; protects different threads from global cross-tagging. Async cross-thread attribution remains unverified; Shortcuts discovery is guarded | `CRPkd.m`, CraneSupport 0xE888/0xEC44/0xF174/0xFD70/0x101CC, U-10 | P1 | Correct plugin results by synchronous container query, no pkd crash/hang |
| F-13 | Selection UI | PARTIAL, direct-icon picker device-proven | BOOL callback/delay, unset shortcut defaults, DEFAULT-inclusive registry/count model and child-before-title replacement remain; direct-icon Always Ask path ports the per-app 0x1F008 gate, 0x12B3C picker and all three 0x18354/0x18580/0x18710 `SBIconController` launch hooks. User device on iOS 15.8.8 confirms Always Ask works with Chrome and the selected non-default container reaches the app/helper proof path | `CRSpringBoard.m`, `CRMenuHooks.m`, `CRPreferences.h`, `CRContainerRegistry.h`, 0x1F008/0x12B3C/0x18354/0x18580/0x18710 | P1 VERIFY LEGACY/DIFF | Legacy iOS 11/12 + biometric/delay differential + UI comparison |
| F-14 | Badge UI + store | PARTIAL, active work | Badge store + native-aware `SBIconBadgeView`/`CRFakeIcon` menu renderer ported, fallback label retained; verify Theos build and UI/device screenshot, validate async refresh | `CRBadgeStore.m`, `CRBadgeAction.m`, `CRMenuHooks.m`, 0x7F58/0x8ED4/0x13508/0x190D4 | P1 | Accurate aggregate and per-container display, zero removes scoped notifications |
| F-15 | Settings UI | PARTIAL, notification permissions + Browse Data | Game Center settings, async size, Filza app-path browser and native-gated per-container Allow Notifications toggle implemented; reset registration backend remains stub; finish backup/restore, groups/plugins, device ID and device UI tests | `CRPreferences.m`, `CRBadgeStore.m`, CranePrefs 0x11734/0x13980 | P1 | 3/3 panes + expected subcontrollers and navigation |
| F-16 | Lifecycle | PARTIAL, idempotent guarded scaffold | Scoped app-home and unknown discovery retained; repeated Library mkdir EEXIST fixed, SplashBoard added, creation error propagated; retain staging/wipe guards and validate device CRUD | `CRManager.m`, `CRContainerScaffold.h`, Crane 0x65D0/0x6BE0, U-04/U-09 | P0 | CRUD không mất dữ liệu; migration consistency |
| F-17 | Backup/restore | ABSENT | Reverse/archive manifest, restore, encryption, keychain dump; triển khai sau lifecycle/keychain | `CranePrefs_export_for_ai`, U-06 | P1 BLOCKED BY EVIDENCE | Round-trip data/keychain, corrupted archive failure safe |
| F-18 | Biometrics | SOURCE_PORTED / untested | Biometric switch regression tests | Source biometric hooks | P1 VERIFY | Success/cancel/locked behavior |
| F-19 | Helper XPC | PARTIAL, safe unsupported delegates | Authenticated raw-XPC health/attestation remains; credential-less ObjC delegate no longer fabricates Device ID from daemon defaults or fake empty Keychain backups; restore/setter refuse unsupported operations | `CRHelperd.m`, `CRManager.m`, U-01 | P0 BLOCKED BY EVIDENCE | Authorized requests and original protocol compatibility, runtime tested |
| F-20 | Self-verification | PARTIAL, native didFinish chain restored | 0x1782C helper-start/recheck, 0x179C4 failed-fixup error capture, `CraneSB/Loaded`, 0x12AD0/0x12B30 keychain migration state and background badge init are ported; daemon error UI now appends native fix-up description. Original helper-side fix-up normal path is now SOURCE_IMPLEMENTED through the authenticated helper adapter; the reconstructed proxy preserves the recovered `(BOOL, NSError *)` ABI and fails closed on helper/injector/verification errors | `CRSpringBoard.m`, `CRErrorAlerts.m`, `CRManager.m`, 0x14894/0x1782C/0x179C4/0x12AD0/0x12B30, U-01 | P1 VERIFY / U-01 | Missing dylib vs communication/fix-up failures correctly distinguished on device |
| F-21 | Choicy | PARTIAL, editor source ported / untested | Dynamic optional editor subclass, scoped read/write, Crane tweak filtering and active-only reload restored from native callbacks; ABI mismatch retains read-only preview | `CRChoicyEditor.m`, `CRPreferences.m`, CranePrefs 0x3F108/0x3F250/0x3F39C/0x3F3A4/0x3F44C/0x3F5C0/0x3F774 | P1 | Native rootful/roothide build and per-container editor/provider device tests |
| F-22 | Siri/Shortcuts | ABSENT | Recover `CraneIntentHandlerShared` and intent response codes; extension packaging | U-08; missing Shortcuts export | P2 BLOCKED BY EVIDENCE | Siri intents correctly invoke container actions |
| F-23 | Activator | PARTIAL, validated listener/event handling | Verify exact generated event/listener names and registered target, reject stale/nonexistent containers on receive/abort; runtime icon and actual Activator event dispatch still need testing | `CRActivator.m`, CraneSB 0x1C8B0/0x1CF4C/0x1D130/0x1D82C | P2 | Event registration, switch, abort, icon differentiation |

**F-08 APNs topic-key and token-result decoding (`CraneSupport 0x8B24/0x8C78/0x8854/0x8E1C/0x932C/0x96C8/0x989C`):** Original `dataForHexString` reads two characters per byte without testing odd input length, and `topicStorage_decodeKey` accepts the first/last parts of malformed `hex/appId` values. On corruption this may alias another APNs hash or produce an out-of-range ID. `CRApsd.m` now rejects non-hex/odd/empty hash strings, requires exactly one `/` and a uint16 decimal app ID, and returns no mapping rather than silently truncating. The legacy `ffffffXX` signed-byte representation still decodes for valid keychain accounts; invalid/incomplete pairs, wrong entry/data/account types and malformed incoming token/hash or token response types no longer rewrite topic hashes. These are deliberately stricter guards than the native code; the existing valid topic mapping/removal, notification availability gate and XPC selector layout remain unchanged. Added `check_apsd_topic_contract.py` with decoder/payload source checks plus independent valid/invalid maps to rootful/roothide CI. **Real APNs registration and push delivery in multiple containers, newer APS keychain deserialization, and NSXPC callback timing remain unverified**; F-08 is still partial.

**F-12/F-22 guarded Crane Shortcuts discovery (`CraneSupport 0x101CC`):** The fallback for `LSApplicationWorkspace.pluginsMatchingQuery:applyFilter:` remains scoped to an empty original result, `IntentsSupported`, a CraneApplication containing path, and `com.apple.intents-service`; the exact original Shortcuts bundle identifier is unchanged. Added type checks for `NSDictionary` and `NSString` query fields (avoid sending `containsString:` to `NSNull` or unexpected XPC values) and a `respondsToSelector:` gate for the optional private `LSPlugInKitProxy.pluginKitProxyForIdentifier:` method. When the proxy is unavailable, the original result is retained rather than crashing pkd. New `check_pkd_shortcuts_contract.py` covers legitimate fallback, invalid payloads, nonempty Apple results and missing proxy; integrated into both CI variants. This **does not reconstruct the Siri/Shortcuts intent handler** or prove packaging, so F-22 remains incomplete.

**F-12 PlugInKit scoped synchronous query state (`CraneSupport 0xFD70/0xF174`):** The native implementation stored `crane_containerID` in a process-global `gCRPkdContainerID`, allowing stale sequential state and cross-talk if independent transactions interleave on separate threads. The reconstructed `CRPkdMatchPlugIns` now uses `NSThread.threadDictionary` to scope the validated container identifier to the invoking thread and the dynamic duration of the original `matchPlugIns` call. It clears any inherited value on entry, strips the private Crane XPC rule, restores the outer value on nested calls, and always restores/cleans the scope in `@finally` if the match returns or throws. The four `CRPkdFindPlugIns` wrappers consume only the invoking thread's scoped identifier once. Valid `DEFAULT`, UUID and safe imported names remain supported; malformed rules are rejected without passing Crane's private key to Apple. Updated `check_pkd_query_state_contract.py` in rootful/roothide CI to cover independent interleaved thread contexts, nested matches, aborted matches, invalid IDs and cross-thread fail-closed behavior. **Limitation:** this relies on a synchronous call chain. If Apple's matcher dispatches database queries asynchronously to another thread, the resulting plugin remains untagged rather than inheriting another transaction's container. Actual transaction-to-database attribution, cross-thread callback timing and pkd runtime tests are still required before F-12 can be called complete. This change deliberately differs from the native process-global lifetime; no XPC or SpringBoard ABI change.

**F-12 PlugInKit reload and bounded termination (CraneSupport `0xE888/0xEC44`):** In `CRPkdReloadApplication`, the original code (and previous reconstruction) enumerated an `NSMutableArray` through `reverseObjectEnumerator` while removing notification-service extensions from the same array. This can throw `NSGenericException` (collection mutated during enumeration) on pkd reload. The rewritten path copies eligible plugins into a separate array, retaining native exclusion of `com.apple.usernotifications.service` while allowing other plugins to terminate on application reload. `CRPkdTerminatePlugIns` still supports both PKDServer selector variants and the original no-argument reply block; on older APIs it now waits **at most 5 seconds** rather than `DISPATCH_TIME_FOREVER`, logs timeout and continues after requesting termination. These are explicit safety deviations from the native 0xE888 code, designed to avoid hanging pkd if an older PKDServer drops the callback; a timeout does not prove plugin termination succeeded. New `check_pkd_lifecycle_contract.py` covers both APIs, filtering, callback shape and timeouts, wired into rootful/roothide CI. F-12 still needs on-device PlugInKit class selector, notification-service environment and synchronous-versus-async query differential tests; a thread-local scoped rule does not provide identity for callbacks dispatched onto a different thread.

**F-09 accountsd isolated Core Data store attachment (`CraneSupport 0x7CB8/0x8324`):** The modern reconstructed `ACDAccountStore` flow previously ignored the return value of `addPersistentStoreWithType:NSSQLiteStoreType` and changed `_persistentStoreCoordinator` even if the per-container SQLite store failed to open. The new flow checks the returned `NSPersistentStore`, captures/logs `NSError` and refuses to change the live coordinator or `crane_activeContainer` when the attach fails. Both modern and legacy paths now validate the normalized SQLite filename component, existing/created Crane directory, and symlink/non-file collisions on `.sqlite`, `-wal` and `-shm` before opening, while retaining native `CRCreateDirectoryIfNotExists` ownership behavior. The modern cache also refuses to reuse a coordinator with no persistent stores. This deliberately strengthens the original 0x7CB8/0x8324 implementation; it does **not** claim atomic filesystem security (path preflights remain subject to concurrent changes) or full accountsd/Game Center parity. A new `check_accountsd_isolation_contract.py` enforces the attach-before-switch ordering and models failure retention and path/sidecar cases; run on rootful/roothide CI. The user should test real accountsd initialization, system account separation, iCloud follow-up suppression and database migration on roothide 15.8.8; avoid mixing real accounts until tested.

**F-19/F-07 privileged helper methods — no fabricated success:** The original `cranehelperd` protocol and securityd/keychain archive format are not exported (U-01/U-03). The earlier reconstructed `CRHGlobalServiceDelegate` incorrectly read/wrote a daemon-local `NSUserDefaults` key for Device ID, which is not equivalent to the lsd/vendor identifier. It also replied `@{}` to a Keychain dump, falsely signaling a legitimately empty successful backup. These unsupported delegate operations now explicitly log unavailability and return `nil` for the identifier lookup and Keychain dump; identifier writes and Keychain restores remain non-mutating with log messages. The selectors and reply arities are unchanged, and the caller-authenticated raw-XPC health, PID lookup and runtime attestation surface is untouched. This is **fail-closed helper-delegate safety work, not working Device ID / Keychain backup-restore or a restored native helper XPC protocol**. Runtime Keychain isolation is now separately implemented in `CRSecurityd.m` on the original five-symbol path; the helper archive format remains unavailable. Added `check_helper_privileged_contract.py` to both CI variants, checking that no daemon-local defaults or fake empty Keychain dump can be mistaken for backend success. On-device backup/restore must not be offered until the real securityd/keychain pipeline is recovered.

**F-05 cfprefsd bounded path rewrite (CraneSupport `0xADF0/0xB4D0`):** The original CFPreferences hook rewrites a `.plist` pathname by narrowing UTF-16 characters into a 0x400-byte C buffer and omits a terminator when truncated. This reconstruction preserves its ASCII filenames but uses full UTF-8 encoding with an explicit `length < 0x400` guard and trailing NUL; when the full rewrite cannot fit, it leaves CoreFoundation's original path untouched (fail closed rather than writing an unterminated/partial pathname). This is a deliberate safety deviation from native B4D0 for Unicode/oversized names, not a claim of exact parity. `check_preferences_isolation_contract.py` covers the source and UTF-8 boundary model in CI. Runtime cfprefsd/PID→container interception still requires device testing.

**F-15 interactive Game Center row (CranePrefs `0x8D00/0xA4B8`):** Ported missing `setSeparateSystemAccountsValue:specifier:` behavior: after saving setting, insert the cached Game Center specifier immediately after the system accounts switch when enabled; remove it when disabled; avoid repeated insertions and keep reconstruction's specifier cache in sync. Reload the application if its active container is not `DEFAULT`, following the native original. Added guarded Preferences.framework selector declarations and `check_prefs_settings_contract.py` for repeat toggles and reload gating in rootful/roothide CI. Game Center switch handling now also follows native `0xA670`: persist, call `gameCenter_reloadExceptApplicationWithIdentifier:nil`, and reload the application on disable. The manager's global Game Center reload is **still a stub**, so this does not complete F-10. Other Settings functionality (Choicy's dynamic editor, suggestions, backup/restore) remains partial.

**F-15 container size footer (CranePrefs `0x113A4/0x1148C/0x11520`):** Added a read-only size footer to the reconstructed per-container settings page, with an initial `(...)` placeholder and `NSByteCountFormatter` output after asynchronous calculation. `CraneManager` now scans only the app-scoped verified container path on a utility queue, skips symlinked entries, counts regular files with saturating unsigned 64-bit arithmetic, and dispatches its completion to the main queue. The Preferences controller discards late callbacks if the app/container identity or request generation changes, preventing a result for the previous page from updating the next one. No synthetic fallback to shared Crane storage. New `check_container_size_contract.py` covers native selector use, threading, validation and stale-callback cases in both CI variants. **The original libcrane scanning algorithm is not exported**; filesystem accounting, accuracy, runtime UI refresh and native Theos builds still require device validation.

**F-23 Activator listener/event validation (CraneSB `0x1C8B0/0x1C924/0x1CF4C/0x1D130/0x1D82C/0x1D8A0`):** Activator listener and changed-to-container event names are now accepted only when they exactly match Crane's generated `prefix.Action|app|container|` or `prefix.Action|container|app|` shape. The native parser accepted broad substrings/prefixes, but a malformed or foreign Activator event could feed invalid IDs into switch/abort flows. On receive, the listener must still be registered, the target app installed, and the target container still registered (or `DEFAULT`), and the previous active ID must be a nonempty string before assigning event rollback metadata. On abort, the same registered-listener and installed-app guards apply; rollback is refused when its target container no longer exists. This is intentional defensive validation, not instruction-for-instruction parity; the original biometric success callback/selection remains unchanged. `check_activator_contract.py` validates source dispatch and independent parser/eligibility cases in both CI variants. **Activator framework runtime, event execution, icon generation, and actual device callback timing remain unverified.**

**F-11 guarded Device ID options (`CranePrefs 0x10608/0x12EE8/0xF8F0/0x12F74`; `CraneSupport/CRLsd.m`):** The previous reconstruction of `deviceIdentifierToUseForContainerWithIdentifier:ofApplicationWithIdentifier:` returned nil for an unset `useContainerIdentifierAsDeviceIdentifier` preference even though native CranePrefs defaults this to enabled and the existing LSD hook falls back to the container ID. It now selects the non-DEFAULT container UUID when the switch is absent/true or a valid custom UUID is unavailable, and uses a verified custom UUID only when explicitly selected. For supported apps (`applicationHasDeviceIdentifier:`), the non-DEFAULT Settings detail pane displays the selected UUID read-only. It exposes `USE_CONTAINER_IDENTIFIER` only if there is already a *valid stored custom UUID*, so turning it off has a meaningful, non-null LSD result. The toggle persists only the per-container preference; Settings changes take effect on the next device-ID request and are not asserted to force a live application reload. **Generate New, Set Custom and editing DEFAULT are deliberately withheld:** the original helperd/lsd setter, vendor cache and ID generation behavior are not recovered; the reconstruction's `applicationHasDeviceIdentifier:` currently depends on its own preference record, not native eligibility discovery. The new `check_device_identifier_settings_contract.py` covers defaulting, UUID guard, UI visibility and agreement with `CRLsd` source in rootful/roothide CI. This is partial F-11, not verified device ID isolation.

**F-15 per-container notification permission (`CranePrefs 0x11734`; `CraneSB/CRBadgeStore.m`):** The reconstructed container detail page now includes a NOTIFICATIONS group, footer and `ALLOW_NOTIFICATIONS` switch, matching the native condition: show only when `notificationsSupportEnabled` (global) and `separateNotificationRegistrationsEnabled` (per-app) are not explicitly false; either key being absent counts as enabled. The setting defaults to true, is persisted only in the selected container's settings as `notificationsAllowed`, and is already read by the existing CraneSB notification routing filter (absent key = allowed). No app-wide setting or DEFAULT exclusion is invented. **The native Reset Notification Registration button (`0x13980`) is deliberately not exposed**: `CraneManager.unregisterFromNotificationsIfNeededForContainerIdentifier:ofApplicationWithIdentifier:` is currently empty in reconstruction. Showing a reset button that silently does nothing would be misleading. The new `check_prefs_notification_contract.py` covers gating, default/persistence, routing key agreement and the blocked reset button; included in both CI variants. Verify notification suppression and reset behavior on device separately.

**F-15 Filza Browse Data (`0x11734/0xDFD4/0xE030/0xE08C/0xE1E0/0xE31C`):** Added `CRPBrowseContainerListController` and the conditional Browse Data link in the container detail pane. Following the native UI contract, show the link only if `UIApplication canOpenURL:filza://` succeeds; pass `applicationIdentifier` and `containerIdentifier` to the detail controller; create path buttons and encode each with `URLPathAllowedCharacterSet` for `filza://view%@/./`. The reconstructed manager has only `pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:` (per-app verified application root), **not** the original manager's category-aware `enumerate:pathsAssociatedToContainerWithIdentifier:ofApplicationWithIdentifier:` callback. Therefore only the known **APPLICATION** path is displayed, while native **GROUPS** and **PLUGINS** entries remain blocked by missing mapping evidence. No path is inferred or fabricated. The path must exist as a real directory, must not be a symlink, and must still be included in the manager's current verified path list immediately before opening Filza (reinstall/stale-link protection). No destructive or filesystem-mutating operations are introduced; Filza itself is a third-party app and can modify data independently after the hand-off. Added `check_browse_container_contract.py` to the rootful/roothide CI matrix. **Native build and on-device Filza URL-scheme and navigation testing remain required.**

**F-21 optional Choicy container editor (`0x10BD4/0x10CD0/0x10D84/0x10E68/0x111AC/0x3F108-0x3F774`):** Added `CRChoicyEditor.m`, dynamically subclassing the loaded `CHPProcessConfigurationListController` as `CRPContainerChoicyOverwriteListController`. Recovered the initializer's five selectors directly from ARM64 LDR-literal instructions and selector references `0x58FD0-0x58FF0`: `shouldShowAppPlugIns`, `shouldShowTweak:`, `readPreferences`, `writePreferences` and `sendPostNotification`. The editor reads `containerIdentifier` from the specifier (0x3F250), hides plug-ins (0x3F39C), hides the leading-space `" Crane"` tweak while delegating other visibility to Choicy (0x3F3A4), loads a mutable per-container override or an empty dictionary (0x3F44C), merges edited preferences into current container settings without writing Choicy's global store (0x3F5C0), and reloads only when the edited container is active (0x3F774). The existing overwrite toggle and Choicy-owned preview remain. Reconstructed guards require compatible loaded method signatures, reject DEFAULT/deleted containers and non-plist edits, dispose failed unregistered classes, and preserve a read-only preview if the private ABI is unavailable. Updated `check_choicy_integration_contract.py` to verify ARM64 selector mapping against a **tracked, byte-for-byte fixture** at `reconstruction/tools/fixtures/choicy_native_selectors.json` (five LDR-literal instructions, selector-reference pointers and NUL-terminated selector bytes extracted from the original memory export). The full `Library/.../CranePrefs_export_for_ai/memory` export is ignored by Git, so GitHub Actions previously raised `KeyError: 258432` trying to read `0x3F180`. CI now forces the self-contained fixture path; local runs with exports also cross-check every byte against native memory and can require it via `CRANE_CHOICY_REQUIRE_NATIVE_EXPORT=1`. This fixes a CI evidence dependency, not on-device ABI validation. Added a Foundation Objective-C smoke fixture compiling the actual editor source in both CI variants: absent/incomplete/mismatched private API, class-name collision, inherited visibility, copy independence, scoped merge/persistence and active-only reload. **Local Python contracts pass; native smoke, Theos builds and real Settings/Choicy device behavior have not run in this Windows session.** F-21 remains partial until those checks pass.

**ROOTHIDE 15.8.8 — Safe Mode status:** The user confirmed on-device that SpringBoard is no longer entering Safe Mode after the XPC protocol metadata fix. This confirms the original crash symptom is resolved on that device; notification delivery, lsd extension compatibility, and complete Theos/rootful testing remain separate acceptance items.

**XPC protocol metadata incident — roothide iOS 15.8.8 SpringBoard Safe Mode (device report 2026-10-12 09:16):** SpringBoard initializes CraneSB, then crashes with `NSInvalidArgumentException: NSXPCInterface: Unable to get extended method signature from Protocol data (UNUserNotificationProtocolCraneAdditions / crane_unregisterFromNotificationsIfNeededForContainerIdentifier:ofApplicationWithIdentifier:). Use of clang is required for NSXPCInterface.` Root cause in reconstruction: dynamically registered *addition methods* via `objc_allocateProtocol` / `protocol_addMethodDescription` do not provide Clang's extended method-type metadata. The original CraneSB, CraneSupport, and main Crane exports contain compiled `_OBJC_PROTOCOL_$_UNUserNotificationProtocolCraneAdditions` and `_OBJC_PROTOCOL_$__LSDDeviceIdentifierProtocolCraneAdditions` entries; only their **composite** `PlusCraneAdditions` protocols are assembled dynamically. Added Clang-emitted `@protocol` declarations in `CRXPCProtocols.h` and referenced them with `@protocol(...)` from `CRBadgeStore.m` and `CRLsd.m`, while retaining dynamic composition of the private system base and additions. This also preemptively addresses the same crash mechanism in lsd. If an OS still rejects the composite XPC interface, both CraneSB and CraneSupport now log the exception and retry the original system protocol to preserve SpringBoard/lsd availability; Crane's extended XPC methods may then be unavailable. Added `check_xpc_protocol_metadata_contract.py` in both CI variants; old runtime-only registration is prohibited. **Source contract PASS, and the user has confirmed SpringBoard no longer enters Safe Mode on roothide iOS 15.8.8.** This does not verify all XPC functions or rootful compatibility.

**F-06/F-16 guarded app-home resolution and lifecycle (libcrane U-04/U-09; CraneSupport `CRMCM.m` 0xC2BC/0xC3E4; prefs `0x86A8/0xB638`):** The original libcrane implementation is **not exported**. CraneSupport constructs per-container paths relative to the system-assigned app data container. `CRManager` now resolves that base dynamically from optional `LSApplicationProxy.applicationProxyForIdentifier:` / `dataContainerURL`, checks for an existing file URL, standardizes/resolves the path, requires a UUID below the exact iOS `/var/mobile/Containers/Data/Application` (or `/private/var/mobile/...`) root, and rejects symlinked `Library` / `Library/___Crane_Containers`. It never guesses an app UUID, creates an app home, reuses a cached path after reinstall, or falls back to shared `CR_DATA_DIR` when LaunchServices is unavailable. The shared `CR_DATA_DIR` remains **only a comparison to reject, not a container base**. The new resolver is **runtime-guarded but inferred**: the exact native libcrane discovery API is still unknown and system apps/alternate paths may be rejected until verified. Prior reconstruction data created under shared `CR_DATA_DIR` is **not migrated automatically**; no destructive migration has been implemented.

`CRContainerPathForContainer(@"DEFAULT", base)` returns that entire **app base**; hence destructive operations still fail closed for `DEFAULT`, active containers, unsafe IDs, cross-app ID collisions, symlinks, and unknown on-disk targets. New containers are first staged in a unique temporary scaffold and renamed only after successful setup; failed creation never modifies the registry. Failed deletion keeps registry entries, and wipe preserves container metadata with a replacement/backup/rollback sequence. **Read-only unknown-container discovery is re-enabled only for a verified per-app home**, excluding registered/known IDs, symlinks, DEFAULT and `.crane-` staging paths. Unknown import/delete workflows and the original `CRPContainerManager` behavior require separate end-to-end validation before enabling destructive adoption. The private `_populateContainerDirectory:ofType:` selector observed in CraneSupport `0xC2BC/0xC8E8` is now handled by a restricted reconstruction method. Only `type == 1` and an exact non-default `UUID/Library/___Crane_Containers/ID` directory under the known system app-data root are accepted. Unrecognized paths, including group containers and original app-home paths, are left unchanged rather than guessed. **The modern `CRMCMRedirectModernContainer` hook preserves native `0xC8E8`'s call on the original data path, and additionally offers the redirected data component to the guarded helper** so the non-default directory can actually be populated. This extra call is a deliberate integration adaptation rather than native instruction parity. The shared directory-scaffold helper now rejects symlinked or non-directory intermediate components when building `tmp`, `Library/Caches`, `Library/Preferences`, `Documents`, and `SystemData`; these Foundation checks are not atomic against concurrent filesystem replacements. **F-06/F-16 parent-path correction:** `CR_CONTAINERS_DIR_COMPONENT` already contains `Library/`, so prior checks unintentionally probed `<apphome>/___Crane_Containers` rather than `<apphome>/Library/___Crane_Containers`. Both `CRManagerVerifiedApplicationHome` and `_populateContainerDirectory:ofType:` now use one `CRManagerAppContainerParentsAreSafe` helper for the actual `Library` and nested container directory, rejecting symlinks **and existing non-directories** at either level. Create and wipe also reject pre-existing or symlinked temporary staging/backup slot names before creating them, so cleanup cannot deliberately adopt a colliding path. These remain best-effort Foundation preflight checks, **not atomic protection against concurrent modifications**. The F-16 contract tests assert the nested parent path and model symlink/file cases, plus the order of the staging collision guards; they run in both CI variants. **These are source-level safety changes, not native Theos or iPhone runtime validation**.

**F-13 shared Settings shortcut (`0x12720/0x14484/0x19068`):** Both modern and legacy Crane menus call the same Settings deep-link function. Recovered native `appID == nil` versus non-nil empty-string semantics: nil ID still generates `prefs:root=Crane&path=` (or Shuffle `Crane/`); non-nil empty ID generates `APPLICATIONS/`. The enabled Shuffle path uses `kTweaksGroupName` with `nil → Tweaks` only, preserving explicitly empty names, and the native `stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding` instead of `URLQueryAllowedCharacterSet`. Always includes `&path=`. Added static and Python edge-case contracts to `check_legacy_shortcut_contract.py`. **Theos compile and SpringBoard Settings deep-link behavior remain unverified.**

**F-13 iOS 11–12 legacy Force Touch (`0x1555C/0x16A90/0x170A4/0x18A3C/0x18B4C/0x18CFC/0x18D08/0x18E84/0x18F04/0x19000`):** Fixed a native nil-versus-empty-array discrepancy: when expanded shortcuts are enabled, original `applicationShortcutItems == nil` returns only Crane actions, but a valid empty `NSArray` still receives the separator before Crane actions. New `check_legacy_shortcut_contract.py` exercises nil/empty/nonempty ordering, legacy action categories, per-container badge text and Force Touch dismissal/presentation lifecycle; CI runs it for rootful and roothide. Native new-container alert activation schedules exactly one main-queue hop after dismissal: removed redundant `dispatch_async` wrapper in `CRMenuHooks.m`; `CRPresentNewContainerAlert` now invokes the export-confirmed `setApplicationID:` via a guarded typed message send rather than assuming KVC property behavior. **Static contracts pass; Theos native build and iOS 11/12 UI/runtime behavior after this batch remain unverified.**

**F-13 selection callback and launch timing (`0x14214/0x14294/0x143CC`):** Recovered `CraneManager`'s BOOL-bearing success-handler ABI and propagated it through both manager overloads and all reconstruction callers (`CRMenuHooks`, `CRBadgeStore` notification action, `CRActivator`). After a successful protected-container switch, modern menu delays `FBSOpenApplicationService` launch by one second **only when CoreFoundation < 1740.0 and the BOOL is true**; same-container or unprotected switches launch immediately. The reconstruction currently derives the BOOL from `requireBiometricAuthentication` and does not distinguish an actually displayed biometric prompt from `CRRequestAuthentication`'s native-compatible no-biometrics fallback; device differential testing remains needed. `check_container_switch_contract.py` covers ABI callers and the boundary condition and runs in rootful/roothide CI. **Not native-built or on-device verified for this batch.**

**Badge menu renderer (native 0x137FC/0x16A90/0x1C064/0x7F58/0x8530/0x8ED4/0x13508/0x190D4):** Recovered direct modern `CRBadgeAction` factory creation and 32-bit badge strings, and preserved legacy RTL/LTR dot ordering. Added opt-in use of `SBIconBadgeView` with dynamically registered `CRFakeIcon` (`SBApplicationIcon` descendant; native keyed text, accessory text, bundle ID, `_application` KVC bridge) only when native classes/selectors and target `SBApplicationController` application exist. UIKit private action view classes are **not changed**; `UILabel` remains fallback. Cell configuration and `_interfaceActionGroupForActions:` now share badge-attachment logic, including cached app/text identity and removal of stale badges on cell reuse. **Layout hardening (0x8778/0x9464/0x949C/0x9214/0x9360):** the renderer now validates the native badge's intrinsic width, adds an explicit width constraint, and reserves `width + 5pt` by shifting an existing `trailingView.centerX` or `labelStackView.trailing` constraint linked to the action view trailing edge. Unlike the original global-once baseline, the reconstruction retains each UIKit view's original constant and restores it on badge changes or recycled cells; unrecognized anchors are never modified. Group-mode badge actions also create a guarded `_UIContextMenuActionView` if UIKit's `customContentView` is initially missing, instead of silently omitting badge decoration. This is a **safe layout adaptation**, not an exact port of the native subclass's `updateConstraints` / `layoutSubviews` hooks; device UI/layout comparison and both Theos builds still required. `check_menu_badge_contract.py` is wired into both CI build variants.

## 1A. Audit hook-level notification: batch 2026-10-12

| Native offset | Reconstruction | Tình trạng / giới hạn |
|---|---|---|
| `0xA4A0`, `0x20F58` | `CRBadgeContainerForConnectionAndApplication` | Ported gate iOS 17+ and 9 caller sites; runtime unverified |
| `0xFD9C` | `CRBadgePublicSet` | Ported XPC resolver, `intValue`, badge-zero scoped removal; static contract |
| `0xF524` | `CRBadgeRemoveAllRecords` | Ported predicate-based remove-all (does not call unscoped original when enabled) |
| `0xF398`, `0x11FC0` | `CRBadgeRemoveRecordsPassingTest` | Ported predicate then container filter; requires device validation |
| `0xF59C` | `CRBadgeRecordLookup` | Ported filtering and copyWithoutContainerID; type/runtime safety differs defensively |
| `0xF750` | `CRBadgeRecordsLookup` | Ported collection filtering, copied output |
| `0xFA20`, `0x120B0` | `CRBadgeRecordsLookupWithReply` | Ported asynchronous reply mapping using captured connection container |
| `0xBE18` | `CRBadgeRecordSource` | Corrected nil-vs-present keyed userInfo handling; requires live behavior comparison |
| `0xBA6C` | `CRBadgeContainerForNotificationInfo` | Recovered nil userInfo/appID → DEFAULT, present source authoritative, absent source → conditional DEFAULT; generic keyed info |
| `0xF254` | `CRBadgeOuterSave` | Now uses shared 0xBA6C resolver before forwarding and async foreground clear |
| Save revisions/options | `CRBadgeSourceForRecord` | Uses same 0xBA6C resolver; no longer discards nil userInfo/appID or present non-string tagged source in this path |

**Badge aggregate + private setter (`0xAA00/0xAB44/0xBB04/0xFBB4/0xFCA8`):** Bổ sung phép cộng wrap 32-bit cho tổng positive và negative bằng `uint32_t`, sau đó áp dụng signed-negative fallback *sau khi đã wrap* như binary gốc; loại bỏ cộng `NSInteger` 64-bit. Cả queued/private setter lưu `number.intValue` và gửi `NSNumber` 32-bit aggregate cho original. Với `number == nil`, original vẫn xóa count cũ (`[nil intValue] == 0`) nhưng không coi đó là `NSNumber(0)` để remove records; bản port giờ giữ đúng phân biệt này. Regression test có các tình huống tổng tràn 32-bit, chỉ có badge âm, tổng positive wrap về 0, và kiểm tra selector/forwarding. Cần chạy build mới và kiểm thử trên thiết bị.

**Badge store khởi tạo / đồng bộ icon (`0xB00C/0xB688/0xAC2C/0xA860/0xACD0/0xA774`):** Thêm **refresh badge sau khởi tạo** cho những ứng dụng có dữ liệu đã được reconcile/prune, bởi native `0xB00C` gọi `badgeCountStoreUpdateBadge` sau khi sửa dữ liệu còn reconstruction trước đây chỉ ghi plist. Refresh được giữ trong danh sách một lần và tiêu thụ **ngoài `dispatch_once`**, tránh đệ quy `CRBadgeProjectApplicationCount → CRBadgeAggregateCount → CRBadgeStoreInitialize` dẫn đến deadlock. Tổng badge dương được tính từ snapshot **trước khi xóa** container không hợp lệ (native `0xB688`), ghi `DEFAULT` đúng cả giá trị 0 **kể cả khi registry chưa liệt kê `DEFAULT`** (native `0xB00C` không kiểm tra membership trước khi phục hồi), và cộng kiểu `_DWORD` để tránh signed-overflow UB. Getter/setter và giá trị project badge chuyển sang `intValue`/32-bit number theo binary gốc. Các regression assertions mới kiểm tra trật tự, xử lý số và gọi refresh một lần. **Build Theos và runtime sau thay đổi này chưa kiểm chứng.**

**Batch queue-save + badge-zero removal:** `0x10138/0xBF00` queue-save now delegates to the original `0xBA6C`-based shared resolver instead of dictionary-only source extraction; `0xBD98/0xBE80` zero-badge record removal now uses `CRBadgeRecordSource` (`0xBE18`) for keyed userInfo, preventing inconsistent DEFAULT handling. Both have contract regression assertions. Native ABI/device validation still pending.

**Batch 0x10D10 / 0x12424:** pending-request asynchronous callback now uses the same `0xBE18` marker helper as record reads/mutation. Native callback retains its caller container from XPC before dispatch; the remaining divergence is defensive selector/sanitization validation, pending native-device comparison. Verified alongside native `0xFF30/0x10050/0x10138` callback signatures, which remain wired in reconstruction.

**Record/request copy sanitization (`0x1172C/0x11984/0x126E8`) + mutation (`0x115F4/0x1235C`) batch:** `CRBadgeExplicitSourceTagFromInfo` now reads the explicit tag from keyed `userInfo` via typed `objc_msgSend`, even for non-NSDictionary keyed collections. Both record/request copy helpers use `CRBadgeUserInfoCopyWithoutTag`: it requires an independent mutable copy, removes the marker, re-reads the copied result and fails closed on unsupported selectors/exceptions or retained tags; untagged objects still retain native original identity. Single-record, bulk and asynchronous pending-request sanitization share the same marker check, including preventing a tagged pending request from being returned as the original object. Mutated extension content now copies keyed `userInfo` via `0x1235C`-equivalent `setObject:forKeyedSubscript:` rather than dictionary-only code, without changing existing error/fallback behavior. Static regression assertions added; native Theos compilation and device behavior remain unverified.

**Batch 0xBE18 / 0x11884 / 0x115F4:** cùng dùng `CRBadgeSourceMarkerFromInfo` trong record lookup, record similarity và notification-content mutation, bảo toàn `nil` vs `DEFAULT` và keyed `userInfo` gốc. Đã bổ sung regression assertions. Không tuyên bố runtime pass.

**Batch bổ sung:** `0x1119C` bulletin provider và `0x11420` bulletin action giờ dùng chung resolver `0xBA6C` thay vì nhánh kiểm tra riêng chỉ nhận NSDictionary. `0x115F4` content mutation đọc marker từ userInfo keyed collection, giữ phân biệt nil và thiếu marker theo `0xBE18`. Các contract assertions đã được cập nhật.

**APNs registration/invalidation gate 0xDA30/0xDC5C/0xDF68/0xE194/0x11D74/0x11E44:** token request and token invalidation now verify a live, caller-authenticated `CraneSupport` runtime report from `apsd` before constructing a per-container topic; otherwise the original bundle ID is forwarded. Token requests present the existing apsd registration error on failed verification; invalidation follows native behavior without an alert. `CRInsuranceHealthProxy` now accepts only `apsd` and `pkd` in `verifyCraneSupportLoadedIntoDaemon:reply:`; the existing authenticated helper daemon `component_loaded` path and 2s/3s bounded waits are reused. Corrected modern (`0xDA30`, thread-local origin) versus legacy (`0xDF68`, temporary `_bundleIdentifierToSourceDescription` alias) token paths, including native fallback to unencoded bundle ID when the legacy source description is unavailable. Regression checks added. **Native build since these changes and device/APNs operation not yet verified.**

**pkd verification 0xB7B8/0x11CA4/0x11D64 — end-to-end adapter:** Both `CRBadgeModifyPush` and `CRBadgeModifyLegacy` now gate metadata on the recovered `runSafeXPCBlock:` → sync-proxy `verifyCraneSupportLoadedIntoDaemon:@"pkd" reply:` sequence. `libcrane/CRManager.m` now implements **both missing selectors**: it bridges the helper's authenticated `component_loaded` runtime-attestation path (`CraneSupport` in `pkd`) to a bounded synchronous reply. Raw-XPC component checks time out after 2s, synchronous caller waits at most 3s, missing/late callbacks fail closed, and both hook variants use existing `CRPresentPkdRegistrationError`. `CRSupport` already emits its authenticated runtime report from `pkd`; `cranehelperd` already restricts `component_loaded` to trusted CraneSB/CraneSupport callers. The adapter is **reconstruction-specific**, not the original unknown libcrane NSXPC transport; native callback/daemon admission testing remains necessary.

**Mutation metadata 0xEF84/0xF094/0xB7B8:** preserved the conservative enabled-app selection rule and normalized extraction of explicit `crane_sourceContainerID` from keyed `userInfo` (not just `NSDictionary`), with DEFAULT fallback for enabled-app missing tags. The original synchronous `pkd` handshake now has a **read-only authenticated reconstruction adapter**, but full NSXPC-transport and device-behavior parity remain unverified.

**Incoming remote-message permission 0xEDF4:** normalized permission source extraction to the original `0xBE18` helper. The check now runs for nil userInfo and all keyed userInfo rather than skipping non-NSDictionary metadata, and consults `notificationsAllowed` with the exact nil/DEFAULT container. Regression contract added; runtime validation pending.

**Foreground failure-path cleanup:** outer save `0xF254` now schedules the generation-guarded foreground clear inside `@finally`, so exceptions raised by the original save cannot leave process-wide foreground metadata set indefinitely. This defensive reconstruction-only behavior still requires native compilation and fault-injection/device validation.

**Foreground concurrency hardening:** generation guard is now paired with synchronized reads/writes via `CRBadgeForegroundLock`, including `0x10218` comparison snapshot and guarded async clear. If repository `_queue` is unavailable, perform synchronous guarded clear to avoid stale process-wide foreground metadata. These are reconstruction safety changes not present in the recovered unconditional native `0x11FB0` implementation, and require concurrency/device verification.

**Foreground lifecycle audit (0xF254/0x10218/0x11FB0):** retained original save-first/`_queue`-async-clear behavior and added a **reconstruction-only generation guard** so an older asynchronous clear does not erase a newer foreground context. This is intentionally a safety divergence, not binary-exact parity; runtime concurrency test remains needed.

Remaining unresolved: exhaustive `0xCBEC` hook registration matrix, original asynchronous foreground-check propagation, native badge cell/view fidelity, dynamic system-private class availability. This is a **targeted** matrix, not a claim to have audited all 40+ hooks.

## 2. Thứ tự triển khai có dependency

1. **G0 — Evidence & parity audit:** đối chiếu exports và mã mới, cập nhật feature report (F-08/F-14 thay đổi nhiều). Ghi mapping selector → original offset → implementation → test.
2. **G1 — Core transport/data correctness:** U-01/F-19 → F-06/F-16 → F-05/F-09/F-11. Trước khi sửa giao thức phải có bằng chứng từ original daemon; không tạo tương thích giả.
3. **G2 — Isolation/security:** U-03/F-07; tiến hành có test harness, fallback an toàn và thử nghiệm trên thiết bị.
4. **G3 — Notifications:** F-08/F-12/F-14, bao gồm kiểm thử callback bất đồng bộ, badge reset, publish/deliver và foreground semantics.
5. **G4 — User UI:** F-13/F-15/F-21, sau đó F-10 và F-23.
6. **G5 — Data portability:** U-04/U-06/F-17, sau khi F-07/F-16 ổn định.
7. **G6 — Optional integrations:** U-08/F-22.
8. **G7 — Validation:** rootful + roothide Theos build, artifact inspection, installation, injection, 76 test IDs và differential tests.

## 3. Những điều không nên hiểu sai

- Feature summary trong `IMPLEMENTATION_STATUS.md` là **snapshot**, không được tự động xem là đã cập nhật theo các lần sửa gần nhất của `CRBadgeStore.m`.
- `F-10` được gắn U-06 trong bảng feature, nhưng U-06 của `uncertainty_register.md` bàn về **backup archive**. Đây là bất nhất tài liệu cần sửa sau khi có evidence.
- Không gọi 5 nhóm SOURCE_PORTED là runtime passed.
- Không thử backup/restore hoặc keychain trên dữ liệu thật trước khi test hoàn nguyên và isolation.
- Không commit/push thay đổi kiểm kê này nếu chưa có yêu cầu.

## 4. Cách triển khai theo lô (ưu tiên tốc độ nhưng giữ fidelity)

- Mỗi lượt xử lý **3–8 thay đổi có liên quan** hoặc một phân hệ có thể nghiệm thu; không dừng ở một selector/nhận xét nếu còn công việc an toàn trong cùng nhóm.
- Trong cùng lượt: (1) đọc export gốc cho nhóm, (2) đánh dấu ported/partial/missing, (3) sửa tất cả sai lệch đã xác nhận, (4) bổ sung static contracts/regressions, (5) chạy kiểm tra tổng hợp, (6) cập nhật bảng trạng thái và session.
- Ưu tiên batch ít rủi ro: F-08/F-14 notification/BadgeStore; F-13/F-15/F-21 UI; F-05/F-06/F-11 PID routing; không triển khai dựa trên phỏng đoán giao thức/helper, keychain, backup.
- Khi một mục bị chặn do thiếu binary gốc, chuyển sang mục có bằng chứng rõ ràng trong **cùng lượt**, tránh dừng toàn bộ phiên.
- Không commit/push trừ khi được yêu cầu; build native và device tests vẫn là cổng nghiệm thu bắt buộc.

## 5. Các bước thực hiện ngay

- [ ] Lập mapping hook-level cho CraneSB/CraneSupport từ export và mã nguồn; đánh dấu missing/partial/ported có evidence.
- [ ] Khắc phục sai lệch tài liệu F-08/F-14 và bất nhất U-06.
- [ ] Kiểm tra các chức năng Preferences còn thiếu bằng export CranePrefs.
- [ ] Viết regression contracts cho từng hook được port; mỗi patch hẹp một nhóm hành vi.
- [ ] Chạy CI rootful/roothide rồi device tests khi có môi trường phù hợp.
