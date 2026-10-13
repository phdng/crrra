# Reconstruction XPC ping — device validation matrix

The source contract check and a successful Theos build do **not** establish
that the launchd Mach service responds on an actual jailbroken iOS device.

## Prerequisites

Install a package containing **both** the matching `libcrane.dylib` and
`cranehelperd` from the same build. Check the launchd plist is installed and
the helper process starts. Preserve device logs for both listener errors and
client failures. Do not expose privileged RPCs while peer authorization is
unimplemented.

## Tests to perform (not yet observed)

| Case | Procedure | Expected result |
|---|---|---|
| Matched versions | Invoke `-[CraneManager cranehelperdConnectionWorks]` from a worker with the helper running | Returns YES after a versioned `alive=true` reply |
| First UI query | Invoke the method on main thread before any cache entry | Returns NO without a blocking XPC wait; schedules background ping |
| Cached UI query | Repeat on main thread after background ping finishes, within five seconds | Returns latest cached state without synchronous wait |
| Wrong request protocol | Send a ping dictionary with another `protocol` value through a diagnostic client | Helper replies `alive=false` with its own protocol version; normal client treats it as failure |
| Helper unavailable | Stop the helper temporarily in a controlled test; invoke from worker | Returns NO; do not claim a fixed completion duration beyond the two-second wait |
| Error/invalidation | Interrupt a peer connection during ping | Error completes with NO; no crash or hang |
| Delayed reply | Arrange a test peer to respond after the two-second deadline | Returns NO and ignores late completion |
| Recovery | Restart the helper after a failure, then retry after cache TTL | A new probe may return YES; verify independently |

Record iOS version, jailbreak environment, package hash, initiating process,
thread, elapsed time, reply fields, and relevant logs per test. Mark a row
passed only after observing it on-device. The wrong-protocol and delayed-reply
cases require a controlled diagnostic client/peer; no such harness is currently
included in the reconstruction.

## Chrome PID 3756: app Mach profile installed, XPC still invalid

Latest Roothide 15.8.8 trace (Chrome PID 3756) shows the **same selected**
`F7555D97-7AE9-4D62-9BF2-9A9E42AE5BBB` container and repeated
`runtime_report` / same-connection `ping` Code=1003. The file
`/Library/libSandy/CraneAppRuntime.plist` is present and root-owned
(198-byte on-device plist); **this alone does not prove it was applied**.
A later Chrome PID 4261 trace now includes
`Crane: app runtime Mach profile begin pid=4261 marker=APP_RUNTIME_MACH_DIAGNOSTIC_V2`
and `Crane: app runtime Mach profile pid=4261 status=0`. This proves the current
binary entered the diagnostic path and libSandy accepted the profile. The
remaining Code=1003 is therefore downstream of profile application. Comparing
with the recovered `CraneSupport` / `CraneRB` profiles shows the app profile
was missing their second service-specific class,
`com.apple.security.exception.mach-lookup.global-name`, for the same helper
name. The fix mirrors both recovered classes without changing the XPC ABI.

The main dylib now emits a versioned marker
`APP_RUNTIME_MACH_DIAGNOSTIC_V2` before attempting libSandy,
and explicit reasons for no resolved library path, `dlopen` failure,
missing `libSandy_applyProfile` symbol and profile application status.
No sandbox permission, Mach service, report identity or data-path changes
were made in this diagnostic batch. A mobile-shell-only **read-only** script
`reconstruction/tools/diagnose_crane_app_mach.sh` checks the installed
leading-space dylib with `strings`, the actual profile with `plutil` and
provides the exact log filter. Copy it to the device using existing file
transfer or run manually:

```sh
strings '/Library/MobileSubstrate/DynamicLibraries/ Crane.dylib' | grep -F 'APP_RUNTIME_MACH_DIAGNOSTIC_V2'
plutil -p /Library/libSandy/CraneAppRuntime.plist
oslog | grep -E 'Crane: app runtime Mach profile|Crane: app runtime_report|Crane: helper runtime_report error'
```

