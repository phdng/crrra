#!/usr/bin/env python3
"""Verify the fat-slice architectures of the packaged binaries.

Run by CI after unpacking the .deb. Reads the Mach-O fat headers directly so it
has no dependency on otool, which is convenient but not required.

Exit code 0 when dylibs/bundles are fat arm64 + arm64e and executable tools
are thin arm64, matching the recovered package (CONFIRMED_STATIC: see
analysis/binary_inventory.md). Any other slice set is an error.
"""
import pathlib
import struct
import sys

FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
CPU_ARM64 = 0x0100000C
SUBTYPE_ARM64_ALL = 0
SUBTYPE_ARM64E = 2


def slices(path):
    data = path.read_bytes()
    if len(data) < 8:
        return None
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        n = struct.unpack_from(">I", data, 4)[0]
        out = []
        for i in range(n):
            cputype, cpusubtype, off, size, align = struct.unpack_from(">iiIII", data, 8 + i * 20)
            out.append((cputype, cpusubtype))
        return out
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic in (0xFEEDFACF, 0xFEEDFACE, 0xCFFAEDFE, 0xCEFAEDFE):
        cputype, cpusubtype = struct.unpack_from("<ii", data, 4)
        return [(cputype, cpusubtype)]
    return None


def mach_header_filetype(path):
    """Return MH_DYLIB / MH_EXECUTE by reading the slice's mach_header."""
    data = path.read_bytes()
    if len(data) < 8:
        return None
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        n = struct.unpack_from(">I", data, 4)[0]
        if n < 1:
            return None
        off = struct.unpack_from(">iiIII", data, 8)[2]
        magic2 = struct.unpack_from("<I", data, off)[0]
        if magic2 not in (0xFEEDFACF, 0xFEEDFACE, 0xCFFAEDFE, 0xCEFAEDFE):
            return None
        filetype = struct.unpack_from("<I", data, off + 12)[0]
    else:
        if magic not in (0xFEEDFACF, 0xFEEDFACE, 0xCFFAEDFE, 0xCEFAEDFE):
            return None
        filetype = struct.unpack_from("<I", data, 12)[0]
    return {2: "MH_EXECUTE", 6: "MH_DYLIB", 8: "MH_BUNDLE", 1: "MH_OBJECT"}.get(filetype)


def main(root):
    root = pathlib.Path(root)
    failures = 0
    checked = 0
    for p in sorted(root.rglob("*")):
        if not p.is_file():
            continue
        sl = slices(p)
        if sl is None:
            continue
        checked += 1
        rel = p.relative_to(root)
        filetype = mach_header_filetype(p)
        # CONFIRMED_STATIC from the original package (analysis/binary_inventory.md):
        # every *dylib* is a fat arm64 + arm64e binary, while every *executable*
        # (cranehelperd, cranehelperd_start, the app and the appex) is a thin
        # arm64 binary. The reconstruction must match both.
        wants_fat = filetype in ("MH_DYLIB", "MH_BUNDLE")
        names = []
        ok = True
        for cputype, cpusubtype in sl:
            if cputype != CPU_ARM64:
                ok = False
                names.append("cputype=0x%X" % cputype)
            elif cpusubtype == SUBTYPE_ARM64_ALL:
                names.append("arm64")
            elif cpusubtype == SUBTYPE_ARM64E:
                names.append("arm64e")
            else:
                ok = False
                names.append("arm64(0x%X)" % cpusubtype)
        if wants_fat:
            have = sorted(names)
            if have != ["arm64", "arm64e"]:
                ok = False
        else:
            if names != ["arm64"]:
                ok = False
        status = "OK  " if ok else "FAIL"
        if not ok:
            failures += 1
        print("%s %-72s %-12s %s" % (status, rel, filetype, " + ".join(names)))
    print("\n%d Mach-O binaries checked, %d failures" % (checked, failures))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "."))