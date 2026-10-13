#!/usr/bin/env python3
"""Verify emitted helper signing entitlements. No device or signing action."""
from pathlib import Path
import plistlib
import struct
import sys

ROOT = Path(__file__).resolve().parents[1]
NATIVE = ROOT.parent
EXTRA_ROOTHIDE = {
    "platform-application": True,
    "com.apple.private.security.no-sandbox": True,
    "com.apple.private.security.storage.AppBundles": True,
    "com.apple.private.security.storage.AppDataContainers": True,
}
# Recovered from LC_CODE_SIGNATURE, SuperBlob slot 5 in each original tool.
ORIGINAL = {
    "cranehelperd": {
        "platform-application": True,
        "com.apple.private.security.container-required": False,
        "task_for_pid-allow": True,
        "get-task-allow": True,
        "com.apple.private.security.no-container": True,
        "com.apple.multitasking.termination": True,
        "com.apple.security.exception.mach-lookup.global-name": [
            "jailbreakd", "com.apple.cfprefsd.daemon", "com.apple.containermanagerd",
            "com.apple.securityd", "com.apple.pluginkit.pkd", "com.apple.lsd.xpc",
            "com.apple.accountsd.accountmanager", "com.apple.apsd",
        ],
    },
    "cranehelperd_start": {
        "platform-application": True,
        "com.apple.private.security.container-required": False,
    },
}
RELATIVE = {
    "cranehelperd": "usr/local/libexec/cranehelperd",
    "cranehelperd_start": "usr/local/bin/cranehelperd_start",
}

def read_entitlements(path):
    data = Path(path).read_bytes()
    magic = struct.unpack_from(">I", data)[0]
    if magic == 0xCAFEBABE:
        count = struct.unpack_from(">I", data, 4)[0]
        assert count == 1, f"{path}: expected one executable slice"
        _, _, offset, size, _ = struct.unpack_from(">iiIII", data, 8)
        assert 0 <= offset < offset + size <= len(data)
        data = data[offset:offset + size]
    assert struct.unpack_from("<I", data)[0] == 0xFEEDFACF, f"{path}: not Mach-O64"
    ncmds = struct.unpack_from("<I", data, 16)[0]
    pos = 32
    signature = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, pos)
        assert size >= 8 and pos + size <= len(data)
        if cmd == 0x1D:
            offset, length = struct.unpack_from("<II", data, pos + 8)
            assert offset + length <= len(data)
            signature = data[offset:offset + length]
            break
        pos += size
    assert signature, f"{path}: missing LC_CODE_SIGNATURE"
    magic, length, count = struct.unpack_from(">III", signature)
    assert magic == 0xFADE0CC0 and length <= len(signature)
    for i in range(count):
        slot, offset = struct.unpack_from(">II", signature, 12 + i * 8)
        if slot == 5:
            magic, size = struct.unpack_from(">II", signature, offset)
            assert magic == 0xFADE7171 and offset + size <= length
            return plistlib.loads(signature[offset + 8:offset + size])
    raise AssertionError(f"{path}: missing XML entitlement slot 5")

def expected(name, variant):
    result = dict(ORIGINAL[name])
    if variant == "roothide":
        result.update(EXTRA_ROOTHIDE)
    return result

def check_sources():
    for name, original in ORIGINAL.items():
        for variant in ("original", "roothide"):
            p = ROOT / "sources" / name / f"entitlements.{variant}.plist"
            assert plistlib.loads(p.read_bytes()) == expected(name, variant), p
        native = NATIVE / RELATIVE[name]
        if native.exists():
            assert read_entitlements(native) == original, native
            print(f"{name}: original code-signature slot 5 matches")
        else:
            print(f"{name}: original binary unavailable; pinned evidence only")

def main():
    check_sources()
    if len(sys.argv) > 1:
        assert len(sys.argv) == 3 and sys.argv[2] in ("rootful", "roothide")
        package, variant = Path(sys.argv[1]), sys.argv[2]
        for name, rel in RELATIVE.items():
            assert read_entitlements(package / rel) == expected(name, variant), name
            print(f"{name}: packaged {variant} entitlements match")
    print("Helper entitlement verification: PASS (device execution unverified)")

if __name__ == "__main__":
    main()
