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

> **Historical diagnostic record.** The same-peer app `ping` described below was temporary instrumentation and has been removed from production after runtime-report transport was device-proven. Keep these observations for provenance; do not expect the current build to emit `app_runtime_probe` logs.

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

> **Historical F-07 investigation.** The 0/7/probe/userspace-reboot steps below document how the injection blocker was isolated. They are superseded by the 2026-10-14 10:20 `success=1` / `works=1` closure later in this file; current production builds do not ship the probe tweaks or run the per-launch seven-daemon health matrix.

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

The roothide diagnostic package now also includes two temporary constructor-only
probe tweaks with the same seven `Executables`: `CraneSupportProbeFlags` keeps
the recovered `Flags=1`, while `CraneSupportProbePlain` omits `Flags`. Both use
Theos `tweak.mk` and link only Substrate so they traverse the same tweak-loader
pipeline as CraneSupport, while their source bodies still avoid Foundation,
libcrane, libbsm and Crane logic. This replaces the first `library.mk` probe
revision, whose absence was not sufficient to prove a Dopamine2-roothide
injection failure. **After installing this diagnostic build, perform a userspace
reboot from the jailbreak/bootstrap UI before testing. A normal Respring is not
enough**, because this reconstruction's package `postinst` only kickstarts
`cranehelperd`, and the unrecovered privileged `reloadDaemons:` backend is not
implemented.

Capture:

```sh
oslog | grep -E 'CraneSupportProbe:|CraneSupport: (constructor process=|init process=|XPC unsandbox profile.*process=)|Crane helper: insurance|CraneManager: helper insurance|CraneSB: support health process='
```

Interpret only after verifying that the three dylibs plus their filter
plists exist in the *installed* package and that the log stream captures
daemon-side events during a fresh process start. Neither probe constructor in
a log-only sample is **not proof of failed injection**, because the constructor
may have run before logging began or daemon messages may be missing from the
stream. After these prerequisites, no probe constructor points toward the
Dopamine2-roothide daemon injection/filter path; `plain` but not `flags1`
points toward `Flags=1` semantics; both probes but no CraneSupport constructor
points toward CraneSupport's Mach-O/dependencies and CI `linkage.txt`;
CraneSupport constructor with health=0 points toward libSandy/profile/runtime
report authentication.

The latest device sample at 19:02:02 on Dopamine 2 + roothide has two identical
SpringBoard insurance lines: `works=0 connection=1 broken=cfprefsd,
containermanagerd, securityd, pkd, lsd, accountsd, apsd error=(null)`. It has
neither `CraneSupportProbe:` constructor nor the expected `Crane helper:
insurance` line, even though the helper *must* log the latter when it prepares
this insurance response. Thus the sample proves the seven missing runtime
proofs but does **not** establish complete daemon log coverage. Check the
installed payload read-only as the `mobile` user before drawing a loader
conclusion:

```sh
for n in CraneSupport CraneSupportProbeFlags CraneSupportProbePlain; do
  for suffix in dylib plist; do
    p=$(jbroot "/Library/MobileSubstrate/DynamicLibraries/$n.$suffix")
    ls -l "$p"
  done
done
```

If `jbroot` is unavailable, inspect
`dpkg -L com.opa334.cranereconstruction` and the corresponding accessible
jailbreak root paths instead. The listing proves installation presence, not execution.

**2026-10-13 device result:** the mobile shell's `jbroot` + `ls -l` verified
all six files under the actual Dopamine 2 roothide root
`/var/containers/Bundle/Application/.jbroot-DFEDD416F550194C/Library/MobileSubstrate/DynamicLibraries/`:

- `CraneSupport.dylib` 344176 bytes, `CraneSupport.plist` 159 bytes
- `CraneSupportProbeFlags.dylib` 165856 bytes, `CraneSupportProbeFlags.plist` 159 bytes
- `CraneSupportProbePlain.dylib` 165856 bytes, `CraneSupportProbePlain.plist` 147 bytes

