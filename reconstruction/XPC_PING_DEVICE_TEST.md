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