The version marker is available only after **installing a build that contains
this diagnostic update**; the prior package is expected to lack it. If no
profile log appeared even on the previous build, first check the full
`oslog` output for the non-versioned profile status and distinguish a stale
binary/log filter from actual profile rejection. After installing the
diagnostic build, `profile begin` proves the current compiled call path
was entered, `reason=dlopen/no_apply_symbol` diagnoses library linkage,
`status!=0` means libSandy rejected/failed the grant, while `status=0`
followed by Code=1003 directs investigation toward sandbox/launchd
Mach-service namespace and helper peer connection logs. A successful
profile return is **not** the same as a successful helper attestation.

Avoid further 2-second retry additions, dropping
`XPC_CONNECTION_MACH_SERVICE_PRIVILEGED`, anonymous helper enrollment or
altering Chrome's stored profile while this evidence is missing.

## Chrome PID 3411: sandboxed app cannot reach helper XPC (2026-10-13)

New device evidence after the app runtime probe is definitive at the
**transport** level:

```text
Chrome[3411]: Crane: app init ... container=F7555D97-7AE9-4D62-9BF2-9A9E42AE5BBB
Chrome[3411]: Crane: app runtime_report queued pid=3411
Chrome[3411]: Crane: helper runtime_report error=... Code=1003 ... Connection invalid
Chrome[3411]: Crane: app runtime_report transport probe error ... Code=1003
SpringBoard: post-launch proof missing ... helper=1 (attempts 1/2/3)
```

Chrome is injected and its container environment is present. The helper is
reachable **from SpringBoard**, not from the Chrome app sandbox. Existing
package libSandy profiles `CraneRB`, `CraneSupport` and
`CraneShortcuts` grant the helper's Mach lookup to those processes, but
there is no corresponding grant for arbitrary third-party applications.
This is a strong sandbox/Mach-lookup hypothesis. A Connection invalid result
could also represent a rejected peer or broken listener, so validate again
with the new profile status and the helper's peer logs.

The reconstruction now ships **an additional** profile
`Library/libSandy/CraneAppRuntime.plist`: it allows exactly two Mach extension
classes for the same exact helper name `com.opa334.cranehelperd.xpc`:
`com.apple.app-sandbox.mach` and
`com.apple.security.exception.mach-lookup.global-name`. This mirrors the
recovered `CraneSupport` / `CraneRB` profile pattern and grants **nothing else**.
Its `AllowedProcesses=["*"]` permits Crane to support arbitrary managed apps,
but the profile is only requested by the injected Crane main dylib when a
nondefault container was supplied. Before the existing one-way
`runtime_report`, that dylib calls `libSandy_applyProfile("CraneAppRuntime")`
using the jbroot-resolved libSandy library. It does not grant filesystem
access, authorize other helper operations, claim a PID supplied by the
client, or bypass the Helper's runtime-attestation checks. Both rootful and
roothide package inspection verify that the shipped profile contains exactly
these two classes for this one Mach service and no broader permission. If loading/applying libSandy fails, the existing
connection still attempts normally and the source reports the failure.

After rebuilding/reinstalling the package, on the mobile shell:

```sh
ls -l /Library/libSandy/CraneAppRuntime.plist
plutil -p /Library/libSandy/CraneAppRuntime.plist
oslog | grep -E 'Crane: app runtime Mach profile|Crane: app runtime_report|Crane: helper runtime_report error|Crane helper: (accepted peer|runtime_report|PID proof missing|lookup_pid)|CraneSB: post-launch'
```

- `app runtime Mach profile ... status=0`: libSandy said it applied the
  extension; confirm the **separate** XPC probe reaches `alive=1 compatible=1`.
- `Mach profile unavailable` or nonzero `status`: inspect libSandy
  installation/profile support in the active Roothide bootstrap.
- Compatible app ping but no Helper `runtime_report accepted`: do not infer
  injection proof; inspect rejection and peer registration logs instead.
- Chrome's app report accepted for the **same PID** and Helper
  `lookup_pid ... hasProof=1` is the required end-to-end success.

