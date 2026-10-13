"""F-07 per-container keychain isolation contract.

CI validates reconstruction against a small tracked evidence fixture extracted
from the recovered CraneSupport binary.  When the ignored local decompile export
is available, the same run additionally cross-checks the fixture against it.

The original 0x11C08 private-symbol patchfinder fallback remains unported; this
test requires all five normal-path securityd hooks to be installed together or
not at all.
"""
import json
import os
from pathlib import Path

root = Path(__file__).resolve().parents[1]
repo = root.parent
source = (root / "sources/support/CRSecurityd.m").read_text(encoding="utf-8")
support = (root / "sources/support/CRSupport.m").read_text(encoding="utf-8")
makefile = (root / "sources/support/Makefile").read_text(encoding="utf-8")

fixture_path = root / "tools/fixtures/keychain_securityd_evidence.json"
fixture = json.loads(fixture_path.read_text(encoding="utf-8"))

# The full original exports live under Library/, which is intentionally ignored
# by Git. CI therefore consumes this reviewable fixture instead of assuming the
# workstation-only decompile tree exists.
assert fixture["ignore_access_groups_offset"] == "0x62FC"
assert fixture["access_group_marker_offset"] == "0x10834"
assert fixture["host_pid_offset"] == "0x112D8"
assert fixture["unrestrict_offset"] == "0x10FB0"
assert fixture["init_offset"] == "0x11E5C"
assert fixture["hook_dispatch_offset"] == "0x12FF8"
assert fixture["hook_table_stride"] == 32
assert fixture["hook_count"] == 5

ignore_groups = tuple(fixture["ignore_access_groups"])
assert ignore_groups == (
    "com.apple.token",
    "com.apple.certificates",
    "com.apple.identities",
    "apple",
    "com.apple.cfnetwork",
    "com.apple.ProtectedCloudStorage",
    "com.apple.passd",
    "com.apple.managed.vpn.shared",
)
for group in ignore_groups:
    assert f'@"{group}"' in source, group

# These earlier reconstruction guesses are not in the recovered ignore list.
assert '@"group.com.apple.icloud"' not in source
assert '@"*"' not in source

# Exact per-container access-group marker from 0x10834/0x108B8.
marker = fixture["access_group_marker"]
assert marker == ".c_r_a_n_e."
assert f'@"{marker}"' in source
assert "CRSecurityUpdatedAccessGroup" in source
assert "CR_DEFAULT_CONTAINER_IDENTIFIER" in source

# securityd host PID must be scoped around the original XPC dictionary handler,
# then resolved through the same ClientContainerCache surface used by the other
# CraneSupport daemon hooks.
host_pid_key = fixture["host_pid_key"]
assert host_pid_key == "hostPid"
assert f'CRSecurityHostPidKey = @"{host_pid_key}"' in source
assert 'dlsym(RTLD_DEFAULT, "xpc_connection_get_pid")' in source
assert "activeContainerIdentifierForPid:pid" in source
# Device diagnostics are transition-only and must observe the resolved state
# after ClientContainerCache lookup, never alter query/access-group behavior.
assert "static void CRSecurityLogClientResolution" in source
assert 'lastStateByPid[@(pid)] = state;' in source
assert 'CraneSupport: securityd client pid=%d signingID=%@ container=%@' in source
fetch = source[source.index("static void CRSecurityFetchClientInfo"):
               source.index("/* CraneSupport 0x10D90")]
assert fetch.index("activeContainerIdentifierForPid:pid") < fetch.index("CRSecurityLogClientResolution(pid, signingID, *containerOut);")
handler = source[source.index("static void CRSecurityDXPCHandlerHook"):
                 source.index("void CRInstallSecuritydHooks")]
assert "threadDictionary[CRSecurityHostPidKey] = @(pid);" in handler
assert "gSecurityDXPCHandlerOrig(connection, message);" in handler
assert "[threadDictionary removeObjectForKey:CRSecurityHostPidKey];" in handler

# Original helper-only escape hatch is preserved and stripped before forwarding.
unrestrict_key = fixture["unrestrict_key"]
helper_prefix = fixture["helper_signing_prefix"]
assert unrestrict_key == "craneprefs_unrestrict"
assert helper_prefix == "cranehelperd"
assert f'CRSecurityUnrestrictKey = @"{unrestrict_key}"' in source
assert f'[signingID hasPrefix:@"{helper_prefix}"]' in source
assert "CRSecurityDictionaryWithoutUnrestrict" in source

# All four data operations transform the query/attributes and temporary client
# access-group list; read/add also restore application-visible access groups in
# returned dictionaries/arrays.
for hook in (
    "CRSecItemCopyMatchingHook",
    "CRSecItemAddHook",
    "CRSecItemDeleteHook",
    "CRSecItemUpdateHook",
):
    assert f"static int64_t {hook}" in source, hook