Each has timestamp **Oct 13 17:55**, permissions `0755` for dylibs and
`0644` for plists, owner `root:wheel`. The **16:36** insurance sample predates
that installation and cannot test the latest probe build; the **19:02**
SpringBoard insurance failure postdates installation but lacks **both** probe
constructor messages **and** the helper's expected `Crane helper: insurance`
message. Do not treat a missing message in that stream as proof of no daemon
injection. The files are installed but neither filter parsing nor actual
dylib mapping and daemon restart has yet been demonstrated.

Next read-only mobile checks:

```sh
for n in CraneSupport CraneSupportProbeFlags CraneSupportProbePlain; do
  p="$(jbroot "/Library/MobileSubstrate/DynamicLibraries/$n.plist")"
  echo "=== $n filter ==="
  plutil -p "$p"
done
ps -A -o pid,lstart,comm | grep -E 'cfprefsd|containermanagerd|securityd|pkd|lsd|accountsd|apsd'
```

**2026-10-13 device process evidence:** the `mobile` shell supports the
`ps -A -o pid,lstart,comm` command. The resulting actual system daemon start
times were `cfprefsd` PID 455 at **14:34:43**, `accountsd` PID 456 at
**14:34:44**, `lsd` PID 458 at **14:34:45**, `securityd` PID 469 at
**14:34:50**, `apsd` PID 481 at **14:34:55**, and `pkd` PID 483 at
**14:34:55** (all Oct 13), fully **before** the **17:55** diagnostic-package
install. An unrelated `amsaccountsd` PID 451 appeared too; do not confuse it
with the exact `accountsd` executable filter target. `containermanagerd` was
not shown in this particular `ps` output. These six verified daemon processes
**were not restarted after the diagnostic tweak probes were installed**.
Consequently the lack of constructor logs at **19:02** cannot diagnose the
Dopamine2-roothide injection subsystem. Perform a userspace reboot **after**
the installed 17:55 diagnostic build, via the jailbreak UI (choose **Reboot
Userspace**, not **Restart SpringBoard**), then check new process start times
and insurance/log outcome. Do not use `killall`, privileged shell launchctl,
or any manual daemon termination from mobile.

`plutil -p` was attempted from the device `mobile` shell and returned
`zsh: command not found: plutil` for all three filter checks. That is a
missing shell utility, **not** a Crane filter parsing result. Do not require
users to install `plutil` merely for this test.

**2026-10-13 20:36 device evidence, after userspace reboot:** the six visible
target daemons restarted around **19:45**, after the 17:55 installation:
`cfprefsd` PID 485 at 19:45:41, `accountsd` PID 489 at 19:45:45, `lsd`
PID 490 at 19:45:45, `securityd` PID 500 at 19:45:49, `pkd` PID 508 at
19:45:53 and `apsd` PID 514 at 19:45:55. `amsaccountsd` PID 482 is a
different process; `containermanagerd` remains absent in the mobile-shell
process listing, despite appearing in helper insurance broken names.
SpringBoard PID 1066 logged twice at **20:36:17**:

```text
CraneManager: helper insurance works=0 connection=1 broken=cfprefsd, containermanagerd, securityd, pkd, lsd, accountsd, apsd error=(null)
```

Therefore the old-process hypothesis is **ruled out for the six observed
daemons**. Installation presence and fresh process starts are confirmed; yet
the helper received no valid CraneSupport runtime proofs. The absence of
`CraneSupportProbe:` and `CraneSupport:` constructor messages in a live
`oslog` stream **after** userspace reboot is not enough to prove no code
injection: constructors run during daemon startup at ~19:45, and the same
stream also omits the helper's on-demand `Crane helper: insurance` log at
20:36. In reconstruction `CRSupport.m`, constructor diagnostics precede
libSandy and registration, while `CRHelperd.m` distinguishes only live
accepted registration, not actual mapped-image presence. The unresolved
branches are (1) daemon filter/loader injection did not occur, or (2)
injected CraneSupport could not send an authenticated runtime report through
its libSandy/Mach path (or the helper rejected it). **Do not weaken the
insurance gate** or attempt to patch securityd/private symbols until one
branch has independent evidence. As a noninvasive platform check, confirm
that Dopamine 2 Settings has `Disable Tweak Injection` turned **off**, and
that no relevant daemon is selectively excluded by the installed tweak
injection controls. The SpringBoard CraneManager log proves some injection
is working but not that the daemon-injection path is enabled. Repeating an
identical reboot and live grep alone will not distinguish these branches.