User data warning: at least THREE different Chrome container IDs have
appeared during testing:
`007FADC7-01AC-4740-AD98-0099E98A32FC`,
`1947F19D-7E24-40BF-9E8F-2EA7C70B65B9`, and
`F7555D97-7AE9-4D62-9BF2-9A9E42AE5BBB`. Their profiles are separate.
Do not delete, reset, merge or overwrite any of them or Chrome's default
container while confirming the current active selection. The XPC fix does
not read/write Chrome's profile files.

## Chrome PID 3100: container supplied, runtime proof missing (2026-10-13)

The latest Roothide 15.8.8 device log conclusively shows Chrome accepted
`CRANE_CONTAINER_IDENTIFIER=1947F19D-7E24-40BF-9E8F-2EA7C70B65B9`.
The app logged `protection=0 spoof=0` and `hooks=0`, which is **expected**:
no protection or sandbox-spoof hook is registered when both switches are
off. `hooks=0` does NOT mean ` Crane.dylib` injection failed. SpringBoard
still missed app runtime proof for the exact PID on attempts 1/2/3 despite a
healthy Helper query. This is now an **app-to-Helper runtime attestation /
live-PID registry** incident, not an environment-propagation incident.

Prior Chrome launch / Filza logs showed a different container
`007FADC7-01AC-4740-AD98-0099E98A32FC`. These are distinct data locations.
If Chrome appears reset, the most likely reason is opening a newly selected
empty container, **not proof of data deletion**. The main dylib's constructor
calls `CRCreateDirectoryIfNotExists` on a container skeleton then updates
`HOME`/`CFFIXED_USER_HOME`/`TMPDIR`; it does not delete the earlier
container. Preserve **both** IDs and the DEFAULT profile; do not wipe, move,
rename or reinstall Chrome while the registry is unverified. In Filza, browse
the known app data-container root and inspect the two UUID subdirectories
under `Library/___Crane_Containers` read-only. The base application's UUID
can change on reinstall, so do not assume the previously logged base path
is permanent.

The reconstructed app currently sends `runtime_report` as a one-way raw
XPC message to `com.opa334.cranehelperd.xpc`. Helper availability from
SpringBoard does NOT establish that Chrome's app sandbox permits this Mach
service. A new diagnostic, restricted to a real `Crane` container report,
sends the existing read-only `ping` on the **same persistent XPC peer**
immediately after queueing the runtime report. An async ping reply confirms
that the app's transport is reachable, **not that injection proof was
registered**. Helper logs report accepted/rejected peer claims, disconnects,
and whether PID lookup is missing due to no peer, process-name mismatch,
no Crane report or an empty container claim.

After installing a matching build, close/relaunch Chrome and capture these
mobile-readable logs (start capture *before* launching):

```sh
oslog | grep -E 'Crane: app (init|environment ready|runtime_report)|Crane: helper runtime_report error|Crane helper: (accepted peer|runtime_report|runtime peer|PID proof missing|lookup_pid)|CraneSB: post-launch'
```

Diagnosis:

- `Crane: app runtime_report transport probe error`: app-to-helper IPC
  cannot complete. Check Roothide sandbox/Mach lookup, installed helper
  listener and matching bootstrap; do NOT relax peer authentication or fake
  successful verification.
- `probe ... alive=1 compatible=1` and `Crane helper: runtime_report
  accepted ... component=Crane containerProof=1`: Helper received proof.
  If lookup then misses it, inspect `runtime peer disconnected`,
  `process_name_mismatch` and exact PIDs; a different PID cannot be
  trusted as evidence for this launch.
- `probe ... alive=1 compatible=1` without an accepted runtime report:
  inspect `runtime_report rejected`, Helper peer process/signing logs and
  protocol; a read-only ping success does not replace the required report.
- `PID proof missing ... reason=no_runtime_peer`: no live report exists;
  `reason=no_crane_report` means another component was present;
  `reason=empty_container_claim` is an incomplete app claim.

The report/lookup authorization and raw-XPC message formats are unchanged.
No client-side probe result turns `injection_verified` true, and nothing
modifies or deletes Chrome's container data. Source contract:
`check_app_runtime_probe_contract.py`. Real device behavior is pending.

### PID cache coherence after runtime proof

