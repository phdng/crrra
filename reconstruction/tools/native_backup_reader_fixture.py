#!/usr/bin/env python3
"""Create three disposable ZIP64/local-descriptor native reader smoke fixtures.

No real app data; output exists only for macOS Foundation CI smoke tests.
Does not use the original user Chrome archive. The isolated native reader
must accept the valid file and reject bad CRC and non-binary Info.plist.
"""
from __future__ import annotations

import argparse
import io
from pathlib import Path
import plistlib
import struct
import zipfile


class NoSeek:
    def __init__(self):
        self.data = io.BytesIO()

    def write(self, data):
        return self.data.write(data)

    def flush(self):
        return self.data.flush()

    def tell(self):
        raise io.UnsupportedOperation("force data descriptors, no seeking")

    def seek(self, offset, whence=0):
        raise io.UnsupportedOperation("force data descriptors, no seeking")


INFO = {
    "applicationIdentifier": "com.example.crane.native",
    "containerIdentifier": "00000000-0000-4000-8000-000000000001",
    "containerName": "synthetic-test-only",
    "deviceIdentifierForVendor": "00000000-0000-4000-8000-000000000002",
    "originalPaths": {
        "com.example.crane.native": "/disposable/fake/app",
        "group.com.example.crane.native": "/disposable/fake/group",
    },
}


def fixture(info_bytes: bytes) -> bytes:
    sink = NoSeek()
    with zipfile.ZipFile(sink, mode="w", allowZip64=True) as archive:
        member = zipfile.ZipInfo("Info.plist")
        member.create_system = 19
        member.compress_type = zipfile.ZIP_DEFLATED
        with archive.open(member, "w", force_zip64=True) as output:
            output.write(info_bytes)
        archive.writestr("com.example.crane.native/empty.txt", b"")
    return sink.data.getvalue()


def create(output: Path) -> list[Path]:
    if not output.is_dir():
        raise ValueError("pre-existing output directory required")
    valid = fixture(plistlib.dumps(INFO, fmt=plistlib.FMT_BINARY))
    marker = b"PK\x07\x08"
    descriptor = valid.find(marker)
    if descriptor == -1 or descriptor + 8 > len(valid):
        raise ValueError("ZIP data descriptor not generated")
    corrupt = bytearray(valid)
    corrupt[descriptor + 4] ^= 0x01
    # First central Info record: sizes/CRC are genuine here, while the
    # local ZIP64 extra carries zeroes because bit 3 is set. Test that the
    # native reader validates the CENTRAL fields, not just the descriptor.
    central = valid.rfind(b"PK\x05\x06")
    if central < 0:
        raise ValueError("missing end of central directory")
    first_central = struct.unpack_from("<I", valid, central + 16)[0]
    if valid[first_central:first_central + 4] != b"PK\x01\x02":
        raise ValueError("missing first central record")
    wrong_size = bytearray(valid)
    wrong_size[first_central + 20] ^= 1
    wrong_crc = bytearray(valid)
    wrong_crc[first_central + 16] ^= 1
    variants = {
        "crane-native-valid.cranect": valid,
        "crane-native-bad-crc.cranect": bytes(corrupt),
        "crane-native-invalid-info.cranect": fixture(b"not-a-binary-property-list"),
        "crane-native-bad-central-size.cranect": bytes(wrong_size),
        "crane-native-bad-central-crc.cranect": bytes(wrong_crc),
    }
    written = []
    for name, data in variants.items():
        target = output / name
        if target.is_symlink():
            raise ValueError("output must not be symlink")
        with target.open("xb") as stream:
            stream.write(data)
        written.append(target)
    return written


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()
    names = create(Path(args.output_dir))
    for name in names:
        print(name.name)


if __name__ == "__main__":
    main()