**Oct 13, 21:55:23 — no change:** SpringBoard PID 1862 again returned
`works=0 connection=1` with all seven names in `broken`, no transport
error. This is a missing authenticated CraneSupport report, **not** a
definitive dylib mapping test. Dopamine 2's `Disable Tweak Injection` is
confirmed **OFF** by the user; do not keep suggesting that same toggle.

### New roothide-only live injection probe (requires a newly built package)

The constructor-only probes originally printed once during daemon startup,
which usually happened **before** mobile launched `oslog`. A safer
on-demand *positive* proof now uses Darwin notifications, with no helper
XPC, filesystem writes, private memory inspection or added hooks:

1. After injection, each minimal probe registers a callback for
   `com.opa334.cranereconstruction.supportprobe.ping`.
2. When the user attempts a non-default container launch, SpringBoard
   posts that diagnostic ping, logging
   `CraneSB: support probe ping status=<code>`.
3. A live injected probe responds on
   `com.opa334.cranereconstruction.supportprobe.reply.<variant>.<process>`.
   SpringBoard registers 14 observers (2 variants × 7 daemons) on
   initialization and logs
   `CraneSB: support probe reply variant=plain process=securityd` or
   `variant=flags1`, etc. **Positive replies prove the corresponding
   probe's constructor ran and its callback is still alive.**

To use this diagnostic, **first build/install the updated roothide package**,
then reboot userspace once after installation so target daemons load the new
probe revision. Begin an `oslog` session and trigger a non-default
container launch; inspect:

```sh
oslog | grep -E 'CraneSB: support probe (ping|reply|listener)|CraneManager: helper insurance'
```

**2026-10-13 22:12:29 new-device observation:** SpringBoard PID 2119 emitted
two `CraneSB: support probe ping status=0` lines and two helper-insurance
lines (`works=0 connection=1 broken=` all seven targets, `error=(null)`).
There were **no** `CraneSB: support probe reply` messages in this sample.
The new SpringBoard PID, compared with 21:55 PID 1862, proves SpringBoard
restarted, **not** that target daemons restarted after the latest *live
notification* probe package was installed. Check installed dylib timestamps
and current daemon births read-only **before** interpreting this negative:

```sh
for n in CraneSB CraneSupportProbeFlags CraneSupportProbePlain; do
  ls -l "$(jbroot "/Library/MobileSubstrate/DynamicLibraries/$n.dylib")"
done
ps -A -o pid,lstart,comm | grep -E 'cfprefsd|containermanagerd|securityd|pkd|lsd|accountsd|apsd'
```

**2026-10-13 22:12 read-only device check (definitive stale-process
sample):** the device shows `CraneSupportProbeFlags.dylib` and
`CraneSupportProbePlain.dylib` installed at **22:09** (each 166208 bytes)
and `CraneSB.dylib` installed at **22:11** (509520 bytes), all under
the current root `.jbroot-F98DDB12689CCD84`. The actual six observed
system daemons started at **20:30:57–20:31:30**, all *before* either
live diagnostic probe was installed. SpringBoard subsequently started
with the new `CraneSB` and posted ping at **22:12**, but those daemons
were never recreated to execute the new probe constructor. That is a
sufficient explanation for **no live-probe replies in this sample**;
it does **not** explain all earlier `CraneSupport` 0/7 failures.
User confirms **original Crane and other tweaks work** on Dopamine 2
roothide, so do not attribute the reconstruction problem to a global
injector outage. The reconstruction `postinst` only kickstarts
`cranehelperd`; it deliberately does not restart protected system
daemons. The installer now explicitly prints a reminder to **Reboot
Userspace** after install rather than silently leaving a mixed-version
runtime; it never reboots or terminates anything automatically.

