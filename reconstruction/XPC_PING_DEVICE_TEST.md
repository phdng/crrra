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

## Signing and packaging adapter

Rootful helper entitlement dictionaries are recovered from the original
LC_CODE_SIGNATURE / SuperBlob XML entitlement slot 5. Roothide adds the
executable permissions specified in its
[official developer guide](https://github.com/roothide/Developer).
The starter follows its [bootstrap executable path API](https://github.com/roothide/Developer/blob/master/interface.md).
Client connections explicitly select the privileged bootstrap for the existing
LaunchDaemons service, following [Apple's Mach-service API](https://developer.apple.com/documentation/xpc/xpc_connection_create_mach_service(_:_:_:)).
This flag selects the service namespace; it does not grant caller privileges.

The proposed install adapter is awaiting explicit approval. On package
configuration it would register only the recovered Crane helper job if absent,
then restart that job to match the updated client library. On package removal
it would stop only that job. User containers would remain intact. Such scripts
are reconstruction packaging work because original maintainer scripts were not
provided. Automatic review blocked adding these scripts and their executable
staging step due to the root-service lifecycle effects; none is included.

## Current evidence

Static contract: `python reconstruction/tools/check_xpc_ping_contract.py`.
Native CI/package build and runtime outcomes must be reported independently.
The original NSXPC protocol, privileged RPC authorization, and F-08 are still partial.