The original CraneSupport cache (0x12724/0x12A4C) clears on
`com.opa334.cranesb/Loaded`. The reconstruction additionally learns a
non-default PID/container asynchronously from the app runtime report. A daemon
can therefore perform an early lookup before that report and temporarily cache
DEFAULT. The helper now posts reconstruction-only
`com.opa334.cranehelperd/RuntimeRegistryChanged` when an accepted `Crane`
report carries a real container and when that live peer disconnects; every
CraneSupport `ClientContainerCache` clears on that notification. Each lookup
also snapshots a cache generation before raw XPC, and its asynchronous cache
write is accepted only if the generation is unchanged. Therefore an old
pre-proof reply cannot repopulate DEFAULT after the proof-triggered clear, and a
reused PID cannot inherit a previous positive mapping. It does **not** prove the
first daemon request cannot precede runtime proof.

For the next package, start the log before launching Chrome and look for the
same PID in this order. **Do not reuse the older grep that ends with only
`CraneSB: post-launch` / `CraneSupport: securityd keychain isolation`: that
filter intentionally cannot show the newer `CraneManager`, `support health`,
or `securityd client` diagnostics.**

```sh
oslog | grep -E 'Crane: app (init|environment ready|runtime_report)|CraneManager: helper lookup_pid|Crane helper: (runtime_report accepted|PID proof missing|lookup_pid|runtime peer disconnected)|CraneSupport: (init process=securityd|XPC unsandbox profile.*securityd|securityd (keychain isolation|client))|CraneSB: (post-launch|support health)'
```

For a non-default container, a transient early `lookup_pid ... hasProof=0` is
acceptable only if `runtime_report accepted ... component=Crane
containerProof=1` follows and later lookups for that live PID report
`hasProof=1`. `CraneManager: helper lookup_pid ... injected=1 container=<id>` is
the caller-side equivalent and remains visible even when helperd's own NSLog is
not surfaced by the device log tool. If lookups remain unproven after the app
proof, the cache-coherence adapter is not working.

For F-07, device evidence on 2026-10-13 first showed `CraneSB: support health
process=securityd loaded=0` while the app PID/container proof was healthy. The
recovered CraneSupport constructor 0x6C5C installs `_setXPCUnsandboxHandler:`;
its block target 0x6E44 applies `libSandy_applyProfile("CraneSupport")` and caches
only success. The reconstruction now applies that exact named profile before
its support runtime report and makes later libcrane raw-XPC connections honor
the same retryable handler.

A later rebuilt package (Chrome PID 8799) proves the application side is now
healthy end-to-end: Chrome reports container
`28009C2B-3A8C-4807-BFC6-219EAA490DFB`, SpringBoard's helper lookup returns
`authorized=1 injected=1` with the same ID, and post-launch expected==actual.
The direct-icon Always Ask Before Launch path is also device-confirmed working.
However the same run still reports `CraneSB: support health process=securityd
loaded=0`.

The Substrate filter is not the discrepancy: decoded reconstruction and
original `CraneSupport.plist` both have `Flags=1` and the same executable set,
including `securityd`. The package configure hook currently restarts only
`com.opa334.cranehelperd`; it does not reload securityd. Therefore an upgrade
can leave an already-running securityd on the previous injected image (or with
no CraneSupport image) even though SpringBoard/helper were replaced. Do **not**
port `patchfindSecurityd` based on `loaded=0`: that status occurs before the
five private-symbol lookup path can be evaluated.

After a userspace/securityd reload, start logging before the first Chrome launch
and require these stages in order:

```sh
oslog | grep -E 'CraneSupport: (constructor process=|init process=|XPC unsandbox profile.*process=|securityd (keychain isolation|client))|CraneSB: support health process=|Crane helper: (component_loaded|insurance)|CraneManager: helper (lookup_pid|insurance)|Crane: app (init|environment ready)'
```

