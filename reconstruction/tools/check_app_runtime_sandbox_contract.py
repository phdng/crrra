"""F-19 app-side XPC sandbox extension contract.

Chrome on iOS15.8.8 roothide successfully loaded the main dylib and
received a nondefault container UUID, but its own privileged Mach-service
connection to cranehelperd.xpc returned Code=1003 repeatedly. SpringBoard
was able to query the same helper, showing process-specific access.

libSandy already provides profile-based sandbox extensions to other Crane
system components; this reconstruct-only app runtime profile grants ONLY
the helper's exact Mach lookup to sandboxed apps, using the same two
service-specific extension classes recovered in CraneSupport/CraneRB. The
report is still processed by the helper's kernel-PID-scoped, authenticated
registry.

Source/package checks and model only; must build/install and validate on
the device. This does not establish runtime grant success.
"""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
profile_path = root / "layout/Library/libSandy/CraneAppRuntime.plist"
profile = plistlib.loads(profile_path.read_bytes())

assert set(profile) == {"AllowedProcesses", "Extensions"}, profile
# A container switching library runs in any supported third-party bundle.
# The wildcard grants the ability to REQUEST two service-specific Mach
# extension classes for the same exact helper name, not to modify the helper's
# authorization policy.
assert profile["AllowedProcesses"] == ["*"]
assert profile["Extensions"] == [{
    "type": "mach",
    "extension_class": "com.apple.app-sandbox.mach",
    "mach_name": "com.opa334.cranehelperd.xpc",
}, {
    "type": "mach",
    "extension_class": "com.apple.security.exception.mach-lookup.global-name",
    "mach_name": "com.opa334.cranehelperd.xpc",
}]
for extension in profile["Extensions"]:
    assert "path" not in extension
    assert extension["mach_name"] == "com.opa334.cranehelperd.xpc"
assert {x["extension_class"] for x in profile["Extensions"]} == {
    "com.apple.app-sandbox.mach",
    "com.apple.security.exception.mach-lookup.global-name",
}

main = (root / "sources/maindylib/CRMainDylib.m").read_text(encoding="utf-8")
support = (root / "sources/support/CRSupport.m").read_text(encoding="utf-8")
manager = (root / "sources/libcrane/CRManager.m").read_text(encoding="utf-8")
common = (root / "sources/common/CRCommon.m").read_text(encoding="utf-8")
helper = (root / "sources/cranehelperd/CRHelperd.m").read_text(encoding="utf-8")
master = (root / "Makefile").read_text(encoding="utf-8")
verifier = (root / "tools/verify_package_layout.py").read_text(encoding="utf-8")
workflow = (root.parent / ".github/workflows/build.yml").read_text(encoding="utf-8")

a = main.index("static BOOL CRPrepareAppRuntimeMachLookup(void)")
b = main.index("__attribute__((constructor))", a)
setup = main[a:b]
for needle in (
    'CRJailbreakRootPath(CR_LIB_SANDY)',
    'APP_RUNTIME_MACH_DIAGNOSTIC_V2',
    'Crane: app runtime Mach profile begin pid=%d marker=%s',
    'Crane: app runtime Mach profile failed pid=%d reason=no_libSandy_path',
    'Crane: app runtime Mach profile failed pid=%d reason=dlopen',
    'Crane: app runtime Mach profile failed pid=%d reason=no_apply_symbol',
    'dlopen(path.fileSystemRepresentation, RTLD_NOW)',
    'dlsym(handle, "libSandy_applyProfile")',
    'applyProfile("CraneAppRuntime")',
    'dlclose(handle);',
    'Crane: app runtime Mach profile pid=%d status=%d',
    'return rc == 0;',
):
    assert needle in setup, needle
assert setup.index('dlopen(') < setup.index('dlsym(') < setup.index('applyProfile(')
assert setup.index('int rc = applyProfile("CraneAppRuntime");') < setup.rindex('dlclose(handle);')
assert 'sandbox_extension_issue_mach(' not in setup
assert 'task_for_pid(' not in setup

constructor = main[main.index("static void CRInitFunc(void)"):]
assert 'if (_crActiveContainerIdentifier.length) {' in constructor
assert 'CRPrepareAppRuntimeMachLookup();' in constructor
assert 'CRReportRuntimeInjection(@"Crane", _crActiveContainerIdentifier);' in constructor
assert constructor.index('CRPrepareAppRuntimeMachLookup();') < constructor.index('CRReportRuntimeInjection(@"Crane",')
assert constructor.index('if (_crActiveContainerIdentifier.length) {\n        CRPrepareAppRuntimeMachLookup();') != -1
assert 'removeItemAtPath:' not in constructor
assert 'setenv(CR_ENV_HOME.UTF8String, container.UTF8String, 1);' in constructor

