#!/usr/bin/env python3
"""N2: independent READ-ONLY CRC+ZIP64 verification of native dummy-only ZIP.

Intended exclusively for the fixed, public in-memory Objective-C smoke
fixture, never a real Crane backup or user app contents. Emits no filenames,
path values, digest or data. Full payload CRC here is CI-only, not native N1.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import plistlib
import stat
import struct
import sys
import zipfile

MAX_BYTES = 2 * 1024 * 1024
EXPECTED = (
    "Info.plist",
    "com.example.crane.native/",
    "com.example.crane.native/one.txt",
    "com.example.crane.native/zero.txt",
    "Metadata.plist",
)


class FixtureRejected(ValueError):
    pass


def validate_native_writer_output(path: str | Path) -> dict:
    source = Path(path)
    if source.is_symlink() or not source.is_file() or source.stat().st_size > MAX_BYTES:
        raise FixtureRejected("fixture path invalid")
    before = source.stat()
    with zipfile.ZipFile(source, "r") as archive:
        members = archive.infolist()
        if tuple(i.filename for i in members) != EXPECTED:
            raise FixtureRejected("unexpected fixture member")
        with source.open("rb") as handle:
            for member in members:
                if (member.flag_bits != 0x0808 or member.create_system != 19 or
                        member.extract_version != 45 or
                        member.compress_type !=
                        (zipfile.ZIP_STORED if member.is_dir() else zipfile.ZIP_DEFLATED) or
                        member.flag_bits & 1 or len(member.extra) != 20 or
                        member.extra[:4] != b"\x01\x00\x10\x00"):
                    raise FixtureRejected("unexpected ZIP envelope")
                if struct.unpack_from("<QQ", member.extra, 4) != (
                        member.file_size, member.compress_size):
                    raise FixtureRejected("central ZIP64 sizes differ")
                handle.seek(member.header_offset)
                local = handle.read(30)
                if (len(local) != 30 or local[:4] != b"PK\x03\x04" or
                        struct.unpack_from("<II", local, 18) != (0xFFFFFFFF, 0xFFFFFFFF)):
                    raise FixtureRejected("invalid local ZIP64 sentinel")
                name_len, extra_len = struct.unpack_from("<HH", local, 26)
                if name_len != len(member.filename.encode()) or extra_len != 20:
                    raise FixtureRejected("local member lengths differ")
                local_name = handle.read(name_len)
                local_extra = handle.read(extra_len)
                if (local_name != member.filename.encode() or
                        local_extra != b"\x01\x00\x10\x00" + b"\0" * 16):
                    raise FixtureRejected("invalid local ZIP64 placeholders")
                handle.seek(member.header_offset + 30 + name_len + extra_len +
                            member.compress_size)
                descriptor = handle.read(24)
                if (len(descriptor) != 24 or
                        descriptor[:4] != b"PK\x07\x08" or
                        struct.unpack_from("<IQQ", descriptor, 4) !=
                        (member.CRC, member.compress_size, member.file_size)):
                    raise FixtureRejected("bad ZIP64 descriptor")
                if member.is_dir() and (member.file_size != 0 or
                                        member.compress_size != 0 or member.CRC != 0):
                    raise FixtureRejected("nonempty ZIP directory entry")
                kind = (member.external_attr >> 16) & 0o170000
                if kind != (stat.S_IFDIR if member.is_dir() else stat.S_IFREG):
                    raise FixtureRejected("unexpected Unix file type")

        # These are fixed public dummy values, no private archive permitted.
        info = plistlib.loads(archive.read("Info.plist"))
        if (info.get("applicationIdentifier") != "com.example.crane.native" or
                info.get("deviceIdentifierForVendor") !=
                "00000000-0000-4000-8000-000000000002"):
            raise FixtureRejected("not the synthetic Info.plist")
        metadata = plistlib.loads(archive.read("Metadata.plist"))
        if len(metadata) != 3:
            raise FixtureRejected("synthetic Metadata.plist changed")
        if archive.read("com.example.crane.native/one.txt") != b"DUMMY-SYNTHETIC-ONLY\n":
            raise FixtureRejected("dummy data unexpected")
        if archive.read("com.example.crane.native/zero.txt") != b"":
            raise FixtureRejected("empty dummy data unexpected")
    after = source.stat()
    if ((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) !=
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)):
        raise FixtureRejected("fixture mutated during CRC check")
    return {
        "status": "disposable_native_zip64_payload_crc_verified",
        "entryCount": len(EXPECTED),
        "payloadCRCVerified": True,
        "originalCompatibilityProven": False,
        "restoreExecutable": False,
        "keychainContentsRead": False,
        "filesystemWrites": False,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True)
    args = parser.parse_args()
    try:
        report = validate_native_writer_output(args.archive)
        rc = 0
    except (FixtureRejected, OSError, EOFError, ValueError, TypeError,
            KeyError, RuntimeError, zipfile.BadZipFile, plistlib.InvalidFileException):
        report = {"status": "native_writer_fixture_rejected",
                  "originalCompatibilityProven": False,
                  "restoreExecutable": False}
        rc = 2
    print(json.dumps(report, sort_keys=True))
    return rc


if __name__ == "__main__":
    sys.exit(main())