The diagnostic build emits `CraneSupport: constructor process=<daemon>
platform=<...>` before any libSandy/profile/XPC work, then asks helperd for
CraneSupport health across the exact seven executables in the recovered filter:
`cfprefsd`, `containermanagerd`, `securityd`, `pkd`, `lsd`, `accountsd`, and
`apsd`. Device run with Chrome PID 939 produced **loaded=0 for all seven** while
the app proof remained `authorized=1 injected=1` with the selected container.
This classifies the current failure as global CraneSupport daemon
injection/load/report failure, not securityd-specific keychain symbol failure.
Do not port `patchfindSecurityd` from this result.

The recovered CraneSB 0x1B45C + callback 0x1BAA4 also establish that insurance
failure returns the original launch environment: the callback is exactly
`(success, brokenDaemons, error)`, then `getLastError` separately classifies the
connection. The reconstruction now mirrors that callback shape and checks the
live runtime registry for each CraneSupport filter target that is actually
running. An on-demand target that is not running does not fail insurance, but a
running target without CraneSupport is reported as broken and a non-default
container environment is not supplied. This prevents an apparently successful
launch with preferences/keychain/APNs/account daemon isolation absent.

`CraneSupport: init process=securityd xpcUnsandbox=1` plus `XPC unsandbox
profile process=securityd status=0` proves the recovered profile gate succeeded.
Then `support health process=securityd loaded=1` proves its runtime report reached
the authenticated helper registry. Only after those facts should `securityd
keychain isolation hooks=5 status=0` (or a `missing_private_symbols` line)
decide whether the normal symbol path works or the original 0x11C08 patchfinder
is actually required. A real SecItem request
then emits the transition-only `securityd client pid=<pid> signingID=<id>
container=<container>` line; for non-default Chrome its container should match
the app proof. `container=<none>` means the hook ran but no non-default proof
was available at that moment and is deliberately not labeled DEFAULT.

Do not use or reset the user's existing Chrome containers merely to generate
this test; use a throwaway account or non-destructive state difference when
checking isolation.

## Chrome launch reports default container (main dylib not confirmed)

Further device evidence (Chrome PID 2767 on the new package): the main
` Crane.dylib` is **definitely loaded** by Chrome, but reports
`Crane: app dylib loaded bundle=com.google.chrome.ios pid=2767
containerEnvPresent=0`. Meanwhile the helper responds successfully for
that PID, yet all three proof attempts fail. This conclusively separates
tweak injection from **missing launch environment**, so do not increase
injection-proof retries, relabel the main dylib, or blame absent Choicy.

The native CraneSB iOS 13+ (`0x180F0`) returns a container ID but relies on
the separate `runningboardd` hook (`0x1BF10/0x1BD44`) to add
`CRANE_CONTAINER_IDENTIFIER`. Some Roothide Bootstrap deployments restrict
daemon injection, which can leave Chrome loaded without a redirected env.
Reconstruction now has a **Roothide-only** guarded SpringBoard compatibility
route: before submitting the FBProcess launch, it attempts the original
`CRApplyEnvironmentChanges` insurance gate using an available
`_additionalEnvironment/_setAdditionalEnvironment:` (preferred) or native
legacy `environment/setEnvironment:` accessor pair. It only writes when
the same validated target ID is returned. The rootful path and native
runningboardd hook remain unchanged. An unavailable execution-context API,
failed insurance or failed propagation still leaves the launch unredirected
and triggers the original post-launch error; do not claim success based
on an `applied` log alone.

On the rebuilt Roothide package, collect only mobile-readable logs:

```sh
oslog | grep -E 'CraneSB: roothide SpringBoard launch fallback|CraneSB: runningboardd|Crane: app (dylib loaded|init|environment ready)|CraneSB: post-launch|Crane helper:'
```

`fallback unavailable ... contextEnvironmentSelectors=0` means neither
verified accessor pair is present on the SpringBoard launch context;
`fallback blocked` means Helper/libSandy verification or ID equality failed;
`fallback applied ... surface=...` says the environment was set on the
context but is **not** evidence that the value survived into Chrome. Success
requires `Crane: app init ... container=<selected UUID>` in Chrome AND
an accepted Helper runtime proof for that PID. If
`fallback applied` is followed by `containerEnvPresent=0`, the execution
context did not propagate the value; inspect Roothide daemon injection
capability and launch request APIs, rather than bypassing Crane's proof.