# The recovered CraneRB/CraneSupport profiles establish that privileged
# helper lookup uses both service-specific Mach extension classes. Keep the
# app runtime profile aligned with that original evidence rather than inventing
# a broader exception.
for name in ("CraneRB.plist", "CraneSupport.plist"):
    other = plistlib.loads((root / "layout/Library/libSandy" / name).read_bytes())
    helper_extensions = [x for x in other["Extensions"]
                         if x.get("mach_name") == "com.opa334.cranehelperd.xpc"]
    assert {x.get("extension_class") for x in helper_extensions} >= {
        "com.apple.app-sandbox.mach",
        "com.apple.security.exception.mach-lookup.global-name",
    }, name

# The complete IDA export lives under Library/, which is ignored by Git and
# absent on GitHub Actions. Keep small, reviewable evidence in the tracked
# fixture; cross-check its markers AND source-file hashes when native exports
# are available on the developer workstation (same model as F-07/Choicy).
import hashlib
import json
import os

evidence = json.loads(
    (root / "tools/fixtures/cranesupport_constructor_evidence.json")
    .read_text(encoding="utf-8")
)
assert evidence["architecture"] == "arm64"
assert evidence["source"] == "CraneSupport.dylib_export_for_ai/decompile"
ctor_evidence = evidence["constructor"]
profile_evidence = evidence["profile_callback"]
assert ctor_evidence["address"] == "0x6C5C"
assert ctor_evidence["filename"] == "6C5C.c"
assert ctor_evidence["unsandbox_handler_selector"] == '"_setXPCUnsandboxHandler:"'
assert ctor_evidence["first_daemon_dispatch"] == "initCfprefsd();"
assert ctor_evidence["last_daemon_dispatch"] == "initLsd();"
assert ctor_evidence["absent_runtime_report"] == "CRReportRuntimeInjection"
assert profile_evidence["address"] == "0x6E44"
assert profile_evidence["filename"] == "6E44.c"
assert profile_evidence["success_cache_guard"] == "if ( byte_22D18 )"
assert profile_evidence["profile_apply"] == 'libSandy_applyProfile("CraneSupport") == 0'
for record in (ctor_evidence, profile_evidence):
    assert len(record["sha256"]) == 64
    assert all(char in "0123456789abcdef" for char in record["sha256"])

original_support = (
    root.parent
    / "Library/MobileSubstrate/DynamicLibraries"
    / evidence["source"]
)
original_ctor_path = original_support / ctor_evidence["filename"]
original_profile_path = original_support / profile_evidence["filename"]
skip_native = os.environ.get("CRANE_SUPPORT_SKIP_NATIVE_EXPORT") == "1"
require_native = os.environ.get("CRANE_SUPPORT_REQUIRE_NATIVE_EXPORT") == "1"
assert not (skip_native and require_native)
native_available = (
    original_ctor_path.is_file() and original_profile_path.is_file()
)
if require_native:
    assert native_available, "Original CraneSupport IDA exports were required but missing"
if native_available and not skip_native:
    for record in (ctor_evidence, profile_evidence):
        source_path = original_support / record["filename"]
        assert hashlib.sha256(source_path.read_bytes()).hexdigest() == record["sha256"], (
            f"Original IDA evidence changed: {source_path}"
        )
    original_ctor = original_ctor_path.read_text(encoding="utf-8")
    original_profile_callback = original_profile_path.read_text(encoding="utf-8")
    assert original_ctor.index(ctor_evidence["unsandbox_handler_selector"]) < (
        original_ctor.index(ctor_evidence["first_daemon_dispatch"])
    ) < original_ctor.index(ctor_evidence["last_daemon_dispatch"])
    assert ctor_evidence["absent_runtime_report"] not in original_ctor
    assert profile_evidence["success_cache_guard"] in original_profile_callback
    assert profile_evidence["profile_apply"] in original_profile_callback
    print("CraneSupport original constructor evidence: fixture + local IDA cross-check PASS")
else:
    print("CraneSupport original constructor evidence: tracked fixture PASS (local IDA unavailable/skipped)")
# Original CraneSupport 0x6C5C installs a global _setXPCUnsandboxHandler:
# block whose invoke target 0x6E44 applies libSandy profile "CraneSupport"
# and caches only success. The reconstruction runtime_report bypasses the
# unrecovered original libcrane XPC transport, so it must invoke the same
# profile gate explicitly before reporting while preserving the manager hook.
support_profile = plistlib.loads(
    (root / "layout/Library/libSandy/CraneSupport.plist").read_bytes())
assert "com.apple.securityd" in support_profile["AllowedProcesses"]
assert any(x.get("mach_name") == "com.opa334.cranehelperd.xpc"
           for x in support_profile["Extensions"])
unsandbox_start = support.index("static BOOL CRPrepareSupportXPCUnsandbox(void)")
unsandbox_end = support.index("__attribute__((constructor))", unsandbox_start)
unsandbox = support[unsandbox_start:unsandbox_end]
for needle in (
    'CRJailbreakRootPath(CR_LIB_SANDY)',
    'dlopen(path.fileSystemRepresentation, RTLD_NOW)',
    'dlsym(handle, "libSandy_applyProfile")',
    'applyProfile("CraneSupport")',
    'applied = (status == 0);',
    'CraneSupport: XPC unsandbox profile process=%@ status=%d',
):
    assert needle in unsandbox, needle