If target daemon births precede the new probe dylib timestamps, the live
probe constructor was not exercised in those existing processes; a
**post-install userspace reboot** (not merely Respring) is necessary for
a valid test. Conversely, if daemons are fresh, `ping status=0` alone
does **not** prove their notification receivers registered or received
anything; a missing reply remains ambiguous between missing injection
and sandboxed/undelivered Darwin notifications. The diagnostic
SpringBoard listeners log only on registration **failure**, so absence
of a `listener failed` line is not an explicit registration-success log.
Never bypass helper insurance due to a diagnostic ping or lack of reply.

**2026-10-14 00:43–00:49 — fresh-daemon negative:** after the
22:09 probe installation, the device's target processes were recreated:
`cfprefsd` PID 385 at 00:43:35, `accountsd` PID 386 at 00:43:36,
`lsd` PID 392 at 00:43:40, `securityd` PID 413 at 00:43:53,
`apsd` PID 423 at 00:44:03, and `pkd` PID 445 at 00:44:21.
At 00:49:41–00:49:42 SpringBoard PID 612 posted the support-probe ping
twice with status 0, received **no plain/flags1 replies**, and helper
insurance still returned all seven broken targets. This **rules out stale
pre-install daemon lifetime** for the current probe build. It still does
not distinguish an unmapped tweak image from Darwin-notification
registration/delivery being restricted inside those system daemons.
The user reports original Crane and other tweaks work normally on the
same Dopamine 2 roothide environment, so a platform-wide injection outage
is not a supported conclusion.

### Read-only helper mapped-image diagnostic

To eliminate the Darwin-notify ambiguity, the reconstruction helper now has
a diagnostic-only VM-region inspector. On an authenticated failed insurance
request it enumerates the already-running CraneSupport target PIDs with
`proc_listpids/proc_name`, walks each PID's **read-only** region metadata
using `proc_pidinfo(PROC_PIDREGIONINFO)`, and obtains file-backed region
names with `proc_regionfilename`. It looks only for these exact leaf names:

- `CraneSupport.dylib`
- `CraneSupportProbeFlags.dylib`
- `CraneSupportProbePlain.dylib`

The helper returns the summary as `support_image_map`, and libcrane logs
it from the requesting SpringBoard process:

```text
CraneManager: helper support image map cfprefsd[pid=... inspect=1 support=... flags=... plain=...]; ...
```

This diagnostic is **not part of the `works` expression** and cannot
grant a non-default container. `inspect=1 support=0 flags=0 plain=0`
is strong evidence those image files are not mapped in that PID.
`support=1` with missing runtime health instead points to the
CraneSupport libSandy/raw-XPC registration path. `inspect=0` remains
inconclusive because the kernel can deny cross-process region-path
inspection even to the helper.

**2026-10-14 01:18 definitive mapped-image result:** helper returned
`inspect=1 support=0 flags=0 plain=0` for **all seven targets**, including
`containermanagerd` PID 363 plus the six previously verified fresh PIDs.
Therefore `CraneSupport.dylib` and both minimal probe tweaks are genuinely
**not mapped** in these daemon processes. The failure is before every
constructor, hook, libSandy profile call and runtime-report XPC operation.
Do not debug securityd private symbols or helper authentication until this
loader/filter issue is resolved. CraneSB from the same reconstruction package
*is* mapped in SpringBoard, and the user reports original Crane/other tweaks
working under the same Dopamine2-roothide environment, so this is not evidence
that all tweak injection is globally disabled.

**2026-10-14 02:10 loader-stack result:** the extended mapper showed
`cfprefsd`, `securityd` and `lsd` with `ellekit=1`; `securityd`
also had an actual third-party/system tweak image `SandyProxy.dylib`
(`other=1 sample=SandyProxy.dylib`). At the same time all visible Crane
fields remained zero. This proves tweak injection is active in at least
`securityd` on the same boot while Crane's three daemon dylibs are absent.
The sample also showed `containermanagerd` and `pkd` with RootHide
runtime images but no visible ElleKit/tweak image; the accountsd/apsd tail
was truncated in the pasted mobile log, so do not invent values for them.