Follow-up device evidence: Chrome PID 2339 produced *two copies of each*
`CraneSB: post-launch proof missing` line, attempts 1/2/3, all with
`helper=1 error=(null)`. The device has **no Choicy**. This is strong evidence
the helper lookup responds while no app-side attestation is recorded; repeating
the bounded wait alone did not repair injection. The original grep omitted
`CraneSB: constructor reached` and a loaded app dylib with **no**
`CRANE_CONTAINER_IDENTIFIER` previously emitted no `Crane: app init` log.
Therefore the absence of app-init/runningboard logs from that grep does not
conclusively prove either image was never loaded.

A diagnostic update prints `Crane: app dylib loaded ... containerEnvPresent=0`
when the main dylib constructor runs in a third-party app but sees no container
environment variable; it does not change the launch environment. SpringBoard
uses an FBProcess-associated PID token to avoid registering duplicate
post-launch checks for the same FBProcess and PID (a different FBProcess object
can still have its own check). Neither change repairs a missing injector.
Confirm newly installed matching package binaries before interpreting new logs.

From the mobile shell, check the **leading-space main filename** and filters:

```sh
ls -l '/Library/MobileSubstrate/DynamicLibraries/ Crane.dylib'
ls -l '/Library/MobileSubstrate/DynamicLibraries/ Crane.plist'
ls -l /Library/MobileSubstrate/DynamicLibraries/CraneSB.dylib
plutil -p '/Library/MobileSubstrate/DynamicLibraries/ Crane.plist'
plutil -p /Library/MobileSubstrate/DynamicLibraries/CraneSB.plist
```

The original main filter is `Bundles=(com.apple.Foundation)`, `Flags=0`,
and CraneSB matches the SpringBoard bundle plus the `runningboardd`
executable. Having the package paths is necessary, not proof the injector
actually loaded either image. Log the full launch with an expanded pattern:

```sh
oslog | grep -E 'CraneSB: constructor reached|CraneSB: runningboardd|CraneSB: post-launch|Crane: app dylib loaded|Crane: app init|Crane: app environment ready|Crane helper: (runtime_report|lookup_pid)|CraneManager: helper'
```

If `Crane: app dylib loaded ... containerEnvPresent=0` appears for Chrome,
the dylib was loaded but the launch environment was not set: focus on
`runningboardd` hook/profile/context and insurance. If no Chrome constructor
message appears despite a confirmed new package, investigate Substrate/roothide
injection/filter and application launch restrictions. If the constructor
reports a nondefault container yet helper has no proof, investigate the app
`runtime_report` connection/authorization. Do not blame Choicy on a device
where it is not installed.

Device report (roothide iOS 15.8.8): Preferences showed the active Chrome
container as `007FADC7-01AC-4740-AD98-0099E98A32FC`, and the Filza URL was
successfully opened by LaunchServices. A later SpringBoard alert said Chrome
started into `DEFAULT` because Crane's app dylib was not loaded. The Filza
success only demonstrates access to a container directory; it does **not**
prove that Chrome received the redirected launch environment or loaded Crane.
The alert is emitted when helperd can reply to `lookup_pid` but has no active
`Crane` runtime attestation for the launched PID. That can mean (1) the
runningboardd hook/profile never supplied `CRANE_CONTAINER_IDENTIFIER`, (2)
tweak injection was disabled or failed, or (3) the independent app-side
runtime report was rejected/delayed. Do not treat the alert as proof of the
precise cause without runtime logs.

The reconstructed CraneSB 0x194EC/0x19608 path now retries *only* the
reachable-helper/no-proof branch two times, 750 ms apart. The old PID must
still be alive and unchanged before each result is accepted; a transport error
never masquerades as proof. Helper and runningboardd log missing/accepted
attestations and launch-environment decisions. This is a bounded reliability
adaptation, not an implementation of the original app-side injection transport
and not a reason to disable the missing-dylib alert.

Collect a **new** mobile-accessible log beginning before the next Chrome
launch (filter for all of the following; availability varies by logging tool):

