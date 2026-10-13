"""F-07 per-container keychain isolation contract.

Compares the reconstructed securityd normal symbol path with recovered
CraneSupport 0x62FC and 0x10834..0x11E5C.  The original 0x11C08 private-symbol
patchfinder fallback remains unported; this test requires all five hooks to be
installed together or not at all.
"""
from pathlib import Path

root = Path(__file__).resolve().parents[1]
repo = root.parent
source = (root / "sources/support/CRSecurityd.m").read_text(encoding="utf-8")
support = (root / "sources/support/CRSupport.m").read_text(encoding="utf-8")
makefile = (root / "sources/support/Makefile").read_text(encoding="utf-8")

original_dir = (
    repo
    / "Library/MobileSubstrate/DynamicLibraries"
    / "CraneSupport.dylib_export_for_ai/decompile"
)

# Evidence files must remain present so this contract cannot silently drift
# away from the recovered binary.
original = {
    name: (original_dir / f"{name}.c").read_text(encoding="utf-8")
    for name in (
        "62FC", "10834", "108B8", "10C1C", "10D90", "10EB0",
        "10FB0", "11034", "11130", "111E4", "112D8",
        "11498", "11680", "11868", "11A20", "11E5C", "12FF8",
    )
}

ignore_groups = (
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
    assert f'CFSTR("{group}")' in original["62FC"], group
    assert f'@"{group}"' in source, group

# These earlier reconstruction guesses are not in the recovered ignore list.
assert '@"group.com.apple.icloud"' not in source
assert '@"*"' not in source

# Exact per-container access-group marker from 0x10834/0x108B8.
assert 'CFSTR(".c_r_a_n_e.")' in original["10834"]
assert '@".c_r_a_n_e."' in source
assert 'CRSecurityUpdatedAccessGroup' in source
assert 'CR_DEFAULT_CONTAINER_IDENTIFIER' in source

# securityd host PID must be scoped around the original XPC dictionary handler,
# then resolved through the same ClientContainerCache surface used by the other
# CraneSupport daemon hooks.
assert 'CFSTR("hostPid")' in original["112D8"]
assert 'CRSecurityHostPidKey = @"hostPid"' in source
assert 'dlsym(RTLD_DEFAULT, "xpc_connection_get_pid")' in source
assert 'activeContainerIdentifierForPid:pid' in source
handler = source[source.index("static void CRSecurityDXPCHandlerHook"):
                 source.index("void CRInstallSecuritydHooks")]
assert 'threadDictionary[CRSecurityHostPidKey] = @(pid);' in handler
assert 'gSecurityDXPCHandlerOrig(connection, message);' in handler
assert '[threadDictionary removeObjectForKey:CRSecurityHostPidKey];' in handler

# Original helper-only escape hatch is preserved and stripped before forwarding.
assert 'CFSTR("craneprefs_unrestrict")' in original["10FB0"]
assert 'CRSecurityUnrestrictKey = @"craneprefs_unrestrict"' in source
assert '[signingID hasPrefix:@"cranehelperd"]' in source
assert 'CRSecurityDictionaryWithoutUnrestrict' in source

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
assert source.count("CRSecurityApplyClientInfoContainer(clientInfo, containerID)") == 4
assert source.count("CRSecurityRestoreClientInfoAccessGroups(clientInfo, oldGroups)") >= 8
assert source.count("CRSecurityProcessResult(result);") == 2
assert "CRSecurityApplicationDictionary" in source

# 0x11E5C resolves exactly five private functions before installing five hooks.
symbols = (
    "_securityd_xpc_dictionary_handler",
    "__SecItemCopyMatching",
    "__SecItemAdd",
    "__SecItemDelete",
    "__SecItemUpdate",
)
for symbol in symbols:
    assert f'MSFindSymbol(image, "{symbol}")' in source, symbol
    assert f'MSFindSymbol(v0, "{symbol}"' in original["11E5C"], symbol

init = source[source.index("void CRInstallSecuritydHooks(void)"):]
guard = 'if (!xpcHandler || !copyMatching || !add || !deleteItem || !update)'
assert guard in init
assert init.index(guard) < init.index("struct CRSecurityHookEntry hooks[5]")
assert init.count("CRSecurityHookFunctions(hooks, 5)") == 1
assert source.count("MSHookFunction(") == 2  # extern declaration + fallback call
assert 'dlsym(RTLD_DEFAULT, "__LHHookFunctions")' in source
assert 'return lhHookFunctions(hooks, count);' in source
assert 'MSHookFunction(*(v4 - 1), *v4, v4[1])' in original["12FF8"]
assert '__LHHookFunctions' in original["12FF8"]
assert 'keychain isolation hooks=5 status=%d' in init
assert 'reason=missing_private_symbols' in init

# Build/dispatch integration.
assert "CRSecurityd.m" in makefile
assert "extern void CRInstallSecuritydHooks(void);" in support
security_dispatch = support[support.index("static void CRInitSecurityd(void)"):
                           support.index("/* ------------------------------------------------------------------------- */",
                                         support.index("static void CRInitSecurityd(void)"))]
assert "CRInstallSecuritydHooks();" in security_dispatch
assert '[process isEqualToString:@"securityd"]' in support

# Independent model of 0x108B8 access-group transitions.
def update_group(group, old, new):
    if group is None:
        return None
    if not new or old == new:
        return group
    marker = ".c_r_a_n_e"
    if new == "DEFAULT":
        if old:
            return group.replace(".c_r_a_n_e." + old, "")
        return group.split(marker, 1)[0]
    if old == "DEFAULT":
        base = group.split(marker, 1)[0]
        return base + ".c_r_a_n_e." + new
    if old:
        return group.replace(
            ".c_r_a_n_e." + old,
            ".c_r_a_n_e." + new,
        )
    base = group.split(marker, 1)[0]
    return base + ".c_r_a_n_e." + new

assert update_group("TEAM.app", "DEFAULT", "C1") == "TEAM.app.c_r_a_n_e.C1"
assert update_group("TEAM.app.c_r_a_n_e.C1", "C1", "C2") == "TEAM.app.c_r_a_n_e.C2"
assert update_group("TEAM.app.c_r_a_n_e.C1", "C1", "DEFAULT") == "TEAM.app"
assert update_group("TEAM.app.c_r_a_n_e.C1", None, "DEFAULT") == "TEAM.app"
assert update_group("TEAM.app", "C1", "C1") == "TEAM.app"

print("Crane F-07 keychain isolation contracts: PASS (patchfinder/device unverified)")