The device path check also proves packaging visibility is not the missing
link: `/Library/MobileSubstrate/DynamicLibraries` is a symlink to
`/usr/lib/TweakInject/`, and each of `CraneSupport.dylib`,
`CraneSupportProbeFlags.dylib` and `CraneSupportProbePlain.dylib`
resolves to the same installed file through **both** paths. Therefore stop
investigating a missing TweakInject symlink/directory.

The remaining high-value split is **filter/load eligibility vs Mach-O
dependency failure**. Both existing probes are still built through
`tweak.mk` and carry the tweak backend dependency, so a common roothide
load-command failure can make `support=flags=plain=0` even when filters
match. A new roothide-only `CraneSupportProbeBare.dylib` is therefore
built through `library.mk`, has the same seven-process Executables filter,
and deliberately has no Foundation/notify/tweak-backend/libcrane/libSandy
dependency. CI inspects its `otool -L` output and rejects it if a jailbreak
hooking dependency sneaks in. CI also rejects roothide Crane dependencies
whose jailbreak-library install name is not under
`@loader_path/.jbroot/...`, matching RootHide's documented load-path rule.
The helper mapper reports this fourth discriminator as `bare=0/1`.

**2026-10-14 03:26 — Bare result is generation-invalid, not a negative.**
SpringBoard PID 1560 and the helper were clearly updated because the image-map
format contains the new `bare=` field. However, every target PID shown in the
same log is unchanged from the **00:43–00:44** boot generation:
`cfprefsd=385`, `containermanagerd=363`, `securityd=413`, `pkd=445`,
`lsd=392` (and the untruncated earlier sample established the corresponding
accountsd/apsd generation). Those processes existed **before
CraneSupportProbeBare was introduced/built**, so `bare=0` in this sample only
means "this old process does not map a library that did not exist when it
started." Do **not** classify this as filter/signing failure. The older,
already-valid facts remain useful: ElleKit is active in cfprefsd/securityd/lsd,
SandyProxy is mapped in securityd, and Support/Flags/Plain remain absent.

The `03:26` Bare sample is generation-invalid, but **do not turn
that diagnostic limitation into a product requirement for Userspace Reboot**.
Direct original-binary analysis now explains why original Crane does not need
one: recovered CraneSB `didFinishLaunching` at `0x1782C` calls the helper's
`runInjectionFixUpIfNeededAndReply:`, and original `cranehelperd` contains
the complete verify/fix-up surface including
`_fixupInjectionIfNeededForDaemon:error:`,
`_injectDylib:intoProcessWithPid:error:` and
`_injectDylib:intoProcessWithName:error:`. It imports `task_for_pid`, has
`task_for_pid-allow`, and contains injection backend paths for
`libsyringe`/`cynject`. Therefore original Crane can repair
`CraneSupport` in already-running daemons after SpringBoard starts.

Reconstruction now implements the recovered normal live fix-up path through a fixed-purpose authenticated helper request. It never accepts a caller-selected PID or dylib path; it reads the installed CraneSupport filter, skips non-running/already-loaded targets, invokes a bounded injector backend, and verifies the fixed CraneSupport image is mapped. Do not require Userspace Reboot as a normal installation or upgrade step. Bare remains diagnostic only.

The insurance reply also carries reconstruction-only **last fix-up state** so a live `oslog` session started after SpringBoard boot can still diagnose the startup attempt. Look for `CraneManager: helper injection fixup state attempted=... inProgress=... success=... process=... backend=... transitions=... errorCode=... error=... backends=...`. `attempted=0` means the current helper has not received a fix-up request since it started. While `inProgress=1`, `success=0 error=(null)` is only the initialized state of an active pass and must **not** be read as failure. Once `inProgress=0`, `success=0` identifies a completed failed pass and should carry the final error; `success=1` means the injector pass completed, while insurance still independently decides whether runtime proof is healthy. `transitions=` records daemons whose PID disappeared/changed after a successful injector exit and is diagnostic only. The `backends=` field reports fixed candidate availability as `name=exists/executable` and is diagnostic only; neither field affects insurance success.