```sh
oslog | grep -E 'CraneSB: runningboardd|CraneSB: post-launch|Crane: app init|Crane: app environment ready|Crane helper: (runtime_report|lookup_pid)|CraneManager: helper lookup_pid|Crane Error'
```

Interpret in order:

- `runningboardd hook selectors execute=0 private=0`: no supported selector
  hooked; a new iOS-specific selector must be established from device
  evidence before modifying launch arguments.
- `CraneRB profile cannot load` or `sandbox profile unavailable`: the
  runningboardd launch gate is blocked, independently of the Filza success.
- `runningboardd launch environment ... containerIDSet=1`: Crane attempted to
  insert the container ID into the process launch request, but this alone
  does not prove the tweak injector loaded ` Crane.dylib`.
- `Crane: app init bundle=com.google.chrome.ios` and `app environment ready`:
  app-side constructor consumed a non-default ID. If absent, check the
  installed ` Crane.dylib` (leading space), its recovered Foundation bundle
  filter and injection controls such as Choicy/TweakRestrict on this app.
- `Crane helper: runtime_report accepted ... component=Crane ... containerProof=1`:
  helper registered the app-side proof for that kernel PID. `rejected` or a
  missing report requires examining sandbox/Mach-service access and peer logs.
- `Crane helper: lookup_pid ... hasProof=0` followed by
  `CraneSB: post-launch proof missing ... attempt=3`: all bounded checks
  failed; the original alert still appears. A proof on attempt 2/3 indicates
  an XPC report race rather than a persistent injection failure.

No application data should be deleted or moved during this investigation.
Avoid guessing that the helper XPC fix automatically repairs the separate
app-side injection path. The CI source-contract test is
`check_postlaunch_injection_contract.py`; actual iOS/roothide launch and helper
logs are required.

## Communication alert diagnostics

An empty suffix after COMMUNICATION_ERROR_MESSAGE was possible because the
adapter discarded transport errors. Matching builds now report the request
operation, service name and error category, including protocol mismatch and
two-second insurance/lookup deadlines. A valid reply with missing injection
proof stays an injection failure; an error never grants container redirection.

Run these read-only checks from the device bootstrap shell (root if required):

```sh
launchctl print system/com.opa334.cranehelperd
ps -A | grep '[c]ranehelperd'
oslog | grep -E 'Crane|cranehelperd'
```

Preserve launchd's program path, state and last exit code, and helper startup,
listener, peer identity and client request errors. Install the matching helper
and libcrane together; the reconstruction protocol cannot speak to an original
Crane daemon.

### Roothide 15.8.8 — mobile-only shell (no root login available)

For this installation the user has **only a `mobile` shell**. Do not ask them
for `su`, a root password, `sudo`, or `launchctl bootstrap system ...` from
`mobile`: registering the system Mach service requires a privileged context.
Use the read-only `reconstruction/tools/diagnose_cranehelperd.sh`, or run:

```sh
id -u
jbroot /Library/LaunchDaemons/com.opa334.cranehelperd.plist
jbroot /usr/local/libexec/cranehelperd
ls -l /Library/LaunchDaemons/com.opa334.cranehelperd.plist /usr/local/libexec/cranehelperd
ps -A | grep '[c]ranehelperd'
launchctl print system/com.opa334.cranehelperd
```

Roothide bootstrap tools may interpret `/Library` and `/usr` relative to their
private jailbreak root. `jbroot` converts these paths for native system APIs;
paths may be inaccessible to `mobile` even if installed. Capture the output of
these checks and of the **package manager** entry for
`com.opa334.cranereconstruction`, including whether the helper binary and
LaunchDaemon plist were actually installed. A `launchctl print system/...`
failure from `mobile` is **inconclusive**, not proof the job is missing. A missing
PID also does not distinguish failed daemon launch from missing registration.

For a user without privileged terminal access, **repair belongs in a trusted
package-installation/bootstrap lifecycle**, not in an XPC client and not in a
mobile-shell workaround. The user has authorized a package configure hook:
`layout/DEBIAN/postinst` now registers only the Crane job when absent and
restarts the installed helper build. Install a newly rebuilt package through
the privileged package manager; this does not require a root terminal login.
Merely rerunning `cranehelperd_start` or reinstalling an older package without
this hook does not register a missing job. Verify the daemon and XPC response
on device after installation.