constructor_support = support[support.index("static void CRInitFunc(void)"):]
assert 'CraneSupport: constructor process=%@ platform=%@' not in constructor_support
assert '[manager _setXPCUnsandboxHandler:^BOOL{' in constructor_support
# Original 0x6C5C dispatches daemon hooks immediately after registering
# the unsandbox handler. Attestation is reconstruction-only: reporting before
# hooks could falsely certify isolation before its hooks even exist.
hook_first = constructor_support.index('if ([process isEqualToString:@"cfprefsd"])')
hook_last = constructor_support.index('CRInitLsd();')
profile_apply = constructor_support.index('BOOL unsandboxed = CRPrepareSupportXPCUnsandbox();')
runtime_proof = constructor_support.index('CRReportRuntimeInjection(@"CraneSupport", nil);')
assert constructor_support.index('[manager _setXPCUnsandboxHandler:^BOOL{') < hook_first
assert hook_first < hook_last < profile_apply < runtime_proof
assert constructor_support.count('CRReportRuntimeInjection(@"CraneSupport", nil);') == 1
assert 'CraneSupport: init process=%@ xpcUnsandbox=%d' in constructor_support

# libcrane's reconstructed raw-XPC paths now honor the recovered handler.
assert 'static xpc_connection_t CRManagerCreateHelperConnection(void)' in manager
assert 'if (![manager crane_prepareXPCUnsandbox])' in manager
assert 'return handler ? handler() : YES;' in manager
assert '- (void)_setXPCUnsandboxHandler:(id)handler' in manager
assert 'self.unsandboxHandler = [handler copy];' in manager
assert manager.count('xpc_connection_t connection = CRManagerCreateHelperConnection();') >= 4
shortcuts = plistlib.loads((root / "layout/Library/libSandy/CraneShortcuts.plist").read_bytes())
assert any(x.get("mach_name") == "com.opa334.cranehelperd.xpc"
           for x in shortcuts["Extensions"])

assert 'CR_HELPERD_MACH_SERVICE.UTF8String, NULL, XPC_CONNECTION_MACH_SERVICE_PRIVILEGED' in common
assert 'xpc_connection_send_message(created, replay);' in common
assert 'xpc_connection_send_message_with_reply(created, probe,' not in common
assert 'app_runtime_probe' not in common
assert 'CRRuntimeComponentAllowed(component, peerProcess, peerSigningID)' in helper
assert 'CRRegisterRuntime(peerPid, peerProcess, component, containerID,' in helper
assert 'CRRuntimeContainerForPid(targetPid, targetProcess)' in helper
assert 'xpc_dictionary_set_bool(reply, "injection_verified", containerID.length > 0)' in helper

# Theos package verification's expected file list is populated from layout;
# ensure the new app runtime sandbox profile is installed as data, never
# accidentally placed in the DEBIAN control archive.
assert 'for p in layout.rglob("*")' in verifier
assert 'p.relative_to(layout).parts[0] != "DEBIAN"' in verifier
assert 'app_profile = root / "Library/libSandy/CraneAppRuntime.plist"' in verifier
assert 'actual_profile = plistlib.loads(app_profile.read_bytes())' in verifier
assert '"mach_name": "com.opa334.cranehelperd.xpc",' in verifier
assert '"FAIL app runtime sandbox: invalid or overbroad permissions"' in verifier
assert 'include $(THEOS_MAKE_PATH)/aggregate.mk' in master
assert 'check_app_runtime_sandbox_contract.py' in workflow
assert "'pkg/Library/MobileSubstrate/DynamicLibraries/CraneSupport.dylib'" in workflow
assert 'otool -L "$binary" | tee -a linkage.txt' in workflow
assert 'sh -n reconstruction/tools/diagnose_crane_app_mach.sh' in workflow
shell = (root / 'tools/diagnose_crane_app_mach.sh').read_text(encoding='utf-8')
assert shell.startswith('#!/bin/sh')
for statement in (
    'APP_RUNTIME_MACH_DIAGNOSTIC_V2',
    'Crane: app runtime Mach profile',
    'strings "$image"',
    'plutil -p "$granted"',
    'A profile file or binary marker alone does NOT establish',
):
    assert statement in shell
for forbidden in ('launchctl bootstrap ', 'launchctl kickstart ', 'chmod ', 'chown ', 'sandbox_extension_issue_'):
    assert forbidden not in shell

# Do not mistake a profile-apply failure for registration success.
def outcome(profile_applied, report_transport, helper_registered):
    if not profile_applied:
        return "profile-unavailable"
    if not report_transport:
        return "transport-unavailable"
    if not helper_registered:
        return "unverified-runtime"
    return "live-proof"

assert outcome(False, False, False) == "profile-unavailable"
assert outcome(True, False, False) == "transport-unavailable"
assert outcome(True, True, False) == "unverified-runtime"
assert outcome(True, True, True) == "live-proof"

print("Crane app runtime Mach-extension contracts: PASS (native/device unverified)")
