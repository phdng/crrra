"""App-side runtime-report transport and helper PID-proof contracts.

The temporary same-peer ping added while diagnosing one-way runtime-report
delivery is no longer needed after on-device helper/runtime proof succeeded.
The production reconstruction keeps the persistent authenticated runtime_report
transport and reconnect/replay semantics, but must not send a second diagnostic
ping for every app registration.
"""

from pathlib import Path

root = Path(__file__).resolve().parents[1]
common = (root / "sources/common/CRCommon.m").read_text(encoding="utf-8")
helper = (root / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
main = (root / "sources/maindylib/CRMainDylib.m").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

start = common.index("void CRReportRuntimeInjection(")
report = common[start:]
for token in (
    'reports[component] = containerID.length ? [containerID copy] : NSNull.null;',
    'CR_HELPERD_MACH_SERVICE.UTF8String, NULL, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED',
    'xpc_connection_set_event_handler(created,',
    'xpc_connection_resume(created);',
    'xpc_connection_send_message(created, replay);',
    '"operation", "runtime_report"',
    'xpc_connection_send_message(connection, report);',
):
    assert token in report, token

assert report.index('xpc_connection_resume(created);') < report.index(
    'xpc_connection_send_message(created, replay);'
)
assert '"operation", "lookup_pid"' not in report
assert 'reply(YES' not in report

# The diagnosis-only acknowledgment must stay removed from production.
for forbidden in (
    'Crane: app runtime_report queued pid=%d',
    'app_runtime_probe',
    'runtime_report transport probe',
    'xpc_connection_send_message_with_reply(created, probe,',
):
    assert forbidden not in report, forbidden

assert 'CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);' in main

assert 'CRRegisterRuntime(peerPid, peerProcess, component, containerID,' in helper
assert 'CRRuntimeContainerForPid(targetPid, targetProcess)' in helper
assert 'CRRuntimeComponentAllowed(component, peerProcess, peerSigningID)' in helper
assert 'xpc_dictionary_set_bool(reply, "injection_verified", containerID.length > 0)' in helper
assert 'xpc_dictionary_set_bool(reply, "alive", compatible);' in helper
assert 'Crane helper: runtime peer disconnected pid=%d' in helper
for reason in ('no_runtime_peer', 'process_name_mismatch', 'no_crane_report', 'empty_container_claim'):
    assert 'reason=' + reason in helper
assert 'CRUnregisterRuntime(peerPid, peerToken);' in helper

# Main init creates missing directories but does not remove existing data.
# Protection=0, spoof=0 means hook count 0 by design.
init = main[main.index("static void CRInitFunc(void)"):]
assert 'if (spoofLookups)' in init
assert 'if (_crActiveContainerIdentifier) {' in init
assert 'CRCreateDirectoryIfNotExists(container);' in init
assert 'setenv(CR_ENV_HOME.UTF8String, container.UTF8String, 1);' in init
assert 'if (count >= 1)' in init
assert 'Crane: app environment ready container=%@ hooks=%u' in init
# Reconstruction runtime proof must be emitted after the borrowed launch-env
# claim is snapshotted/hidden, but before filesystem/HOME work, minimizing the
# first-daemon-request window without changing native 0x65D0 setup ordering.
assert init.count('CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);') == 1
assert init.index('unsetenv(CR_ENV_CONTAINER_IDENTIFIER.UTF8String);') < init.index(
    'CRPrepareAppRuntimeMachLookup();'
)
assert init.index('CRPrepareAppRuntimeMachLookup();') < init.index(
    'CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);'
)
assert init.index('CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);') < init.index(
    'CRCreateDirectoryIfNotExists(container);'
)
assert init.index('CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);') < init.index(
    'setenv(CR_ENV_HOME.UTF8String, container.UTF8String, 1);'
)
assert 'It does not claim that the remaining 0x65D0 environment setup is done.' in init
assert 'removeItemAtPath:' not in init

assert "check_app_runtime_probe_contract.py" in workflow

print("Crane app-to-helper runtime-report contracts: PASS (device transport proven)")