### Roothide 15.8.8 — missing system-domain job / error 1003

An observed repeating `runtime_report` Code=1003 (`Connection invalid`) with
no helper PID means clients cannot reach the Mach listener. The **launchd job
label** is `com.opa334.cranehelperd`, but the **XPC Mach service** is
`com.opa334.cranehelperd.xpc`; do not use the Mach service as the job label in
`launchctl print`. A `launchctl print` run as `mobile` can be insufficient for
a system-domain diagnosis; repeat from a `root` shell. The fact that CranePrefs
loads successfully does not mean the separate helper daemon is running.

Copy/run the **read-only** `reconstruction/tools/diagnose_cranehelperd.sh` on
the device from a root shell (`sh diagnose_cranehelperd.sh`), or run these
checks manually (the `jbroot` command is provided by the Roothide bootstrap):

```sh
id -u
P="$(jbroot /Library/LaunchDaemons/com.opa334.cranehelperd.plist)"
E="$(jbroot /usr/local/libexec/cranehelperd)"
ls -l "$P" "$E"
plutil -p "$P"
launchctl print system/com.opa334.cranehelperd
ps -A | grep '[c]ranehelperd'
```

If **both files exist** with an executable helper and the **root**
`launchctl print` confirms no job exists, the package has installed files but
has not registered the daemon. In a controlled recovery, a root operator may
explicitly register **only Crane's job** and then verify it:

```sh
launchctl bootstrap system "$P"
launchctl kickstart -k system/com.opa334.cranehelperd
launchctl print system/com.opa334.cranehelperd
ps -A | grep '[c]ranehelperd'
```

The **read-only diagnostic** does not execute recovery commands. The approved
package configure hook uses bootstrap only when the job query fails, then
kickstarts the exact Crane job to replace the old helper on upgrades. Manual
root recovery is optional for environments with privileged terminal access;
it is not the procedure for this mobile-only installation. If the plist/binary is
missing, reinstall a **matching** Crane helper/client package rather than
registering a dangling job. Never start the daemon as an ad-hoc user process;
launchd owns and authenticates the recovered Mach names. The current
`cranehelperd_start` only performs `kickstart -k`, which fails if the job was
never bootstrapped. Registration now belongs to the user-authorized package
configure hook. No user container files need to be removed for diagnosis.


## Signing and packaging adapter

Rootful helper entitlement dictionaries are recovered from the original
LC_CODE_SIGNATURE / SuperBlob XML entitlement slot 5. Roothide adds the
executable permissions specified in its
[official developer guide](https://github.com/roothide/Developer).
The starter follows its [bootstrap executable path API](https://github.com/roothide/Developer/blob/master/interface.md).
Client connections explicitly select the privileged bootstrap for the existing
LaunchDaemons service, following [Apple's Mach-service API](https://developer.apple.com/documentation/xpc/xpc_connection_create_mach_service(_:_:_:)).
This flag selects the service namespace; it does not grant caller privileges.

The user explicitly approved the install adapter. During `configure`, postinst
requires the privileged installer, checks the installed plist/executable,
queries the exact Crane job, bootstraps it only if needed and kickstarts that
job to match the updated client library. Registration failures are accepted
only if a subsequent query confirms concurrent registration; other errors
fail package configuration visibly. It never touches user container data.

This is reconstruction packaging work: the original maintainer scripts were
not provided. Theos stages postinst with mode 0755, and CI verifies its exact
contents and permissions in control.tar.*, separate from installed data.
Eight actual-script control-flow cases pass against a mock launchctl on the
Windows host; no native Theos package or real device registration was executed.
Device verification is still required after installing the rebuilt package.

## Current evidence

Static contract: `python reconstruction/tools/check_xpc_ping_contract.py`.
Native CI/package build and runtime outcomes must be reported independently.
The original NSXPC protocol, privileged RPC authorization, and F-08 are still partial.