assert source.count(
    "CRSecurityApplyClientInfoContainer(clientInfo, containerID)"
) == 4
assert source.count(
    "CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups)"
) >= 8
assert source.count("CRSecurityProcessResult(result);") == 2
assert "CRSecurityApplicationDictionary" in source

# 0x11E5C resolves exactly five private functions before installing five hooks.
symbols = tuple(fixture["private_symbols"])
assert symbols == (
    "_securityd_xpc_dictionary_handler",
    "__SecItemCopyMatching",
    "__SecItemAdd",
    "__SecItemDelete",
    "__SecItemUpdate",
)
for symbol in symbols:
    assert f'MSFindSymbol(image, "{symbol}")' in source, symbol

init = source[source.index("void CRInstallSecuritydHooks(void)"):]
guard = "if (!xpcHandler || !copyMatching || !add || !deleteItem || !update)"
assert guard in init
assert init.index(guard) < init.index("struct CRSecurityHookEntry hooks[5]")
assert init.count("CRSecurityHookFunctions(hooks, 5)") == 1
assert source.count("MSHookFunction(") == 2  # extern declaration + fallback call
assert fixture["libhooker_symbol"] == "__LHHookFunctions"
assert fixture["fallback_hook"] == "MSHookFunction"
assert 'dlsym(RTLD_DEFAULT, "__LHHookFunctions")' in source
assert "return lhHookFunctions(hooks, count);" in source
assert "keychain isolation hooks=5 status=%d" in init
assert "reason=missing_private_symbols" in init

# Build/dispatch integration.
assert "CRSecurityd.m" in makefile
assert "extern void CRInstallSecuritydHooks(void);" in support
dispatch_start = support.index("static void CRInitSecurityd(void)")
security_dispatch = support[
    dispatch_start:
    support.index("/* ------------------------------------------------------------------------- */",
                  dispatch_start)
]
assert "CRInstallSecuritydHooks();" in security_dispatch
assert '[process isEqualToString:@"securityd"]' in support

# Optional workstation-only evidence cross-check.  Library/ is ignored by Git,
# so absence here is expected in GitHub Actions and is not a contract failure.
evidence_names = (
    "62FC", "10834", "108B8", "10C1C", "10D90", "10EB0",
    "10FB0", "11034", "11130", "111E4", "112D8",
    "11498", "11680", "11868", "11A20", "11E5C", "12FF8",
)
original_dir = (
    repo
    / "Library/MobileSubstrate/DynamicLibraries"
    / "CraneSupport.dylib_export_for_ai/decompile"
)
skip_native = os.environ.get("CRANE_KEYCHAIN_SKIP_NATIVE_EXPORT") == "1"
native_available = (
    not skip_native
    and all((original_dir / f"{name}.c").is_file() for name in evidence_names)
)
if native_available:
    original = {
        name: (original_dir / f"{name}.c").read_text(encoding="utf-8")
        for name in evidence_names
    }
    for group in ignore_groups:
        assert f'CFSTR("{group}")' in original["62FC"], group
    assert f'CFSTR("{marker}")' in original["10834"]
    assert f'CFSTR("{host_pid_key}")' in original["112D8"]
    assert f'CFSTR("{unrestrict_key}")' in original["10FB0"]
    for symbol in symbols:
        assert f'MSFindSymbol(v0, "{symbol}"' in original["11E5C"], symbol
    assert "MSHookFunction(*(v4 - 1), *v4, v4[1])" in original["12FF8"]
    assert fixture["libhooker_symbol"] in original["12FF8"]
    print("Crane F-07 original evidence: tracked fixture + local decompile cross-check PASS")
else:
    print("Crane F-07 original evidence: tracked fixture PASS (local decompile unavailable/skipped)")

# Independent model of 0x108B8 access-group transitions.
def update_group(group, old, new):
    if group is None:
        return None
    if not new or old == new:
        return group
    base_marker = ".c_r_a_n_e"
    if new == "DEFAULT":
        if old:
            return group.replace(".c_r_a_n_e." + old, "")
        return group.split(base_marker, 1)[0]
    if old == "DEFAULT":
        base = group.split(base_marker, 1)[0]
        return base + ".c_r_a_n_e." + new
    if old:
        return group.replace(
            ".c_r_a_n_e." + old,
            ".c_r_a_n_e." + new,
        )
    base = group.split(base_marker, 1)[0]
    return base + ".c_r_a_n_e." + new

assert update_group("TEAM.app", "DEFAULT", "C1") == "TEAM.app.c_r_a_n_e.C1"
assert update_group(
    "TEAM.app.c_r_a_n_e.C1", "C1", "C2"
) == "TEAM.app.c_r_a_n_e.C2"
assert update_group(
    "TEAM.app.c_r_a_n_e.C1", "C1", "DEFAULT"
) == "TEAM.app"
assert update_group(
    "TEAM.app.c_r_a_n_e.C1", None, "DEFAULT"
) == "TEAM.app"
assert update_group("TEAM.app", "C1", "C1") == "TEAM.app"

print("Crane F-07 keychain isolation contracts: PASS (patchfinder/device unverified)")
