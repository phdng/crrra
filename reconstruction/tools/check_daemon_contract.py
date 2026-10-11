"""Static safety contracts for the partial Crane XPC reconstruction.

Run on the host without Theos. This is not a runtime injection test.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1] / "sources"
manager = (root / "libcrane" / "CRManager.m").read_text(encoding="utf-8")
helper = (root / "cranehelperd" / "CRHelperd.m").read_text(encoding="utf-8")
header = (root / "common" / "CRPreferences.h").read_text(encoding="utf-8")

assert '#define CR_PREFS_DOMAIN @"com.opa334.craneprefs"' in header
for source in (manager, helper):
    assert 'CFPreferencesCopyAppValue(' in source, "global domain read missing"
    assert 'CFPreferencesSetAppValue(' in source, "global domain write missing"
    assert '(__bridge CFStringRef)CR_PREFS_DOMAIN' in source, "explicit global domain missing"

# Isolate the daemon PID inspector to catch the earlier false DEFAULT success.
pid_start = helper.index('- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid', helper.index('@implementation CRHGlobalServiceDelegate'))
pid_end = helper.index('- (void)reloadApplicationWithIdentifier:', pid_start)
pid_body = helper[pid_start:pid_end]
assert 'reply(nil)' in pid_body
assert 'reply(CR_DEFAULT_CONTAINER_IDENTIFIER)' not in pid_body

manager_pid_start = manager.index('- (void)fetchActiveContainerIDForProcessWithPid:(pid_t)pid')
manager_pid_end = manager.index('- (BOOL)cranehelperdConnectionWorks', manager_pid_start)
manager_pid_body = manager[manager_pid_start:manager_pid_end]
assert 'reply(nil)' in manager_pid_body
assert 'reply(CR_DEFAULT_CONTAINER_IDENTIFIER)' not in manager_pid_body

# The unauthenticated raw XPC listener must remain ping-only. Do not silently
# expose the privileged Objective-C service methods to arbitrary clients.
peer_start = helper.index('static void CRHandleHealthPing(')
peer_end = helper.index('#pragma mark - main', peer_start)
peer_code = helper[peer_start:peer_end]
assert 'strcmp(operation, "ping")' in peer_code
assert 'CRHandleHealthPing(peer, message)' in peer_code
for prohibited in ('setPreferenceValue:', 'restoreKeychainItems:', 'reloadApplicationWithIdentifier:'):
    assert prohibited not in peer_code, f"privileged endpoint exposed: {prohibited}"

print("Crane daemon static contracts: PASS (runtime unverified)")
