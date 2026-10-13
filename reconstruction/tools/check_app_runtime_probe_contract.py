"""App-side runtime report transport probe and helper PID-proof contracts.

Chrome logged app init and app environment ready for a nondefault container,
while SpringBoard's lookup of the SAME PID returned no proof. A one-way
runtime_report cannot reveal whether sandbox Mach lookup failed. Queue an
already-existing authenticated read-only ping on the SAME long-lived XPC
peer after the initial report. The async reply diagnoses connection health
without inventing injection proof. Source tests only, not device testing.
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
    'if ([name isEqualToString:@"Crane"] && value != NSNull.null)',
    'Crane: app runtime_report queued pid=%d',
    'xpc_dictionary_set_string(probe, "operation", "ping");',
    'xpc_dictionary_set_string(probe, "protocol",',
    'xpc_connection_send_message_with_reply(created, probe,',
    'CRHelperXPCEventError(response, @"app_runtime_probe")',
    'Crane: app runtime_report transport probe error pid=%d',
    'Crane: app runtime_report transport probe pid=%d alive=%d compatible=%d',
    'strcmp(protocol, CR_HELPERD_PING_PROTOCOL_V1) == 0;',
):
    assert token in report, token

assert report.index('xpc_connection_resume(created);') < report.index('xpc_connection_send_message(created, replay);')
assert report.index('xpc_connection_send_message(created, replay);') < report.index('xpc_connection_send_message_with_reply(created, probe,')
assert report.index('if ([name isEqualToString:@"Crane"]') < report.index('xpc_connection_send_message_with_reply(created, probe,')
assert '"operation", "runtime_report"' in report
assert '"operation", "lookup_pid"' not in report
assert 'reply(YES' not in report
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
assert init.index('unsetenv(CR_ENV_CONTAINER_IDENTIFIER.UTF8String);') < init.index('CRPrepareAppRuntimeMachLookup();')
assert init.index('CRPrepareAppRuntimeMachLookup();') < init.index('CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);')
assert init.index('CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);') < init.index('CRCreateDirectoryIfNotExists(container);')
assert init.index('CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);') < init.index('setenv(CR_ENV_HOME.UTF8String, container.UTF8String, 1);')
assert 'It does not claim that the remaining 0x65D0 environment setup is done.' in init
assert 'removeItemAtPath:' not in init

def probe_outcome(reply_kind, alive, version_ok):
    if reply_kind == "error":
        return "transport-error"
    if reply_kind != "dictionary" or not alive or not version_ok:
        return "invalid-reply"
    return "connection-reachable"

assert probe_outcome("error", False, False) == "transport-error"
assert probe_outcome("dictionary", True, True) == "connection-reachable"
assert probe_outcome("dictionary", False, True) == "invalid-reply"
assert probe_outcome("dictionary", True, False) == "invalid-reply"
assert probe_outcome("none", False, False) == "invalid-reply"
assert "check_app_runtime_probe_contract.py" in workflow

print("Crane app-to-helper runtime probe and data-preservation contracts: PASS (device unverified)")