**2026-10-14 06:29 — startup race proved:** device reported `attempted=0`, while both RootHide injector candidates existed and were executable (`/basebin/opainject=1/1`, `/usr/bin/opainject=1/1`). Source inspection found the exact cause: `CRDidFinishLaunching` called `cranehelperdConnectionWorks` on SpringBoard's main thread before and immediately after `CRStartHelperIfNeeded`. Main-thread connection checks are intentionally cache-only and schedule a background probe; the first call returned false and marked the probe in-flight, then the immediate second call also returned false while that probe was still pending, so the recovered fix-up selector was never sent. `CRDidFinishLaunching` now starts the helper when needed and unconditionally schedules a worker-thread readiness loop. On the worker, `cranehelperdConnectionWorks` performs the real bounded synchronous health request; it retries up to 8 times with 250 ms spacing and sends `runInjectionFixUpIfNeededAndReply:` as soon as the helper is reachable. This changes only helper-readiness sequencing; insurance remains fail-closed and no Userspace Reboot is required.

**2026-10-14 07:07 — live injection succeeds, then a target transitions:** device reported `attempted=1` with RootHide `opainject`; `cfprefsd` changed from `support=0` to `support=1` and disappeared from the broken-daemon list. This proves the full CraneSupport path in that daemon: injector load, constructor execution, libSandy preparation, and accepted runtime-report proof. The pass then stopped at `containermanagerd` with reconstruction-only error 1107 because PID 363 disappeared after the injector exited. Direct disassembly of original cranehelperd shows `_injectDylib:intoProcessWithPid:error:` treats injector exit status 0 as success and does not add a post-injection PID-stability error; the outer fix-up stops on `NSError`, not on the helper method's BOOL alone. Reconstruction now matches that behavior: target disappearance/change after injector exit 0 is recorded in `transitions=` and verification is deferred instead of aborting the seven-daemon pass. PID lookup is also performed fresh immediately before each daemon, matching original `_fixupInjectionIfNeededForDaemon:error:` rather than using one stale PID snapshot for all seven. The original `_crucialCraneSupportDaemons` list was also recovered exactly as `cfprefsd`, `containermanagerd`, `securityd`; reconstruction therefore fails insurance when any of those crucial daemons is absent rather than silently treating absence as healthy. The original helper can additionally ping an on-demand Mach service before verification; that activation parity remains a later step if `containermanagerd` does not naturally return.

**2026-10-14 08:23 — snapshot was taken mid-fix-up, not after failure:** insurance showed `process=pkd`, `transitions=securityd[413->gone]`, `success=0 error=(null)`, while the same image map already had `cfprefsd support=1`, a restarted `containermanagerd pid=3582 support=1` with all three probes loaded, and `pkd support=1`. Nine seconds later a new `lsd[4294]` logged `CraneSupport: init process=lsd xpcUnsandbox=1`. Therefore the 08:23:44 insurance sample occurred while the sequential fix-up was still advancing; `success=0/error=null` was just the initialized active state. The mapper/runtime proof also shows separate timing: `pkd` could already map CraneSupport while still appearing in the broken list until its runtime report was accepted. Reconstruction now exposes explicit `inProgress=1/0` to distinguish this state. In addition, the reconstructed post-inject 2-second map poll has been removed from the fix-up path: original `_injectDylib:intoProcessWithPid:error:` treats injector exit 0 as success and leaves health verification to later insurance. Reconstruction keeps one immediate map sample for logging only, reducing the window in which an app launch can race an unnecessarily long fix-up pass.

