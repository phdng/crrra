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
    variants = {
        "crane-native-valid.cranect": valid,
        "crane-native-bad-crc.cranect": bytes(corrupt),
        "crane-native-invalid-info.cranect": fixture(b"not-a-binary-property-list"),
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