**2026-10-14 08:55 — insurance is fully healthy despite an injector timeout:** helper reported `attempted=1 inProgress=0 success=0 process=pkd backend=opainject errorCode=1104`, but in the same sample insurance returned `works=1`, `connection=1`, and an empty broken list. This is decisive: all required live CraneSupport runtime proofs were present, so the `opainject timed out` status is a false-negative of the reconstruction fix-up wrapper, not a functional Crane failure. The likely sequence is that `opainject` completed the actual remote load/runtime registration but remained alive long enough to hit the reconstruction's 8-second child timeout. Timeout handling now salvages this exact case after terminating only the injector child: it first confirms the PID still resolves to the same daemon, then checks both mapped `CraneSupport.dylib` and exact-PID runtime proof; if either exists, the timeout is logged as recovered and fix-up continues/succeeds. If the PID disappeared or now belongs to another process, the timeout is recorded as a deferred transition before any recovery check. Error 1104 remains fatal only when the original PID still exists with neither image nor runtime proof. Insurance remains authoritative and unchanged.

**2026-10-14 10:20 — fix-up and insurance both pass; injection blocker closed:** the rebuilt device logged `helper injection fixup authorized=1 success=1 error=(null)`, followed by the completed snapshot `attempted=1 inProgress=0 success=1 process=pkd backend=opainject transitions=(null) errorCode=0 error=(null)`. The same run returned `helper insurance works=1 connection=1 broken= error=(null)` twice. This is the expected final state: the recovered startup fix-up is executing, the reconstruction wrapper no longer leaves a false 1104 failure, and the independent insurance gate sees every required CraneSupport proof. Further work should move to app/container feature behavior rather than daemon-injection debugging unless `works` regresses or `broken` becomes non-empty.

**Post-debug production cleanup:** the temporary `CraneSupportProbeFlags`, `CraneSupportProbePlain`, and `CraneSupportProbeBare` sources are retained only as an archived manual diagnostic harness; normal Roothide packages no longer build or stage them. SpringBoard no longer registers/sends probe notifications, the helper no longer reports `flags/plain/bare`, the seven-daemon health matrix is no longer queried after every successful app launch, and the app runtime-report path no longer sends an extra diagnostic ping. Rootful injector discovery has also been restored to the recovered `libsyringe/cynject/cynject.old` set; `opainject` is restricted to Roothide builds.

The mapper has now been extended to report the surrounding injection stack
without changing insurance: exact `systemhook.dylib`, TweakLoader/TweakInject,
ElleKit's `libinjector.dylib`/`libellekit.dylib`, Substrate compatibility,
a bounded sample/count of other mapped tweak dylibs, and a bounded sample/count
of file-backed images originating from the randomized jailbreak tree. RootHide
can randomize the systemhook filename, so `jb=<count> jbSample=...` is the
fallback signal when the exact `systemhook` leaf is unavailable. The next
summary format is:

```text
process[pid=N inspect=1 systemhook=... loader=... injector=... ellekit=...
 substrate=... jb=N jbSample=... other=N sample=...
 support=0 flags=0 plain=0]
```

Interpretation: `injector=1` or meaningful `other>0` while all three Crane
fields remain zero strongly localizes the problem to the reconstruction's
tweak filter/package/load eligibility. If no loader/injector/other tweak image
is observable but jailbreak images are present, inspect Dopamine's per-process
TweakLoader path. This remains diagnostic-only; none of these fields can make
`works=1`.

After building/installing this revision and rebooting userspace once, capture:

```sh
oslog | grep -E 'CraneManager: helper (support image map|insurance)'
```

**Classification:** a `plain` reply but no `flags1` replies points
toward `Flags=1` filtering; both variants responding from a daemon
with missing CraneSupport health points away from global daemon tweak
injection and toward **CraneSupport load/dependency or runtime-report
failure**. No replies are **inconclusive**, not proof of injector failure:
a sandbox may reject Darwin notify registration/delivery and the observer
also logs any registration failure. Ping status zero only means SpringBoard
posted a notification, not that the probe received it. These probes are
diagnostic-only and **never** grant container access or override insurance.

If this `ps` implementation lacks `lstart` on another device, use
`ps -A -o pid,etime,comm` to compare elapsed runtime, or use the full
`ps -A` output. These commands read current daemon state and do not
restart/kill anything. Do not delete/reset container data.

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
